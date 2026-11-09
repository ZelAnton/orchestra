"""Hermetic workflow/protocol tests; never invoke a paid provider."""

import contextlib
import hashlib
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
from cycle_state import Blocked, ProviderQuota, ProviderTransient, Lease, LocalLock, Repository, Store, atomic_write, changed, command, digest, encode
from cycle_prompts import CODE_IMPLEMENTATION_CONTRACT, COMMAND_EXECUTION_CONTRACT, PAIR_CONTRACT, PROFILES, REVIEW_PROFILE_VERSION, REVIEW_ROLES, REVIEW_TARGETS, WRITING_CONTRACT
from focus_pair_profile import PAIRS, PAIR_ROLES, PAIR_READONLY, PAIR_WRITERS
from cycle_transport import Process, Rpc, Transport, concise_summary, parse_report
from cycle_workflow import Cycle, fresh_state
from focus_control import Control, FocusStop, request_stop, runtime_active, status
from focus_progress import Progress, safe_text
from focus_output import LiveOutput
from focus_messages import MessagePending
from focus_snapshot_archive import read_source


# The report schema keywords that Codex strict structured output has accepted.
STRICT_KEYWORDS = {"additionalProperties", "anyOf", "description", "enum", "items", "maxItems",
                   "minItems", "minLength", "minimum", "properties", "required", "type"}


def schema_keywords(schema):
    if isinstance(schema, list):
        return set().union(*map(schema_keywords, schema))
    if not isinstance(schema, dict):
        return set()
    names = set(schema)
    for key, value in schema.items():
        names |= set().union(*map(schema_keywords, value.values())) if key == "properties" else schema_keywords(value)
    return names


def strict_objects(schema):
    """Strict mode: each object requires all its properties and forbids other properties."""
    if isinstance(schema, list):
        return all(map(strict_objects, schema))
    if not isinstance(schema, dict):
        return True
    kind, properties = schema.get("type"), schema.get("properties", {})
    if "properties" in schema or ("object" in kind if isinstance(kind, list) else kind == "object"):
        if "properties" not in schema or set(schema.get("required", [])) != set(properties) or schema.get("additionalProperties") is not False:
            return False
    return all(strict_objects(value) for key, value in schema.items() if key != "properties") and all(map(strict_objects, properties.values()))


def report(**kwargs):
    value = dict(status="done", summary="Validated fixture result", description="Full coding result, details and deferred work.",
                 implementation_fixes=0, other_fixes=0, minor_edits=0, substantial=False, evidence=["Focused fixture validation"])
    value.update(kwargs)
    return value


def final_round_actions(done=None):
    return [("final_opus", report(findings=[])), ("final_astra", report(findings=[])),
            ("claude", report(findings=[])),
            ("final_triage", (lambda: dict(done(), assessments=[])) if done else report(assessments=[]))]


def pair_actions(done=None):
    roles = [*PAIRS["pair_a"], *PAIRS["pair_b"], *PAIRS["final"]]
    actions = [(role, report(findings=[])) for role in roles]
    if done:
        actions[-1] = (roles[-1], lambda: dict(done(), findings=[]))
    return actions


class FixtureTransport:
    def __init__(self, root, actions=()):
        self.root, self.actions, self.calls = root, list(actions), []
        self.lock = threading.Lock()

    def fork(self, root, state, save, heartbeat, control=None, progress=None):
        parent = self
        class Child:
            def run(self, role, prompt, pending, directory):
                # Deterministic fixture order; the separate concurrency test uses a barrier.
                deadline = time.monotonic() + 5
                while True:
                    with parent.lock:
                        if not parent.actions or parent.actions[0][0] == role:
                            return parent.run(role, prompt, pending, directory)
                    heartbeat()
                    if time.monotonic() > deadline:
                        raise AssertionError("Unexpected pair role " + role)
                    time.sleep(.01)
        return Child()

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
        if role in PAIRS["final"] and '"final_gate": {' in prompt and isinstance(result, dict) and "final_gate" not in result:
            result = dict(result, final_gate={"full_run": False, "reason": "Targeted checks cover the stage changes."})
        return json.dumps(result)


class CycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="orc-cycle-test-")
        self.root = Path(self.temp.name) / "repo with spaces"
        self.root.mkdir()
        self.root = self.root.resolve()  # Windows TEMP may use an 8.3 alias.
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

    def review_pass(self, role, **kwargs):
        self.assertEqual(self.state["phase"], role)
        self.transport.actions = [(role, report(**kwargs))]
        self.cycle.review(role)

    def finish_loop(self, role):
        self.review_pass(role)
        self.review_pass(role)

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
        self.state.update(phase="sol", status="blocked", code_started=True, sol_clean=2)
        self.cycle.state = self.state
        self.edit(content="current operator work\n")()
        snapshot = self.repo.snapshot()
        plan = self.root / ".work/reconcile.json"
        prepared = focus_reconcile.write_plan(self.cycle, plan)
        self.assertEqual([(row["path"], row["action"]) for row in prepared["changes"]], [("source.txt", "adopt-file")])
        focus_reconcile.apply(self.cycle, plan)
        self.cycle.check_protected(self.repo.snapshot())
        self.assertEqual(self.repo.snapshot(), snapshot)
        self.assertEqual((self.state["phase"], self.state["sol_clean"], self.state["claude_clean"]), ("code", 0, 0))
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
                parse_report("Final report:\n" + json.dumps(value), "sol")

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
        self.assertEqual(self.state["phase"], "pair_a")
        self.assertEqual(self.state["code_report"], raw)
        self.assertEqual((self.state["sol_clean"], self.state["claude_clean"]), (0, 0))
        self.assertEqual(json.loads(Path(self.state["last"]["report"]).read_bytes())["raw"], raw)

    def test_prefaced_review_report_cannot_hide_blocker_or_missing_evidence(self):
        for value in (report(status="blocked"), report(evidence=[])):
            with self.subTest(value=value):
                self.state.update(phase="sol", sol_clean=0, pending=None)
                with patch.object(self.transport, "run", return_value="Final report:\n" + json.dumps(value)):
                    with self.assertRaises(Blocked):
                        self.cycle.review("sol")
                self.assertEqual(self.state["sol_clean"], 0)

    def test_long_summary_preserves_the_complete_validated_report(self):
        for length in (1199, 1200, 1201, 12000):
            with self.subTest(length=length):
                value = report(summary="\u0416" * length, implementation_fixes=2,
                               other_fixes=1, minor_edits=3, substantial=True)
                self.assertEqual(parse_report(json.dumps(value), "opus_final"), value)
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
        for role in ("coordinate", "code", "sol", "opus_final", "heal"):
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
        cases = [(0, False, "opus_final", 2), (1, False, "astra", 0), (1, True, "astra", 0)]
        for fixes, substantial, phase, clean in cases:
            with self.subTest(fixes=fixes, substantial=substantial):
                self.state.update(review_plan=[], review_substantial=False, phase="astra", sol_passes=3, sol_clean=3, astra_clean=1)
                self.transport.actions = [("astra", report(summary="x" * 1201,
                    implementation_fixes=fixes, substantial=substantial))]
                self.cycle.review("astra")
                self.assertEqual(self.state["phase"], phase)
                self.assertEqual(self.state["astra_clean"], clean)

    def test_long_summary_cannot_certify_an_incomplete_or_blocked_review(self):
        for overrides, error in ((dict(evidence=[]), "completed pass"),
                                 (dict(status="complete"), "completed pass"),
                                 (dict(status="blocked"), "Provider blocker detail")):
            with self.subTest(overrides=overrides):
                self.state.update(phase="opus_final", pending=None, opus_final_clean=1)
                self.transport.actions = [("opus_final", report(summary="x" * 1201,
                    description="Provider blocker detail", **overrides))]
                with self.assertRaisesRegex(Blocked, error):
                    self.cycle.review("opus_final")
                self.assertEqual(self.state["phase"], "opus_final")
                self.assertEqual(self.state["opus_final_clean"], 1)

    def test_retry_legacy_summary_blocker_preserves_review_phase_and_sessions(self):
        import cc_focus
        self.state.update(phase="opus_final", coordinated="opus_final", sol_clean=3,
                          opus_final_clean=1, recovery_unverified=True,
                          sessions={"opus_final": "preserved-review-session"})
        self.transport.actions = [("opus_final", report(summary="x" * 1201))]
        self.cycle.invoke("opus_final")
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
        self.assertEqual(current["phase"], "opus_final")
        self.assertEqual(current["sessions"], self.state["sessions"])
        self.assertEqual(current["sol_clean"], 3)
        self.assertEqual(current["opus_final_clean"], 0)
        self.assertEqual(result_path.read_bytes(), saved)

    def test_new_coding_work_does_not_require_review_fix_counts(self):
        raw = json.dumps(report(substantial=True))
        self.assertTrue(parse_report(raw, "code")["substantial"])
        for role in (None, "sol", "opus_final", "heal", "coordinate"):
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
        self.state.update(sol_clean=2, claude_clean=1)
        self.cycle.recover_review(path)
        self.assertEqual(self.state["phase"], "pair_a")
        self.assertEqual(self.state["status"], "paused")
        self.assertEqual((self.state["sol_clean"], self.state["claude_clean"]), (0, 0))
        self.assertEqual(self.state["sessions"]["code"], "preserved-code-session")
        self.assertIsNone(self.state["blocker"])
        self.assertIsNone(self.state["pending"])
        self.assertIn("Original full coding account", self.state["code_report"])
        self.assertEqual(path.read_bytes(), raw_bytes)
        self.assertEqual(self.repo.snapshot(), snapshot)
        backups = list((self.store.directory / "recoveries").glob("*.json"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(json.loads(backups[0].read_text())["previous_state"]["phase"], "code")
        self.assertEqual(self.store.read()["phase"], "pair_a")

    def test_coding_recovery_bounds_summary_without_shortening_sol_context(self):
        path = self.rejected_coding_fixture()
        result = json.loads(path.read_bytes())
        value = json.loads(result["raw"])
        value["summary"] = "x" * 1201 + "unique summary ending"
        result["raw"] = json.dumps(value)
        path.write_bytes(encode(result))
        saved = path.read_bytes()
        self.cycle.recover_review(path)
        self.assertLessEqual(len(self.state["last"]["summary"]), 1200)
        self.assertIn("unique summary ending", self.cycle.context("sol"))
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
        self.assertEqual(self.state["phase"], "pair_a")
        self.assertEqual((self.state["sol_clean"], self.state["claude_clean"]), (0, 0))
        self.assertEqual(self.state["code_report"], result["raw"])
        self.assertEqual(path.read_bytes(), saved)
        self.assertEqual(self.repo.snapshot(), snapshot)

    def test_new_implementation_report_advances_to_reviews_without_healer(self):
        self.transport.actions = [("coordinate", report()), ("code", self.edit(substantial=True))]
        control = self.focus_control()
        def finish_review():
            self.stop_request(control)
            return report()
        self.transport.actions += [("pair_opus", lambda: dict(finish_review(), findings=[])), ("pair_sol", report(findings=[]))]
        self.assertEqual(self.cycle.run(), 0)
        self.assertEqual([role for role, _ in self.transport.calls], ["coordinate", "code", "pair_opus", "pair_sol"])
        self.assertEqual(self.state["pair_review"]["step"], "decide")
        self.assertEqual(self.state["pair_clean"]["pair_a"], 0)

    def test_recovered_code_still_requires_all_review_passes(self):
        path = self.rejected_coding_fixture()
        self.cycle.recover_review(path)
        control = self.focus_control()
        def finish_reviews():
            self.stop_request(control)
            return report()
        self.transport.calls.clear()
        self.transport.actions = pair_actions(finish_reviews)
        self.assertEqual(self.cycle.run(), 0)
        self.cycle.paired_review_step()  # Safe pause was before the final seal.
        self.assertEqual(self.state["phase"], "publish")
        self.assertEqual([role for role, _ in self.transport.calls], [r for r, _ in pair_actions()])
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
        for phase in ("sol", "claude", "publish", "ci"):
            self.state["phase"] = phase
            with self.subTest(phase=phase), self.assertRaisesRegex(Blocked, "stopped, already-started code"):
                self.cycle.recover_review(path)

    def test_recovery_coordinator_context_allows_report_finalization(self):
        self.rejected_coding_fixture()
        prompt = self.cycle.context("coordinate")
        self.assertIn("recovery of its lost or rejected final report", prompt)
        self.assertIn("Confirm this report recovery route", prompt)

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
        self.assertEqual(self.store.read()["phase"], "pair_a")

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
        self.state.update(phase="opus_final", sol_passes=3, sol_clean=3, opus_final_clean=1,
                          reviewed=self.repo.snapshot())
        before = self.repo.snapshot()
        self.cycle.correct("Keep the existing stage; handle empty input explicitly.")
        self.assertEqual(self.state["phase"], "code")
        self.assertEqual(self.state["status"], "paused")
        self.assertEqual(self.state["iteration"], 1)
        self.assertEqual(self.repo.snapshot(), before)
        self.assertEqual(self.state["sessions"]["code"], "preserved-code-session")
        self.assertEqual((self.state["sol_clean"], self.state["opus_final_clean"]), (0, 0))
        self.assertIsNone(self.state["pending"])
        self.assertIsNone(self.state["blocker"])
        self.assertIsNone(self.state["reviewed"])
        correction = self.store.read()["corrections"][0]
        self.assertIn("empty input", Path(correction["path"]).read_text())
        self.assertEqual(json.loads(Path(correction["archive"]).read_text())["previous_state"]["phase"], "opus_final")
        for role in ("coordinate", "code", "sol", "opus_final", "heal"):
            self.assertIn(correction["id"], self.cycle.context(role))
            self.assertIn("Do not select the next unfinished", self.cycle.context(role))
        with self.assertRaisesRegex(Blocked, "not a coding result"):
            self.cycle.recover_review(old_result)

    def precode_reconciliation_fixture(self):
        import focus_reconcile
        self.edit(content="pre-existing operator work\n")()
        self.edit(name="untouched.txt", content="protected unrelated work\n")()
        self.state = fresh_state(self.repo)
        # A real stage start writes the brief record with the iteration.
        self.state.update(iteration=9, project_brief={"iteration": 9, "sha256": None}, status="blocked",
                          last={"role": "publish", "summary": "Previous stage published"},
                          task={"id": "old-proposal", "title": "Provisional task", "plan": "source.txt", "iteration": 9},
                          sessions={"code": "previous-coding-session"},
                          blocker={"code": "protected-work", "status": "blocked"})
        self.cycle.state = self.state
        self.edit(content="current operator work\n")()
        self.store.save(self.state)
        plan = self.root / ".work/precode-plan.json"
        focus_reconcile.write_plan(self.cycle, plan)
        return plan

    def test_reconcile_before_coding_is_model_free_and_preserves_iteration(self):
        import cc_focus
        path = self.precode_reconciliation_fixture()
        before = self.repo.snapshot()
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.Lease") as lease, \
                patch("cycle_transport.Transport.run", side_effect=AssertionError("No model during handover")):
            lease.return_value.__enter__.return_value.pwsh = "pwsh"
            self.assertEqual(cc_focus.main(["reconcile", "--apply-plan", str(path)]), 0)
        state = self.store.read()
        self.assertEqual((state["iteration"], state["phase"], state["status"]), (9, "code", "paused"))
        self.assertFalse(state["code_started"])
        self.assertIsNone(state["task"])
        self.assertEqual(state["sessions"], {"code": "previous-coding-session"})
        self.assertNotIn("source.txt", state["protected"])
        self.assertIn("untouched.txt", state["protected"])
        self.assertEqual(self.repo.snapshot(), before)
        self.assertTrue(state["corrections"][-1]["before_code"])
        self.cycle.state = state
        self.cycle.check_protected(before)
        context = self.cycle.context("coordinate")
        self.assertIn("BEFORE coding began", context)
        self.assertIn("Do not reopen it", context)
        self.assertNotIn("If the original stage cannot be identified", context)

    def test_precode_reconciliation_requires_coding_and_both_reviews(self):
        import focus_reconcile
        self.remote()
        path = self.precode_reconciliation_fixture()
        focus_reconcile.apply(self.cycle, path)
        self.transport.actions = [
            ("coordinate", report()), ("code", self.edit(content="next stage implementation\n")),
            *pair_actions(),
            ("coordinate", report()), ("publish", report(summary="Update reviewed source")),
            ("coordinate", report(status="complete")),
        ]
        self.assertEqual(self.cycle.run(), 0)
        self.assertEqual([role for role, _ in self.transport.calls if role != "coordinate"],
                         ["code", *[r for r, _ in pair_actions()], "publish"])
        coding_context = next(prompt for role, prompt in self.transport.calls if role == "code")
        self.assertNotIn('"coding_recovery"', coding_context)
        self.assertIn("next unfinished stage", coding_context)
        archived = json.loads((self.store.directory / "iterations/000009.json").read_text())
        self.assertTrue(archived["corrections"][-1]["before_code"])
        self.assertEqual(self.state["iteration"], 10)
        self.assertEqual(self.state["corrections"], [])

    def test_precode_reconciliation_cannot_complete_with_unpublished_adopted_work(self):
        import focus_reconcile
        path = self.precode_reconciliation_fixture()
        focus_reconcile.apply(self.cycle, path)
        self.transport.actions = [("coordinate", report(status="complete")), ("heal", report(status="blocked"))]
        self.assertEqual(self.cycle.run(), 3)
        self.assertEqual(self.state["blocker"]["code"], "premature-completion")
        self.assertFalse(self.state["code_started"])
        self.assertEqual(self.state["iteration"], 9)

    def test_coding_recovery_context_requires_a_previous_attempt(self):
        self.state.update(code_started=True, pending={"role": "code", "resume_code": False})
        self.assertNotIn('"coding_recovery"', self.cycle.context("code"))
        self.state["pending"]["attempts"] = 1
        self.assertIn('"coding_recovery"', self.cycle.context("code"))

    def test_corrected_cycle_requires_coding_and_all_reviews_before_publication(self):
        self.remote()
        self.rejected_coding_fixture()
        self.cycle.correct("Address the missing edge case.")
        correction_id = self.state["correction_revision"]
        self.transport.actions = [
            ("coordinate", report()), ("code", self.edit(content="corrected\n")),
            *pair_actions(),
            ("coordinate", report()), ("publish", report(summary="Update reviewed source")),
            ("coordinate", report(status="complete")),
        ]
        self.transport.calls.clear()
        self.assertEqual(self.cycle.run(), 0)
        self.assertEqual([role for role, _ in self.transport.calls if role != "coordinate"],
                         ["code", *[r for r, _ in pair_actions()], "publish"])
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
        self.assertEqual(self.state["phase"], "pair_a")
        self.assertEqual((self.state["sol_clean"], self.state["claude_clean"]), (0, 0))

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
        self.assertEqual(self.store.read()["phase"], "pair_a")  # Profile 8 restarts reviews at pair A.
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

    def test_full_cycle_uses_pairs_and_preserves_coding_account(self):
        self.remote()
        self.transport.actions = [
            ("coordinate", report()), ("code", self.edit(description="Full unabridged implementation description")),
            *pair_actions(),
            ("coordinate", report()), ("publish", report(summary="Update reviewed source")),
            ("coordinate", report(status="complete")),
        ]
        with patch.object(self.cycle, "wait_ci", wraps=self.cycle.wait_ci) as wait:
            self.assertEqual(self.cycle.run(), 0)
            wait.assert_called_once()
        self.assertEqual(self.state["iteration"], 2)
        self.assertEqual(self.state["status"], "complete")
        copies = [view for path in self.store.directory.glob("pair-reviews/**/view.json")
                  if "__review__/coding-full.json" in (view := json.loads(path.read_text()))["files"]]
        self.assertTrue(copies)
        self.assertIn("Full unabridged implementation description",
                      read_source(copies[0], "__review__/coding-full.json").decode())
        for role, prompt in self.transport.calls:
            if role == "pair_sol":
                self.assertIn("__review__/coding.json", prompt)
            if role == "coordinate":
                self.assertNotIn("Full unabridged implementation description", prompt)

    def test_four_reviewer_profiles_are_fixed(self):
        self.assertEqual(PROFILES['sol'], ('codex', 'gpt-6.1-sol', 'xhigh'))
        self.assertEqual(PROFILES['claude'], ('claude', 'claude-fable-5-1', 'xhigh'))
        self.assertEqual(PROFILES['astra'], ('codex', 'gpt-6-astra', 'xhigh'))
        self.assertEqual(PROFILES['opus'], ('claude', 'opus', 'xhigh'))
        self.assertEqual(PROFILES['code'], ('claude', 'opus', 'xhigh'))
        self.assertEqual(PROFILES['heal'], ('codex', 'gpt-6-astra', 'xhigh'))
        self.assertEqual(PROFILES['publish'], ('codex', 'gpt-5.6-luna', 'xhigh'))
        self.assertEqual(PROFILES['coordinate'], ('codex', 'gpt-5.6-luna', 'xhigh'))
        self.assertEqual(REVIEW_ROLES, ('opus', 'sol', 'astra', 'opus_final'))
        self.assertEqual(REVIEW_TARGETS, {'opus': 2, 'sol': 2, 'astra': 2, 'opus_final': 2})

    def test_current_profiles_deliver_execution_rules_and_effort_on_start_and_resume(self):
        for role, (provider, model, effort) in PROFILES.items():
            with self.subTest(role=role):
                self.state['inspection'] = {'root': str(self.root), 'files': {'source.txt': __import__('hashlib').sha256((self.root / 'source.txt').read_bytes()).hexdigest()}, 'stage_paths': ['source.txt'], 'diffs': {}}
                self.state['inspection_path'] = str(self.root / 'manifest.json')
                transport = Transport(self.root, self.state, self.store.save, lambda: None)
                transport.commands[provider] = [sys.executable, str(Path(__file__).resolve()), 'fixture', provider]
                for attempt in ('start', 'resume'):
                    directory = self.store.directory / ('profile-' + role + '-' + attempt)
                    directory.mkdir(parents=True)
                    session = self.state['sessions'].get(role)
                    with patch.dict(os.environ, ORCHESTRA_FIXTURE_MODEL=model, ORCHESTRA_FIXTURE_EFFORT=effort,
                                    ORCHESTRA_FIXTURE_ROLE=role):
                        result = transport.run(role, 'Verify selected profile', {'id': role + '-' + attempt}, directory)
                    self.assertEqual(parse_report(result, role)['status'], 'done')
                    prompt = (directory / 'prompt.txt').read_text(encoding='utf-8')
                    self.assertIn(COMMAND_EXECUTION_CONTRACT, prompt)
                    if role == 'code':
                        self.assertIn(CODE_IMPLEMENTATION_CONTRACT, prompt)
                        self.assertNotIn(PAIR_CONTRACT, prompt)
                    if role in PAIR_READONLY:
                        self.assertIn('Use only focus_inspect', prompt)
                    if provider == 'claude':
                        saved = json.loads((directory / 'claude-diagnostics.json').read_text(encoding='utf-8'))
                        if role in PAIR_READONLY:  # Paired inspectors start without user/project settings.
                            self.assertEqual((saved['launch']['instruction_files'],
                                              saved['completion']['instruction_files']), ([], []))
                        self.assertEqual(saved['launch']['instruction_files_captured'], 'before-start')
                        self.assertEqual(saved['launch']['instruction_files_enabled'], role not in PAIR_READONLY)
                        self.assertEqual(saved['launch']['cwd'], str(self.root))
                    if role == 'repair_execute':
                        self.assertIn('ONLY B/FINAL repair_execute with operation=fix must not build or test', prompt)
                    if attempt == 'resume':
                        self.assertEqual(self.state['sessions'][role], session)

    def test_executor_report_only_restriction_follows_common_execution_rules(self):
        for role in PAIR_WRITERS:
            with self.subTest(role=role):
                self.state['sessions'][role] = 'saved-executor-session'
                transport = Transport(self.root, self.state, self.store.save, lambda: None)
                directory = self.store.directory / role
                directory.mkdir(parents=True)
                pending = {'id': role, 'attempts': 1, 'report_repair': {'reason': 'invocation-accounting'}}
                with patch.object(transport, '_claude', return_value=json.dumps(report())) as provider:
                    transport.run(role, 'Correct only the saved JSON report.', pending, directory)
                self.assertEqual(provider.call_args.args[3], 'saved-executor-session')
                prompt = provider.call_args.args[4]
                self.assertIn(COMMAND_EXECUTION_CONTRACT, prompt)
                self.assertIn('They do not permit tools, builds, or tests that the role or current operation forbids.', prompt)
                self.assertLess(prompt.index(COMMAND_EXECUTION_CONTRACT),
                                prompt.index('This invocation is REPORT-ONLY CORRECTION'))
                self.assertIn('Do not repeat review, builds, or tests', prompt)

    def test_sol_defers_opus_until_two_clean_then_skips_sol(self):
        self.cycle.reset_reviews()
        self.state.update(phase="opus", review_plan=[])
        self.review_pass("opus", implementation_fixes=1, substantial=True)
        self.finish_loop("opus")
        self.review_pass("sol", implementation_fixes=1, substantial=True)
        self.assertEqual(self.state["phase"], "sol")
        self.review_pass("sol")
        self.assertEqual(self.state["phase"], "sol")
        self.state = self.store.read()
        self.cycle.state = self.state
        self.review_pass("sol", implementation_fixes=1, substantial=False)
        self.assertTrue(self.state["review_substantial"])
        self.finish_loop("sol")
        self.assertEqual(self.state["phase"], "opus")
        self.assertEqual([v["role"] for v in self.state["review_plan"]], ["opus", "astra", "opus_final"])
        self.finish_loop("opus")
        self.assertEqual(self.state["phase"], "astra")
        self.finish_loop("astra")
        self.finish_loop("opus_final")
        self.assertEqual(self.state["phase"], "final")
        self.assertIsNone(self.state["reviewed"])

    def test_every_reviewer_small_fix_stays_in_current_loop(self):
        for role in REVIEW_ROLES:
            with self.subTest(role=role):
                self.state.update(phase=role, review_plan=[], review_substantial=False, reviewed=None)
                self.state[role + "_clean"] = 1
                self.review_pass(role, implementation_fixes=1)
                self.assertEqual(self.state["phase"], role)
                self.assertEqual(self.state[role + "_clean"], 0)
                self.assertFalse(self.state["review_substantial"])
                self.finish_loop(role)
                expected = {"opus": "sol", "sol": "astra", "astra": "opus_final", "opus_final": "final"}[role]
                self.assertEqual(self.state["phase"], expected)

    def test_full_test_eligibility_tracks_current_visit_and_retry(self):
        def context(role):
            return json.loads(self.cycle.context(role).split("Runtime context:\n", 1)[1])
        for role in PROFILES:
            if role in (*PAIR_ROLES, "publish", "final_fix", "final_cleanup"):
                continue  # Requires a publication/triage seal, and never permits broad testing.
            for clean in (0, 1):
                self.state[role + "_clean"] = clean
                self.assertEqual(context(role)["verification"]["full_run_allowed"],
                                 role == "opus_final" or (role == "astra" and clean == 1))
        self.state.update(phase="opus_final", review_plan=[], review_substantial=False, opus_final_clean=1)
        self.review_pass("opus_final", implementation_fixes=1, substantial=True)
        self.assertTrue(context("opus_final")["verification"]["full_run_allowed"])
        self.finish_loop("opus_final")
        self.assertFalse(context("astra")["verification"]["full_run_allowed"])
        self.review_pass("astra")
        self.assertTrue(context("astra")["verification"]["full_run_allowed"])
        # An interrupted pass invalidates the preceding streak before building its prompt.
        self.state["pending"] = {"id": "retry-eligibility", "role": "astra", "attempts": 1,
                                 "before": self.repo.snapshot()}
        self.review_pass("astra")
        sent = json.loads(self.transport.calls[-1][1].split("Runtime context:\n", 1)[1])
        self.assertFalse(sent["verification"]["full_run_allowed"])
        self.assertEqual(sent["astra_clean"], 0)

    def test_opus_review_session_is_distinct_and_resumes_its_own_conversation(self):
        self.state["sessions"]["code"] = "implementation-session"
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude"]
        for index in range(2):
            directory = self.store.directory / ("opus-session-" + str(index))
            directory.mkdir(parents=True)
            with patch.dict(os.environ, ORCHESTRA_FIXTURE_MODEL="opus", ORCHESTRA_FIXTURE_EFFORT="xhigh"):
                parse_report(transport.run("opus", "Review only", {"id": str(index)}, directory), "opus")
            if index == 0:
                review_session = self.state["sessions"]["opus"]
                self.assertNotEqual(review_session, "implementation-session")
            self.assertEqual(self.state["sessions"]["opus"], review_session)
            self.assertEqual(self.state["sessions"]["code"], "implementation-session")

    def test_profile_three_and_four_migration_and_publishing_preserve_work(self):
        for old_profile, phase, started in [(v, p, started) for v in (3, 4)
                for p, started in [("sol", False), ("astra", False), ("claude", False),
                                   ("publish", False), ("publish", True), ("ci", True)]]:
            with self.subTest(version=old_profile, phase=phase, started=started):
                self.state.update(review_profile=old_profile, phase=phase, publication_started=started,
                                  reviewed=self.repo.snapshot(), pending=None,
                                  sessions={"code": "coding", "sol": "old-review"})
                self.state.pop("publication_review_profile", None)
                before = self.repo.snapshot()
                self.cycle.upgrade_review_profile()
                self.assertEqual(self.state["review_profile"], REVIEW_PROFILE_VERSION)
                self.assertEqual(self.state["phase"], phase if started else "pair_a")
                self.assertEqual(self.state["sessions"], {"code": "coding"})
                if started:
                    self.assertEqual(self.state["publication_review_profile"], old_profile)
                    self.assertEqual(self.state["reviewed"], before)
                else:
                    self.assertEqual(self.state["review_plan"], [])
                    self.assertEqual(self.state["pair_clean"], {"pair_a": 0, "pair_b": 0})
                self.assertEqual(self.repo.snapshot(), before)

    def test_sol_does_not_fall_back_to_the_previous_model(self):
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands['codex'] = [sys.executable, str(Path(__file__).resolve()), 'fixture', 'codex', 'old-sol-only']
        directory = self.store.directory / 'unavailable-sol'
        directory.mkdir(parents=True)
        with self.assertRaises(Blocked) as caught:
            transport.run('sol', 'Review', {'id': 'unavailable-sol'}, directory)
        self.assertEqual(caught.exception.code, 'model-unavailable')
        self.assertNotIn('sol', self.state['sessions'])

    def test_astra_review_needs_two_clean_passes(self):
        self.state.update(phase='astra', sol_clean=3)
        for fixes, other, clean, phase in ((0, 0, 1, 'astra'), (1, 0, 0, 'astra'),
                                           (0, 1, 0, 'astra'), (0, 0, 1, 'astra'), (0, 0, 2, 'opus_final')):
            self.transport.actions = [('astra', report(implementation_fixes=fixes, other_fixes=other))]
            self.cycle.review('astra')
            self.assertEqual((self.state['astra_clean'], self.state['phase']), (clean, phase))
            self.assertIsNone(self.state['reviewed'])

    def test_second_astra_substantial_fix_returns_to_first_review(self):
        self.state.update(phase="astra", opus_clean=2, sol_clean=2, astra_clean=1)
        self.review_pass("astra", implementation_fixes=1, substantial=True)
        self.assertEqual(self.state["phase"], "astra")
        self.assertTrue(self.state["review_substantial"])
        self.finish_loop("astra")
        self.assertEqual(self.state["phase"], "opus")
        self.review_pass("opus", implementation_fixes=1, substantial=True)
        self.finish_loop("opus")
        self.assertEqual(self.state["phase"], "opus_final")
        self.assertEqual(self.state["sol_clean"], 2)
    def test_final_review_repeats_until_clean_and_seals_latest_work(self):
        self.state.update(phase='opus_final', sol_clean=3, astra_clean=2)
        self.transport.actions = [('opus_final', self.edit(other_fixes=1)),
                                  ('opus_final', self.edit(content='small fix\n', implementation_fixes=1)),
                                  ('opus_final', report()), ('opus_final', report())]
        for _ in range(2):
            self.cycle.review('opus_final')
            self.assertEqual(self.state['phase'], 'opus_final')
            self.assertEqual(self.state['opus_final_clean'], 0)
            self.assertIsNone(self.state['reviewed'])
        self.cycle.review('opus_final')
        self.cycle.review('opus_final')
        self.assertEqual(self.state['phase'], 'final')
        self.assertEqual(self.state['opus_final_clean'], 2)
        self.assertIsNone(self.state['reviewed'])
        self.assertEqual(self.state['display_reviews']['opus_final']['completed'], 4)

    def test_late_opus_substantial_fix_finishes_two_clean_then_repeats_only_astra(self):
        self.state.update(phase="opus_final", opus_clean=2, sol_clean=2, astra_clean=2)
        self.review_pass("opus_final", implementation_fixes=1, substantial=True)
        self.review_pass("opus_final")
        self.state = self.store.read()
        self.cycle.state = self.state
        self.assertTrue(self.state["review_substantial"])
        self.review_pass("opus_final")
        self.assertEqual(self.state["phase"], "astra")
        self.assertEqual([v["role"] for v in self.state["review_plan"]], ["astra"])
        self.finish_loop("astra")
        self.assertEqual(self.state["phase"], "final")
        self.assertIsNone(self.state["reviewed"])
        self.assertEqual((self.state["opus_clean"], self.state["sol_clean"]), (2, 2))

    def test_final_small_fixes_and_minor_edits_never_return_to_an_earlier_review(self):
        for field, expected in (('implementation_fixes', 'opus_final'), ('other_fixes', 'opus_final'),
                                ('minor_edits', 'final')):
            with self.subTest(field=field):
                self.state.update(phase='opus_final', sol_passes=5, sol_clean=3, astra_clean=2,
                                  opus_final_clean=1, reviewed=None, review_plan=[], review_substantial=False)
                self.transport.actions = [('opus_final', self.edit(content=field, **{field: 1}))]
                self.cycle.review('opus_final')
                self.assertEqual(self.state['phase'], expected)
                self.assertEqual((self.state['sol_passes'], self.state['sol_clean'], self.state['astra_clean']), (5, 3, 2))
                if expected == 'opus_final':
                    self.assertEqual(self.state['opus_final_clean'], 0)
                    self.assertIsNone(self.state['reviewed'])
                else:
                    self.assertIsNone(self.state['reviewed'])

    def test_cached_fable_fix_after_restart_still_returns_to_astra(self):
        self.state.update(phase='opus_final', sol_passes=5, sol_clean=3, astra_clean=2)
        self.transport.actions = [('opus_final', self.edit(implementation_fixes=1, substantial=True))]
        self.cycle.invoke('opus_final')  # Provider completed; phase transition did not persist.
        self.state = self.store.read()
        self.cycle.state = self.state
        self.cycle.review('opus_final')
        self.assertEqual(self.state['phase'], 'opus_final')
        self.assertTrue(self.state['review_substantial'])
        self.assertEqual((self.state['sol_passes'], self.state['sol_clean']), (5, 3))
        self.assertEqual((self.state['astra_clean'], self.state['opus_final_clean']), (2, 0))
        self.assertEqual(len(self.transport.calls), 1)
        self.assertIsNone(self.state['reviewed'])

    def test_explicit_full_review_restart_takes_precedence_over_final_fix(self):
        self.state.update(phase='opus_final', sol_clean=0, astra_clean=0, pending={
            'id': 'intervened-final', 'role': 'opus_final', 'before': self.repo.snapshot(),
            'restart_reviews': True, 'operator_intervened': True})
        self.transport.actions = [('opus_final', self.edit(implementation_fixes=1, substantial=True))]
        self.cycle.review('opus_final')
        self.assertEqual(self.state['phase'], 'pair_a')
        self.assertEqual([self.state[k + '_clean'] for k in REVIEW_ROLES], [0, 0, 0, 0])
        self.assertIsNone(self.state['reviewed'])

    def test_astra_substantial_fix_after_late_opus_adds_initial_opus_then_final_round(self):
        self.state.update(phase="opus_final", opus_clean=2, sol_clean=2, astra_clean=2)
        self.review_pass("opus_final", implementation_fixes=1, substantial=True)
        self.finish_loop("opus_final")
        self.review_pass("astra", implementation_fixes=1, substantial=True)
        self.finish_loop("astra")
        self.assertEqual(self.state["phase"], "opus")
        self.finish_loop("opus")
        self.assertEqual(self.state["phase"], "final")
        self.assertEqual(self.state["sol_clean"], 2)

    def test_final_incomplete_or_unreported_change_cannot_publish(self):
        for response in (report(evidence=[]), report(status='complete'), self.edit()):
            with self.subTest(response=response):
                self.state.update(phase='opus_final', pending=None, sol_clean=3, astra_clean=2)
                self.transport.actions = [('opus_final', response), ('opus_final', report())]
                with self.assertRaises(Blocked):
                    self.cycle.review('opus_final')
                self.assertIsNone(self.state['reviewed'])
                self.assertEqual(self.state['opus_final_clean'], 0)

    def test_interrupted_final_review_with_changes_returns_to_astra(self):
        self.state.update(phase='opus_final', sol_clean=3, astra_clean=2,
                          pending={'id': 'interrupted-final', 'role': 'opus_final', 'before': self.repo.snapshot(), 'attempts': 1})
        self.edit()()
        self.transport.actions = [('opus_final', report(other_fixes=1))]
        self.cycle.review('opus_final')
        self.assertEqual(self.state['phase'], 'opus_final')
        self.assertTrue(self.state['review_substantial'])
        self.assertEqual(self.state['sol_clean'], 3)
        self.assertEqual(self.state['astra_clean'], 2)

    def test_final_review_failure_after_edits_cannot_reuse_prior_credit(self):
        self.state.update(phase='opus_final', sol_clean=3, astra_clean=2)
        self.transport.actions = [('opus_final', self.edit(status='blocked', implementation_fixes=1))]
        with self.assertRaises(Blocked) as caught:
            self.cycle.review('opus_final')
        self.cycle.handle_block(caught.exception)
        self.assertEqual(self.state['blocker']['phase'], 'opus_final')
        self.assertEqual(self.state['sol_clean'], 3)
        self.assertEqual(self.state['astra_clean'], 2)

        self.assertTrue(self.state["review_substantial"])
    def test_legacy_review_profile_archives_credit_and_keeps_work(self):
        self.edit()()
        self.state.pop('review_profile')
        self.state.update(phase='publish', sol_clean=0, astra_passes=3, astra_clean=3,
                          claude_clean=2, reviewed=self.repo.snapshot(), publication_started=False,
                          publication_paths=['source.txt'], publication_prepared={'subject': 'Old preparation'},
                          sessions={'code': 'coder', 'astra': 'old-first', 'claude': 'old-fable', 'heal': 'healer'},
                          pending={'id': 'old-publisher', 'role': 'publish'})
        previous = json.loads(json.dumps(self.state))
        work = self.repo.snapshot()
        self.cycle.upgrade_review_profile()
        self.assertEqual(json.loads(Path(self.state['review_profile_archive']).read_text()), previous)
        self.assertEqual(self.state['phase'], 'pair_a')
        self.assertEqual(self.state['sessions'], {'code': 'coder', 'heal': 'healer'})
        self.assertEqual(self.state['publication_paths'], ['source.txt'])
        self.assertFalse(self.state['publication_started'])
        self.assertIsNone(self.state['pending'])
        self.assertIsNone(self.state['reviewed'])
        self.assertNotIn('publication_prepared', self.state)
        self.assertEqual([self.state[k + '_clean'] for k in ('opus', 'claude', 'astra')], [0, 0, 0])
        self.assertEqual(self.repo.snapshot(), work)
        after = json.loads(json.dumps(self.state))
        self.cycle.upgrade_review_profile()
        self.assertEqual(self.state, after)

    def test_legacy_resume_runs_all_new_reviews_before_publication(self):
        self.edit()()
        self.state.pop('review_profile')
        self.state.pop('sol_clean')
        self.state.pop('sol_passes')
        self.state.update(phase='claude', astra_passes=3, astra_clean=3, claude_clean=1,
                          code_started=True, code_report='Original completed implementation',
                          last_snapshot=self.repo.snapshot(),
                          pending={'id': 'legacy-review', 'role': 'claude', 'attempts': 1},
                          sessions={'astra': 'old-astra', 'claude': 'old-fable'})
        control = self.focus_control()
        def final_pass():
            self.stop_request(control)
            return report()
        self.transport.actions = pair_actions(final_pass)
        self.assertEqual(self.cycle.run(), 0)
        self.cycle.paired_review_step()
        self.assertEqual([role for role, _ in self.transport.calls], [r for r, _ in pair_actions()])
        self.assertEqual((self.state['phase'], self.state['status']), ('publish', 'paused'))
        self.assertEqual(self.state['pair_clean'], {'pair_a': 1, 'pair_b': 1})
        self.assertEqual(self.state['code_report'], 'Original completed implementation')
        self.assertEqual(self.state['reviewed'], self.repo.snapshot())
    def test_profile_upgrade_keeps_coding_and_completed_publication_continuation(self):
        for phase in ('code', 'publish', 'ci'):
            with self.subTest(phase=phase):
                self.state.pop('review_profile', None)
                self.state.update(phase=phase, pending={'id': phase, 'role': phase},
                                  publication_started=True, reviewed=self.repo.snapshot(), published={'sha': 'known-pushed-sha'})
                self.cycle.upgrade_review_profile()
                self.assertEqual(self.state['phase'], phase)
                self.assertEqual(self.state['pending']['id'], phase)
                self.assertEqual(self.state['published']['sha'], 'known-pushed-sha')
                self.assertEqual(self.state['reviewed'], self.repo.snapshot())

    def test_profile_upgrade_failure_preserves_state_and_future_profiles(self):
        self.state.pop('review_profile')
        previous = json.loads(json.dumps(self.state))
        with patch.object(self.store, 'save', side_effect=OSError('disk full')):
            with self.assertRaises(OSError):
                self.cycle.upgrade_review_profile()
        self.assertEqual(self.state, previous)
        self.state['review_profile'] = 999
        with self.assertRaisesRegex(Blocked, 'newer runtime'):
            self.cycle.upgrade_review_profile()
        self.assertEqual(self.state['review_profile'], 999)

    def test_profile_two_migration_restarts_each_unpublished_review_phase(self):
        for phase in ('opus', 'claude', 'astra', 'publish'):
            with self.subTest(phase=phase):
                self.state.update(review_profile=2, phase=phase, sol_clean=3, claude_clean=2, astra_clean=1,
                                  publication_started=False, reviewed=self.repo.snapshot(),
                                  pending={'id': 'previous-' + phase, 'role': phase, 'turn_id': 'old-turn'},
                                  sessions={role: 'old-' + role for role in PROFILES})
                work = self.repo.snapshot()
                previous = json.loads(json.dumps(self.state))
                self.cycle.upgrade_review_profile()
                self.assertEqual(self.state['review_profile'], REVIEW_PROFILE_VERSION)
                self.assertEqual(self.state['phase'], 'pair_a')
                self.assertIsNone(self.state['pending'])
                self.assertIsNone(self.state['reviewed'])
                self.assertEqual(self.state['sessions'], {'code': 'old-code', 'publish': 'old-publish',
                                                        'coordinate': 'old-coordinate', 'heal': 'old-heal'})
                self.assertEqual([self.state[role + '_clean'] for role in REVIEW_ROLES], [0, 0, 0, 0])
                self.assertEqual(json.loads(Path(self.state['review_profile_archive']).read_bytes()), previous)
                self.assertEqual(self.repo.snapshot(), work)
                saved = json.loads(json.dumps(self.state))
                self.cycle.upgrade_review_profile()
                self.assertEqual(self.state, saved)

    def test_profile_two_coding_recovery_preserves_session_and_intent_with_new_model(self):
        self.edit()()
        self.state.update(review_profile=2, phase='code', code_started=True,
                          sessions={'code': 'old-fable', 'coordinate': 'coordinator', 'heal': 'healer'},
                          pending={'id': 'same-stage', 'role': 'code', 'before': self.state['baseline'],
                                   'attempts': 1, 'resolved_model': 'old-model'})
        before = self.repo.snapshot()
        self.cycle.upgrade_review_profile()
        self.assertEqual((self.state['phase'], self.state['pending']['id']), ('code', 'same-stage'))
        self.assertEqual(self.state['sessions']['code'], 'old-fable')
        self.assertNotIn('resolved_model', self.state['pending'])
        self.assertEqual(self.state['pending']['before'], self.state['baseline'])
        self.assertIn('coding_recovery', self.cycle.context('code'))
        self.assertEqual(self.repo.snapshot(), before)
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands['claude'] = [sys.executable, str(Path(__file__).resolve()), 'fixture', 'claude']
        directory = self.store.directory / 'migrated-coder'
        directory.mkdir(parents=True)
        transport.run('code', self.cycle.context('code'), self.state['pending'], directory)
        self.assertEqual(self.state['sessions']['code'], 'old-fable')
        self.assertEqual(self.state['pending']['resolved_model'], 'claude-opus-5-5')

    def test_profile_two_publication_keeps_its_seal_and_same_pending_turn(self):
        for phase in ('publish', 'ci'):
            with self.subTest(phase=phase):
                seal = self.repo.snapshot()
                self.state.update(review_profile=2, phase=phase, publication_started=True,
                                  reviewed=seal, published={'sha': 'already-pushed'},
                                  publication_prepared={'subject': 'Prepared earlier'},
                                  sessions={'publish': 'old-publisher', 'heal': 'healer'},
                                  pending={'id': 'same-publication', 'role': 'publish', 'turn_id': 'old-turn'})
                self.cycle.upgrade_review_profile()
                self.assertEqual(self.state['phase'], phase)
                self.assertEqual(self.state['publication_review_profile'], 2)
                self.assertEqual(self.state['reviewed'], seal)
                self.assertEqual(self.state['published'], {'sha': 'already-pushed'})
                self.assertEqual(self.state['publication_prepared'], {'subject': 'Prepared earlier'})
                self.assertEqual(self.state['pending']['id'], 'same-publication')
                self.assertEqual(self.state['pending']['turn_id'], 'old-turn')
                self.assertEqual(self.state['sessions']['publish'], 'old-publisher')
                self.assertIn('previous review profile', self.cycle.context('coordinate'))

    def test_profile_two_migration_preserves_pending_healing_and_old_publication_seal(self):
        self.state.update(review_profile=2, phase='astra',
                          blocker={'phase': 'astra', 'status': 'healing'},
                          pending={'id': 'same-healer', 'role': 'heal', 'turn_id': 'healer-turn'},
                          sessions={'heal': 'healer', 'astra': 'old-review'})
        self.cycle.upgrade_review_profile()
        self.assertEqual((self.state['phase'], self.state['blocker']['phase']), ('pair_a', 'pair_a'))
        self.assertEqual(self.state['pending']['turn_id'], 'healer-turn')
        self.assertEqual(self.state['sessions'], {'heal': 'healer'})
        self.state.update(review_profile=2, phase='ci', publication_review_profile=1)
        self.cycle.upgrade_review_profile()
        self.assertEqual(self.state['publication_review_profile'], 1)

    def test_profile_upgrade_preserves_unresolved_delivery_without_mutating(self):
        self.state.pop('review_profile')
        self.state.update(phase='astra', pending={'id': 'old-pass', 'role': 'astra'})
        target = {'iteration': 1, 'invocation': 'old-pass', 'role': 'astra', 'generation': 1}
        self.cycle.messages.add(target, 'Do not lose this instruction')
        before = json.loads(json.dumps(self.state))
        with self.assertRaises(MessagePending):
            self.cycle.upgrade_review_profile()
        self.assertEqual(self.state, before)
        self.assertFalse((self.store.directory / 'review-profiles').exists())

    def test_opus_alias_rejects_wrong_family_and_model_changes(self):
        for variant, code in [('opus-wrong-family', 'provider-profile'), ('opus-switch', 'model-rerouted'),
                              ('opus-before-init', 'model-rerouted')]:
            with self.subTest(variant=variant):
                transport = Transport(self.root, self.state, self.store.save, lambda: None)
                transport.commands['claude'] = [sys.executable, str(Path(__file__).resolve()), 'fixture', 'claude', variant]
                directory = self.store.directory / variant
                directory.mkdir(parents=True)
                with self.assertRaises(Blocked) as caught:
                    transport.run('code', 'Implement with Opus', {'id': variant}, directory)
                self.assertEqual(caught.exception.code, code)

    def test_opus_alias_records_resolved_version_and_rejects_resume_drift(self):
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands['claude'] = [sys.executable, str(Path(__file__).resolve()), 'fixture', 'claude']
        directory = self.store.directory / 'opus-version'
        directory.mkdir(parents=True)
        pending = {'id': 'opus-version'}
        transport.run('code', 'Implement with Opus', pending, directory)
        self.assertEqual(pending['resolved_model'], 'claude-opus-5-5')
        pending['resolved_model'] = 'claude-opus-5'
        with self.assertRaisesRegex(Blocked, 'interrupted invocation'):
            transport.run('code', 'Continue same implementation', pending, directory)

    def test_sol_other_fixes_always_reset_the_clean_streak(self):
        self.state.update(phase="sol")
        for fixes, expected in [(0, 1), (1, 0), (0, 1), (1, 0), (0, 1), (0, 2)]:
            self.review_pass("sol", other_fixes=fixes)
            self.assertEqual(self.state["sol_clean"], expected)
        self.assertEqual(self.state["phase"], "astra")
    def test_minor_edits_do_not_reset_clean_passes(self):
        self.state.update(phase="sol", coordinated="sol")
        self.transport.actions = [("sol", self.edit(content=str(i), minor_edits=1)) for i in range(2)]
        for _ in range(2):
            self.cycle.review("sol")
        self.assertEqual(self.state["phase"], "astra")

    def test_repeated_substantial_late_opus_fixes_do_not_start_astra_early(self):
        self.state.update(phase="opus_final", sol_clean=2)
        self.review_pass("opus_final", implementation_fixes=1, substantial=True)
        self.review_pass("opus_final")
        self.review_pass("opus_final", implementation_fixes=1, substantial=True)
        self.assertEqual(self.state["phase"], "opus_final")
        self.review_pass("opus_final")
        self.assertEqual(self.state["phase"], "opus_final")
        self.review_pass("opus_final")
        self.assertEqual(self.state["phase"], "astra")
        self.finish_loop("astra")
        self.assertEqual(self.state["phase"], "final")
        self.assertEqual(self.state["sol_clean"], 2)

    def test_failed_or_unreported_review_does_not_count(self):
        self.state.update(phase="sol", sol_clean=1)
        self.transport.actions = [("sol", self.edit()), ("sol", report())]
        with self.assertRaisesRegex(Blocked, "reported no changes"):
            self.cycle.review("sol")
        self.assertEqual(self.state["sol_clean"], 1)

    def test_review_evidence_writes_preserve_clean_credit_for_every_reviewer(self):
        from cycle_prompts import REVIEW_TARGETS
        for role, target in REVIEW_TARGETS.items():
            with self.subTest(role=role):
                self.state.update(review_plan=[], review_substantial=False, phase=role, pending=None, sol_passes=2)
                self.state[role + "_clean"] = target - 1
                name = "review-evidence-" + role + ".json"
                self.transport.actions = [(role, self.edit(name=name, content='{"checks": "passed"}\n', minor_edits=1))]
                self.cycle.review(role)
                self.assertEqual(self.state[role + "_clean"], target)
                self.assertNotEqual(self.state["phase"], role)
                self.assertIsNone(self.state["pending"])
                self.assertEqual((self.root / "source.txt").read_text(), "initial\n")
                self.assertIn(name, self.state["last_snapshot"]["files"])
                if self.state["phase"] == "publish":
                    self.assertEqual(self.state["reviewed"], self.repo.snapshot())

    def test_zero_count_evidence_report_and_cached_replay_still_fail_closed(self):
        for role in REVIEW_ROLES:
            with self.subTest(role=role):
                self.state.update(review_plan=[], review_substantial=False, phase=role, pending=None)
                self.state[role + "_clean"] = 0
                name = "review-evidence-" + role + ".json"
                self.transport.actions = [(role, self.edit(name=name, content='{"checks": "passed"}\n')), (role, report())]
                self.transport.calls.clear()
                for _ in range(2):
                    with self.assertRaises(Blocked) as caught:
                        self.cycle.review(role)
                    self.assertEqual(caught.exception.code, "unreported-fix")
                    self.assertIn("minor_edits", str(caught.exception))
                    self.assertEqual(self.state[role + "_clean"], 0)
                    self.assertEqual(self.state["phase"], role)
                    self.assertEqual(len(self.transport.calls), 2)
                result = self.store.directory / "invocations" / self.state["pending"]["id"] / "result.json"
                saved = json.loads(result.read_text())
                self.assertEqual(changed(saved["before"], saved["after"]), [name])
                self.assertEqual(json.loads(saved["raw"])["minor_edits"], 0)
                self.assertEqual((self.root / name).read_text(), '{"checks": "passed"}\n')

    def test_report_only_correction_counts_the_original_review_once(self):
        for role in REVIEW_ROLES:
            with self.subTest(role=role):
                self.state.update(phase=role, pending=None, review_plan=[], review_substantial=False)
                self.state[role + '_clean'] = 1
                self.state['sessions'][role] = 'review-conversation'
                self.transport.calls.clear()
                self.transport.actions = [(role, self.edit(name='journal-' + role, minor_edits=0)),
                                          (role, report(minor_edits=1))]
                self.cycle.review(role)
                self.assertEqual(self.state[role + '_clean'], 2)
                self.assertEqual(self.state['display_reviews'][role]['completed'], 1)
                self.assertEqual([r for r, _ in self.transport.calls], [role, role])
                self.assertEqual(self.state['sessions'][role], 'review-conversation')
                corrected = json.loads(Path(self.state['last']['report']).read_text())
                original = json.loads(Path(corrected['report_repair']['source']).read_text())
                self.assertEqual(json.loads(original['raw'])['minor_edits'], 0)
                self.assertEqual(json.loads(corrected['raw'])['minor_edits'], 1)
                self.assertEqual(original['before'], corrected['before'])
                self.assertEqual(original['after'], corrected['after'])
                self.assertIn('REPORT-ONLY CORRECTION', self.transport.calls[1][1])
                self.assertIn('journal-' + role, self.transport.calls[1][1])

    def test_report_correction_can_discover_a_substantial_fix(self):
        self.state.update(phase='sol', sol_clean=1)
        self.transport.actions = [('sol', self.edit()), ('sol', report(implementation_fixes=1, substantial=True))]
        self.cycle.review('sol')
        self.assertEqual(self.state['phase'], 'sol')
        self.assertEqual(self.state['sol_clean'], 0)
        self.assertTrue(self.state['review_substantial'])
        self.assertEqual(self.state['display_reviews']['sol']['completed'], 1)
        self.finish_loop('sol')
        self.assertEqual(self.state['phase'], 'opus')

    def interrupted_report_correction(self, error=KeyboardInterrupt):
        self.state.update(phase='sol', sol_clean=1)
        def interrupt():
            self.state['pending']['attempts'] = 1
            self.cycle.save()
            raise error()
        self.transport.actions = [('sol', self.edit(name='journal.md')), ('sol', interrupt)]
        with self.assertRaises(error):
            self.cycle.review('sol')
        return json.loads(json.dumps(self.state['pending']))

    def test_report_correction_survives_restart_and_cache_without_extra_credit(self):
        pending = self.interrupted_report_correction()
        self.assertEqual(self.state['sol_clean'], 1)
        self.state = self.store.read()
        self.cycle.state = self.state
        self.transport.actions = [('sol', report(minor_edits=1))]
        self.cycle.invoke('sol')  # Crash after result persistence, before credit.
        self.state = self.store.read()
        self.cycle.state = self.state
        self.assertEqual(self.state['pending']['id'], pending['id'])
        self.cycle.review('sol')
        self.assertEqual(len(self.transport.calls), 3)
        self.assertEqual(self.state['sol_clean'], 2)
        self.assertEqual(self.state['display_reviews']['sol']['completed'], 1)
        self.assertEqual(self.state['phase'], 'astra')

    def test_report_correction_rejects_file_index_or_original_report_drift(self):
        for kind in ('file', 'index', 'report'):
            with self.subTest(kind=kind):
                self.state.update(phase='sol', sol_clean=1, pending=None, review_plan=[])
                self.transport.actions = [('sol', self.edit(name=kind + '.txt')), ('sol', KeyboardInterrupt())]
                with self.assertRaises(KeyboardInterrupt):
                    self.cycle.review('sol')
                if kind == 'file':
                    self.edit(content='external edit')()
                elif kind == 'index':
                    self.repo.git('add', 'source.txt')
                else:
                    Path(self.state['pending']['report_repair']['source']).write_text('{}')
                with self.assertRaisesRegex(Blocked, 'report changed|Working files'):
                    self.cycle.review('sol')
                self.assertEqual(self.state['sol_clean'], 1)
                self.assertFalse(self.transport.actions)

    def test_report_correction_keeps_immutable_handoff_guards(self):
        handoff = self.root / 'transfer.md'
        handoff.write_text('Historical context')
        self.state['handoffs'] = [self.store.handoff(handoff)]
        self.interrupted_report_correction()
        Path(self.state['handoffs'][0]['path']).write_text('Changed archived context')
        self.transport.actions = []
        with self.assertRaisesRegex(Blocked, 'imported handoff snapshot changed'):
            self.cycle.review('sol')
        self.assertEqual(self.state['sol_clean'], 1)

    def test_report_correction_cannot_write_even_minor_evidence(self):
        self.state.update(phase='sol', sol_clean=1)
        self.transport.actions = [('sol', self.edit(name='journal.md')),
                                  ('sol', self.edit(name='new-evidence.json', minor_edits=2))]
        with self.assertRaisesRegex(Blocked, 'report-only correction'):
            self.cycle.review('sol')
        self.assertEqual(self.state['sol_clean'], 1)
        self.assertEqual(self.state['display_reviews']['sol']['completed'], 0)
        self.assertTrue((self.root / 'new-evidence.json').exists())  # Preserve, never discard.
        self.assertIsNone(self.state['reviewed'])

    def test_report_correction_quota_preserves_completed_pass_and_accounting(self):
        pending = self.interrupted_report_correction()
        self.cycle.defer_quota(ProviderQuota(1, no_work=True))
        self.assertTrue(self.state['pending']['quota_wait']['no_work'])
        self.assertEqual(self.state['sol_clean'], 1)
        self.assertFalse(self.state['review_substantial'])
        self.transport.actions = [('sol', report(minor_edits=1))]
        self.cycle.review('sol')
        self.assertEqual(self.state['sol_clean'], 2)
        self.assertEqual(self.state['display_reviews']['sol']['completed'], 1)
        self.assertEqual(json.loads(Path(self.state['last']['report']).read_text())['report_repair'], pending['report_repair'])

    def test_failed_report_correction_uses_existing_healer_route(self):
        self.state.update(phase='sol', sol_clean=1)
        self.transport.actions = [('sol', self.edit()), ('sol', report())]
        with self.assertRaises(Blocked) as caught:
            self.cycle.review('sol')
        self.assertEqual(caught.exception.code, 'unreported-fix')
        self.assertEqual(len(self.transport.calls), 2)
        self.cycle.handle_block(caught.exception)
        self.assertEqual(self.state['status'], 'healing')
        self.assertEqual(self.state['sol_clean'], 0)
        self.assertEqual(self.state['display_reviews']['sol']['completed'], 0)

    def test_report_correction_carries_operator_restart_requirement(self):
        self.state.update(phase='opus_final', pending={'id': 'instructed', 'role': 'opus_final',
                          'before': self.repo.snapshot(), 'restart_reviews': True})
        self.transport.actions = [('opus_final', self.edit()), ('opus_final', report(minor_edits=1))]
        self.cycle.review('opus_final')
        self.assertEqual(self.state['phase'], 'pair_a')
        self.assertEqual([self.state[r + '_clean'] for r in REVIEW_ROLES], [0, 0, 0, 0])

    def test_report_correction_native_prompt_does_not_repeat_the_review(self):
        pending = self.interrupted_report_correction()
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        directory = self.store.directory / 'repair-prompt'
        directory.mkdir(parents=True)
        with patch.object(transport, '_codex', return_value=json.dumps(report(minor_edits=1))) as provider:
            transport.run('sol', self.cycle.report_repair_context(pending), pending, directory)
        prompt = provider.call_args.args[4]
        self.assertIn('REPORT-ONLY CORRECTION', prompt)
        self.assertNotIn('RECOVERY:', prompt)

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
        self.transport.actions = [("sol", report())]
        self.state["phase"] = "sol"
        self.cycle.invoke("sol")
        pending_id = self.state["pending"]["id"]
        self.cycle.review("sol")
        self.assertEqual(len(self.transport.calls), 1)
        self.assertEqual(self.state["sol_clean"], 1)
        self.assertTrue((self.store.directory / "invocations" / pending_id / "result.json").exists())

    def test_pause_stops_before_any_provider(self):
        self.store.directory.mkdir(parents=True)
        (self.root / ".work" / "PAUSE").write_text("operator stop")
        self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(self.state["status"], "paused")
        self.assertFalse(self.transport.calls)

    def test_blocker_heals_once_then_escalates_without_spin(self):
        self.state.update(phase="sol", coordinated="sol")
        problem = Blocked("fixture", "same unavailable dependency")
        self.transport.actions = [("sol", problem), ("heal", report()),
                                  ("coordinate", report()), ("sol", problem)]
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
        self.assertEqual(self.state["phase"], "pair_a")
        self.assertIsNone(self.state["reviewed"])

    def test_changing_error_details_cannot_spin_recovery(self):
        self.state.update(phase="sol", coordinated="sol")
        self.transport.actions = [("sol", Blocked("dependency", "failed request at timestamp one")),
                                  ("heal", report()), ("coordinate", report()),
                                  ("sol", Blocked("dependency", "failed request at timestamp two"))]
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
                          sol_clean=3, claude_clean=2, sessions={"codex": "saved-session"})
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
                self.assertEqual((saved["sol_clean"], saved["claude_clean"]), (3, 2))
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
                          remote="origin", sol_clean=3, claude_clean=2)
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
                          sol_clean=3, claude_clean=2, sessions={"codex": "saved-session"}, recovery_unverified=True)
        self.cycle.handle_block(Blocked("command-unavailable", "git: ls-remote timed out after 60 seconds"))
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.Lease") as lease, \
                patch("cc_focus.Cycle.run", return_value=0):
            lease.return_value.__enter__.return_value.pwsh = "pwsh"
            self.assertEqual(cc_focus.main(["--retry", "--ui", "off"]), 0)
        current = self.store.read()
        self.assertIsNone(current["blocker"])
        self.assertEqual(current["phase"], "publish")
        self.assertEqual(current["reviewed"], reviewed)
        self.assertEqual((current["sol_clean"], current["claude_clean"]), (3, 2))
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
        self.assertEqual(self.state["phase"], "pair_a")

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
        for role in ("code", "sol", "astra", "coordinate", "claude", "publish", "heal"):
            for attempt in range(2):
                invocation = {"id": role + str(attempt)}
                directory = self.store.directory / invocation["id"]
                directory.mkdir()
                raw = transport.run(role, "fixture prompt", invocation, directory)
                self.assertEqual(parse_report(raw, role)["status"], "done")
                prompt = (directory / "prompt.txt").read_text(encoding="utf-8")
                self.assertIn("Use the current project plan as the source of stages.", prompt)
                self.assertIn("Do not require or recreate HANDOFF.md", prompt)
                self.assertIn("Before you select the next unfinished stage, read the current plan.", prompt)
                self.assertIn("Do not invent work.", prompt)
                self.assertIn("If the plan is missing or unreadable, report blocked.", prompt)
                self.assertIn("If unfinished stages remain without a clear next stage, report blocked.", prompt)
        self.assertEqual(len(set(self.state["sessions"].values())), 7)

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
        self.state.update(phase="sol", sol_clean=2, pending={"id": "interrupted", "role": "sol", "before": self.repo.snapshot()})
        self.cycle.handle_block(Blocked("failed-test", "Verification failed"))
        self.assertEqual(self.state["sol_clean"], 0)

    def test_external_edit_invalidates_opus_final_clean_streak(self):
        self.state.update(phase="opus_final", sol_clean=3, opus_final_clean=1)
        self.edit(content="external change")()
        # The blocked reader answers last: it stops its peer, which must not lose its turn first.
        self.transport.actions = [("pair_sol", report(findings=[])), ("pair_opus", report(status="blocked", findings=[])), ("heal", report(status="blocked"))]
        self.assertEqual(self.cycle.run(), 3)
        self.assertEqual(self.state["phase"], "pair_a")
        self.assertEqual((self.state["sol_clean"], self.state["opus_final_clean"]), (0, 0))

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

    def test_legacy_ci_fix_can_restore_baseline_bytes_without_losing_owned_scope(self):
        self.remote()
        self.edit()()
        self.state.update(phase="publish", reviewed=self.repo.snapshot(), remote="origin")
        self.commit_stage()
        self.assertTrue(self.cycle.reconcile_publish())
        self.assertNotIn("publication_paths", self.state)  # old published-state format
        first = self.state["published"]["sha"]
        self.edit(content="initial\n")()
        self.state.update(phase="publish", reviewed=self.repo.snapshot())
        self.transport.actions = [("publish", report(summary="Restore reviewed baseline behavior"))]
        with patch.object(self.cycle, "policy", return_value=subprocess.CompletedProcess([], 0, b"", b"")):
            self.cycle.publish()
        self.assertNotEqual(self.state["published"]["sha"], first)
        self.assertEqual(self.repo.text("diff", "--name-only", self.state["baseline"]["head"], "HEAD"), "")
        self.assertEqual(self.state["publication_paths"], ["source.txt"])
        self.assertEqual(self.state["phase"], "ci")

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

    def test_runtime_publication_uses_literal_files_and_preserves_siblings_and_staging(self):
        self.remote()
        (self.root / "pieces").mkdir()
        (self.root / "pieces/part1.txt").write_text("operator sibling")
        (self.root / "operator.txt").write_text("operator staging")
        self.repo.git("add", "operator.txt")
        self.state = fresh_state(self.repo)
        self.cycle.state = self.state
        protected = dict(self.state["protected_index"])
        self.edit()()
        names = ["pieces/part[1].txt", "-leading.txt"]
        if os.name != "nt":
            names += [":(glob)magic", "line\nbreak.txt"]
        for name in names:
            (self.root / name).write_text("reviewed")
        self.state.update(phase="publish", reviewed=self.repo.snapshot(), remote="origin")
        self.transport.actions = [("publish", report(summary="Update reviewed files"))]
        with patch.object(self.cycle, "policy", return_value=subprocess.CompletedProcess([], 0, b"", b"")):
            self.cycle.publish()
        committed = set(os.fsdecode(n) for n in self.repo.git("diff", "--name-only", "-z", self.state["baseline"]["head"], "HEAD").stdout.split(b"\0") if n)
        self.assertEqual(committed, {"source.txt", *names})
        self.assertEqual(self.repo.index_entries(self.state["protected"]), protected)
        self.assertEqual(self.repo.text("diff", "--cached", "--name-only"), "operator.txt")
        self.assertEqual((self.root / "pieces/part1.txt").read_text(), "operator sibling")
        self.assertEqual(self.state["phase"], "ci")

    @unittest.skipIf(os.name == "nt", "POSIX Git hook fixture")
    def test_commit_hook_cannot_push_an_extra_protected_file(self):
        self.remote()
        (self.root / "operator.txt").write_text("private pre-existing work")
        self.state = fresh_state(self.repo)
        self.cycle.state = self.state
        self.edit()()
        self.state.update(phase="publish", reviewed=self.repo.snapshot(), remote="origin")
        hook = self.root / ".git/hooks/pre-commit"
        hook.write_text("#!/bin/sh\ngit add -- operator.txt\n")
        hook.chmod(0o755)
        self.transport.actions = [("publish", report())]
        with patch.object(self.cycle, "policy", return_value=subprocess.CompletedProcess([], 0, b"", b"")), self.assertRaises(Blocked) as caught:
            self.cycle.publish()
        self.assertIn(caught.exception.code, ("protected-index", "unreviewed-commit"))
        self.assertEqual(self.repo.remote_head("origin"), self.state["baseline"]["head"])
        self.assertNotEqual(self.repo.text("rev-parse", "HEAD"), self.state["baseline"]["head"])
        self.assertEqual((self.root / "operator.txt").read_text(), "private pre-existing work")

    def test_reverted_unreviewed_file_in_history_is_rejected_before_push(self):
        self.remote()
        self.edit()()
        self.state.update(phase="publish", reviewed=self.repo.snapshot(), remote="origin")
        (self.root / "extra.txt").write_text("unreviewed intermediate data")
        self.repo.git("add", "source.txt", "extra.txt")
        self.repo.git("commit", "-m", "Include an extra file")
        self.repo.git("rm", "extra.txt")
        self.repo.git("commit", "-m", "Remove the extra file")
        with self.assertRaises(Blocked) as caught:
            self.cycle.publish()
        self.assertEqual(caught.exception.code, "unreviewed-commit")
        self.assertEqual(self.repo.remote_head("origin"), self.state["baseline"]["head"])
        self.assertEqual(self.transport.calls, [])

    def test_readonly_publisher_cannot_stage_even_owned_paths(self):
        self.remote()
        self.edit()()
        self.state.update(phase="publish", reviewed=self.repo.snapshot(), remote="origin")
        def stage():
            self.repo.git("add", "source.txt")
            return report()
        self.transport.actions = [("publish", stage)]
        with patch.object(self.cycle, "policy", return_value=subprocess.CompletedProcess([], 0, b"", b"")), self.assertRaises(Blocked) as caught:
            self.cycle.publish()
        self.assertEqual(caught.exception.code, "publisher-mutation")
        self.assertEqual(self.repo.remote_head("origin"), self.state["baseline"]["head"])
        self.assertEqual(self.repo.text("rev-parse", "HEAD"), self.state["baseline"]["head"])

    def test_runtime_push_response_loss_does_not_repeat_publication_or_provider(self):
        import focus_commit
        self.remote()
        self.edit()()
        self.state.update(phase="publish", reviewed=self.repo.snapshot(), remote="origin")
        self.transport.actions = [("publish", report())]
        run_git = focus_commit.run_git
        def lost(cycle, *args):
            run_git(cycle, *args)
            if args[0] == "push":
                raise FocusStop("Push receipt lost")
        with patch.object(self.cycle, "policy", return_value=subprocess.CompletedProcess([], 0, b"", b"")):
            with patch.object(focus_commit, "run_git", side_effect=lost), self.assertRaises(FocusStop):
                self.cycle.publish()
            head = self.repo.text("rev-parse", "HEAD")
            self.assertIsNotNone(self.store.read()["publication_prepared"])
            self.cycle.publish()
        self.assertEqual(self.repo.text("rev-parse", "HEAD"), head)
        self.assertEqual(self.state["phase"], "ci")
        self.assertEqual(len(self.transport.calls), 1)

    @unittest.skipIf(os.name == "nt", "POSIX Git hook fixture")
    def test_commit_hook_cannot_redirect_runtime_push(self):
        self.remote()
        self.edit()()
        self.state.update(phase="publish", reviewed=self.repo.snapshot(), remote="origin")
        hook = self.root / ".git/hooks/pre-commit"
        hook.write_text("#!/bin/sh\ngit config remote.origin.pushurl /unapproved-push-destination\n")
        hook.chmod(0o755)
        self.transport.actions = [("publish", report())]
        with patch.object(self.cycle, "policy", return_value=subprocess.CompletedProcess([], 0, b"", b"")), self.assertRaises(Blocked) as caught:
            self.cycle.publish()
        self.assertEqual(caught.exception.code, "remote-changed")
        # Query the original bare repository directly: the hook changed only
        # the fixture's local push URL, never any real account or configuration.
        original = subprocess.check_output(["git", "-C", str(Path(self.temp.name) / "bare.git"), "rev-parse", "main"]).decode().strip()
        self.assertEqual(original, self.state["baseline"]["head"])

    def test_runtime_push_does_not_publish_operator_tags(self):
        self.remote()
        self.repo.git("tag", "-a", "operator-tag", "-m", "Private annotated tag")
        self.repo.git("config", "push.followTags", "true")
        self.edit()()
        self.state.update(phase="publish", reviewed=self.repo.snapshot(), remote="origin")
        self.transport.actions = [("publish", report())]
        with patch.object(self.cycle, "policy", return_value=subprocess.CompletedProcess([], 0, b"", b"")):
            self.cycle.publish()
        self.assertEqual(self.repo.text("ls-remote", "--tags", "origin"), "")
        self.assertEqual(self.state["phase"], "ci")

    @unittest.skipIf(os.name == "nt", "POSIX Git hook fixture")
    def test_emergency_stop_during_git_hook_contains_children_and_prevents_push(self):
        self.remote()
        self.edit()()
        self.state.update(phase="publish", reviewed=self.repo.snapshot(), remote="origin")
        marker = self.root / ".work/hook-running"
        hook = self.root / ".git/hooks/pre-commit"
        hook.write_text("#!/bin/sh\ntouch .work/hook-running\nsleep 600\n")
        hook.chmod(0o755)
        def heartbeat():
            if marker.exists():
                raise FocusStop("Fixture emergency stop during hook")
        self.cycle.heartbeat = heartbeat
        self.transport.actions = [("publish", report())]
        with patch.object(self.cycle, "policy", return_value=subprocess.CompletedProcess([], 0, b"", b"")), self.assertRaises(FocusStop):
            self.cycle.publish()
        self.assertEqual(self.repo.remote_head("origin"), self.state["baseline"]["head"])
        self.assertIsNotNone(self.store.read()["publication_prepared"])
        self.assertEqual((self.root / "source.txt").read_text(), "changed\n")

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
        self.state["sessions"]["sol"] = "known-session"
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["codex"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "codex", "recover"]
        pending = {"id": "recovered", "turn_id": "finished-turn"}
        directory = self.store.directory / "recover"
        directory.mkdir(parents=True)
        self.assertEqual(parse_report(transport.run("sol", "recover same stage", pending, directory))["status"], "done")
        log = (directory / "protocol.jsonl").read_text()
        self.assertNotIn('turn/completed', log)

    def test_stdio_server_exits_gracefully_before_cleanup(self):
        argv = [sys.executable, str(Path(__file__).resolve()), "fixture", "codex",
                "-s", "danger-full-access", "-a", "on-request", "app-server",
                "-c", 'sandbox_mode="danger-full-access"',
                "features.multi_agent=false", "features.memories=false"]
        process = Process(argv, self.root, self.root / "protocol.jsonl", lambda: None)
        Rpc(process).request("initialize", {})
        process.close()
        self.assertEqual(process.proc.returncode, 0)

    def test_all_codex_roles_disable_memory_agents_on_start_and_resume(self):
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["codex"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "codex"]
        for role in ("coordinate", "sol", "astra", "publish", "heal"):
            for attempt in range(2):
                with self.subTest(role=role, resume=bool(attempt)):
                    previous = self.state["sessions"].get(role)
                    directory = self.store.directory / (role + str(attempt))
                    directory.mkdir(parents=True)
                    pending = {"id": directory.name}
                    self.assertEqual(parse_report(transport.run(role, "Same stage", pending, directory))["status"], "done")
                    if attempt:
                        self.assertEqual(self.state["sessions"][role], previous)

    def test_codex_scanner_of_an_existing_review_gets_a_strict_coverage_schema(self):
        # Codex strict mode refused uniqueItems in this coverage schema with HTTP 400.
        files = {"source.txt": digest((self.root / "source.txt").read_bytes())}
        self.state.update(review_scope={"coverage_ids": ["scope"]}, inspection_path=str(self.root / "manifest.json"),
                          inspection={"root": str(self.root), "files": files, "stage_paths": ["source.txt"], "diffs": {}})
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["codex"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "codex"]
        directory = self.store.directory / "scanner"
        directory.mkdir(parents=True)
        sent, original = [], Rpc.request
        def record(rpc, method, params):
            sent.append((method, params))
            return original(rpc, method, params)
        with patch.object(Rpc, "request", record):
            transport.run("pair_sol", "Inspect the scope", {"id": directory.name}, directory)
        schema = next(params["outputSchema"] for method, params in sent if method == "turn/start")
        self.assertIn("coverage", schema["properties"])
        self.assertLessEqual(schema_keywords(schema), STRICT_KEYWORDS)
        self.assertTrue(strict_objects(schema))

    def test_interrupted_review_cannot_reuse_old_clean_streak(self):
        self.state.update(phase="sol", sol_clean=2, pending={
            "id": "interrupted-review", "role": "sol", "before": self.repo.snapshot(), "attempts": 1})
        self.edit(content="fixed before power loss")()
        self.transport.actions = [("sol", report(minor_edits=1))]
        self.cycle.review("sol")
        self.assertEqual(self.state["sol_clean"], 1)
        self.assertEqual(self.state["phase"], "sol")

    def test_uncertain_interrupted_claude_changes_return_to_astra(self):
        self.state.update(phase="opus_final", opus_final_clean=1, sol_clean=3, pending={
            "id": "interrupted-claude", "role": "opus_final", "before": self.repo.snapshot(), "attempts": 1})
        self.edit(content="changed before response was lost")()
        self.transport.actions = [("opus_final", report(minor_edits=1))]
        self.cycle.review("opus_final")
        self.assertEqual(self.state["phase"], "opus_final")
        self.assertTrue(self.state["review_substantial"])
        self.assertEqual(self.state["sol_clean"], 3)

    def test_unmaterialized_codex_session_recovers_same_phase(self):
        self.state["sessions"]["sol"] = "unmaterialized-session"
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["codex"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "codex", "missing-session"]
        pending = {"id": "cold-continuation", "attempts": 1}
        directory = self.store.directory / "cold-continuation"
        directory.mkdir(parents=True)
        self.assertEqual(parse_report(transport.run("sol", "same phase", pending, directory))["status"], "done")
        self.assertNotEqual(self.state["sessions"]["sol"], "unmaterialized-session")
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
        self.assertIn("new conversation for the SAME runtime phase", (directory / "prompt.txt").read_text())

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
                self.state["sessions"]["opus_final"] = "saved-review-session"
                transport = Transport(self.root, self.state, self.store.save, lambda: None)
                transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", variant]
                directory = self.store.directory / variant
                directory.mkdir(parents=True)
                with patch.dict(os.environ, {"CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "0", "BASH_MAX_TIMEOUT_MS": "600000"}):
                    result = parse_report(transport.run("opus_final", "same review", {"id": variant}, directory), "opus_final")
                    self.assertEqual(os.environ["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"], "0")
                self.assertEqual(result["status"], "done")
                self.assertEqual(result["implementation_fixes"], 2 if variant == "native-fixes" else 0)
                self.assertEqual(result["substantial"], variant == "native-fixes")
                deferred = list(directory.glob("deferred-*.txt"))
                self.assertEqual(len(deferred), 0 if variant == "foreground-task" else 2)
                self.assertEqual(self.state["sessions"]["opus_final"], "saved-review-session")
                summary = json.loads((directory / "claude-diagnostics.json").read_text(encoding="utf-8"))
                self.assertFalse(summary["result"]["deferred"])  # Diagnostics agree on the final result.

    def test_claude_native_wait_cannot_earn_a_review_without_final_completion(self):
        for variant, expected in (("native-eof", "provider-eof"), ("native-wrong-session", "provider-profile")):
            with self.subTest(variant=variant):
                transport = Transport(self.root, self.state, self.store.save, lambda: None)
                transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", variant]
                directory = self.store.directory / variant
                directory.mkdir(parents=True)
                with self.assertRaises(Blocked) as caught:
                    transport.run("opus_final", "same review", {"id": variant}, directory)
                self.assertEqual(caught.exception.code, expected)
                self.assertFalse((directory / "result.json").exists())
                if variant == "native-eof":  # Diagnostics do not count the waiting result as completion.
                    summary = json.loads((directory / "claude-diagnostics.json").read_text(encoding="utf-8"))
                    self.assertTrue(summary["result"]["deferred"])

    def test_claude_native_fix_cannot_count_as_a_clean_review(self):
        self.state.update(phase="opus_final", coordinated="opus_final", sol_passes=4, sol_clean=3, opus_final_clean=1)
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", "native-fixes"]
        self.cycle.transport = transport
        self.cycle.review("opus_final")
        self.assertEqual(self.state["phase"], "opus_final")
        self.assertTrue(self.state["review_substantial"])
        self.assertEqual((self.state["sol_clean"], self.state["opus_final_clean"]), (3, 0))
        self.assertEqual(self.state["display_reviews"]["opus_final"]["completed"], 1)
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
            transport.run("opus_final", "same review", {"id": "native-stop"}, directory)
        self.assertFalse((directory / "result.json").exists())

    def test_claude_quota_requires_matching_structured_refusal_and_valid_reset(self):
        for variant, expected in (("quota", "claude-quota"), ("quota-result", "claude-quota"),
                                  ("quota-preinit", "claude-quota"), ("quota-work", "claude-quota"),
                                  ("quota-event-only", None), ("quota-warning", None), ("quota-allowed", None),
                                  ("quota-wrong-session", "provider-profile"),
                                  ("quota-error-wrong-session", "provider-profile"),
                                  ("quota-no-reset", "claude-api-error"), ("quota-no-event", "claude-api-error"),
                                  ("quota-reset-string", "claude-api-error"), ("quota-reset-bool", "claude-api-error"),
                                  ("quota-reset-inf", "claude-api-error"), ("quota-reset-nan", "claude-api-error"),
                                  ("quota-reset-huge", "claude-api-error"), ("quota-reset-negative", "claude-api-error"),
                                  ("quota-allowed-error", "claude-api-error"),
                                  ("quota-access", "claude-access-denied")):
            with self.subTest(variant=variant):
                self.state["sessions"]["opus_final"] = "saved-review-session"
                transport = Transport(self.root, self.state, self.store.save, lambda: None)
                transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", variant]
                directory = self.store.directory / variant
                directory.mkdir(parents=True)
                if expected:
                    with self.assertRaises(Blocked) as caught:
                        transport.run("opus_final", "same review", {"id": variant}, directory)
                    self.assertEqual(caught.exception.code, expected)
                    if expected == "claude-quota":
                        self.assertEqual(caught.exception.resets_at, 1789482000)
                        self.assertEqual(caught.exception.no_work, variant != "quota-work")
                else:
                    self.assertEqual(parse_report(transport.run("opus_final", "same review", {"id": variant}, directory))["status"], "done")
                self.assertEqual(self.state["sessions"]["opus_final"], "saved-review-session")

    def test_quota_cleanup_failure_still_prevents_automatic_retry(self):
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", "quota"]
        directory = self.store.directory / "quota-cleanup"
        directory.mkdir(parents=True)
        close = Process.close
        def unsafe_close(process):
            close(process)
            raise Blocked("cleanup-incomplete", "Fixture containment failure")
        with patch.object(Process, "close", unsafe_close), self.assertRaises(Blocked) as caught:
            transport.run("opus_final", "same review", {"id": "quota-cleanup"}, directory)
        self.assertEqual(caught.exception.code, "cleanup-incomplete")

    def test_quota_wait_retries_same_invocation_without_healing_or_resetting_clean_passes(self):
        self.state.update(phase="opus_final", coordinated="opus_final", sol_clean=3, astra_clean=2, opus_final_clean=1,
                          sessions={"opus_final": "same-native-session"})
        original = self.repo.snapshot()
        clock, waited, ids = [1000.0], [], []
        def reject():
            pending = self.state["pending"]
            pending["attempts"] = 1
            ids.append(pending["id"])
            raise ProviderQuota(1100, no_work=True)
        def retry():
            ids.append(self.state["pending"]["id"])
            self.assertEqual(self.state["opus_final_clean"], 1)
            self.assertEqual(self.state["astra_clean"], 2)
            self.assertGreaterEqual(clock[0], 1105)
            return report()
        def tick(delay):
            self.assertLessEqual(delay, 0.25)
            saved = self.store.read()
            waited.append(saved["pending"]["quota_wait"])
            self.assertEqual((saved["phase"], saved["opus_final_clean"]), ("opus_final", 1))
            self.assertIsNone(saved["blocker"])
            self.assertEqual(saved["display_reviews"]["opus_final"]["completed"], 0)
            clock[0] += 60
        control = type("ControlFixture", (), {"boundary": lambda _, window: self.state["phase"] == "final"})()
        self.cycle.control = control
        self.transport.actions = [("opus_final", reject), ("opus_final", retry)]
        with patch("cycle_workflow.time", wraps=time) as timer:
            timer.time.side_effect = lambda: clock[0]
            timer.sleep.side_effect = tick
            self.assertEqual(self.cycle.run(), 0)
        self.assertTrue(waited)
        self.assertEqual(ids, [ids[0], ids[0]])
        self.assertEqual([role for role, _ in self.transport.calls], ["opus_final", "opus_final"])
        self.assertEqual((self.state["sol_clean"], self.state["astra_clean"], self.state["opus_final_clean"]), (3, 2, 2))
        self.assertEqual(self.state["sessions"], {"opus_final": "same-native-session"})
        self.assertEqual(self.repo.snapshot(), original)
        self.assertIsNone(self.state["pending"])

    def quota_cli_fixture(self, no_work=True):
        self.state.update(phase="opus_final", coordinated="opus_final", sol_clean=3, astra_clean=2, opus_final_clean=0,
                          sessions={"opus_final": "same-review-session"}, pending={
                              "id": "account-change-" + str(time.time_ns()), "role": "opus_final", "attempts": 1,
                              "before": self.repo.snapshot(), "quota_wait": {
                                  "resets_at": time.time() + 7200, "retry_at": time.time() + 7205,
                                  "no_work": no_work}})
        self.store.save(self.state)
        return json.loads(json.dumps(self.state["pending"]))

    def test_explicit_quota_retry_keeps_invocation_and_verifies_review_credit(self):
        import cc_focus
        for no_work, drift in ((True, False), (False, False), (True, True)):
            with self.subTest(no_work=no_work, drift=drift):
                pending = self.quota_cli_fixture(no_work)
                if drift:
                    self.edit(content="changed while waiting\n")()
                before = self.repo.snapshot()
                def run(cycle):
                    quota = cycle.state["pending"]["quota_wait"]
                    self.assertLessEqual(quota["retry_at"], time.time())
                    self.assertEqual(quota["resets_at"], pending["quota_wait"]["resets_at"])
                    self.assertEqual(quota["no_work"], no_work)
                    self.assertEqual(cycle.state["pending"]["id"], pending["id"])
                    self.assertEqual(cycle.state["sessions"], self.state["sessions"])
                    self.assertFalse(cycle.wait_quota())
                    cycle.review("opus_final")
                    return 0
                with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.Lease") as lease, \
                        patch("cc_focus.Cycle.run", autospec=True, side_effect=run), \
                        patch("cycle_transport.Transport.run", return_value=json.dumps(report(other_fixes=int(drift)))) as provider:
                    lease.return_value.__enter__.return_value.pwsh = "pwsh"
                    self.assertEqual(cc_focus.main(["--retry", "--ui", "off"]), 0)
                provider.assert_called_once()
                saved = self.store.read()
                self.assertEqual(saved["sessions"], self.state["sessions"])
                self.assertEqual(saved["opus_final_clean"], 0 if drift else 1)
                self.assertEqual(saved["astra_clean"], 2)
                self.assertEqual(saved["phase"], "opus_final")
                self.assertEqual(self.repo.snapshot(), before)

    def test_plain_restart_keeps_saved_quota_deadline(self):
        import cc_focus
        pending = self.quota_cli_fixture()
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.Lease") as lease, \
                patch("cc_focus.Cycle.run", return_value=0), \
                patch("cycle_transport.Transport.run", side_effect=AssertionError("No provider in admission")):
            lease.return_value.__enter__.return_value.pwsh = "pwsh"
            self.assertEqual(cc_focus.main(["--ui", "off"]), 0)
        self.assertEqual(self.store.read()["pending"], pending)

    def test_explicit_quota_retry_refusal_restores_wait_without_polling(self):
        import cc_focus
        pending = self.quota_cli_fixture()
        reset = time.time() + 3600
        def refuse(*_):
            (self.root / ".work" / "PAUSE").touch()
            raise ProviderQuota(reset, no_work=True)
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.Lease") as lease, \
                patch("cycle_transport.Transport.run", side_effect=refuse) as provider:
            lease.return_value.__enter__.return_value.pwsh = "pwsh"
            self.assertEqual(cc_focus.main(["--retry", "--ui", "off"]), 0)
        provider.assert_called_once()
        saved = self.store.read()
        self.assertEqual(saved["pending"]["id"], pending["id"])
        self.assertEqual(saved["pending"]["quota_wait"]["resets_at"], reset)
        self.assertGreaterEqual(saved["pending"]["quota_wait"]["retry_at"], reset + 5)
        self.assertEqual(saved["claude_clean"], 0)
        self.assertEqual(saved["status"], "paused")
        self.assertIsNone(saved["blocker"])

    def test_explicit_quota_retry_cannot_override_uncertain_messages(self):
        import cc_focus
        pending = self.quota_cli_fixture()
        record = self.cycle.messages.add({"iteration": 1, "invocation": pending["id"], "role": "claude"}, "Check restart")
        self.cycle.messages.update(record, "sending")
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.Lease") as lease, \
                patch("cycle_transport.Transport.run", side_effect=AssertionError("No provider before message resolution")):
            lease.return_value.__enter__.return_value.pwsh = "pwsh"
            self.assertEqual(cc_focus.main(["--retry", "--ui", "off"]), 0)
        saved = self.store.read()
        self.assertEqual(saved["pending"], pending)
        self.assertEqual(saved["status"], "paused")
        self.assertEqual(self.cycle.messages.unresolved(1)[0]["status"], "sending")

    def test_quota_wait_survives_pause_restart_and_a_repeated_stale_reset(self):
        self.state.update(phase="code", coordinated="code")
        def reject():
            self.state["pending"]["attempts"] = self.state["pending"].get("attempts", 0) + 1
            raise ProviderQuota(900, no_work=True)
        self.transport.actions = [("code", reject), ("code", reject), ("code", report(status="complete"))]
        clock = [1000.0]
        def pause(delay):
            (self.root / ".work" / "PAUSE").touch()
        with patch("cycle_workflow.time", wraps=time) as timer:
            timer.time.side_effect = lambda: clock[0]
            timer.sleep.side_effect = pause
            self.assertEqual(self.cycle.run(), 0)
        saved = self.store.read()
        self.assertEqual(saved["status"], "paused")
        self.assertEqual(saved["pending"]["quota_wait"]["retry_at"], 1060)
        invocation = saved["pending"]["id"]
        (self.root / ".work" / "PAUSE").unlink()
        self.state = saved
        self.cycle = Cycle(self.repo, self.store, saved, self.transport, lambda: None, REPO / "tools", "pwsh")
        waits = []
        def tick(delay):
            waits.append(self.state["pending"]["quota_wait"]["retry_at"])
            self.assertEqual(self.state["pending"]["id"], invocation)
            clock[0] += 60
        with patch("cycle_workflow.time", wraps=time) as timer:
            timer.time.side_effect = lambda: clock[0]
            timer.sleep.side_effect = tick
            self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(waits, [1060, 1120])
        self.assertEqual([role for role, _ in self.transport.calls], ["code", "code", "code"])
        self.assertEqual(self.state["status"], "complete")

    def test_quota_retry_after_started_work_or_checkout_drift_cannot_keep_review_credit(self):
        self.state.update(phase="opus_final", coordinated="opus_final", sol_clean=3, opus_final_clean=1)
        for started, drift in ((True, False), (False, True)):
            with self.subTest(started=started, drift=drift):
                before = self.repo.snapshot()
                self.state.update(phase="opus_final", opus_final_clean=1, sol_clean=3,
                                  pending={"id": str(started), "role": "opus_final", "attempts": 1, "before": before})
                self.cycle.defer_quota(ProviderQuota(1, no_work=not started))
                if drift:
                    self.edit()()
                self.transport.actions = [("opus_final", report(other_fixes=int(drift)))]
                self.cycle.review("opus_final")
                self.assertEqual(self.state["opus_final_clean"], 0 if drift else 1)
                self.assertEqual(self.state["phase"], "opus_final")

    def test_final_quota_after_edits_persists_return_to_astra(self):
        self.state.update(phase='opus_final', sol_passes=5, sol_clean=3, astra_clean=2,
                          pending={'id': 'final-quota', 'role': 'opus_final', 'attempts': 1,
                                   'before': self.repo.snapshot()})
        self.edit(content='fix made before quota refusal')()
        self.cycle.defer_quota(ProviderQuota(1, no_work=False))
        self.assertTrue(self.store.read()['review_substantial'])
        self.assertNotIn('return_to_sol', self.state['pending'])
        self.state = self.store.read()
        self.cycle.state = self.state
        self.transport.actions = [('opus_final', report(implementation_fixes=1))]
        self.cycle.review('opus_final')
        self.assertEqual(self.state['phase'], 'opus_final')
        self.assertTrue(self.state['review_substantial'])
        self.assertEqual((self.state['sol_passes'], self.state['sol_clean']), (5, 3))
        self.assertEqual((self.state['astra_clean'], self.state['opus_final_clean']), (2, 0))
        self.assertIsNone(self.state['reviewed'])

    def test_quota_refusal_cannot_hide_protected_file_changes(self):
        self.edit(name="operator.txt", content="owned by operator")()
        self.state = fresh_state(self.repo)
        self.cycle.state = self.state
        self.state.update(coordinated="code")
        def refuse_after_edit():
            self.edit(name="operator.txt", content="unexpected mutation")()
            raise ProviderQuota(time.time() + 3600, no_work=True)
        self.transport.actions = [("code", refuse_after_edit), ("heal", report(status="blocked"))]
        self.assertEqual(self.cycle.run(), 3)
        self.assertEqual(self.state["blocker"]["code"], "protected-work")
        self.assertEqual([role for role, _ in self.transport.calls], ["code", "heal"])

    def test_quota_wait_honors_safe_and_emergency_stops_without_a_provider(self):
        for emergency in (False, True):
            with self.subTest(emergency=emergency):
                control = Control(self.store)
                control.begin()
                self.cycle.control = control
                self.state.update(status="ready", pending={"id": "waiting", "role": "code",
                                  "quota_wait": {"retry_at": time.time() + 3600}})
                with patch("cycle_workflow.time", wraps=time) as timer:
                    timer.sleep.side_effect = lambda _: control.submit_stop(now=emergency)
                    if emergency:
                        with self.assertRaises(FocusStop):
                            self.cycle.run()
                    else:
                        self.assertEqual(self.cycle.run(), 0)
                        self.assertEqual(self.store.read()["status"], "paused")
                self.assertEqual(self.state["pending"]["id"], "waiting")
                self.assertEqual(self.transport.calls, [])
                control.finish(self.state, 0)

    def test_quota_never_resends_uncertain_delivery(self):
        self.state.update(coordinated="code")
        def reject():
            pending = self.state["pending"]
            record = self.cycle.messages.add({"iteration": 1, "invocation": pending["id"], "role": "code"}, "Keep this instruction")
            self.cycle.messages.update(record, "sending")
            raise ProviderQuota(time.time() + 3600, no_work=True)
        self.transport.actions = [("code", reject)]
        with self.assertRaises(MessagePending):
            self.cycle.run()
        saved = self.store.read()
        self.assertIn("quota_wait", saved["pending"])
        self.assertIsNone(saved["blocker"])
        message = self.cycle.messages.unresolved(1)[0]
        self.assertEqual(message["identity"]["invocation"], saved["pending"]["id"])
        self.assertEqual(message["status"], "sending")
        self.assertEqual([role for role, _ in self.transport.calls], ["code"])

    def test_quota_retry_checks_ownership_and_head_before_starting_a_provider(self):
        self.edit(name="operator.txt", content="operator work")()
        self.state = fresh_state(self.repo)
        self.cycle.state = self.state
        self.state.update(phase="opus_final", pending={"id": "quota-guard", "role": "opus_final", "attempts": 1,
                          "before": self.repo.snapshot(), "quota_wait": {"no_work": True}})
        self.edit(name="operator.txt", content="changed during wait")()
        with self.assertRaises(Blocked) as caught:
            self.cycle.invoke("opus_final")
        self.assertEqual(caught.exception.code, "protected-work")
        self.edit(name="operator.txt", content="operator work")()
        self.edit()()
        self.repo.git("add", "source.txt")
        self.repo.git("commit", "-m", "External update during wait")
        with self.assertRaises(Blocked) as caught:
            self.cycle.invoke("opus_final")
        self.assertEqual(caught.exception.code, "unauthorized-commit")
        self.assertEqual(self.transport.calls, [])

    def test_claude_synthetic_api_errors_keep_the_cause_and_session(self):
        for variant, expected in (("synthetic-org", "claude-access-denied"),
                                  ("synthetic-org-preinit", "claude-access-denied"),
                                  ("synthetic-api", "claude-api-error"),
                                  ("synthetic-unmarked", "model-rerouted"),
                                  ("synthetic-wrong-session", "provider-profile"),
                                  ("wrong-model", "model-rerouted")):
            with self.subTest(variant=variant):
                self.state["sessions"]["opus_final"] = "known-review-session"
                transport = Transport(self.root, self.state, self.store.save, lambda: None)
                transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", variant]
                directory = self.store.directory / variant
                directory.mkdir(parents=True)
                before = self.repo.snapshot()
                with self.assertRaises(Blocked) as raised:
                    transport.run("opus_final", "same review", {"id": variant}, directory)
                self.assertEqual(raised.exception.code, expected)
                if expected == "claude-access-denied":
                    self.assertIn("oauth_org_not_allowed", str(raised.exception))
                    self.assertIn("administrator", str(raised.exception))
                    self.assertIn("subscription/payment status", str(raised.exception))
                    self.assertIn("Your organization has disabled Claude subscription access", str(raised.exception))
                if expected == "claude-api-error":
                    self.assertIn("Provider temporarily unavailable", str(raised.exception))
                self.assertEqual(self.repo.snapshot(), before)
                self.assertEqual(self.state["sessions"]["opus_final"], "known-review-session")
                self.assertNotIn("session_recoveries", self.state)
                self.assertTrue((directory / "protocol.jsonl").exists())

    def test_error_code_quoted_in_a_real_claude_answer_is_not_an_api_refusal(self):
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", "quoted-api-error"]
        directory = self.store.directory / "quoted-api-error"
        directory.mkdir(parents=True)
        self.assertEqual(parse_report(transport.run("opus_final", "same review", {"id": "quoted"}, directory))["status"], "done")

    def test_provider_api_refusal_stops_review_without_healing_and_can_resume(self):
        self.state.update(phase="opus_final", coordinated="opus_final", sol_passes=4, sol_clean=3, opus_final_clean=1,
                          sessions={"opus_final": "saved-review-session"})
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
        self.assertEqual(saved["phase"], "opus_final")
        self.assertEqual((saved["sol_clean"], saved["opus_final_clean"]), (3, 0))
        self.assertEqual(saved["healed"], [])
        self.assertEqual(saved["display_reviews"]["opus_final"]["completed"], 0)
        self.assertEqual(self.repo.snapshot(), before)
        self.assertFalse(list(self.store.directory.glob("invocations/*/result.json")))
        # Operator continuation after access is restored uses the saved role
        # conversation and must still complete the required final review pass.
        self.state.update(blocker=None, pending=None, status="ready")
        transport.commands["claude"] = fixture
        self.cycle.review("opus_final")
        self.assertEqual(self.state["phase"], "opus_final")
        self.cycle.review("opus_final")
        self.assertEqual(self.state["phase"], "final")
        self.assertEqual(self.state["sessions"], {"opus_final": "saved-review-session"})

    def test_unknown_structured_api_failure_tries_healing_before_stopping(self):
        self.state.update(phase="code", coordinated="code")
        self.transport.actions = [("code", Blocked("claude-api-error", "Provider temporarily unavailable")),
                                  ("heal", report(status="blocked", summary="Provider outage persists after verification"))]
        self.assertEqual(self.cycle.run(), 3)
        self.assertEqual([role for role, _ in self.transport.calls], ["code", "heal"])
        self.assertEqual(self.state["blocker"]["status"], "blocked")
        self.assertEqual(self.state["blocker"]["escalation_reason"], "healer-failed")

    def test_claude_structured_refusals_preserve_details_and_validate_origin(self):
        cases = [("refusal-synthetic", "claude-refusal"), ("refusal-preinit", "claude-refusal"),
                 ("refusal-native", "claude-refusal"), ("refusal-null", "claude-refusal"),
                 ("refusal-foreign", "provider-profile"), ("refusal-native-foreign", "provider-profile"),
                 ("refusal-unmarked", "model-rerouted"), ("refusal-wrong-model", "model-rerouted"),
                 ("refusal-text-only", "claude-api-error"), ("refusal-quoted", None)]
        for variant, expected in cases:
            with self.subTest(variant=variant):
                self.state["sessions"]["code"] = "saved-coding-session"
                self.state.pop("refused_sessions", None)  # Each case is a separate conversation.
                transport = Transport(self.root, self.state, self.store.save, lambda: None)
                transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", variant]
                directory = self.store.directory / variant
                directory.mkdir(parents=True)
                before = self.repo.snapshot()
                if expected:
                    with self.assertRaises(Blocked) as caught:
                        transport.run("code", "same implementation", {"id": variant, "refusal_restart": {"session": "earlier"}}, directory)
                    self.assertEqual(caught.exception.code, expected)
                    if expected == "claude-refusal":
                        detail = str(caught.exception)
                        self.assertIn("The runtime already continued this invocation one time in a new conversation.", detail)
                        self.assertIn("unspecified" if variant == "refusal-null" else "reasoning_extraction", detail)
                        self.assertIn("Request ID: req_fixture", detail)
                        self.assertIn("Response message ID: msg_fixture", detail)
                        if variant != "refusal-null":
                            self.assertIn("public provider explanation", detail)
                        self.assertNotIn("PRIVATE REFUSAL CONTENT", detail)
                else:
                    self.assertEqual(parse_report(transport.run("code", "same implementation", {"id": variant}, directory))["status"], "done")
                self.assertEqual(self.repo.snapshot(), before)
                self.assertEqual(self.state["sessions"]["code"], "saved-coding-session")
                self.assertNotIn("session_recoveries", self.state)

    def test_claude_streamed_refusal_stops_before_native_continuation(self):
        cases = {"stream-refusal": "claude-refusal", "stream-refusal-null": "claude-refusal",
                 "stream-refusal-foreign": "provider-profile", "stream-refusal-wrong-model": "model-rerouted",
                 "stream-refusal-no-start": "provider-profile", "stream-refusal-child": "provider-profile",
                 "stream-refusal-foreign-start": "provider-profile", "stream-refusal-child-start": "provider-profile"}
        for variant, expected in cases.items():
            with self.subTest(variant=variant):
                self.state["sessions"] = {"code": "saved-coding-session"}
                self.state.pop("refused_sessions", None)  # Each case is a separate conversation.
                transport = Transport(self.root, self.state, self.store.save, lambda: None)
                transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", variant]
                directory = self.store.directory / "invocations" / variant
                directory.mkdir(parents=True)
                with self.assertRaises(Blocked) as caught:
                    transport.run("code", "same implementation", {"id": variant, "refusal_restart": {"session": "earlier"}}, directory)
                self.assertEqual(caught.exception.code, expected)
                summary = json.loads((directory / "claude-diagnostics.json").read_text())
                self.assertEqual(summary["refusals"][0]["source"], "message_delta")
                self.assertFalse(summary["result"])
                self.assertNotIn("PRIVATE", json.dumps(summary))
                self.assertEqual((summary["launch"]["requested_model"], summary["launch"]["effort"]), ("opus", "xhigh"))
                self.assertTrue(summary["launch"]["resumed"])
                self.assertTrue(summary["launch"]["standard_system_prompt"])
                self.assertEqual(summary["launch"]["prompt_sha256"], hashlib.sha256((directory / "prompt.txt").read_bytes()).hexdigest())
                if expected == "claude-refusal":
                    self.assertIn("Response message ID: msg_stream", str(caught.exception))
                    self.assertIn("Request ID: req_stream", str(caught.exception))
                    self.assertEqual(summary["refusals"][0]["last_action"]["tool"], "Write")

    def test_diagnostic_write_failure_cannot_hide_refusal(self):
        self.state["sessions"] = {"code": "saved-coding-session"}
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", "stream-refusal"]
        directory = self.store.directory / "invocations" / ("d" * 32)
        directory.mkdir(parents=True)
        def write(path, data):
            if Path(path).name == "claude-diagnostics.json":
                raise OSError("disk full")
            atomic_write(path, data)
        with patch("cycle_transport.atomic_write", side_effect=write), contextlib.redirect_stderr(io.StringIO()), \
                self.assertRaises(Blocked) as caught:
            transport.run("code", "same implementation", {"id": "d" * 32}, directory)
        self.assertEqual(caught.exception.code, "claude-refusal")
        self.assertIn("cc-focus diagnose --invocation " + "d" * 32, str(caught.exception))

    def test_claude_refusal_preserves_partial_work_without_retry_or_healer(self):
        self.state.update(phase="code", coordinated="code", sessions={"code": "saved-coding-session"})
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", "refusal-work"]
        self.cycle.transport = transport
        before = self.repo.snapshot()
        with patch.object(self.cycle, "heal", side_effect=AssertionError("Refusal must not launch a healer")), \
                patch.object(self.cycle, "defer_transient", side_effect=AssertionError("Refusal is not transient")), \
                patch.object(self.cycle, "defer_quota", side_effect=AssertionError("Refusal is not quota")):
            self.assertEqual(self.cycle.run(), 3)
            self.assertEqual(self.cycle.run(), 3)
        saved = self.store.read()
        self.assertEqual(saved["blocker"]["code"], "claude-refusal")
        self.assertEqual(saved["blocker"]["escalation_reason"], "provider-refusal")
        self.assertIn("The runtime already continued this invocation one time in a new conversation.", saved["blocker"]["message"])
        self.assertEqual(saved["phase"], "code")
        self.assertEqual(saved["status"], "blocked")
        # The resumed conversation was refused. The one new conversation was refused too and stays visible.
        self.assertNotEqual(saved["sessions"]["code"], "saved-coding-session")
        self.assertEqual(saved["refusal_restarts"], [{"role": "code", "session": "saved-coding-session",
                                                       "invocation": saved["blocker"]["interrupted"]["id"]}])
        self.assertEqual(saved["healed"], [])
        self.assertFalse(saved.get("recovery_unverified", False))
        self.assertIsNone(saved["reviewed"])
        self.assertIsNone(saved["published"])
        self.assertEqual(saved["code_report"], "")
        after = self.repo.snapshot()
        self.assertEqual((after["head"], after["index"]), (before["head"], before["index"]))
        self.assertEqual((self.root / "source.txt").read_text(), "partial implementation\n")
        intents = list(self.store.directory.glob("invocations/*/intent.json"))
        self.assertEqual(len(intents), 1)
        self.assertEqual(json.loads(intents[0].read_text())["id"], saved["blocker"]["interrupted"]["id"])
        records = [json.loads(line) for line in (intents[0].parent / "protocol.jsonl").read_text().splitlines()]
        attempts = [json.loads(r["line"]) for r in records if r.get("stream") == "runtime"]
        self.assertEqual([a["resumed"] for a in attempts if a.get("type") == "attempt"], [True, False])

    def test_a_refused_resumed_conversation_continues_once_in_a_new_conversation(self):
        self.state["sessions"] = {"code": "saved-coding-session"}
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", "refusal-resumed"]
        directory = self.store.directory / "invocations" / ("a" * 32)
        directory.mkdir(parents=True)
        pending = {"id": "a" * 32}
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(parse_report(transport.run("code", "same implementation", pending, directory))["status"], "done")
        self.assertIn("The runtime continues the same invocation one time in a new conversation", output.getvalue())
        self.assertNotEqual(self.state["sessions"]["code"], "saved-coding-session")
        self.assertEqual(pending["refusal_restart"]["session"], "saved-coding-session")
        self.assertEqual(self.state["refusal_restarts"], [{"role": "code", "session": "saved-coding-session", "invocation": "a" * 32}])
        self.assertNotIn("session_recoveries", self.state)
        self.assertIn("The prior native conversation is unavailable.", (directory / "prompt.txt").read_text())

    def test_a_late_refusal_of_a_new_conversation_continues_once(self):
        for variant, outcome in (("refusal-late-once", "done"), ("refusal-late", "claude-refusal")):
            with self.subTest(variant=variant):
                marker = self.root / ".work/cycle/refusal-late-once"
                marker.unlink(missing_ok=True)
                self.state["sessions"] = {}
                self.state.pop("refused_sessions", None)
                self.state.pop("refusal_restarts", None)
                transport = Transport(self.root, self.state, self.store.save, lambda: None)
                transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", variant]
                directory = self.store.directory / "invocations" / (("4" if outcome == "done" else "3") * 32)
                directory.mkdir(parents=True)
                pending = {"id": directory.name}
                with contextlib.redirect_stdout(io.StringIO()) as output:
                    if outcome == "done":
                        self.assertEqual(parse_report(transport.run("code", "same implementation", pending, directory))["status"], "done")
                    else:
                        with self.assertRaises(Blocked) as caught:
                            transport.run("code", "same implementation", pending, directory)
                        self.assertIn("The runtime already continued this invocation one time in a new conversation. "
                                      "The provider refused that conversation too.", str(caught.exception))
                # The refused request had an earlier answer, so a new conversation sends a different request.
                self.assertIn("request that had earlier history", output.getvalue())
                self.assertEqual(len(self.state["refusal_restarts"]), 1)
                self.assertTrue(self.state["refusal_restarts"][0]["session"])

    def test_a_retried_first_request_has_no_earlier_history(self):
        self.state["sessions"] = {}
        self.state.pop("refused_sessions", None)
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", "refusal-broken-stream"]
        directory = self.store.directory / "invocations" / ("2" * 32)
        directory.mkdir(parents=True)
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(Blocked) as caught:
            transport.run("code", "same implementation", {"id": "2" * 32}, directory)
        # Two message IDs, but no completed tool exchange: the runtime does not repeat the first request.
        self.assertIn("The provider refused the first request of a new conversation", str(caught.exception))
        self.assertNotIn("refusal_restarts", self.state)

    def test_a_restart_keeps_the_diagnostics_of_the_refused_attempt(self):
        from focus_diagnostics import refusal_history
        self.state["sessions"] = {"code": "saved-coding-session"}
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", "refusal-synthetic"]
        directory = self.store.directory / "invocations" / ("7" * 32)
        directory.mkdir(parents=True)
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(Blocked):
            transport.run("code", "same implementation", {"id": "7" * 32}, directory)
        rows = [r for r in refusal_history(self.store.directory)["refusals"] if r["invocation"] == "7" * 32]
        self.assertEqual([(r["attempt"], r["resumed"]) for r in rows], [(1, True), (2, False)])
        first, second = rows
        # The second attempt replaced the shared files. The refused attempt keeps its own launch record and prompt.
        self.assertTrue(first["role_contract_sha256"])
        self.assertTrue(first["prompt_known"])
        self.assertTrue(first["prompt_file"].startswith("prompt-"))
        self.assertNotIn("The prior native conversation is unavailable.", (directory / first["prompt_file"]).read_text())
        self.assertIn("The prior native conversation is unavailable.", (directory / "prompt.txt").read_text())
        self.assertIn("RECOVERY: the previous attempt of THIS SAME invocation was interrupted.", (directory / "prompt.txt").read_text())
        self.assertEqual((second["prompt_file"], second["prompt_known"]), ("prompt.txt", True))

    def test_a_resume_never_resends_a_refused_conversation(self):
        self.state["sessions"] = {}
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", "refusal-synthetic"]
        directory = self.store.directory / "invocations" / ("6" * 32)
        directory.mkdir(parents=True)
        pending = {"id": "6" * 32}
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(Blocked):
            transport.run("code", "same implementation", pending, directory)
        refused = self.state["sessions"]["code"]
        self.assertEqual(pending["refused_session"], refused)
        # A pause for operator messages keeps the invocation. Its resume starts no provider.
        transport.commands["claude"] = [sys.executable, "-c", "raise SystemExit('provider started')"]
        attempts = pending["attempts"]
        with self.assertRaises(Blocked) as caught:
            transport.run("code", "same implementation", pending, directory)
        self.assertEqual(caught.exception.code, "claude-refusal")
        self.assertIn("starts no provider", str(caught.exception))
        self.assertEqual((pending["attempts"], self.state["sessions"]["code"]), (attempts, refused))
        # A correction or a retry replaces the pending invocation. The state still knows the refused conversation.
        self.assertEqual(self.state["refused_sessions"], [refused])
        with self.assertRaises(Blocked) as caught:
            transport.run("code", "same implementation", {"id": "5" * 32}, directory)
        self.assertIn("starts no provider", str(caught.exception))

    def test_a_refusal_restart_has_limits(self):
        cases = [("new conversation", {}, {"id": "b" * 32}, "code",
                  "The provider refused the first request of a new conversation, so the runtime does not repeat it."),
                 ("report correction", {"code": "saved"}, {"id": "c" * 32, "report_repair": {"source": "x"}}, "code",
                  "A report-only correction keeps its conversation, so the runtime does not start a new one."),
                 ("operator message", {"code": "saved"}, {"id": "d" * 32, "operator_intervened": True}, "code",
                  "Operator messages went to the refused conversation, so the runtime does not start a new one."),
                 ("second refusal", {"code": "saved"}, {"id": "e" * 32}, "code",
                  "The runtime already continued this invocation one time in a new conversation. The provider refused that conversation too.")]
        for name, sessions, pending, role, reason in cases:
            with self.subTest(name):
                self.state["sessions"] = dict(sessions)
                self.state.pop("refusal_restarts", None)
                self.state.pop("refused_sessions", None)  # Each case is a separate conversation.
                transport = Transport(self.root, self.state, self.store.save, lambda: None)
                transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", "refusal-synthetic"]
                directory = self.store.directory / "invocations" / pending["id"]
                directory.mkdir(parents=True)
                with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(Blocked) as caught:
                    transport.run(role, "same work", pending, directory)
                self.assertEqual(caught.exception.code, "claude-refusal")
                self.assertIn(reason, str(caught.exception))
                restarted = name == "second refusal"
                self.assertEqual(bool(self.state.get("refusal_restarts")), restarted)
                if not restarted and sessions:
                    self.assertEqual(self.state["sessions"], sessions)
        # A self review resumes the executor's conversation. A new conversation would replace the executor.
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        self.assertIn("self-review", transport.restart_refused("repair_self", "executor-session", {"id": "9" * 32}))
        self.assertEqual(transport.restart_refused("pair_opus", "reader-session", {"id": "f" * 32}), "")
        self.assertFalse(list(self.store.directory.glob("invocations/*/result.json")))

    def test_claude_diagnostics_keep_instruction_hashes_from_before_the_start(self):
        config = Path(self.temp.name) / "claude-config"
        config.mkdir()
        user_file = config / "CLAUDE.md"
        version_a, version_b = (hashlib.sha256(text).hexdigest() for text in (b"Version A", b"Version B"))
        cases = {(): [version_a], ("instruction-change",): [version_b], ("instruction-delete",): [],
                 ("refusal-work", "instruction-change"): [version_b]}
        for index, (variant, final) in enumerate(cases.items()):
            with self.subTest(variant=variant):
                user_file.write_text("Version A", encoding="utf-8")
                self.state["sessions"] = {"code": "saved-coding-session"}
                transport = Transport(self.root, self.state, self.store.save, lambda: None)
                transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", *variant]
                directory = self.store.directory / "invocations" / format(index, "032x")
                directory.mkdir(parents=True)
                with patch.dict(os.environ, CLAUDE_CONFIG_DIR=str(config)):
                    if "refusal-work" in variant:
                        with self.assertRaises(Blocked) as caught:
                            transport.run("code", "same implementation", {"id": directory.name, "refusal_restart": {"session": "earlier"}}, directory)
                        self.assertEqual(caught.exception.code, "claude-refusal")
                    else:
                        transport.run("code", "same implementation", {"id": directory.name}, directory)
                saved = json.loads((directory / "claude-diagnostics.json").read_text(encoding="utf-8"))
                user = lambda files: [f["sha256"] for f in files if f["scope"] == "user"]
                self.assertEqual(saved["launch"]["instruction_files_captured"], "before-start")
                self.assertEqual(user(saved["launch"]["instruction_files"]), [version_a])
                self.assertEqual(user(saved["completion"]["instruction_files"]), final)
                self.assertNotIn("Version", json.dumps(saved))

    def test_instruction_hashes_are_taken_before_the_process_exists(self):
        config = Path(self.temp.name) / "claude-config"
        config.mkdir()
        user_file = config / "CLAUDE.md"
        user_file.write_text("Version A", encoding="utf-8")
        import cycle_transport
        real = cycle_transport.Process
        def start(*args, **kwargs):
            user_file.write_text("Version B", encoding="utf-8")  # Changed at process creation.
            return real(*args, **kwargs)
        self.state["sessions"] = {"code": "saved-coding-session"}
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude"]
        directory = self.store.directory / "invocations" / ("f" * 32)
        directory.mkdir(parents=True)
        with patch.dict(os.environ, CLAUDE_CONFIG_DIR=str(config)), patch("cycle_transport.Process", side_effect=start):
            transport.run("code", "same implementation", {"id": "f" * 32}, directory)
        saved = json.loads((directory / "claude-diagnostics.json").read_text(encoding="utf-8"))
        user = [f["sha256"] for f in saved["launch"]["instruction_files"] if f["scope"] == "user"]
        self.assertEqual(user, [hashlib.sha256(b"Version A").hexdigest()])

    def test_diagnostic_metadata_errors_cannot_replace_a_claude_outcome(self):
        for variant, expected in (("stream-refusal", "claude-refusal"), ("", None)):
            with self.subTest(variant=variant):
                self.state["sessions"] = {"code": "saved-coding-session"}
                transport = Transport(self.root, self.state, self.store.save, lambda: None)
                transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude",
                                                *([variant] if variant else [])]
                directory = self.store.directory / "invocations" / (("a" if variant else "b") * 32)
                directory.mkdir(parents=True)
                with patch("cycle_transport.ClaudeTrace.report", side_effect=UnicodeEncodeError(
                        "utf-8", "\ud83d", 0, 1, "surrogates not allowed")), contextlib.redirect_stderr(io.StringIO()):
                    if expected:
                        with self.assertRaises(Blocked) as caught:
                            transport.run("code", "same implementation", {"id": directory.name}, directory)
                        self.assertEqual(caught.exception.code, expected)
                    else:
                        self.assertEqual(parse_report(transport.run("code", "same implementation",
                                                                    {"id": directory.name}, directory))["status"], "done")

    def test_a_retry_in_the_same_directory_keeps_each_attempt_separate(self):
        from focus_diagnostics import refusal_history
        directory = self.store.directory / "invocations" / ("c" * 32)
        directory.mkdir(parents=True)
        self.state["sessions"] = {"code": "saved-coding-session"}
        for variant, expected in (("stream-refusal", "claude-refusal"), ("synthetic-org-preinit", "claude-access-denied")):
            transport = Transport(self.root, self.state, self.store.save, lambda: None)
            transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", variant]
            with self.assertRaises(Blocked) as caught:
                transport.run("code", "same implementation", {"id": "c" * 32, "refusal_restart": {"session": "earlier"}}, directory)
            self.assertEqual(caught.exception.code, expected)
            self.state["sessions"] = {}  # The second attempt starts a new conversation.
        rows = refusal_history(self.store.directory)
        first = rows["onset"]["first_refusal"]
        self.assertEqual((first["session_id"], first["attempt"], first["attempts"]), ("saved-coding-session", 1, 2))
        self.assertTrue(first["resumed"])
        self.assertIsNone(first["role_contract_sha256"])  # The saved launch record belongs to attempt 2.
        self.assertFalse(first["prompt_known"])

    def test_a_failed_diagnostic_write_cannot_hide_a_refused_pair_reader(self):
        import cc_focus
        from focus_diagnostics import selected_refusals
        identity = "c" * 32
        directory = self.store.directory / "invocations" / identity
        directory.mkdir(parents=True)
        self.state["sessions"] = {"code": "saved-coding-session"}
        for variant in ((), ("stream-refusal",)):  # The reader completes, then a correction attempt is refused.
            transport = Transport(self.root, self.state, self.store.save, lambda: None)
            transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", *variant]
            def write(path, data, fail=bool(variant)):
                if fail and Path(path).name == "claude-diagnostics.json":
                    raise OSError("disk full")
                atomic_write(path, data)
            with patch("cycle_transport.atomic_write", side_effect=write), contextlib.redirect_stderr(io.StringIO()):
                if variant:
                    with self.assertRaises(Blocked) as caught:
                        transport.run("code", "same review", {"id": identity, "refusal_restart": {"session": "earlier"}}, directory)
                    self.assertEqual(caught.exception.code, "claude-refusal")
                else:
                    transport.run("code", "same review", {"id": identity}, directory)
        self.assertFalse(json.loads((directory / "claude-diagnostics.json").read_text())["refusals"])  # Stale file.
        # A pair blocker names only its group. The unfinished reader still holds the refused session.
        self.state.update(sessions={}, pair_review={"jobs": {"scan/pair_opus": {
            "id": identity, "role": "pair_opus", "sessions": {"pair_opus": "saved-coding-session"}}}},
            blocker={"code": "claude-refusal", "interrupted": {"id": "d" * 32, "role": "pair_group"},
                     "signature": "fixture", "status": "blocked", "message": "Claude refused."})
        self.store.save(self.state)
        self.assertEqual([r["invocation"] for r in selected_refusals(self.store.directory, self.state)], [identity])
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.Lease", side_effect=AssertionError("lease")), \
                patch("cc_focus.Cycle.run", side_effect=AssertionError("provider")), \
                contextlib.redirect_stderr(io.StringIO()) as error:
            self.assertEqual(cc_focus.main(["--retry", "--ui", "off"]), 3)
        self.assertIn("cc-focus --new-sessions --retry", error.getvalue())

    def test_failed_instruction_hashing_cannot_stop_or_hide_a_claude_result(self):
        self.state["sessions"] = {"code": "saved-coding-session"}
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", "stream-refusal"]
        directory = self.store.directory / "invocations" / ("e" * 32)
        directory.mkdir(parents=True)
        with patch("cycle_transport.instruction_files", side_effect=TypeError("diagnostic defect")), \
                self.assertRaises(Blocked) as caught:
            transport.run("code", "same implementation", {"id": "e" * 32}, directory)
        self.assertEqual(caught.exception.code, "claude-refusal")
        saved = json.loads((directory / "claude-diagnostics.json").read_text(encoding="utf-8"))
        self.assertIsNone(saved["launch"]["instruction_files"])
        self.assertIsNone(saved["completion"]["instruction_files"])

    def test_claude_refusal_retry_requires_a_new_conversation(self):
        import cc_focus
        config = Path(self.temp.name) / "claude-config"
        config.mkdir()
        (config / "CLAUDE.md").write_text("User writing policy", encoding="utf-8")
        self.state.update(phase="code", coordinated="code", sessions={"code": "saved-coding-session"})
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", "refusal-work"]
        self.cycle.transport = transport
        with patch.dict(os.environ, CLAUDE_CONFIG_DIR=str(config)):
            self.assertEqual(self.cycle.run(), 3)
        invocation = self.store.directory / "invocations" / self.store.read()["blocker"]["interrupted"]["id"]
        launch = json.loads((invocation / "claude-diagnostics.json").read_text(encoding="utf-8"))["launch"]
        user = [f for f in launch["instruction_files"] if f["scope"] == "user"]
        self.assertEqual([f["path"] for f in user], [str(config / "CLAUDE.md")])
        self.assertTrue(all(set(f) == {"scope", "path", "bytes", "sha256"} for f in launch["instruction_files"]))
        self.assertNotIn("User writing policy", json.dumps(launch))
        saved = (self.store.directory / "state.json").read_bytes()
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.Lease", side_effect=AssertionError("lease")), \
                patch("cc_focus.Cycle.run", side_effect=AssertionError("provider")), \
                contextlib.redirect_stderr(io.StringIO()) as error:
            self.assertEqual(cc_focus.main(["--retry", "--ui", "off"]), 3)
        self.assertIn("cc-focus --new-sessions --retry", error.getvalue())
        self.assertEqual((self.store.directory / "state.json").read_bytes(), saved)
        # A correction keeps the refused conversation too, so it needs new sessions first.
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.Lease", side_effect=AssertionError("lease")), \
                contextlib.redirect_stderr(io.StringIO()) as error:
            self.assertEqual(cc_focus.main(["correct", "--message", "Remove the refused instruction"]), 3)
            self.assertEqual(cc_focus.main(["recover", "--review-from", str(invocation / "result.json")]), 3)
            # An applied reconcile plan records the same correction and keeps role sessions.
            self.assertEqual(cc_focus.main(["reconcile", "--apply-plan", str(self.root / "plan.json")]), 3)
        self.assertEqual(error.getvalue().count("Run cc-focus --new-sessions first"), 3)
        self.assertEqual((self.store.directory / "state.json").read_bytes(), saved)
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.Lease") as lease, \
                patch("cc_focus.Cycle.run", return_value=0):
            lease.return_value.__enter__.return_value.pwsh = "pwsh"
            self.assertEqual(cc_focus.main(["--new-sessions", "--retry", "--ui", "off"]), 0)
        current = self.store.read()
        self.assertIsNone(current["blocker"])
        self.assertEqual((current["sessions"], current["phase"]), ({}, "code"))

    def test_claude_refusal_does_not_credit_an_interrupted_review(self):
        self.state.update(phase="opus_final", coordinated="opus_final", sol_clean=2, opus_final_clean=1)
        self.transport.actions = [("opus_final", Blocked("claude-refusal", "Refused by provider"))]
        self.assertEqual(self.cycle.run(), 3)
        self.assertEqual([role for role, _ in self.transport.calls], ["opus_final"])
        self.assertEqual((self.state["sol_clean"], self.state["opus_final_clean"]), (2, 0))
        self.assertEqual(self.state["display_reviews"]["opus_final"]["completed"], 0)
        self.assertEqual(self.state["healed"], [])

    def test_transient_protocol_only_retries_structured_server_errors(self):
        cases = [("transient-server", "claude-transient"), ("transient-overloaded", "claude-transient"),
                 ("transient-work", "claude-transient"), ("transient-foreign", "provider-profile"),
                 ("transient-unmarked", "model-rerouted"), ("transient-quoted", None),
                 ("transient-http-string", "claude-failed"), ("transient-http-401", "claude-failed"),
                 ("transient-http-429", "claude-failed"), ("transient-http-501", "claude-failed"),
                 ("transient-result-text", "claude-failed")]
        cases += [("transient-http-" + str(code), "claude-transient") for code in (500, 502, 503, 504, 529)]
        for variant, expected in cases:
            with self.subTest(variant=variant):
                transport = Transport(self.root, self.state, self.store.save, lambda: None)
                transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", variant]
                directory = self.store.directory / variant
                directory.mkdir(parents=True)
                if expected:
                    with self.assertRaises(Blocked) as caught:
                        transport.run("code", "same implementation", {"id": variant}, directory)
                    self.assertEqual(caught.exception.code, expected)
                    if expected == "claude-transient":
                        self.assertIsInstance(caught.exception, ProviderTransient)
                        self.assertEqual(caught.exception.no_work, variant != "transient-work")
                else:
                    self.assertEqual(parse_report(transport.run("code", "same implementation", {"id": variant}, directory))["status"], "done")

    def test_codex_server_overload_is_a_transient_error(self):
        cases = {"serverOverloaded": "codex-transient", "internalServerError": "codex-transient",
                 "http503": "codex-transient", "http529": "codex-transient", "http400": "codex-failed",
                 "badRequest": "codex-failed", "usageLimitExceeded": "codex-failed", "contextWindowExceeded": "codex-failed"}
        for kind, expected in cases.items():
            for work in (False, True):
                with self.subTest(kind=kind, work=work):
                    transport = Transport(self.root, self.state, self.store.save, lambda: None)
                    transport.commands["codex"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "codex",
                                                   "codex-error=" + kind, *(["codex-work"] if work else [])]
                    directory = self.store.directory / f"{kind}-{work}"
                    directory.mkdir(parents=True)
                    with self.assertRaises(Blocked) as caught:
                        transport.run("sol", "Same review", {"id": directory.name}, directory)
                    self.assertEqual(caught.exception.code, expected)
                    if expected == "codex-transient":
                        self.assertIsInstance(caught.exception, ProviderTransient)
                        self.assertEqual(caught.exception.no_work, not work)
                        self.assertIn("Codex server error", str(caught.exception))
                        self.assertIn("different model. No review credit earned.", str(caught.exception))
        # A read-only reviewer answers inspection tool calls inside the RPC layer; they are work too.
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["codex"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "codex",
                                       "codex-error=serverOverloaded"]
        directory = self.store.directory / "readonly-overload"
        directory.mkdir(parents=True)
        with self.assertRaises(ProviderTransient) as caught:
            transport.run("final_astra", "Same final review", {"id": directory.name}, directory)
        self.assertFalse(caught.exception.no_work)

    def test_codex_overload_retries_the_same_invocation_without_a_healer(self):
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["codex"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "codex",
                                       "codex-error=serverOverloaded-once"]
        transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude"]
        self.cycle.transport = transport
        self.cycle.control = type("StopAfterCode", (), {"boundary": lambda _, window: self.state["phase"] == "pair_a",
                                                         "request": lambda _: False})()
        with patch("cycle_workflow.PROVIDER_RETRY_DELAYS", (0, 0, 0)), contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(self.cycle.run(), 0)
        self.assertIn("Codex server error; automatic retry 1/3", out.getvalue())
        self.assertEqual(self.state["healed"], [])
        self.assertIsNone(self.state["blocker"])
        self.assertEqual(self.state["phase"], "pair_a")
        coordinate = [d for d in (self.store.directory / "invocations").iterdir()
                      if json.loads((d / "intent.json").read_text())["role"] == "coordinate"]
        self.assertEqual(len(coordinate), 1)  # The same invocation was retried.

    def test_transient_native_retry_resumes_same_opus_session_and_invocation(self):
        self.state.update(coordinated="code")
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", "transient-once"]
        self.cycle.transport = transport
        self.cycle.control = type("StopAfterCode", (), {"boundary": lambda _, window: self.state["phase"] == "pair_a"})()
        original = self.repo.snapshot()
        with patch("cycle_workflow.PROVIDER_RETRY_DELAYS", (0, 0, 0)):
            self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(self.state["healed"], [])
        self.assertEqual(self.state["phase"], "pair_a")
        self.assertEqual(self.repo.snapshot(), original)
        invocations = list((self.store.directory / "invocations").iterdir())
        self.assertEqual(len(invocations), 1)
        prompt = (invocations[0] / "prompt.txt").read_text()
        self.assertIn("THIS SAME invocation was interrupted", prompt)
        events = [json.loads(json.loads(row)["line"]) for row in (invocations[0] / "protocol.jsonl").read_text().splitlines()
                  if json.loads(row).get("stream") == "stdout"]
        inits = [event for event in events if event.get("subtype") == "init"]
        self.assertEqual(len(inits), 2)
        self.assertEqual({event["session_id"] for event in inits}, {self.state["sessions"]["code"]})
        self.assertEqual({event["model"] for event in inits}, {"claude-opus-5-5"})
        self.assertTrue((invocations[0] / "result.json").exists())

    def exhaust_server_retries(self, error, code, retry="cc-focus --retry"):
        self.state.update(coordinated="code")
        clock, deadlines, ids = [1000.0], [], []
        def fail():
            ids.append(self.state["pending"]["id"])
            self.state["pending"]["attempts"] = len(ids)
            raise error()
        # The healer has an action. The run must not use it.
        self.transport.actions = [("code", fail)] * 4 + [("heal", report())]
        def tick(delay):
            self.assertLessEqual(delay, 0.25)
            wait = self.store.read()["pending"]["transient_wait"]
            deadlines.append(wait["retry_at"])
            self.assertEqual(wait["attempt"], len(deadlines))
            clock[0] = wait["retry_at"]
        with patch("cycle_workflow.time", wraps=time) as timer, contextlib.redirect_stdout(io.StringIO()) as out:
            timer.time.side_effect = lambda: clock[0]
            timer.sleep.side_effect = tick
            self.assertEqual(self.cycle.run(), 3)
            self.assertEqual(self.cycle.run(), 3)  # A plain rerun starts no provider.
        self.assertEqual(deadlines, [1015, 1045, 1105])
        self.assertEqual(ids, [ids[0]] * 4)
        self.assertEqual([r for r, _ in self.transport.calls], ["code"] * 4)
        blocker = self.state["blocker"]
        self.assertEqual((blocker["code"], blocker["status"], blocker["escalation_reason"]),
                         (code, "blocked", "provider-unavailable"))
        self.assertEqual(blocker["interrupted"]["id"], ids[0])
        self.assertIn("The retained invocation holds the server failure. "
                      f"Operator: wait until the provider is available. Then run {retry}.", blocker["message"])
        self.assertIn(f"Resolve the problem, then run {retry}.", out.getvalue())
        self.assertEqual(self.state["healed"], [])
        self.assertIn("Recovery cannot retry a provider.", out.getvalue())
        self.assertNotIn("routing blocker to the separate", out.getvalue())

    def test_claude_transient_retries_are_bounded_and_then_stop_for_the_operator(self):
        self.exhaust_server_retries(lambda: ProviderTransient("server_error", "mid-response", no_work=True), "claude-transient")

    def test_codex_transient_retries_are_bounded_and_then_stop_for_the_operator(self):
        self.exhaust_server_retries(lambda: ProviderTransient(
            "serverOverloaded", "Selected model is at capacity.", no_work=True, provider="codex"), "codex-transient")

    def test_a_review_run_names_its_own_retry_command_after_exhausted_server_retries(self):
        self.state["review_run"] = {"id": "abc123"}
        self.exhaust_server_retries(lambda: ProviderTransient("server_error", "mid-response", no_work=True),
                                    "claude-transient", "cc-focus review --resume abc123 --retry")

    def test_an_exhausted_pair_participant_stops_for_the_operator_without_a_healer(self):
        # run_jobs raises a plain blocker with the provider code after the participant retries (see test_focus_pairs).
        self.state.update(phase="pair_a", pending={"id": "group", "role": "pair_group", "before": self.repo.snapshot()})
        self.cycle.handle_block(Blocked("codex-transient", "Codex server error (serverOverloaded): at capacity."))
        blocker = self.state["blocker"]
        self.assertEqual((blocker["status"], blocker["escalation_reason"]), ("blocked", "provider-unavailable"))
        self.assertEqual(blocker["interrupted"]["role"], "pair_group")
        self.assertEqual(self.cycle.run(), 3)
        self.assertEqual(self.transport.calls, [])

    def test_an_unavailable_provider_outranks_unverified_recovery_and_a_repeated_blocker(self):
        error = Blocked("claude-transient", "Claude server error (server_error): mid-response. No review credit earned.")
        signature = digest(encode({"code": error.code, "message": str(error)}))
        for setup in ({"recovery_unverified": True}, {"healed": [signature]}):
            with self.subTest(setup=setup):
                self.state.update({"blocker": None, "pending": None, "recovery_unverified": False, "healed": [], **setup})
                self.cycle.handle_block(error)
                self.assertEqual((self.state["blocker"]["status"], self.state["blocker"]["escalation_reason"]),
                                 ("blocked", "provider-unavailable"))

    def stop_during_the_last_failure(self, error, failures):
        control = Control(self.store)
        control.begin()
        self.cycle.control = control
        self.state.update(coordinated="code")
        calls = []
        def fail():
            calls.append(1)
            if len(calls) == failures:
                control.submit_stop(now=False)  # The operator stops the run during the last attempt.
            raise error()
        self.transport.actions = [("code", fail)] * failures
        clock = [1000.0]
        def tick(delay):
            clock[0] = self.store.read()["pending"]["transient_wait"]["retry_at"]
        with patch("cycle_workflow.time", wraps=time) as timer, contextlib.redirect_stdout(io.StringIO()) as out:
            timer.time.side_effect = lambda: clock[0]
            timer.sleep.side_effect = tick
            code = self.cycle.run()
        control.finish(self.state, code)
        self.assertEqual(len(calls), failures)
        self.assertNotIn("heal", [role for role, _ in self.transport.calls])
        return code, out.getvalue()

    def test_a_stop_after_exhausted_server_retries_ends_like_a_blocked_run(self):
        code, out = self.stop_during_the_last_failure(lambda: ProviderTransient("server_error", "mid-response", no_work=True), 4)
        self.assertEqual((code, self.state["status"], self.state["blocker"]["escalation_reason"]),
                         (3, "blocked", "provider-unavailable"))
        self.assertIn("cc-focus: The provider still has a server failure", out)
        self.assertIn("Operator: wait until the provider is available. Then run cc-focus --retry.", out)
        self.assertIn("Resolve the problem, then run cc-focus --retry.", out)
        self.assertIn("cc-focus recover --review-from", out)
        self.assertNotIn("recovery will run", out)

    def test_a_stop_at_a_blocker_for_recovery_pauses_before_the_healer(self):
        code, out = self.stop_during_the_last_failure(lambda: Blocked("claude-failed", "Unexpected provider result."), 1)
        self.assertEqual((code, self.state["status"], self.state["blocker"]["status"]), (0, "paused", "healing"))
        self.assertIn("cc-focus: stopped at a preserved blocker; recovery will run only after continuation.", out)

    def test_a_codex_healer_server_error_waits_before_each_retry(self):
        self.state.update(coordinated="code")
        clock, deadlines, starts = [1000.0], [], []
        def overloaded():
            starts.append(clock[0])
            raise ProviderTransient("serverOverloaded", "Selected model is at capacity.", no_work=True, provider="codex")
        self.transport.actions = [("code", Blocked("codex-failed", "Turn failed"))] + [("heal", overloaded)] * 4
        def tick(delay):
            wait = self.store.read()["pending"]["transient_wait"]
            deadlines.append(wait["retry_at"])
            self.assertEqual((wait["attempt"], wait["provider"]), (len(deadlines), "Codex"))
            clock[0] = wait["retry_at"]
        with patch("cycle_workflow.time", wraps=time) as timer:
            timer.time.side_effect = lambda: clock[0]
            timer.sleep.side_effect = tick
            self.assertEqual(self.cycle.run(), 3)
        self.assertEqual(deadlines, [1015, 1045, 1105])
        self.assertEqual(starts, [1000, 1015, 1045, 1105])
        self.assertEqual([r for r, _ in self.transport.calls], ["code"] + ["heal"] * 4)
        self.assertEqual(self.state["blocker"]["escalation_reason"], "healer-failed")
        self.assertIn("Operator: wait until the provider is available. Then run cc-focus --retry.", self.state["blocker"]["resolution"])

    def test_transient_retry_budget_and_deadline_survive_restart(self):
        self.state.update(coordinated="code")
        def fail():
            self.state["pending"]["attempts"] = 1
            raise ProviderTransient("server_error", "mid-response")
        self.transport.actions = [("code", fail)]
        with patch("cycle_workflow.time", wraps=time) as timer:
            timer.time.return_value = 1000
            timer.sleep.side_effect = lambda _: (self.root / ".work/PAUSE").touch()
            self.assertEqual(self.cycle.run(), 0)
        saved = self.store.read()
        self.assertEqual(saved["pending"]["transient_wait"]["retry_at"], 1015)
        self.assertEqual(saved["pending"]["transient_retries"], 1)
        self.assertEqual(saved["status"], "paused")
        original_id = saved["pending"]["id"]
        (self.root / ".work/PAUSE").unlink()
        self.state = saved
        self.cycle = Cycle(self.repo, self.store, saved, self.transport, lambda: None, REPO / "tools", "pwsh")
        self.transport.actions = [("code", fail), ("code", report(status="complete"))]
        clock, deadlines = [1010.0], []
        def tick(delay):
            pending = self.store.read()["pending"]
            self.assertEqual(pending["id"], original_id)
            deadlines.append(pending["transient_wait"]["retry_at"])
            clock[0] = deadlines[-1]
        with patch("cycle_workflow.time", wraps=time) as timer:
            timer.time.side_effect = lambda: clock[0]
            timer.sleep.side_effect = tick
            self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(deadlines, [1015, 1045])
        self.assertIsNone(self.state["pending"])

    def test_transient_retry_retains_wip_but_invalidates_interrupted_review_credit(self):
        for started, mutated in ((False, False), (True, False), (True, True)):
            with self.subTest(started=started, mutated=mutated):
                self.state.update(phase="opus_final", coordinated="opus_final", opus_final_clean=1, astra_clean=2,
                                  pending={"id": f"transient-review-{started}-{mutated}", "role": "opus_final", "attempts": 1,
                                           "before": self.repo.snapshot()})
                if mutated:
                    self.edit(content="partial implementation")()
                current = self.repo.snapshot()
                self.assertTrue(self.cycle.defer_transient(ProviderTransient("server_error", "failure", no_work=not started)))
                self.assertEqual(self.state["opus_final_clean"], 0 if started else 1)
                self.transport.actions = [("opus_final", report(implementation_fixes=int(mutated)))]
                self.cycle.review("opus_final")
                self.assertEqual(self.repo.snapshot(), current)
                self.assertEqual(self.state["opus_final_clean"], 0 if mutated else 1 if started else 2)
                self.assertEqual(self.state["astra_clean"], 2)
                if mutated:
                    self.assertTrue(self.state["review_substantial"])

    def test_transient_retry_rechecks_head_index_and_protected_files(self):
        self.edit(name="operator.txt", content="operator work")()
        self.state = fresh_state(self.repo)
        self.cycle.state = self.state
        self.state.update(phase="code", pending={"id": "transient-guard", "role": "code", "attempts": 1,
                          "before": self.repo.snapshot()})
        self.cycle.defer_transient(ProviderTransient("server_error", "failure", no_work=True))
        self.edit(name="operator.txt", content="operator changed while waiting")()
        with self.assertRaises(Blocked) as caught:
            self.cycle.invoke("code")
        self.assertEqual(caught.exception.code, "protected-work")
        self.edit(name="operator.txt", content="operator work")()
        self.edit()()
        self.repo.git("add", "source.txt")
        with self.assertRaises(Blocked) as caught:
            self.cycle.invoke("code")
        self.assertEqual(caught.exception.code, "unauthorized-staging")
        self.repo.git("commit", "-m", "External commit")
        with self.assertRaises(Blocked) as caught:
            self.cycle.invoke("code")
        self.assertEqual(caught.exception.code, "unauthorized-commit")
        self.assertEqual(self.transport.calls, [])

    def test_transient_wait_never_resends_unresolved_messages(self):
        self.state.update(coordinated="code")
        for delivery in ("queued", "sending"):
            with self.subTest(delivery=delivery):
                def fail():
                    pending = self.state["pending"]
                    record = self.cycle.messages.add({"iteration": 1, "invocation": pending["id"], "role": "code"}, "Operator instruction")
                    if delivery == "sending":
                        self.cycle.messages.update(record, "sending")
                    raise ProviderTransient("server_error", "failure")
                self.transport.actions = [("code", fail)]
                with self.assertRaises(MessagePending):
                    self.cycle.run()
                self.assertNotIn("transient_wait", self.state["pending"])
                self.assertIsNone(self.state["blocker"])
                record = self.cycle.messages.unresolved(1)[0]
                self.assertEqual(record["status"], delivery)
                self.cycle.messages.resolve(1, record["identity"]["id"], False, self.state["pending"]["id"])

    def test_transient_explicit_retry_keeps_budget_and_wait_deadline(self):
        import cc_focus
        self.state.update(coordinated="code", sessions={"code": "same-session"}, pending={
            "id": "saved-server-retry", "role": "code", "attempts": 2, "before": self.repo.snapshot(),
            "transient_retries": 2, "transient_wait": {"retry_at": time.time() + 60, "no_work": False, "attempt": 2, "limit": 3}})
        self.store.save(self.state)
        pending = json.loads(json.dumps(self.state["pending"]))
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.Lease") as lease, \
                patch("cc_focus.Cycle.run", return_value=0), \
                patch("cycle_transport.Transport.run", side_effect=AssertionError("No provider during admission")):
            lease.return_value.__enter__.return_value.pwsh = "pwsh"
            self.assertEqual(cc_focus.main(["--retry", "--ui", "off"]), 0)
        saved = self.store.read()
        self.assertEqual(saved["pending"], pending)
        self.assertEqual(saved["sessions"], {"code": "same-session"})

    def test_transient_wait_detects_source_drift_after_a_no_work_failure(self):
        self.state.update(phase="opus", opus_clean=1, pending={"id": "wait-drift", "role": "opus", "attempts": 1,
                          "before": self.repo.snapshot()})
        self.cycle.defer_transient(ProviderTransient("server_error", "failure", no_work=True))
        self.edit()()
        self.transport.actions = [("opus", report(implementation_fixes=1))]
        self.cycle.review("opus")
        self.assertEqual(self.state["opus_clean"], 0)
        self.assertTrue(self.state["review_substantial"])
        self.assertEqual(self.state["phase"], "opus")

    def test_transient_report_correction_preserves_one_pass_and_freezes_files(self):
        self.state.update(phase="opus_final", opus_final_clean=1)
        self.transport.actions = [("opus_final", self.edit(name="journal.md")),
                                  ("opus_final", ProviderTransient("server_error", "failure"))]
        with self.assertRaises(ProviderTransient) as caught:
            self.cycle.review("opus_final")
        pending = self.state["pending"]
        original = Path(pending["report_repair"]["source"]).read_bytes()
        self.cycle.defer_transient(caught.exception)
        self.assertEqual(self.state["opus_final_clean"], 1)
        self.edit(name="unwanted-evidence.md")()
        with self.assertRaises(Blocked) as guard:
            self.cycle.defer_transient(caught.exception)
        self.assertEqual(guard.exception.code, "report-repair-drift")
        (self.root / "unwanted-evidence.md").unlink()  # Fixture-owned scratch file.
        self.transport.actions = [("opus_final", report(minor_edits=1))]
        self.cycle.review("opus_final")
        self.assertEqual(self.state["opus_final_clean"], 2)
        self.assertEqual(self.state["display_reviews"]["opus_final"]["completed"], 1)
        self.assertEqual(Path(pending["report_repair"]["source"]).read_bytes(), original)

    def test_transient_wait_honors_safe_and_emergency_stop(self):
        for emergency in (False, True):
            control = Control(self.store)
            control.begin()
            self.cycle.control = control
            self.state.update(status="ready", pending={"id": "transient-stopped", "role": "code", "transient_wait": {
                "retry_at": time.time() + 60, "attempt": 1, "limit": 3}})
            with patch("cycle_workflow.time.sleep", side_effect=lambda _: control.submit_stop(now=emergency)):
                if emergency:
                    with self.assertRaises(FocusStop):
                        self.cycle.run()
                else:
                    self.assertEqual(self.cycle.run(), 0)
                    self.assertEqual(self.store.read()["status"], "paused")
            self.assertEqual(self.transport.calls, [])
            control.finish(self.state, 0)

    def test_transient_cleanup_failure_prevents_retry_and_healing(self):
        self.state.update(coordinated="code")
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["claude"] = [sys.executable, str(Path(__file__).resolve()), "fixture", "claude", "transient-server"]
        self.cycle.transport = transport
        close = Process.close
        def unsafe_close(process):
            close(process)
            raise Blocked("cleanup-incomplete", "Containment failure")
        with patch.object(Process, "close", unsafe_close):
            self.assertEqual(self.cycle.run(), 3)
        self.assertEqual(self.state["blocker"]["code"], "cleanup-incomplete")
        self.assertEqual(self.state["healed"], [])

    def test_reported_human_request_is_checked_by_the_recovery_agent(self):
        self.state.update(phase="code", coordinated="code")
        self.transport.actions = [("code", report(status="blocked", summary="Ask the operator to authorize a necessary dependency")),
                                  ("heal", report()), ("coordinate", report()),
                                  ("code", report(status="complete"))]
        self.assertEqual(self.cycle.run(), 0)
        self.assertEqual([role for role, _ in self.transport.calls], ["code", "heal", "coordinate", "code"])
        healing_prompt = self.transport.calls[1][1]
        self.assertIn("a claim to check", healing_prompt)
        self.assertIn("Use existing operator authorization", healing_prompt)
        self.assertEqual(PROFILES["heal"], ("codex", "gpt-6-astra", "xhigh"))
        self.assertEqual(self.state["status"], "complete")

    def test_blocker_routing_only_skips_recovery_for_manual_or_unsafe_actions(self):
        for code, reason in (("claude-access-denied", "manual-action"), ("approval-required", "manual-action"),
                             ("approval-denied", "manual-action"), ("instruction-version", "runtime-version"),
                             ("parallel-merge-conflict", "operator-context"), ("parallel-sync-git", None),
                             ("cleanup-incomplete", "unsafe-provider"),
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
        self.state.update(phase="sol", coordinated="sol")
        def finish_pass():
            self.stop_request(control)
            return report()
        self.transport.actions = [("sol", finish_pass)]
        self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(self.state["sol_clean"], 1)
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
        self.state.update(phase="sol", coordinated="sol")
        def fail_after_stop():
            self.stop_request(control)
            raise Blocked("fixture", "failed check")
        self.transport.actions = [("sol", fail_after_stop)]
        self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(self.state["blocker"]["status"], "healing")
        self.assertEqual([role for role, _ in self.transport.calls], ["sol"])

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
        self.store.directory.mkdir(parents=True, exist_ok=True)
        path = self.store.directory / "runtime.lock"
        path.write_bytes(b"\0")
        before = path.read_bytes(), path.stat().st_mtime_ns
        with LocalLock(self.store.directory):
            self.assertTrue(runtime_active(self.store))
            # Windows byte-range locks forbid a second handle from reading the
            # locked byte. Check metadata while held and content after release.
            self.assertEqual(path.stat().st_mtime_ns, before[1])
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
            self.assertIn("claude/opus effort=xhigh", output.getvalue())
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

    def test_interactive_progress_updates_timers_without_flooding_the_log(self):
        progress = Progress(self.store, self.state, "run")
        progress.heartbeat_log = False
        updates = []
        progress.on_update = lambda: updates.append(progress.view())
        with contextlib.redirect_stdout(io.StringIO()) as output:
            progress.start("publish", self.store.directory)
            progress.event({"method": "item/commandExecution/requestApproval", "params": {}})
            before = output.getvalue()
            # A half second keeps the whole seconds exact: a large monotonic value loses float precision.
            with patch("focus_progress.time.monotonic", return_value=progress.started + 3600.5):
                progress.pulse()
            self.assertEqual(output.getvalue(), before)
            self.assertEqual(updates[-1]["elapsed_seconds"], 3600)
            saved = json.loads((self.store.directory / "progress.json").read_text())
            self.assertEqual(saved["elapsed_seconds"], 3600)
            self.assertIn("waiting for operator", saved["activity"])
            progress.note("operation answered")
            self.assertIn("operation answered", output.getvalue())

    def test_live_codex_output_streams_messages_commands_and_errors_without_duplicates(self):
        renderer = LiveOutput("sol")
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
        renderer = LiveOutput("sol")
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
        renderer = LiveOutput("sol")
        with contextlib.redirect_stdout(io.StringIO()) as output:
            for value in ('{"example": 1}', '{"example": 1}'):
                renderer.feed("message", "message", value, final=True, message=True)
            for value in ("pending: inspect", "inProgress: inspect", "inProgress: inspect"):
                renderer.feed("plan", "plan", value, final=True)
        self.assertEqual(output.getvalue().count('"example"'), 1)
        self.assertEqual(output.getvalue().count("inProgress: inspect"), 1)

    def test_live_changed_json_snapshots_share_one_display_budget(self):
        renderer = LiveOutput("sol")
        with contextlib.redirect_stdout(io.StringIO()) as output:
            renderer.feed("message", "message", json.dumps({"text": "a" * 32000}), final=True, message=True)
            renderer.feed("message", "message", json.dumps({"text": "b" * 64000}), final=True, message=True)
        self.assertLess(len(output.getvalue()), renderer.LIMIT + 200)
        self.assertIn("display truncated", output.getvalue())

    def test_live_tools_include_structured_results_and_changed_file_diffs(self):
        renderer = LiveOutput("sol")
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
        for role, provider in (("code", "claude"), ("sol", "codex")):
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
        self.assertEqual(self.state["phase"], "pair_a")
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


class ProtocolRecordTests(unittest.TestCase):
    """An Edit of a large file makes Claude repeat the whole file in one tool record."""

    def process(self, *lines):
        import queue
        process = Process.__new__(Process)
        process.heartbeat, process.on_poll, process.progress = (lambda: None), None, None
        process.deadline, process.stderr_tail = time.monotonic() + 60, ""
        process.events = queue.Queue()
        for label, line in lines:
            process.events.put((label, line))
        self.log = io.BytesIO()
        process.log = self.log
        return process

    def tool_record(self, echo_bytes, content="Edited the file."):
        return json.dumps({"type": "user", "session_id": "s", "parent_tool_use_id": None, "uuid": "u",
                           "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t", "content": content}]},
                           "tool_use_result": {"filePath": "plan.md", "originalFile": "x" * echo_bytes}}).encode() + b"\n"

    def test_an_oversized_tool_echo_is_removed_and_the_record_is_kept(self):
        line = self.tool_record(9 * 1024 * 1024)
        event = self.process(("stdout", line)).receive()
        self.assertNotIn("tool_use_result", event)
        self.assertEqual(event["message"]["content"][0]["type"], "tool_result")
        logged = json.loads(self.log.getvalue())
        self.assertGreater(logged["tool_echo_removed_bytes"], 9 * 1024 * 1024)
        self.assertEqual(json.loads(logged["line"]), event)
        self.assertLess(len(self.log.getvalue()), 1024 * 1024)

    def test_a_small_tool_echo_stays_unchanged(self):
        event = self.process(("stdout", self.tool_record(1000))).receive()
        self.assertEqual(len(event["tool_use_result"]["originalFile"]), 1000)
        self.assertNotIn("tool_echo_removed_bytes", json.loads(self.log.getvalue()))

    def test_a_lone_surrogate_survives_the_reduction(self):
        event = self.process(("stdout", self.tool_record(9 * 1024 * 1024, content="cut \ud83d text"))).receive()
        self.assertEqual(event["message"]["content"][0]["content"], "cut \ud83d text")

    def test_a_rejected_line_logs_only_its_size(self):
        line = json.dumps({"type": "assistant", "message": {"content": "q" * (20 * 1024 * 1024)}}).encode() + b"\n"
        with self.assertRaises(Blocked):
            self.process(("stdout", line)).receive()
        frame = json.loads(self.log.getvalue())
        self.assertEqual((frame["rejected_bytes"], "line" in frame), (len(line), False))
        from cycle_transport import protocol_frame
        self.assertIsInstance(protocol_frame("stdout", line)[1], Blocked)

    def test_a_real_pipe_delivers_a_large_tool_record_and_the_next_record(self):
        script = (
            "import json, sys\n"
            "record = {'type': 'user', 'session_id': 's', 'parent_tool_use_id': None, 'uuid': 'u',\n"
            "          'message': {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': 't', 'content': 'ok'}]},\n"
            "          'tool_use_result': {'originalFile': 'x' * (9 * 1024 * 1024)}}\n"
            "sys.stdout.write(json.dumps(record) + '\\n')\n"
            "sys.stdout.write(json.dumps({'type': 'result', 'subtype': 'success'}) + '\\n')\n"
            "sys.stdout.flush()\n"
            "sys.stdin.read()\n")
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / "protocol.jsonl"
            process = Process([sys.executable, "-c", script], Path(temp), log, lambda: None)
            try:
                started = time.monotonic()
                first, second = process.receive(), process.receive()
                self.assertLess(time.monotonic() - started, 20)
            finally:
                process.close()
            self.assertNotIn("tool_use_result", first)
            self.assertEqual(first["message"]["content"][0]["content"], "ok")
            self.assertEqual(second["type"], "result")
            self.assertLess(log.stat().st_size, 1024 * 1024)

    def test_the_close_drain_logs_queued_large_lines_by_size_or_reduced(self):
        script = (
            "import json, sys\n"
            "sys.stdout.write(json.dumps({'type': 'assistant', 'message': {'content': 'q' * (20 * 1024 * 1024)}}) + '\\n')\n"
            "sys.stdout.write(json.dumps({'type': 'user', 'message': {'content': 'ok'},\n"
            "                             'tool_use_result': {'originalFile': 'x' * (9 * 1024 * 1024)}}) + '\\n')\n"
            "sys.stdout.flush()\n")
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / "protocol.jsonl"
            process = Process([sys.executable, "-c", script], Path(temp), log, lambda: None)
            for reader in process.readers:
                reader.join(timeout=20)  # Both records are queued. receive() never runs.
            process.close()
            frames = [json.loads(line) for line in log.read_bytes().splitlines()]
            self.assertTrue(all(len(json.dumps(frame)) < 4096 for frame in frames))
            self.assertTrue(any((frame.get("rejected_bytes") or 0) > 20 * 1024 * 1024 for frame in frames))
            reduced = [frame for frame in frames if "tool_echo_removed_bytes" in frame]
            self.assertEqual(json.loads(reduced[0]["line"])["message"], {"content": "ok"})

    def test_cjk_text_is_reduced_without_ascii_growth(self):
        # About 6 MiB in UTF-8. ASCII escapes would need about 12 MiB and reject the record.
        event = self.process(("stdout", self.tool_record(9 * 1024 * 1024, content="界" * (2 * 1024 * 1024)))).receive()
        self.assertEqual(len(event["message"]["content"][0]["content"]), 2 * 1024 * 1024)

    def test_other_oversized_records_still_stop_the_invocation(self):
        big = b"y" * (9 * 1024 * 1024)
        cases = {"assistant": json.dumps({"type": "assistant", "message": {"content": big.decode()}}).encode() + b"\n",
                 "large message": self.tool_record(10, content="z" * (9 * 1024 * 1024)),
                 "not json": big + b"\n",
                 "stderr": None,
                 "over the echo limit": b"z" * (128 * 1024 * 1024 + 1)}
        for name, line in cases.items():
            with self.subTest(name=name):
                label = "stderr" if name == "stderr" else "stdout"
                record = self.tool_record(9 * 1024 * 1024) if name == "stderr" else line
                with self.assertRaisesRegex(Blocked, "oversized protocol record") as raised:
                    self.process((label, record)).receive()
                self.assertEqual(raised.exception.code, "provider-output")


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
                    state.update(pending=None, status="paused", phase="sol")
                finally:
                    process.close()
            except FocusStop:
                state["status"] = "interrupted"
            finally:
                store.save(state)
                control.finish(state, 0)
        return
    recovery = "recover" in args
    old_sol_only = "old-sol-only" in args
    paired_report_once = "paired-report-once" in args
    paired_blocked_once = "paired-blocked-once" in args
    paired_active = "paired-active" in args
    missing_session = "missing-session" in args
    live = "live" in args
    steer = "steer" in args
    late_ack, error_ack = "late-ack" in args, "error-ack" in args
    # A Codex turn fails with this codexErrorInfo; a "-once" suffix fails only the first turn.
    codex_error = next((arg.split("=", 1)[1] for arg in args if arg.startswith("codex-error=")), None)
    codex_work = "codex-work" in args
    args = [arg for arg in args if arg not in ("recover", "missing-session", "live", "steer", "late-ack", "error-ack", "old-sol-only", "paired-report-once", "paired-blocked-once", "paired-active", "codex-work")
            and not arg.startswith("codex-error=")]
    def emit(value):
        print(json.dumps(value), flush=True)
    if provider == "claude":
        assert args[args.index("--permission-mode") + 1] == "bypassPermissions"
        requested_model = args[args.index("--model") + 1]
        assert requested_model in ("claude-fable-5-1", "opus")
        effective_model = "claude-opus-5-5" if requested_model == "opus" else requested_model
        assert args[args.index("--effort") + 1] == os.environ["CLAUDE_CODE_EFFORT_LEVEL"]
        if 'ORCHESTRA_FIXTURE_MODEL' in os.environ:
            assert requested_model == os.environ['ORCHESTRA_FIXTURE_MODEL']
            assert args[args.index('--effort') + 1] == os.environ['ORCHESTRA_FIXTURE_EFFORT']
        settings = json.loads(args[args.index("--settings") + 1])
        for key, value in {"CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1", "BASH_DEFAULT_TIMEOUT_MS": "1800000",
                           "BASH_MAX_TIMEOUT_MS": "21600000", "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "400000"}.items():
            assert os.environ[key] == settings["env"][key] == value
        assert {"Agent", "Task", "Monitor", "CronCreate", "ScheduleWakeup", "RemoteTrigger", "Workflow"} <= set(
            args[args.index("--disallowedTools") + 1].split(","))
        sid = args[args.index("--resume") + 1] if "--resume" in args else args[args.index("--session-id") + 1]
        streaming_input = "--input-format" in args
        initial = json.loads(sys.stdin.readline()) if streaming_input else None
        prompt = initial["message"]["content"] if initial else sys.stdin.read()
        agent = json.loads(args[args.index('--agents') + 1])['cycle_worker']
        assert args[args.index('--agent') + 1] == 'cycle_worker'
        assert agent['model'] == requested_model
        if '--tools' in args:
            assert '--append-system-prompt' not in args
            agent_prompt = agent['prompt']
        else:
            assert agent['prompt'] == '' and 'memory' not in agent
            assert '--system-prompt' not in args and '--system-prompt-file' not in args
            agent_prompt = args[args.index('--append-system-prompt') + 1]
        assert COMMAND_EXECUTION_CONTRACT in agent_prompt
        assert COMMAND_EXECUTION_CONTRACT in prompt
        # Every Claude role can read its runtime prompt again after a compaction.
        assert agent_prompt.endswith(" a finding needs.") or agent_prompt.endswith(" a finding or a fix needs."), agent_prompt[-200:]
        assert "After a compaction of the conversation, read your runtime prompt again" in agent_prompt
        if os.environ.get("ORCHESTRA_FIXTURE_SYSTEM_LOG"):
            with open(os.environ["ORCHESTRA_FIXTURE_SYSTEM_LOG"], "a", encoding="utf-8") as log:
                log.write(json.dumps(agent_prompt) + "\n")
        assert WRITING_CONTRACT not in agent_prompt and WRITING_CONTRACT not in prompt
        if os.environ.get('ORCHESTRA_FIXTURE_ROLE') == 'code':
            for instructions in (agent_prompt, prompt):
                assert CODE_IMPLEMENTATION_CONTRACT in instructions
                assert PAIR_CONTRACT not in instructions
        readonly = "--tools" in args
        paired = os.environ.get("ORCHESTRA_FIXTURE_ROLE", "") in PAIR_ROLES
        if readonly:
            assert args[args.index("--tools") + 1] == ("" if paired else "Read,Glob,Grep")
            assert "--strict-mcp-config" in args and "--disable-slash-commands" in args
            servers = json.loads(args[args.index("--mcp-config") + 1])["mcpServers"]
            assert set(servers) == ({"focus"} if paired else set())
            if paired:
                # The view server gets the recovery copy of the reader's prompt as its second argument.
                recovery = Path(servers["focus"]["args"][2])
                assert recovery.name.endswith(".txt") and recovery.parent.name == "prompts" and recovery.is_file()
            if paired:
                assert args[args.index("--setting-sources") + 1] == ""
        if not (readonly and paired):
            # The user writing policy reaches Claude writers through these settings.
            assert args[args.index("--setting-sources") + 1] == "user,project,local"
        if "--resume" in args and (missing_session or "auth-error" in args):
            error = f"No conversation found with session ID: {sid}" if missing_session else "Authentication failed"
            emit({"type": "result", "subtype": "error_during_execution", "is_error": True,
                  "num_turns": 0, "session_id": sid, "errors": [error]})
            return
        if missing_session:
            assert "new conversation for the SAME runtime phase" in prompt
        if 'opus-wrong-family' in args:
            effective_model = 'claude-fable-5-1'
        if 'opus-before-init' in args:
            emit({'type': 'assistant', 'message': {'model': effective_model}})
        if "synthetic-org-preinit" not in args and "quota-preinit" not in args and "refusal-preinit" not in args:
            emit({"type": "system", "subtype": "init", "model": effective_model, "session_id": sid, "permissionMode": "bypassPermissions",
                  "tools": (["mcp__focus__inspect"] if paired else ["Read", "Glob", "Grep"]) if readonly else ["Bash", "Read"]})
        if "instruction-change" in args or "instruction-delete" in args:
            # An operator changes the user instruction file while Claude runs.
            user_file = Path(os.environ["CLAUDE_CONFIG_DIR"]) / "CLAUDE.md"
            user_file.unlink() if "instruction-delete" in args else user_file.write_text("Version B", encoding="utf-8")
        if 'opus-switch' in args:
            emit({'type': 'assistant', 'message': {'model': 'claude-opus-5'}})
        quota_variant = next((arg for arg in args if arg.startswith("quota")), None)
        if quota_variant:
            reset = {"quota-no-reset": None, "quota-reset-string": "1789482000", "quota-reset-bool": True,
                     "quota-reset-inf": float("inf"), "quota-reset-nan": float("nan"),
                     "quota-reset-huge": 10**100, "quota-reset-negative": -1}.get(quota_variant, 1789482000)
            info = {"status": "rejected", "resetsAt": reset, "rateLimitType": "five_hour",
                    "overageStatus": "rejected", "overageDisabledReason": "org_level_disabled"}
            if quota_variant in ("quota-allowed", "quota-allowed-error"):
                info["status"] = "allowed"
            if quota_variant == "quota-warning":
                info["status"] = "allowed_warning"
            if quota_variant != "quota-no-event":
                emit({"type": "rate_limit_event", "rate_limit_info": info,
                      "session_id": "foreign" if quota_variant == "quota-wrong-session" else sid})
            if quota_variant == "quota-work":
                emit({"type": "assistant", "message": {"model": effective_model, "content": [
                    {"type": "tool_use", "name": "Bash", "input": {"command": "fixture-command"}}]}})
            if quota_variant == "quota-result":
                emit({"type": "result", "subtype": "success", "is_error": True, "terminal_reason": "api_error",
                      "api_error_status": 429, "session_id": sid, "result": "Session quota rejected"})
                return
            if quota_variant not in ("quota-event-only", "quota-warning", "quota-allowed"):
                emit({"type": "assistant", "session_id": "foreign" if quota_variant == "quota-error-wrong-session" else sid,
                      "is_api_error_message": True, "error": "oauth_org_not_allowed" if quota_variant == "quota-access" else "rate_limit",
                      "message": {"model": "<synthetic>", "content": [{"type": "text", "text": "Session quota rejected"}]}})
                return
        transient = next((arg for arg in args if arg.startswith("transient-")), None)
        if transient == "transient-once":
            marker = Path.cwd() / ".work/cycle/transient-once"
            if marker.exists():
                transient = None
            else:
                marker.touch()
        if transient:
            if transient.startswith("transient-http-") or transient == "transient-result-text":
                code = transient.removeprefix("transient-http-")
                status_code = "500" if code == "string" else 500 if transient == "transient-result-text" else int(code)
                emit({"type": "result", "session_id": sid, "is_error": True, "subtype": "error_during_execution",
                      "terminal_reason": "unclassified" if transient == "transient-result-text" else "api_error",
                      "api_error_status": status_code, "errors": ["server_error in provider result"]})
                return
            if transient in ("transient-work", "transient-once"):
                emit({"type": "assistant", "session_id": sid, "message": {"model": effective_model,
                      "content": [{"type": "tool_use", "id": "read", "name": "Bash", "input": {"command": "read-only fixture"}}]}})
            emit({"type": "assistant", "session_id": "foreign" if transient == "transient-foreign" else sid,
                  "is_api_error_message": transient not in ("transient-unmarked", "transient-quoted"),
                  "error": "overloaded_error" if transient == "transient-overloaded" else "server_error",
                  "message": {"model": effective_model if transient == "transient-quoted" else "<synthetic>",
                              "content": [{"type": "text", "text": "Server error mid-response"}]}})
            if transient != "transient-quoted":
                return
        stream_refusal = next((arg for arg in args if arg.startswith("stream-refusal")), None)
        if stream_refusal:
            model = "other-model" if stream_refusal.endswith("wrong-model") else effective_model
            if stream_refusal != "stream-refusal-no-start":
                emit({"type": "stream_event", "session_id": "foreign" if stream_refusal.endswith("foreign-start") else sid,
                      "parent_tool_use_id": "child" if stream_refusal.endswith("child-start") else None, "event": {
                    "type": "message_start", "message": {"id": "msg_stream", "model": model}}})
                # Real CLI emits the assistant frame before the terminal delta;
                # the assistant stop_reason is null and request_id is here only.
                if model == effective_model:
                    emit({"type": "assistant", "session_id": sid, "request_id": "req_stream", "message": {
                        "id": "msg_stream", "model": model, "stop_reason": None, "content": [
                            {"type": "thinking", "thinking": "PRIVATE THOUGHT", "signature": "PRIVATE SIGNATURE"},
                            {"type": "tool_use", "id": "write-1", "name": "Write", "input": {"file_path": "private.cs"}}]}})
            emit({"type": "stream_event", "session_id": "foreign" if stream_refusal.endswith("foreign") else sid,
                  "parent_tool_use_id": "child" if stream_refusal.endswith("child") else None,
                  "event": {"type": "message_delta", "delta": {"stop_reason": "refusal", "stop_details":
                      None if stream_refusal.endswith("null") else {
                          "type": "refusal", "category": "reasoning_extraction", "explanation": "public refusal"}}}})
            # A successful native continuation must never erase a streamed refusal.
            emit({"type": "result", "subtype": "success", "is_error": False, "session_id": sid,
                  "result": json.dumps(report())})
            return
        refusal = next((arg for arg in args if arg.startswith("refusal-")), None)
        if refusal == "refusal-resumed" and "--resume" not in args:
            refusal = None  # A new conversation completes normally.
        if refusal in ("refusal-late", "refusal-late-once"):
            marker = Path.cwd() / ".work/cycle/refusal-late-once"
            if refusal == "refusal-late-once" and marker.exists():
                refusal = None  # The second conversation completes normally.
            else:
                marker.touch()
                # The conversation completes a tool exchange, then the provider refuses a later request.
                emit({"type": "assistant", "session_id": sid, "message": {"id": "msg_work", "model": effective_model,
                      "content": [{"type": "tool_use", "id": "read", "name": "Bash", "input": {"command": "read-only fixture"}}]}})
                emit({"type": "user", "session_id": sid, "message": {"role": "user", "content": [
                      {"type": "tool_result", "tool_use_id": "read", "content": "fixture output"}]}})
        if refusal == "refusal-broken-stream":
            # A stream broke before its first answer completed. The CLI then retried the same first request.
            emit({"type": "stream_event", "session_id": sid, "parent_tool_use_id": None, "event": {
                  "type": "message_start", "message": {"id": "msg_aborted", "model": effective_model}}})
        if refusal:
            if refusal == "refusal-work":
                (Path.cwd() / "source.txt").write_text("partial implementation\n")
            native = refusal in ("refusal-native", "refusal-native-foreign", "refusal-quoted", "refusal-wrong-model")
            message = {"type": "assistant", "session_id": "foreign" if refusal.endswith("foreign") else sid,
                       "request_id": "req_fixture", "message": {
                           "model": effective_model if native else "<synthetic>", "id": "msg_fixture",
                           "stop_reason": "end_turn" if refusal in ("refusal-text-only", "refusal-quoted") else "refusal",
                           "stop_details": None if refusal == "refusal-null" else {
                               "type": "refusal", "category": "reasoning_extraction", "explanation": "public provider explanation"},
                           "content": [{"type": "text", "text": "API Error: safeguards flagged this request [reasoning_extraction]"},
                                       {"type": "thinking", "thinking": "PRIVATE REFUSAL CONTENT"}]}}
            if refusal == "refusal-wrong-model":
                message["message"]["model"] = "unexpected-model"
            if not native and refusal != "refusal-unmarked":
                message.update(is_api_error_message=True, error="invalid_request")
            emit(message)
            if refusal != "refusal-quoted":
                return
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
                    api_message["message"]["model"] = effective_model
            emit(api_message)
            if api_variant != "quoted-api-error":
                return
        if live:
            emit({"type": "assistant", "message": {"id": "m", "model": effective_model, "content": [
                {"type": "text", "text": "Public fixture message"},
                {"type": "thinking", "thinking": "PRIVATE REASONING"},
                {"type": "tool_use", "id": "t", "name": "Bash", "input": {"command": "fixture-command"}}]}})
            emit({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t", "content": "Fixture output"}]}})
        if "usage-stream" in args:
            # One API message as a stream start, three assistant events, and a final delta; then a compaction and a second message.
            usage = {"input_tokens": 10, "cache_creation_input_tokens": 300, "cache_read_input_tokens": 1000,
                     "cache_creation": {"ephemeral_5m_input_tokens": 100, "ephemeral_1h_input_tokens": 200}}
            emit({"type": "stream_event", "session_id": sid, "event": {"type": "message_start", "message": {
                "id": "usage-1", "model": effective_model, "usage": dict(usage, output_tokens=1)}}})
            for output in (5, 9, 9):
                emit({"type": "assistant", "session_id": sid, "message": {"id": "usage-1", "model": effective_model,
                      "usage": dict(usage, output_tokens=output), "content": [{"type": "text", "text": "Fixture"}]}})
            emit({"type": "stream_event", "session_id": sid, "event": {"type": "message_delta",
                  "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 40}}})
            emit({"type": "stream_event", "session_id": sid, "event": {"type": "message_stop"}})
            emit({"type": "system", "subtype": "compact_boundary", "session_id": sid,
                  "compact_metadata": {"trigger": "auto", "pre_tokens": 390000, "post_tokens": 9000}})
            emit({"type": "assistant", "session_id": sid, "message": {"id": "usage-2", "model": effective_model, "usage": {
                "input_tokens": 5, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 9000, "output_tokens": 7},
                "content": [{"type": "text", "text": "Fixture after compaction"}]}})
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
            emit({"type": "assistant", "message": {"model": effective_model, "content": [
                {"type": "text", "text": "Native tasks finished; completing verification"}]}})
        first = report(implementation_fixes=1, substantial=True) if "prior-fix" in args else report()
        if os.environ.get("ORCHESTRA_FIXTURE_ROLE") == "final_cleanup":
            first["resolutions"] = []
        if readonly:
            first["findings"] = []
        role = os.environ.get("ORCHESTRA_FIXTURE_ROLE", "")
        if role in PAIR_ROLES:
            if role == "repair_evidence":
                first.pop("findings", None)
                first["evidence_delta"] = {"before": "before", "after": "after", "files": [{
                    "path": "plan.md", "verdict": "evidence_only", "reason": "Historical check record",
                    "evidence": ["Exact fixture diff"]}]}
            elif role.endswith("_discuss") or role == "pair_arbiter":
                first.pop("findings", None)
                first.update(assessments=[], new_findings=[], consensus=None, impact="minor")
            elif role in PAIR_WRITERS:
                first.update(resolutions=[], handoff={"decisions": [], "assumptions": [], "checks": []})
            if os.environ.get("ORCHESTRA_FIXTURE_ROLE") == "repair_execute":
                first["repair"] = {"mode": "self", "reason": "Local fix", "risks": [], "tests": {"status": "deferred", "reason": "Await reviews", "evidence": [], "failures": []}}
        if "long-summary" in args:
            first["summary"] = "First summary " * 100 + "first summary ending"
        if paired_report_once and paired and not Path(".paired-report-once").exists():
            Path(".paired-report-once").touch()
            first.pop("findings", None)  # The runtime asks once for a corrected report.
        emit({"type": "result", "subtype": "success", "is_error": False, "session_id": sid, "result": json.dumps(first)})
        if streaming_input:
            assert "--replay-user-messages" in args
            for line in sys.stdin:
                incoming = json.loads(line)
                assert "focus-message:" in incoming["message"]["content"]
                if "no-ack" not in args:
                    emit(incoming)
                if "follow-up-server-error" in args:
                    emit({"type": "assistant", "session_id": sid, "is_api_error_message": True, "error": "server_error",
                          "message": {"model": "<synthetic>", "content": [{"type": "text", "text": "Internal server error"}]}})
                    return
                final = report(description="Operator instruction handled in the same process.")
                if "long-summary" in args:
                    final["summary"] = "Final summary " * 100 + "final summary ending"
                emit({"type": "result", "subtype": "success", "is_error": False, "session_id": sid,
                      "result": json.dumps(final)})
        if live:
            print("Trailing fixture stderr", file=sys.stderr, flush=True)
        return
    readonly = args[1] == "read-only"
    assert args[:5] == ["-s", "read-only" if readonly else "danger-full-access", "-a", "on-request", "app-server"]
    assert ('sandbox_mode="read-only"' if readonly else 'sandbox_mode="danger-full-access"') in args
    if readonly:
        from focus_readonly import READONLY_FEATURES
        assert all("features." + key + "=false" in args for key in READONLY_FEATURES)
        assert "features.code_mode_host=true" in args
        assert "features.code_mode_host=false" not in args
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
            result = {"data": [{"model": model, "supportedReasoningEfforts": [{"reasoningEffort": "high"}, {"reasoningEffort": "xhigh"}, {"reasoningEffort": "max"}]}
                               for model in ((() if old_sol_only else ("gpt-6.1-sol",)) + ("gpt-6-sol", "gpt-6-astra", "gpt-5.6-luna"))], "nextCursor": None}
        elif method in ("thread/start", "thread/resume"):
            assert COMMAND_EXECUTION_CONTRACT in params['developerInstructions']
            assert WRITING_CONTRACT in params['developerInstructions']
            assert params["config"]["features.memories"] is False
            if 'ORCHESTRA_FIXTURE_MODEL' in os.environ:
                assert params['model'] == os.environ['ORCHESTRA_FIXTURE_MODEL']
                assert params['config']['model_reasoning_effort'] == os.environ['ORCHESTRA_FIXTURE_EFFORT']
            if method == "thread/resume" and missing_session:
                emit({"id": request["id"], "error": {"code": -32600, "message": "no rollout found for thread id"}})
                continue
            sid = params.get("threadId", str(uuid.uuid4()))
            assert params["approvalPolicy"] == "on-request"
            assert params["sandbox"] == ("read-only" if readonly else "danger-full-access")
            if readonly:
                assert params["config"]["mcp_servers"] == {}
                assert params["config"]["features.code_mode_host"] is True
                assert all(params["config"]["features." + key] is False for key in READONLY_FEATURES)
                assert "mcp_servers={}" in args
                if method == "thread/start":
                    assert params["dynamicTools"][0]["name"] == "focus_inspect"
                    if os.environ.get("ORCHESTRA_FIXTURE_ROLE"):
                        # Only a reader of a frozen pair view gets the search operation.
                        searchable = "pattern" in params["dynamicTools"][0]["inputSchema"]["properties"]
                        assert searchable == (os.environ["ORCHESTRA_FIXTURE_ROLE"] in PAIR_READONLY), params["dynamicTools"][0]
            if method == "thread/resume":
                assert params["excludeTurns"] is True, "Do not return unbounded conversation history"
            result = {"thread": {"id": sid, "turns": []}, "model": params["model"], "cwd": params["cwd"],
                      "reasoningEffort": params["config"]["model_reasoning_effort"],
                      "approvalPolicy": "on-request", "approvalsReviewer": "user", "sandbox": {"type": "readOnly" if readonly else "dangerFullAccess"}}
        elif method == "thread/turns/list" and codex_error and (Path.cwd() / ".work/cycle/codex-failed-turn.json").exists():
            # Like the app-server: the latest turn is the failed one, with the original input.
            result = {"data": [json.loads((Path.cwd() / ".work/cycle/codex-failed-turn.json").read_text())]}
        elif method == "thread/turns/list":
            assert not paired_report_once, "A corrected report needs a fresh marker"
            assert not missing_session, "An unmaterialized replacement has no historical turns to fetch"
            assert params["limit"] == 1 and params["itemsView"] == "full"
            recovered_report = report(status="blocked", findings=[]) if paired_blocked_once else report()
            result = {"data": [{"id": "finished-turn", "status": "inProgress" if paired_active else "completed", "items": [
                {"id": "final", "type": "agentMessage", "phase": "final_answer", "text": json.dumps(recovered_report)}]}]}
        elif method == "turn/start":
            assert COMMAND_EXECUTION_CONTRACT in params['input'][0]['text']
            assert WRITING_CONTRACT in params['input'][0]['text']
            assert not recovery, "A completed turn must not be repeated"
            assert params["threadId"] == sid
            assert params["sandboxPolicy"] == {"type": "readOnly" if readonly else "dangerFullAccess"}
            assert schema_keywords(params["outputSchema"]) <= STRICT_KEYWORDS and strict_objects(params["outputSchema"]), \
                "Codex strict mode refuses this schema"
            if missing_session:
                assert "new conversation for the SAME runtime phase" in params["input"][0]["text"]
            final = report()
            for field in ("findings", "assessments", "new_findings", "resolutions"):
                if field in params["outputSchema"]["properties"]:
                    final[field] = []
            if "complexity" in params["outputSchema"]["properties"]:
                final["complexity"] = {"assignment_sha256": "fixture", "effort": "high", "reason": "Local fix",
                                       "assignments": [{"source_id": "fixture", "effort": "high", "reason": "Local fix"}]}
            if paired_report_once and not Path(".paired-report-once").exists():
                Path(".paired-report-once").touch()
                final.pop("findings", None)
            if paired_blocked_once and not Path(".paired-blocked-once").exists():
                Path(".paired-blocked-once").touch()
                final.update(status="blocked", summary="Inspection host unavailable")
            if "consensus" in params["outputSchema"]["properties"]:
                final.update(consensus=None, impact="minor")
            turn = {"id": str(uuid.uuid4()), "status": "completed", "items": [
                {"id": "final", "type": "agentMessage", "phase": "final_answer", "text": json.dumps(final)}]}
            once = Path.cwd() / ".work/cycle/codex-error-once"
            if codex_error and not (codex_error.endswith("-once") and once.exists()):
                if codex_error.endswith("-once"):
                    once.touch()
                kind = codex_error.removesuffix("-once")
                info = {"httpConnectionFailed": {"httpStatusCode": int(kind[4:])}} if kind.startswith("http") else kind
                turn.update(status="failed", items=[], error={
                    "message": "Selected model is at capacity. Please try a different model.",
                    "codexErrorInfo": info, "additionalDetails": None})
                (Path.cwd() / ".work/cycle/codex-failed-turn.json").write_text(json.dumps({**turn, "items": [
                    {"id": "input", "type": "userMessage", "content": params["input"]}]}))
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
        if method == "turn/start" and codex_error:
            # The app-server reports the input message as the first item; it is not model work.
            emit({"method": "item/started", "params": {"threadId": sid, "turnId": turn["id"],
                  "item": {"id": "input", "type": "userMessage", "content": params["input"]}}})
        if method == "turn/start":
            if readonly:
                for operation in ("list", "read", "diff", "run"):
                    emit({"id": "inspect-" + operation, "method": "item/tool/call", "params": {
                        "threadId": sid, "turnId": turn["id"], "callId": operation, "tool": "focus_inspect",
                        "arguments": {"operation": operation, "path": "source.txt", "offset": 0, "limit": 20}}})
                    answer = json.loads(sys.stdin.readline())
                    assert answer["id"] == "inspect-" + operation
                    assert answer["result"]["success"] == (operation != "run")
                    if operation == "read":
                        assert "initial" in answer["result"]["contentItems"][0]["text"]
                    if operation == "list":
                        assert "source.txt" in answer["result"]["contentItems"][0]["text"]
            if live:
                emit({"method": "item/agentMessage/delta", "params": {"itemId": "m", "delta": "Public fixture message"}})
                emit({"method": "item/reasoning/textDelta", "params": {"delta": "PRIVATE REASONING"}})
                emit({"method": "item/started", "params": {"item": {"id": "cmd", "type": "commandExecution", "command": "fixture-command"}}})
                emit({"method": "item/commandExecution/outputDelta", "params": {"itemId": "cmd", "delta": "Fixture output"}})
            if codex_work:
                emit({"method": "item/started", "params": {"item": {"id": "cmd", "type": "commandExecution", "command": "fixture-command"}}})
            if not steer:
                emit({"method": "turn/completed", "params": {"threadId": sid, "turn": turn}})
            if live:
                print("Trailing fixture stderr", file=sys.stderr, flush=True)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "fixture":
        fixture(sys.argv[2])
    else:
        unittest.main()
