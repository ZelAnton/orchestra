"""Hermetic workflow/protocol tests; never invoke a paid provider."""

import contextlib
import io
import json
import os
import shutil
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
sys.path.insert(0, str(REPO / "tools"))
from cycle_state import Blocked, Lease, LocalLock, Repository, Store, atomic_write, changed, command, encode
from cycle_prompts import PROFILES
from cycle_transport import Process, Rpc, Transport, concise_summary, parse_report
from cycle_workflow import Cycle, fresh_state
from focus_control import Control, FocusStop, request_stop, runtime_active, status
from focus_progress import Progress, safe_text
from focus_output import LiveOutput


def report(**kwargs):
    value = dict(status="done", summary="Validated fixture result", description="Full coding result, details and deferred work.",
                 implementation_fixes=0, other_fixes=0, minor_edits=0, substantial=False, evidence=["Focused fixture validation"])
    value.update(kwargs)
    return value


class FixtureTransport:
    def __init__(self, root, actions=()):
        self.root, self.actions, self.calls = root, list(actions), []

    def run(self, role, prompt, pending, directory):
        self.calls.append((role, prompt))
        if not self.actions:
            raise AssertionError(f"Unexpected provider call: {role}")
        expected, action = self.actions.pop(0)
        if role != expected:
            raise AssertionError(f"Expected {expected}, got {role}")
        if isinstance(action, BaseException):
            raise action
        result = action() if callable(action) else action
        return json.dumps(result)


class CycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="orc-cycle-test-")
        self.root = Path(self.temp.name) / "repo with spaces"
        self.root.mkdir()
        self.repo = Repository(self.root)
        self.repo.git("init", "--initial-branch=main")
        self.repo.git("config", "user.email", "test@example.invalid")
        self.repo.git("config", "user.name", "Test")
        (self.root / ".gitignore").write_text(".work/\n", encoding="utf-8")
        (self.root / "source.txt").write_text("initial\n", encoding="utf-8")
        self.repo.git("add", ".gitignore", "source.txt")
        self.repo.git("commit", "-m", "Initial source")
        self.store = Store(self.root)
        self.state = fresh_state(self.repo)
        self.transport = FixtureTransport(self.root)
        self.cycle = Cycle(self.repo, self.store, self.state, self.transport, lambda: None, REPO / "tools", "pwsh")
        self.quiet = contextlib.redirect_stdout(io.StringIO())
        self.quiet.__enter__()

    def tearDown(self):
        self.quiet.__exit__(None, None, None)
        self.temp.cleanup()

    def edit(self, name="source.txt", content="changed\n", **kwargs):
        def action():
            (self.root / name).write_text(content, encoding="utf-8")
            return report(**kwargs)
        return action

    def remote(self):
        remote = Path(self.temp.name) / "bare.git"
        command = subprocess.run(["git", "init", "--bare", str(remote)], capture_output=True)
        self.assertEqual(command.returncode, 0)
        self.repo.git("remote", "add", "origin", str(remote))
        self.repo.git("push", "-u", "origin", "main")

    def commit_stage(self):
        self.repo.git("add", "source.txt")
        self.repo.git("commit", "-m", "Update source")
        self.repo.git("push", "origin", "main")
        return report()

    def test_ci_transition_cannot_accept_changed_protected_staging(self):
        self.remote()
        self.edit(name="operator.txt", content="preexisting operator work\n")()
        self.state = fresh_state(self.repo)
        self.cycle.state = self.state
        self.edit()()
        self.state.update(reviewed=self.repo.snapshot(), phase="ci")
        self.commit_stage()
        self.state["published"] = {"sha": self.repo.text("rev-parse", "HEAD"), "remote": "origin", "at": time.time()}
        self.cycle.assert_publication_current()
        self.repo.git("add", "operator.txt")
        before = self.repo.snapshot()
        with self.assertRaisesRegex(Blocked, "index entries changed"):
            self.cycle.next_stage()
        self.assertEqual(self.repo.snapshot(), before)
        self.assertEqual((self.state["iteration"], self.state["phase"]), (1, "ci"))
        self.assertFalse((self.store.directory / "iterations/000001.json").exists())

    def test_handoff_is_immutable_and_checksummed_state_is_bound(self):
        source = self.root / "handoff.md"
        source.write_text("stage plan", encoding="utf-8")
        handoff = self.store.handoff(source)
        source.write_text("changed source", encoding="utf-8")
        self.assertEqual(Path(handoff["path"]).read_text(), "stage plan")
        self.store.save(self.state)
        self.assertEqual(self.store.read()["root"], str(self.root))
        raw = json.loads(self.store.path.read_text())
        raw["state"]["phase"] = "publish"
        atomic_write(self.store.path, encode(raw))
        with self.assertRaisesRegex(Blocked, "checksum"):
            self.store.read()

    def test_local_lock_is_exclusive_and_reusable(self):
        with LocalLock(self.store.directory):
            with self.assertRaises(Blocked):
                with LocalLock(self.store.directory):
                    pass
        with LocalLock(self.store.directory):
            pass

    def test_single_repository_reconciliation_preserves_work_and_restarts_reviews(self):
        import focus_reconcile
        self.edit(content="previous operator work\n")()
        self.state = fresh_state(self.repo)
        self.state.update(phase="astra", status="blocked", code_started=True, astra_clean=2)
        self.cycle.state = self.state
        self.edit(content="current operator work\n")()
        snapshot = self.repo.snapshot()
        plan = self.root / ".work/reconcile.json"
        prepared = focus_reconcile.write_plan(self.cycle, plan)
        self.assertEqual([(row["path"], row["action"]) for row in prepared["changes"]], [("source.txt", "adopt-file")])
        focus_reconcile.apply(self.cycle, plan)
        self.cycle.check_protected(self.repo.snapshot())
        self.assertEqual(self.repo.snapshot(), snapshot)
        self.assertEqual((self.state["phase"], self.state["astra_clean"], self.state["claude_clean"]), ("code", 0, 0))
        self.assertEqual(self.state["protected"], [])
        self.assertFalse(self.transport.calls)

    def test_reconciliation_plan_must_not_change_its_own_work_snapshot(self):
        import focus_reconcile
        (self.root / ".gitignore").write_text("# No work exclusion\n")
        self.repo.git("add", ".gitignore")
        self.repo.git("commit", "-m", "Change work tracking")
        self.edit(content="previous work\n")()
        self.state = fresh_state(self.repo)
        self.state.update(code_started=True)
        self.cycle.state = self.state
        self.edit(content="new work\n")()
        with self.assertRaisesRegex(Blocked, "part of the Git work snapshot"):
            focus_reconcile.write_plan(self.cycle, self.root / ".work/plan.json")
        path = Path(self.temp.name) / "plan.json"
        focus_reconcile.write_plan(self.cycle, path)
        focus_reconcile.apply(self.cycle, path)
        self.assertEqual(self.state["status"], "paused")

    def test_report_rejects_fabricated_types(self):
        for value in (report(implementation_fixes=True), report(substantial=True), report(summary=""),
                      report(evidence=[1]), report(evidence=[""]), report(evidence=[" \t\n"]),
                      report(implementation_fixes=-1)):
            with self.assertRaises(Blocked):
                parse_report(json.dumps(value))

    def test_report_accepts_one_final_object_after_prose_or_fence(self):
        value = report(description='Full account with {braces}, [arrays], "quotes" and\nUnicode: Ж.')
        raw = json.dumps(value, ensure_ascii=False)
        for wrapped in (raw, "Report follows.\n\n" + raw,
                        "The cited range §§55–64 is correct. Everything is in place; final report follows.\n\n" + raw,
                        "```json\n" + raw + "\n```", "Report follows.\r\n```\r\n" + raw + "\r\n```\r\n"):
            with self.subTest(wrapped=wrapped[:40]):
                self.assertEqual(parse_report(wrapped, "code"), value)

    def test_report_unwrapping_rejects_ambiguous_or_malformed_payloads(self):
        raw = json.dumps(report())
        for wrapped in (raw + "\n" + raw, "{}\n" + raw, '{"broken":\n' + raw,
                        "[\n" + raw + "\n]", '{"nested":\n' + raw + "}",
                        "Report: " + raw, "Report:\n" + raw + "\nActually blocked.",
                        "```json\n" + raw, "```python\n" + raw + "\n```",
                        'Report:\n{"status":"blocked",' + raw[1:],
                        '"Quoted report:\n' + raw + '"', "null", None):
            with self.subTest(wrapped=str(wrapped)[:50]), self.assertRaises(Blocked):
                parse_report(wrapped, "code")

    def test_report_preamble_preserves_schema_and_fix_validation(self):
        for value in (report(implementation_fixes=True), report(substantial=True),
                      report(summary=""), report(evidence=[1]), report(implementation_fixes=-1),
                      report(extra="field"), report(status="unknown")):
            with self.subTest(value=value), self.assertRaises(Blocked):
                parse_report("Final report:\n" + json.dumps(value), "astra")

    def test_prefaced_coding_report_advances_without_healer_and_preserves_raw(self):
        raw = "Everything is in place; final report follows.\n\n" + json.dumps(report(substantial=True))
        self.state.update(coordinated="code")
        control = self.focus_control()
        def finish_code(*args):
            self.stop_request(control)
            return raw
        with patch.object(self.transport, "run", side_effect=finish_code) as provider:
            self.assertEqual(self.cycle.run(), 0)
        provider.assert_called_once()
        self.assertEqual(self.state["phase"], "astra")
        self.assertEqual(self.state["code_report"], raw)
        self.assertEqual((self.state["astra_clean"], self.state["claude_clean"]), (0, 0))
        self.assertEqual(json.loads(Path(self.state["last"]["report"]).read_bytes())["raw"], raw)

    def test_prefaced_review_report_cannot_hide_blocker_or_missing_evidence(self):
        for value in (report(status="blocked"), report(evidence=[])):
            with self.subTest(value=value):
                self.state.update(phase="astra", astra_clean=0, pending=None)
                with patch.object(self.transport, "run", return_value="Final report:\n" + json.dumps(value)):
                    with self.assertRaises(Blocked):
                        self.cycle.review("astra")
                self.assertEqual(self.state["astra_clean"], 0)

    def test_long_summary_preserves_the_complete_validated_report(self):
        for length in (1199, 1200, 1201, 12000):
            with self.subTest(length=length):
                value = report(summary="\u0416" * length, implementation_fixes=2,
                               other_fixes=1, minor_edits=3, substantial=True)
                self.assertEqual(parse_report(json.dumps(value), "claude"), value)
                preview = concise_summary(value["summary"])
                self.assertLessEqual(len(preview), 1200)
                if length <= 1200:
                    self.assertEqual(preview, value["summary"])
                else:
                    self.assertIn("summary shortened; full report saved", preview)

    def test_long_summary_does_not_relax_semantic_report_validation(self):
        for overrides in (dict(substantial=True), dict(implementation_fixes=True),
                          dict(evidence=[1]), dict(description=""), dict(status="unknown")):
            with self.subTest(overrides=overrides), self.assertRaises(Blocked):
                parse_report(json.dumps(report(summary="x" * 1201, **overrides)), "claude")

    def test_long_summary_bounds_projections_but_keeps_raw_and_cached_results(self):
        value = report(summary="Result " * 400 + "unique ending")
        for role in ("coordinate", "code", "astra", "claude", "heal"):
            with self.subTest(role=role):
                self.transport.actions = [(role, value)]
                parsed, before, after, raw = self.cycle.invoke(role)
                self.assertEqual(parsed, value)
                self.assertEqual(json.loads(raw), value)
                projection = self.state["coordination" if role == "coordinate" else "last"]
                self.assertLessEqual(len(projection["summary"]), 1200)
                saved = Path(projection["report"]).read_bytes()
                self.assertEqual(json.loads(saved)["raw"], raw)
                self.assertEqual(self.cycle.invoke(role), (parsed, before, after, raw))
                self.assertEqual(Path(projection["report"]).read_bytes(), saved)
                self.assertEqual(self.transport.calls[-1][0], role)
                if role != "coordinate":
                    self.assertNotIn("unique ending", self.cycle.context("coordinate"))
                self.cycle.complete_invocation()
        self.assertEqual(len(self.transport.calls), 5)

    def test_long_review_summary_preserves_clean_pass_and_fix_gates(self):
        cases = [(0, False, "publish", 2), (1, False, "claude", 0), (1, True, "astra", 0)]
        for fixes, substantial, phase, clean in cases:
            with self.subTest(fixes=fixes, substantial=substantial):
                self.state.update(phase="claude", astra_passes=3, astra_clean=3, claude_clean=1)
                self.transport.actions = [("claude", report(summary="x" * 1201,
                    implementation_fixes=fixes, substantial=substantial))]
                self.cycle.review("claude")
                self.assertEqual(self.state["phase"], phase)
                self.assertEqual(self.state["claude_clean"], clean)

    def test_long_summary_cannot_certify_an_incomplete_or_blocked_review(self):
        for overrides, error in ((dict(evidence=[]), "completed pass"),
                                 (dict(status="complete"), "completed pass"),
                                 (dict(status="blocked"), "Provider blocker detail")):
            with self.subTest(overrides=overrides):
                self.state.update(phase="claude", pending=None, claude_clean=1)
                self.transport.actions = [("claude", report(summary="x" * 1201,
                    description="Provider blocker detail", **overrides))]
                with self.assertRaisesRegex(Blocked, error):
                    self.cycle.review("claude")
                self.assertEqual(self.state["phase"], "claude")
                self.assertEqual(self.state["claude_clean"], 1)

    def test_retry_legacy_summary_blocker_preserves_review_phase_and_sessions(self):
        import cc_focus
        self.state.update(phase="claude", coordinated="claude", astra_clean=3,
                          claude_clean=1, recovery_unverified=True,
                          sessions={"claude": "preserved-review-session"})
        self.transport.actions = [("claude", report(summary="x" * 1201))]
        self.cycle.invoke("claude")
        result_path = Path(self.state["last"]["report"])
        saved = result_path.read_bytes()
        self.cycle.handle_block(Blocked("invalid-report", "Provider final report is invalid: summary exceeds 1200 characters"))
        self.assertEqual(self.state["status"], "blocked")
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.Lease") as lease, \
                patch("cc_focus.Cycle.run", return_value=0):
            lease.return_value.__enter__.return_value.pwsh = "pwsh"
            self.assertEqual(cc_focus.main(["--retry", "--ui", "off"]), 0)
        current = self.store.read()
        self.assertIsNone(current["blocker"])
        self.assertEqual(current["phase"], "claude")
        self.assertEqual(current["sessions"], self.state["sessions"])
        self.assertEqual(current["astra_clean"], 3)
        self.assertEqual(current["claude_clean"], 0)
        self.assertEqual(result_path.read_bytes(), saved)

    def test_new_coding_work_does_not_require_review_fix_counts(self):
        raw = json.dumps(report(substantial=True))
        self.assertTrue(parse_report(raw, "code")["substantial"])
        for role in (None, "astra", "claude", "heal", "coordinate"):
            with self.subTest(role=role), self.assertRaises(Blocked):
                parse_report(raw, role)

    def rejected_coding_fixture(self):
        self.state.update(coordinated="code", sessions={"code": "preserved-code-session"})
        self.transport.actions = [("code", self.edit(substantial=True, description="Original full coding account"))]
        self.cycle.invoke("code")
        path = self.store.directory / "invocations" / self.state["pending"]["id"] / "result.json"
        self.state.update(status="blocked", pending=None, coordinated=None, code_report="",
                          recovery_unverified=True, last={"role": "heal", "summary": "Report-only recovery"},
                          blocker={"phase": "code", "status": "blocked", "code": "reported-blocker",
                                   "signature": "fixture", "message": "Coding complete; reviews pending"})
        self.store.save(self.state)
        return path

    def test_review_recovery_preserves_legacy_result_sessions_and_files(self):
        path = self.rejected_coding_fixture()
        intent_path = path.parent / "intent.json"
        intent = json.loads(intent_path.read_text())
        intent.pop("iteration")  # Previously installed cc-cycle did not persist this field.
        intent_path.write_bytes(encode(intent))
        snapshot = self.repo.snapshot()
        raw_bytes = path.read_bytes()
        self.state.update(astra_clean=2, claude_clean=1)
        self.cycle.recover_review(path)
        self.assertEqual(self.state["phase"], "astra")
        self.assertEqual(self.state["status"], "paused")
        self.assertEqual((self.state["astra_clean"], self.state["claude_clean"]), (0, 0))
        self.assertEqual(self.state["sessions"]["code"], "preserved-code-session")
        self.assertIsNone(self.state["blocker"])
        self.assertIsNone(self.state["pending"])
        self.assertIn("Original full coding account", self.state["code_report"])
        self.assertEqual(path.read_bytes(), raw_bytes)
        self.assertEqual(self.repo.snapshot(), snapshot)
        backups = list((self.store.directory / "recoveries").glob("*.json"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(json.loads(backups[0].read_text())["previous_state"]["phase"], "code")
        self.assertEqual(self.store.read()["phase"], "astra")

    def test_coding_recovery_bounds_summary_without_shortening_astra_context(self):
        path = self.rejected_coding_fixture()
        result = json.loads(path.read_bytes())
        value = json.loads(result["raw"])
        value["summary"] = "x" * 1201 + "unique summary ending"
        result["raw"] = json.dumps(value)
        path.write_bytes(encode(result))
        saved = path.read_bytes()
        self.cycle.recover_review(path)
        self.assertLessEqual(len(self.state["last"]["summary"]), 1200)
        self.assertIn("unique summary ending", self.cycle.context("astra"))
        self.assertNotIn("unique summary ending", self.cycle.context("coordinate"))
        self.assertEqual(path.read_bytes(), saved)

    def test_prefaced_report_recovery_requires_the_original_snapshot(self):
        path = self.rejected_coding_fixture()
        result = json.loads(path.read_bytes())
        result["raw"] = "Final report follows.\n\n" + result["raw"]
        path.write_bytes(encode(result))
        saved = path.read_bytes()
        self.edit(content="Concurrent source change")()
        with self.assertRaisesRegex(Blocked, "files, HEAD or index"):
            self.cycle.recover_review(path)
        self.assertEqual(self.state["phase"], "code")
        self.assertEqual(path.read_bytes(), saved)
        self.assertFalse((self.store.directory / "recoveries").exists())

    def test_prefaced_report_recovery_preserves_artifact_and_review_gates(self):
        path = self.rejected_coding_fixture()
        result = json.loads(path.read_bytes())
        result["raw"] = "Final report follows.\n\n" + result["raw"]
        path.write_bytes(encode(result))
        saved, snapshot = path.read_bytes(), self.repo.snapshot()
        self.cycle.recover_review(path)
        self.assertEqual(self.state["phase"], "astra")
        self.assertEqual((self.state["astra_clean"], self.state["claude_clean"]), (0, 0))
        self.assertEqual(self.state["code_report"], result["raw"])
        self.assertEqual(path.read_bytes(), saved)
        self.assertEqual(self.repo.snapshot(), snapshot)

    def test_new_implementation_report_advances_to_reviews_without_healer(self):
        self.transport.actions = [("coordinate", report()), ("code", self.edit(substantial=True))]
        control = self.focus_control()
        def finish_review():
            self.stop_request(control)
            return report()
        self.transport.actions += [("coordinate", report()), ("astra", finish_review)]
        self.assertEqual(self.cycle.run(), 0)
        self.assertEqual([role for role, _ in self.transport.calls], ["coordinate", "code", "coordinate", "astra"])
        self.assertEqual(self.state["astra_clean"], 1)

    def test_recovered_code_still_requires_all_review_passes(self):
        path = self.rejected_coding_fixture()
        self.cycle.recover_review(path)
        control = self.focus_control()
        def finish_reviews():
            self.stop_request(control)
            return report()
        self.transport.calls.clear()
        self.transport.actions = [("coordinate", report()), *[("astra", report())] * 3,
                                  ("coordinate", report()), ("claude", report()), ("claude", finish_reviews)]
        self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(self.state["phase"], "publish")
        self.assertEqual([role for role, _ in self.transport.calls],
                         ["coordinate", "astra", "astra", "astra", "coordinate", "claude", "claude"])

    def test_review_recovery_rejects_working_tree_and_index_drift(self):
        path = self.rejected_coding_fixture()
        self.repo.git("add", "source.txt")
        with self.assertRaisesRegex(Blocked, "files, HEAD or index"):
            self.cycle.recover_review(path)
        self.assertEqual(self.state["phase"], "code")
        self.assertFalse((self.store.directory / "recoveries").exists())

    def test_review_recovery_rejects_wrong_role_iteration_or_incomplete_report(self):
        path = self.rejected_coding_fixture()
        intent_path = path.parent / "intent.json"
        intent = json.loads(intent_path.read_text())
        for field, value in (("role", "heal"), ("iteration", 99), ("id", "wrong")):
            with self.subTest(field=field):
                intent_path.write_bytes(encode(dict(intent, **{field: value})))
                with self.assertRaises(Blocked):
                    self.cycle.recover_review(path)
        intent_path.write_bytes(encode(intent))
        result = json.loads(path.read_text())
        result["raw"] = json.dumps(report(status="blocked"))
        path.write_bytes(encode(result))
        with self.assertRaisesRegex(Blocked, "did not report a completed stage"):
            self.cycle.recover_review(path)
        self.assertEqual(self.state["phase"], "code")

    def test_review_recovery_rejects_external_source_and_wrong_phase(self):
        path = self.rejected_coding_fixture()
        external = Path(self.temp.name) / "result.json"
        external.write_bytes(path.read_bytes())
        with self.assertRaisesRegex(Blocked, "repository's saved code"):
            self.cycle.recover_review(external)
        for phase in ("astra", "claude", "publish", "ci"):
            self.state["phase"] = phase
            with self.subTest(phase=phase), self.assertRaisesRegex(Blocked, "stopped, already-started code"):
                self.cycle.recover_review(path)

    def test_recovery_coordinator_context_allows_report_finalization(self):
        self.rejected_coding_fixture()
        prompt = self.cycle.context("coordinate")
        self.assertIn("reconstructing its lost/rejected final report", prompt)
        self.assertIn("Confirm that report-finalization route", prompt)

    def test_review_recovery_preserves_protected_work_guard(self):
        path = self.rejected_coding_fixture()
        self.state["protected"] = ["source.txt"]
        with self.assertRaisesRegex(Blocked, "Pre-existing work was changed"):
            self.cycle.recover_review(path)
        self.assertFalse((self.store.directory / "recoveries").exists())

    @unittest.skipIf(os.name == "nt", "Directory symlink fixtures require POSIX privileges")
    def test_review_recovery_rejects_symlinked_external_artifact_directories(self):
        path = self.rejected_coding_fixture()
        external = Path(self.temp.name) / "external-invocations"
        path.parent.parent.rename(external)
        (self.store.directory / "invocations").symlink_to(external, target_is_directory=True)
        with self.assertRaisesRegex(Blocked, "repository's saved code"):
            self.cycle.recover_review(path)
        (self.store.directory / "invocations").unlink()
        external.rename(self.store.directory / "invocations")
        archive = Path(self.temp.name) / "external-archive"
        archive.mkdir()
        (self.store.directory / "recoveries").symlink_to(archive, target_is_directory=True)
        with self.assertRaisesRegex(Blocked, "archive directory resolves outside"):
            self.cycle.recover_review(path)
        self.assertEqual(list(archive.iterdir()), [])
        self.assertEqual(self.state["phase"], "code")

    def test_recover_command_obeys_pause_without_launching_model(self):
        import cc_focus
        path = self.rejected_coding_fixture()
        pause = self.root / ".work" / "PAUSE"
        pause.touch()
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.Lease") as lease, \
             patch("cycle_transport.Transport.run", side_effect=AssertionError("No model may run")), \
             contextlib.redirect_stderr(io.StringIO()):
            lease.return_value.__enter__.return_value.pwsh = "pwsh"
            self.assertEqual(cc_focus.main(["recover", "--review-from", str(path)]), 3)
        self.assertEqual(self.store.read()["phase"], "code")
        self.assertTrue(pause.exists())
        self.assertFalse((self.store.directory / "recoveries").exists())

    def test_recover_command_starts_no_model_and_exits_paused(self):
        import cc_focus
        path = self.rejected_coding_fixture()
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.Lease") as lease, \
             patch("cc_focus.Cycle.run", side_effect=AssertionError("Recovery must not start processing")), \
             patch("cycle_transport.Transport.run", side_effect=AssertionError("No model may run")):
            lease.return_value.__enter__.return_value.pwsh = "pwsh"
            self.assertEqual(cc_focus.main(["recover", "--review-from", str(path)]), 0)
        self.assertEqual(self.store.read()["status"], "paused")
        self.assertEqual(self.store.read()["phase"], "astra")

    def test_recover_command_rejects_ambiguous_arguments(self):
        import cc_focus
        for argv in (["recover"], ["--review-from", "result.json"],
                     ["recover", "--review-from", "result.json", "--retry"],
                     ["status", "--review-from", "result.json"]):
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                cc_focus.main(argv)
            self.assertEqual(error.exception.code, 2)

    def test_correction_preserves_stage_sessions_work_and_restarts_reviews(self):
        old_result = self.rejected_coding_fixture()
        self.state.update(phase="claude", astra_passes=3, astra_clean=3, claude_clean=1,
                          reviewed=self.repo.snapshot())
        before = self.repo.snapshot()
        self.cycle.correct("Keep the existing stage; handle empty input explicitly.")
        self.assertEqual(self.state["phase"], "code")
        self.assertEqual(self.state["status"], "paused")
        self.assertEqual(self.state["iteration"], 1)
        self.assertEqual(self.repo.snapshot(), before)
        self.assertEqual(self.state["sessions"]["code"], "preserved-code-session")
        self.assertEqual((self.state["astra_clean"], self.state["claude_clean"]), (0, 0))
        self.assertIsNone(self.state["pending"])
        self.assertIsNone(self.state["blocker"])
        self.assertIsNone(self.state["reviewed"])
        correction = self.store.read()["corrections"][0]
        self.assertIn("empty input", Path(correction["path"]).read_text())
        self.assertEqual(json.loads(Path(correction["archive"]).read_text())["previous_state"]["phase"], "claude")
        for role in ("coordinate", "code", "astra", "claude", "heal"):
            self.assertIn(correction["id"], self.cycle.context(role))
            self.assertIn("Do not select the next unfinished", self.cycle.context(role))
        with self.assertRaisesRegex(Blocked, "not a coding result"):
            self.cycle.recover_review(old_result)

    def test_corrected_cycle_requires_coding_and_all_reviews_before_publication(self):
        self.remote()
        self.rejected_coding_fixture()
        self.cycle.correct("Address the missing edge case.")
        correction_id = self.state["correction_revision"]
        self.transport.actions = [
            ("coordinate", report()), ("code", self.edit(content="corrected\n")),
            ("coordinate", report()), *[("astra", report())] * 3,
            ("coordinate", report()), *[("claude", report())] * 2,
            ("coordinate", report()), ("publish", self.commit_stage),
            ("coordinate", report(status="complete")),
        ]
        self.transport.calls.clear()
        self.assertEqual(self.cycle.run(), 0)
        self.assertEqual([role for role, _ in self.transport.calls if role != "coordinate"],
                         ["code", "astra", "astra", "astra", "claude", "claude", "publish"])
        archived = json.loads((self.store.directory / "iterations/000001.json").read_text())
        self.assertEqual(archived["correction_revision"], correction_id)
        self.assertIsNone(archived["correction_pending"])
        self.assertEqual(self.state["corrections"], [])
        self.assertNotIn(correction_id, self.transport.calls[-1][1])

    def test_correction_cannot_be_skipped_by_complete_or_a_cached_result(self):
        self.rejected_coding_fixture()
        self.cycle.correct("Apply this before completing the stage.")
        self.transport.actions = [("code", report(status="complete"))]
        with self.assertRaisesRegex(Blocked, "cannot bypass"):
            self.cycle.invoke("code")
        previous = dict(self.state["pending"])
        self.cycle.correct("Second correction after interruption.")
        self.transport.actions = [("code", report())]
        self.cycle.invoke("code")
        self.assertNotEqual(self.state["pending"]["id"], previous["id"])
        self.assertNotEqual(self.state["pending"]["correction_revision"], previous["correction_revision"])
        self.assertEqual(len(self.state["corrections"]), 2)
        self.assertTrue((self.store.directory / "invocations" / previous["id"] / "result.json").exists())

    def test_correction_rejects_unstarted_published_and_committed_stages(self):
        with self.assertRaisesRegex(Blocked, "No started stage"):
            self.cycle.correct("Correction")
        self.rejected_coding_fixture()
        for updates in ({"phase": "ci"}, {"phase": "publish"}, {"published": {"sha": "published"}}):
            original = dict(self.state)
            self.state.update(updates)
            with self.subTest(updates=updates), self.assertRaisesRegex(Blocked, "Publication may have started"):
                self.cycle.correct("Correction")
            self.state.clear()
            self.state.update(original)
        self.repo.git("add", "source.txt")
        self.repo.git("commit", "-m", "Preserved interrupted publication")
        with self.assertRaisesRegex(Blocked, "HEAD changed"):
            self.cycle.correct("Correction")
        self.assertFalse((self.store.directory / "corrections").exists())

    def test_correction_is_durable_but_a_failed_state_save_does_not_acknowledge_it(self):
        self.rejected_coding_fixture()
        previous = self.store.read()
        with patch.object(self.store, "save", side_effect=OSError("simulated crash")):
            with self.assertRaises(OSError):
                self.cycle.correct("Keep until safely acknowledged.")
        self.assertEqual(self.store.read(), previous)
        self.assertEqual(self.state, previous)
        self.assertEqual(len(list((self.store.directory / "corrections").glob("*.md"))), 1)
        self.state.clear()
        self.state.update(self.store.read())
        self.cycle.correct("Accepted on retry.")
        revision = self.state["correction_revision"]
        self.assertEqual(self.store.read()["correction_pending"], revision)
        Path(self.state["corrections"][0]["path"]).write_text("tampered")
        with self.assertRaisesRegex(Blocked, "immutable operator correction"):
            self.cycle.context("code")

    def test_correct_command_accepts_file_and_starts_no_model(self):
        import cc_focus
        self.rejected_coding_fixture()
        path = Path(self.temp.name) / "operator correction.md"
        path.write_text("Поправка: сохранить текущую стадию.", encoding="utf-8-sig")
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.Lease") as lease, \
             patch("cc_focus.Cycle.run", side_effect=AssertionError("No processing")), \
             patch("cycle_transport.Transport.run", side_effect=AssertionError("No model")):
            lease.return_value.__enter__.return_value.pwsh = "pwsh"
            self.assertEqual(cc_focus.main(["correct", "--file", str(path)]), 0)
        saved = self.store.read()
        self.assertEqual(saved["status"], "paused")
        self.assertEqual(Path(saved["corrections"][0]["path"]).read_text(encoding="utf-8"), "Поправка: сохранить текущую стадию.")
        path.write_text("Changed external source", encoding="utf-8")
        self.assertNotIn("Changed external", Path(saved["corrections"][0]["path"]).read_text())

    def test_correct_command_rejects_active_runtime_and_ambiguous_arguments(self):
        import cc_focus
        for argv in (["correct"], ["--message", "x"], ["correct", "--message", "x", "--file", "x"],
                     ["correct", "--message", "x", "--retry"], ["stop", "--output", "compact"]):
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                cc_focus.main(argv)
        self.rejected_coding_fixture()
        before = self.store.read()
        with LocalLock(self.store.directory), patch("cc_focus.Path.cwd", return_value=self.root), \
             contextlib.redirect_stderr(io.StringIO()), patch("cc_focus.Lease") as lease:
            self.assertEqual(cc_focus.main(["correct", "--message", "x"]), 3)
            lease.assert_not_called()
        self.assertEqual(self.store.read(), before)

    def test_correction_rejects_empty_oversized_and_protected_changes(self):
        self.rejected_coding_fixture()
        for value in (" ", "x" * 65537, "bad\0text"):
            with self.subTest(size=len(value)), self.assertRaisesRegex(Blocked, "nonempty UTF-8"):
                self.cycle.correct(value)
        self.state["protected"] = ["source.txt"]
        with self.assertRaisesRegex(Blocked, "Pre-existing work"):
            self.cycle.correct("Keep protected work intact.")

    def test_correction_context_is_checked_even_when_replaying_a_saved_result(self):
        self.rejected_coding_fixture()
        self.cycle.correct("Preserve the new requirement.")
        self.transport.actions = [("code", report())]
        self.cycle.invoke("code")
        self.transport.actions.clear()
        archive = Path(self.state["corrections"][0]["archive"])
        archive.write_text("broken stage context")
        with self.assertRaisesRegex(Blocked, "immutable operator correction"):
            self.cycle.invoke("code")
        with self.assertRaisesRegex(Blocked, "immutable operator correction"):
            self.cycle.recover_review(self.store.directory / "invocations" / self.state["pending"]["id"] / "result.json")
        self.assertIsNotNone(self.state["correction_pending"])

    def test_correction_survives_clean_sessions_and_retry(self):
        import cc_focus
        self.rejected_coding_fixture()
        self.cycle.correct("Preserve across conversation replacement.")
        saved = self.store.read()
        saved["blocker"] = {"signature": "temporary"}
        self.store.save(saved)
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.Lease") as lease, \
             patch("cc_focus.Cycle.run", return_value=0):
            lease.return_value.__enter__.return_value.pwsh = "pwsh"
            self.assertEqual(cc_focus.main(["--new-sessions", "--retry"]), 0)
        current = self.store.read()
        self.assertEqual(current["sessions"], {})
        self.assertEqual(current["corrections"], saved["corrections"])
        self.assertEqual(current["correction_pending"], saved["correction_pending"])
        self.assertEqual(current["phase"], "code")

    def test_correction_rejects_pause_invalid_utf8_and_oversized_file(self):
        import cc_focus
        self.rejected_coding_fixture()
        source = Path(self.temp.name) / "correction.md"
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.Lease") as lease, \
             patch("cycle_transport.Transport.run", side_effect=AssertionError("No model")), \
             contextlib.redirect_stderr(io.StringIO()):
            lease.return_value.__enter__.return_value.pwsh = "pwsh"
            for content in (b"\xff\xfeinvalid", b"x" * 65537):
                source.write_bytes(content)
                self.assertEqual(cc_focus.main(["correct", "--file", str(source)]), 3)
            pause = self.root / ".work/PAUSE"
            pause.touch()
            self.assertEqual(cc_focus.main(["correct", "--message", "x"]), 3)
            self.assertTrue(pause.exists())
        self.assertFalse(self.store.read().get("corrections"))

    def test_completed_corrected_coding_result_can_recover_into_fresh_reviews(self):
        self.rejected_coding_fixture()
        self.cycle.correct("Recover only the corrected result.")
        self.transport.actions = [("code", report())]
        self.cycle.invoke("code")
        source = self.store.directory / "invocations" / self.state["pending"]["id"] / "result.json"
        self.cycle.recover_review(source)
        self.assertIsNone(self.state["correction_pending"])
        self.assertEqual(self.state["phase"], "astra")
        self.assertEqual((self.state["astra_clean"], self.state["claude_clean"]), (0, 0))

    @unittest.skipIf(os.name == "nt", "POSIX directory symlink fixture")
    def test_correction_archive_cannot_escape_runtime_directory(self):
        self.rejected_coding_fixture()
        external = Path(self.temp.name) / "external"
        external.mkdir()
        (self.store.directory / "corrections").symlink_to(external, target_is_directory=True)
        with self.assertRaisesRegex(Blocked, "resolves outside"):
            self.cycle.correct("Do not write outside runtime state.")
        self.assertEqual(list(external.iterdir()), [])

    @unittest.skipIf(os.name == "nt", "POSIX native root/lease integration fixture")
    def test_recover_wrapper_acquires_and_releases_real_lease_without_provider(self):
        cli = Path(shutil.which("processkit-cli") or
                   (Path(os.environ.get("ORCHESTRA_HOME", Path.home() / ".orchestra")) / "processkit-cli"))
        if not cli.is_file():
            self.skipTest("Optional installed ProcessKit CLI is unavailable")
        path = self.rejected_coding_fixture()
        config = Path(self.temp.name) / "isolated-runtime"
        config.mkdir()
        (config / "root-config.md").write_text(f"CC_PROCESSKIT_CLI: {cli}\n", encoding="utf-8")
        forbidden = config / "provider-called"
        for name in ("codex", "claude"):
            executable = config / name
            executable.write_text('#!/bin/sh\nprintf unexpected > "$ORCHESTRA_FIXTURE_CALLED"\nexit 97\n')
            executable.chmod(0o755)
        env = dict(os.environ, ORCHESTRA_HOME=str(config), ORCHESTRA_PROCESSKIT_ROOT_RUN_ID="",
                   ORCHESTRA_FIXTURE_CALLED=str(forbidden), PATH=str(config) + os.pathsep + os.environ["PATH"])
        result = subprocess.run(["pwsh", "-NoProfile", "-File", str(REPO / "tools/focus-runtime.ps1"),
                                 "recover", "--review-from", str(path)],
                                cwd=self.root, env=env, capture_output=True, timeout=45)
        self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
        self.assertFalse(forbidden.exists())
        self.assertFalse(runtime_active(self.store))
        self.assertFalse((self.root / ".work/orchestrator.lock/lease.json").exists())
        self.assertEqual(self.store.read()["phase"], "astra")
        self.assertEqual(self.store.read()["status"], "paused")

        correction = subprocess.run(["pwsh", "-NoProfile", "-File", str(REPO / "tools/focus-runtime.ps1"),
                                     "correct", "--message", "Keep the recovered stage; add an edge case."],
                                    cwd=self.root, env=env, capture_output=True, timeout=45)
        self.assertEqual(correction.returncode, 0, (correction.stdout, correction.stderr))
        self.assertFalse(forbidden.exists())
        self.assertFalse(runtime_active(self.store))
        self.assertFalse((self.root / ".work/orchestrator.lock/lease.json").exists())
        self.assertEqual(self.store.read()["phase"], "code")
        self.assertIsNotNone(self.store.read()["correction_pending"])

    def test_full_cycle_is_serial_with_full_coding_description(self):
        self.remote()
        self.transport.actions = [
            ("coordinate", report()), ("code", self.edit(description="Full unabridged implementation description")),
            ("coordinate", report()), *[("astra", report())] * 3,
            ("coordinate", report()), *[("claude", report())] * 2,
            ("coordinate", report()), ("publish", self.commit_stage),
            ("coordinate", report(status="complete")),
        ]
        with patch.object(self.cycle, "wait_ci", wraps=self.cycle.wait_ci) as wait:
            self.assertEqual(self.cycle.run(), 0)
            wait.assert_called_once()
        self.assertEqual(self.state["iteration"], 2)
        self.assertEqual(self.state["status"], "complete")
        for role, prompt in self.transport.calls:
            if role == "astra":
                self.assertIn("Full unabridged implementation description", prompt)
            if role == "coordinate":
                self.assertNotIn("Full unabridged implementation description", prompt)

    def test_astra_counter_changes_after_third_pass(self):
        self.state.update(phase="astra", coordinated="astra")
        for index, other in enumerate((0, 0, 1, 1, 1, 1), start=1):
            self.transport.actions.append(("astra", report(other_fixes=other)))
            self.cycle.review("astra")
            if index == 3:
                self.assertEqual(self.state["astra_clean"], 0)
        self.assertEqual(self.state["astra_clean"], 3)
        self.assertEqual(self.state["phase"], "claude")

    def test_minor_edits_do_not_reset_clean_passes(self):
        self.state.update(phase="astra", coordinated="astra")
        self.transport.actions = [("astra", self.edit(content=str(i), minor_edits=1)) for i in range(3)]
        for _ in range(3):
            self.cycle.review("astra")
        self.assertEqual(self.state["phase"], "claude")

    def test_substantial_claude_fixes_return_to_astra(self):
        self.state.update(phase="claude", astra_passes=3, astra_clean=3, claude_clean=1)
        self.transport.actions = [("claude", self.edit(implementation_fixes=1, substantial=True))]
        self.cycle.review("claude")
        self.assertEqual(self.state["phase"], "astra")
        self.assertEqual(self.state["astra_clean"], 0)
        self.assertEqual(self.state["claude_clean"], 0)

    def test_failed_or_unreported_review_does_not_count(self):
        self.state.update(phase="astra", astra_clean=1)
        self.transport.actions = [("astra", self.edit())]
        with self.assertRaisesRegex(Blocked, "reported no changes"):
            self.cycle.review("astra")
        self.assertEqual(self.state["astra_clean"], 1)

    def test_coder_cannot_commit(self):
        def bad_coder():
            self.edit()()
            self.repo.git("commit", "-am", "Unexpected commit")
            return report()
        self.transport.actions = [("code", bad_coder)]
        with self.assertRaisesRegex(Blocked, "outside publication"):
            self.cycle.invoke("code")

    def test_protected_work_is_not_overwritten(self):
        self.edit(content="operator WIP")()
        self.state = fresh_state(self.repo)
        self.cycle.state = self.state
        self.transport.actions = [("code", self.edit(content="clobbered"))]
        with self.assertRaisesRegex(Blocked, "Pre-existing"):
            self.cycle.invoke("code")

    def test_recorded_result_replays_without_provider(self):
        self.transport.actions = [("astra", report())]
        self.state["phase"] = "astra"
        self.cycle.invoke("astra")
        pending_id = self.state["pending"]["id"]
        self.cycle.review("astra")
        self.assertEqual(len(self.transport.calls), 1)
        self.assertEqual(self.state["astra_clean"], 1)
        self.assertTrue((self.store.directory / "invocations" / pending_id / "result.json").exists())

    def test_pause_stops_before_any_provider(self):
        self.store.directory.mkdir(parents=True)
        (self.root / ".work" / "PAUSE").write_text("operator stop")
        self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(self.state["status"], "paused")
        self.assertFalse(self.transport.calls)

    def test_blocker_heals_once_then_escalates_without_spin(self):
        self.state.update(phase="astra", coordinated="astra")
        problem = Blocked("fixture", "same unavailable dependency")
        self.transport.actions = [("astra", problem), ("heal", report()),
                                  ("coordinate", report()), ("astra", problem)]
        self.assertEqual(self.cycle.run(), 3)
        self.assertEqual([role for role, _ in self.transport.calls].count("heal"), 1)
        self.assertEqual(self.state["blocker"]["escalation_reason"], "verification-failed")
        self.transport.calls.clear()
        self.assertEqual(self.cycle.run(), 3)
        self.assertFalse(self.transport.calls)

    def test_healer_fix_invalidates_review_seal(self):
        self.state.update(phase="publish", reviewed=self.repo.snapshot(), blocker={"phase": "publish", "status": "healing"})
        self.transport.actions = [("heal", self.edit(implementation_fixes=1, substantial=True))]
        self.cycle.heal()
        self.assertEqual(self.state["phase"], "astra")
        self.assertIsNone(self.state["reviewed"])

    def test_changing_error_details_cannot_spin_recovery(self):
        self.state.update(phase="astra", coordinated="astra")
        self.transport.actions = [("astra", Blocked("dependency", "failed request at timestamp one")),
                                  ("heal", report()), ("coordinate", report()),
                                  ("astra", Blocked("dependency", "failed request at timestamp two"))]
        self.assertEqual(self.cycle.run(), 3)
        self.assertEqual([role for role, _ in self.transport.calls].count("heal"), 1)
        self.assertEqual(self.state["blocker"]["status"], "blocked")

    def test_healer_dependency_fix_returns_to_unfinished_coding(self):
        self.state.update(phase="code", code_started=True, blocker={"phase": "code", "status": "healing"})
        self.transport.actions = [("heal", self.edit(implementation_fixes=1, substantial=True)), ("code", report())]
        self.cycle.heal()
        self.assertEqual(self.state["phase"], "code")
        self.cycle.invoke("code")
        self.assertIn("Finish that SAME stage", self.transport.calls[-1][1])

    def test_command_timeout_is_distinct_from_missing_executable(self):
        argv = ["git", "ls-remote", "https://secret@example.invalid/repo"]
        for failure, code in ((subprocess.TimeoutExpired(argv, 60), "command-timeout"),
                              (FileNotFoundError("git not found"), "command-unavailable")):
            with self.subTest(code=code), patch("cycle_state.subprocess.run", side_effect=failure):
                with self.assertRaises(Blocked) as raised:
                    command(argv, self.root)
                self.assertEqual(raised.exception.code, code)
                self.assertNotIn("secret", str(raised.exception))

    def test_remote_query_retries_timeout_and_uses_only_successful_evidence(self):
        url = "https://example.invalid/repo"
        sha = self.state["baseline"]["head"]
        timed_out = subprocess.TimeoutExpired(["git", "ls-remote", url], 60,
                                              output=b"unconfirmed\trefs/heads/main\n")
        success = subprocess.CompletedProcess([], 0, f"{sha}\trefs/heads/main\n".encode(), b"")
        attempts = []
        with patch.object(self.repo, "push_url", return_value=url), \
                patch("cycle_state.subprocess.run", side_effect=[timed_out, success]) as run, \
                patch("cycle_state.time.sleep") as sleep:
            self.assertEqual(self.repo.remote_head("origin", progress=lambda *args: attempts.append(args)), sha)
        self.assertEqual(attempts, [(1, 3), (2, 3)])
        self.assertEqual(run.call_count, 2)
        sleep.assert_called_once_with(2)
        self.assertEqual(run.call_args.args[0], ["git", "ls-remote", "--refs", url, "refs/heads/main"])

    def test_remote_query_timeout_exhaustion_never_accepts_partial_output(self):
        url = "https://secret@example.invalid/repo"
        timed_out = subprocess.TimeoutExpired(["git", "ls-remote", url], 60,
                                              output=b"unconfirmed\trefs/heads/main\n")
        with patch.object(self.repo, "push_url", return_value=url), \
                patch("cycle_state.subprocess.run", side_effect=timed_out) as run, \
                patch("cycle_state.time.sleep") as sleep:
            with self.assertRaises(Blocked) as raised:
                self.repo.remote_head("origin")
        self.assertEqual(raised.exception.code, "remote-query-timeout")
        self.assertIn("3/3 attempts", str(raised.exception))
        self.assertNotIn("secret", str(raised.exception))
        self.assertEqual(run.call_count, 3)
        self.assertEqual(sleep.call_count, 2)

    def test_remote_query_retries_transient_network_errors(self):
        sha = self.state["baseline"]["head"]
        success = subprocess.CompletedProcess([], 0, f"{sha}\trefs/heads/main\n".encode(), b"")
        for detail in (b"fatal: Could not resolve host: example.invalid",
                       b"fatal: Failed to connect to example.invalid port 443",
                       b"fatal: The requested URL returned error: 503"):
            with self.subTest(detail=detail), patch.object(self.repo, "push_url", return_value="fixture"), \
                    patch("cycle_state.subprocess.run", side_effect=[
                        subprocess.CompletedProcess([], 128, b"", detail), success]) as run, \
                    patch("cycle_state.time.sleep"):
                self.assertEqual(self.repo.remote_head("origin"), sha)
                self.assertEqual(run.call_count, 2)

    def test_remote_query_authentication_failure_stops_without_retry_or_env_mutation(self):
        url = "https://secret@example.invalid/repo"
        original_env = dict(os.environ)
        failure = subprocess.CompletedProcess([], 128, b"", f"fatal: Authentication failed for '{url}'".encode())
        with patch.object(self.repo, "push_url", return_value=url), \
                patch("cycle_state.subprocess.run", return_value=failure) as run, \
                patch("cycle_state.time.sleep") as sleep:
            with self.assertRaises(Blocked) as raised:
                self.repo.remote_head("origin")
        self.assertEqual(raised.exception.code, "remote-query-failed")
        self.assertIn("Authentication failed", str(raised.exception))
        self.assertNotIn("secret", str(raised.exception))
        run.assert_called_once()
        sleep.assert_not_called()
        self.assertEqual(run.call_args.kwargs["env"]["GIT_TERMINAL_PROMPT"], "0")
        self.assertEqual(run.call_args.kwargs["env"]["GCM_INTERACTIVE"], "Never")
        self.assertEqual(dict(os.environ), original_env)

    def test_remote_query_missing_or_ambiguous_main_is_not_retried(self):
        for output in (b"", b"one\trefs/heads/main\ntwo\trefs/heads/main\n"):
            with self.subTest(output=output), patch.object(self.repo, "push_url", return_value="fixture"), \
                    patch("cycle_state.subprocess.run", return_value=subprocess.CompletedProcess([], 0, output, b"")) as run, \
                    patch("cycle_state.time.sleep") as sleep:
                with self.assertRaises(Blocked) as raised:
                    self.repo.remote_head("origin")
                self.assertEqual(raised.exception.code, "remote-main")
                run.assert_called_once()
                sleep.assert_not_called()

    def test_remote_failure_tries_healing_and_preserves_publish_reviews(self):
        self.remote()
        self.edit()()
        reviewed = self.repo.snapshot()
        self.state.update(phase="publish", coordinated="publish", reviewed=reviewed, last_snapshot=reviewed,
                          astra_clean=3, claude_clean=2, sessions={"codex": "saved-session"})
        for code in ("remote-query-timeout", "remote-query-failed"):
            with self.subTest(code=code), patch.object(self.repo, "remote_head", side_effect=Blocked(code, "Remote unavailable")):
                self.state.update(blocker=None, status="ready", healed=[], recovery_unverified=False)
                self.transport.calls.clear()
                self.transport.actions = [("heal", report(status="blocked", summary="Existing credentials cannot access the remote"))]
                self.assertEqual(self.cycle.run(), 3)
                saved = self.store.read()
                self.assertEqual(saved["phase"], "publish")
                self.assertEqual(saved["blocker"]["status"], "blocked")
                self.assertEqual(saved["reviewed"], reviewed)
                self.assertEqual((saved["astra_clean"], saved["claude_clean"]), (3, 2))
                self.assertEqual(saved["sessions"], {"codex": "saved-session"})
                self.assertIsNone(saved["published"])
                self.assertEqual(len(saved["healed"]), 1)
                self.assertEqual([role for role, _ in self.transport.calls], ["heal"])
                self.assertEqual(saved["blocker"]["escalation_reason"], "healer-failed")
                self.assertEqual(self.repo.snapshot(), reviewed)

    def test_remote_failure_after_push_reconciles_without_another_publisher(self):
        self.remote()
        self.edit()()
        reviewed = self.repo.snapshot()
        self.state.update(phase="publish", coordinated="publish", reviewed=reviewed, last_snapshot=reviewed,
                          remote="origin", astra_clean=3, claude_clean=2)
        self.commit_stage()
        with patch.object(self.repo, "remote_head", side_effect=Blocked("remote-query-timeout", "Timed out")):
            with self.assertRaises(Blocked) as raised:
                self.cycle.reconcile_publish()
            self.cycle.handle_block(raised.exception)
        self.assertEqual(self.state["status"], "healing")
        self.assertIsNone(self.state["published"])
        self.state.update(blocker=None, status="ready")
        with patch.object(self.cycle, "policy", return_value=subprocess.CompletedProcess([], 0)):
            self.cycle.publish()
        self.assertEqual(self.state["phase"], "ci")
        self.assertEqual(self.state["published"]["sha"], self.repo.text("rev-parse", "HEAD"))
        self.assertFalse(self.transport.calls)

    def test_retry_legacy_git_timeout_preserves_publication_phase_and_review_credit(self):
        import cc_focus
        self.edit()()
        reviewed = self.repo.snapshot()
        self.state.update(phase="publish", coordinated="publish", reviewed=reviewed, last_snapshot=reviewed,
                          astra_clean=3, claude_clean=2, sessions={"codex": "saved-session"}, recovery_unverified=True)
        self.cycle.handle_block(Blocked("command-unavailable", "git: ls-remote timed out after 60 seconds"))
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.Lease") as lease, \
                patch("cc_focus.Cycle.run", return_value=0):
            lease.return_value.__enter__.return_value.pwsh = "pwsh"
            self.assertEqual(cc_focus.main(["--retry", "--ui", "off"]), 0)
        current = self.store.read()
        self.assertIsNone(current["blocker"])
        self.assertEqual(current["phase"], "publish")
        self.assertEqual(current["reviewed"], reviewed)
        self.assertEqual((current["astra_clean"], current["claude_clean"]), (3, 2))
        self.assertEqual(current["sessions"], {"codex": "saved-session"})

    def test_remote_query_progress_does_not_report_a_running_coordinator(self):
        self.remote()
        self.cycle.progress = Progress(self.store, self.state)
        self.cycle.progress.role = "coordinate"
        self.assertEqual(self.cycle.remote_head("origin"), self.state["baseline"]["head"])
        progress = json.loads((self.store.directory / "progress.json").read_text())
        self.assertIsNone(progress["role"])
        self.assertIn("Checking remote main", progress["activity"])

    def test_push_response_loss_reconciles_without_duplicate_commit(self):
        self.remote()
        self.edit()()
        self.state.update(phase="publish", reviewed=self.repo.snapshot(), remote="origin")
        self.commit_stage()
        head = self.repo.text("rev-parse", "HEAD")
        self.assertTrue(self.cycle.reconcile_publish())
        self.assertEqual(self.state["published"]["sha"], head)
        self.assertFalse(self.transport.calls)

    def test_publish_hook_content_change_requires_review(self):
        self.remote()
        self.edit()()
        self.state.update(phase="publish", reviewed=self.repo.snapshot(), remote="origin")
        self.edit(content="unreviewed hook output")()
        self.assertFalse(self.cycle.prepare_publish())
        self.assertEqual(self.state["phase"], "astra")

    def test_wrong_sha_and_pending_ci_cannot_pass(self):
        self.remote()
        self.state["reviewed"] = self.repo.snapshot()
        self.state["published"] = {"sha": self.repo.text("rev-parse", "HEAD"), "remote": "origin", "at": 0}
        workflows = self.root / ".github" / "workflows"
        workflows.mkdir(parents=True)
        (workflows / "ci.yml").write_text("on: push")
        self.repo.git("add", ".github/workflows/ci.yml")
        self.repo.git("commit", "-m", "Configure CI")
        self.repo.git("push", "origin", "main")
        self.state["published"]["sha"] = self.repo.text("rev-parse", "HEAD")
        self.state["reviewed"] = self.repo.snapshot()
        with patch.object(self.cycle, "ci_gate", return_value={"verdict": "no-required-checks"}), \
             patch.object(self.cycle, "github", return_value=("github.com", "owner/repo")), \
             patch("cycle_workflow.command"), \
             patch.object(self.cycle, "gh_records", return_value=[{
                 "name": "CI", "head_sha": "wrong", "status": "completed", "conclusion": "success", "run_id": 1}]):
            with self.assertRaisesRegex(Blocked, "within 30 minutes"):
                self.cycle.wait_ci()

    def test_protocols_pin_models_efforts_and_resume_exact_sessions(self):
        self.store.save(self.state)
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        for provider in ("codex", "claude"):
            transport.commands[provider] = [sys.executable, str(Path(__file__).resolve()), "fixture", provider]
        for role in ("code", "astra", "coordinate", "claude", "publish", "heal"):
            for attempt in range(2):
                invocation = {"id": role + str(attempt)}
                directory = self.store.directory / invocation["id"]
                directory.mkdir()
                raw = transport.run(role, "fixture prompt", invocation, directory)
                self.assertEqual(parse_report(raw)["status"], "done")
                prompt = (directory / "prompt.txt").read_text(encoding="utf-8")
                self.assertIn("The project plan referenced in the handoff is the source of stages.", prompt)
                self.assertIn("Read the current project plan before selecting the next unfinished stage", prompt)
                self.assertIn("report blocked; do not invent work", prompt)
        self.assertEqual(len(set(self.state["sessions"].values())), 6)

    def test_failed_ci_never_starts_next_stage(self):
        self.remote()
        self.edit()()
        self.state.update(phase="publish", reviewed=self.repo.snapshot(), remote="origin")
        self.commit_stage()
        self.cycle.reconcile_publish()
        self.transport.actions = [("heal", report(status="blocked"))]
        with patch.object(self.cycle, "wait_ci", side_effect=Blocked("ci-failed", "Tests failed")), \
             patch.object(self.cycle, "next_stage") as advance:
            self.assertEqual(self.cycle.run(), 3)
            advance.assert_not_called()
        self.assertEqual(self.state["iteration"], 1)
        self.assertEqual([role for role, _ in self.transport.calls], ["heal"])

    def test_configured_green_ci_allows_next_iteration_only_after_wait(self):
        self.remote()
        self.edit()()
        self.state.update(phase="publish", reviewed=self.repo.snapshot(), remote="origin")
        self.commit_stage()
        self.cycle.reconcile_publish()
        sha = self.state["published"]["sha"]
        records = [{"name": "CI", "head_sha": sha, "status": "completed", "conclusion": "success", "run_id": 1}]
        self.transport.actions = [("coordinate", report(status="complete"))]
        def waiting(_):
            self.assertEqual(self.state["iteration"], 1)
            self.assertEqual(self.state["phase"], "ci")
            self.assertFalse(self.transport.calls)
        with patch.object(self.cycle, "ci_gate", return_value={"verdict": "ready"}), \
             patch.object(self.cycle, "github", return_value=("github.com", "owner/repo")), \
             patch("cycle_workflow.command"), patch("cycle_workflow.time", wraps=time) as timer, \
             patch.object(self.cycle, "gh_records", return_value=records):
            timer.sleep.side_effect = waiting
            self.assertEqual(self.cycle.run(), 0)
            timer.sleep.assert_called_once_with(30)
        self.assertEqual(self.state["iteration"], 2)

    def test_noninteractive_approval_is_not_auto_granted(self):
        class ApprovalProcess:
            def receive(self):
                return {"id": "approval", "method": "item/commandExecution/requestApproval", "params": {"command": "operation"}}
            def send(self, _):
                raise AssertionError("No approval should be fabricated")
        with patch("sys.stdin.isatty", return_value=False), self.assertRaisesRegex(Blocked, "Operator approval"):
            Rpc(ApprovalProcess())._receive()

    def test_cli_rejects_session_id_import(self):
        result = subprocess.run([sys.executable, str(REPO / "tools/cc_focus.py"), "--session-id", "fake"],
                                cwd=self.root, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.store.path.exists())

    def test_deletion_fingerprint_survives_commit(self):
        (self.root / "source.txt").unlink()
        reviewed = self.repo.snapshot()
        self.repo.git("add", "source.txt")
        self.repo.git("commit", "-m", "Remove source")
        self.assertFalse(changed(reviewed, self.repo.snapshot()))

    def test_failed_pass_resets_existing_clean_streak(self):
        self.state.update(phase="astra", astra_clean=2, pending={"id": "interrupted", "role": "astra"})
        self.cycle.handle_block(Blocked("failed-test", "Verification failed"))
        self.assertEqual(self.state["astra_clean"], 0)

    def test_external_edit_invalidates_claude_clean_streak(self):
        self.state.update(phase="claude", astra_clean=3, claude_clean=1)
        self.edit(content="external change")()
        self.transport.actions = [("coordinate", report(status="blocked")), ("heal", report(status="blocked"))]
        self.assertEqual(self.cycle.run(), 3)
        self.assertEqual(self.state["phase"], "astra")
        self.assertEqual(self.state["astra_clean"], 0)

    def test_lost_acquire_reply_uses_persisted_owner_intent(self):
        self.state["lease_owners"] = ["old-intended-owner"]
        directory = self.root / ".work" / "orchestrator.lock"
        directory.mkdir(parents=True)
        atomic_write(directory / "lease.json", encode({"owner_id": "old-intended-owner"}))
        lease = Lease(self.root, REPO / "tools", self.state, self.store.save)
        with patch.object(lease, "run", side_effect=[subprocess.CompletedProcess([], 11),
                                                   subprocess.CompletedProcess([], 0),
                                                   subprocess.CompletedProcess([], 0)]) as run:
            with lease:
                self.assertTrue(lease.held)
            takeover = run.call_args_list[1].args
            self.assertEqual(takeover[0], "takeover")
            self.assertIn("old-intended-owner", takeover)

    def test_new_sessions_preserves_pending_stage_and_work(self):
        import cc_focus
        self.state["sessions"] = {"code": "old-session"}
        self.state["pending"] = {"id": "in-flight", "role": "code", "turn_id": "old-turn"}
        self.state["code_started"] = True
        self.store.save(self.state)
        self.edit(content="unfinished stage")()
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.Lease") as lease, \
             patch("cc_focus.Cycle.run", return_value=0):
            lease.return_value.__enter__.return_value.pwsh = "pwsh"
            self.assertEqual(cc_focus.main(["--new-sessions"]), 0)
        state = self.store.read()
        self.assertEqual(state["sessions"], {})
        self.assertEqual(state["pending"]["id"], "in-flight")
        self.assertNotIn("turn_id", state["pending"])
        self.assertEqual((self.root / "source.txt").read_text(), "unfinished stage")

    def test_ci_fix_can_be_published_after_prior_commit(self):
        self.remote()
        self.edit()()
        self.state.update(phase="publish", reviewed=self.repo.snapshot(), remote="origin")
        self.commit_stage()
        self.assertTrue(self.cycle.reconcile_publish())
        self.edit(content="CI fix")()
        self.state.update(phase="publish", reviewed=self.repo.snapshot())
        self.assertFalse(self.cycle.reconcile_publish())
        self.commit_stage()
        self.assertTrue(self.cycle.reconcile_publish())

    def test_final_ci_barrier_detects_late_worktree_change(self):
        self.remote()
        self.edit()()
        self.state.update(phase="publish", reviewed=self.repo.snapshot(), remote="origin")
        self.commit_stage()
        self.cycle.reconcile_publish()
        self.edit(content="after CI changed")()
        with self.assertRaisesRegex(Blocked, "publication window"):
            self.cycle.next_stage()

    def test_operator_staging_survives_explicit_path_publication(self):
        self.remote()
        (self.root / "operator.txt").write_text("private staged work")
        self.repo.git("add", "operator.txt")
        self.state = fresh_state(self.repo)
        self.cycle.state = self.state
        self.edit()()
        self.state.update(phase="publish", reviewed=self.repo.snapshot(), remote="origin")
        self.repo.git("add", "source.txt")
        self.repo.git("commit", "--only", "-m", "Update reviewed source", "--", "source.txt")
        self.repo.git("push", "origin", "main")
        self.cycle.check_protected(self.repo.snapshot())
        self.assertTrue(self.cycle.reconcile_publish())
        self.assertEqual(self.repo.text("diff", "--cached", "--name-only"), "operator.txt")
        self.assertEqual(self.repo.git("cat-file", "-e", "HEAD:operator.txt", check=False).returncode, 128)

    def test_unstaging_protected_work_is_detected(self):
        self.edit()()
        self.repo.git("add", "source.txt")
        self.state = fresh_state(self.repo)
        self.cycle.state = self.state
        self.repo.git("restore", "--staged", "source.txt")
        with self.assertRaisesRegex(Blocked, "index entries"):
            self.cycle.check_protected(self.repo.snapshot())

    def test_changed_handoff_is_not_silently_consumed(self):
        source = self.root / "handoff.md"
        source.write_text("next stage plan")
        handoff = self.store.handoff(source)
        self.state["handoffs"] = [handoff]
        Path(handoff["path"]).write_text("unexpected replacement")
        with self.assertRaisesRegex(Blocked, "handoff snapshot"):
            self.cycle.context("coordinate")
        self.cycle.context("heal")

    def test_status_does_not_create_runtime_state(self):
        result = subprocess.run([sys.executable, str(REPO / "tools/cc_focus.py"), "status"],
                                cwd=self.root, capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertFalse(self.store.directory.exists())

    def test_green_ci_after_restart_can_finish_past_original_deadline(self):
        self.remote()
        self.state.update(reviewed=self.repo.snapshot(), published={
            "sha": self.repo.text("rev-parse", "HEAD"), "remote": "origin", "at": 0})
        sha = self.state["published"]["sha"]
        records = [{"name": "CI", "head_sha": sha, "status": "completed", "conclusion": "success", "run_id": 1}]
        with patch.object(self.cycle, "ci_gate", return_value={"verdict": "ready"}), \
             patch.object(self.cycle, "github", return_value=("github.com", "owner/repo")), \
             patch("cycle_workflow.command"), patch("cycle_workflow.time") as timer, \
             patch.object(self.cycle, "gh_records", return_value=records):
            timer.time.return_value = 3600
            self.cycle.wait_ci()
            timer.sleep.assert_called_once_with(30)

    def test_same_named_pending_workflow_cannot_hide_behind_green_check(self):
        self.remote()
        self.state.update(reviewed=self.repo.snapshot(), published={
            "sha": self.repo.text("rev-parse", "HEAD"), "remote": "origin", "at": 0})
        sha = self.state["published"]["sha"]
        records = [
            {"name": "CI", "head_sha": sha, "status": "completed", "conclusion": "success", "run_id": 20, "source": "check"},
            {"name": "CI", "head_sha": sha, "status": "in_progress", "conclusion": None, "run_id": 10, "source": "workflow"}]
        with patch.object(self.cycle, "ci_gate", return_value={"verdict": "ready"}), \
             patch.object(self.cycle, "github", return_value=("github.com", "owner/repo")), \
             patch("cycle_workflow.command"), patch.object(self.cycle, "gh_records", return_value=records):
            with self.assertRaisesRegex(Blocked, "within 30 minutes"):
                self.cycle.wait_ci()

    def test_codex_completed_turn_is_recovered_without_turn_start(self):
        self.state["sessions"]["astra"] = "known-session"
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["codex"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "codex", "recover"]
        pending = {"id": "recovered", "turn_id": "finished-turn"}
        directory = self.store.directory / "recover"
        directory.mkdir(parents=True)
        self.assertEqual(parse_report(transport.run("astra", "recover same stage", pending, directory))["status"], "done")
        log = (directory / "protocol.jsonl").read_text()
        self.assertNotIn('turn/completed', log)

    def test_stdio_server_exits_gracefully_before_cleanup(self):
        argv = [sys.executable, str(Path(__file__).resolve()), "fixture", "codex",
                "-s", "danger-full-access", "-a", "on-request", "app-server",
                "features.multi_agent=false", "features.memories=false"]
        process = Process(argv, self.root, self.root / "protocol.jsonl", lambda: None)
        Rpc(process).request("initialize", {})
        process.close()
        self.assertEqual(process.proc.returncode, 0)

    def test_all_codex_roles_disable_memory_agents_on_start_and_resume(self):
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["codex"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "codex"]
        for role in ("coordinate", "astra", "publish", "heal"):
            for attempt in range(2):
                with self.subTest(role=role, resume=bool(attempt)):
                    previous = self.state["sessions"].get(role)
                    directory = self.store.directory / (role + str(attempt))
                    directory.mkdir(parents=True)
                    pending = {"id": directory.name}
                    self.assertEqual(parse_report(transport.run(role, "Same stage", pending, directory))["status"], "done")
                    if attempt:
                        self.assertEqual(self.state["sessions"][role], previous)

    def test_interrupted_review_cannot_reuse_old_clean_streak(self):
        self.state.update(phase="astra", astra_clean=2, pending={
            "id": "interrupted-review", "role": "astra", "before": self.repo.snapshot(), "attempts": 1})
        self.edit(content="fixed before power loss")()
        self.transport.actions = [("astra", report(minor_edits=1))]
        self.cycle.review("astra")
        self.assertEqual(self.state["astra_clean"], 1)
        self.assertEqual(self.state["phase"], "astra")

    def test_uncertain_interrupted_claude_changes_return_to_astra(self):
        self.state.update(phase="claude", claude_clean=1, astra_clean=3, pending={
            "id": "interrupted-claude", "role": "claude", "before": self.repo.snapshot(), "attempts": 1})
        self.edit(content="changed before response was lost")()
        self.transport.actions = [("claude", report(minor_edits=1))]
        self.cycle.review("claude")
        self.assertEqual(self.state["phase"], "astra")
        self.assertEqual(self.state["astra_clean"], 0)

    def test_unmaterialized_codex_session_recovers_same_phase(self):
        self.state["sessions"]["astra"] = "unmaterialized-session"
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["codex"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "codex", "missing-session"]
        pending = {"id": "cold-continuation", "attempts": 1}
        directory = self.store.directory / "cold-continuation"
        directory.mkdir(parents=True)
        self.assertEqual(parse_report(transport.run("astra", "same phase", pending, directory))["status"], "done")
        self.assertNotEqual(self.state["sessions"]["astra"], "unmaterialized-session")
        self.assertEqual(self.state["session_recoveries"][0]["missing"], "unmaterialized-session")

    def test_publication_reconciles_unicode_filenames(self):
        self.remote()
        name = "file-\u044d.txt"
        (self.root / name).write_text("reviewed unicode path")
        self.state.update(phase="publish", reviewed=self.repo.snapshot(), remote="origin")
        self.repo.git("add", "--", name)
        self.repo.git("commit", "-m", "Add reviewed file")
        self.repo.git("push", "origin", "main")
        self.assertTrue(self.cycle.reconcile_publish())

    def test_unmaterialized_claude_session_recovers_same_phase(self):
        self.state["sessions"]["code"] = "unmaterialized-session"
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", "missing-session"]
        pending = {"id": "claude-continuation", "attempts": 1}
        directory = self.store.directory / "claude-continuation"
        directory.mkdir(parents=True)
        self.assertEqual(parse_report(transport.run("code", "same phase", pending, directory))["status"], "done")
        self.assertNotEqual(self.state["sessions"]["code"], "unmaterialized-session")
        self.assertEqual(self.state["session_recoveries"][0]["missing"], "unmaterialized-session")
        self.assertIn("clean continuation", (directory / "prompt.txt").read_text())

    def test_claude_auth_failure_does_not_replace_conversation(self):
        self.state["sessions"]["code"] = "known-session"
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", "auth-error"]
        directory = self.store.directory / "claude-auth"
        directory.mkdir(parents=True)
        with self.assertRaises(Blocked):
            transport.run("code", "same phase", {"id": "claude-auth"}, directory)
        self.assertEqual(self.state["sessions"]["code"], "known-session")
        self.assertNotIn("session_recoveries", self.state)

    def test_claude_native_wait_is_not_the_final_report(self):
        for variant in ("native-wait", "native-fixes", "queued-turn", "foreground-task"):
            with self.subTest(variant=variant):
                self.state["sessions"]["claude"] = "saved-review-session"
                transport = Transport(self.root, self.state, self.store.save, lambda: None)
                transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", variant]
                directory = self.store.directory / variant
                directory.mkdir(parents=True)
                with patch.dict(os.environ, {"CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "0", "BASH_MAX_TIMEOUT_MS": "600000"}):
                    result = parse_report(transport.run("claude", "same review", {"id": variant}, directory), "claude")
                    self.assertEqual(os.environ["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"], "0")
                self.assertEqual(result["status"], "done")
                self.assertEqual(result["implementation_fixes"], 2 if variant == "native-fixes" else 0)
                self.assertEqual(result["substantial"], variant == "native-fixes")
                deferred = list(directory.glob("deferred-*.txt"))
                self.assertEqual(len(deferred), 0 if variant == "foreground-task" else 2)
                self.assertEqual(self.state["sessions"]["claude"], "saved-review-session")

    def test_claude_native_wait_cannot_earn_a_review_without_final_completion(self):
        for variant, expected in (("native-eof", "provider-eof"), ("native-wrong-session", "provider-profile")):
            with self.subTest(variant=variant):
                transport = Transport(self.root, self.state, self.store.save, lambda: None)
                transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", variant]
                directory = self.store.directory / variant
                directory.mkdir(parents=True)
                with self.assertRaises(Blocked) as caught:
                    transport.run("claude", "same review", {"id": variant}, directory)
                self.assertEqual(caught.exception.code, expected)
                self.assertFalse((directory / "result.json").exists())

    def test_claude_native_fix_cannot_count_as_a_clean_review(self):
        self.state.update(phase="claude", coordinated="claude", astra_passes=4, astra_clean=3, claude_clean=1)
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", "native-fixes"]
        self.cycle.transport = transport
        self.cycle.review("claude")
        self.assertEqual(self.state["phase"], "astra")
        self.assertEqual((self.state["astra_clean"], self.state["claude_clean"]), (0, 0))
        self.assertEqual(self.state["display_reviews"]["claude"]["completed"], 1)
        self.assertIsNone(self.state["published"])

    def test_claude_native_wait_still_honors_operator_stop(self):
        directory = self.store.directory / "native-stop"
        directory.mkdir(parents=True)
        def heartbeat():
            if list(directory.glob("deferred-*.txt")):
                raise FocusStop("fixture operator stop")
        transport = Transport(self.root, self.state, self.store.save, heartbeat)
        transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", "native-wait"]
        with self.assertRaises(FocusStop):
            transport.run("claude", "same review", {"id": "native-stop"}, directory)
        self.assertFalse((directory / "result.json").exists())

    def test_claude_synthetic_api_errors_keep_the_cause_and_session(self):
        for variant, expected in (("synthetic-org", "claude-access-denied"),
                                  ("synthetic-org-preinit", "claude-access-denied"),
                                  ("synthetic-api", "claude-api-error"),
                                  ("synthetic-unmarked", "model-rerouted"),
                                  ("synthetic-wrong-session", "provider-profile"),
                                  ("wrong-model", "model-rerouted")):
            with self.subTest(variant=variant):
                self.state["sessions"]["claude"] = "known-review-session"
                transport = Transport(self.root, self.state, self.store.save, lambda: None)
                transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", variant]
                directory = self.store.directory / variant
                directory.mkdir(parents=True)
                before = self.repo.snapshot()
                with self.assertRaises(Blocked) as raised:
                    transport.run("claude", "same review", {"id": variant}, directory)
                self.assertEqual(raised.exception.code, expected)
                if expected == "claude-access-denied":
                    self.assertIn("oauth_org_not_allowed", str(raised.exception))
                    self.assertIn("administrator", str(raised.exception))
                    self.assertIn("subscription/payment status", str(raised.exception))
                    self.assertIn("Your organization has disabled Claude subscription access", str(raised.exception))
                if expected == "claude-api-error":
                    self.assertIn("Provider temporarily unavailable", str(raised.exception))
                self.assertEqual(self.repo.snapshot(), before)
                self.assertEqual(self.state["sessions"]["claude"], "known-review-session")
                self.assertNotIn("session_recoveries", self.state)
                self.assertTrue((directory / "protocol.jsonl").exists())

    def test_error_code_quoted_in_a_real_claude_answer_is_not_an_api_refusal(self):
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", "quoted-api-error"]
        directory = self.store.directory / "quoted-api-error"
        directory.mkdir(parents=True)
        self.assertEqual(parse_report(transport.run("claude", "same review", {"id": "quoted"}, directory))["status"], "done")

    def test_provider_api_refusal_stops_review_without_healing_and_can_resume(self):
        self.state.update(phase="claude", coordinated="claude", astra_passes=4, astra_clean=3, claude_clean=1,
                          sessions={"claude": "saved-review-session"})
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        fixture = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude"]
        transport.commands["claude"] = fixture + ["synthetic-org"]
        self.cycle.transport = transport
        before = self.repo.snapshot()
        with patch.object(self.cycle, "heal", side_effect=AssertionError("Access refusals cannot be healed")):
            self.assertEqual(self.cycle.run(), 3)
        saved = self.store.read()
        self.assertEqual(saved["blocker"]["code"], "claude-access-denied")
        self.assertEqual(saved["blocker"]["status"], "blocked")
        self.assertEqual(saved["phase"], "claude")
        self.assertEqual((saved["astra_clean"], saved["claude_clean"]), (3, 0))
        self.assertEqual(saved["healed"], [])
        self.assertEqual(saved["display_reviews"]["claude"]["completed"], 0)
        self.assertEqual(self.repo.snapshot(), before)
        self.assertFalse(list(self.store.directory.glob("invocations/*/result.json")))
        # Operator continuation after access is restored uses the saved role
        # conversation and must still complete both required review passes.
        self.state.update(blocker=None, pending=None, status="ready")
        transport.commands["claude"] = fixture
        self.cycle.review("claude")
        self.assertEqual(self.state["phase"], "claude")
        self.cycle.review("claude")
        self.assertEqual(self.state["phase"], "publish")
        self.assertEqual(self.state["sessions"], {"claude": "saved-review-session"})

    def test_unknown_structured_api_failure_tries_healing_before_stopping(self):
        self.state.update(phase="code", coordinated="code")
        self.transport.actions = [("code", Blocked("claude-api-error", "Provider temporarily unavailable")),
                                  ("heal", report(status="blocked", summary="Provider outage persists after verification"))]
        self.assertEqual(self.cycle.run(), 3)
        self.assertEqual([role for role, _ in self.transport.calls], ["code", "heal"])
        self.assertEqual(self.state["blocker"]["status"], "blocked")
        self.assertEqual(self.state["blocker"]["escalation_reason"], "healer-failed")

    def test_reported_human_request_is_checked_by_the_recovery_agent(self):
        self.state.update(phase="code", coordinated="code")
        self.transport.actions = [("code", report(status="blocked", summary="Ask the operator to authorize a necessary dependency")),
                                  ("heal", report()), ("coordinate", report()),
                                  ("code", report(status="complete"))]
        self.assertEqual(self.cycle.run(), 0)
        self.assertEqual([role for role, _ in self.transport.calls], ["code", "heal", "coordinate", "code"])
        healing_prompt = self.transport.calls[1][1]
        self.assertIn("a claim to investigate", healing_prompt)
        self.assertIn("Use existing operator authorization", healing_prompt)
        self.assertEqual(PROFILES["heal"], ("codex", "gpt-6-astra", "xhigh"))
        self.assertEqual(self.state["status"], "complete")

    def test_blocker_routing_only_skips_recovery_for_manual_or_unsafe_actions(self):
        for code, reason in (("claude-access-denied", "manual-action"), ("approval-required", "manual-action"),
                             ("approval-denied", "manual-action"), ("cleanup-incomplete", "unsafe-provider"),
                             ("turn-active", "unsafe-provider"), ("operator-input", None),
                             ("remote-query-timeout", None), ("remote-query-failed", None),
                             ("claude-api-error", None), ("command-unavailable", None), ("failed-test", None)):
            with self.subTest(code=code):
                self.state.update(blocker=None, pending=None, healed=[], recovery_unverified=False)
                self.cycle.handle_block(Blocked(code, "Fixture diagnosis"))
                self.assertEqual(self.state["status"], "blocked" if reason else "healing")
                self.assertEqual(self.state["blocker"].get("escalation_reason"), reason)
                self.assertEqual(len(self.state["healed"]), 0 if reason else 1)

    def test_unpublished_ci_draft_does_not_enable_remote_wait(self):
        self.remote()
        workflows = self.root / ".github" / "workflows"
        workflows.mkdir(parents=True)
        (workflows / "draft.yml").write_text("on: push")
        self.state.update(reviewed=self.repo.snapshot(), published={
            "sha": self.repo.text("rev-parse", "HEAD"), "remote": "origin", "at": 0})
        with patch.object(self.cycle, "ci_gate", return_value={"verdict": "no-required-checks"}), \
             patch.object(self.cycle, "gh_records", side_effect=AssertionError("Draft CI must not be queried")):
            self.cycle.wait_ci()

    def test_external_ci_is_not_silently_skipped(self):
        self.remote()
        (self.root / ".gitlab-ci.yml").write_text("stages: [test]")
        self.repo.git("add", ".gitlab-ci.yml")
        self.repo.git("commit", "-m", "Configure external CI")
        self.repo.git("push", "origin", "main")
        self.state.update(reviewed=self.repo.snapshot(), published={
            "sha": self.repo.text("rev-parse", "HEAD"), "remote": "origin", "at": 0})
        with patch.object(self.cycle, "ci_gate", return_value={"verdict": "no-required-checks"}), \
             self.assertRaisesRegex(Blocked, "External CI"):
            self.cycle.wait_ci()

    def test_publication_checks_push_url_not_fetch_url(self):
        self.remote()
        alternate = Path(self.temp.name) / "publish-target.git"
        self.repo.git("clone", "--bare", self.repo.text("remote", "get-url", "origin"), str(alternate))
        self.repo.git("remote", "set-url", "--push", "origin", str(alternate))
        self.edit()()
        self.state.update(phase="publish", reviewed=self.repo.snapshot(), remote="origin")
        self.commit_stage()
        self.assertTrue(self.cycle.reconcile_publish())
        fetch_head = self.repo.text("ls-remote", "--refs", "origin", "refs/heads/main").split()[0]
        self.assertNotEqual(fetch_head, self.state["published"]["sha"])

    def test_handoff_named_status_does_not_bypass_root_launcher(self):
        config = Path(self.temp.name) / "isolated-config"
        config.mkdir()
        (config / "root-config.md").write_text("CC_PROCESSKIT_CLI: off\n")
        (self.root / "status").write_text("continue the current stage")
        env = dict(os.environ, ORCHESTRA_HOME=str(config), ORCHESTRA_PROCESSKIT_ROOT_RUN_ID="")
        result = subprocess.run(["pwsh", "-NoProfile", "-File", str(REPO / "tools/focus-runtime.ps1"),
                                 "--handoff", "status"], cwd=self.root, env=env, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 3)
        self.assertIn(b"requires processkit-cli with inherited stdio", result.stderr)
        self.assertFalse(self.store.path.exists())

    def test_wrapper_emits_utf8_status_under_legacy_pipe_encoding(self):
        self.state["last"] = {"summary": "\u043f\u0440\u043e\u0432\u0435\u0440\u0435\u043d\u043e"}
        self.store.save(self.state)
        result = subprocess.run(["pwsh", "-NoProfile", "-File", str(REPO / "tools/focus-runtime.ps1"), "status"],
                                cwd=self.root, env=dict(os.environ, PYTHONIOENCODING="ascii"), capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout.decode("utf-8"))["last"], self.state["last"])

    def focus_control(self):
        control = Control(self.store)
        control.begin()
        self.cycle.control = control
        return control

    def stop_request(self, control, mode="safe"):
        self.store.artifact("stop.json", encode({"nonce": control.active["nonce"], "mode": mode, "requested": time.time()}))

    def test_safe_stop_before_phase_starts_no_provider(self):
        control = self.focus_control()
        self.stop_request(control)
        self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(self.state["status"], "paused")
        self.assertFalse(self.transport.calls)
        self.assertFalse((self.root / ".work" / "PAUSE").exists())

    def test_safe_stop_finishes_current_pass_but_not_next_one(self):
        control = self.focus_control()
        self.state.update(phase="astra", coordinated="astra")
        def finish_pass():
            self.stop_request(control)
            return report()
        self.transport.actions = [("astra", finish_pass)]
        self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(self.state["astra_clean"], 1)
        self.assertIsNone(self.state["pending"])
        self.assertEqual(len(self.transport.calls), 1)

    def test_safe_stop_during_ci_waits_for_publication_boundary(self):
        self.remote()
        self.edit()()
        self.state.update(phase="publish", reviewed=self.repo.snapshot(), remote="origin")
        self.commit_stage()
        self.cycle.reconcile_publish()
        control = self.focus_control()
        self.stop_request(control)
        with patch.object(self.cycle, "wait_ci") as wait:
            self.assertEqual(self.cycle.run(), 0)
            wait.assert_called_once()
        self.assertEqual(self.state["iteration"], 2)
        self.assertFalse(self.transport.calls)

    def test_operator_stop_does_not_start_blocker_healer(self):
        control = self.focus_control()
        self.state.update(phase="astra", coordinated="astra")
        def fail_after_stop():
            self.stop_request(control)
            raise Blocked("fixture", "failed check")
        self.transport.actions = [("astra", fail_after_stop)]
        self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(self.state["blocker"]["status"], "healing")
        self.assertEqual([role for role, _ in self.transport.calls], ["astra"])

    def test_emergency_stop_never_becomes_model_blocker(self):
        control = self.focus_control()
        self.stop_request(control, "now")
        with self.assertRaises(FocusStop):
            self.cycle.run()
        self.assertFalse(self.transport.calls)
        self.assertIsNone(self.state["blocker"])

    def test_old_stop_request_cannot_stop_new_run(self):
        control = self.focus_control()
        self.stop_request(control, "now")
        replacement = Control(self.store)
        replacement.begin()
        self.assertFalse(replacement.boundary())

    def test_stop_timeout_preserves_request_and_does_not_signal(self):
        with LocalLock(self.store.directory):
            control = self.focus_control()
            with self.assertRaisesRegex(Blocked, "Stop is still pending"), patch("focus_control.command") as external:
                request_stop(self.store, timeout=0.01)
            external.assert_not_called()
            self.assertEqual(control.request()["mode"], "safe")

    def test_status_and_idle_stop_are_nonmutating(self):
        self.assertFalse(runtime_active(self.store))
        self.assertEqual(request_stop(self.store), 0)
        self.assertFalse(self.store.directory.exists())

    def test_status_lock_probe_does_not_write_existing_lock(self):
        with LocalLock(self.store.directory):
            path = self.store.directory / "runtime.lock"
            before = path.read_bytes(), path.stat().st_mtime_ns
            self.assertTrue(runtime_active(self.store))
            self.assertEqual((path.read_bytes(), path.stat().st_mtime_ns), before)
        self.assertFalse(runtime_active(self.store))
        self.assertEqual((path.read_bytes(), path.stat().st_mtime_ns), before)

    def test_failed_lease_release_cannot_acknowledge_clean_stop(self):
        import cc_focus
        self.store.save(self.state)
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.Lease") as lease, \
             patch("cc_focus.Cycle.run", return_value=0):
            lease.return_value.__enter__.return_value.pwsh = "pwsh"
            lease.return_value.__exit__.side_effect = Blocked("release", "Fixture release failed")
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(cc_focus.main([]), 3)
        active = json.loads((self.store.directory / "active.json").read_text())
        self.assertEqual(active["exit_code"], 3)
        self.assertEqual(active["status"], "interrupted")

    def test_stop_refuses_unaddressed_legacy_runtime(self):
        with LocalLock(self.store.directory):
            with self.assertRaisesRegex(Blocked, "legacy cc-cycle"), patch("focus_control.command") as external:
                request_stop(self.store, now=True)
            external.assert_not_called()

    def test_progress_heartbeat_uses_actual_elapsed_and_silent_time(self):
        clock = [100.0]
        with patch("focus_progress.time") as timer:
            timer.monotonic.side_effect = lambda: clock[0]
            timer.time.side_effect = lambda: clock[0]
            timer.strftime.return_value = "[clock] "
            progress = Progress(self.store, self.state, "run")
            with contextlib.redirect_stdout(io.StringIO()) as output:
                progress.start("code", self.store.directory)
                clock[0] += 16
                progress.pulse()
            self.assertIn("active 16s", output.getvalue())
            self.assertIn("last event 16s ago", output.getvalue())
            self.assertIn("claude-fable-5-1", output.getvalue())
            self.assertEqual(json.loads((self.store.directory / "progress.json").read_text())["events"], 0)

    def test_progress_does_not_print_reasoning_secrets_or_command_arguments(self):
        progress = Progress(self.store, self.state, "run")
        events = [
            {"method": "item/started", "params": {"item": {"type": "commandExecution", "command": "tool --token SECRET"}}},
            {"type": "assistant", "message": {"content": [{"type": "thinking", "thinking": "PRIVATE REASONING"}]}},
            {"method": "item/commandExecution/outputDelta", "params": {"delta": "SECRET"}},
            {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Read", "input": {"file_path": "src/main.py", "token": "SECRET"}}]}}]
        with contextlib.redirect_stdout(io.StringIO()) as output:
            for event in events:
                progress.last_print = 0
                progress.event(event)
        self.assertIn("Read src/main.py", output.getvalue())
        for secret in ("SECRET", "PRIVATE REASONING", "--token"):
            self.assertNotIn(secret, output.getvalue())
            self.assertNotIn(secret, (self.store.directory / "progress.json").read_text())
        self.assertNotIn("\x1b", safe_text("\x1b[31mhello\nworld"))

    def test_live_codex_output_streams_messages_commands_and_errors_without_duplicates(self):
        renderer = LiveOutput("astra")
        def item(kind, **values):
            renderer.event({"method": "item/" + kind, "params": {"item": values}})
        with contextlib.redirect_stdout(io.StringIO()) as output:
            renderer.event({"method": "item/agentMessage/delta", "params": {"itemId": "m", "delta": "Checking "}})
            self.assertIn("Checking ", output.getvalue())
            renderer.event({"method": "item/agentMessage/delta", "params": {"itemId": "m", "delta": "the tests.\n"}})
            item("completed", id="m", type="agentMessage", text="Checking the tests.\n")
            item("started", id="cmd", type="commandExecution", command="pytest -q")
            renderer.event({"method": "item/commandExecution/outputDelta", "params": {"itemId": "cmd", "delta": "one passed\n"}})
            item("completed", id="cmd", type="commandExecution", command="pytest -q", aggregatedOutput="one passed\n", exitCode=0, status="completed")
            renderer.event({"method": "error", "params": {"error": {"message": "Connection lost"}}})
        text = output.getvalue()
        for expected in ("Checking the tests.", "pytest -q", "one passed", "exit=0", "Connection lost"):
            self.assertEqual(text.count(expected), 1, text)

    def test_live_claude_output_deduplicates_partial_messages_and_tool_results(self):
        renderer = LiveOutput("code")
        def stream(kind, **values):
            renderer.event({"type": "stream_event", "event": dict(type=kind, **values)})
        with contextlib.redirect_stdout(io.StringIO()) as output:
            stream("message_start", message={"id": "m"})
            stream("content_block_start", index=0, content_block={"type": "text", "text": ""})
            stream("content_block_delta", index=0, delta={"type": "text_delta", "text": "Inspecting code."})
            stream("content_block_stop", index=0)
            stream("content_block_start", index=1, content_block={"type": "tool_use", "id": "t", "name": "Bash"})
            stream("content_block_delta", index=1, delta={"type": "input_json_delta", "partial_json": '{"command":"pytest -q"}'})
            stream("content_block_stop", index=1)
            renderer.event({"type": "assistant", "message": {"id": "m", "content": [
                {"type": "text", "text": "Inspecting code."},
                {"type": "tool_use", "id": "t", "name": "Bash", "input": {"command": "pytest -q"}}]}})
            result = {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t", "is_error": True,
                       "content": [{"type": "text", "text": "Test failed"}, {"type": "image", "data": "PRIVATE IMAGE"}]}]}}
            renderer.event(result)
            renderer.event(result)
        for expected in ("Inspecting code.", "pytest -q", "Test failed"):
            self.assertEqual(output.getvalue().count(expected), 1, output.getvalue())
        self.assertIn("[code/error]", output.getvalue())
        self.assertNotIn("PRIVATE IMAGE", output.getvalue())

    def test_live_output_hides_reasoning_protocol_and_structured_final_report(self):
        renderer = LiveOutput("astra")
        with contextlib.redirect_stdout(io.StringIO()) as output:
            for event in (
                {"method": "item/reasoning/textDelta", "params": {"delta": "PRIVATE"}},
                {"method": "item/reasoning/summaryTextDelta", "params": {"delta": "PRIVATE"}},
                {"method": "item/completed", "params": {"item": {"type": "reasoning", "text": "PRIVATE"}}},
                {"type": "assistant", "message": {"content": [{"type": "thinking", "thinking": "PRIVATE"}]}},
                {"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "thinking_delta", "thinking": "PRIVATE"}}},
                {"id": 1, "result": {"thread": {"id": "PRIVATE"}}},
                {"method": "item/agentMessage/delta", "params": {"itemId": "f", "delta": json.dumps(report())}},
                {"method": "item/completed", "params": {"item": {"type": "agentMessage", "id": "f", "text": json.dumps(report())}}},
            ):
                renderer.event(event)
            renderer.report(report(description="Validated public result."))
        self.assertNotIn("PRIVATE", output.getvalue())
        self.assertNotIn("implementation_fixes", output.getvalue())
        self.assertIn("Validated public result.", output.getvalue())

    def test_live_output_is_bounded_and_cannot_inject_terminal_controls(self):
        renderer = LiveOutput("code")
        with contextlib.redirect_stdout(io.StringIO()) as output:
            renderer.feed("tool", "output", "hello\x1b[2J\x07\u202e\rworld\n" + "x" * 80000)
            size = len(output.getvalue())
            renderer.feed("tool", "output", "y" * 80000)
            self.assertEqual(len(output.getvalue()), size)
        self.assertIn("display truncated", output.getvalue())
        self.assertLess(size, 66500)
        for character in ("\x1b", "\x07", "\u202e", "\r"):
            self.assertNotIn(character, output.getvalue())
        with contextlib.redirect_stdout(io.StringIO()):
            for index in range(renderer.ITEMS + 10):
                renderer.feed(str(index), "output", "x", final=True)
        self.assertEqual(len(renderer.items), renderer.ITEMS)

    def test_live_final_json_messages_and_updated_plans_are_not_echoed_twice(self):
        renderer = LiveOutput("astra")
        with contextlib.redirect_stdout(io.StringIO()) as output:
            for value in ('{"example": 1}', '{"example": 1}'):
                renderer.feed("message", "message", value, final=True, message=True)
            for value in ("pending: inspect", "inProgress: inspect", "inProgress: inspect"):
                renderer.feed("plan", "plan", value, final=True)
        self.assertEqual(output.getvalue().count('"example"'), 1)
        self.assertEqual(output.getvalue().count("inProgress: inspect"), 1)

    def test_live_changed_json_snapshots_share_one_display_budget(self):
        renderer = LiveOutput("astra")
        with contextlib.redirect_stdout(io.StringIO()) as output:
            renderer.feed("message", "message", json.dumps({"text": "a" * 32000}), final=True, message=True)
            renderer.feed("message", "message", json.dumps({"text": "b" * 64000}), final=True, message=True)
        self.assertLess(len(output.getvalue()), renderer.LIMIT + 200)
        self.assertIn("display truncated", output.getvalue())

    def test_live_tools_include_structured_results_and_changed_file_diffs(self):
        renderer = LiveOutput("astra")
        events = [
            {"id": "files", "type": "fileChange", "changes": [{"path": "source.py", "diff": "+fixed edge case"}], "status": "completed"},
            {"id": "mcp", "type": "mcpToolCall", "server": "fixture", "tool": "query", "arguments": {"query": "example"},
             "result": {"content": [], "structuredContent": {"rows": 12}}, "status": "completed"},
            {"id": "dynamic", "type": "dynamicToolCall", "tool": "check", "arguments": {}, "success": False,
             "contentItems": [{"type": "inputText", "text": "Failed check"}, {"type": "inputImage", "imageUrl": "HIDDEN IMAGE"}]},
        ]
        with contextlib.redirect_stdout(io.StringIO()) as output:
            for item in events:
                renderer.event({"method": "item/completed", "params": {"item": item}})
        for expected in ("source.py", "+fixed edge case", '"rows": 12', "Failed check"):
            self.assertIn(expected, output.getvalue())
        self.assertNotIn("HIDDEN IMAGE", output.getvalue())

    def test_unknown_display_events_do_not_break_protocol_processing(self):
        progress = Progress(self.store, self.state, "run", live=True)
        with contextlib.redirect_stdout(io.StringIO()):
            progress.start("code", self.store.directory)
            for event in (None, [], {"method": None}, {"method": "item/started", "params": None},
                          {"type": "assistant", "message": {"content": [None]}},
                          {"type": "stream_event", "event": "unknown"}):
                progress.event(event)
            progress.pulse(force=True)
        self.assertEqual(json.loads((self.store.directory / "progress.json").read_text())["events"], 4)

    def test_cli_defaults_to_live_but_compact_remains_available(self):
        import cc_focus
        self.store.save(self.state)
        for argv, expected in (([], True), (["--output", "compact"], False)):
            with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.Lease") as lease, \
                 patch("cc_focus.Progress", wraps=Progress) as progress, patch("cc_focus.Cycle.run", return_value=0):
                lease.return_value.__enter__.return_value.pwsh = "pwsh"
                self.assertEqual(cc_focus.main(argv), 0)
                self.assertEqual(progress.call_args.kwargs["live"], expected)

    def test_live_progress_keeps_public_payloads_out_of_status_snapshot(self):
        progress = Progress(self.store, self.state, "run", live=True)
        with contextlib.redirect_stdout(io.StringIO()) as output:
            progress.start("code", self.store.directory)
            progress.event({"method": "item/commandExecution/outputDelta", "params": {"itemId": "cmd", "delta": "VISIBLE COMMAND RESULT"}})
            progress.stderr("VISIBLE STDERR\n")
            progress.result(report(description="Detailed result"))
        self.assertIn("VISIBLE COMMAND RESULT", output.getvalue())
        self.assertIn("VISIBLE STDERR", output.getvalue())
        self.assertNotIn("VISIBLE", (self.store.directory / "progress.json").read_text())

    def test_live_transport_outputs_both_provider_events_and_trailing_stderr(self):
        for role, provider in (("code", "claude"), ("astra", "codex")):
            with self.subTest(provider=provider), contextlib.redirect_stdout(io.StringIO()) as output:
                progress = Progress(self.store, self.state, "run", live=True)
                directory = self.store.directory / ("live-" + provider)
                directory.mkdir(parents=True)
                progress.start(role, directory)
                transport = Transport(self.root, self.state, self.store.save, lambda: None, progress=progress)
                transport.commands[provider] = [sys.executable, str(Path(__file__).resolve()), "fixture", provider, "live"]
                raw = transport.run(role, "fixture", {"id": "live-" + provider}, directory)
                parse_report(raw, role)
                self.assertIn("Public fixture message", output.getvalue())
                self.assertIn("fixture-command", output.getvalue())
                self.assertIn("Fixture output", output.getvalue())
                self.assertIn("Trailing fixture stderr", output.getvalue())
                self.assertNotIn("PRIVATE REASONING", output.getvalue())
                self.assertIn("Trailing fixture stderr", (directory / "protocol.jsonl").read_text())

    def test_status_marks_old_progress_as_not_live(self):
        control = self.focus_control()
        progress = Progress(self.store, self.state, control.active["nonce"])
        progress.pulse(force=True)
        result = status(self.store, self.state)
        self.assertFalse(result["running"])
        self.assertFalse(result["progress"]["live"])
        self.assertTrue((self.store.directory / "state.json").exists() is False)

    def test_status_distinguishes_running_but_unresponsive_runtime(self):
        with LocalLock(self.store.directory):
            control = self.focus_control()
            self.store.artifact("progress.json", encode({"run_nonce": control.active["nonce"], "updated": time.time() - 60}))
            result = status(self.store, self.state)
        self.assertTrue(result["running"])
        self.assertTrue(result["progress"]["stale"])
        self.assertFalse(result["progress"]["live"])

    def test_old_conversation_marker_is_retained_after_command_rename(self):
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude"]
        directory = self.store.directory / "renamed"
        directory.mkdir(parents=True)
        transport.run("code", "continue", {"id": "existing-invocation"}, directory)
        prompt = (directory / "prompt.txt").read_text()
        self.assertIn("Invocation marker: cc-cycle/existing-invocation", prompt)
        self.assertIn("operator-selected cc-focus profile", prompt)

    def test_interrupted_publication_with_changed_content_returns_to_review(self):
        self.state.update(phase="publish", reviewed=self.repo.snapshot(), pending={"id": "old-publish", "role": "publish"})
        self.edit()()
        self.assertFalse(self.cycle.prepare_publish())
        self.assertEqual(self.state["phase"], "astra")
        self.assertIsNone(self.state["pending"])

    def start_focus_fixture(self, mode="normal", native=False):
        self.store.save(self.state)
        argv = [sys.executable, str(Path(__file__).resolve()), "fixture", "focus-worker", mode]
        if native:
            cli = Path(shutil.which("processkit-cli") or (Path(os.environ.get("ORCHESTRA_HOME", Path.home() / ".orchestra")) / ("processkit-cli.exe" if os.name == "nt" else "processkit-cli")))
            if not cli.is_file():
                self.skipTest("Optional installed ProcessKit CLI is unavailable")
            import uuid
            run_id = "orchestra-focus-" + uuid.uuid4().hex
            argv = [str(cli), "run", "--run-id", run_id, "--cwd", str(self.root),
                    "--jsonl", str(self.store.directory / "fixture.processkit.jsonl"),
                    "--env", "ORCHESTRA_PROCESSKIT_ROOT_RUN_ID=" + run_id,
                    "--env", "ORCHESTRA_FOCUS_PROCESSKIT_CLI=" + str(cli), "--", *argv]
        process = subprocess.Popen(argv, cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        def cleanup():
            if process.poll() is None:
                if native:
                    subprocess.run([str(cli), "kill", "--run-id", run_id], capture_output=True, timeout=15)
                elif os.name != "nt":
                    process.send_signal(signal.SIGINT)
                else:
                    active = json.loads((self.store.directory / "active.json").read_text())
                    self.store.artifact("stop.json", encode({"nonce": active["nonce"], "mode": "now"}))
            process.communicate(timeout=20)
        self.addCleanup(cleanup)
        deadline = time.monotonic() + 20
        while not (self.store.directory / "fixture-ready").exists():
            if process.poll() is not None or time.monotonic() > deadline:
                stdout, stderr = process.communicate(timeout=5)
                self.fail(f"Focus fixture failed: {stdout!r} {stderr!r}")
            time.sleep(0.05)
        return process

    def test_stop_command_waits_for_real_safe_acknowledgement(self):
        process = self.start_focus_fixture()
        def release_provider():
            deadline = time.monotonic() + 10
            while not (self.store.directory / "stop.json").exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            (self.store.directory / "complete-provider").touch()
        release = threading.Thread(target=release_provider)
        release.start()
        try:
            self.assertEqual(request_stop(self.store, timeout=15), 0)
        finally:
            release.join(timeout=10)
            process.communicate(timeout=15)
        self.assertEqual(process.returncode, 0)
        self.assertEqual(self.store.read()["status"], "paused")
        self.assertIsNone(self.store.read()["pending"])
        self.assertFalse(runtime_active(self.store))

    def test_emergency_stop_preserves_pending_turn_and_cleans_provider(self):
        process = self.start_focus_fixture()
        try:
            self.assertEqual(request_stop(self.store, now=True, timeout=15), 0)
        finally:
            process.communicate(timeout=15)
        self.assertEqual(self.store.read()["status"], "interrupted")
        self.assertEqual(self.store.read()["pending"]["id"], "unfinished-turn")
        self.assertFalse(runtime_active(self.store))

    def test_emergency_fallback_terminates_exact_contained_run(self):
        process = self.start_focus_fixture("hung", native=True)
        try:
            self.assertEqual(request_stop(self.store, now=True, timeout=30), 0)
        except Blocked as error:
            events = (self.store.directory / "fixture.processkit.jsonl").read_text(encoding="utf-8")[-6000:]
            self.fail(f"{error}; root return={process.poll()}; native events={events}")
        finally:
            process.communicate(timeout=30)
        self.assertIsNotNone(self.store.read()["pending"])
        self.assertFalse(runtime_active(self.store))

    def test_emergency_stop_recovers_leaf_after_root_crash(self):
        process = self.start_focus_fixture("crash", native=True)
        try:
            self.assertEqual(request_stop(self.store, now=True, timeout=30), 0)
        finally:
            process.communicate(timeout=30)
        self.assertFalse(runtime_active(self.store))

    def test_contained_provider_protocol_remains_clean(self):
        process = self.start_focus_fixture("transport", native=True)
        stdout, stderr = process.communicate(timeout=30)
        self.assertEqual(process.returncode, 0, (stdout, stderr))
        self.assertEqual(self.store.read()["status"], "paused")
        self.assertFalse(runtime_active(self.store))


def fixture(provider):
    args = sys.argv[3:]
    if provider == "silent":
        while not (Path.cwd() / ".work/cycle/complete-provider").exists():
            time.sleep(0.1)
        print(json.dumps({"type": "result"}), flush=True)
        return
    if provider == "focus-worker":
        store = Store(Path.cwd())
        state = store.read()
        with LocalLock(store.directory) as lock:
            control = Control(store)
            control.begin()
            state["pending"] = {"id": "unfinished-turn", "role": "code", "attempts": 1}
            store.save(state)
            if args == ["transport"]:
                (store.directory / "fixture-ready").touch()
                transport = Transport(Path.cwd(), state, store.save, control.poll, lock.stream.fileno(), control=control)
                for provider_name in ("codex", "claude"):
                    transport.commands[provider_name] = [sys.executable, str(Path(__file__).resolve()), "fixture", provider_name]
                for role in ("coordinate", "code"):
                    directory = store.directory / role
                    directory.mkdir()
                    parse_report(transport.run(role, "fixture", {"id": role}, directory))
                state.update(pending=None, status="paused")
                store.save(state)
                control.finish(state, 0)
                return
            process = Process([sys.executable, str(Path(__file__).resolve()), "fixture", "silent"],
                              Path.cwd(), store.directory / "fixture.jsonl", control.poll, lock.stream.fileno(), control=control)
            (store.directory / "fixture-ready").touch()
            try:
                try:
                    if args == ["hung"]:
                        time.sleep(3600)
                    if args == ["crash"]:
                        os._exit(1)
                    process.receive()
                    state.update(pending=None, status="paused", phase="astra")
                finally:
                    process.close()
            except FocusStop:
                state["status"] = "interrupted"
            finally:
                store.save(state)
                control.finish(state, 0)
        return
    recovery = "recover" in args
    missing_session = "missing-session" in args
    live = "live" in args
    steer = "steer" in args
    late_ack, error_ack = "late-ack" in args, "error-ack" in args
    args = [arg for arg in args if arg not in ("recover", "missing-session", "live", "steer", "late-ack", "error-ack")]
    def emit(value):
        print(json.dumps(value), flush=True)
    if provider == "claude":
        assert args[args.index("--permission-mode") + 1] == "bypassPermissions"
        assert args[args.index("--model") + 1] == "claude-fable-5-1"
        assert args[args.index("--effort") + 1] == os.environ["CLAUDE_CODE_EFFORT_LEVEL"]
        settings = json.loads(args[args.index("--settings") + 1])
        for key, value in {"CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1", "BASH_DEFAULT_TIMEOUT_MS": "1800000",
                           "BASH_MAX_TIMEOUT_MS": "21600000"}.items():
            assert os.environ[key] == settings["env"][key] == value
        assert {"Agent", "Task", "Monitor", "CronCreate", "ScheduleWakeup", "RemoteTrigger", "Workflow"} <= set(
            args[args.index("--disallowedTools") + 1].split(","))
        sid = args[args.index("--resume") + 1] if "--resume" in args else args[args.index("--session-id") + 1]
        streaming_input = "--input-format" in args
        initial = json.loads(sys.stdin.readline()) if streaming_input else None
        prompt = initial["message"]["content"] if initial else sys.stdin.read()
        if "--resume" in args and (missing_session or "auth-error" in args):
            error = f"No conversation found with session ID: {sid}" if missing_session else "Authentication failed"
            emit({"type": "result", "subtype": "error_during_execution", "is_error": True,
                  "num_turns": 0, "session_id": sid, "errors": [error]})
            return
        if missing_session:
            assert "clean continuation" in prompt
        if "synthetic-org-preinit" not in args:
            emit({"type": "system", "subtype": "init", "model": "claude-fable-5-1", "session_id": sid, "permissionMode": "bypassPermissions"})
        api_variant = next((arg for arg in args if arg.startswith("synthetic-") or arg in ("wrong-model", "quoted-api-error")), None)
        if api_variant:
            api_message = {"type": "assistant", "session_id": sid, "is_api_error_message": True,
                           "error": "oauth_org_not_allowed", "message": {"model": "<synthetic>", "content": [
                               {"type": "text", "text": "Your organization has disabled Claude subscription access for Claude Code"}]}}
            if api_variant == "synthetic-api":
                api_message.update(error="fixture_api_failure")
                api_message["message"]["content"][0]["text"] = "Provider temporarily unavailable"
            elif api_variant == "synthetic-wrong-session":
                api_message["session_id"] = "another-session"
            elif api_variant in ("synthetic-unmarked", "wrong-model", "quoted-api-error"):
                del api_message["is_api_error_message"]
                if api_variant == "wrong-model":
                    api_message["message"]["model"] = "unexpected-model"
                elif api_variant == "quoted-api-error":
                    api_message["message"]["model"] = "claude-fable-5-1"
            emit(api_message)
            if api_variant != "quoted-api-error":
                return
        if live:
            emit({"type": "assistant", "message": {"id": "m", "model": "claude-fable-5-1", "content": [
                {"type": "text", "text": "Public fixture message"},
                {"type": "thinking", "thinking": "PRIVATE REASONING"},
                {"type": "tool_use", "id": "t", "name": "Bash", "input": {"command": "fixture-command"}}]}})
            emit({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t", "content": "Fixture output"}]}})
        if "slow-ui" in args:
            time.sleep(0.6)
        native = next((arg for arg in args if arg.startswith("native-") or arg in ("queued-turn", "foreground-task")), None)
        if native:
            def task(subtype, task_id):
                emit({"type": "system", "subtype": subtype, "task_id": task_id,
                      "session_id": "foreign-session" if native == "native-wrong-session" else sid,
                      "is_backgrounded": False, "task_type": "local_bash", "status": "completed"})
            if native != "queued-turn":
                task("task_started", "integration")
                task("task_started", "monitor")
            if native != "foreground-task":
                waiting = json.dumps(report(implementation_fixes=2, substantial=True)) if native == "native-fixes" else "Waiting for native completion"
                emit({"type": "result", "subtype": "success", "is_error": False, "session_id": sid,
                      "result": waiting, "queued_turn_count": 1 if native == "queued-turn" else 0})
                if native == "native-eof":
                    return
                time.sleep(0.05)
            if native != "queued-turn":
                task("task_notification", "integration")
            if native != "foreground-task":
                emit({"type": "result", "subtype": "success", "is_error": False, "session_id": sid,
                      "result": "Waiting for remaining verification", "queued_turn_count": 1 if native == "queued-turn" else 0})
            if native != "queued-turn":
                task("task_notification", "monitor")
            emit({"type": "assistant", "message": {"model": "claude-fable-5-1", "content": [
                {"type": "text", "text": "Native tasks finished; completing verification"}]}})
        first = report(implementation_fixes=1, substantial=True) if "prior-fix" in args else report()
        if "long-summary" in args:
            first["summary"] = "First summary " * 100 + "first summary ending"
        emit({"type": "result", "subtype": "success", "is_error": False, "session_id": sid, "result": json.dumps(first)})
        if streaming_input:
            assert "--replay-user-messages" in args
            for line in sys.stdin:
                incoming = json.loads(line)
                assert "focus-message:" in incoming["message"]["content"]
                if "no-ack" not in args:
                    emit(incoming)
                final = report(description="Operator instruction handled in the same process.")
                if "long-summary" in args:
                    final["summary"] = "Final summary " * 100 + "final summary ending"
                emit({"type": "result", "subtype": "success", "is_error": False, "session_id": sid,
                      "result": json.dumps(final)})
        if live:
            print("Trailing fixture stderr", file=sys.stderr, flush=True)
        return
    assert args[:5] == ["-s", "danger-full-access", "-a", "on-request", "app-server"]
    assert "features.multi_agent=false" in args
    assert "features.memories=false" in args, "Memory consolidation must not run beside the selected role"
    sid = ""
    import uuid
    for line in sys.stdin:
        request = json.loads(line)
        method, params = request["method"], request.get("params", {})
        if "id" not in request:
            continue
        if method == "initialize":
            result = {"userAgent": "fixture"}
        elif method == "model/list":
            result = {"data": [{"model": model, "supportedReasoningEfforts": [{"reasoningEffort": "high"}, {"reasoningEffort": "xhigh"}]}
                               for model in ("gpt-6-astra", "gpt-5.6-luna")], "nextCursor": None}
        elif method in ("thread/start", "thread/resume"):
            assert params["config"]["features.memories"] is False
            if method == "thread/resume" and missing_session:
                emit({"id": request["id"], "error": {"code": -32600, "message": "no rollout found for thread id"}})
                continue
            sid = params.get("threadId", str(uuid.uuid4()))
            assert params["approvalPolicy"] == "on-request"
            assert params["sandbox"] == "danger-full-access"
            if method == "thread/resume":
                assert params["excludeTurns"] is True, "Do not return unbounded conversation history"
            result = {"thread": {"id": sid, "turns": []}, "model": params["model"], "cwd": params["cwd"],
                      "reasoningEffort": params["config"]["model_reasoning_effort"],
                      "approvalPolicy": "on-request", "approvalsReviewer": "user", "sandbox": {"type": "dangerFullAccess"}}
        elif method == "thread/turns/list":
            assert not missing_session, "An unmaterialized replacement has no historical turns to fetch"
            assert params["limit"] == 1 and params["itemsView"] == "full"
            result = {"data": [{"id": "finished-turn", "status": "completed", "items": [
                {"id": "final", "type": "agentMessage", "phase": "final_answer", "text": json.dumps(report())}]}]}
        elif method == "turn/start":
            assert not recovery, "A completed turn must not be repeated"
            assert params["threadId"] == sid
            assert params["sandboxPolicy"] == {"type": "dangerFullAccess"}
            if missing_session:
                assert "clean continuation" in params["input"][0]["text"]
            turn = {"id": str(uuid.uuid4()), "status": "completed", "items": [
                {"id": "final", "type": "agentMessage", "phase": "final_answer", "text": json.dumps(report())}]}
            result = {"turn": turn}
        elif method == "turn/steer":
            assert steer
            assert params["expectedTurnId"] == turn["id"] and params["threadId"] == sid
            assert "focus-message:" in params["input"][0]["text"]
            turn["items"][-1]["text"] = json.dumps(report(description="Steered the active turn."))
            if late_ack:
                emit({"method": "turn/completed", "params": {"threadId": sid, "turn": turn}})
            if error_ack:
                emit({"id": request["id"], "error": {"message": "No active turn"}})
            else:
                emit({"id": request["id"], "result": {"turnId": turn["id"]}})
            if not late_ack:
                emit({"method": "turn/completed", "params": {"threadId": sid, "turn": turn}})
            continue
        else:
            raise AssertionError(method)
        emit({"id": request["id"], "result": result})
        if method == "turn/start":
            if live:
                emit({"method": "item/agentMessage/delta", "params": {"itemId": "m", "delta": "Public fixture message"}})
                emit({"method": "item/reasoning/textDelta", "params": {"delta": "PRIVATE REASONING"}})
                emit({"method": "item/started", "params": {"item": {"id": "cmd", "type": "commandExecution", "command": "fixture-command"}}})
                emit({"method": "item/commandExecution/outputDelta", "params": {"itemId": "cmd", "delta": "Fixture output"}})
            if not steer:
                emit({"method": "turn/completed", "params": {"threadId": sid, "turn": turn}})
            if live:
                print("Trailing fixture stderr", file=sys.stderr, flush=True)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "fixture":
        fixture(sys.argv[2])
    else:
        unittest.main()
