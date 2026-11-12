"""A Claude quota wait remembers its login and retries at once after a login change."""

import io
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import contextlib

import test_cycle as fixtures
import test_focus_pairs as pairs
from test_cycle import report
from cycle_state import ProviderQuota
from cycle_prompts import PROFILES
import cycle_transport
from cycle_transport import LoginWatch, QuotaProbe, Transport, claude_account, probe_outcome
from focus_status import build_panel

FIXTURE = [sys.executable, str(fixtures.REPO / "tests/test_cycle.py"), "fixture"]
PROBE_FOLDER = cycle_transport.probe_folder
ACCOUNT = {"accountUuid": "11111111-2222-3333-4444-555555555555", "organizationUuid": "org-1",
           "emailAddress": "person@example.invalid", "displayName": "Person"}


class AccountTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.config = Path(self.temp.name)

    def login(self, account, folder=None):
        (folder or self.config).mkdir(parents=True, exist_ok=True)
        (folder or self.config).joinpath(".claude.json").write_text(json.dumps({"oauthAccount": account, "projects": {}}))

    def test_the_hash_names_the_account_and_its_organization_without_the_address(self):
        env = {"CLAUDE_CONFIG_DIR": str(self.config)}
        self.login(ACCOUNT)
        first = claude_account(env)
        self.assertRegex(first, "^[0-9a-f]{64}$")
        self.assertNotIn("person", first)
        self.login(dict(ACCOUNT, displayName="Renamed", emailAddress="new@example.invalid"))
        self.assertEqual(claude_account(env), first)  # The account ID decides, not the profile text.
        for change in ({"accountUuid": "other"}, {"organizationUuid": "org-2"}):
            with self.subTest(change=change):
                self.login(dict(ACCOUNT, **change))
                self.assertNotEqual(claude_account(env), first)
        self.login({"emailAddress": "person@example.invalid"})
        self.assertRegex(claude_account(env), "^[0-9a-f]{64}$")  # An older record has only the address.

    def test_an_unknown_login_gives_none(self):
        env = {"CLAUDE_CONFIG_DIR": str(self.config)}
        self.assertIsNone(claude_account(env))  # No file.
        for content in ("{broken", json.dumps([]), json.dumps({}), json.dumps({"oauthAccount": {"accountUuid": ""}})):
            with self.subTest(content=content[:20]):
                (self.config / ".claude.json").write_text(content)
                self.assertIsNone(claude_account(env))
        self.login(ACCOUNT)
        for key in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"):
            with self.subTest(key=key):
                self.assertIsNone(claude_account(dict(env, **{key: "secret"})))  # A key replaces the login.

    def test_without_a_config_directory_the_home_file_counts(self):
        home = self.config / "home"
        self.login(ACCOUNT, home)
        with patch.object(Path, "home", return_value=home):
            self.assertEqual(claude_account({}), claude_account({"CLAUDE_CONFIG_DIR": str(home)}))
        self.assertIsNotNone(claude_account({"CLAUDE_CONFIG_DIR": str(home)}))

    def test_the_watch_reads_the_login_at_most_every_period(self):
        watch, reads, clock = LoginWatch(), [], [100.0]
        def current():
            reads.append(clock[0])
            return "new" if clock[0] >= 105 else "old"
        with patch("cycle_transport.claude_account", side_effect=current), \
                patch("cycle_transport.time.monotonic", side_effect=lambda: clock[0]):
            self.assertFalse(watch.changed(None))  # A wait without a login is for the operator.
            self.assertEqual(reads, [])
            self.assertFalse(watch.changed("old"))
            clock[0] = 105
            self.assertFalse(watch.changed("old"))  # Within the period, the last reading counts.
            clock[0] = 100 + LoginWatch.PERIOD
            self.assertTrue(watch.changed("old"))
        self.assertEqual(reads, [100.0, 100.0 + LoginWatch.PERIOD])
        with patch("cycle_transport.claude_account", return_value=None):
            self.assertFalse(LoginWatch().changed("old"))  # An unknown current login is no change.


class QuotaLoginTests(unittest.TestCase):
    setUp = fixtures.CycleTests.setUp
    tearDown = fixtures.CycleTests.tearDown

    def test_a_quota_refusal_names_the_login_of_its_launch(self):
        config = Path(self.temp.name) / "claude-config"
        config.mkdir()
        (config / ".claude.json").write_text(json.dumps({"oauthAccount": ACCOUNT}))
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["claude"] = FIXTURE + ["claude", "quota"]
        directory = self.store.directory / "invocations" / "quota"
        directory.mkdir(parents=True)
        _, model, effort = PROFILES["code"]
        with patch.dict(os.environ, CLAUDE_CONFIG_DIR=str(config), ORCHESTRA_FIXTURE_MODEL=model,
                        ORCHESTRA_FIXTURE_EFFORT=effort), self.assertRaises(ProviderQuota) as caught:
            transport.run("code", "Implement", {"id": "quota"}, directory)
        self.assertEqual(caught.exception.account, claude_account({"CLAUDE_CONFIG_DIR": str(config)}))
        self.cycle.state["pending"] = {"id": "quota", "role": "code", "before": self.repo.snapshot()}
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.cycle.defer_quota(caught.exception)
        self.assertEqual(self.state["pending"]["quota_wait"]["account"], caught.exception.account)
        self.assertIn("or at once after a Claude login change", output.getvalue())
        self.assertNotIn("person", json.dumps(self.store.read()))

    def test_a_login_change_retries_the_same_invocation_at_once(self):
        self.state.update(phase="opus_final", coordinated="opus_final", sol_clean=3, astra_clean=2, opus_final_clean=1,
                          sessions={"opus_final": "same-native-session"})
        ids = []
        def reject():
            pending = self.state["pending"]
            pending["attempts"] = 1
            ids.append(pending["id"])
            raise ProviderQuota(time.time() + 86400, no_work=True, account="old-login")
        def retry():
            ids.append(self.state["pending"]["id"])
            self.assertEqual(self.state["sessions"]["opus_final"], "same-native-session")
            return report()
        control = type("ControlFixture", (), {"boundary": lambda _, window: self.state["phase"] == "final"})()
        self.cycle.control = control
        self.transport.actions = [("opus_final", reject), ("opus_final", retry)]
        with patch("cycle_transport.claude_account", return_value="new-login"), \
                patch("cycle_workflow.time", wraps=time) as timer, contextlib.redirect_stdout(io.StringIO()) as output:
            timer.sleep.side_effect = AssertionError("no wait after a login change")
            self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(len(ids), 2)
        self.assertEqual(ids[0], ids[1])
        self.assertIn("the Claude login changed after the quota refusal", output.getvalue())

    def test_the_same_login_unresolved_messages_and_an_older_wait_keep_the_deadline(self):
        deadline = time.time() + 3600
        cases = (("same login", {"account": "login"}, "login", False),
                 ("unresolved message", {"account": "old"}, "new", True),
                 ("older wait", {}, "new", False))
        for name, extra, current, unresolved in cases:
            with self.subTest(name):
                self.cycle.login_watch = LoginWatch()
                self.state["pending"] = {"id": "waiting", "role": "code", "quota_wait": dict(extra, retry_at=deadline)}
                with patch("cycle_transport.claude_account", return_value=current), \
                        patch.object(self.cycle.messages, "unresolved", return_value=[{"id": "m"}] if unresolved else []), \
                        patch("cycle_workflow.time", wraps=time) as timer:
                    timer.sleep.side_effect = lambda _: None
                    self.assertTrue(self.cycle.wait_quota())
                self.assertEqual(self.state["pending"]["quota_wait"]["retry_at"], deadline)

    def test_the_panel_says_how_a_login_change_retries(self):
        for account, text in (("login", "смена логина — повтор сразу"), (None, "после смены логина — /resume")):
            with self.subTest(account=account):
                wait = {"retry_at": time.time() + 3600, "resets_at": time.time() + 3600}
                if account:
                    wait["account"] = account
                self.state.update(phase="code", status="running", pending={"id": "waiting", "role": "code", "quota_wait": wait})
                panel = "\n".join(build_panel(self.state).lines)
                self.assertIn(text, panel)
                self.assertIn(f"проверка квоты каждые {QuotaProbe.PERIOD // 60} мин", panel)

    def test_an_answered_quota_check_retries_the_same_invocation_at_once(self):
        self.state.update(phase="opus_final", coordinated="opus_final", sol_clean=3, astra_clean=2, opus_final_clean=1,
                          sessions={"opus_final": "same-native-session"})
        ids = []
        def reject():
            pending = self.state["pending"]
            pending["attempts"] = 1
            ids.append(pending["id"])
            raise ProviderQuota(time.time() + 86400, no_work=True, account="same-login")
        def retry():
            ids.append(self.state["pending"]["id"])
            return report()
        control = type("ControlFixture", (), {"boundary": lambda _, window: self.state["phase"] == "final"})()
        self.cycle.control = control
        self.transport.actions = [("opus_final", reject), ("opus_final", retry)]
        checks = []
        def answered(model, waiter, wait, ready):
            checks.append((model, waiter))
            return ready()  # An operator reset the quota of the same login.
        with patch("cycle_transport.claude_account", return_value="same-login"), \
                patch.object(self.cycle.quota_probe, "answered", side_effect=answered), \
                patch("cycle_workflow.time", wraps=time) as timer, contextlib.redirect_stdout(io.StringIO()) as output:
            timer.sleep.side_effect = AssertionError("no wait after an answered quota check")
            self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(len(ids), 2)
        self.assertEqual(ids[0], ids[1])
        self.assertEqual(checks, [(PROFILES["opus_final"][1], ids[0])])  # The model of the role that waits.
        self.assertIn("a Claude quota check got an answer; retrying now", output.getvalue())


    def test_unresolved_messages_keep_the_wait_and_use_no_quota_check(self):
        deadline = time.time() + 3600
        self.state["pending"] = {"id": "waiting", "role": "code", "quota_wait": {"retry_at": deadline, "account": "login"}}
        readiness = []
        def answered(model, waiter, wait, ready):
            readiness.append(ready())
            return False  # The probe neither starts a check nor uses an answer while ready() is False.
        with patch("cycle_transport.claude_account", return_value="login"), \
                patch.object(self.cycle.quota_probe, "answered", side_effect=answered), \
                patch.object(self.cycle.messages, "unresolved", return_value=[{"id": "m"}]), \
                patch("cycle_workflow.time", wraps=time) as timer:
            timer.sleep.side_effect = lambda _: None
            self.assertTrue(self.cycle.wait_quota())
        self.assertEqual(readiness, [False])
        self.assertEqual(self.state["pending"]["quota_wait"]["retry_at"], deadline)


class QuotaProbeTests(unittest.TestCase):
    """A periodic minimal Claude request finds a quota reset that keeps the login."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        script = self.folder / "fake_claude.py"
        script.write_text(
            "import json, os, sys\n"
            "folder, mode, argv = sys.argv[1], sys.argv[2], sys.argv[3:]\n"
            "model = argv[argv.index('--model') + 1]\n"
            "record = {'argv': argv, 'cwd': os.getcwd(), 'stdin': sys.stdin.read()}\n"
            "open(os.path.join(folder, model + '.json'), 'w', encoding='utf-8').write(json.dumps(record))\n"
            "if mode == 'answer':\n"
            "    print(json.dumps({'type': 'result', 'subtype': 'success', 'is_error': False, 'result': 'OK'}))\n"
            "elif mode == 'refuse':\n"
            "    print(json.dumps({'type': 'rate_limit_event', 'rate_limit_info': {'status': 'rejected', 'resetsAt': 1}}))\n"
            "    print(json.dumps({'type': 'result', 'subtype': 'success', 'is_error': True, 'api_error_status': 429}))\n"
            "else:\n"
            "    sys.stderr.write('error: unknown option\\n')\n"
            "    sys.exit(2)\n",
            encoding="utf-8")
        self.command = [sys.executable, str(script), str(self.folder)]
        # The checks use a folder of this test, not the folder of the user in the system temp folder.
        checks = self.folder / "checks"
        checks.mkdir()
        folder = patch.object(cycle_transport, "probe_folder", return_value=checks)
        folder.start()
        self.addCleanup(folder.stop)

    def probe(self, mode, period=0):
        probe = QuotaProbe(lambda: self.command + [mode])
        probe.PERIOD = period
        self.addCleanup(probe.close)
        return probe

    def finish(self, probe):
        for entry in list(probe.running.values()):
            entry["thread"].join(30)

    def record(self, model):
        return json.loads((self.folder / (model + ".json")).read_text(encoding="utf-8"))

    def test_the_result_decides_between_an_answer_a_refusal_and_a_failure(self):
        success = json.dumps({"type": "result", "subtype": "success", "is_error": False})
        rejected = json.dumps({"type": "rate_limit_event", "rate_limit_info": {"status": "rejected"}})
        allowed = json.dumps({"type": "rate_limit_event", "rate_limit_info": {"status": "allowed"}})
        limited = json.dumps({"type": "result", "subtype": "success", "is_error": True, "api_error_status": 429})
        failed = json.dumps({"type": "result", "subtype": "error_during_execution", "is_error": True})
        cases = (([success], "answered"), ([allowed, success], "answered"),
                 ([rejected, success], "answered"),  # Extra usage answers after a rejected window, as in a real launch.
                 ([rejected, limited], "refused"), ([limited], "refused"), ([rejected, failed], "refused"),
                 ([failed], "failed"), (["not json", "[]"], "failed"), ([], "failed"))
        for lines, outcome in cases:
            with self.subTest(lines=lines):
                self.assertEqual(probe_outcome(lines), outcome)

    def test_an_answer_retries_each_waiter_once_and_the_check_has_no_tools_settings_or_session(self):
        probe = self.probe("answer", period=10 ** 9)
        self.assertFalse(probe.answered("claude-fable-5-2", "second", 1))  # Two participants wait on one model.
        self.assertFalse(probe.answered("claude-fable-5-2", "first", 1))
        self.assertEqual(probe.running, {})
        probe.PERIOD = 0
        self.assertFalse(probe.answered("claude-fable-5-2", "first", 1))  # This call starts the check.
        self.finish(probe)
        self.assertTrue(probe.answered("claude-fable-5-2", "first", 1))
        self.assertFalse(probe.answered("claude-fable-5-2", "first", 1))  # A waiter uses an answer one time.
        self.assertTrue(probe.answered("claude-fable-5-2", "second", 1))
        self.assertFalse(probe.answered("opus", "first", 2))  # Another model needs its own check.
        self.finish(probe)
        self.assertEqual(probe.last_outcome("opus"), None)  # Not collected yet.
        self.assertTrue(probe.answered("opus", "first", 2))  # The opus wait of the same waiter.
        self.assertEqual(probe.last_outcome("opus"), "answered")
        self.finish(probe)
        value = self.record("opus")
        argv = value["argv"]
        self.assertEqual(argv[argv.index("--model") + 1], "opus")
        for flag in ("--print", "--no-session-persistence", "--strict-mcp-config", "--disable-slash-commands"):
            self.assertIn(flag, argv)
        self.assertEqual(argv[argv.index("--tools") + 1], "")
        self.assertEqual(argv[argv.index("--setting-sources") + 1], "")
        self.assertNotIn("--resume", argv)
        self.assertNotEqual(Path(value["cwd"]).resolve(), fixtures.REPO.resolve())  # An empty folder, not a project.
        self.assertEqual(list(Path(value["cwd"]).iterdir()), [])
        self.assertEqual(self.record("claude-fable-5-2")["cwd"], value["cwd"])  # One fixed folder for every check.
        self.assertEqual(value["stdin"], "Reply with the single word OK.")

    def test_a_refused_check_keeps_the_wait_and_a_failed_check_is_reported_once(self):
        probe = self.probe("refuse")
        self.assertFalse(probe.answered("opus", "waiter", 1))
        self.finish(probe)
        self.assertFalse(probe.answered("opus", "waiter", 1))
        self.assertEqual(probe.last_outcome("opus"), "refused")
        self.finish(probe)
        failing = self.probe("fail")
        with contextlib.redirect_stdout(io.StringIO()) as output:
            for _ in range(3):
                self.assertFalse(failing.answered("opus", "waiter", 1))
                self.finish(failing)
        self.assertEqual(failing.last_outcome("opus"), "failed")
        self.assertEqual(output.getvalue().count("the Claude quota check of opus failed (exit code 2: error: unknown option)"), 1)

    def test_a_check_waits_one_period_of_its_wait_and_early_retries_back_off(self):
        probe, clock = self.probe("answer", period=100), [1000.0]
        with patch("cycle_transport.time.monotonic", side_effect=lambda: clock[0]):
            self.assertFalse(probe.answered("opus", "waiter", "a"))
            self.assertEqual(probe.running, {})  # The refusal is new, so the first check comes after one period.
            clock[0] = 1100
            self.assertFalse(probe.answered("opus", "waiter", "a"))
            self.finish(probe)
            clock[0] = 1101
            self.assertTrue(probe.answered("opus", "waiter", "a"))
            clock[0] = 1102  # The early retry was refused again: a new wait of the same waiter.
            self.assertFalse(probe.answered("opus", "waiter", "b"))
            clock[0] = 1150
            self.assertFalse(probe.answered("opus", "waiter", "b"))
            self.assertEqual(probe.running, {})  # Within one period after the early retry, nothing starts.
            clock[0] = 1250  # The second early retry waits two periods after the first one.
            self.assertFalse(probe.answered("opus", "waiter", "b"))
            self.assertEqual(probe.running, {})
            clock[0] = 1301
            self.assertFalse(probe.answered("opus", "waiter", "b"))  # An answer from before this wait does not count.
            self.assertIn("opus", probe.running)
            self.finish(probe)
            clock[0] = 1302
            self.assertTrue(probe.answered("opus", "waiter", "b"))
            clock[0] = 1303
            self.assertFalse(probe.answered("opus", "waiter", "c"))
            clock[0] = 1700  # The third one waits four periods.
            self.assertFalse(probe.answered("opus", "waiter", "c"))
            self.assertEqual(probe.running, {})
            clock[0] = 1702
            self.assertFalse(probe.answered("opus", "waiter", "c"))
            self.assertIn("opus", probe.running)
            self.finish(probe)

    @unittest.skipIf(os.name == "nt", "POSIX links and owners")
    def test_the_check_folder_is_a_private_folder_of_the_user(self):
        with patch("cycle_transport.tempfile.gettempdir", return_value=str(self.folder)), \
                patch("cycle_transport.getpass.getuser", return_value="tester"):
            own = PROBE_FOLDER  # setUp replaces the module function.
            self.assertEqual(own(), self.folder / "focus-quota-probe-tester")
            self.assertEqual(own().stat().st_mode & 0o777, 0o700)
            (self.folder / "focus-quota-probe-tester").rmdir()
            (self.folder / "elsewhere").mkdir()
            (self.folder / "focus-quota-probe-tester").symlink_to(self.folder / "elsewhere")
            with self.assertRaisesRegex(OSError, "not a private folder"):
                own()

    def test_unresolved_messages_start_no_check_and_keep_an_answer(self):
        probe, ready = self.probe("answer"), [False]
        self.assertFalse(probe.answered("opus", "waiter", 1, lambda: ready[0]))
        self.assertEqual(probe.running, {})  # No check while messages are unresolved.
        ready[0] = True
        self.assertFalse(probe.answered("opus", "waiter", 1, lambda: ready[0]))
        self.finish(probe)
        ready[0] = False
        self.assertFalse(probe.answered("opus", "waiter", 1, lambda: ready[0]))
        ready[0] = True
        self.assertTrue(probe.answered("opus", "waiter", 1, lambda: ready[0]))  # The answer was kept.

    def test_without_a_command_no_check_starts(self):
        for command in (None, lambda: None):
            with self.subTest(command=command):
                probe = QuotaProbe(command)
                probe.PERIOD = 0
                self.assertFalse(probe.answered("opus", "waiter", 1))
                self.assertEqual(probe.running, {})


class ParticipantLoginTests(unittest.TestCase):
    setUp = fixtures.CycleTests.setUp
    tearDown = fixtures.CycleTests.tearDown
    edit = fixtures.CycleTests.edit
    start = pairs.PairTests.start

    def test_a_waiting_reader_retries_at_once_after_a_login_change(self):
        self.start()
        calls = [0]
        def quota(c, h):
            calls[0] += 1
            if calls[0] == 1:
                raise ProviderQuota(time.time() + 86400, no_work=True, account="old-login")
            return report(findings=[])
        self.transport.handlers["pair_sol"] = quota
        accounts = iter(["old-login"] * 3)
        def current():
            return next(accounts, "new-login")  # The operator logs in while the reader waits.
        self.cycle.login_watch.PERIOD = 0
        with patch("cycle_transport.claude_account", side_effect=current), contextlib.redirect_stdout(io.StringIO()) as output:
            self.cycle.paired_review_step()
        roles = [r for r, _ in self.transport.calls]
        self.assertEqual(roles.count("pair_sol"), 2)
        self.assertEqual(roles.count("pair_opus"), 1)
        self.assertIn("the Claude login changed after the quota refusal of pair_sol", output.getvalue())

    def test_a_waiting_reader_retries_at_once_after_an_answered_quota_check(self):
        self.start()
        calls = [0]
        def quota(c, h):
            calls[0] += 1
            if calls[0] == 1:
                raise ProviderQuota(time.time() + 86400, no_work=True, account="same-login")
            return report(findings=[])
        self.transport.handlers["pair_opus"] = quota  # A Claude reader. A Codex wait gets no Claude quota check.
        checks, beats = [], [0]
        def answered(model, waiter, wait, ready):
            checks.append((model, waiter))
            return len(checks) >= 3  # An operator reset the quota while the reader waits.
        normal = self.cycle.heartbeat
        def heartbeat():
            beats[0] += 1
            if beats[0] > 200:
                raise AssertionError("the reader did not retry")  # Fail instead of a wait of one day.
            normal()
        with patch("cycle_transport.claude_account", return_value="same-login"), \
                patch.object(self.cycle.quota_probe, "answered", side_effect=answered), \
                patch.object(self.cycle, "heartbeat", side_effect=heartbeat), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.cycle.paired_review_step()
        roles = [r for r, _ in self.transport.calls]
        self.assertEqual(roles.count("pair_opus"), 2)
        self.assertEqual({model for model, _ in checks}, {PROFILES["pair_opus"][1]})
        self.assertIn("a Claude quota check got an answer; retrying pair_opus now", output.getvalue())


if __name__ == "__main__":
    unittest.main()
