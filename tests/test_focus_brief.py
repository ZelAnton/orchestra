"""Project brief regressions: import, stage capture, delivery, application, and integrity. No provider runs."""

import contextlib
import copy
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import threading
import unittest
from unittest.mock import patch

import test_cycle as fixtures
import test_focus_pairs as pairs
from test_cycle import report
from cycle_prompts import BRIEF_CHANGE_CORRECTION, PROJECT_BRIEF_RULE
from cycle_state import Blocked, LocalLock, Repository, Store, digest
from cycle_workflow import ESCALATION_REASONS, fresh_state
import focus_brief
from focus_control import status
from focus_pair_profile import PAIRS, PAIR_WRITERS
from focus_pair_view import read_record
from focus_progress import Progress

TEXT = "# Purpose\n\nKeep the archive correct for its maintainers.\n"
BOM = "\ufeff"


def context_of(prompt, marker="Runtime context:\n"):
    return json.JSONDecoder().raw_decode(prompt.split(marker, 1)[1])[0]


class BriefFixture:
    setUp = fixtures.CycleTests.setUp
    tearDown = fixtures.CycleTests.tearDown
    edit = fixtures.CycleTests.edit
    remote = fixtures.CycleTests.remote

    def brief_file(self, text=TEXT, name="brief.md"):
        path = Path(self.temp.name) / name
        path.write_bytes(text.encode("utf-8") if isinstance(text, str) else text)
        return path

    def set_brief(self, text=TEXT, name="brief.md", root=None):
        path = self.brief_file(text, name)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(focus_brief.command(root or self.root, "set", path), 0)
        return digest(path.read_bytes())

    def pointer(self, root=None):
        return focus_brief.read_pointer(focus_brief.control_directory(root or self.root))

    def pointer_path(self):
        directory = focus_brief.control_directory(self.root)
        directory.mkdir(parents=True, exist_ok=True)
        return directory / focus_brief.POINTER

    def copy(self, sha):
        return focus_brief.copy_path(focus_brief.control_directory(self.root), sha)

    def start_stage(self):
        """A new stage captures the current default."""
        self.state = fresh_state(self.repo)
        self.cycle.state = self.state
        return self.state["project_brief"]["sha256"]

    def saved(self):
        return self.store.read()

    def stopped(self, **fields):
        self.state.update(fields)
        self.store.save(self.state)

    def main(self, *args, lease_exit=None, lease_enter=None):
        import cc_focus
        err, out = io.StringIO(), io.StringIO()
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.Lease") as lease, \
                patch("cycle_transport.Transport.run", side_effect=AssertionError("No provider in a brief command")), \
                contextlib.redirect_stderr(err), contextlib.redirect_stdout(out):
            lease.return_value.__enter__.return_value.pwsh = "pwsh"
            if lease_enter:
                lease.return_value.__enter__.side_effect = lease_enter
            if lease_exit:
                lease.return_value.__exit__.side_effect = lease_exit
            code = cc_focus.main(list(args))
        self.out = out.getvalue()
        return code, err.getvalue()


class CommandTests(BriefFixture, unittest.TestCase):
    def test_set_stores_exact_bytes_and_points_to_their_hash(self):
        sha = self.set_brief(BOM + TEXT)
        self.assertEqual(self.pointer()["sha256"], sha)
        self.assertEqual(self.copy(sha).read_bytes(), (BOM + TEXT).encode())  # The BOM stays.
        self.assertTrue(Path(self.pointer()["source"]).is_absolute())
        self.assertEqual(focus_brief.read_copy(focus_brief.control_directory(self.root), sha, ""), TEXT)
        self.assertFalse(self.store.path.exists())  # No workflow state is written.

    def test_invalid_inputs_do_not_change_the_pointer(self):
        sha = self.set_brief()
        directory = Path(self.temp.name)
        cases = {"empty": b"", "whitespace": b" \n\t", "bom-only": b"\xef\xbb\xbf", "nul": b"text\0",
                 "utf8": b"\xff\xfe", "oversize": b"a" * (focus_brief.LIMIT + 1),
                 "bom-oversize": b"\xef\xbb\xbf" + b"a" * (focus_brief.LIMIT - 2)}
        for name, data in cases.items():
            with self.subTest(name=name):
                path = directory / (name + ".md")
                path.write_bytes(data)
                with self.assertRaises(Blocked) as raised:
                    focus_brief.command(self.root, "set", path)
                self.assertEqual(raised.exception.code, "brief-file")
                self.assertEqual(self.pointer()["sha256"], sha)
        (directory / "folder").mkdir()
        targets = [directory / "folder", directory / "missing.md"]
        if os.name != "nt":
            link = directory / "link.md"
            link.symlink_to(self.brief_file(name="target.md"))
            os.mkfifo(directory / "fifo.md")
            targets += [link, directory / "fifo.md"]
        for path in targets:
            with self.subTest(path=path.name), self.assertRaises(Blocked):
                focus_brief.command(self.root, "set", path)
        self.assertEqual(self.pointer()["sha256"], sha)

    def test_exact_limit_is_accepted(self):
        sha = self.set_brief(b"\xef\xbb\xbf" + b"a" * (focus_brief.LIMIT - 3))
        self.assertEqual(len(self.copy(sha).read_bytes()), focus_brief.LIMIT)

    def test_windows_read_path_and_identity_check(self):
        path = self.brief_file()
        flags = []

        class WindowsOs:
            O_BINARY = 0x40000000  # A stub value. No POSIX open flag uses this bit.
            def __getattr__(self, name):
                if name in ("O_NOFOLLOW", "O_NONBLOCK"):
                    raise AttributeError(name)
                return getattr(os, name)
            def open(self, target, mode):
                flags.append(mode)
                return os.open(target, mode & ~self.O_BINARY)
        with patch("focus_brief.os", WindowsOs()):
            self.assertEqual(focus_brief.read_bounded(path, focus_brief.LIMIT), TEXT.encode())
        self.assertEqual(flags, [os.O_RDONLY | WindowsOs.O_BINARY])  # No POSIX flag on Windows.
        real = os.lstat(path)

        class Reparse:
            st_mode, st_dev, st_ino = real.st_mode, real.st_dev, real.st_ino
            st_file_attributes = stat.FILE_ATTRIBUTE_REPARSE_POINT
        with patch("focus_brief.os.lstat", return_value=Reparse()), self.assertRaisesRegex(ValueError, "reparse"):
            focus_brief.read_bounded(path, focus_brief.LIMIT)
        moved = os.stat_result((real.st_mode, real.st_ino + 1, *tuple(real)[2:]))
        with patch("focus_brief.os.fstat", return_value=moved), self.assertRaisesRegex(ValueError, "changed"):
            focus_brief.read_bounded(path, focus_brief.LIMIT)
        special = os.stat_result((stat.S_IFIFO | 0o600, *tuple(real)[1:]))  # Same identity, not a regular file.
        with patch("focus_brief.os.fstat", return_value=special), self.assertRaisesRegex(ValueError, "changed"):
            focus_brief.read_bounded(path, focus_brief.LIMIT)
        if os.name != "nt":
            opened = []
            original = os.open
            with patch("focus_brief.os.open", side_effect=lambda p, m: opened.append(m) or original(p, m)):
                focus_brief.read_bounded(path, focus_brief.LIMIT)
            self.assertTrue(opened[0] & os.O_NOFOLLOW and opened[0] & os.O_NONBLOCK)

    def test_growing_file_is_refused_by_the_bounded_read(self):
        path = self.brief_file("a" * 10)
        original = os.read

        def grow(descriptor, size):
            return original(descriptor, size) or b"b" * size
        with patch("focus_brief.os.read", side_effect=grow), self.assertRaisesRegex(ValueError, "larger"):
            focus_brief.read_bounded(path, 16)

    def test_set_replaces_a_corrupt_copy_and_restore_keeps_the_pointer(self):
        first = self.set_brief()
        self.copy(first).write_text("damaged")
        self.set_brief()
        self.assertEqual(digest(self.copy(first).read_bytes()), first)
        second = self.set_brief("Second brief.\n", "second.md")
        self.copy(first).write_text("damaged again")
        state = fresh_state(self.repo)
        state["project_brief"] = {"iteration": 1, "sha256": first}
        self.store.save(state)
        with contextlib.redirect_stdout(io.StringIO()):
            focus_brief.command(self.root, "restore", self.brief_file())
        self.assertEqual(digest(self.copy(first).read_bytes()), first)
        self.assertEqual(self.pointer()["sha256"], second)  # The pending default stays.
        with self.assertRaisesRegex(Blocked, "No pointer or stage record"):
            focus_brief.command(self.root, "restore", self.brief_file("Unknown brief.\n", "unknown.md"))

    def test_restore_skips_a_malformed_pointer_with_a_notice(self):
        self.set_brief()
        stage = self.start_stage()
        self.store.save(self.state)
        self.copy(stage).unlink()
        self.pointer_path().write_text("{")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            focus_brief.command(self.root, "restore", self.brief_file())
        self.assertIn("skipped the pointer", out.getvalue())
        self.assertEqual(digest(self.copy(stage).read_bytes()), stage)

    def test_clear_and_set_recover_a_malformed_pointer(self):
        path = self.pointer_path()
        path.write_text('{"schema": "x"}')
        with self.assertRaises(Blocked):
            focus_brief.capture(self.root, "")
        with contextlib.redirect_stdout(io.StringIO()):
            focus_brief.command(self.root, "clear")
        self.assertIsNone(self.pointer()["sha256"])
        path.write_text("not json")
        sha = self.set_brief()
        self.assertEqual(self.pointer()["sha256"], sha)

    def test_pointer_schema(self):
        sha = self.set_brief()
        path = self.pointer_path()
        good = json.loads(path.read_text())
        cases = {"unknown": dict(good, extra=1), "half-null": dict(good, source=None),
                 "reverse-half-null": dict(good, sha256=None), "number-hash": dict(good, sha256=7),
                 "bool-time": dict(good, updated=True), "negative": dict(good, updated=-1),
                 "hash": dict(good, sha256=sha.upper()), "relative": dict(good, source="brief.md"),
                 "schema": dict(good, schema="other")}
        for name, value in cases.items():
            with self.subTest(name=name):
                path.write_text(json.dumps(value))
                with self.assertRaises(Blocked) as raised:
                    focus_brief.capture(self.root, "")
                self.assertEqual(raised.exception.code, "brief-drift")
        texts = {"duplicate": json.dumps(good)[:-1] + ', "schema": "%s"}' % focus_brief.SCHEMA,
                 "infinite": json.dumps(good).replace(str(good["updated"]), "Infinity"),
                 "huge-integer": json.dumps(good).replace(str(good["updated"]), "9" * 400),
                 "oversize": json.dumps(dict(good)) + " " * focus_brief.POINTER_LIMIT}
        for name, text in texts.items():
            with self.subTest(name=name):
                path.write_text(text)
                with self.assertRaises(Blocked) as raised:
                    focus_brief.capture(self.root, "")
                self.assertEqual(raised.exception.code, "brief-drift")
                self.assertIn("pointer_error", focus_brief.status_entry(self.root, None))

    def test_a_device_prefix_of_a_resolved_path_is_not_an_escape(self):
        # Windows can keep the \\?\ prefix when another command creates the copies directory at the same time.
        self.assertEqual(focus_brief.plain("\\\\?\\C:\\cycle\\briefs"), "C:\\cycle\\briefs")
        self.assertEqual(focus_brief.plain("\\\\?\\UNC\\server\\share"), "\\\\server\\share")
        self.assertEqual(focus_brief.plain("/srv/cycle/briefs"), "/srv/cycle/briefs")
        original = Path.resolve
        def prefixed(path, *args, **kwargs):
            value = original(path, *args, **kwargs)
            return Path("\\\\?\\" + str(value)) if value.name == focus_brief.COPIES else value
        with patch.object(Path, "resolve", prefixed):
            self.assertEqual(focus_brief.control_directory(self.root), Store(self.root).control_directory)

    def test_concurrent_set_and_clear_leave_one_complete_pointer(self):
        paths = [self.brief_file(f"Brief {n}.\n", f"b{n}.md") for n in range(4)]
        errors = []

        def work(index):
            try:
                for _ in range(10):
                    if index % 2:
                        focus_brief.command(self.root, "clear")
                    else:
                        focus_brief.command(self.root, "set", paths[index])
            except BaseException as error:  # A thread failure must fail the test.
                errors.append(error)
        with contextlib.redirect_stdout(io.StringIO()):
            threads = [threading.Thread(target=work, args=(n,)) for n in range(4)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join()
        self.assertEqual(errors, [])
        sha = focus_brief.capture(self.root, "")
        self.assertIn(sha, (None, *(digest(p.read_bytes()) for p in paths)))

    def test_a_crash_between_copy_and_pointer_keeps_the_earlier_default(self):
        first = self.set_brief()
        original = focus_brief.atomic_write

        def crash(path, data):
            if Path(path).name == focus_brief.POINTER:
                raise OSError("simulated crash")
            return original(path, data)
        path = self.brief_file("New brief.\n", "new.md")
        with patch("focus_brief.atomic_write", side_effect=crash), self.assertRaises(OSError):
            focus_brief.command(self.root, "set", path)
        self.assertEqual(focus_brief.capture(self.root, ""), first)
        self.assertTrue(self.copy(digest(path.read_bytes())).exists())

    @unittest.skipIf(os.name == "nt", "POSIX symbolic link fixture")
    def test_redirected_runtime_paths_are_refused_without_external_writes(self):
        external = Path(self.temp.name) / "external"
        external.mkdir()
        directory = self.pointer_path().parent
        (directory / focus_brief.COPIES).symlink_to(external, target_is_directory=True)
        with self.assertRaises(Blocked):
            focus_brief.command(self.root, "set", self.brief_file())
        self.assertEqual(list(external.iterdir()), [])
        (directory / focus_brief.COPIES).unlink()
        (directory / focus_brief.POINTER).symlink_to(external / "pointer.json")
        with self.assertRaises(Blocked):
            focus_brief.command(self.root, "clear")
        self.assertEqual(list(external.iterdir()), [])

    @unittest.skipIf(os.name == "nt", "POSIX symbolic link fixture")
    def test_a_symbolic_link_copy_is_brief_drift(self):
        sha = self.set_brief()
        target = self.brief_file(name="outside.md")
        self.copy(sha).unlink()
        self.copy(sha).symlink_to(target)
        with self.assertRaises(Blocked) as raised:
            focus_brief.capture(self.root, "")
        self.assertEqual(raised.exception.code, "brief-drift")

    def test_root_checks(self):
        sub = self.root / "sub"
        sub.mkdir()
        with self.assertRaisesRegex(Blocked, "root"):
            focus_brief.command(sub, "show")
        worktree = Path(self.temp.name) / "linked"
        self.repo.git("worktree", "add", "-b", "side", str(worktree))
        with self.assertRaisesRegex(Blocked, "linked worktree"):
            focus_brief.command(worktree, "show")
        self.repo.git("checkout", "-b", "feature")  # A branch other than main is accepted.
        (self.root / ".git" / "MERGE_HEAD").write_text(self.repo.text("rev-parse", "HEAD") + "\n")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(focus_brief.command(self.root, "show"), 0)

    def test_project_root_holds_the_pointer_and_a_project_subdirectory_is_refused(self):
        project = Path(self.temp.name) / "project"
        member = project / "core"
        member.mkdir(parents=True)
        Repository(member).git("init", "--initial-branch=main")
        (project / "notes").mkdir()
        sha = self.set_brief(root=project)
        self.assertEqual(self.pointer(project)["sha256"], sha)
        self.assertTrue((project / ".work/cycle/briefs" / (sha + ".md")).is_file())
        self.assertFalse((member / ".work").exists())
        with self.assertRaisesRegex(Blocked, "root"):
            focus_brief.command(project / "notes", "show")

    def test_member_of_a_running_project_is_refused(self):
        parent = self.root.parent
        Store(self.root).directory.mkdir(parents=True)
        (Store(self.root).directory / "project-owner.json").write_text(json.dumps({"root": str(parent), "nonce": "x"}))
        with patch("focus_project.runtime_active", return_value=True), self.assertRaisesRegex(Blocked, "running project"):
            focus_brief.command(self.root, "set", self.brief_file())
        with patch("focus_project.runtime_active", return_value=False), contextlib.redirect_stdout(io.StringIO()):
            focus_brief.command(self.root, "set", self.brief_file())  # A standalone member run is legitimate.

    def test_commands_work_while_a_run_holds_the_lock_and_apply_is_refused(self):
        self.stopped()
        with LocalLock(Store(self.root).directory):
            code, err = self.main("brief", "set", str(self.brief_file()))
            self.assertEqual(code, 0, err)
            self.assertEqual(self.main("brief", "show")[0], 0)
            self.assertEqual(self.main("brief", "restore", str(self.brief_file()))[0], 0)
            self.assertEqual(self.main("brief", "clear")[0], 0)
            code, err = self.main("brief", "apply")
            self.assertEqual(code, 3)
            self.assertIn("runtime.lock", err)

    def test_show_reports_records_source_and_escapes_text(self):
        # Windows refuses control characters in file names, so only POSIX checks the escaped name.
        source = self.brief_file(name="brief.md" if os.name == "nt" else "brief\x1b[31m.md")
        with contextlib.redirect_stdout(io.StringIO()):
            focus_brief.command(self.root, "set", source)
        self.start_stage()
        self.store.save(self.state)
        shown = focus_brief.show(self.root)
        self.assertNotIn("\x1b", json.dumps(shown, ensure_ascii=False))
        self.assertEqual(shown["source"], "unchanged")
        self.assertEqual(shown["records"]["development"]["stage"], self.pointer()["sha256"])
        source.write_text("edited")
        self.assertEqual(focus_brief.show(self.root)["source"], "changed since the import")
        source.unlink()
        self.assertIn("not readable", focus_brief.show(self.root)["source"])
        missing = focus_brief.show(self.root, "0" * 32)
        self.assertIn("error", missing["records"]["campaign " + "0" * 32])
        self.assertEqual(missing["pointer"]["sha256"], self.pointer()["sha256"])
        self.store.path.write_text("damaged")
        damaged = focus_brief.show(self.root)
        self.assertIn("error", damaged["records"]["development"])
        self.assertEqual(damaged["pointer"]["sha256"], self.pointer()["sha256"])

    def test_status_never_reads_the_source_and_reports_errors(self):
        sha = self.set_brief()
        entry = focus_brief.status_entry(self.root, None)
        self.assertEqual((entry["default"], entry["stage"]), (sha, None))
        self.assertIn("No stage", entry["note"])
        self.state["project_brief"] = {"iteration": 1, "sha256": None}
        self.assertEqual(focus_brief.status_entry(self.root, self.state)["pending"], "takes effect at the next stage")
        with patch("focus_brief.read_bounded", wraps=focus_brief.read_bounded) as reads:
            focus_brief.status_entry(self.root, self.state)
        self.assertNotIn(str(self.brief_file()), [str(c.args[0]) for c in reads.call_args_list])
        self.pointer_path().write_text("{")
        self.assertIn("pointer_error", focus_brief.status_entry(self.root, self.state))
        code, _ = self.main("status")
        self.assertEqual(code, 0)
        self.assertIn("pointer_error", json.loads(self.out)["project_brief"])

    def test_status_and_progress_export_no_brief_text(self):
        self.set_brief()
        self.start_stage()
        self.cycle.progress = Progress(self.store, self.state, "run")
        self.transport.actions = [("code", report())]
        self.cycle.invoke("code")
        self.assertNotIn("archive correct", json.dumps(status(self.store, self.state), ensure_ascii=False))
        self.assertNotIn("archive correct", (self.store.directory / "progress.json").read_text())

    def test_parser_rules(self):
        import cc_focus
        for args in (["brief"], ["brief", "set"], ["brief", "clear", "x"], ["brief", "show", "--retry"],
                     ["brief", "set", "f", "--review-run", "0" * 32], ["status", "extra"], ["brief", "unknown"]):
            with self.subTest(args=args), patch("cc_focus.Path.cwd", return_value=self.root), \
                    contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                cc_focus.main(args)
        self.assertEqual(self.main("brief", "show", "--review-run", "0" * 32)[0], 0)
        self.assertIn("does not exist", self.main("brief", "apply", "--review-run", "0" * 32)[1])  # Parsed, no such run.

    def test_cc_config_does_not_seed_the_template(self):
        # A seeded placeholder would become a valid brief.
        self.assertTrue((fixtures.REPO / "project-brief.example.md").is_file())
        for name in ("launchers/cc-config.sh", "launchers/cc-config.cmd", "tools/config-runtime.ps1", "tools/sync-runtime.ps1"):
            self.assertNotIn("project-brief", (fixtures.REPO / name).read_text(encoding="utf-8"), name)

    def test_the_checker_scans_both_provider_texts(self):
        from check_focus_instructions import prose
        texts = {text for _, text in prose(fixtures.REPO)}
        self.assertIn(PROJECT_BRIEF_RULE.strip(), texts)
        self.assertIn(BRIEF_CHANGE_CORRECTION.strip(), texts)

    def test_launcher_runs_brief_commands_directly_and_apply_needs_the_root_process(self):
        config = Path(self.temp.name) / "isolated-config"
        config.mkdir()
        (config / "root-config.md").write_text("CC_PROCESSKIT_CLI: off\n")
        env = dict(os.environ, ORCHESTRA_HOME=str(config))
        self.stopped()

        def launch(*args):
            return subprocess.run(["pwsh", "-NoProfile", "-File", str(fixtures.REPO / "tools/focus-runtime.ps1"), *args],
                                  cwd=self.root, env=env, capture_output=True, timeout=60)
        for args in (["brief", "set", str(self.brief_file())], ["brief", "restore", str(self.brief_file())],
                     ["brief", "show"]):
            result = launch(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
        result = launch("brief", "apply")  # A state change needs the contained root process.
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"processkit", result.stderr.lower())
        self.assertIsNone(self.saved()["project_brief"]["sha256"])
        self.assertEqual(launch("brief", "clear").returncode, 0)
        self.assertIsNone(self.pointer()["sha256"])


class StageTests(BriefFixture, unittest.TestCase):
    def test_each_stage_captures_the_default_and_later_changes_wait(self):
        sha = self.set_brief()
        self.assertEqual(self.start_stage(), sha)
        second = self.set_brief("Second brief.\n", "second.md")
        self.assertEqual(focus_brief.stage_hash(self.state), sha)  # The stage keeps its brief.
        self.cycle.advance_stage(self.repo.snapshot(), [], {})
        self.assertEqual(self.state["project_brief"], {"iteration": 2, "sha256": second})

    def test_a_failed_read_at_a_stage_start_leaves_the_stage_intact(self):
        sha = self.set_brief()
        self.start_stage()
        self.state["sessions"] = {"code": "session"}
        before = copy.deepcopy(self.state)
        self.copy(sha).write_text("damaged")
        with self.assertRaises(Blocked) as raised:
            self.cycle.advance_stage(self.repo.snapshot(), [], {})
        self.assertEqual(raised.exception.code, "brief-drift")
        self.assertIn("cc-focus --retry", str(raised.exception))
        self.assertEqual(self.state, before)
        with self.assertRaisesRegex(Blocked, "the same cc-focus command"):
            fresh_state(self.repo)

    def test_a_legacy_state_gets_no_brief_and_the_next_stage_captures_it(self):
        sha = self.set_brief()
        self.state.pop("project_brief")
        self.assertIsNone(focus_brief.stage_hash(self.state))
        self.assertNotIn("project_brief", context_of(self.cycle.context("code")))
        self.assertNotIn("project_brief", self.state)  # No record is written for the old stage.
        self.cycle.advance_stage(self.repo.snapshot(), [], {})
        self.assertEqual(self.state["project_brief"], {"iteration": 2, "sha256": sha})

    def test_damaged_records_stop_with_the_apply_remedy(self):
        for record in ({"iteration": 2, "sha256": None}, {"iteration": True, "sha256": None},
                       {"iteration": 1, "sha256": "x"}, {"iteration": 1}):
            with self.subTest(record=record):
                self.state["project_brief"] = record
                with self.assertRaises(Blocked) as raised:
                    self.cycle.context("code")
                self.assertEqual(raised.exception.code, "brief-drift")
                self.assertIn("cc-focus brief apply", str(raised.exception))

    def test_a_damaged_record_stops_before_the_code_intent(self):
        self.state["project_brief"] = {"iteration": 4, "sha256": None}
        with self.assertRaises(Blocked):
            self.cycle.invoke("code")
        self.assertFalse(self.state["code_started"])
        self.assertIsNone(self.state["pending"])

    def test_cancel_a_pending_change(self):
        self.set_brief()
        self.start_stage()
        self.set_brief("Second brief.\n", "second.md")
        self.assertIn("pending", focus_brief.status_entry(self.root, self.state))
        self.set_brief()
        self.assertNotIn("pending", focus_brief.status_entry(self.root, self.state))
        self.state["project_brief"]["sha256"] = None
        with contextlib.redirect_stdout(io.StringIO()):
            focus_brief.command(self.root, "clear")
        self.assertNotIn("pending", focus_brief.status_entry(self.root, self.state))

    def test_only_the_code_role_gets_the_brief_in_the_main_context(self):
        sha = self.set_brief()
        self.start_stage()
        field = context_of(self.cycle.context("code"))["project_brief"]
        self.assertEqual(field, {"sha256": sha, "text": TEXT, "rule": PROJECT_BRIEF_RULE})
        for role in ("coordinate", "heal", "publish"):
            if role == "heal":
                self.state["blocker"] = {"code": "x", "message": "y"}
            if role == "publish":
                self.state.update(remote="origin", reviewed=self.repo.snapshot())
            with self.subTest(role=role):
                self.assertNotIn("project_brief", context_of(self.cycle.context(role)))
        self.copy(sha).unlink()
        self.cycle.context("publish")  # A drifted copy does not stop publication.
        with self.assertRaises(Blocked) as raised:
            self.cycle.context("code")
        self.assertIn("cc-focus brief restore", str(raised.exception))

    def test_no_brief_adds_no_field(self):
        self.assertIsNone(self.state["project_brief"]["sha256"])
        context = context_of(self.cycle.context("code"))
        self.assertNotIn("project_brief", context)
        self.assertNotIn("project_brief_notice", context)

    def test_brief_errors_start_no_healer_and_print_their_reason(self):
        for code in ("brief-drift", "brief-path"):
            with self.subTest(code=code):
                self.state.update(blocker=None, healed=[])
                self.cycle.handle_block(Blocked(code, "Project brief: the copy is missing."))
                self.assertEqual((self.state["blocker"]["status"], self.state["blocker"]["escalation_reason"]),
                                 ("blocked", "brief-input"))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(self.cycle.run(), 3)
        self.assertIn(ESCALATION_REASONS["brief-input"], out.getvalue())
        self.assertNotIn(ESCALATION_REASONS["manual-action"], out.getvalue())

    def test_code_intent_records_the_selected_hash(self):
        sha = self.set_brief()
        self.start_stage()
        self.transport.actions = [("code", report())]
        self.cycle.invoke("code")
        self.assertEqual(self.state["pending"]["project_brief_sha256"], sha)
        intent = json.loads((self.store.directory / "invocations" / self.state["pending"]["id"] / "intent.json").read_text())
        self.assertEqual(intent["project_brief_sha256"], sha)
        self.assertEqual(context_of(self.transport.calls[0][1])["project_brief"]["text"], TEXT)


class ApplyTests(BriefFixture, unittest.TestCase):
    def test_refusals(self):
        self.set_brief()
        cases = [({"status": "complete"}, "complete"), ({"phase": "ci"}, "Publication"),
                 ({"phase": "publish"}, "Publication"), ({"publication_started": True}, "Publication")]
        for fields, text in cases:
            with self.subTest(fields=fields):
                self.state = fresh_state(self.repo)
                self.cycle.state = self.state
                self.stopped(**fields)
                code, err = self.main("brief", "apply")
                self.assertEqual(code, 3)
                self.assertIn(text, err)
                self.assertEqual(self.saved(), self.state)
        self.state = fresh_state(self.repo)
        self.stopped()
        before = self.store.path.read_bytes()
        with patch("focus_messages.Messages.unresolved", return_value=[{}]):
            code, err = self.main("brief", "apply")
        self.assertEqual(code, 3)
        self.assertIn("messages", err)
        self.assertEqual(self.store.path.read_bytes(), before)
        self.store.path.unlink()
        code, err = self.main("brief", "apply")
        self.assertIn("next stage start captures the pointer", err)

    def test_the_checks_run_in_the_planned_order(self):
        self.set_brief()
        self.pointer_path().write_text("{")
        self.stopped(status="complete")
        self.assertIn("complete", self.main("brief", "apply")[1])  # A saved-state refusal precedes the pointer.
        self.stopped(status="ready", blocker={"code": "claude-refusal", "message": "refused", "status": "blocked",
                                               "signature": "s", "phase": "code"})
        with patch("focus_diagnostics.selected_refusals", return_value=[{"session": "x"}]):
            self.assertIn("refused", self.main("brief", "apply")[1])  # The refusal check precedes the pointer.
        self.stopped(blocker=None)
        self.assertIn("pointer", self.main("brief", "apply")[1])
        with contextlib.redirect_stdout(io.StringIO()):
            focus_brief.command(self.root, "clear")
        (self.root / "source.txt").write_text("committed later\n")
        self.repo.git("commit", "-am", "Later commit")
        code, err = self.main("brief", "apply")  # The equal-hash exit precedes the live HEAD check.
        self.assertEqual(code, 0, err)
        self.assertIn("already uses", self.out)

    def test_live_refusals_after_the_lease_change_nothing(self):
        self.set_brief()
        self.stopped()
        before = self.saved()
        (self.root / "source.txt").write_text("committed later\n")
        self.repo.git("commit", "-am", "Later commit")
        code, err = self.main("brief", "apply")
        self.assertEqual(code, 3)
        self.assertIn("HEAD changed", err)
        self.assertNotIn("saved state", err)  # No save started, so no commit report.
        strip = lambda state: {k: v for k, v in state.items() if k != "updated"}
        self.assertEqual(strip(self.saved()), strip(before))
        self.repo.git("reset", "--hard", "HEAD~1")
        (self.root / ".work" / "PAUSE").write_text("")
        code, err = self.main("brief", "apply")
        self.assertIn("pause", err.lower())
        self.assertEqual(strip(self.saved()), strip(before))

    def test_equal_hash_changes_nothing_and_exits_zero(self):
        self.set_brief()
        self.start_stage()
        self.stopped()
        before = self.store.path.read_bytes()
        code, _ = self.main("brief", "apply")
        self.assertEqual(code, 0)
        self.assertIn("already uses", self.out)
        self.assertEqual(self.store.path.read_bytes(), before)

    def test_direct_update_before_any_work_keeps_blocker_and_pending_coordinator(self):
        self.stopped(blocker={"code": "x", "message": "y", "status": "blocked", "signature": "s", "phase": "code"},
                     pending={"id": "c" * 32, "role": "coordinate", "iteration": 1})
        sha = self.set_brief()
        code, err = self.main("brief", "apply")
        self.assertEqual(code, 0, err)
        saved = self.saved()
        self.assertEqual(saved["project_brief"], {"iteration": 1, "sha256": sha})
        self.assertEqual(saved["blocker"]["code"], "x")
        self.assertEqual(saved["pending"]["role"], "coordinate")
        self.assertEqual(saved.get("corrections", []), [])
        self.assertIn("direct update", self.out)
        self.assertIn("cc-focus --retry", self.out)  # The retry command follows.

    def test_pending_coordinator_or_healer_permit_and_other_work_prevents_the_direct_update(self):
        allowed = {"pending coordinator": {"pending": {"id": "c" * 32, "role": "coordinate", "iteration": 1}},
                   "pending healer": {"pending": {"id": "h" * 32, "role": "heal", "iteration": 1}},
                   "kept coordinator session": {"sessions": {"coordinate": "kept"}}}
        refused = {"code started": {"code_started": True},
                   "kept code session": {"sessions": {"code": "kept"}},
                   "writer session": {"sessions": {"repair_execute": "kept"}},
                   "completed pair": {"pair_completed": {"pair_a": "ref"}, "phase": "pair_b"},
                   "pair handoff": {"pair_handoff": ["ref"]},
                   "final review": {"final_review": {"round": 1}},
                   "pending reader": {"pending": {"id": "r" * 32, "role": "pair_group", "iteration": 1}},
                   "pending writer": {"pending": {"id": "w" * 32, "role": "pair_fix", "iteration": 1}},
                   "damaged record": {"project_brief": {"iteration": 9, "sha256": None}}}
        for cases, expected in ((allowed, True), (refused, False)):
            for name, fields in cases.items():
                with self.subTest(name=name):
                    self.state = fresh_state(self.repo)
                    self.cycle.state = self.state
                    self.state.update(fields)
                    self.assertEqual(self.cycle.brief_unused(), expected)

    def test_correction_keeps_an_earlier_pending_correction_and_sets_no_publication_recovery(self):
        self.stopped(code_started=True)
        self.cycle.correct("Add an edge case.")
        earlier = self.state["correction_pending"]
        self.assertTrue(earlier)
        self.state["coordinated"] = "code"
        self.store.save(self.state)
        sha = self.set_brief()
        code, err = self.main("brief", "apply")
        self.assertEqual(code, 0, err)
        saved = self.saved()
        entry = saved["corrections"][-1]
        self.assertTrue(entry["brief_change"])
        self.assertNotIn("publication_recovery", entry)
        self.assertEqual(Path(entry["path"]).read_text(), BRIEF_CHANGE_CORRECTION)
        self.assertEqual(saved["correction_pending"], earlier)
        self.assertEqual(saved["project_brief"], {"iteration": 1, "sha256": sha})
        self.assertEqual((saved["phase"], saved["status"]), ("code", "paused"))
        self.assertIsNone(saved["coordinated"])
        archive = json.loads(Path(entry["archive"]).read_text())
        self.assertEqual(archive["brief_change"]["sha256"], sha)
        self.assertIn("by correction", self.out)

    def test_correction_before_coding_clears_the_task_and_a_pair_phase_resumes_at_pair_a(self):
        self.stopped(sessions={"code": "kept"}, task={"id": "S1", "title": "Provisional", "plan": "p", "iteration": 1},
                     coordinated="code")
        self.cycle.apply_brief(self.set_brief())
        self.assertIsNone(self.state["task"])
        self.assertTrue(self.state["corrections"][-1]["before_code"])
        self.state = fresh_state(self.repo)
        self.cycle.state = self.state
        self.state.update(code_started=True, phase="pair_b", pair_completed={"pair_a": "ref"},
                          pair_clean={"pair_a": 1, "pair_b": 0})
        self.cycle.apply_brief(None)
        self.assertEqual((self.state["phase"], self.state["pair_completed"], self.state["pair_clean"]),
                         ("pair_a", {}, {"pair_a": 0, "pair_b": 0}))
        self.assertIsNone(self.state["pair_review"])

    def test_brief_entries_are_a_notice_not_a_task_correction(self):
        self.stopped(code_started=True)
        sha = self.set_brief()
        self.cycle.apply_brief(sha)
        self.assertIsNone(self.state["correction_pending"])  # A brief change alone adds no complete block.
        context = context_of(self.cycle.context("code"))
        self.assertEqual(context["project_brief_notice"], BRIEF_CHANGE_CORRECTION)
        for key in ("operator_corrections", "correction_instructions", "correction_pending", "publication_recovery"):
            self.assertNotIn(key, context)
        self.assertEqual(context["project_brief"]["sha256"], sha)
        self.cycle.correct("A task correction.")
        self.cycle.apply_brief(None)  # A brief entry after a task correction.
        context = context_of(self.cycle.context("code"))
        self.assertEqual(len(context["operator_corrections"]), 1)
        self.assertNotIn("brief_change", context["operator_corrections"][0])
        self.assertIn("SAME project stage", context["correction_instructions"])
        self.assertIsNotNone(context["correction_pending"])

    def test_a_complete_report_is_accepted_after_a_brief_change_alone(self):
        self.stopped(code_started=True)
        self.cycle.apply_brief(self.set_brief())
        self.state["coordinated"] = "code"
        self.transport.actions = [("code", report(status="complete"))]
        self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(self.state["status"], "complete")

    def test_a_restart_after_a_brief_change_alone_gets_no_same_stage_text(self):
        self.stopped(code_started=True)
        sha = self.set_brief()
        self.cycle.apply_brief(sha)
        self.state.update(status="complete", coordinated="code")
        self.store.save(self.state)
        handoff = self.brief_file("Handoff text.\n", "handoff.md")
        with patch("cc_focus.Cycle.run", return_value=0):
            self.assertEqual(self.main("--handoff", str(handoff), "--ui", "off")[0], 0)
        self.state = self.saved()
        self.cycle.state = self.state
        context = context_of(self.cycle.context("coordinate"))
        self.assertNotIn("correction_instructions", context)
        self.assertEqual(context["project_brief_notice"], BRIEF_CHANGE_CORRECTION)

    def test_damaged_record_is_replaced_through_correction_without_its_old_text(self):
        sha = self.set_brief()
        self.stopped(project_brief={"iteration": 7, "sha256": sha})
        with patch("focus_brief.read_copy", wraps=focus_brief.read_copy) as reads:
            code, err = self.main("brief", "apply")
        self.assertEqual(code, 0, err)
        self.assertEqual([c.args[1] for c in reads.call_args_list], [sha])  # Only the new pointer copy.
        saved = self.saved()
        self.assertEqual(saved["project_brief"], {"iteration": 1, "sha256": sha})
        archive = json.loads(Path(saved["corrections"][-1]["archive"]).read_text())
        self.assertEqual(archive["previous_state"]["project_brief"]["iteration"], 7)

    def test_a_failed_save_is_reported_and_never_overwritten(self):
        self.stopped(code_started=True)
        self.set_brief()
        before = self.saved()
        with patch("cycle_workflow.Cycle.save", side_effect=OSError("disk full")):
            code, err = self.main("brief", "apply")
        self.assertEqual(code, 3)
        self.assertIn("does not contain the applied brief", err)
        # Only the admission save of the lease protocol can change the timestamp.
        strip = lambda state: {k: v for k, v in state.items() if k != "updated"}
        self.assertEqual(strip(self.saved()), strip(before))

    def test_failures_after_the_atomic_replacement_keep_the_committed_change(self):
        for name, fields in (("direct update", {}), ("correction", {"code_started": True})):
            with self.subTest(name=name):
                self.state = fresh_state(self.repo)
                self.cycle.state = self.state
                self.stopped(**fields)
                sha = self.set_brief(f"Brief for {name}.\n", name + ".md")
                real = Store.save

                def save_then_fail(cycle):
                    real(cycle.store, cycle.state)
                    raise OSError("directory synchronization failed")
                with patch("cycle_workflow.Cycle.save", save_then_fail):
                    code, err = self.main("brief", "apply")
                self.assertEqual(code, 3)
                self.assertIn("contains the applied brief", err)
                saved = self.saved()
                self.assertEqual(saved["project_brief"], {"iteration": 1, "sha256": sha})
                if fields:
                    self.assertTrue(Path(saved["corrections"][-1]["archive"]).is_file())

    def test_a_lease_release_failure_after_acceptance_keeps_and_reports_the_record(self):
        for name, fields in (("direct update", {}), ("correction", {"code_started": True})):
            with self.subTest(name=name):
                self.state = fresh_state(self.repo)
                self.cycle.state = self.state
                self.stopped(**fields)
                sha = self.set_brief(f"Release {name}.\n", name + "-release.md")
                code, err = self.main("brief", "apply", lease_exit=Blocked("lease-release", "release failed"))
                self.assertEqual(code, 3)
                self.assertIn("contains the applied brief", err)
                self.assertEqual(self.saved()["project_brief"], {"iteration": 1, "sha256": sha})

    def test_an_interrupt_after_acceptance_reports_the_record(self):
        self.stopped()
        sha = self.set_brief()
        code, err = self.main("brief", "apply", lease_exit=KeyboardInterrupt())
        self.assertEqual(code, 130)
        self.assertIn("contains the applied brief", err)
        self.assertEqual(self.saved()["project_brief"]["sha256"], sha)
        self.assertEqual(self.saved()["status"], "ready")

    def test_lease_failure_changes_no_workflow_status(self):
        self.stopped()
        self.set_brief()
        code, err = self.main("brief", "apply", lease_enter=Blocked("lease-unavailable", "held"))
        self.assertEqual(code, 3)
        self.assertEqual(self.saved()["status"], "ready")
        self.assertIsNone(self.saved()["project_brief"]["sha256"])
        self.assertNotIn("saved state", err)

    def test_a_pointer_change_during_apply_keeps_the_captured_hash(self):
        self.stopped()
        first = self.set_brief()
        later = self.brief_file("A later default.\n", "later.md")

        def enter():
            with contextlib.redirect_stdout(io.StringIO()):
                focus_brief.command(self.root, "set", later)
            return type("LeaseValue", (), {"pwsh": "pwsh", "heartbeat": lambda self: None})()
        code, err = self.main("brief", "apply", lease_enter=enter)
        self.assertEqual(code, 0, err)
        self.assertEqual(self.saved()["project_brief"]["sha256"], first)
        self.assertEqual(self.pointer()["sha256"], digest(later.read_bytes()))  # Pending for the next stage.

    def test_a_refusal_blocker_names_the_session_command_and_apply(self):
        self.stopped(blocker={"code": "claude-refusal", "message": "refused", "status": "blocked", "signature": "s", "phase": "code"})
        self.set_brief()
        with patch("focus_diagnostics.selected_refusals", return_value=[{"session": "x"}]):
            code, err = self.main("brief", "apply")
        self.assertEqual(code, 3)
        self.assertIn("cc-focus --new-sessions", err)
        self.assertIn("Then run cc-focus brief apply.", err)

    def test_the_refusal_recovery_sequence_starts_no_provider_before_acceptance(self):
        old = self.set_brief("A brief that caused a refusal.\n", "old.md")
        self.start_stage()
        self.stopped(code_started=True, sessions={"code": "refused-session"},
                     blocker={"code": "claude-refusal", "message": "refused", "status": "blocked",
                              "signature": "s", "phase": "code", "escalation_reason": "provider-refusal",
                              "interrupted": {"id": "a" * 32, "role": "code"}})
        self.assertEqual(self.state["project_brief"]["sha256"], old)
        with contextlib.redirect_stdout(io.StringIO()):
            focus_brief.command(self.root, "clear")
        refused = {"session_id": "refused-session", "refused": True}
        with patch("focus_diagnostics.saved_claude_call", return_value=refused):
            code, err = self.main("brief", "apply")  # The refused conversation still exists.
            self.assertEqual(code, 3)
            self.assertIn("Claude refused the saved conversation", err)
            self.assertEqual(self.saved()["project_brief"]["sha256"], old)
            code, err = self.main("--new-sessions", "--ui", "off")
            self.assertEqual(code, 3, err)  # The run stops at the saved blocker.
            self.assertEqual(self.saved()["sessions"], {})
            code, err = self.main("brief", "apply")
            self.assertEqual(code, 0, err)
        saved = self.saved()
        self.assertEqual((saved["project_brief"]["sha256"], saved["blocker"]), (None, None))
        with patch("cc_focus.Cycle.run", return_value=0):
            self.assertEqual(self.main("--ui", "off")[0], 0)

    def test_changed_protected_work_and_a_stop_request_refuse_after_the_lease(self):
        strip = lambda state: {k: v for k, v in state.items() if k != "updated"}
        (self.root / "operator.txt").write_text("operator work\n")
        self.start_stage()
        self.assertIn("operator.txt", self.state["protected"])
        self.stopped()
        self.set_brief()
        before = self.saved()
        (self.root / "operator.txt").write_text("changed operator work\n")
        code, err = self.main("brief", "apply")
        self.assertEqual(code, 3)
        self.assertIn("Pre-existing work was changed", err)
        self.assertNotIn("saved state", err)
        self.assertEqual(strip(self.saved()), strip(before))
        (self.root / "operator.txt").write_text("operator work\n")
        with patch("cc_focus.Control.boundary", return_value=True):
            code, err = self.main("brief", "apply")
        self.assertEqual(code, 3)
        self.assertIn("pause/stop", err)
        self.assertEqual(strip(self.saved()), strip(before))

    def test_a_malformed_pointer_at_apply_changes_nothing(self):
        self.stopped()
        before = self.store.path.read_bytes()
        self.pointer_path().write_text("{")
        code, err = self.main("brief", "apply")
        self.assertEqual(code, 3)
        self.assertIn("pointer", err)
        self.assertEqual(self.store.path.read_bytes(), before)


class RestartTests(BriefFixture, unittest.TestCase):
    def completed(self, sessions=None, record=None):
        self.state.update(status="complete", code_started=True, coordinated="code", sessions=sessions or {"code": "old"})
        if record is not None:
            self.state["project_brief"] = record
        self.store.save(self.state)
        return self.brief_file("Handoff text.\n", "handoff.md")

    def run_handoff(self, handoff, *extra):
        with patch("cc_focus.Cycle.run", return_value=0):
            return self.main("--handoff", str(handoff), "--ui", "off", *extra)

    def test_a_changed_brief_retires_old_conversations_once(self):
        handoff = self.completed()
        sha = self.set_brief()
        code, err = self.run_handoff(handoff, "--new-sessions")
        self.assertEqual(code, 0, err)
        saved = self.saved()
        self.assertEqual(saved["project_brief"], {"iteration": 1, "sha256": sha})
        self.assertEqual((saved["status"], saved["code_started"], saved["sessions"]), ("ready", False, {}))
        self.assertEqual(saved["session_generation"], 2)

    def test_equal_and_legacy_null_hashes_keep_conversations(self):
        handoff = self.completed()
        self.assertEqual(self.run_handoff(handoff)[0], 0)
        self.assertEqual(self.saved()["sessions"], {"code": "old"})
        for brief in (False, True):
            with self.subTest(brief=brief):
                self.state = self.saved()
                self.state.pop("project_brief")
                self.state["status"] = "complete"
                self.store.save(self.state)
                if brief:
                    self.set_brief()
                self.assertEqual(self.run_handoff(handoff)[0], 0)
                self.assertEqual(self.saved()["sessions"], {} if brief else {"code": "old"})

    def test_failures_before_the_restart_update_keep_complete(self):
        handoff = self.completed()
        self.pointer_path().write_text("{")
        code, err = self.run_handoff(handoff)
        self.assertEqual((code, self.saved()["status"]), (3, "complete"))
        self.assertIn("the same cc-focus command", err)
        with contextlib.redirect_stdout(io.StringIO()):
            focus_brief.command(self.root, "clear")
        empty = self.brief_file(b"", "empty.md")
        code, _ = self.run_handoff(empty)
        self.assertEqual((code, self.saved()["status"]), (3, "complete"))
        for failure in (Blocked("lease-unavailable", "held"), KeyboardInterrupt()):
            with self.subTest(failure=type(failure).__name__):
                self.main("--handoff", str(handoff), "--ui", "off", lease_enter=failure)
                self.assertEqual(self.saved()["status"], "complete")
        self.assertEqual(self.run_handoff(handoff)[0], 0)
        self.assertEqual(self.saved()["status"], "ready")

    def test_a_damaged_record_is_archived_with_a_notice(self):
        handoff = self.completed(record={"iteration": 5, "sha256": None})
        self.assertEqual(self.run_handoff(handoff)[0], 0)
        self.assertIn("replaced the damaged brief record", self.out)
        archives = list((self.store.directory / "brief-restarts").iterdir())
        self.assertEqual(len(archives), 1)
        archived = json.loads(archives[0].read_text())
        self.assertEqual(archived["project_brief"]["iteration"], 5)
        self.assertEqual(archived["handoffs"], [])  # The archive is the state before the restart.
        self.assertEqual(self.saved()["sessions"], {})


class PairDeliveryTests(BriefFixture, unittest.TestCase):
    start = pairs.PairTests.start
    until = pairs.PairTests.until
    assign = pairs.PairTests.assign

    def test_every_reader_and_writer_gets_the_pair_brief_and_the_assessor_does_not(self):
        sha = self.set_brief()
        self.start_stage()
        self.start()
        pair = self.cycle.new_pair()
        self.assertEqual(pair["project_brief_sha256"], sha)
        row = dict(pairs.finding(), source_id="assigned", severity="high")
        pair.update(step="decide", issues=[row], decisions=[pairs.decision(row)], impact="minor")
        self.transport.handlers["pair_complexity"] = lambda c, h: report(complexity=pairs.complexity(c["assignment"], "high"))
        self.set_brief("A later default.\n", "later.md")  # The pair keeps its own hash.
        self.until(lambda: self.state["phase"] == "pair_b")
        roles = [role for role, _ in self.transport.calls]
        self.assertIn("pair_complexity", roles)
        self.assertTrue(any(role in PAIR_WRITERS for role in roles))
        for role, context in self.transport.calls:
            with self.subTest(role=role):
                if role == "pair_complexity":
                    self.assertNotIn("project_brief", context)
                else:
                    self.assertEqual(context["project_brief"], {"sha256": sha, "text": TEXT, "rule": PROJECT_BRIEF_RULE})
        conclusion = read_record(self.store, self.state["pair_completed"]["pair_a"])
        self.assertEqual(conclusion["project_brief_sha256"], sha)

    def test_discussion_readers_and_the_final_arbiter_get_the_brief(self):
        sha = self.set_brief()
        self.start_stage()
        self.start("final")
        self.transport.handlers["pair_final_opus"] = lambda c, h: report(findings=[pairs.finding()])

        def dissent(c, h):
            return report(assessments=[pairs.decision(r, "reject", False) for r in c["assignment"]["registry"]],
                          new_findings=[], consensus=None, impact="minor")
        self.transport.handlers["pair_final_fable_discuss"] = dissent
        self.transport.handlers["pair_arbiter"] = dissent
        self.until(lambda: self.state["phase"] == "publish")
        roles = {role for role, _ in self.transport.calls}
        self.assertTrue({"pair_arbiter", "pair_final_opus_discuss", "pair_final_fable_discuss"} <= roles)
        for role, context in self.transport.calls:
            with self.subTest(role=role):
                self.assertEqual(context["project_brief"]["sha256"], sha)

    def test_the_evidence_auditor_and_the_assessor_get_no_brief_even_with_a_pair_hash(self):
        self.set_brief()
        self.start_stage()
        self.start()
        pair = self.cycle.new_pair()
        for role in ("repair_evidence", "pair_complexity"):
            context = context_of(self.cycle.pair_prompt(pair, role, {"mode": "test_evidence_delta"}), "Runtime assignment:\n")
            self.assertNotIn("project_brief", context)

    def test_new_job_intents_record_the_pair_hash(self):
        sha = self.set_brief()
        self.start_stage()
        self.start()
        pair = self.cycle.new_pair()
        self.cycle.paired_review_step()
        self.assertEqual(sorted(job["role"] for job in pair["jobs"].values()), sorted(PAIRS["pair_a"]))
        self.assertTrue(all(job["project_brief_sha256"] == sha for job in pair["jobs"].values()))

    def test_final_pair_initial_prompt_has_the_brief_and_no_history_after_earlier_pairs(self):
        sha = self.set_brief()
        self.start_stage()
        self.start()
        self.until(lambda: self.state["phase"] == "publish")
        finals = [(role, context) for role, context in self.transport.calls if role in PAIRS["final"]]
        self.assertTrue(finals and any(role in PAIRS["pair_a"] for role, _ in self.transport.calls))
        for role, context in finals:
            self.assertEqual(context["project_brief"]["sha256"], sha)
            self.assertEqual(context["history"], [])
            self.assertEqual(context["assignment"], {"mode": "independent_initial"})

    def test_inner_readers_writers_and_seals_use_the_outer_hash(self):
        sha = self.set_brief()
        self.start_stage()
        pair = self.assign("final", "low", False)
        self.assertEqual(pair["project_brief_sha256"], sha)
        self.until(lambda: self.state["phase"] == "publish")
        roles = [role for role, _ in self.transport.calls]
        self.assertIn("repair_self", roles)
        self.assertIn("repair_execute", roles)
        for role, context in self.transport.calls:
            with self.subTest(role=role):
                self.assertEqual(context["project_brief"]["sha256"], sha)
        seals = list((self.store.directory / "pair-reviews").rglob("seal.json"))
        self.assertGreaterEqual(len(seals), 2)  # The repair seal and the publication seal.
        for path in seals:
            self.assertEqual(json.loads(path.read_text())["project_brief_sha256"], sha, path)

    def test_the_final_gate_copies_the_outer_hash(self):
        sha = self.set_brief()
        self.start_stage()
        self.start("final")
        review = self.cycle.new_pair()
        review["scans"] = {"pair_final_opus": {"final_gate": {"full_run": True, "reason": "Shared configuration changed."}}}
        self.assertTrue(self.cycle.start_final_gate(review, self.repo.snapshot(), "conclusion-ref"))
        self.assertEqual(self.state["pair_review"]["project_brief_sha256"], sha)
        writer = context_of(self.cycle.context("repair_execute"), "Executor assignment:\n")
        self.assertEqual(writer["project_brief"]["sha256"], sha)
        legacy = dict(review)
        legacy.pop("project_brief_sha256")
        self.assertTrue(self.cycle.start_final_gate(legacy, self.repo.snapshot(), "conclusion-ref"))
        self.assertNotIn("project_brief_sha256", self.state["pair_review"])

    def test_a_legacy_pair_gets_no_brief_and_brief_entries_keep_the_corrections_key(self):
        self.set_brief()
        self.start_stage()
        self.start()
        pair = self.cycle.new_pair()
        pair.pop("project_brief_sha256")
        context = context_of(self.cycle.pair_prompt(pair, "pair_opus", {"mode": "independent_initial"}), "Runtime assignment:\n")
        self.assertNotIn("project_brief", context)
        self.assertEqual(context["corrections"], [])
        self.state["code_started"] = True
        self.cycle.apply_brief(None)
        pair = self.cycle.new_pair()
        context = context_of(self.cycle.pair_prompt(pair, "pair_opus", {"mode": "independent_initial"}), "Runtime assignment:\n")
        self.assertEqual(context["corrections"], [])
        self.assertEqual(context["project_brief_notice"], BRIEF_CHANGE_CORRECTION)
        self.assertNotIn("project_brief", context)  # A removed brief adds no field.
        self.assertIsNone(pair["project_brief_sha256"])


class CampaignTests(BriefFixture, unittest.TestCase):
    def campaign(self, request=None):
        import test_focus_campaign as campaigns
        from focus_review_run import ReviewCycle, create_run
        from focus_review_scope import make_request
        store, state = create_run(self.repo, request or make_request(scope="Check source behavior"))
        transport = campaigns.CampaignTransport(self.root)
        cycle = ReviewCycle(self.repo, store, state, transport, lambda: None, fixtures.REPO / "tools", "pwsh")
        transport.cycle = cycle
        return store, state, transport, cycle

    def review(self, state, cycle):
        for _ in range(80):
            if state["phase"] == "publish":
                return
            cycle.paired_review_step()
        self.fail("Review did not converge")

    def test_targets_record_the_brief_and_the_coordinator_gets_none(self):
        sha = self.set_brief()
        self.remote()
        store, state, transport, cycle = self.campaign()
        self.assertEqual(state["project_brief"], {"iteration": 1, "sha256": sha})
        self.assertNotIn("project_brief", cycle.context("coordinate"))
        cycle.wait_ci = lambda: state.update(display_ci={"sha": state["published"]["sha"], "status": "ready"})
        self.assertEqual(cycle.run(), 0)
        result = read_record(store, state["review_run"]["results"]["0"])
        self.assertEqual(result["project_brief_sha256"], sha)
        scans = [c for r, c in transport.calls if r in PAIRS["pair_a"]]
        self.assertTrue(scans and all(c["project_brief"]["sha256"] == sha for c in scans))
        self.assertEqual(focus_brief.show(self.root, store.review_id)["records"]["campaign " + store.review_id]["stage"], sha)

    def test_a_later_target_captures_the_pointer_and_a_failed_start_repeats_cleanly(self):
        from test_focus_campaign import PLAN
        from focus_review_scope import make_request, plan_index
        (self.root / "PLAN.md").write_text(PLAN)
        self.repo.git("add", "PLAN.md")
        self.repo.git("commit", "-m", "Add plan")
        first = self.set_brief()
        self.remote()
        store, state, transport, cycle = self.campaign(make_request(plan_index(self.root, "PLAN.md"), ["S2-1", "S2-2a"]))
        self.assertIn("campaign " + store.review_id, focus_brief.show(self.root)["records"])  # The unfinished campaign.
        self.review(state, cycle)
        cycle.publish()
        second_file = self.brief_file("Second brief.\n", "second.md")
        second = self.set_brief("Second brief.\n", "second.md")
        self.copy(second).write_text("damaged")
        with self.assertRaises(Blocked) as raised:
            cycle.next_stage()
        self.assertIn("review --resume " + store.review_id + " --retry", str(raised.exception))
        failed = copy.deepcopy(state)
        with contextlib.redirect_stdout(io.StringIO()):
            focus_brief.command(self.root, "restore", second_file)
        self.assertTrue(cycle.next_stage())
        self.assertEqual(state["project_brief"], {"iteration": 2, "sha256": second})
        self.assertEqual(failed["iteration"], 1)  # The failed start left the earlier stage.
        self.assertEqual(len(state["review_run"]["history"]), 1)  # The repeat recorded the target once.
        result = read_record(store, state["review_run"]["results"]["0"])
        self.assertEqual(result["project_brief_sha256"], first)

    def test_a_damaged_record_does_not_stop_the_target_result(self):
        self.remote()
        store, state, transport, cycle = self.campaign()
        state["project_brief"] = {"iteration": 3, "sha256": None}
        self.assertIsNone(cycle.target_brief()["project_brief_sha256"])
        self.assertIn("project_brief_error", cycle.target_brief())

    def test_apply_in_a_campaign_requires_its_id(self):
        self.remote()
        store, state, _, _ = self.campaign()
        sha = self.set_brief()
        code, err = self.main("brief", "apply")
        self.assertEqual(code, 3)
        self.assertIn("cc-focus brief apply --review-run " + store.review_id, err)
        code, err = self.main("brief", "apply", "--review-run", store.review_id)
        self.assertEqual(code, 0, err)
        self.assertEqual(store.read()["project_brief"], {"iteration": 1, "sha256": sha})
        self.assertIn("cc-focus review --resume " + store.review_id, self.out)

    def test_a_campaign_refusal_names_the_campaign_session_command(self):
        self.remote()
        store, state, _, _ = self.campaign()
        state["blocker"] = {"code": "claude-refusal", "message": "refused", "status": "blocked", "signature": "s", "phase": "pair_a"}
        store.save(state)
        self.set_brief()
        for args in (["brief", "apply"], ["correct", "--message", "Check the restart path."]):
            with self.subTest(command=args[0]), patch("focus_diagnostics.selected_refusals", return_value=[{"session": "x"}]):
                code, err = self.main(*args, "--review-run", store.review_id)
                self.assertEqual(code, 3)
                self.assertIn("cc-focus review --resume " + store.review_id + " --new-sessions", err)
                if args[0] == "brief":
                    self.assertIn("Then run cc-focus brief apply --review-run " + store.review_id + ".", err)

    def test_the_campaign_refusal_recovery_sequence(self):
        self.remote()
        store, state, _, _ = self.campaign()
        old = state["project_brief"]["sha256"]
        # A refused conversation of a role that a correction keeps. Pair A of this target used the brief.
        state.update(phase="pair_b", pair_completed={"pair_a": "ref"}, sessions={"code": "refused-session"},
                     blocker={"code": "claude-refusal", "message": "refused", "status": "blocked", "signature": "s",
                              "phase": "pair_b", "escalation_reason": "provider-refusal",
                              "interrupted": {"id": "b" * 32, "role": "code"}})
        store.save(state)
        self.set_brief()
        refused = {"session_id": "refused-session", "refused": True}
        with patch("focus_diagnostics.saved_claude_call", return_value=refused):
            code, err = self.main("brief", "apply", "--review-run", store.review_id)
            self.assertEqual(code, 3)
            self.assertIn("cc-focus review --resume " + store.review_id + " --new-sessions", err)
            code, err = self.main("review", "--resume", store.review_id, "--new-sessions", "--ui", "off")
            self.assertEqual(code, 3, err)
            self.assertEqual(store.read()["sessions"], {})
            code, err = self.main("brief", "apply", "--review-run", store.review_id)
            self.assertEqual(code, 0, err)
        saved = store.read()
        self.assertNotEqual(saved["project_brief"]["sha256"], old)
        self.assertEqual((saved["blocker"], saved["phase"]), (None, "pair_a"))
        with patch("cc_focus.Cycle.run", return_value=0):
            self.assertEqual(self.main("review", "--resume", store.review_id, "--ui", "off")[0], 0)

    def test_a_refused_pair_a_writer_does_not_stop_a_campaign_correction(self):
        self.remote()
        store, state, _, _ = self.campaign()
        # The next outer pair starts the Pair A executor in a new session, so the correction resends nothing.
        state.update(phase="pair_b", pair_completed={"pair_a": "ref"}, sessions={"pair_fix": "refused-session"},
                     blocker={"code": "claude-refusal", "message": "refused", "status": "blocked", "signature": "s",
                              "phase": "pair_b", "escalation_reason": "provider-refusal",
                              "interrupted": {"id": "b" * 32, "role": "pair_fix"}})
        store.save(state)
        self.set_brief()
        with patch("focus_diagnostics.saved_claude_call", return_value={"session_id": "refused-session", "refused": True}):
            code, err = self.main("brief", "apply", "--review-run", store.review_id)
        self.assertEqual(code, 0, err)
        self.assertEqual((store.read()["blocker"], store.read()["phase"]), (None, "pair_a"))

    def development_boundary(self, **fields):
        development = fresh_state(self.repo)
        development.update(fields)
        Store(self.root).save(development)
        return development

    def test_apply_accepts_a_pending_handover_and_a_new_stage_with_the_pointer_needs_no_change(self):
        self.remote()
        head = self.repo.text("rev-parse", "HEAD")
        self.development_boundary(phase="ci", status="paused", code_started=True, published={"sha": head},
                                  stage_completed={"iteration": 1, "sha": head})
        store, state, transport, cycle = self.campaign()
        self.review(state, cycle)
        cycle.publish()
        cycle.next_stage()
        sha = self.set_brief()
        code, err = self.main("brief", "apply")
        self.assertEqual(code, 0, err)
        self.assertIn("already uses", self.out)
        development = Store(self.root).read()
        self.assertEqual(development["review_handover"]["id"], store.review_id)
        self.assertEqual(development["project_brief"], {"iteration": 2, "sha256": sha})

    def test_a_direct_update_after_an_unchanged_campaign_keeps_its_handover(self):
        self.remote()
        self.development_boundary()  # Phase code before coding is a development boundary.
        store, state, transport, cycle = self.campaign()
        self.review(state, cycle)
        cycle.publish()
        cycle.next_stage()
        sha = self.set_brief()
        code, err = self.main("brief", "apply")
        self.assertEqual(code, 0, err)
        self.assertIn("direct update", self.out)
        development = Store(self.root).read()
        self.assertEqual(development["review_handover"]["id"], store.review_id)
        self.assertEqual(development["project_brief"], {"iteration": 1, "sha256": sha})


if __name__ == "__main__":
    unittest.main()
