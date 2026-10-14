"""Final round regressions: real snapshots, fake providers, no account or model calls."""

import json
import os
import unittest
from unittest.mock import patch
from pathlib import Path

import test_cycle as fixtures
from test_cycle import report
from cycle_prompts import FINAL_SCANNERS, READONLY_REVIEW_ROLES
from focus_pair_profile import PAIR_READONLY
READONLY_REVIEW_ROLES = tuple(r for r in READONLY_REVIEW_ROLES if r not in PAIR_READONLY)
from cycle_state import Blocked
from cycle_transport import parse_report
from focus_readonly import Inspector


def finding(identity="a"):
    return {"id": identity, "title": "Missing empty input guard", "body": "Empty input reaches an unchecked index.",
            "severity": "high", "locations": [{"path": "source.txt", "line": 1}]}


def assessment(source, blocking=True, verdict="confirmed", duplicate_of=None):
    return {"source_id": source, "verdict": verdict, "duplicate_of": duplicate_of,
            "blocking": blocking, "reason": "Verified the actual input path and current implementation.",
            **{k: v for k, v in finding().items() if k != "id"}}


def resolution(source="r1:final_opus:a"):
    return {"source_id": source, "resolution": "Added the missing input guard.",
            "evidence": ["The empty-input regression passes with the guard in source.txt."]}


class FinalReviewTests(unittest.TestCase):
    setUp = fixtures.CycleTests.setUp
    tearDown = fixtures.CycleTests.tearDown
    edit = fixtures.CycleTests.edit

    def start(self):
        self.edit()()
        self.state.update(phase="final", last_snapshot=self.repo.snapshot())

    def step(self, role, result):
        self.transport.actions = [(role, result)]
        self.cycle.final_review_step()
        self.assertFalse(self.transport.actions)

    def scan(self, rows=()):
        for index, role in enumerate(FINAL_SCANNERS):
            self.step(role, report(findings=list(rows) if index == 0 else []))

    def test_one_complete_clean_round_is_sufficient(self):
        self.start()
        original = self.repo.snapshot()
        self.scan()
        self.assertEqual(self.state["phase"], "final")
        self.assertIsNone(self.state["reviewed"])
        self.step("final_triage", report(assessments=[]))
        self.assertEqual(self.state["phase"], "publish")
        self.assertEqual(self.state["reviewed"], original)
        self.assertEqual(self.state["final_review"]["round"], 1)
        self.assertEqual(self.repo.snapshot(), original)
        self.assertEqual([r for r, _ in self.transport.calls], [*FINAL_SCANNERS, "final_triage"])

    def test_scanners_get_a_readable_stage_diff_and_new_file_scope(self):
        self.start()
        self.edit(name="new.txt", content="new behavior\n")()
        self.step("final_opus", report(findings=[]))
        context = json.loads(self.transport.calls[-1][1].split("Runtime context:\n", 1)[1])
        self.assertIn("new.txt", context["stage_scope"]["new_paths"])
        path = Path(context["final_review"]["stage_diff"])
        self.assertIn("-initial", path.read_text())
        self.assertIn("+changed", path.read_text())
        self.assertTrue(path.is_relative_to(self.store.directory))
        path.write_text("tampered diff")
        with self.assertRaisesRegex(Blocked, "stage diff changed"):
            self.cycle.final_review_step()
        self.assertEqual(len(self.transport.calls), 1)

    def test_final_fixer_context_permits_only_scoped_verification(self):
        self.start()
        self.scan([finding()])
        self.step("final_triage", report(assessments=[assessment("r1:final_opus:a")]))
        context = json.loads(self.cycle.context("final_fix").split("Runtime context:\n", 1)[1])
        self.assertFalse(context["verification"]["full_run_allowed"])
        self.assertTrue(context["verification"]["builds_tests_allowed"])
        for role in READONLY_REVIEW_ROLES:
            context = json.loads(self.cycle.context(role).split("Runtime context:\n", 1)[1])
            self.assertFalse(context["verification"]["full_run_allowed"])
            self.assertFalse(context["verification"]["builds_tests_allowed"])

    def test_triage_artifact_cannot_change_during_repair(self):
        self.start()
        self.scan([finding()])
        self.step("final_triage", report(assessments=[assessment("r1:final_opus:a")]))
        def corrupt():
            (self.store.directory / self.state["final_review"]["triage"]["path"]).write_text("{}")
            return self.edit(content="fixed\n", implementation_fixes=1)()
        with self.assertRaisesRegex(Blocked, "evidence changed"):
            self.step("final_fix", corrupt)
        self.assertEqual(self.state["phase"], "final")
        self.assertIsNone(self.state["reviewed"])

    def test_all_scanners_run_despite_findings_then_fix_and_recheck_everything(self):
        self.start()
        self.scan([finding()])
        self.step("final_triage", report(assessments=[assessment("r1:final_opus:a")]))
        self.assertEqual(self.state["final_review"]["step"], "final_fix")
        self.assertIsNone(self.state["reviewed"])
        self.step("final_fix", self.edit(content="fixed empty input\n", implementation_fixes=1, substantial=True))
        self.assertEqual(self.state["final_review"]["round"], 2)
        self.scan()
        self.step("final_triage", report(assessments=[assessment("r1:final_opus:a", False, "rejected")]))
        self.assertEqual(self.state["phase"], "publish")
        self.assertEqual([r for r, _ in self.transport.calls],
                         [*FINAL_SCANNERS, "final_triage", "final_fix", *FINAL_SCANNERS, "final_triage"])
        self.assertEqual(self.state["backlog"][0]["findings"], [])

    def test_nonblocking_findings_survive_blocker_repair_then_cleanup_without_review(self):
        self.start()
        self.scan([finding("blocker"), finding("later")])
        self.step("final_triage", report(assessments=[assessment("r1:final_opus:blocker"), assessment("r1:final_opus:later", False)]))
        self.step("final_fix", self.edit(content="fixed\n", implementation_fixes=1))
        self.state = self.store.read()
        self.cycle.state = self.state
        self.scan()
        self.step("final_triage", report(assessments=[assessment("r1:final_opus:blocker", False, "rejected"),
                                                     assessment("r1:final_opus:later", False)]))
        backlog = json.loads((self.store.directory / "backlog.json").read_text())
        self.assertEqual(backlog["stages"], self.state["backlog"])
        self.assertEqual([r["source_id"] for r in backlog["stages"][0]["findings"]], ["r1:final_opus:later"])
        self.assertEqual(self.state["phase"], "final")
        self.assertEqual(self.state["final_review"]["step"], "final_cleanup")
        self.step("final_cleanup", self.edit(content="all findings fixed\n", implementation_fixes=1,
                                             resolutions=[resolution("r1:final_opus:later")]))
        self.assertEqual(self.state["phase"], "publish")
        self.assertEqual(self.state["backlog"][0]["findings"], [])
        self.assertEqual([r for r, _ in self.transport.calls],
                         [*FINAL_SCANNERS, "final_triage", "final_fix", *FINAL_SCANNERS, "final_triage", "final_cleanup"])

    def test_renewed_reviews_of_same_stage_cannot_silently_drop_its_backlog(self):
        self.start()
        self.scan([finding()])
        self.step("final_triage", report(assessments=[assessment("r1:final_opus:a", False)]))
        self.cycle.reset_reviews("CI repair requires fresh review")
        self.state["phase"] = "final"  # Ordinary clean loops complete before this boundary.
        self.scan([finding()])  # Reusing a scanner-local ID must not collide with carried evidence.
        sources = self.cycle.final_sources(self.state["final_review"])
        self.assertEqual(len({row["source_id"] for row in sources}), 2)
        old_id = next(row["source_id"] for row in sources if row["source_id"].startswith("carried:"))
        self.step("final_triage", report(assessments=[assessment(old_id, False),
            assessment("r1:final_opus:a", False, "duplicate", old_id)]))
        self.assertEqual(len(self.state["backlog"]), 1)
        self.assertEqual(len(self.state["backlog"][0]["findings"]), 1)

    def start_cleanup(self):
        self.start()
        self.scan([finding()])
        self.step("final_triage", report(assessments=[assessment("r1:final_opus:a", False)]))
        self.assertIsNone(self.state["reviewed"])
        self.assertEqual(self.state["final_review"]["step"], "final_cleanup")

    def test_cleanup_seals_its_changes_without_clean_pass_loop_or_review_return(self):
        self.start_cleanup()
        before = self.repo.snapshot()
        context = json.loads(self.cycle.context("final_cleanup").split("Runtime context:\n", 1)[1])
        self.assertTrue(context["verification"]["builds_tests_allowed"])
        self.assertFalse(context["verification"]["full_run_allowed"])
        self.assertEqual(len(context["final_review"]["findings"]), 1)
        self.step("final_cleanup", self.edit(content="guarded\n", implementation_fixes=1,
                                             substantial=True, resolutions=[resolution()]))
        self.assertNotEqual(self.state["reviewed"], before)
        self.assertEqual(self.state["reviewed"], self.repo.snapshot())
        self.assertEqual(self.state["phase"], "publish")
        self.assertIsNone(self.state["pending"])
        self.assertFalse(self.state["coordinated"])
        self.assertEqual([r for r, _ in self.transport.calls], [*FINAL_SCANNERS, "final_triage", "final_cleanup"])
        entry = self.state["backlog"][0]
        self.assertEqual(entry["findings"], [])
        self.assertEqual(len(entry["closed_findings"]), 1)
        self.assertEqual(self.cycle.final_record(entry["cleanup"])["resolutions"], [resolution()])
        self.assertEqual(json.loads((self.store.directory / "backlog.json").read_text())["stages"], self.state["backlog"])
        self.assertEqual(self.cycle.publication_paths(), ["source.txt"])

    def test_cleanup_requires_complete_closure_and_cannot_handle_blockers(self):
        self.start_cleanup()
        with self.assertRaisesRegex(Blocked, "close every"):
            self.step("final_cleanup", report(resolutions=[]))
        self.assertIsNone(self.state["reviewed"])
        for rows in ([resolution(), resolution()], [dict(resolution(), evidence=[])],
                     [dict(resolution(), resolution=" ")]):
            with self.subTest(rows=rows), self.assertRaises(Blocked):
                parse_report(json.dumps(report(resolutions=rows)), "final_cleanup")
        final = self.state["final_review"]
        original = final["confirmed"]
        with patch.object(self.cycle, "confirmed_findings", return_value=[dict(original[0], blocking=True)]):
            with self.assertRaisesRegex(Blocked, "only confirmed nonblocking"):
                self.cycle.final_review_step()
        self.assertEqual(len(self.transport.calls), 5)
        with self.assertRaisesRegex(Blocked, "close every"):
            self.cycle.validate_final_cleanup(final, report(resolutions=[resolution("unknown")]))

    def test_cleanup_blocked_report_keeps_findings_open(self):
        self.start_cleanup()
        with self.assertRaisesRegex(Blocked, "cannot close"):
            self.step("final_cleanup", report(status="blocked", summary="cannot close", resolutions=[]))
        self.assertEqual(self.state["phase"], "final")
        self.assertIsNone(self.state["reviewed"])
        self.assertEqual(len(self.store.read()["backlog"][0]["findings"]), 1)

    def test_cleanup_resume_and_cached_result_do_not_repeat_any_model(self):
        self.start_cleanup()
        self.state = self.store.read()
        self.cycle.state = self.state
        with patch.object(self.cycle, "save_final_record", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                self.step("final_cleanup", self.edit(content="fixed\n", implementation_fixes=1,
                                                     resolutions=[resolution()]))
        self.state = self.store.read()
        self.cycle.state = self.state
        self.transport.actions = []
        self.cycle.final_review_step()
        self.assertEqual(len(self.transport.calls), 5)
        self.assertEqual(self.state["phase"], "publish")
        self.assertEqual(self.state["reviewed"], self.repo.snapshot())

    def test_closed_findings_have_verifiable_history_and_do_not_reopen_on_restart(self):
        self.start_cleanup()
        self.step("final_cleanup", self.edit(content="fixed\n", implementation_fixes=1, resolutions=[resolution()]))
        entry = self.state["backlog"][0]
        self.cycle.reset_reviews("CI repair")
        self.state["phase"] = "final"
        self.scan()
        self.assertEqual(self.cycle.final_sources(self.state["final_review"]), [])
        self.step("final_triage", report(assessments=[]))
        # Start again with the original closure entry: a missing report cannot silently erase findings.
        self.state["backlog"] = [entry]
        (self.store.directory / entry["cleanup"]["path"]).write_text("{}")
        self.cycle.reset_reviews("CI repair")
        self.state["phase"] = "final"
        with self.assertRaisesRegex(Blocked, "evidence changed"):
            self.cycle.final_review_step()

    def test_cleanup_operator_intervention_still_restarts_all_reviews(self):
        self.start_cleanup()
        def intervene():
            self.state["pending"]["restart_reviews"] = True
            return self.edit(content="operator-requested change\n", implementation_fixes=1,
                             resolutions=[resolution()])()
        self.step("final_cleanup", intervene)
        self.assertEqual(self.state["phase"], "pair_a")
        self.assertIsNone(self.state["reviewed"])
        self.assertIsNone(self.state["final_review"])
        self.assertEqual(len(self.state["backlog"][0]["findings"]), 1)

    def test_cleanup_preserves_protected_work_and_staging_guards(self):
        self.edit(name="operator.txt", content="operator work\n")()
        self.repo.git("add", "operator.txt")
        self.state = fixtures.fresh_state(self.repo)
        self.cycle.state = self.state
        self.start_cleanup()
        def stage_operator_change():
            self.edit(name="operator.txt", content="different index\n")()
            self.repo.git("add", "operator.txt")
            self.edit(name="operator.txt", content="operator work\n")()
            return report(resolutions=[resolution()])
        with self.assertRaises(Blocked) as caught:
            self.step("final_cleanup", stage_operator_change)
        self.assertEqual(caught.exception.code, "protected-index")
        self.assertIsNone(self.state["reviewed"])

    def test_cleanup_cannot_mutate_its_triage_or_commit(self):
        self.start_cleanup()
        def commit():
            self.repo.git("add", "source.txt")
            self.repo.git("commit", "-m", "Unauthorized")
            return report(resolutions=[resolution()])
        with self.assertRaises(Blocked) as caught:
            self.step("final_cleanup", commit)
        self.assertEqual(caught.exception.code, "unauthorized-commit")
        self.assertIsNone(self.state["reviewed"])

    def test_false_positive_or_duplicate_needs_explicit_disposition(self):
        self.start()
        self.scan([finding("a"), finding("b")])
        with self.assertRaisesRegex(Blocked, "every source"):
            self.step("final_triage", report(assessments=[assessment("r1:final_opus:a", False)]))
        self.assertEqual(self.state["phase"], "final")
        self.assertIsNone(self.state["reviewed"])

    def test_duplicate_must_name_a_confirmed_finding(self):
        self.start()
        self.scan([finding()])
        with self.assertRaisesRegex(Blocked, "duplicate must"):
            self.step("final_triage", report(assessments=[assessment("r1:final_opus:a", False, "duplicate", "missing")]))

    def test_resume_does_not_repeat_completed_scanners(self):
        self.start()
        self.step("final_opus", report(findings=[]))
        self.state = self.store.read()
        self.cycle.state = self.state
        self.step("final_astra", report(findings=[]))
        self.assertEqual([r for r, _ in self.transport.calls], ["final_opus", "final_astra"])
        self.assertEqual(self.state["final_review"]["step"], "claude")

    def test_cached_result_survives_crash_before_step_transition(self):
        self.start()
        # Persist candidate and invocation, then interrupt after result is durable.
        with patch.object(self.cycle, "save_final_record", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                self.step("final_opus", report(findings=[]))
        self.state = self.store.read()
        self.cycle.state = self.state
        self.transport.actions = []
        self.cycle.final_review_step()
        self.assertEqual(len(self.transport.calls), 1)
        self.assertEqual(self.state["final_review"]["step"], "final_astra")

    def test_candidate_drift_invalidates_inspection_without_new_provider(self):
        self.start()
        self.step("final_opus", report(findings=[]))
        self.edit(content="external change\n")()
        with self.assertRaisesRegex(Blocked, "candidate changed"):
            self.cycle.final_review_step()
        self.assertEqual(len(self.transport.calls), 1)

    def test_readonly_inspection_cannot_change_files_even_with_edit_counters(self):
        for role in READONLY_REVIEW_ROLES:
            with self.subTest(role=role):
                self.state["pending"] = None
                extra = {"assessments": []} if role == "final_triage" else {"findings": []}
                self.transport.actions = [(role, self.edit(content=role, **extra))]
                with self.assertRaisesRegex(Blocked, "read-only"):
                    self.cycle.invoke(role)
                self.assertIsNone(self.state["reviewed"])
                with self.assertRaisesRegex(Blocked, "cannot claim"):
                    parse_report(json.dumps(report(minor_edits=1, **extra)), role)

    def test_report_schema_rejects_duplicate_ids_and_malformed_locations(self):
        for rows in [[finding(), finding()], [dict(finding(), locations=[{"path": "../escape", "line": 1}])],
                     [dict(finding(), locations=[{"path": "source.txt", "line": True}])]]:
            with self.subTest(rows=rows), self.assertRaises(Blocked):
                parse_report(json.dumps(report(findings=rows)), "final_opus")

    def test_record_drift_cannot_be_used_for_triage(self):
        self.start()
        self.scan()
        record = self.state["final_review"]["scans"][0]
        (self.store.directory / record["path"]).write_text("{}")
        with self.assertRaisesRegex(Blocked, "evidence changed"):
            self.cycle.final_review_step()
        self.assertEqual(len(self.transport.calls), 3)

    def test_fixer_disagreement_still_requires_a_complete_round_and_explicit_triage(self):
        self.start()
        self.scan([finding()])
        self.step("final_triage", report(assessments=[assessment("r1:final_opus:a")]))
        self.step("final_fix", report(description="The existing guard handles this input; see the current source."))
        self.assertEqual(self.state["phase"], "final")
        self.assertIsNone(self.state["reviewed"])
        self.assertEqual(self.state["final_review"]["step"], "final_opus")
        context = json.loads(self.cycle.context("final_opus").split("Runtime context:\n", 1)[1])
        self.assertTrue(Path(context["final_review"]["preceding_repair"]["report"]).is_file())
        self.scan()
        self.step("final_triage", report(assessments=[assessment("r1:final_opus:a", False, "rejected")]))
        self.assertEqual(self.state["phase"], "publish")

    def test_inspection_tools_are_bounded_readers_and_literal_diff(self):
        self.start()
        inspector = Inspector(self.root, self.state)
        def call(op, path):
            return inspector.call({"tool": "focus_inspect", "arguments": {"operation": op, "path": path, "offset": 0, "limit": 20}})
        self.assertIn("changed", call("read", "source.txt")["contentItems"][0]["text"])
        self.assertIn("+changed", call("diff", "source.txt")["contentItems"][0]["text"])
        self.assertIn("source.txt", call("list", ".")["contentItems"][0]["text"])
        for op, path in [("run", "pytest"), ("read", "../outside"), ("read", ".git/config"), ("diff", "../../source.txt")]:
            self.assertFalse(call(op, path)["success"])
        if os.name != "nt":  # Windows developer-mode symlink privilege is optional.
            (self.root / "escape").symlink_to(self.root.parent)
            self.assertFalse(call("read", "escape/missing")["success"])

    def test_large_stage_diff_can_be_read_by_pages(self):
        path = self.root / "large.diff"
        path.write_bytes(b"+" + b"x" * 1000 + b"\n")
        with path.open("ab") as stream:
            for _ in range(5000):
                stream.write(b"+" + b"x" * 1000 + b"\n")
        result = Inspector(self.root, self.state).call({"tool": "focus_inspect", "arguments": {
            "operation": "read", "path": "large.diff", "offset": 4999, "limit": 2}})
        self.assertTrue(result["success"])
        text = result["contentItems"][0]["text"]
        self.assertIn("5000: +", text)
        self.assertIn("5001: +", text)
        self.assertIn("more: False", text)


if __name__ == "__main__":
    unittest.main()
