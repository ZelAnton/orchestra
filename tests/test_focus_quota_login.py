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
from cycle_transport import LoginWatch, Transport, claude_account
from focus_status import build_panel

FIXTURE = [sys.executable, str(fixtures.REPO / "tests/test_cycle.py"), "fixture"]
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
                self.assertIn(text, "\n".join(build_panel(self.state).lines))


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


if __name__ == "__main__":
    unittest.main()
