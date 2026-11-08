"""Hermetic paired-review regressions with actual Git snapshots and bounded tools."""

import copy
import json
from pathlib import Path
import threading
import time
import unittest
from unittest.mock import patch

import test_cycle as fixtures
from test_cycle import report
from cycle_state import Blocked, ProviderQuota, ProviderTransient, digest, encode
from cycle_prompts import PROFILES, REVIEW_PROFILE_VERSION
from cycle_transport import parse_report
from focus_pair_profile import PAIRS, PAIR_READONLY, PAIR_WRITERS
from focus_pair_protocol import validate_decisions, assignment_key, validate_complexity
from focus_pair_view import ViewInspector, materialize, read_record
from focus_control import Control, FocusStop, provider_records, kill_provider
from focus_status import build_panel


def finding(identity="guard"):
    return {"id": identity, "title": "Empty input guard", "body": "Empty input reads outside the buffer.",
            "severity": "high", "locations": [{"path": "source.txt", "line": 1}], "kind": "defect"}


def decision(row, action="fix", blocking=True, full_suite=False, severity=None):
    return {"source_id": row["source_id"], **{k: row[k] for k in ("title", "body", "severity", "locations")},
            "severity": severity or row["severity"], "action": action, "duplicate_of": None, "blocking": blocking, "reason": "Checked source and requirement.",
            "repair": "Guard the empty input.", "check": "Test the empty-input path.", "full_suite": full_suite}


def complexity(assignment, effort="xhigh"):
    return {"assignment_sha256": assignment["assignment_sha256"], "effort": effort,
            "reason": "Fixture complexity assessment", "assignments": [
                {"source_id": t["source_id"], "effort": effort, "reason": "Fixture repair difficulty"}
                for t in assignment["tasks"]]}


def repair_metadata(context, mode="self"):
    testing = context["operation"] == "test"
    return {"mode": mode, "reason": "Fixture patch risk", "risks": [], "tests": {
        "status": "passed" if testing else "deferred", "reason": "Scoped fixture check",
        "evidence": ["Fixture targeted check passed"] if testing else [], "failures": []}}


class PairTransport:
    def __init__(self, root):
        self.root, self.calls, self.handlers = root, [], {}
        self.lock = threading.Lock()
        self.interaction = None

    def fork(self, root, state, save, heartbeat, control=None, progress=None):
        parent = self
        class Child:
            def run(self, role, prompt, pending, directory):
                state["sessions"].setdefault(role, pending["id"])
                save(state)
                return parent.dispatch(role, prompt, heartbeat)
        return Child()

    def run(self, role, prompt, pending, directory):
        if role == "repair_execute":
            self.cycle.state["sessions"].setdefault(role, "executor-session")
        return self.dispatch(role, prompt, lambda: None)

    def dispatch(self, role, prompt, heartbeat):
        raw = self.answer(role, prompt, heartbeat)
        context = json.JSONDecoder().raw_decode(prompt.split("assignment:\n", 1)[1])[0]
        if "final_gate" not in context:
            return raw
        # A current initial final scan must report final_gate. Fixtures request no gate by default.
        value = json.loads(raw)
        if not value.pop("omit_final_gate", False):
            value.setdefault("final_gate", {"full_run": False, "reason": "Targeted checks cover the stage changes."})
        return json.dumps(value)

    def answer(self, role, prompt, heartbeat):
        context = json.JSONDecoder().raw_decode(prompt.split("assignment:\n", 1)[1])[0]
        with self.lock:
            self.calls.append((role, context))
            handler = self.handlers.get(role)
        if handler:
            return json.dumps(handler(context, heartbeat))
        if role == "repair_execute":
            testing = context["operation"] == "test"
            if not testing:
                (self.root / "source.txt").write_text("guarded\n")
            return json.dumps(report(implementation_fixes=0 if testing else 1,
                resolutions=[{"source_id": t["source_id"], "outcome": ("verified" if testing else "deferred") if t["action"] == "verify" else "fixed",
                              "resolution": "Scoped repair/check", "evidence": ["Fixture evidence"]} for t in context["assignments"]],
                handoff={"decisions": [], "assumptions": [], "checks": []},
                repair={"mode": "self", "reason": "Local guard", "risks": [],
                        "tests": {"status": "passed" if testing else "deferred", "reason": "Scoped guard check", "evidence": ["Guard passed"] if testing else [], "failures": []}}))
        if role in PAIR_WRITERS:
            tasks = context["assignments"]
            (self.root / "source.txt").write_text("guarded\n")
            return json.dumps(report(implementation_fixes=1,
                resolutions=[{"source_id": t["source_id"], "outcome": "verified" if t["action"] == "verify" else "fixed", "resolution": "Guarded input.", "evidence": ["Focused guard check passed"]} for t in tasks],
                handoff={"decisions": ["Guard empty input."], "assumptions": [], "checks": ["Guard check passed"]}))
        assignment = context["assignment"]
        if role == "pair_complexity":
            return json.dumps(report(complexity=complexity(assignment)))
        if assignment["mode"] == "independent_initial":
            return json.dumps(report(findings=[]))
        if role != "pair_arbiter" and assignment.get("proposal_hash"):
            return json.dumps(report(assessments=[], new_findings=[], consensus=assignment["proposal_hash"], impact="minor"))
        decisions = [decision(r, "reject", False) if r.get("resolution", {}).get("outcome") in ("fixed", "verified") else decision(r)
                     for r in assignment["registry"]]
        return json.dumps(report(assessments=decisions, new_findings=[], consensus=None, impact="minor"))


class PairTests(unittest.TestCase):
    setUp = fixtures.CycleTests.setUp
    tearDown = fixtures.CycleTests.tearDown
    edit = fixtures.CycleTests.edit

    def start(self, phase="pair_a"):
        self.edit()()
        self.cycle.reset_reviews()
        self.state.update(phase=phase, last_snapshot=self.repo.snapshot())
        self.transport = PairTransport(self.root)
        self.cycle.transport = self.transport
        self.transport.cycle = self.cycle

    def until(self, predicate, limit=70):
        for _ in range(limit):
            if predicate():
                return
            self.cycle.paired_review_step()
        self.fail("pair did not converge")

    def test_fixed_profiles(self):
        self.assertEqual(PROFILES["pair_opus_max"], ("claude", "opus", "max"))
        self.assertEqual(PROFILES["pair_arbiter"], ("codex", "gpt-6-astra", "max"))
        self.assertEqual(PROFILES["pair_sol"], ("codex", "gpt-6.1-sol", "xhigh"))
        self.assertEqual(PROFILES["pair_complexity"], ("codex", "gpt-6-sol", "high"))

    def test_current_service_roles_receive_only_the_paired_route(self):
        self.state.update(publication_review_profile=5, review_profile_archive="archived-profile.json",
                          reviewed=self.repo.snapshot(), remote="origin")
        for role in ("code", "coordinate", "heal", "publish"):
            context = self.cycle.context(role)
            self.assertIn('"review_targets": {"pair_a": 1, "pair_b": 1, "final": 1}', context)
            self.assertNotIn('"sol_passes"', context)
            self.assertNotIn("Late Opus permits", context)
            self.assertIn("do not require new-model reviews", context.lower())

    def test_full_clean_route_and_final_independence(self):
        self.start()
        self.until(lambda: self.state["phase"] == "publish")
        roles = [r for r, _ in self.transport.calls]
        for role in (*PAIRS["pair_a"], *PAIRS["pair_b"]):
            self.assertEqual(roles.count(role), 1)
        self.assertEqual(roles[-2:], list(PAIRS["final"]))
        for role, context in self.transport.calls[-2:]:
            self.assertEqual(context["history"], [])
            self.assertEqual(context["assignment"], {"mode": "independent_initial"})
        self.assertEqual(self.state["reviewed"], self.repo.snapshot())
        self.assertEqual(self.state["pair_clean"], {"pair_a": 1, "pair_b": 1})

    def assign(self, phase="pair_a", severity="high", blocking=True, effort="high", action="fix"):
        self.start(phase)
        pair = self.cycle.new_pair()
        row = dict(finding(), source_id="assigned", severity=severity)
        pair.update(step="decide", issues=[row], decisions=[decision(row, action, blocking)], impact="minor")
        self.transport.handlers["pair_complexity"] = lambda c, h: report(complexity=complexity(c["assignment"], effort))
        self.cycle.paired_review_step()
        self.assertEqual(pair["step"], "complexity" if phase == "pair_a" else "repair")
        return pair

    def test_minor_repairs_advance_without_expensive_rescan_after_applicable_gate(self):
        for phase, next_phase in (("pair_a", "pair_b"), ("pair_b", "final"), ("final", "publish")):
            with self.subTest(phase=phase):
                pair = self.assign(phase, "low", False)
                self.until(lambda: self.state["phase"] == next_phase)
                roles = [r for r, c in self.transport.calls]
                if phase == "pair_a":
                    self.assertEqual(roles, ["pair_complexity", "pair_cleanup_high"])
                else:
                    self.assertEqual(roles, ["repair_execute", "repair_self", "repair_self", "repair_execute"])
                    self.assertEqual(pair["repair"]["clean"], 2)
                conclusion = read_record(self.store, self.state["pair_completed"][phase])
                self.assertTrue(conclusion["cleanup_without_rereview"])
                self.assertEqual(conclusion["candidate_after"], digest(encode(self.repo.snapshot())))

    def test_significance_and_repair_complexity_are_independent(self):
        cases = (("medium", False, "high", "fix", True),
                 ("low", True, "high", "fix", True),
                 ("low", False, "xhigh", "cleanup", False))
        for severity, blocking, effort, kind, repeats in cases:
            with self.subTest(severity=severity, blocking=blocking, effort=effort):
                pair = self.assign(severity=severity, blocking=blocking, effort=effort)
                self.cycle.paired_review_step()
                self.assertEqual(pair["step"], kind)
                role = "pair_" + kind + ("_high" if effort == "high" else "")
                self.assertEqual(pair["executor_role"], role)
                self.cycle.paired_review_step()
                self.assertEqual(self.state["phase"], "pair_a" if repeats else "pair_b")
                self.assertIsNone(self.state["pair_review"])
                if repeats:
                    self.assertEqual(len(self.state["pair_carry"]), 1)
                    self.until(lambda: self.state["phase"] == "pair_b")
                    self.assertEqual([r for r, c in self.transport.calls].count("pair_opus"), 1)

    def test_complexity_and_chosen_effort_survive_restart_without_reassessment(self):
        pair = self.assign(effort="high")
        self.cycle.paired_review_step()
        saved_assessment = copy.deepcopy(pair["assessment"])
        self.state = self.store.read()
        self.cycle.state = self.state
        self.cycle.paired_review_step()
        self.assertEqual([r for r, c in self.transport.calls], ["pair_complexity", "pair_fix_high"])
        context = self.transport.calls[-1][1]
        self.assertEqual(context["complexity"], read_record(self.store, saved_assessment)["complexity"])

    def test_complexity_rejects_stale_incomplete_duplicate_and_underestimated_batches(self):
        pair = self.assign()
        pair["tasks"].append(dict(pair["tasks"][0], source_id="second"))
        base = complexity({"assignment_sha256": assignment_key(pair["snapshot"], pair["tasks"]), "tasks": pair["tasks"]})
        validate_complexity(base, pair["snapshot"], pair["tasks"])
        variants = []
        bad = copy.deepcopy(base); bad["assignment_sha256"] = "stale"; variants.append(bad)
        bad = copy.deepcopy(base); bad["assignments"].pop(); variants.append(bad)
        bad = copy.deepcopy(base); bad["assignments"][1]["source_id"] = "assigned"; variants.append(bad)
        bad = copy.deepcopy(base); bad["effort"] = "high"; variants.append(bad)
        for bad in variants:
            with self.subTest(bad=bad), self.assertRaises(Blocked):
                validate_complexity(bad, pair["snapshot"], pair["tasks"])
        for field, value in (("body", "Changed assignment"), ("severity", "low"), ("check", "Different verification")):
            changed = copy.deepcopy(pair["tasks"]); changed[0][field] = value
            with self.assertRaises(Blocked):
                validate_complexity(base, pair["snapshot"], changed)

    def test_invalid_complexity_gets_author_correction_before_writer(self):
        pair = self.assign()
        calls = [0]
        def assessor(c, h):
            calls[0] += 1
            value = complexity(c["assignment"], "high")
            if calls[0] == 1:
                value["assignments"] = [dict(value["assignments"][0], source_id="wrong")]
            return report(complexity=value)
        self.transport.handlers["pair_complexity"] = assessor
        self.cycle.paired_review_step()
        self.assertEqual(pair["step"], "complexity")
        self.cycle.paired_review_step()
        self.assertEqual(pair["executor_role"], "pair_fix_high")
        self.assertEqual([r for r, c in self.transport.calls], ["pair_complexity", "pair_complexity"])

    def test_assessor_is_readonly_and_executor_pin_cannot_be_changed(self):
        pair = self.assign()
        value = complexity({"assignment_sha256": assignment_key(pair["snapshot"], pair["tasks"]), "tasks": pair["tasks"]})
        with self.assertRaises(Blocked):
            parse_report(json.dumps(report(complexity=value, implementation_fixes=1)), "pair_complexity")
        self.cycle.paired_review_step()
        pair["executor_role"] = "pair_fix"  # assessment selected high
        with self.assertRaisesRegex(Blocked, "pinned executor"):
            self.cycle.paired_review_step()

    def test_substantial_minor_cleanup_requires_same_pair_inspection(self):
        pair = self.assign(severity="low", blocking=False)
        self.cycle.paired_review_step()
        def fix(c, h):
            (self.root / "source.txt").write_text("contract changed\n")
            return report(implementation_fixes=1, substantial=True,
                resolutions=[{"source_id": "assigned", "outcome": "fixed", "resolution": "Changed contract", "evidence": ["Contract check passed"]}],
                handoff={"decisions": [], "checks": [], "assumptions": []})
        self.transport.handlers["pair_cleanup_high"] = fix
        self.cycle.paired_review_step()
        self.assertEqual(self.state["phase"], "pair_a")
        self.assertNotIn("pair_a", self.state["pair_completed"])
        self.until(lambda: self.state["phase"] == "pair_b")
        self.assertEqual([r for r, c in self.transport.calls].count("pair_opus"), 1)

    def test_disputed_minor_fix_goes_to_autonomous_arbitration(self):
        pair = self.assign(severity="low", blocking=False)
        self.cycle.paired_review_step()
        self.transport.handlers["pair_cleanup_high"] = lambda c, h: report(
            resolutions=[{"source_id": "assigned", "outcome": "disputed", "resolution": "Requirement contradicts finding", "evidence": ["Source contract"]}],
            handoff={"decisions": [], "checks": [], "assumptions": []})
        self.cycle.paired_review_step()
        self.assertEqual(pair["step"], "arbitrate")
        self.transport.handlers["pair_arbiter"] = lambda c, h: report(
            assessments=[decision(r, "reject", False) for r in c["assignment"]["registry"]],
            new_findings=[], consensus=None, impact="minor")
        self.until(lambda: self.state["phase"] == "pair_b")
        self.assertEqual([r for r, c in self.transport.calls].count("pair_arbiter"), 1)

    def disputed_arbitration(self):
        pair = self.assign(severity="low", blocking=False)
        self.cycle.paired_review_step()
        self.transport.handlers["pair_cleanup_high"] = lambda c, h: report(
            resolutions=[{"source_id": "assigned", "outcome": "disputed", "resolution": "Requirement contradicts finding", "evidence": ["Source contract"]}],
            handoff={"decisions": [], "checks": [], "assumptions": []})
        self.cycle.paired_review_step()
        self.assertEqual(pair["step"], "arbitrate")
        return pair

    def test_new_arbiter_findings_join_the_registry_and_a_second_arbitration_decides_them(self):
        pair = self.disputed_arbitration()
        contexts = []
        def arbiter(c, h):
            contexts.append(c["assignment"])
            new = [finding("arbiter-new")] if len(contexts) == 1 else []
            return report(assessments=[decision(r, "reject", False) for r in c["assignment"]["registry"]],
                          new_findings=new, consensus=None, impact="minor")
        self.transport.handlers["pair_arbiter"] = arbiter
        self.until(lambda: self.state["phase"] == "pair_b")
        self.assertEqual(len(contexts), 2)
        added = pair["id"] + "/pair_arbiter/arbitrate-1/arbiter-new"
        self.assertNotIn(added, [r["source_id"] for r in contexts[0]["registry"]])
        self.assertIn(added, [r["source_id"] for r in contexts[1]["registry"]])
        # A saved first arbitration keeps its prompt. Only the second one gets the closing rule.
        self.assertEqual(contexts[0]["rule"], 'Make binding decisions. Disagreement is not an operator blocker. Do not repeat '
                         'an answered diagnostic without new evidence. For a closed defect, explicitly return reject with proof of closure.')
        self.assertIn("The previous arbitration added findings to the registry.", contexts[1]["rule"])
        self.assertIn(added, [r["source_id"] for r in pair["decisions"]])

    def test_an_arbiter_report_refused_by_an_older_runtime_is_registered_after_retry(self):
        import focus_pair_protocol
        from unittest.mock import patch
        pair = self.disputed_arbitration()
        # Like the live job: an earlier ruling of this pair makes the refused job arbitrate/2.
        pair["rulings"] = [report(assessments=[], new_findings=[], consensus=None, impact="minor")]
        contexts = []
        def arbiter(c, h):
            contexts.append(c["assignment"])
            new = [] if any(r["source_id"].endswith("/arbiter-new") for r in c["assignment"]["registry"]) else [finding("arbiter-new")]
            return report(assessments=[decision(r, "reject", False) for r in c["assignment"]["registry"]],
                          new_findings=new, consensus=None, impact="minor")
        self.transport.handlers["pair_arbiter"] = arbiter
        current = focus_pair_protocol.validate_report
        def older(report, role):
            if role == "pair_arbiter" and report["new_findings"]:
                raise ValueError("arbiter must decide the complete supplied registry")
            return current(report, role)
        with patch("focus_pair_protocol.validate_report", older), self.assertRaises(Blocked):
            self.until(lambda: self.state["phase"] == "pair_b")
        self.assertEqual(len(contexts), 3)  # The report and two corrections, all refused.
        self.assertEqual(pair["jobs"]["arbitrate/2"]["report_error"], focus_pair_protocol.LEGACY_ARBITER_ERROR)
        # The operator retries with the new runtime. cc_focus gives the reader a new correction budget.
        for job in pair["jobs"].values():
            if not job.get("result"):
                job.pop("report_repairs", None)
        self.state.update(blocker=None, status="ready")
        self.until(lambda: self.state["phase"] == "pair_b")
        # The saved report is accepted without a provider call. Only the extended arbitration runs.
        self.assertEqual(len(contexts), 4)
        self.assertEqual(pair["arbiter_extension"], 2)
        self.assertIn(pair["id"] + "/pair_arbiter/arbitrate-2/arbiter-new", [r["source_id"] for r in contexts[3]["registry"]])
        self.assertIn("The previous arbitration added findings to the registry.", contexts[3]["rule"])

    def test_an_incomplete_refused_arbiter_report_gets_a_current_correction_text(self):
        import focus_pair_protocol
        from unittest.mock import patch
        pair = self.disputed_arbitration()
        prompts = []
        dispatch = self.transport.dispatch
        def record(role, prompt, heartbeat):
            if role == "pair_arbiter":
                prompts.append(prompt)
            return dispatch(role, prompt, heartbeat)
        self.transport.dispatch = record
        def arbiter(c, h):
            registry = c["assignment"]["registry"]
            if any(r["source_id"].endswith("/arbiter-new") for r in registry):
                return report(assessments=[decision(r, "reject", False) for r in registry], new_findings=[], consensus=None, impact="minor")
            # Before the retry, the report also has no evidence.
            return report(assessments=[decision(r, "reject", False) for r in registry], new_findings=[finding("arbiter-new")],
                          consensus=None, impact="minor", evidence=[] if len(prompts) <= 3 else ["Registry decided"])
        self.transport.handlers["pair_arbiter"] = arbiter
        current = focus_pair_protocol.validate_report
        def older(report, role):
            if role == "pair_arbiter" and report["new_findings"]:
                raise ValueError("arbiter must decide the complete supplied registry")
            return current(report, role)
        with patch("focus_pair_protocol.validate_report", older), self.assertRaises(Blocked):
            self.until(lambda: self.state["phase"] == "pair_b")
        for job in pair["jobs"].values():
            if not job.get("result"):
                job.pop("report_repairs", None)
        self.state.update(blocker=None, status="ready")
        self.until(lambda: self.state["phase"] == "pair_b")
        # The incomplete report is not accepted. Its correction names the current problem, not the old parser error.
        self.assertIn("Complete the arbitration. Return status=done with evidence.", prompts[3])
        self.assertNotIn(focus_pair_protocol.LEGACY_ARBITER_ERROR, prompts[3])
        self.assertEqual((len(prompts), pair["arbiter_extension"]), (5, 1))

    def test_a_second_arbitration_cannot_add_findings_again(self):
        self.disputed_arbitration()
        self.transport.handlers["pair_arbiter"] = lambda c, h: report(
            assessments=[decision(r, "reject", False) for r in c["assignment"]["registry"]],
            new_findings=[finding("again-" + str(len(c["assignment"]["registry"])))], consensus=None, impact="minor")
        with self.assertRaisesRegex(Blocked, "already added findings"):
            self.until(lambda: self.state["phase"] == "pair_b")
        self.assertEqual([r for r, c in self.transport.calls].count("pair_arbiter"), 4)  # One extension, then three refused reports.

    def test_partial_progress_allows_same_assignment_on_new_candidate(self):
        pair = self.assign()
        self.cycle.paired_review_step()
        def partial(c, h):
            (self.root / "source.txt").write_text("partial progress\n")
            return report(implementation_fixes=1,
                resolutions=[{"source_id": "assigned", "outcome": "disputed", "resolution": "Needs remainder", "evidence": ["Partial repair"]}],
                handoff={"decisions": [], "checks": [], "assumptions": []})
        self.transport.handlers["pair_fix_high"] = partial
        self.cycle.paired_review_step()
        self.cycle.paired_review_step()  # Binding arbiter retains the same task on the new candidate.
        self.cycle.paired_review_step()
        self.assertEqual(pair["step"], "complexity")
        self.assertEqual(len(pair["executed_assignments"]), 2)
        self.cycle.paired_review_step()
        self.assertEqual([r for r, c in self.transport.calls].count("pair_complexity"), 2)
        self.assertEqual(pair["executor_role"], "pair_fix_high")

    def test_unchanged_repeated_assignment_still_rejects_no_progress(self):
        pair = self.assign()
        self.cycle.paired_review_step()
        self.transport.handlers["pair_fix_high"] = lambda c, h: report(
            resolutions=[{"source_id": "assigned", "outcome": "disputed", "resolution": "No evidence", "evidence": ["Unchanged source"]}],
            handoff={"decisions": [], "checks": [], "assumptions": []})
        self.cycle.paired_review_step()
        self.cycle.paired_review_step()
        with self.assertRaisesRegex(Blocked, "without new evidence"):
            self.cycle.paired_review_step()

    def test_status_exposes_assessment_then_chosen_executor_effort(self):
        from focus_control import status
        pair = self.assign()
        self.assertIn("оценка сложности gpt-6-sol/high", "\n".join(build_panel(self.state).lines))
        self.cycle.paired_review_step()
        self.assertIn("исправления Opus/high", "\n".join(build_panel(self.state).lines))
        self.assertEqual(status(self.store, self.state)["pair_review"]["executor_role"], "pair_fix_high")

    def test_significant_findings_cannot_escape_through_deferral(self):
        row = dict(finding(), source_id="one")
        with self.assertRaisesRegex(Blocked, "cannot be deferred"):
            validate_decisions([row], [decision(row, "defer", False)], "pair_a")

    def test_duplicate_cannot_hide_significance_in_minor_or_deferred_target(self):
        rows = [dict(finding(), source_id="original"), dict(finding(), source_id="duplicate")]
        duplicate = dict(decision(rows[1], "duplicate", False), duplicate_of="original")
        for action in ("fix", "defer"):
            target = decision(rows[0], action, False, severity="low")
            with self.subTest(action=action), self.assertRaisesRegex(Blocked, "retain significance"):
                validate_decisions(rows, [target, duplicate], "pair_a")
        validate_decisions(rows, [decision(rows[0], "fix", False), duplicate], "pair_a")

    def test_profile_six_migration_preserves_carried_findings_and_started_publication(self):
        self.start("pair_b")
        pair = self.cycle.new_pair()
        pair["scans"]["pair_astra"] = report(findings=[finding()])
        before = self.repo.snapshot()
        self.state.update(review_profile=6)
        self.cycle.upgrade_review_profile()
        self.assertEqual(self.state["review_profile"], REVIEW_PROFILE_VERSION)
        self.assertEqual(self.state["phase"], "pair_a")
        self.assertEqual(self.state["pair_carry"][0]["id"], "guard")
        self.assertEqual(self.repo.snapshot(), before)
        self.state.update(review_profile=6, phase="publish", publication_started=True, reviewed=before)
        self.cycle.upgrade_review_profile()
        self.assertEqual(self.state["phase"], "publish")
        self.assertEqual(self.state["publication_review_profile"], 6)
        self.assertEqual(self.state["reviewed"], before)

    def test_initial_peers_really_overlap_and_source_is_unchanged(self):
        self.start()
        barrier = threading.Barrier(2)
        original = self.repo.snapshot()
        def reader(context, heartbeat):
            barrier.wait(timeout=5)
            return report(findings=[])
        self.transport.handlers = {role: reader for role in PAIRS["pair_a"]}
        self.cycle.paired_review_step()
        self.assertEqual(self.repo.snapshot(), original)
        self.assertEqual(len(self.state["pair_review"]["scans"]), 2)

    def test_completed_peer_survives_failed_peer_and_restart(self):
        self.start()
        self.state["task"] = {"title": "Current stage", "plan": "PLAN.md", "id": "stage", "iteration": 1}
        def failed(context, heartbeat):
            time.sleep(.15)
            raise Blocked("fixture-provider", "Interrupted peer")
        self.transport.handlers["pair_sol"] = failed
        with self.assertRaisesRegex(Blocked, "Interrupted peer"):
            self.cycle.paired_review_step()
        self.state = self.store.read()
        self.cycle.state = self.state
        self.transport.handlers.clear()
        self.cycle.paired_review_step()
        roles = [r for r, _ in self.transport.calls]
        self.assertEqual(roles.count("pair_opus"), 1)
        self.assertEqual(roles.count("pair_sol"), 2)

    def test_discussion_restart_keeps_assignment_and_current_participant_status(self):
        self.start("final")
        self.transport.handlers["pair_final_opus"] = lambda c, h: report(findings=[finding()])
        self.until(lambda: self.state["pair_review"]["step"] == "discuss" if self.state.get("pair_review") else False)
        def failed(c, h):
            time.sleep(.15)
            raise Blocked("fixture-provider", "Interrupted discussion")
        self.transport.handlers["pair_final_fable_discuss"] = failed
        with self.assertRaisesRegex(Blocked, "Interrupted discussion"):
            self.cycle.paired_review_step()
        self.state = self.store.read()  # Persisted objects reorder their JSON keys.
        self.cycle.state = self.state
        self.assertIn("claude-fable-5-1/xhigh: прерван", "\n".join(build_panel(self.state).lines))
        self.transport.handlers.pop("pair_final_fable_discuss")
        self.cycle.paired_review_step()
        self.assertEqual(self.state["pair_review"]["discussion"], 1)
        self.assertEqual([r for r, _ in self.transport.calls].count("pair_final_opus_discuss"), 1)

    def test_two_exchanges_then_binding_arbiter(self):
        self.start("final")
        self.transport.handlers["pair_final_opus"] = lambda c, h: report(findings=[finding()])
        def dissent(c, h):
            return report(assessments=[decision(r, "reject", False) for r in c["assignment"]["registry"]],
                          new_findings=[], consensus=None, impact="minor")
        self.transport.handlers["pair_final_fable_discuss"] = dissent
        self.transport.handlers["pair_arbiter"] = dissent
        self.until(lambda: self.state["phase"] == "publish")
        roles = [r for r, _ in self.transport.calls]
        self.assertEqual(roles.count("pair_final_fable_discuss"), 2)
        self.assertEqual(roles.count("pair_arbiter"), 1)
        self.assertNotIn("pair_fix", roles)

    def test_findings_cannot_be_silently_omitted(self):
        row = dict(finding(), source_id="a")
        with self.assertRaisesRegex(Blocked, "Every finding"):
            validate_decisions([row], [], "pair_a")
        with self.assertRaisesRegex(Blocked, "Only a Pair B fix or verify assignment"):
            validate_decisions([row], [decision(row, full_suite=True)], "pair_a")
        validate_decisions([row], [decision(row, full_suite=True)], "pair_b")

    def test_final_nonblockers_are_fixed_without_rereview(self):
        self.start("final")
        self.transport.handlers["pair_final_opus"] = lambda c, h: report(findings=[finding()])
        def nonblocking(c, h):
            a = c["assignment"]
            return report(assessments=[] if a.get("proposal_hash") else [decision(r, blocking=False, severity="low") for r in a["registry"]],
                          new_findings=[], consensus=a.get("proposal_hash"), impact="minor")
        for role in PAIRS["final"]:
            self.transport.handlers[role + "_discuss"] = nonblocking
        self.until(lambda: self.state["phase"] == "publish")
        roles = [r for r, _ in self.transport.calls]
        self.assertEqual(roles.count("pair_final_opus"), 1)
        self.assertEqual(roles[-1], "repair_execute")
        self.assertEqual((self.root / "source.txt").read_text(), "guarded\n")

    def test_blocker_fix_is_carried_only_after_both_new_initial_reports(self):
        self.start("final")
        calls = 0
        def first(c, h):
            nonlocal calls
            calls += 1
            return report(findings=[finding()] if calls == 1 else [])
        self.transport.handlers["pair_final_opus"] = first
        self.until(lambda: self.state["phase"] == "publish")
        roles = [r for r, _ in self.transport.calls]
        self.assertEqual(roles.count("pair_final_opus"), 2)
        self.assertEqual(roles.count("repair_execute"), 2)
        for role, context in self.transport.calls:
            if role in PAIRS["final"]:
                self.assertNotIn("registry", context["assignment"])
                self.assertEqual(context["history"], [])
        carried = [c["assignment"]["registry"] for r, c in self.transport.calls if r.endswith("_discuss")]
        self.assertTrue(any(rows[0].get("resolution") for rows in carried))

    def test_substantial_b_fix_repeats_b_without_return_to_a(self):
        self.start("pair_b")
        once = [False]
        def first(c, h):
            if once[0]:
                return report(findings=[])
            once[0] = True
            return report(findings=[finding()])
        self.transport.handlers["pair_astra"] = first
        def fix(c, h):
            testing = c["operation"] == "test"
            if not testing:
                (self.root / "source.txt").write_text("substantial\n")
            return report(implementation_fixes=0 if testing else 1, substantial=not testing, repair=repair_metadata(c, "pair"),
                          resolutions=[{"source_id": t["source_id"], "outcome": "fixed", "resolution": "Fixed", "evidence": ["Test passed"]} for t in c["assignments"]],
                          handoff={"decisions": [], "assumptions": [], "checks": ["Test passed"]})
        self.transport.handlers["repair_execute"] = fix
        self.until(lambda: self.state["phase"] == "final")
        roles = [r for r, _ in self.transport.calls]
        self.assertEqual(roles.count("pair_astra"), 2)
        self.assertEqual(roles.count("pair_opus"), 0)
        self.assertEqual(self.state["pair_clean"], {"pair_a": 0, "pair_b": 1})

    def test_source_drift_does_not_credit_a_pair(self):
        self.start()
        self.transport.handlers["pair_sol"] = lambda c, h: self.edit(content="unexpected concurrent edit\n", findings=[])()
        with self.assertRaisesRegex(Blocked, "changed during"):
            self.cycle.paired_review_step()
        self.assertEqual(self.state["pair_clean"]["pair_a"], 0)

    def test_bounded_view_denies_runtime_parent_and_changed_source(self):
        self.start("final")
        pair = self.cycle.new_pair()
        view = materialize(self.cycle, pair)
        reader = ViewInspector(view)
        def read(name):
            return reader.call({"tool": "focus_inspect", "arguments": {"operation": "read", "path": name, "offset": 0, "limit": 20}})
        self.assertTrue(read("source.txt")["success"])
        self.assertFalse(read("../state.json")["success"])
        self.assertFalse(read(".work/cycle/state.json")["success"])
        (Path(view["root"]) / "source.txt").write_text("tampered\n")
        self.assertFalse(read("source.txt")["success"])

    def test_freezing_rejects_transient_source_bytes_even_if_checkout_is_restored(self):
        self.start()
        pair = self.cycle.new_pair()
        original = Path.read_bytes
        def transient(path):
            return b"temporary mutation\n" if path == self.root / "source.txt" else original(path)
        with patch.object(Path, "read_bytes", transient):
            with self.assertRaisesRegex(Blocked, "copying frozen"):
                materialize(self.cycle, pair)
        self.assertEqual(self.repo.snapshot(), pair["snapshot"])
        self.assertFalse(pair.get("view"))

    def test_readonly_schema_rejects_edits_and_bad_endorsement(self):
        with self.assertRaisesRegex(Blocked, "inspectors"):
            parse_report(json.dumps(report(findings=[], minor_edits=1)), "pair_sol")
        with self.assertRaisesRegex(Blocked, "endorsement"):
            parse_report(json.dumps(report(assessments=[], new_findings=[finding()], consensus="a" * 64, impact="minor")), "pair_sol_discuss")
        # The arbiter keeps its own rule: it decides the registry and never endorses.
        with self.assertRaisesRegex(Blocked, "arbiter cannot endorse"):
            parse_report(json.dumps(report(assessments=[], new_findings=[], consensus="Binding ruling", impact="minor")), "pair_arbiter")
        # A new arbiter finding parses. The arbitration step adds it to the registry.
        parse_report(json.dumps(report(assessments=[], new_findings=[finding()], consensus=None, impact="minor")), "pair_arbiter")
        # A prose endorsement still parses. The discussion step rejects it after both readers finish,
        # so a slow peer keeps its completed report.
        parse_report(json.dumps(report(assessments=[], new_findings=[], consensus="Endorse " + "a" * 64,
                                       impact="minor")), "pair_sol_discuss")

    def test_only_discussion_roles_get_the_consensus_format_rule(self):
        from cycle_prompts import DISCUSSION_CONSENSUS_CONTRACT, PAIR_CONTRACT, PROFILES, role_contract
        from focus_pair_profile import PAIR_DISCUSSERS
        for role in PROFILES:
            with self.subTest(role=role):
                self.assertEqual(DISCUSSION_CONSENSUS_CONTRACT in role_contract(role), role in PAIR_DISCUSSERS)
        # Saved discussion prompts embed PAIR_CONTRACT, so in-flight jobs keep their exact prompt.
        self.assertNotIn(DISCUSSION_CONSENSUS_CONTRACT, PAIR_CONTRACT)
        # A dissenting reader keeps its own impact. Only an endorsement copies the proposal impact.
        self.assertIn("For an endorsement, set impact to the impact of the supplied proposal.", DISCUSSION_CONSENSUS_CONTRACT)
        self.assertIn("If the assignment has no proposal_hash, set consensus to null.", DISCUSSION_CONSENSUS_CONTRACT)

    def test_a_repeated_prose_endorsement_keeps_the_peer_report(self):
        self.start("final")
        self.transport.handlers["pair_final_opus"] = lambda c, h: report(findings=[finding()])
        first, peer = PAIRS["final"]
        def assess(c, h):
            a = c["assignment"]
            if a.get("proposal_hash"):
                for _ in range(20):  # The peer is still running while the other reader fails.
                    time.sleep(0.05)
                    h()  # A cancelled peer stops here and loses its report.
                return report(assessments=[], new_findings=[], consensus=a["proposal_hash"], impact="minor")
            return report(assessments=[decision(r, blocking=False, severity="low") for r in a["registry"]],
                          new_findings=[], consensus=None, impact="minor")
        def prose(c, h):
            a = c["assignment"]
            if a.get("proposal_hash"):
                return report(assessments=[], new_findings=[], consensus="Endorse " + a["proposal_hash"], impact="minor")
            return assess(c, h)
        self.transport.handlers[first + "_discuss"] = prose
        self.transport.handlers[peer + "_discuss"] = assess
        with self.assertRaises(Blocked) as caught:
            self.until(lambda: self.state["phase"] == "publish")
        jobs = self.state["pair_review"]["jobs"]
        turn = self.state["pair_review"]["discussion"] + 1
        self.assertIn("result", jobs[f"discuss/{turn}/{peer}"])  # The peer's completed report is kept.
        self.assertNotIn("result", jobs[f"discuss/{turn}/{first}"])
        self.assertEqual(caught.exception.code, "pair-report")

    def test_an_old_endorsement_error_is_sent_with_exact_values(self):
        from focus_pair_protocol import LEGACY_CONSENSUS_ERROR
        self.start("final")
        self.transport.handlers["pair_final_opus"] = lambda c, h: report(findings=[finding()])
        first, peer = PAIRS["final"]
        prompts, endorsed = [], []
        def endorse(c, h, prose=False):
            a = c["assignment"]
            if not a.get("proposal_hash"):
                return report(assessments=[decision(r, blocking=False, severity="low") for r in a["registry"]],
                              new_findings=[], consensus=None, impact="minor")
            value = a["proposal_hash"]
            if prose and not endorsed:
                endorsed.append(True)
                value = "Endorse " + value
            return report(assessments=[], new_findings=[], consensus=value, impact="minor")
        self.transport.handlers[first + "_discuss"] = lambda c, h: endorse(c, h, prose=True)
        self.transport.handlers[peer + "_discuss"] = endorse
        dispatch = self.transport.dispatch
        def record(role, prompt, heartbeat):
            prompts.append(prompt)
            return dispatch(role, prompt, heartbeat)
        self.transport.dispatch = record
        self.until(lambda: any(j.get("report_error") for j in (self.state["pair_review"] or {}).get("jobs", {}).values()))
        rejected = next(j for j in self.state["pair_review"]["jobs"].values() if j.get("report_error"))
        rejected["report_error"] = LEGACY_CONSENSUS_ERROR  # Saved by an older runtime. No --retry runs.
        self.cycle.save()
        self.until(lambda: self.state["phase"] == "publish")
        correction = next(p for p in prompts if "Correct the prior report" in p)
        self.assertNotIn(LEGACY_CONSENSUS_ERROR, correction)
        key = json.loads(correction.split("assignment:\n", 1)[1].split("\n", 1)[0])["assignment"]["proposal_hash"]
        self.assertIn('An endorsement must set consensus to exactly "' + key + '" with no other text. '
                      'Its impact must be "minor".', correction)

    def test_an_endorsement_without_a_proposal_is_told_to_disagree(self):
        self.start("final")
        self.transport.handlers["pair_final_opus"] = lambda c, h: report(findings=[finding()])
        prompts, first, lock = [], [], threading.Lock()
        def endorse(c, h):
            a = c["assignment"]
            with lock:  # Both discussion readers run at the same time.
                copy_digest = not a.get("proposal_hash") and not first
                if copy_digest:
                    first.append(True)
            if copy_digest:  # Exchange 1 has no proposal. This reader copies another 64-character digest.
                return report(assessments=[], new_findings=[], consensus="0" * 64, impact="minor")
            if not a.get("proposal_hash"):
                return report(assessments=[decision(r, blocking=False, severity="low") for r in a["registry"]],
                              new_findings=[], consensus=None, impact="minor")
            return report(assessments=[], new_findings=[], consensus=a["proposal_hash"], impact="minor")
        for role in PAIRS["final"]:
            self.transport.handlers[role + "_discuss"] = endorse
        dispatch = self.transport.dispatch
        def record(role, prompt, heartbeat):
            prompts.append(prompt)
            return dispatch(role, prompt, heartbeat)
        self.transport.dispatch = record
        self.until(lambda: self.state["phase"] == "publish")
        correction = next(p for p in prompts if "Correct the prior report" in p)
        self.assertIn("No proposal is supplied in this exchange. Set consensus to null.", correction)
        self.assertNotIn("consensus to exactly null", correction)

    def test_a_prose_endorsement_gets_a_precise_correction(self):
        self.start("final")
        self.transport.handlers["pair_final_opus"] = lambda c, h: report(findings=[finding()])
        endorsements, prompts, lock = [], [], threading.Lock()
        def endorse(c, h):
            a = c["assignment"]
            if not a.get("proposal_hash"):
                return report(assessments=[decision(r, blocking=False, severity="low") for r in a["registry"]],
                              new_findings=[], consensus=None, impact="minor")
            with lock:  # Both discussion readers run at the same time.
                endorsements.append(a["proposal_hash"])
                count = len(endorsements)
            # The first endorsement wraps the hash in prose. The second one names another proposal.
            # The third one copies the hash but not the minor impact of the proposal.
            value = {1: "Endorse proposal_hash=" + a["proposal_hash"], 2: "0" * 64}.get(count, a["proposal_hash"])
            return report(assessments=[], new_findings=[], consensus=value, impact="substantial" if count == 3 else "minor")
        for role in PAIRS["final"]:
            self.transport.handlers[role + "_discuss"] = endorse
        dispatch = self.transport.dispatch
        def record(role, prompt, heartbeat):
            if role.endswith("_discuss"):
                prompts.append(prompt)
            return dispatch(role, prompt, heartbeat)
        self.transport.dispatch = record
        self.until(lambda: self.state["phase"] == "publish")
        corrections = [p for p in prompts if "Correct the prior report" in p]
        self.assertEqual(len(corrections), 3)  # The prose endorsement, the wrong hash and the wrong impact.
        self.assertTrue(all("consensus to exactly " + json.dumps(endorsements[0]) in p for p in corrections))
        self.assertTrue(all('Its impact must be "minor".' in p for p in corrections))  # The proposal impact.

    def test_unsafe_peer_exit_takes_priority_over_other_provider_failure(self):
        self.start()
        barrier = threading.Barrier(2)
        def fail(c, h):
            barrier.wait(timeout=5)
            raise Blocked("provider-eof", "Ordinary provider failure")
        def unsafe(c, h):
            barrier.wait(timeout=5)
            while True:
                try:
                    h()
                except FocusStop:
                    raise Blocked("cleanup-incomplete", "Peer containment did not confirm exit")
                time.sleep(.01)
        self.transport.handlers.update(pair_opus=fail, pair_sol=unsafe)
        with self.assertRaises(Blocked) as caught:
            self.cycle.paired_review_step()
        self.assertEqual(caught.exception.code, "cleanup-incomplete")
        self.assertIsNone(self.state["reviewed"])

    def test_quota_wait_retries_only_unfinished_peer(self):
        self.start()
        calls = [0]
        def quota(c, h):
            calls[0] += 1
            if calls[0] == 1:
                raise ProviderQuota(time.time() + 3600, no_work=True)
            return report(findings=[])
        self.transport.handlers["pair_sol"] = quota
        def tick():
            for job in (self.state.get("pair_review") or {}).get("jobs", {}).values():
                if job.get("status") == "waiting":
                    job["retry_at"] = 0  # Explicit resume after an account switch.
        self.cycle.heartbeat = tick
        self.cycle.paired_review_step()
        roles = [r for r, _ in self.transport.calls]
        self.assertEqual(roles.count("pair_sol"), 2)
        self.assertEqual(roles.count("pair_opus"), 1)

    def test_a_stop_takes_effect_while_a_participant_waits_for_quota(self):
        import cc_focus
        for mode in ("safe", "now"):
            with self.subTest(mode=mode):
                self.start()
                self.transport.handlers["pair_sol"] = lambda c, h: (_ for _ in ()).throw(ProviderQuota(time.time() + 3600, no_work=True))
                class Control:
                    requested = None
                    def request(self):
                        return self.requested
                    def poll(self):
                        if self.requested and self.requested["mode"] == "now":
                            raise FocusStop("Emergency stop requested by the operator.")
                    def child(self, slot, cwd=None):
                        return None
                control = Control()
                self.cycle.control = control
                def tick():
                    jobs = (self.state.get("pair_review") or {}).get("jobs", {})
                    if any(job.get("status") == "waiting" for job in jobs.values()):
                        control.requested = {"mode": mode}  # The operator stops during the wait.
                self.cycle.heartbeat = tick
                started = time.monotonic()
                if mode == "safe":
                    self.cycle.paired_review_step()
                else:
                    with self.assertRaises(FocusStop):
                        self.cycle.paired_review_step()
                self.assertLess(time.monotonic() - started, 30)
                jobs = self.state["pair_review"]["jobs"]
                # The completed peer and the saved deadline stay. /resume retries the wait at once.
                self.assertTrue(jobs["scan/pair_opus"].get("result"))
                self.assertEqual((jobs["scan/pair_sol"]["status"], jobs["scan/pair_sol"]["wait_reason"]), ("waiting", "claude-quota"))
                self.assertGreater(jobs["scan/pair_sol"]["retry_at"], time.time() + 3000)
                self.assertTrue(cc_focus.resume_retries(self.state))
                self.cycle.control = None
        self.assertFalse(cc_focus.resume_retries({"pair_review": {"jobs": {"scan/x": {"status": "waiting", "wait_reason": "codex-transient"}}}}))

    def test_a_codex_reader_server_error_retries_only_that_reader(self):
        self.start()
        failures = [1]
        def overloaded(c, h):
            if failures[0]:
                failures[0] -= 1
                raise ProviderTransient("serverOverloaded", "Selected model is at capacity.", no_work=True, provider="codex")
            return report(findings=[])
        self.transport.handlers["pair_sol"] = overloaded
        waits = []
        def tick():
            for job in (self.state.get("pair_review") or {}).get("jobs", {}).values():
                if job.get("status") == "waiting" and job.get("wait_reason"):
                    waits.append((job["role"], job["wait_reason"], job["transient_retries"]))
                    job["retry_at"] = 0  # Skip the delay.
        self.cycle.heartbeat = tick
        self.cycle.paired_review_step()
        roles = [r for r, _ in self.transport.calls]
        self.assertEqual((roles.count("pair_sol"), roles.count("pair_opus")), (2, 1))
        self.assertEqual(set(waits), {("pair_sol", "codex-transient", 1)})

    def test_a_codex_reader_that_stays_overloaded_stops_after_three_retries_and_names_the_participant(self):
        for retry in ("cc-focus --retry", "cc-focus review --resume abc123 --retry"):
            with self.subTest(retry=retry):
                self.tearDown()
                self.setUp()
                # A review run gives its own command. Pair review runs need a review cycle fixture.
                with patch.object(self.cycle, "retry_command", return_value=retry):
                    self.stay_overloaded(retry)

    def stay_overloaded(self, retry):
        self.start()
        def overloaded(c, h):
            raise ProviderTransient("serverOverloaded", "Selected model is at capacity.", no_work=True, provider="codex")
        self.transport.handlers["pair_sol"] = overloaded
        def tick():
            for job in (self.state.get("pair_review") or {}).get("jobs", {}).values():
                if job.get("status") == "waiting":
                    job["retry_at"] = 0  # Skip the delay.
        self.cycle.heartbeat = tick
        with self.assertRaises(Blocked) as caught:
            self.cycle.paired_review_step()
        # A ProviderTransient would get three more retries from Cycle.run.
        self.assertIs(type(caught.exception), Blocked)
        self.assertEqual(caught.exception.code, "codex-transient")
        self.assertIn("The runtime used all 3 retries of this pair participant.", str(caught.exception))
        self.assertIn("The invocation of participant pair_sol holds the server failure. "
                      f"Operator: wait until the provider is available. Then run {retry}.", str(caught.exception))
        roles = [r for r, _ in self.transport.calls]
        self.assertEqual((roles.count("pair_sol"), roles.count("pair_opus")), (4, 1))

    def test_a_provider_response_gives_a_report_correction_new_server_error_retries(self):
        self.start()
        steps = ["overloaded"] * 3 + ["invalid", "overloaded", "valid"]
        def answer(c, h):
            step = steps.pop(0)
            if step == "overloaded":
                raise ProviderTransient("serverOverloaded", "Selected model is at capacity.", no_work=True, provider="codex")
            return {"status": "done"} if step == "invalid" else report(findings=[])
        self.transport.handlers["pair_sol"] = answer
        waits = []
        def tick():
            for job in (self.state.get("pair_review") or {}).get("jobs", {}).values():
                if job.get("status") == "waiting":
                    if not waits or waits[-1] != job["transient_retries"]:
                        waits.append(job["transient_retries"])
                    job["retry_at"] = 0  # Skip the delay.
        self.cycle.heartbeat = tick
        self.cycle.paired_review_step()
        self.assertEqual(steps, [])
        self.assertEqual(waits, [1, 2, 3, 1])
        job = next(job for job in self.state["pair_review"]["jobs"].values() if job["role"] == "pair_sol")
        self.assertEqual((job["status"], job["report_repairs"]), ("done", 1))

    def test_operator_instructions_keep_chronological_precedence(self):
        self.start()
        for role, text in (("code", "Use the old contract"), ("pair_group", "Use the corrected contract")):
            record = self.cycle.messages.add({"iteration": 1, "invocation": role, "role": role}, text)
            self.cycle.messages.update(record, "accepted")
            if role == "pair_group":
                self.state["pair_instructions"] = [{"id": record["identity"]["id"], "text": text}]
        self.assertEqual([r["text"] for r in self.cycle.pair_operator_instructions()],
                         ["Use the old contract", "Use the corrected contract"])

    def test_pair_instruction_cancels_both_and_restarts_with_shared_context(self):
        self.start()
        self.state["pair_carry"] = [dict(finding(), source_id="prior/guard")]
        class Interaction:
            def begin(_, pending):
                self.cycle.messages.add({"iteration": 1, "invocation": pending["id"], "role": "pair_group"}, "Require empty-input behavior.")
            def close_target(_):
                pass
        self.transport.interaction = Interaction()
        self.cycle.paired_review_step()
        self.assertEqual(self.transport.calls, [])
        self.assertIsNone(self.state["pending"])
        self.assertIsNone(self.state["pair_review"])
        self.assertEqual([r["source_id"] for r in self.state["pair_carry"]], ["prior/guard"])
        self.transport.interaction = None
        self.cycle.paired_review_step()
        self.assertEqual(len(self.transport.calls), 2)
        for _, context in self.transport.calls:
            self.assertEqual(context["operator_instructions"][0]["text"], "Require empty-input behavior.")
        self.assertEqual(self.cycle.messages.unresolved(1), [])

    def test_restart_retains_obligations_before_final_peer_finishes(self):
        self.start("final")
        self.state["pair_carry"] = [dict(finding(), source_id="prior/guard")]
        self.transport.handlers["pair_final_opus"] = lambda c, h: report(findings=[finding("new")])
        self.cycle.paired_review_step()
        self.assertEqual(self.state["pair_review"]["issues"], [])
        self.cycle.reset_reviews("New operator requirements")
        self.assertEqual({r["id"] for r in self.state["pair_carry"]}, {"guard", "new"})
        self.assertEqual(self.state["phase"], "pair_a")

    def test_diagnostic_executes_once_then_pair_checks_evidence(self):
        self.start("pair_b")
        first = [True]
        def scan(c, h):
            result = report(findings=[finding()] if first[0] else [])
            first[0] = False
            return result
        self.transport.handlers["pair_astra"] = scan
        def discuss(c, h):
            a = c["assignment"]
            rows = [decision(r, "reject", False) if r.get("resolution") else decision(r, "verify", full_suite=True)
                    for r in a["registry"]]
            return report(assessments=[] if a.get("proposal_hash") else rows,
                          new_findings=[], consensus=a.get("proposal_hash"), impact="minor")
        for role in PAIRS["pair_b"]:
            self.transport.handlers[role + "_discuss"] = discuss
        def verify(c, h):
            self.assertTrue(c["assignments"][0]["full_suite"])
            return report(repair=repair_metadata(c), resolutions=[{"source_id": t["source_id"], "outcome": "verified" if c["operation"] == "test" else "deferred", "resolution": "Broad diagnostic passed", "evidence": ["Fixture suite 8/8 passed"]} for t in c["assignments"]],
                          handoff={"decisions": [], "assumptions": [], "checks": ["8/8 passed"]})
        self.transport.handlers["repair_execute"] = verify
        self.until(lambda: self.state["phase"] == "final")
        roles = [r for r, _ in self.transport.calls]
        self.assertEqual(roles.count("repair_execute"), 2)
        self.assertEqual(roles.count("pair_astra"), 2)
        self.assertEqual((self.root / "source.txt").read_text(), "changed\n")

    def test_writer_operator_input_invalidates_final_cleanup_seal(self):
        self.start("final")
        self.transport.handlers["pair_final_opus"] = lambda c, h: report(findings=[finding()])
        def nonblocking(c, h):
            a = c["assignment"]
            return report(assessments=[] if a.get("proposal_hash") else [decision(r, blocking=False, severity="low") for r in a["registry"]],
                          new_findings=[], consensus=a.get("proposal_hash"), impact="minor")
        for role in PAIRS["final"]:
            self.transport.handlers[role + "_discuss"] = nonblocking
        def cleanup(c, h):
            self.state["pending"]["restart_reviews"] = True
            (self.root / "source.txt").write_text("operator correction\n")
            return report(implementation_fixes=1, repair=repair_metadata(c),
                resolutions=[{"source_id": t["source_id"], "outcome": "fixed", "resolution": "Corrected", "evidence": ["Scoped check passed"]} for t in c["assignments"]],
                handoff={"decisions": [], "assumptions": [], "checks": []})
        self.transport.handlers["repair_execute"] = cleanup
        self.until(lambda: self.state["phase"] == "pair_a")
        self.assertIsNone(self.state["reviewed"])
        self.assertEqual(len(self.state["pair_carry"]), 1)

    def test_profile_five_migration_carries_open_final_obligations(self):
        self.state.update(review_profile=5, phase="final", final_review={"confirmed": [decision(dict(finding(), source_id="old"))]})
        self.cycle.upgrade_review_profile()
        self.assertEqual(self.state["phase"], "pair_a")
        self.assertEqual(self.state["pair_carry"][0]["source_id"], "legacy/old")

    def test_mcp_exposes_only_manifest_inspection(self):
        import subprocess, sys
        self.start("final")
        pair = self.cycle.new_pair()
        materialize(self.cycle, pair)
        requests = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
                    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "inspect", "arguments": {"operation": "read", "path": "source.txt", "offset": 0, "limit": 20}}},
                    {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "shell", "arguments": {}}}]
        result = subprocess.run([sys.executable, str(fixtures.REPO / "tools/focus_pair_view.py"), str(self.store.directory / pair["view"]["path"])],
                                input="\n".join(json.dumps(r) for r in requests) + "\n", capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        replies = [json.loads(line)["result"] for line in result.stdout.splitlines()]
        self.assertEqual([r["name"] for r in replies[1]["tools"]], ["inspect"])
        self.assertFalse(replies[2]["isError"])
        self.assertTrue(replies[3]["isError"])

    def test_panel_shows_both_participants_and_exit_condition(self):
        self.start()
        self.cycle.paired_review_step()
        panel = "\n".join(build_panel(self.state).lines)
        self.assertIn("gpt-6.1-sol/xhigh", panel)
        self.assertIn("opus/xhigh", panel)
        self.assertIn("A: до устранения значимых", panel)

    def test_native_codex_report_repair_uses_new_marker_in_the_same_session(self):
        import os, sys
        from cycle_transport import Transport
        from focus_pair_jobs import run_jobs
        self.start()
        (self.root / "source.txt").write_text("initial\n")
        self.state["last_snapshot"] = self.repo.snapshot()
        native = Transport(self.root, self.state, self.store.save, lambda: None)
        native.commands["codex"] = [sys.executable, str(fixtures.REPO / "tests/test_cycle.py"), "fixture", "codex", "paired-report-once"]
        self.cycle.transport = native
        pair = self.cycle.new_pair()
        view = materialize(self.cycle, pair)
        with patch.dict(os.environ, ORCHESTRA_FIXTURE_ROLE="pair_sol"):
            reports = run_jobs(self.cycle, pair, [("scan/pair_sol", "pair_sol", "Review this candidate")], view)
        self.assertEqual(reports[0]["status"], "done")
        job = pair["jobs"]["scan/pair_sol"]
        self.assertEqual(job["report_repairs"], 1)
        self.assertNotEqual(job["native_id"], job["id"])
        self.assertTrue(job["sessions"]["pair_sol"])
        rejected = read_record(self.store, job["report_source"])
        self.assertNotIn("findings", json.loads(rejected["raw"]))
        correction_prompt = (self.store.directory / "invocations" / job["id"] / "prompt.txt").read_text()
        self.assertIn("Previous public report to correct:", correction_prompt)
        self.assertIn(json.dumps(rejected, ensure_ascii=False), correction_prompt)

    def test_saved_pair_job_survives_only_the_known_instruction_revision(self):
        from cycle_prompts import PAIR_CONTRACT
        from focus_pair_jobs import run_jobs
        self.start()
        pair = self.cycle.new_pair()
        view = materialize(self.cycle, pair)
        previous = json.loads((fixtures.REPO / "tests/fixtures/focus_v8_instruction_style.json").read_text())
        context = {"candidate": "same-candidate", "assignment": {"mode": "independent_initial"}}
        old_context = copy.deepcopy(context)
        for row in previous["changes"]:
            if row["path"] == ["inspection"]:
                old_context["inspection"], context["inspection"] = row["old"], row["new"]
        marker = "\nRuntime assignment:\n"
        saved = previous["pair_contract"] + marker + json.dumps(old_context)
        current = PAIR_CONTRACT + marker + json.dumps(context)
        key, role = "scan/pair_sol", "pair_sol"
        pair["jobs"] = {key: {"id": "saved-participant", "role": role, "prompt": saved,
                             "sessions": {role: "saved-session"}, "status": "ready", "attempts": 0}}

        reports = run_jobs(self.cycle, pair, [(key, role, current)], view)
        self.assertEqual(reports[0]["status"], "done")
        job = pair["jobs"][key]
        self.assertEqual(job["prompt"], saved)
        self.assertEqual(job["sessions"][role], "saved-session")
        self.assertEqual(self.transport.calls, [(role, old_context)])
        self.assertEqual(run_jobs(self.cycle, pair, [(key, role, current)], view), reports)
        self.assertEqual(len(self.transport.calls), 1)
        changed = PAIR_CONTRACT + marker + json.dumps(dict(context, candidate="different-candidate"))
        with self.assertRaises(Blocked) as caught:
            run_jobs(self.cycle, pair, [(key, role, changed)], view)
        self.assertEqual(caught.exception.code, "pair-intent")
        self.assertEqual(job["prompt"], saved)
        self.assertEqual(len(self.transport.calls), 1)

    def test_saved_pair_job_from_before_the_test_scope_rules_continues(self):
        from cycle_prompts import PAIR_CONTRACT
        from focus_pair_jobs import same_pair_prompt
        from focus_review_contract import review_contract
        saved_contracts = json.loads((fixtures.REPO / "tests/fixtures/focus_test_scope_contract.json").read_text())
        previous = saved_contracts["pair_contract"]
        marker = "\nRuntime assignment:\n"
        old = {"candidate": "same-candidate", "assignment": {"mode": "independent_initial"}}
        new = dict(old, full_run={"available": True, "rule": "One full run."},
                   final_gate={"full_runs": [], "rule": "Request the gate."})
        for scoped in (False, True):
            with self.subTest(scoped=scoped):
                # The review-mode form of the saved job used the earlier review contract too.
                with patch("focus_review_contract.CONTRACT", saved_contracts["review_contract"]):
                    saved = review_contract(previous, scoped) + marker + json.dumps(old)
                current = review_contract(PAIR_CONTRACT, scoped) + marker + json.dumps(new)
                self.assertTrue(same_pair_prompt(saved, current))
                # The other form of the contract, or other task data, is another assignment.
                self.assertFalse(same_pair_prompt(saved, review_contract(PAIR_CONTRACT, not scoped) + marker + json.dumps(new)))
                self.assertFalse(same_pair_prompt(saved, review_contract(PAIR_CONTRACT, scoped) + marker
                                                  + json.dumps(dict(new, candidate="different-candidate"))))
        # A saved job that has a new field keeps its exact value.
        saved = previous + marker + json.dumps(dict(old, full_run={"available": False, "rule": "One full run."}))
        self.assertFalse(same_pair_prompt(saved, PAIR_CONTRACT + marker + json.dumps(new)))
        # The current contract accepts no field difference.
        self.assertFalse(same_pair_prompt(PAIR_CONTRACT + marker + json.dumps(old), PAIR_CONTRACT + marker + json.dumps(new)))

    def test_pair_b_permits_one_full_run_in_each_stage(self):
        row = dict(finding(), source_id="a")
        validate_decisions([row], [decision(row, full_suite=False)], "pair_b", full_run_used=True)
        with self.assertRaisesRegex(Blocked, "one full run"):
            validate_decisions([row], [decision(row, "verify", full_suite=True)], "pair_b", full_run_used=True)
        self.start("pair_b")
        self.assertFalse(self.cycle.full_run_used("pair_b"))
        self.state["pair_full_runs"] = [{"phase": "final", "record": None, "candidate": "c", "status": "passed"}]
        self.assertFalse(self.cycle.full_run_used("pair_b"))
        self.state["pair_full_runs"].append({"phase": "pair_b", "record": None, "candidate": "c", "status": "failed"})
        self.assertTrue(self.cycle.full_run_used("pair_b"))
        # The final gate has its own limit of one run in each stage.
        self.assertTrue(self.cycle.full_run_used("final"))
        self.state["pair_full_runs"] = self.state["pair_full_runs"][1:]
        self.assertFalse(self.cycle.full_run_used("final"))
        self.assertFalse(self.cycle.full_run_used("pair_a"))

    def test_only_final_inspectors_report_the_final_gate(self):
        from focus_review import report_schema
        for role in PAIRS["final"]:
            self.assertIn("final_gate", report_schema(role)["required"])
        for role in (*PAIRS["pair_a"], *PAIRS["pair_b"], "pair_final_opus_discuss", "repair_self", "pair_arbiter"):
            self.assertNotIn("final_gate", report_schema(role)["properties"])
        gate = {"full_run": True, "reason": "The build configuration changed."}
        self.assertEqual(parse_report(json.dumps(report(findings=[], final_gate=gate)), "pair_final_fable")["final_gate"], gate)
        # A report saved before this field requests no gate.
        self.assertNotIn("final_gate", parse_report(json.dumps(report(findings=[])), "pair_final_opus"))
        for value in ({"full_run": "yes", "reason": "Shared code."}, {"full_run": True, "reason": ""}, {"full_run": True}):
            with self.assertRaises(Blocked):
                parse_report(json.dumps(report(findings=[], final_gate=value)), "pair_final_opus")
        with self.assertRaises(Blocked):
            parse_report(json.dumps(report(findings=[], final_gate=gate)), "pair_opus")

    def test_completed_codex_blocker_retries_inspection_in_the_same_session(self):
        import os, sys
        from cycle_transport import Transport
        from focus_pair_jobs import run_jobs
        for legacy in (False, True):
            with self.subTest(legacy=legacy):
                self.start()
                (self.root / "source.txt").write_text("initial\n")
                self.state["last_snapshot"] = self.repo.snapshot()
                native = Transport(self.root, self.state, self.store.save, lambda: None)
                native.commands["codex"] = [sys.executable, str(fixtures.REPO / "tests/test_cycle.py"), "fixture", "codex", "paired-blocked-once"]
                self.cycle.transport = native
                pair = self.cycle.new_pair()
                view = materialize(self.cycle, pair)
                requests = [("scan/pair_sol", "pair_sol", "Review this candidate")]
                with patch.dict(os.environ, ORCHESTRA_FIXTURE_ROLE="pair_sol"):
                    with self.assertRaises(Blocked) as blocked:
                        run_jobs(self.cycle, pair, requests, view)
                    self.assertEqual(blocked.exception.code, "pair-incomplete")
                    job = pair["jobs"]["scan/pair_sol"]
                    session = job["sessions"]["pair_sol"]
                    directory = self.store.directory / "invocations" / job["id"]
                    response = directory / "response.json"
                    rejected = read_record(self.store, job["incomplete_report"])
                    if legacy:
                        # Before this fix a completed refusal retained the old
                        # native marker and turn, plus an unbound response file.
                        job.pop("native_id")
                        job.pop("report_repair")
                        job.pop("incomplete_report")
                        job["turn_id"] = "finished-turn"
                        response.write_text(json.dumps({"raw": rejected["raw"]}))
                    self.assertFalse(job.get("result"))
                    reports = run_jobs(self.cycle, pair, requests, view)
                self.assertEqual(reports[0]["status"], "done")
                self.assertEqual(job["sessions"]["pair_sol"], session)
                self.assertNotEqual(job["native_id"], job["id"])
                archived = read_record(self.store, job["incomplete_report"])
                self.assertEqual(json.loads(archived["raw"])["status"], "blocked")
                if not legacy:
                    self.assertEqual(archived, rejected)
                prompt = (directory / "prompt.txt").read_text()
                self.assertIn("review in full", prompt)
                self.assertNotIn("This invocation is REPORT-ONLY CORRECTION", prompt)
                self.assertFalse(job.get("report_repair"))

    def test_stale_response_cannot_invalidate_an_active_native_turn(self):
        import os, sys
        from cycle_transport import Transport
        from focus_pair_jobs import run_jobs
        self.start()
        (self.root / "source.txt").write_text("initial\n")
        self.state["last_snapshot"] = self.repo.snapshot()
        native = Transport(self.root, self.state, self.store.save, lambda: None)
        native.commands["codex"] = [sys.executable, str(fixtures.REPO / "tests/test_cycle.py"), "fixture", "codex", "paired-blocked-once"]
        self.cycle.transport = native
        pair = self.cycle.new_pair()
        view = materialize(self.cycle, pair)
        requests = [("scan/pair_sol", "pair_sol", "Review this candidate")]
        with patch.dict(os.environ, ORCHESTRA_FIXTURE_ROLE="pair_sol"):
            with self.assertRaises(Blocked):
                run_jobs(self.cycle, pair, requests, view)
            job = pair["jobs"]["scan/pair_sol"]
            response = self.store.directory / "invocations" / job["id"] / "response.json"
            stale = json.loads(response.read_text())
            stale.pop("native_id")
            response.write_text(json.dumps(stale))
            job.pop("native_id")
            job["turn_id"] = "finished-turn"
            archived = copy.deepcopy(job["incomplete_report"])
            native.commands["codex"].append("paired-active")
            with self.assertRaises(Blocked) as blocked:
                run_jobs(self.cycle, pair, requests, view)
        self.assertEqual(blocked.exception.code, "turn-active")
        self.assertNotIn("native_id", job)
        self.assertEqual(job["turn_id"], "finished-turn")
        self.assertEqual(job["incomplete_report"], archived)
        self.assertFalse(job.get("result"))

    def test_codex_readonly_rejects_command_and_file_approval(self):
        from unittest.mock import Mock
        from cycle_transport import Rpc
        for method in ("item/commandExecution/requestApproval", "item/fileChange/requestApproval"):
            process = Mock()
            process.receive.return_value = {"id": "forbidden", "method": method, "params": {}}
            with self.assertRaises(Blocked) as blocked:
                Rpc(process, inspector=Mock()).event()
            self.assertEqual(blocked.exception.code, "readonly-tool")
            process.send.assert_not_called()

    def test_report_format_repair_reuses_completed_peer_without_crediting_extra_pass(self):
        self.start()
        calls = [0]
        def incomplete(c, h):
            calls[0] += 1
            return report() if calls[0] == 1 else report(findings=[])
        self.transport.handlers["pair_sol"] = incomplete
        self.cycle.paired_review_step()
        self.cycle.paired_review_step()
        self.assertEqual([r for r, _ in self.transport.calls].count("pair_opus"), 1)
        self.assertEqual(calls[0], 2)
        self.assertEqual(self.state["pair_clean"]["pair_a"], 1)

    def test_incomplete_disposition_repairs_only_its_author_report(self):
        self.start()
        self.transport.handlers["pair_opus"] = lambda c, h: report(findings=[finding()])
        calls = [0]
        def incomplete(c, h):
            calls[0] += 1
            a = c["assignment"]
            return report(assessments=[decision(r) for r in a["registry"]] if calls[0] == 2 else [],
                          new_findings=[], consensus=a.get("proposal_hash"), impact="minor")
        self.transport.handlers["pair_sol_discuss"] = incomplete
        self.until(lambda: (self.state.get("pair_review") or {}).get("step") == "decide")
        self.assertEqual(calls[0], 3)
        self.assertEqual([r for r, _ in self.transport.calls].count("pair_opus_discuss"), 2)
        pair = self.state["pair_review"]
        rejected = pair["jobs"]["discuss/1/pair_sol"]["rejected_reports"]
        self.assertEqual(len(rejected), 1)
        self.assertEqual(read_record(self.store, rejected[0])["assessments"], [])
        self.assertEqual(self.state["pair_clean"]["pair_a"], 0)

    def test_disputed_partial_fix_returns_to_arbiter_on_new_snapshot_before_rescan(self):
        self.start()
        self.transport.handlers["pair_opus"] = lambda c, h: report(findings=[finding()])
        def partial(c, h):
            (self.root / "source.txt").write_text("partial guard\n")
            return report(implementation_fixes=1, resolutions=[{"source_id": t["source_id"], "outcome": "disputed", "resolution": "Partial fix revealed a different contract", "evidence": ["New contract evidence"]} for t in c["assignments"]],
                          handoff={"decisions": [], "assumptions": [], "checks": []})
        self.transport.handlers["pair_fix"] = partial
        def arbitrate(c, h):
            self.assertTrue(c["assignment"]["fresh_inspection_required"])
            self.assertNotEqual(c["assignment"]["reports_candidate"], c["candidate"])
            return report(assessments=[decision(r, "reject", False) for r in c["assignment"]["registry"]],
                          new_findings=[], consensus=None, impact="minor")
        self.transport.handlers["pair_arbiter"] = arbitrate
        self.until(lambda: any(r == "pair_arbiter" for r, _ in self.transport.calls))
        self.cycle.paired_review_step()
        self.assertIsNone(self.state["pair_review"])
        self.assertEqual([r for r, _ in self.transport.calls].count("pair_opus"), 1)
        self.assertEqual(self.state["pair_clean"]["pair_a"], 0)
        self.assertTrue(self.state["pair_carry"])

    def test_executor_cannot_stage_reviewed_source(self):
        self.start("final")
        pair = self.cycle.new_pair()
        row = dict(finding(), source_id="one")
        pair.update(step="decide", issues=[row], decisions=[decision(row, blocking=False, severity="low")], impact="minor")
        self.cycle.paired_review_step()
        def stage(c, h):
            self.repo.git("add", "source.txt")
            return report(repair=repair_metadata(c), resolutions=[{"source_id": "one", "outcome": "fixed", "resolution": "Claimed closure", "evidence": ["Fixture"]}],
                          handoff={"decisions": [], "assumptions": [], "checks": []})
        self.transport.handlers["repair_execute"] = stage
        with self.assertRaises(Blocked) as caught:
            self.cycle.paired_review_step()
        self.assertEqual(caught.exception.code, "unauthorized-staging")
        self.assertIsNone(self.state["reviewed"])

    def test_process_cleanup_uses_leaf_address_and_preserves_live_peer(self):
        import sys
        from cycle_transport import Process
        control = Control(self.store)
        with patch.dict('os.environ', {"ORCHESTRA_PROCESSKIT_ROOT_RUN_ID": "orchestra-focus-" + "a" * 32,
                                     "ORCHESTRA_FOCUS_PROCESSKIT_CLI": str(self.root / "processkit") }):
            control.begin()
        leaves = [control.child("a"), control.child("b")]
        processes = []
        for i, leaf in enumerate(leaves):
            leaf.prepare_provider(self.root / f"leaf-{i}.jsonl")
            process = Process([sys.executable, "-c", "import time; time.sleep(60)"], self.root,
                              self.root / f"process-{i}.jsonl", lambda: None)
            process.control, process.contained = leaf, True
            processes.append(process)
        ids = {provider_records(leaf.active)[0]["processkit_run_id"]: process for leaf, process in zip(leaves, processes)}
        def kill(store, active, timeout=5):
            records = provider_records(active)
            self.assertEqual(len(records), 1)
            ids[records[0]["processkit_run_id"]].proc.terminate()
            return True
        try:
            with patch("focus_control.kill_provider", side_effect=kill):
                try:
                    raise FocusStop("cancel first participant")
                except FocusStop:
                    processes[0].close()
                self.assertIsNone(processes[1].proc.poll())
                self.assertEqual(len(provider_records(control.active)), 1)
                try:
                    raise FocusStop("cancel remaining participant")
                except FocusStop:
                    processes[1].close()
                self.assertEqual(provider_records(control.active), [])
        finally:
            for process in processes:
                if process.proc.poll() is None:
                    process.proc.kill()
                    process.proc.wait(timeout=5)

    def test_control_keeps_both_leaf_identities(self):
        control = Control(self.store)
        with patch.dict('os.environ', {"ORCHESTRA_PROCESSKIT_ROOT_RUN_ID": "orchestra-focus-" + "a" * 32,
                                     "ORCHESTRA_FOCUS_PROCESSKIT_CLI": str(self.root / "processkit") }):
            control.begin()
        a, b = control.child("a", self.root / "snapshot"), control.child("b")
        command = a.prepare_provider(self.root / "a.jsonl")
        self.assertEqual(command[command.index("--cwd") + 1], str(self.root / "snapshot"))
        b.prepare_provider(self.root / "b.jsonl")
        self.assertEqual(len(provider_records(control.active)), 2)
        own_id = provider_records(a.active)[0]["processkit_run_id"]
        peer_id = provider_records(b.active)[0]["processkit_run_id"]
        with patch("focus_control.command") as command, patch("focus_control.wait_container"):
            self.assertTrue(kill_provider(a.store, a.active))
            self.assertIn(own_id, command.call_args.args[0])
            self.assertNotIn(peer_id, command.call_args.args[0])
        a.clear_provider()
        self.assertEqual(len(provider_records(control.active)), 1)
        b.clear_provider()
        self.assertEqual(provider_records(control.active), [])


if __name__ == "__main__":
    unittest.main()
