"""Late repair gates use real Git snapshots and hermetic provider sessions."""

import copy
import json
import unittest
from unittest.mock import patch
from pathlib import Path

import test_cycle as fixtures
from test_cycle import report
import test_focus_pairs as pairs
from test_focus_pairs import finding, decision
from cycle_state import Blocked, digest, encode
from cycle_prompts import PROFILES, REVIEW_PROFILE_VERSION
from cycle_transport import parse_report
from focus_pair_profile import PAIR_READONLY
from focus_pair_view import artifact, materialize, read_record, ViewInspector
from focus_snapshot_archive import read_source
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
                # The seal keeps the inner review rounds of its gate and names the outer pair round separately.
                self.assertEqual((seal["round"], seal["phase"], seal["pair_round"]),
                                 (pair["repair"]["round"], pair["phase"], pair["round"]))
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
        self.assertEqual(set(view["diffs"]), {"source.txt", "new.txt"})
        tool = ViewInspector(view)
        self.assertFalse(tool.call({"tool": "focus_inspect", "arguments": {"operation": "read", "path": "../state.json", "offset": 0, "limit": 10}})["success"])

    def test_inner_repair_view_exposes_the_evidence_of_its_outer_phase(self):
        for phase in ("pair_b", "final"):
            with self.subTest(phase=phase):
                pair = self.assign(phase, "low", False)
                record = lambda name, value: artifact(self.store, f"evidence-{phase}/{name}.json", value)
                fix = record("execution-0", {"operation": "fix", "report": {"summary": "Fixed"}})
                test = record("execution-1", {"operation": "test", "report": {"summary": "Seven methods passed"}})
                frozen = {"path": f"evidence-{phase}/view-0/view.json", "sha256": "0" * 64}
                review = record("review-1", {"decisions": [], "view": frozen,
                                             "sources": [record("report", {"summary": "Inner pass clean"})]})
                approval = record("approval", {"audit": record("audit", {"verdict": "evidence_only"}),
                                               "receipt": record("receipt", {"report": {"summary": "Journal updated"}})})
                lost = {"path": f"evidence-{phase}/lost.json", "sha256": "0" * 64}
                seal = record("seal", {"executions": [fix, test], "tests": [test], "choices": [{"mode": "self", "report": fix}],
                                       "reviews": [{"record": review}], "evidence_changes": [approval], "test_view": frozen,
                                       "lost": lost, "snapshot": {"files": {f"file-{n}.txt": "f:" + "0" * 64 for n in range(2000)}}})
                self.state["pair_handoff"] = [seal, record("conclusion", {"repair_gate": seal, "sources": []})]
                # A long coding account stays one JSON line in its copy.
                self.state["code_report"] = "A" * 120000 + " TAIL-OF-ACCOUNT"
                self.step()
                reader = self.cycle.repair_reader(pair)
                view = materialize(self.cycle, reader)
                tool = ViewInspector(view)
                def read(name):
                    return tool.call({"tool": "focus_inspect", "arguments": {"operation": "read", "path": name, "offset": 0, "limit": 500}})
                self.assertTrue(read(view["publication"])["success"])
                manifest = json.loads(read_source(view, view["publication"]))
                self.assertEqual(manifest["paths"], self.cycle.publication_paths())
                self.assertEqual(manifest["candidate"], digest(encode(reader["snapshot"])))
                context = json.JSONDecoder().raw_decode(self.cycle.pair_prompt(reader, "repair_opus", {}).split("assignment:\n", 1)[1])[0]
                self.assertEqual(context["publication_manifest"], "__review__/publication.json")
                names = [n for n in view["files"] if n.startswith("__review__/")]
                # The open gate's own fix record is readable in both phases.
                gate = json.loads(read_source(view, "__review__/gate.json"))
                self.assertEqual({k: v for k, v in gate["executions"][0].items() if k != "exposed"}, pair["repair"]["executions"][0])
                self.assertEqual(json.loads(read_source(view, gate["executions"][0]["exposed"]))["operation"], "fix")
                if phase == "final":
                    self.assertEqual(set(names), {"__review__/publication.json", "__review__/gate.json", "__review__/gate-record-0.json"})
                    self.assertEqual(set(context["history"]), {"__review__/gate.json", "__review__/gate-record-0.json"})
                    continue
                # A long evidence line is shown in parts; following the page notices yields every character.
                labels, parts = self.read_pages(tool, "__review__/coding-full.json")
                self.assertIn("A" * 120000 + " TAIL-OF-ACCOUNT", "".join(parts))
                self.assertTrue(any(" part " in label for label in labels))
                def follow(reference):
                    self.assertIn(reference["exposed"], context["history"])
                    self.assertTrue(read(reference["exposed"])["success"])
                    return json.loads(read_source(view, reference["exposed"]))
                history = json.loads(read_source(view, "__review__/history-0.json"))
                # Each reference keeps its runtime path and names one readable copy.
                self.assertEqual({k: v for k, v in history["tests"][0].items() if k != "exposed"}, test)
                self.assertEqual(follow(history["tests"][0])["report"]["summary"], "Seven methods passed")
                self.assertEqual(history["tests"][0]["exposed"], history["executions"][1]["exposed"])
                self.assertEqual(history["choices"][0]["report"]["exposed"], history["executions"][0]["exposed"])
                self.assertEqual(follow(history["executions"][0])["report"]["summary"], "Fixed")
                inner = follow(history["reviews"][0]["record"])
                self.assertEqual(follow(inner["sources"][0])["summary"], "Inner pass clean")
                self.assertEqual(inner["view"], frozen)
                self.assertEqual(history["test_view"], frozen)
                self.assertEqual(follow(follow(history["evidence_changes"][0])["receipt"])["report"]["summary"], "Journal updated")
                self.assertIsNone(history["lost"]["exposed"])
                conclusion = json.loads(read_source(view, "__review__/history-1.json"))
                self.assertEqual(conclusion["repair_gate"]["exposed"], "__review__/history-0.json")
                # A large seal stays readable page by page: no line reaches the inspector clip.
                lines = read_source(view, "__review__/history-0.json").decode().splitlines()
                self.assertGreater(len(lines), 2000)
                tail = tool.call({"tool": "focus_inspect", "arguments": {"operation": "read", "path": "__review__/history-0.json", "offset": len(lines) - 20, "limit": 20}})
                self.assertIn('"tests"', tail["contentItems"][0]["text"])
                self.assertNotIn("[Clipped", tail["contentItems"][0]["text"])

    def read_pages(self, tool, path):
        """Follow the page notices of focus_inspect; return each row's label and text."""
        labels, parts, offset = [], [], 0
        while True:
            text = tool.call({"tool": "focus_inspect", "arguments": {"operation": "read", "path": path, "offset": offset, "limit": 500}})["contentItems"][0]["text"]
            # One page of this size fits one tool result.
            self.assertLessEqual(len(text.encode("utf-8")), 30000)
            notice = None
            for row in text.split("\n")[2:]:
                if row.startswith("[The page stops before line"):
                    notice = int(row.rsplit("offset ", 1)[1].rstrip(".]"))
                    break
                label, _, part = row.partition(": ")
                labels.append(label)
                parts.append(part)
            if notice is None:
                self.assertNotIn("next offset", text.split("\n", 2)[1])
                return labels, parts
            self.assertEqual(notice, len(parts))
            self.assertIn(f"; next offset: {notice}", text.split("\n", 2)[1])
            offset = notice

    def test_the_inspector_pages_a_long_source_line_without_loss(self):
        pair = self.assign("pair_b", "low", False)
        execute = self.set_writer()
        def wide(c, h):
            value = execute(c, h)
            (self.root / "wide.txt").write_text("B" * 150000 + "END\nshort\n")
            (self.root / "emoji.txt").write_text("\U0001F600" * 20000 + "\n", encoding="utf-8")
            return value
        self.transport.handlers["repair_execute"] = wide
        self.step()
        view = materialize(self.cycle, self.cycle.repair_reader(pair))
        tool = ViewInspector(view)
        labels, parts = self.read_pages(tool, "wide.txt")
        self.assertEqual("".join(parts[:-1]), "B" * 150000 + "END")
        self.assertEqual((labels[0], labels[-2], labels[-1], parts[-1]), ("1 part 1/26", "1 part 26/26", "2", "short"))
        header = tool.call({"tool": "focus_inspect", "arguments": {"operation": "read", "path": "wide.txt", "offset": 0, "limit": 1}})["contentItems"][0]["text"]
        self.assertIn("Total lines/paths: 2; rows: 27, and offsets count rows; offset: 0", header)
        window = tool.call({"tool": "focus_inspect", "arguments": {"operation": "read", "path": "wide.txt", "offset": 25, "limit": 2}})["contentItems"][0]["text"]
        self.assertTrue(window.endswith("\n1 part 26/26: END\n2: short"))
        # A part of four-byte characters also fits on a page.
        labels, parts = self.read_pages(tool, "emoji.txt")
        self.assertEqual(("".join(parts), labels[-1]), ("\U0001F600" * 20000, "1 part 4/4"))
        # Short lines keep the earlier format.
        short = tool.call({"tool": "focus_inspect", "arguments": {"operation": "read", "path": "source.txt", "offset": 0, "limit": 5}})["contentItems"][0]["text"]
        self.assertIn("Total lines/paths: 1; offset: 0\n1: ", short)

    def test_resume_moves_an_inner_inspection_frozen_without_evidence_to_a_new_view(self):
        pair = self.assign("pair_b", "low", False)
        self.set_writer("pair")
        self.step()
        gate = pair["repair"]
        reader = self.cycle.repair_reader(pair)
        gate["reader"] = reader
        with patch.object(self.cycle, "repair_review_result"):
            self.step()
        self.assertEqual(sorted(reader["scans"]), ["repair_astra", "repair_opus"])
        # Earlier runtimes froze inner views and prompts without the evidence and its pointer.
        view = read_record(self.store, reader["view"])
        legacy = artifact(self.store, "legacy/view-0/view.json", {k: v for k, v in view.items() if k != "publication"})
        for job in reader["jobs"].values():
            prefix, assignment = job["prompt"].split("\nRuntime assignment:\n", 1)
            value = json.loads(assignment)
            value.pop("publication_manifest")
            value.pop("publication_rule")
            value["history"] = []
            job["prompt"] = prefix + "\nRuntime assignment:\n" + json.dumps(value, ensure_ascii=False, sort_keys=True)
        reader["view"] = legacy
        # Between rounds, completed reports stay, name their frozen view, and the next round gets a new view.
        completed = {key: dict(job, frozen_view=legacy) for key, job in reader["jobs"].items()}
        reader["step"] = "discuss"
        with patch.object(self.cycle, "pair_inspection_step") as inspect:
            self.step()
        inspect.assert_called_once_with(reader)
        self.assertEqual((reader["jobs"], reader["view"], reader["view_generation"]), (completed, None, 1))
        # In an interrupted step, only the job without a report starts again; the reader and its round stay.
        reader.update(step="scan", scans={}, view=legacy, view_generation=0)
        reader["jobs"] = {key: {k: v for k, v in job.items() if k != "frozen_view"} for key, job in reader["jobs"].items()}
        reader["jobs"]["scan/repair_astra"].pop("result")
        kept = reader["jobs"]["scan/repair_opus"]
        self.cycle.save()
        self.state = self.store.read()
        self.cycle.state = self.state
        pair, calls = self.state["pair_review"], len(self.transport.calls)
        with patch.object(self.cycle, "pair_inspection_step"):
            self.step()
        current = pair["repair"]["reader"]
        self.assertEqual(sorted(current["jobs"]), ["scan/repair_opus"])
        self.assertEqual((current["jobs"]["scan/repair_opus"]["sessions"], current["jobs"]["scan/repair_opus"]["frozen_view"]),
                         (kept["sessions"], legacy))
        # A kept report that later fails validation reruns in its session and old directory,
        # with the prompt of the renewed view.
        self.cycle.reject_pair_report(current, "scan/repair_opus", Blocked("pair-report", "Fixture validation error"))
        roots, fork = {}, self.transport.fork
        def record(root, state, *args, **kwargs):
            roots[state["pending"]["role"]] = root
            return fork(root, state, *args, **kwargs)
        self.transport.fork = record
        self.step()
        self.assertEqual(roots["repair_opus"], self.store.directory / "legacy/view-0/source")
        self.assertEqual(roots["repair_astra"], Path(read_record(self.store, current["view"])["root"]))
        self.assertEqual((current["id"], pair["repair"]["round"], current["view_generation"]), (reader["id"], 1, 1))
        self.assertIn("publication", read_record(self.store, current["view"]))
        self.assertEqual(current["jobs"]["scan/repair_opus"]["id"], kept["id"])
        self.assertIn('"publication_manifest"', current["jobs"]["scan/repair_opus"]["prompt"])
        self.assertEqual(current["jobs"]["scan/repair_opus"]["frozen_prompt"], kept["prompt"])
        readers = self.transport.calls[calls:]
        self.assertEqual(sorted(r for r, c in readers), ["repair_astra", "repair_opus"])
        self.assertTrue(all(c["publication_manifest"] == "__review__/publication.json" for r, c in readers))
        self.step()
        self.assertEqual((pair["repair"]["clean"], pair["repair"]["reader"]), (1, None))
        record = read_record(self.store, pair["repair"]["reviews"][-1]["record"])
        self.assertEqual(record["earlier_views"], [legacy])

    def test_renewal_keeps_only_jobs_with_work_to_finish(self):
        pair = self.assign("pair_b", "low", False)
        self.step()
        reader = self.cycle.repair_reader(pair)
        view = materialize(self.cycle, reader)
        current = reader["view"]
        legacy = artifact(self.store, "legacy/view.json", {k: v for k, v in view.items() if k != "publication"})
        source = {"path": "legacy/report.json", "sha256": "0" * 64}
        jobs = {"done": {"role": "repair_opus", "result": source},
                "correcting": {"role": "repair_astra", "report_source": source, "report_error": "Invalid"},
                "stale": {"role": "repair_astra", "report_source": source},
                "turn": {"role": "repair_astra", "turn_id": "native-turn"},
                "marker": {"role": "repair_astra", "attempts": 2, "sessions": {"repair_astra": "thread"}},
                "first": {"role": "repair_astra", "attempts": 1, "sessions": {"repair_astra": "thread"}},
                "unstarted": {"role": "repair_astra", "attempts": 0, "sessions": {"repair_astra": "thread"}},
                "claude": {"role": "repair_opus", "attempts": 2, "sessions": {"repair_opus": "conversation"}},
                "incomplete": {"role": "repair_opus", "incomplete_report": source},
                "fresh": {"role": "repair_opus"}}
        reader.update(view=legacy, jobs=copy.deepcopy(jobs))
        self.cycle.renew_legacy_view(reader)
        self.assertEqual(sorted(reader["jobs"]), ["correcting", "done", "first", "marker", "turn"])
        self.assertTrue(all(job["frozen_view"] == legacy for job in reader["jobs"].values()))
        self.assertEqual((reader["view"], reader["view_generation"]), (None, 1))
        # A view of the previous runtime has the manifest but not the records of the open gate.
        previous = artifact(self.store, "previous/view.json", dict(view, files={n: d for n, d in view["files"].items()
                                                                              if not n.startswith("__review__/gate")}))
        reader["view"] = previous
        self.cycle.renew_legacy_view(reader)
        self.assertEqual((reader["view"], reader["view_generation"]), (None, 2))
        # A current view is never renewed.
        reader["view"] = current
        self.cycle.renew_legacy_view(reader)
        self.assertEqual((reader["view"], reader["view_generation"]), (current, 2))

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
        # A repeated risk is harmless evidence, and a writer report gets no report correction.
        repeated = self.writer(c, mode="pair")
        repeated["repair"]["risks"] = ["contracts", "contracts"]
        self.assertEqual(parse_report(json.dumps(repeated), "repair_execute")["repair"]["risks"], ["contracts", "contracts"])

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

    def request_final_gate(self, times=1):
        self.start("final")
        requests = [times]
        def scan(c, h):
            self.assertIn("final_gate", c)
            requested = requests[0] > 0
            requests[0] -= 1
            return report(findings=[], final_gate={"full_run": requested, "reason": "The shared build configuration changed."})
        self.transport.handlers["pair_final_opus"] = scan

    def gate_tests(self):
        return [c for r, c in self.transport.calls if r == "repair_execute" and c["operation"] == "test"]

    def test_final_gate_runs_one_full_run_after_the_passed_final_pair(self):
        from focus_pair_repair import FINAL_GATE_VERIFICATION
        self.request_final_gate()
        candidate = self.repo.snapshot()
        self.until(lambda: self.state["phase"] == "publish")
        self.assertEqual([r for r, c in self.transport.calls], ["pair_final_opus", "pair_final_fable", "repair_execute"])
        context = self.gate_tests()[0]
        self.assertEqual(context["verification"], FINAL_GATE_VERIFICATION)
        self.assertEqual(context["clean_passes"], 0)
        task = context["assignments"][0]
        self.assertEqual((task["action"], task["full_suite"]), ("verify", True))
        self.assertIn("The shared build configuration changed.", task["reason"])
        self.assertEqual(self.state["reviewed"], candidate)
        self.assertEqual([(r["phase"], r["status"]) for r in self.state["pair_full_runs"]], [("final", "passed")])
        seals = sorted((self.store.directory / f"pair-reviews/{self.state['iteration']}").glob("*/seal.json"))
        self.assertEqual(len(seals), 1)
        seal = json.loads(seals[0].read_text())
        self.assertFalse(seal["cleanup_without_rereview"])
        self.assertEqual(seal["final_gate"]["requests"], ["The shared build configuration changed."])
        self.assertEqual(seal["final_gate"]["review"], self.state["pair_completed"]["final"])
        self.assertTrue(seal["repair_gate"])

    def test_final_gate_is_skipped_without_a_request_or_after_a_full_run_of_this_candidate(self):
        for passed in (False, True):
            with self.subTest(passed=passed):
                self.request_final_gate(times=1 if passed else 0)
                candidate = digest(encode(self.repo.snapshot()))
                if passed:
                    # A failed run is review history. The inspectors receive only passed runs.
                    self.state["pair_full_runs"] = [
                        {"phase": "pair_b", "record": None, "candidate": "earlier", "status": "failed"},
                        {"phase": "pair_b", "record": None, "candidate": candidate, "status": "passed"}]
                self.until(lambda: self.state["phase"] == "publish")
                self.assertEqual([r for r, c in self.transport.calls], ["pair_final_opus", "pair_final_fable"])
                facts = self.transport.calls[0][1]["final_gate"]["full_runs"]
                self.assertEqual(facts, [{"phase": "pair_b", "this_candidate": True}] if passed else [])

    def test_final_gate_defect_starts_the_repair_loop_and_a_new_final_pair(self):
        from focus_pair_repair import FULL_RUN_DONE
        self.request_final_gate(times=2)
        execute = self.set_writer()
        def run(c, h):
            if c["operation"] == "test" and len(self.gate_tests()) == 1:
                return self.writer(c, status="failed", failures=[finding("regression")])
            return execute(c, h)
        self.transport.handlers["repair_execute"] = run
        self.until(lambda: len(self.gate_tests()) == 2 and self.state["pair_review"] is None)
        self.assertEqual(self.state["phase"], "final")
        roles = [r for r, c in self.transport.calls]
        self.assertEqual((roles[3], roles[-1]), ("repair_execute", "repair_execute"))
        self.assertEqual(sorted(roles[4:-1]), ["repair_astra", "repair_astra", "repair_opus", "repair_opus"])
        retest = self.gate_tests()[1]["assignments"]
        self.assertFalse(any(t["full_suite"] for t in retest))
        self.assertEqual(retest[0]["check"], FULL_RUN_DONE)
        self.assertEqual([(r["phase"], r["status"]) for r in self.state["pair_full_runs"]], [("final", "failed")])
        # The new final pair checks the correction. The stage has no second final gate.
        self.assertEqual([r["title"] for r in self.state["pair_carry"]], ["Empty input guard"])
        self.assertNotIn("final", self.state["pair_completed"])
        self.assertIn("Финал: до устранения значимых", "\n".join(build_panel(self.state).lines))
        self.until(lambda: self.state["phase"] == "publish")
        self.assertEqual(len(self.gate_tests()), 2)
        self.assertTrue(self.transport.calls[-1][0].endswith("_discuss"))
        rescan = [c for r, c in self.transport.calls if r == "pair_final_opus"][-1]
        self.assertFalse(rescan["final_gate"]["available"])
        self.assertTrue(self.cycle.full_run_used("final"))

    def test_disputed_gate_row_does_not_move_to_the_next_final_pair(self):
        self.request_final_gate()
        execute = self.set_writer()
        def run(c, h):
            if c["operation"] == "test" and len(self.gate_tests()) == 1:
                value = self.writer(c, status="failed", failures=[finding("regression")])
                for row in value["resolutions"]:
                    row["outcome"] = "disputed"
                return value
            return execute(c, h)
        self.transport.handlers["repair_execute"] = run
        def discuss(c, h):
            # The inner readers decide the disputed gate row again, without the runtime gate key.
            a = c["assignment"]
            if a.get("proposal_hash"):
                return report(assessments=[], new_findings=[], consensus=a["proposal_hash"], impact="minor")
            return report(assessments=[decision(r, "verify") for r in a["registry"]], new_findings=[],
                          consensus=None, impact="minor")
        for role in ("repair_opus", "repair_astra"):
            self.transport.handlers[role + "_discuss"] = discuss
        self.until(lambda: len(self.gate_tests()) == 2 and self.state["pair_review"] is None)
        self.assertEqual(self.state["phase"], "final")
        self.assertEqual([r["title"] for r in self.state["pair_carry"]], ["Empty input guard"])
        self.assertFalse(any(r.get("final_gate") for r in self.state["pair_carry"]))

    def test_final_gate_after_a_final_cleanup_reuses_its_view_and_keeps_the_cleanup_record(self):
        pair = self.assign("final", "low", False)
        pair["scans"] = {"pair_final_opus": report(findings=[], final_gate={"full_run": True, "reason": "Shared code changed."})}
        self.set_writer()
        self.until(lambda: (self.state.get("pair_review") or {}).get("final_gate"))
        gate_pair = self.state["pair_review"]
        self.assertEqual(gate_pair["view"], pair["repair"]["test_view"])
        self.assertEqual(read_record(self.store, gate_pair["view"])["candidate"], digest(encode(self.repo.snapshot())))
        self.until(lambda: self.state["phase"] == "publish")
        self.assertEqual(len(self.gate_tests()), 2)
        seal = json.loads((self.store.directory / f"pair-reviews/{self.state['iteration']}/{gate_pair['id']}/seal.json").read_text())
        self.assertTrue(seal["cleanup_without_rereview"])
        self.assertEqual(seal["final_gate"]["requests"], ["Shared code changed."])

    def test_current_final_scan_without_final_gate_is_returned_for_correction(self):
        self.start("final")
        answers = []
        def scan(c, h):
            answers.append(c["final_gate"]["available"])
            return report(findings=[], omit_final_gate=len(answers) == 1)
        self.transport.handlers["pair_final_opus"] = scan
        self.until(lambda: self.state["phase"] == "publish")
        self.assertEqual(answers, [True, True])
        self.assertEqual([r for r, c in self.transport.calls], ["pair_final_opus", "pair_final_opus", "pair_final_fable"])

    def test_final_gate_cannot_skip_its_full_run(self):
        self.request_final_gate()
        self.transport.handlers["repair_execute"] = lambda c, h: self.writer(c, status="not_needed")
        with self.assertRaisesRegex(Blocked, "cannot be skipped"):
            self.until(lambda: self.state["phase"] == "publish")
        self.assertEqual(self.state["pair_review"]["repair"]["step"], "test")
        self.assertNotIn("pair_full_runs", self.state)

    def test_restart_during_the_final_gate_carries_no_gate_request(self):
        self.request_final_gate()
        self.until(lambda: (self.state.get("pair_review") or {}).get("step") == "repair")
        lines = "\n".join(build_panel(self.state).lines)
        self.assertIn("Финальный гейт · полный прогон Opus/xhigh", lines)
        self.assertNotIn("Проверка исправлений", lines)
        # The gate reuses the frozen view of the final pair for this exact candidate.
        pair = self.state["pair_review"]
        self.assertEqual(read_record(self.store, pair["view"])["candidate"], digest(encode(self.repo.snapshot())))
        self.assertNotIn(pair["id"], pair["view"]["path"])
        self.assertEqual(pair["repair"]["base"], pair["view"])
        self.cycle.reset_pairs()
        self.assertEqual((self.state["phase"], self.state["pair_carry"]), ("pair_a", []))

    def test_pair_b_full_run_limit_returns_full_suite_proposals_for_correction(self):
        self.start("pair_b")
        self.state["pair_full_runs"] = [{"phase": "pair_b", "record": None, "candidate": "c", "status": "passed"}]
        calls = {"pair_astra_discuss": 0, "pair_arbiter": 0}
        def broad(role):
            # Each first answer assigns a full run. The reader keeps its own proposal, so arbitration follows.
            def answer(c, h):
                calls[role] += 1
                rows = [decision(r, "verify", full_suite=calls[role] == 1) for r in c["assignment"]["registry"]]
                return report(assessments=rows, new_findings=[], consensus=None, impact="minor")
            return answer
        self.transport.handlers["pair_astra"] = lambda c, h: report(findings=[finding()])
        for role in calls:
            self.transport.handlers[role] = broad(role)
        corrections = []
        answer = self.transport.answer
        def record(role, prompt, heartbeat):
            if "Correct the prior report" in prompt:
                corrections.append((role, prompt.rsplit("Correct the prior report", 1)[1]))
            return answer(role, prompt, heartbeat)
        self.transport.answer = record
        self.until(lambda: (self.state.get("pair_review") or {}).get("step") in ("decide", "repair"))
        pair = self.state["pair_review"]
        for key in ("discuss/1/pair_astra", "arbitrate/1"):
            self.assertEqual(pair["jobs"][key]["report_repairs"], 1)
        self.assertEqual([r for r, _ in corrections], ["pair_astra_discuss", "pair_arbiter"])
        for _, text in corrections:
            self.assertIn("Pair B already used its one full run for this stage.", text)
        self.assertFalse(any(d["full_suite"] for d in pair["decisions"]))

    def test_stage_transition_removes_the_full_run_records(self):
        self.start("publish")
        self.state["pair_full_runs"] = [{"phase": "pair_b", "record": None, "candidate": "c", "status": "passed"}]
        self.cycle.advance_stage(self.repo.snapshot(), [], {})
        self.assertNotIn("pair_full_runs", self.state)
        self.assertFalse(self.cycle.full_run_used("pair_b"))

    def test_pair_b_full_run_happens_once_and_later_checks_are_targeted(self):
        self.start("pair_b")
        pair = self.cycle.new_pair()
        row = dict(finding(), source_id="broad")
        pair.update(step="decide", issues=[row], decisions=[decision(row, "verify", full_suite=True)], impact="minor")
        self.until(lambda: self.state["phase"] == "final")
        tests = self.gate_tests()
        self.assertEqual(len(tests), 1)
        self.assertTrue(tests[0]["assignments"][0]["full_suite"])
        self.assertEqual([(r["phase"], r["status"]) for r in self.state["pair_full_runs"]], [("pair_b", "passed")])
        self.assertFalse(pair["repair"]["accepted"][0]["full_suite"])
        # The verification is significant, so the same pair inspects again without a full run.
        rescans = [c for r, c in self.transport.calls if r == "pair_astra"]
        self.assertEqual([c["full_run"]["available"] for c in rescans], [False])
        self.assertTrue(self.cycle.full_run_used("pair_b"))

    def test_panel_explains_mode_progress_and_next_step(self):
        pair = self.assign("pair_b", "low", False)
        self.until(lambda: pair["repair"]["clean"] == 1)
        lines = "\n".join(build_panel(self.state).lines)
        self.assertIn("1/2 чистых", lines)
        self.assertIn("самопроверка Opus/xhigh", lines)
        self.assertIn("далее: следующий этап", lines)


if __name__ == "__main__":
    unittest.main()
