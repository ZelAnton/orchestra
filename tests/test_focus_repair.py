"""Late repair gates use real Git snapshots and hermetic provider sessions."""

import copy
import json
import unittest

import test_cycle as fixtures
from test_cycle import report
import test_focus_pairs as pairs
from test_focus_pairs import finding, decision
from cycle_state import Blocked, digest, encode
from cycle_prompts import PROFILES, REVIEW_PROFILE_VERSION
from cycle_transport import parse_report
from focus_pair_profile import PAIR_READONLY
from focus_pair_view import materialize, read_record, ViewInspector
from focus_status import build_panel


class RepairTests(unittest.TestCase):
    setUp = fixtures.CycleTests.setUp
    tearDown = fixtures.CycleTests.tearDown
    edit = fixtures.CycleTests.edit
    start = pairs.PairTests.start
    until = pairs.PairTests.until
    assign = pairs.PairTests.assign

    def writer(self, context, mode="self", status=None, failures=None, substantial=False):
        testing = context["operation"] == "test"
        return report(substantial=substantial, resolutions=[{
            "source_id": t["source_id"], "outcome": ("verified" if testing else "deferred") if t["action"] == "verify" else "fixed",
            "resolution": "Scoped fix or check", "evidence": ["Concrete fixture evidence"]} for t in context["assignments"]],
            handoff={"decisions": [], "assumptions": [], "checks": []},
            repair={"mode": mode, "reason": "Interacting contracts" if mode == "pair" else "Local guard",
                "risks": ["contracts"] if mode == "pair" else [], "tests": {
                    "status": status or ("passed" if testing else "deferred"), "reason": "Targeted check assessment",
                    "evidence": ["Guard test passed"] if testing else [], "failures": failures or []}})

    def set_writer(self, mode="self"):
        def execute(c, h):
            value = self.writer(c, mode)
            if c["operation"] == "fix":
                (self.root / "source.txt").write_text("repair " + str(len(self.transport.calls)) + "\n")
                value["implementation_fixes"] = 1
            return value
        self.transport.handlers["repair_execute"] = execute
        return execute

    def step(self):
        self.cycle.paired_review_step()

    def test_both_late_phases_need_two_clean_passes_before_tests_and_minor_exit(self):
        for phase, destination in (("pair_b", "final"), ("final", "publish")):
            with self.subTest(phase=phase):
                pair = self.assign(phase, "low", False)
                self.set_writer()
                gate = pair["repair"]
                self.step()
                candidate = digest(encode(self.repo.snapshot()))
                self.until(lambda: gate["clean"] == 1)
                self.assertFalse(any(c.get("operation") == "test" for r, c in self.transport.calls))
                self.until(lambda: self.state["phase"] == destination)
                self.assertEqual([r for r, c in self.transport.calls], ["repair_execute", "repair_self", "repair_self", "repair_execute"])
                self.assertEqual(gate["clean_candidate"], candidate)
                self.assertEqual([r["candidate"] for r in gate["reviews"]], [candidate, candidate])
                seal = read_record(self.store, pair["repair_seal"])
                self.assertEqual(seal["clean"], 2)
                self.assertEqual(len(seal["tests"]), 1)
                if destination == "publish":
                    publication_seal = json.loads((self.store.directory / f"pair-reviews/{self.state['iteration']}/{pair['id']}/seal.json").read_text())
                    self.assertTrue(publication_seal["cleanup_without_rereview"])
                    self.assertEqual(publication_seal["repair_gate"], pair["repair_seal"])

    def test_significant_repairs_reach_expensive_pair_only_after_gate(self):
        pair = self.assign("pair_b")
        self.set_writer("pair")
        self.until(lambda: self.state["pair_review"] is None)
        roles = [r for r, c in self.transport.calls]
        self.assertNotIn("pair_complexity", roles)
        self.assertNotIn("pair_astra", roles)
        self.assertEqual(roles.count("repair_astra"), 2)
        self.assertEqual(roles.count("repair_opus"), 2)
        self.assertEqual(roles[-1], "repair_execute")
        self.assertEqual(self.state["phase"], "pair_b")
        self.assertEqual(self.state["pair_carry"][0]["resolution"]["outcome"], "fixed")
        self.until(lambda: self.state["phase"] == "final")
        self.assertEqual([r for r, c in self.transport.calls].count("pair_astra"), 1)

    def test_same_executor_session_is_reused_with_inspection_only_but_pair_is_fresh(self):
        pair = self.assign("final", "low", False)
        self.set_writer()
        observed = []
        fork = self.transport.fork
        def record(root, state, save, heartbeat, **kwargs):
            observed.append((root, copy.deepcopy(state["sessions"]), state["inspection"]["root"]))
            return fork(root, state, save, heartbeat, **kwargs)
        self.transport.fork = record
        self.until(lambda: self.state["phase"] == "publish")
        self.assertEqual(len(observed), 2)
        for root, sessions, view in observed:
            self.assertEqual(root, self.root)
            self.assertEqual(sessions, {"repair_self": "executor-session"})
            self.assertNotEqual(str(root), view)
        self.assign("pair_b", "low", False)
        self.set_writer("pair")
        self.until(lambda: self.state["phase"] == "final")
        for role in ("repair_self", "repair_opus", "repair_astra"):
            self.assertIn(role, PAIR_READONLY)
        self.assertEqual(PROFILES["repair_execute"], ("claude", "opus", "xhigh"))

    def test_new_inner_finding_resets_streak_and_never_repeats_outer_early(self):
        pair = self.assign("pair_b", "low", False)
        self.set_writer()
        passes = [0]
        def review(c, h):
            passes[0] += 1
            return report(findings=[dict(finding("missed"), severity="low")] if passes[0] == 2 else [])
        self.transport.handlers["repair_self"] = review
        def minor(c, h):
            a = c["assignment"]
            return report(assessments=[] if a.get("proposal_hash") else [decision(r, blocking=False) for r in a["registry"]],
                          new_findings=[], consensus=a.get("proposal_hash"), impact="minor")
        self.transport.handlers["repair_self_discuss"] = minor
        self.until(lambda: self.state["phase"] == "final")
        gate = pair["repair"]
        self.assertEqual([r["clean"] for r in gate["reviews"]], [True, False, True, True])
        self.assertNotEqual(gate["reviews"][0]["candidate"], gate["reviews"][-1]["candidate"])
        self.assertEqual([r for r, c in self.transport.calls].count("repair_execute"), 3)
        self.assertNotIn("pair_astra", [r for r, c in self.transport.calls])

    def test_significant_inner_finding_retains_outer_repeat_even_for_minor_original_batch(self):
        pair = self.assign("pair_b", "low", False)
        self.set_writer()
        once = [True]
        def review(c, h):
            result = report(findings=[finding("regression")] if once[0] else [])
            once[0] = False
            return result
        self.transport.handlers["repair_self"] = review
        self.until(lambda: self.state["pair_review"] is None)
        self.assertEqual(self.state["phase"], "pair_b")
        self.assertTrue(pair["repair"]["repeat_outer"])
        self.assertEqual(pair["repair"]["clean"], 2)
        self.assertTrue(pair["repair"]["tests"])
        self.assertEqual(len(self.state["pair_carry"]), 2)

    def test_pair_review_protocol_resolves_disagreement_without_operator(self):
        self.assign("final", "low", False)
        self.set_writer("pair")
        self.transport.handlers["repair_opus"] = lambda c, h: report(findings=[finding()])
        def reject(c, h):
            return report(assessments=[decision(r, "reject", False) for r in c["assignment"]["registry"]],
                          new_findings=[], consensus=None, impact="minor")
        self.transport.handlers["repair_astra_discuss"] = reject
        self.transport.handlers["pair_arbiter"] = reject
        self.until(lambda: self.state["phase"] == "publish")
        self.assertEqual([r for r, c in self.transport.calls].count("pair_arbiter"), 2)
        self.assertIsNone(self.state.get("blocker"))

    def test_test_failure_promotes_to_pair_then_fixes_reviews_and_retests(self):
        pair = self.assign("pair_b", "low", False)
        execute = self.set_writer()
        test_count = [0]
        def run(c, h):
            if c["operation"] == "test":
                test_count[0] += 1
                if test_count[0] == 1:
                    return self.writer(c, status="failed", failures=[finding("regression")])
            return execute(c, h)
        self.transport.handlers["repair_execute"] = run
        self.until(lambda: self.state["pair_review"] is None)
        gate = pair["repair"]
        self.assertEqual(gate["mode"], "pair")
        self.assertEqual([r["mode"] for r in gate["reviews"]], ["self", "self", "pair", "pair"])
        self.assertEqual(test_count[0], 2)
        self.assertEqual(gate["step"], "complete")
        self.assertEqual(self.state["phase"], "pair_b")

    def test_infrastructure_failure_retains_static_credit_and_retry_uses_no_review(self):
        pair = self.assign("final", "low", False)
        execute = self.set_writer()
        failed = [False]
        def run(c, h):
            if c["operation"] == "test" and not failed[0]:
                failed[0] = True
                return self.writer(c, status="infrastructure")
            return execute(c, h)
        self.transport.handlers["repair_execute"] = run
        with self.assertRaisesRegex(Blocked, "Targeted check assessment"):
            self.until(lambda: self.state["phase"] == "publish")
        self.assertEqual(pair["repair"]["clean"], 2)
        self.assertEqual(pair["repair"]["mode"], "self")
        self.until(lambda: self.state["phase"] == "publish")
        self.assertEqual([r for r, c in self.transport.calls].count("repair_self"), 2)

    def test_infrastructure_obstacles_are_explicit_and_cannot_hide_defects(self):
        obstacle = dict(finding('workspace-copy'), kind='verification')
        value = self.writer({'operation': 'test', 'assignments': []}, status='infrastructure', failures=[obstacle])
        self.assertEqual(parse_report(json.dumps(value), 'repair_execute')['repair']['tests']['failures'], [obstacle])
        for status, failure in (('infrastructure', finding()), ('passed', obstacle), ('not_needed', obstacle), ('failed', obstacle)):
            with self.subTest(status=status, kind=failure['kind']):
                value['repair']['tests'].update(status=status, failures=[failure])
                with self.assertRaises(Blocked):
                    parse_report(json.dumps(value), 'repair_execute')

    def test_saved_infrastructure_result_replays_then_retries_only_after_storage_repair(self):
        import test_focus_snapshot_archive as archives
        from unittest.mock import patch
        archives.SnapshotArchiveTests.view(self, legacy=True)
        pair = self.assign('final', 'low', False, action='verify')
        self.set_writer()
        gate = pair['repair']
        self.until(lambda: gate['step'] == 'test')
        obstacle = dict(finding('workspace-copy'), kind='verification')
        def failed(c, h):
            result = self.writer(c, status='infrastructure', failures=[obstacle])
            result['resolutions'][0]['outcome'] = 'deferred'
            return result
        self.transport.handlers['repair_execute'] = failed
        with patch('cycle_workflow.parse_report', side_effect=Blocked('invalid-report', 'old infrastructure schema')):
            with self.assertRaisesRegex(Blocked, 'old infrastructure schema'):
                self.cycle.invoke('repair_execute')
        identity = self.state['pending']['id']
        original = self.store.directory / 'invocations' / identity / 'result.json'
        raw = original.read_bytes()
        calls = len(self.transport.calls)
        self.state['pending'] = None
        self.cycle.prepare_snapshot_storage()
        self.assertIsNotNone(self.cycle.saved_repair_test(pair))
        self.step()  # Accept the exact saved failure, without a provider call.
        self.assertEqual(len(self.transport.calls), calls)
        self.assertEqual(original.read_bytes(), raw)
        self.assertEqual(gate['clean'], 2)
        self.assertEqual(gate['step'], 'test')
        self.assertEqual(gate['storage_retry'], self.state['snapshot_storage'])
        self.assertEqual(len(gate['tests']), 1)
        context = json.JSONDecoder().raw_decode(self.cycle.repair_writer_context().split('Executor assignment:\n', 1)[1])[0]
        self.assertEqual(context['retained_test_results'][0]['tests']['failures'], [obstacle])
        self.assertEqual(context['prior_resolutions'][0]['outcome'], 'deferred')
        self.transport.handlers['repair_execute'] = lambda c, h: self.writer(c)
        self.until(lambda: self.state['phase'] == 'publish')
        self.assertEqual([r for r, c in self.transport.calls].count('repair_self'), 2)
        self.assertEqual(len(gate['tests']), 2)

    def test_storage_repair_retry_is_bounded_and_does_not_accept_failure(self):
        import test_focus_snapshot_archive as archives
        archives.SnapshotArchiveTests.view(self, legacy=True)
        pair = self.assign('final', 'low', False)
        self.set_writer()
        gate = pair['repair']
        self.until(lambda: gate['step'] == 'test')
        self.transport.handlers['repair_execute'] = lambda c, h: self.writer(c, status='infrastructure',
            failures=[dict(finding('workspace-copy'), kind='verification')])
        self.cycle.invoke('repair_execute')
        self.cycle.prepare_snapshot_storage()
        self.step()
        self.assertEqual(gate['step'], 'test')
        with self.assertRaisesRegex(Blocked, 'Targeted check assessment'):
            self.step()
        self.assertEqual(gate['step'], 'test')
        self.assertEqual(gate['clean'], 2)
        self.assertNotIn('repair_seal', pair)

    def test_old_storage_migration_does_not_silently_retry_new_infrastructure_failure(self):
        import test_focus_snapshot_archive as archives
        archives.SnapshotArchiveTests.view(self, legacy=True)
        self.cycle.prepare_snapshot_storage()
        pair = self.assign('final', 'low', False)
        self.set_writer()
        self.until(lambda: pair['repair']['step'] == 'test')
        self.transport.handlers['repair_execute'] = lambda c, h: self.writer(c, status='infrastructure',
            failures=[dict(finding('network'), kind='verification')])
        with self.assertRaisesRegex(Blocked, 'Targeted check assessment'):
            self.step()
        self.assertNotIn('storage_retry', pair['repair'])

    def test_source_test_or_expected_output_edit_revokes_clean_credit(self):
        self.assign("final", "low", False)
        self.until(lambda: self.state["pair_review"]["repair"]["clean"] == 1)
        (self.root / "source.txt").write_text("unexpected concurrent change\n")
        with self.assertRaisesRegex(Blocked, "candidate changed"):
            self.step()
        self.assertFalse(any(c.get("operation") == "test" for r, c in self.transport.calls))

    def test_restart_at_every_state_boundary_does_not_duplicate_credit_or_writers(self):
        self.assign("pair_b", "low", False)
        for _ in range(40):
            if self.state["phase"] == "final":
                break
            self.step()
            self.state = self.store.read()
            self.cycle.state = self.state
        self.assertEqual(self.state["phase"], "final")
        self.assertEqual([r for r, c in self.transport.calls], ["repair_execute", "repair_self", "repair_self", "repair_execute"])

    def test_cumulative_repair_diff_includes_new_deleted_and_mode_changed_paths(self):
        pair = self.assign("pair_b", "low", False)
        self.step()
        (self.root / "new.txt").write_text("new repaired content\n")
        (self.root / "source.txt").unlink()
        pair["repair"]["snapshot"] = self.repo.snapshot()
        reader = self.cycle.repair_reader(pair)
        view = materialize(self.cycle, reader)
        self.assertEqual(set(view["stage_paths"]), {"source.txt", "new.txt"})
        self.assertIn("-changed", view["diffs"]["source.txt"])
        self.assertNotIn("-baseline", view["diffs"]["source.txt"])
        self.assertIn("+new repaired content", view["diffs"]["new.txt"])
        self.assertFalse(any(n.startswith("__review__/") for n in view["files"]))
        tool = ViewInspector(view)
        self.assertFalse(tool.call({"tool": "focus_inspect", "arguments": {"operation": "read", "path": "../state.json", "offset": 0, "limit": 10}})["success"])

    def test_frozen_repair_baseline_cannot_be_modified(self):
        pair = self.assign("final", "low", False)
        self.step()
        base = read_record(self.store, pair["repair"]["base"])
        from pathlib import Path
        (Path(base["root"]) / "source.txt").write_text("tampered")
        with self.assertRaisesRegex(Blocked, "baseline changed"):
            self.step()

    def test_early_checks_and_test_edits_are_rejected_without_credit(self):
        pair = self.assign("final", "low", False)
        self.transport.handlers["repair_execute"] = lambda c, h: self.writer(c, status="passed")
        with self.assertRaises(Blocked):
            self.step()
        self.assertEqual(pair["repair"]["clean"], 0)

    def test_test_invocation_cannot_modify_even_expected_results(self):
        pair = self.assign("pair_b", "low", False)
        execute = self.set_writer()
        def run(c, h):
            value = execute(c, h)
            if c["operation"] == "test":
                (self.root / "expected.txt").write_text("changed golden result")
                value["minor_edits"] = 1
            return value
        self.transport.handlers["repair_execute"] = run
        with self.assertRaisesRegex(Blocked, "Tests changed the candidate"):
            self.until(lambda: self.state["phase"] == "final")
        self.assertNotIn("repair_seal", pair)

    def test_required_verification_waits_for_static_passes_without_deadlock(self):
        pair = self.assign("pair_b", action="verify")
        self.transport.handlers["repair_execute"] = lambda c, h: self.writer(c)
        self.until(lambda: self.state["pair_review"] is None)
        gate = pair["repair"]
        self.assertEqual(gate["clean"], 2)
        self.assertEqual(gate["resolutions"]["assigned"]["outcome"], "verified")
        self.assertEqual([r for r, c in self.transport.calls], ["repair_execute", "repair_self", "repair_self", "repair_execute"])

    def test_no_applicable_tests_requires_evidence_and_cannot_skip_required_diagnostic(self):
        pair = self.assign("pair_b", action="verify")
        self.transport.handlers["repair_execute"] = lambda c, h: self.writer(c, status="not_needed" if c["operation"] == "test" else "deferred")
        with self.assertRaisesRegex(Blocked, "Required diagnostic"):
            self.until(lambda: self.state["pair_review"] is None)
        self.assertNotIn("repair_seal", pair)

    def test_inner_pending_findings_survive_reset_together_with_outer_obligations(self):
        pair = self.assign("final", "low", False)
        self.step()
        self.transport.handlers["repair_self"] = lambda c, h: report(findings=[finding("inner")])
        self.step()
        self.cycle.reset_reviews("Operator correction")
        self.assertEqual({r["id"] for r in self.state["pair_carry"]}, {"guard", "inner"})
        self.assertIsNone(self.state["pair_review"])

    def test_schema_risk_flags_cannot_select_self_and_test_success_requires_evidence(self):
        c = {"operation": "fix", "assignments": []}
        bad = self.writer(c, mode="pair")
        bad["repair"]["mode"] = "self"
        with self.assertRaises(Blocked):
            parse_report(json.dumps(bad), "repair_execute")
        bad = self.writer({"operation": "test", "assignments": []}, status="failed", failures=[finding()])
        bad["repair"]["tests"]["failures"][0]["locations"][0]["path"] = "../outside.txt"
        with self.assertRaises(Blocked):
            parse_report(json.dumps(bad), "repair_execute")

    def test_future_verification_requested_by_inner_reviewer_runs_after_clean_gate(self):
        pair = self.assign("pair_b", "low", False)
        self.set_writer()
        first = [True]
        def scan(c, h):
            result = report(findings=[dict(finding("future-check"), kind="verification", severity="low")] if first[0] else [])
            first[0] = False
            return result
        def discuss(c, h):
            a = c["assignment"]
            return report(assessments=[] if a.get("proposal_hash") else [decision(r, "verify", False) for r in a["registry"]],
                          new_findings=[], consensus=a.get("proposal_hash"), impact="minor")
        self.transport.handlers["repair_self"] = scan
        self.transport.handlers["repair_self_discuss"] = discuss
        self.until(lambda: self.state["phase"] == "final")
        self.assertEqual([r["clean"] for r in pair["repair"]["reviews"]], [True, True])
        contexts = [c for r, c in self.transport.calls if r == "repair_execute"]
        self.assertEqual([c["operation"] for c in contexts], ["fix", "test"])
        self.assertEqual(len(contexts[-1]["assignments"]), 2)

    def test_dismissed_dispute_is_resolved_by_inner_protocol_before_advancing(self):
        pair = self.assign("final", "low", False)
        first = [True]
        def execute(c, h):
            value = self.writer(c)
            if first[0]:
                first[0] = False
                value["resolutions"][0]["outcome"] = "disputed"
            return value
        self.transport.handlers["repair_execute"] = execute
        def reject(c, h):
            a = c["assignment"]
            return report(assessments=[] if a.get("proposal_hash") else [decision(r, "reject", False) for r in a["registry"]],
                          new_findings=[], consensus=a.get("proposal_hash"), impact="minor")
        for role in ("repair_opus_discuss", "repair_astra_discuss"):
            self.transport.handlers[role] = reject
        self.until(lambda: self.state["phase"] == "publish")
        self.assertEqual(pair["repair"]["mode"], "pair")
        self.assertEqual(pair["repair"]["accepted"], [])
        self.assertEqual(pair["repair"]["resolutions"]["assigned"]["outcome"], "verified")

    def test_no_progress_ignores_different_scan_local_ids(self):
        self.assign("pair_b", "low", False)
        self.transport.handlers["repair_execute"] = lambda c, h: self.writer(c)
        self.transport.handlers["repair_self"] = lambda c, h: report(findings=[finding("persistent")])
        with self.assertRaisesRegex(Blocked, "repeated an answered repair"):
            self.until(lambda: self.state["phase"] == "final")
        self.assertNotIn("pair_astra", [r for r, c in self.transport.calls])

    def test_repeated_identical_test_failure_on_unchanged_patch_routes_to_recovery(self):
        pair = self.assign("final", "low", False)
        self.transport.handlers["repair_execute"] = lambda c, h: self.writer(c, status="failed", failures=[finding()]) if c["operation"] == "test" else self.writer(c)
        with self.assertRaisesRegex(Blocked, "tests repeated the same failure"):
            self.until(lambda: self.state["phase"] == "publish")
        self.assertEqual(len(pair["repair"]["tests"]), 2)
        self.assertEqual(pair["repair"]["step"], "fix")
        self.assertEqual(pair["repair"]["clean"], 0)

    def test_seal_rejects_missing_test_and_corrupted_review_artifact(self):
        pair = self.assign("pair_b", "low", False)
        self.until(lambda: pair["repair"]["step"] == "test")
        with self.assertRaisesRegex(Blocked, "invocation is missing"):
            self.cycle.finish_repair(pair)
        self.step()
        artifact_path = self.store.directory / pair["repair"]["reviews"][0]["record"]["path"]
        artifact_path.write_text("tampered")
        with self.assertRaisesRegex(Blocked, "sealed pair artifact"):
            self.step()
        self.assertNotIn("repair_seal", pair)

    def test_risk_found_during_tests_promotes_self_to_pair_before_completion(self):
        pair = self.assign("pair_b", "low", False)
        execute = self.set_writer()
        def run(c, h):
            value = execute(c, h)
            if c["operation"] == "test":
                value["repair"].update(mode="pair", reason="Cross-component risk found", risks=["cross_component"])
            return value
        self.transport.handlers["repair_execute"] = run
        self.until(lambda: self.state["phase"] == "final")
        self.assertEqual([r["mode"] for r in pair["repair"]["reviews"]], ["self", "self", "pair", "pair"])
        self.assertEqual(len(pair["repair"]["tests"]), 2)

    def test_pair_reader_retry_preserves_completed_peer_and_native_state(self):
        pair = self.assign("pair_b", "low", False)
        self.set_writer("pair")
        failed = [False]
        def scan(c, h):
            if not failed[0]:
                failed[0] = True
                raise Blocked("fixture", "Interrupted peer")
            return report(findings=[])
        self.transport.handlers["repair_astra"] = scan
        self.step()
        with self.assertRaises(Blocked):
            self.step()
        reader = pair["repair"]["reader"]
        # Either completion or cancellation is legal; only a completed peer is reused.
        completed = bool(reader["jobs"]["scan/repair_opus"].get("result"))
        before = [r for r, c in self.transport.calls].count("repair_opus")
        self.until(lambda: self.state["phase"] == "final")
        after = [r for r, c in self.transport.calls].count("repair_opus")
        if completed:
            self.assertEqual(after - before, 1)  # Only the second clean pass.

    def test_same_session_native_claude_review_has_no_writing_tools(self):
        import os
        import sys
        from unittest.mock import patch
        from cycle_transport import Transport
        from focus_pair_jobs import run_jobs
        self.assign("final", "low", False)
        self.step()
        native = Transport(self.root, self.state, self.store.save, lambda: None)
        native.commands["claude"] = [sys.executable, str(fixtures.REPO / "tests/test_cycle.py"), "fixture", "claude"]
        self.cycle.transport = native
        pair = self.state["pair_review"]
        reader = self.cycle.repair_reader(pair)
        view = materialize(self.cycle, reader)
        with patch.dict(os.environ, ORCHESTRA_FIXTURE_ROLE="repair_self", ORCHESTRA_FIXTURE_MODEL="opus", ORCHESTRA_FIXTURE_EFFORT="xhigh"):
            values = run_jobs(self.cycle, reader, [("scan/repair_self", "repair_self", "Inspect closure with the bounded reader")], view)
        self.assertEqual(values[0]["findings"], [])
        self.assertEqual(reader["jobs"]["scan/repair_self"]["sessions"]["repair_self"], "executor-session")
        bad = self.writer({"operation": "test", "assignments": []})
        bad["repair"]["tests"]["evidence"] = []
        with self.assertRaises(Blocked):
            parse_report(json.dumps(bad), "repair_execute")

    def test_migration_restarts_unfinished_repairs_but_preserves_started_publication(self):
        self.assign("pair_b", "low", False)
        self.state["review_profile"] = 7
        self.cycle.upgrade_review_profile()
        self.assertEqual(self.state["review_profile"], REVIEW_PROFILE_VERSION)
        self.assertEqual(self.state["phase"], "pair_a")
        self.assertEqual(len(self.state["pair_carry"]), 1)
        self.state.update(review_profile=7, phase="publish", publication_started=True, reviewed=self.repo.snapshot())
        self.cycle.upgrade_review_profile()
        self.assertEqual(self.state["phase"], "publish")
        self.assertEqual(self.state["publication_review_profile"], 7)

    def test_noop_recovery_keeps_inner_credit_on_post_repair_snapshot(self):
        pair = self.assign("pair_b", "low", False)
        self.until(lambda: pair["repair"]["clean"] == 1)
        self.state["blocker"] = {"phase": "pair_b", "status": "healing"}
        self.cycle.transport = fixtures.FixtureTransport(self.root, [("heal", report())])
        self.cycle.heal()
        self.assertIs(self.state["pair_review"], pair)
        self.assertEqual(pair["repair"]["clean"], 1)
        self.assertEqual(self.state["phase"], "pair_b")

    def test_recovery_source_edit_invalidates_inner_and_outer_credit(self):
        pair = self.assign("final", "low", False)
        self.until(lambda: pair["repair"]["clean"] == 1)
        self.state["blocker"] = {"phase": "final", "status": "healing"}
        self.cycle.transport = fixtures.FixtureTransport(self.root, [("heal", self.edit(content="recovery fix", implementation_fixes=1))])
        self.cycle.heal()
        self.assertIsNone(self.state["pair_review"])
        self.assertEqual(self.state["phase"], "pair_a")
        self.assertEqual(len(self.state["pair_carry"]), 1)

    def test_cli_retry_and_new_sessions_include_nested_participants(self):
        import cc_focus
        from unittest.mock import patch
        pair = self.assign("pair_b", "low", False)
        self.step()
        reader = self.cycle.repair_reader(pair)
        reader["jobs"]["scan/repair_self"] = {"id": "reader", "role": "repair_self", "sessions": {"repair_self": "old"},
            "status": "waiting", "retry_at": 9999999999, "turn_id": "old-turn", "transient_retries": 3,
            "report_repairs": 3}
        self.cycle.save()
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.Lease") as lease, patch("cc_focus.Cycle.run", return_value=0):
            lease.return_value.__enter__.return_value.pwsh = "pwsh"
            self.assertEqual(cc_focus.main(["--new-sessions", "--retry"]), 0)
        saved = self.store.read()["pair_review"]["repair"]
        job = saved["reader"]["jobs"]["scan/repair_self"]
        self.assertEqual(job["sessions"], {})
        self.assertNotIn("turn_id", job)
        self.assertLess(job["retry_at"], 9999999999)
        self.assertTrue(saved["reader"]["allow_new_self_session"])
        self.assertEqual(job["transient_retries"], 0)
        self.assertNotIn("report_repairs", job)  # An operator retry gives a new report correction budget.

    def test_panel_explains_mode_progress_and_next_step(self):
        pair = self.assign("pair_b", "low", False)
        self.until(lambda: pair["repair"]["clean"] == 1)
        lines = "\n".join(build_panel(self.state).lines)
        self.assertIn("1/2 чистых", lines)
        self.assertIn("самопроверка Opus/xhigh", lines)
        self.assertIn("далее: следующий этап", lines)


if __name__ == "__main__":
    unittest.main()
