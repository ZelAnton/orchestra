"""Review campaigns exercise the production pair, publication, and ownership paths."""

import copy
import asyncio
import io
import json
from pathlib import Path
import subprocess
import tempfile
import os
import importlib.metadata
import sys
import unittest
from unittest.mock import patch

import test_cycle as fixtures
import test_focus_project as projects
import test_focus_pairs as pairs
from cycle_state import Blocked, LocalLock, Repository, Store, encode
from cycle_workflow import fresh_state
from focus_control import Control, request_stage_stop, runtime_active, status
from focus_pair_view import read_record
from focus_review_run import ReviewCycle, ProjectReviewCycle, choose_store, create_run, hand_back, pending_run
from focus_review_scope import load_request, make_request, plan_index, save_request, select, verify_plan
from focus_review_contract import validate_coverage
from focus_picker import Selection
from focus_status import build_panel


PLAN = """# S2. System

| ID | Title | Status |
| --- | --- | --- |
| S2-1 | First | Completed |
| S2-2a | Second A | Published `abc` |
| S2-2b | Second B | In progress |
| S2-2c | Second C | Завершена |
| S2-10 | Tenth | Done |

## S2-1. First
Check the first behavior.
## S2-2. Group
### S2-2a. Second A
Check the second behavior.
### S2-2b. Second B
Pending implementation.
### S2-2c. Second C
Check the shared dependency.
## S2-10. Tenth
Check ordering, not lexicographic sorting.
"""


class ScopeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "PLAN.md").write_text(PLAN)
        self.index = plan_index(self.root, "PLAN.md")

    def test_ranges_document_order_and_overlap(self):
        selected, excluded = select(self.index, ["S2-1..S2-2c,S2-2a,S2-10"])
        self.assertEqual(selected, ["S2-1", "S2-2a", "S2-2c", "S2-10"])
        self.assertEqual([r["id"] for r in excluded], ["S2-2b"])

    def test_parent_inside_range_does_not_expand_beyond_right_endpoint(self):
        self.assertEqual(select(self.index, ["S2-1..S2-2a"])[0], ["S2-1", "S2-2a"])
        self.assertEqual(select(self.index, ["S2-1..S2-2"])[0], ["S2-1", "S2-2a", "S2-2c"])

    def test_parent_prefix_does_not_confuse_one_and_ten(self):
        self.assertEqual(select(self.index, sections=["S2-1"])[0], ["S2-1"])
        self.assertEqual(select(self.index, sections=["S2"])[0], ["S2-1", "S2-2a", "S2-2c", "S2-10"])

    def test_invalid_or_unfinished_explicit_selection(self):
        for selector in ("S2-2b", "S2-99", "S2-10..S2-1", "S2-1,", "S2-1...S2-2"):
            with self.subTest(selector=selector), self.assertRaises(Blocked):
                select(self.index, [selector])

    def test_fences_checklists_and_unknown_status(self):
        (self.root / "PLAN.md").write_text("# Plan\n```md\n## S9. Fake\n```\n- [x] P1. Done\n- [ ] P2. Pending\n## P3. Unknown\n")
        index = plan_index(self.root, "PLAN.md")
        self.assertEqual([r["id"] for r in index["items"]], ["P1", "P2", "P3"])
        self.assertEqual([r["completed"] for r in index["items"]], [True, False, False])

    def test_duplicate_heading_rejected(self):
        (self.root / "PLAN.md").write_text("## P1. A\n## P1. B\n")
        with self.assertRaisesRegex(Blocked, "Duplicate"):
            plan_index(self.root, "PLAN.md")

    def test_large_historical_journal_does_not_enter_selected_requirements(self):
        (self.root / "PLAN.md").write_text(PLAN + "\n## History\n" + "Completed check.\n" * 300000)
        index = plan_index(self.root, "PLAN.md")
        request = make_request(index, ["S2-1", "S2-2a"])
        self.assertLess(len(encode(request)), 4096)
        self.assertEqual(len(request["targets"]), 2)

    def test_selection_roundtrip_pins_plan_and_requirements(self):
        request = make_request(self.index, ["S2-1", "S2-2a"], "Check their boundary", integration=True)
        path = self.root / "selection.json"
        save_request(path, request)
        self.assertEqual(load_request(path), request)
        verify_plan(self.root, request)
        forged = copy.deepcopy(request)
        forged["targets"][0]["items"][0]["text"] = "Different requirement"
        with self.assertRaisesRegex(Blocked, "Saved requirements"):
            verify_plan(self.root, forged)
        (self.root / "PLAN.md").write_text(PLAN + "\nChanged\n")
        with self.assertRaisesRegex(Blocked, "plan changed"):
            verify_plan(self.root, request)

    def test_scope_only_and_saved_shape(self):
        request = make_request(scope="Check service restart and message replay.")
        self.assertEqual(len(request["targets"]), 1)
        path = self.root / "scope.json"
        save_request(path, request)
        with self.assertRaises(FileExistsError): save_request(path, request)
        for change in ({"integration": "yes"}, {"targets": []}, {"plan": {"path": "PLAN.md"}}, {"other": True}):
            path.write_text(json.dumps(dict(request, **change)))
            with self.assertRaises(Blocked): load_request(path)

    def test_several_scopes_are_separate_targets_in_their_order(self):
        request = make_request(scopes=["# First part\nCheck the first part.", "  # Second part\nCheck the second part.\n"])
        self.assertFalse(request["integration"])
        self.assertEqual([(t["id"], t["title"], t["items"]) for t in request["targets"]],
                         [("scope-1", "First part", []), ("scope-2", "Second part", [])])
        self.assertEqual(request["targets"][1]["scope"], "# Second part\nCheck the second part.")
        path = self.root / "scopes.json"
        save_request(path, request)
        self.assertEqual(load_request(path), request)
        self.assertEqual(make_request(scopes=["Only one."]), make_request(scope="Only one."))
        for kwargs in ({"integration": True}, {"selected": ["S2-1"]}):
            with self.subTest(kwargs=kwargs), self.assertRaisesRegex(Blocked, "separate targets"):
                make_request(scopes=["A", "B"], **kwargs)
        for scopes in (["Only"], ["A", "B"]):
            with self.assertRaisesRegex(Blocked, "not both"):
                make_request(scope="Extra", scopes=scopes)
        self.assertEqual(make_request(scopes=["#", "B"])["targets"][0]["title"], "#")  # A bare marker stays.
        for scopes in (["A", "  "], ["A", "B\0"], ["A", "x" * 65537]):
            with self.assertRaisesRegex(Blocked, "at most 64 KiB"):
                make_request(scopes=scopes)

    def test_picker_parent_filter_range_and_hidden_marks(self):
        selection = Selection(self.index)
        selection.toggle("S2-2")
        self.assertEqual(selection.selected, {"S2-2a", "S2-2c"})
        selection.collapsed.add("S2-2")
        self.assertNotIn("S2-2a", [r["id"] for r in selection.visible()])
        self.assertIn("S2-2a", [r["id"] for r in selection.visible("Second A")])
        selection.range("S2-1")
        selection.range("S2-2a")
        self.assertEqual(selection.selected, {"S2-1", "S2-2a", "S2-2c"})


class CampaignTransport(pairs.PairTransport):
    def dispatch(self, role, prompt, heartbeat):
        if role in ("coordinate", "publish"):
            self.calls.append((role, {}))
            return json.dumps(fixtures.report())
        raw = super().dispatch(role, prompt, heartbeat)
        context = json.JSONDecoder().raw_decode(prompt.split("assignment:\n", 1)[1])[0]
        if context.get("review_scope") and context["assignment"]["mode"] == "independent_initial":
            value = json.loads(raw)
            value["coverage"] = [{"id": i, "paths": ["source.txt"], "checks": ["Inspected the requested behavior"], "limitations": []}
                                 for i in context["review_scope"]["coverage_ids"]]
            return json.dumps(value)
        return raw


class SubdirectoryTransport(CampaignTransport):
    """Record coverage in a subdirectory, so a commit elsewhere reaches no target."""
    def dispatch(self, role, prompt, heartbeat):
        raw = super().dispatch(role, prompt, heartbeat)
        if role not in ("coordinate", "publish"):
            value = json.loads(raw)
            for row in value.get("coverage", []):
                row["paths"] = ["sub/target.txt"]
            raw = json.dumps(value)
        return raw


class MemberCoverageTransport(CampaignTransport):
    """Record coverage inside one member repository of a project."""
    def dispatch(self, role, prompt, heartbeat):
        raw = super().dispatch(role, prompt, heartbeat)
        if role not in ("coordinate", "publish"):
            value = json.loads(raw)
            for row in value.get("coverage", []):
                row["paths"] = ["Core/source.txt"]
            raw = json.dumps(value)
        return raw


class CampaignTests(unittest.TestCase):
    setUp = fixtures.CycleTests.setUp
    tearDown = fixtures.CycleTests.tearDown
    remote = fixtures.CycleTests.remote

    def start(self, request=None):
        self.remote()
        self.store, self.state = create_run(self.repo, request or make_request(scope="Check source behavior"))
        self.transport = CampaignTransport(self.root)
        self.cycle = ReviewCycle(self.repo, self.store, self.state, self.transport, lambda: None, fixtures.REPO / "tools", "pwsh")
        self.transport.cycle = self.cycle

    def review(self):
        for _ in range(80):
            if self.state["phase"] == "publish": return
            self.cycle.paired_review_step()
        self.fail("Review did not converge")

    def test_complete_clean_scope_uses_all_pairs_no_code_or_commit(self):
        self.start()
        original = self.repo.snapshot()
        self.cycle.wait_ci = lambda: self.state.update(display_ci={"sha": self.state["published"]["sha"], "status": "ready"})
        self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(self.state["status"], "complete")
        self.assertEqual(self.repo.snapshot(), original)
        self.assertNotIn("code", [r for r, _ in self.transport.calls])
        self.assertEqual(len([c for r, c in self.transport.calls if c.get("review_scope")]), 6)
        self.assertTrue((self.store.directory / "report.md").is_file())
        self.assertIsNone(pending_run(self.root))
        self.assertIn("Выбранные цели", " ".join(build_panel(self.state).lines))

    def complete(self):
        self.cycle.wait_ci = lambda: self.state.update(display_ci={"sha": self.state["published"]["sha"], "status": "ready"})
        self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(self.state["status"], "complete")
        return (self.store.directory / "report.md").read_text()

    def test_report_lists_each_finding_with_its_decision_and_executor_result(self):
        self.start()
        first = [True]
        def scan(context, heartbeat):
            findings = [pairs.finding()] if first[0] else []
            first[0] = False
            return fixtures.report(findings=findings)
        self.transport.handlers["pair_sol"] = scan
        text = self.complete()
        self.assertIn("Findings:", text)
        # The second Pair A closes the repaired finding. The report shows the executor result.
        self.assertRegex(text, r"- pair_a, high, fixed: Empty input guard \(.+/pair_sol/guard\)\. Locations: source\.txt:1\. Guarded input\.")
        self.assertNotIn("## Deferred findings", text)

    def test_report_ends_with_the_deferred_findings(self):
        from focus_pair_profile import PAIRS
        self.start()
        first = [True]
        def scan(context, heartbeat):
            findings = [dict(pairs.finding("style"), title="Long comment line", severity="low")] if first[0] else []
            first[0] = False
            return fixtures.report(findings=findings)
        self.transport.handlers["pair_sol"] = scan
        def defer(context, heartbeat):
            assignment = context["assignment"]
            if assignment.get("proposal_hash"):
                return fixtures.report(assessments=[], new_findings=[], consensus=assignment["proposal_hash"], impact="minor")
            return fixtures.report(assessments=[dict(pairs.decision(r, "defer", False), reason="Unrelated to the reviewed requirement.")
                                                for r in assignment["registry"]], new_findings=[], consensus=None, impact="minor")
        for role in PAIRS["pair_a"]:
            self.transport.handlers[role + "_discuss"] = defer
        text = self.complete()
        self.assertIn("pair_a, low, defer: Long comment line", text)
        deferred = text.split("## Deferred findings", 1)[1]
        self.assertIn("Long comment line", deferred)
        self.assertIn("Unrelated to the reviewed requirement.", deferred)

    def discuss_pair_a(self, choose):
        from focus_pair_profile import PAIRS
        def discuss(context, heartbeat):
            assignment = context["assignment"]
            if assignment.get("proposal_hash"):
                return fixtures.report(assessments=[], new_findings=[], consensus=assignment["proposal_hash"], impact="minor")
            return fixtures.report(assessments=[choose(r) for r in assignment["registry"]], new_findings=[], consensus=None, impact="minor")
        for role in PAIRS["pair_a"]:
            self.transport.handlers[role + "_discuss"] = discuss

    def test_report_keeps_the_deferred_finding_of_a_round_that_also_fixed(self):
        self.start()
        first = [True]
        def scan(context, heartbeat):
            findings = [pairs.finding(), dict(pairs.finding("style"), title="Long comment line", severity="low")] if first[0] else []
            first[0] = False
            return fixtures.report(findings=findings)
        self.transport.handlers["pair_sol"] = scan
        def choose(row):
            if row.get("resolution", {}).get("outcome") == "fixed":
                return pairs.decision(row, "reject", False)
            if row["severity"] == "low":
                return dict(pairs.decision(row, "defer", False), reason="Unrelated to the reviewed requirement.")
            return pairs.decision(row)
        self.discuss_pair_a(choose)
        text = self.complete()
        # The round that fixed the guard ended without a conclusion. Its decision record keeps the deferral.
        self.assertRegex(text, r"- pair_a, high, fixed: Empty input guard")
        self.assertIn("Long comment line", text.split("## Deferred findings", 1)[1])

    def test_report_keeps_decisions_made_before_a_runtime_update(self):
        self.start()
        first = [True]
        def scan(context, heartbeat):
            findings = [dict(pairs.finding("style"), title="Long comment line", severity="low")] if first[0] else []
            first[0] = False
            return fixtures.report(findings=findings)
        self.transport.handlers["pair_sol"] = scan
        self.discuss_pair_a(lambda row: dict(pairs.decision(row, "defer", False), reason="Unrelated to the reviewed requirement."))
        record = self.cycle.record_target
        def updated():
            self.state["pair_decisions"] = []  # A runtime without decision records ran the pairs of this target.
            record()
        self.cycle.record_target = updated
        text = self.complete()
        self.assertIn("pair_a, low, defer: Long comment line", text.split("## Deferred findings", 1)[1])

    def test_each_target_lists_its_own_findings_and_keeps_earlier_deferrals(self):
        from focus_review_scope import plan_index
        for repeat in (False, True):
            with self.subTest(repeat=repeat):
                self.tearDown()
                self.setUp()
                (self.root / "PLAN.md").write_text(PLAN)
                self.repo.git("add", "PLAN.md")
                self.repo.git("commit", "-m", "Add plan")
                self.start(make_request(plan_index(self.root, "PLAN.md"), ["S2-1", "S2-2a"]))
                calls = [0]
                def scan(context, heartbeat):
                    calls[0] += 1
                    task = self.state["task"]["id"]
                    if task == "S2-1" and (calls[0] == 1 or repeat and context["assignment"]["mode"] == "independent_initial"
                                           and (self.root / "source.txt").read_text().startswith("guarded")):
                        return fixtures.report(findings=[dict(pairs.finding("style"), title="Deferred style item", severity="low")])
                    if task == "S2-2a" and not (self.root / "source.txt").read_text().startswith("guarded"):
                        return fixtures.report(findings=[pairs.finding()])
                    return fixtures.report(findings=[])
                self.transport.handlers["pair_sol"] = scan
                def choose(row):
                    if row.get("resolution", {}).get("outcome") in ("fixed", "verified"):
                        return pairs.decision(row, "reject", False)
                    if row["severity"] == "low":
                        return dict(pairs.decision(row, "defer", False), reason="Unrelated to the requirement.")
                    return pairs.decision(row)
                self.discuss_pair_a(choose)
                text = self.complete()
                # The S2-2a repair changed source.txt, so S2-1 was reviewed again.
                self.assertGreater(len(self.state["review_run"]["history"]), 2)
                first, second = text.split("## S2-2a", 1)
                findings, deferred = second.split("## Deferred findings", 1)
                self.assertIn("Deferred style item", first)
                self.assertNotIn("Deferred style item", findings)  # Records are per target.
                # A repeated deferral has a new source id. It is listed once, from the current review.
                self.assertEqual(deferred.count("Deferred style item"), 1)
                self.assertEqual("Earlier review of this target." in text, not repeat)

    def test_a_fixed_finding_that_a_later_round_defers_stays_deferred(self):
        self.start()
        first = [True]
        def scan(context, heartbeat):
            findings = [pairs.finding()] if first[0] else []
            first[0] = False
            return fixtures.report(findings=findings)
        self.transport.handlers["pair_sol"] = scan
        def choose(row):
            if row.get("resolution", {}).get("outcome") == "fixed":
                return dict(pairs.decision(row, "defer", False, severity="low"), reason="The remaining part is unrelated.")
            return pairs.decision(row)
        self.discuss_pair_a(choose)
        text = self.complete()
        deferred = text.split("## Deferred findings", 1)[1]
        self.assertIn("pair_a, low, defer: Empty input guard", deferred)
        self.assertIn("The remaining part is unrelated. Earlier executor result: fixed.", deferred)

    def test_repair_significant_finding_and_reinspect_before_publish(self):
        self.start()
        first = [True]
        def scan(context, heartbeat):
            findings = [pairs.finding()] if first[0] else []
            first[0] = False
            return fixtures.report(findings=findings)
        self.transport.handlers["pair_sol"] = scan
        self.review()
        self.assertEqual((self.root / "source.txt").read_text(), "guarded\n")
        self.assertGreater(sum(r == "pair_sol" for r, _ in self.transport.calls), 1)
        self.cycle.publish()
        self.assertEqual(self.repo.remote_head("origin"), self.repo.text("rev-parse", "HEAD"))
        self.assertEqual(self.repo.dirty_paths(), [])
        self.assertEqual(self.state["phase"], "ci")

    def test_namespace_controls_and_stop_request(self):
        self.start()
        self.assertFalse(Store(self.root).path.exists())
        control = Control(self.store)
        control.begin()
        with LocalLock(Store(self.root).directory):
            self.assertTrue(runtime_active(self.store))
            self.assertTrue(status(self.store, self.state)["running"])
            self.assertEqual(choose_store(self.root, current=True).review_id, self.store.review_id)
            with self.assertRaises(Blocked): request_stage_stop(Store(self.root))
            request_stage_stop(self.store)
        control.finish(self.state, 0)
        self.assertTrue((self.store.directory / "finish-stage.json").exists())
        self.assertFalse((Store(self.root).directory / "finish-stage.json").exists())

    def test_diagnostics_and_stop_can_address_damaged_review_state(self):
        self.start()
        control = Control(self.store)
        control.begin()
        self.store.path.write_text("damaged")
        selected = choose_store(self.root, current=True, require_state=False)
        self.assertEqual(selected.review_id, self.store.review_id)
        with self.assertRaises(Blocked): choose_store(self.root, current=True)
        control.finish(self.state, 0)

    def test_ui_retry_after_failed_admission_keeps_the_selected_scope(self):
        import cc_focus
        import test_focus_terminal as terminal
        class Screen(terminal.Display):
            def __enter__(self): return self
            def __exit__(self, *_): pass
        request = make_request(scope="Inspect existing source")
        with patch.object(cc_focus, "Interaction") as interaction, patch.object(cc_focus, "main", return_value=3) as main, patch.object(cc_focus, "runtime_changed", return_value=False):
            interaction.return_value.messages = None
            interaction.return_value.wait_action.side_effect = [("/resume", ""), ("/exit", "")]
            cc_focus.interactive_main(["review", "--scope", "Inspect existing source"], Screen(), None, request)
            self.assertEqual(main.call_count, 2)
            self.assertEqual(main.call_args.args[0][0], "review")
            self.assertEqual(main.call_args.kwargs["review_request"], request)

    def test_second_run_and_dirty_admission_rejected(self):
        self.start()
        with self.assertRaisesRegex(Blocked, "unfinished"):
            create_run(self.repo, make_request(scope="Another scope"))

    def test_new_review_refuses_unpublished_or_uncommitted_work(self):
        self.remote()
        (self.root / "source.txt").write_text("operator work\n")
        with self.assertRaisesRegex(Blocked, "clean published"):
            create_run(self.repo, make_request(scope="Inspect"))
        self.repo.git("add", "source.txt")
        self.repo.git("commit", "-m", "Unpublished work")
        with self.assertRaisesRegex(Blocked, "Publish the current"):
            create_run(self.repo, make_request(scope="Inspect"))

    def test_review_cli_preview_and_runtime_use_same_request(self):
        import cc_focus
        self.remote()
        original = self.repo.snapshot()
        previous = Path.cwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, previous)
        self.assertEqual(cc_focus.main(["review", "--scope", "Inspect", "--preview"]), 0)
        self.assertFalse(Store(self.root).path.exists())
        self.assertFalse((self.root / ".work/cycle/review-runs").exists())
        class Lease:
            pwsh = "pwsh"
            def __init__(self, *args): pass
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def heartbeat(self): pass
        with patch.object(cc_focus, "Lease", Lease), patch.object(cc_focus, "Transport", return_value=CampaignTransport(self.root)), patch.object(ReviewCycle, "wait_ci", return_value=None):
            self.assertEqual(cc_focus.main(["review", "--scope", "Inspect", "--ui", "off"]), 0)
        self.assertEqual(self.repo.snapshot(), original)
        self.assertIsNone(pending_run(self.root))
        self.assertFalse(Store(self.root).path.exists())

    def test_review_cli_takes_several_scope_files_in_one_campaign(self):
        import cc_focus
        self.remote()
        previous = Path.cwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, previous)
        scopes = Path(self.temp.name) / "scopes"
        scopes.mkdir()
        for name in ("a", "b"):
            (scopes / f"{name}.md").write_text(f"# Part {name}\nInspect part {name}.\n")
        output = io.StringIO()
        with patch("sys.stdout", output):
            self.assertEqual(cc_focus.main(["review", "--scope-file", str(scopes / "a.md"), str(scopes / "b.md"), "--preview"]), 0)
        preview = json.loads(output.getvalue()[output.getvalue().index("{"):])
        self.assertEqual((preview["mode"], [t["title"] for t in preview["targets"]]), ("separate targets", ["Part a", "Part b"]))
        output = io.StringIO()
        with patch("sys.stdout", output):  # A repeated option adds its files in the same order.
            self.assertEqual(cc_focus.main(["review", "--scope-file", str(scopes / "b.md"), "--scope-file", str(scopes / "a.md"), "--preview"]), 0)
        self.assertEqual([t["title"] for t in json.loads(output.getvalue()[output.getvalue().index("{"):])["targets"]], ["Part b", "Part a"])
        for extra in (["--integration"], ["--plan", "PLAN.md"], [str(scopes / "a.md")], ["--scope", "Also"]):
            with self.subTest(extra=extra), patch("sys.stderr", io.StringIO()), self.assertRaises(SystemExit):
                cc_focus.main(["review", "--scope-file", str(scopes / "a.md"), str(scopes / "b.md"), *extra, "--preview"])
        self.assertFalse((self.root / ".work/cycle/review-runs").exists())

    def test_a_campaign_with_several_scopes_reviews_each_target_in_order(self):
        self.start(make_request(scopes=["# Part one\nCheck source behavior.", "# Part two\nCheck source behavior again."]))
        self.assertEqual(self.state["task"]["title"], "Part one")
        report = self.complete()
        self.assertEqual(sorted(self.state["review_run"]["results"]), ["0", "1"])
        self.assertLess(report.index("## Part one"), report.index("## Part two"))

    def test_dependency_change_requeues_prior_target(self):
        (self.root / "PLAN.md").write_text(PLAN)
        self.repo.git("add", "PLAN.md")
        self.repo.git("commit", "-m", "Add plan")
        self.start(make_request(plan_index(self.root, "PLAN.md"), ["S2-1", "S2-2a"]))
        self.review()
        self.cycle.publish()
        self.cycle.next_stage()
        self.transport.handlers["pair_sol"] = lambda context, heartbeat: fixtures.report(
            findings=[pairs.finding()] if (self.root / "source.txt").read_text() != "guarded\n" else [])
        self.review()
        self.cycle.publish()
        self.cycle.next_stage()
        self.assertEqual(self.state["task"]["id"], "S2-1")
        self.assertEqual(self.state["phase"], "pair_a")
        self.assertNotIn("0", self.state["review_run"]["results"])
        self.review()
        self.cycle.publish()
        self.cycle.next_stage()
        self.assertEqual(self.state["status"], "complete")
        self.assertEqual(len(self.state["review_run"]["history"]), 3)

    def test_paused_development_transfers_only_completed_review_checkpoint(self):
        self.remote()
        development = fresh_state(self.repo)
        development.update(phase="ci", status="paused", code_started=True, published={"sha": development["baseline"]["head"]},
                           stage_completed={"iteration": 1, "sha": development["baseline"]["head"]})
        Store(self.root).save(development)
        self.store, self.state = create_run(self.repo, make_request(scope="Check source behavior"))
        self.transport = CampaignTransport(self.root)
        self.cycle = ReviewCycle(self.repo, self.store, self.state, self.transport, lambda: None, fixtures.REPO / "tools", "pwsh")
        self.review()
        self.cycle.publish()
        self.cycle.next_stage()
        hand_back(self.repo, fixtures.REPO / "tools")
        updated = Store(self.root).read()
        self.assertEqual(updated["iteration"], 2)
        self.assertEqual(updated["phase"], "code")
        self.assertEqual(updated["review_handover"]["id"], self.store.review_id)
        hand_back(self.repo, fixtures.REPO / "tools")
        self.assertEqual(Store(self.root).read(), updated)

    def test_a_review_starts_after_pushed_commits_on_a_completed_development_stage(self):
        self.remote()
        development = fresh_state(self.repo)
        development.update(phase="ci", status="paused", code_started=True,
                           published={"sha": development["baseline"]["head"], "remote": "origin"},
                           stage_completed={"iteration": 1, "sha": development["baseline"]["head"]})
        Store(self.root).save(development)
        (self.root / "notes.md").write_text("Plan corrected between stages\n")
        self.repo.git("add", "notes.md")
        self.repo.git("commit", "-m", "Correct the plan")
        self.repo.git("push", "origin", "main")
        store, state = create_run(self.repo, make_request(scope="Check source behavior"))
        self.assertEqual(state["baseline"]["head"], self.repo.text("rev-parse", "HEAD"))
        self.assertEqual(Store(self.root).read(), development)

    def test_a_review_starts_after_pushed_commits_on_an_unstarted_development_stage(self):
        self.remote()
        development = fresh_state(self.repo)  # Phase code, before the first coding invocation.
        Store(self.root).save(development)
        self.push_notes()
        store, state = create_run(self.repo, make_request(scope="Check source behavior"))
        self.assertEqual(state["baseline"]["head"], self.repo.text("rev-parse", "HEAD"))

    def test_a_review_does_not_start_when_main_lost_an_unstarted_development_stage_base(self):
        self.remote()
        self.push_notes()
        development = fresh_state(self.repo)
        Store(self.root).save(development)
        self.repo.git("reset", "--hard", "HEAD~1")
        self.repo.git("push", "--force", "origin", "main")
        with self.assertRaises(Blocked) as caught:
            create_run(self.repo, make_request(scope="Check source behavior"))
        self.assertEqual(caught.exception.code, "stage-base-drift")

    def test_a_review_does_not_start_when_main_lost_the_completed_development_stage(self):
        self.remote()
        (self.root / "notes.md").write_text("Published stage\n")
        self.repo.git("add", "notes.md")
        self.repo.git("commit", "-m", "Publish the stage")
        self.repo.git("push", "origin", "main")
        development = fresh_state(self.repo)
        sha = development["baseline"]["head"]
        development.update(phase="ci", status="paused", code_started=True, published={"sha": sha, "remote": "origin"},
                           stage_completed={"iteration": 1, "sha": sha})
        Store(self.root).save(development)
        self.repo.git("reset", "--hard", "HEAD~1")
        self.repo.git("push", "--force", "origin", "main")
        with self.assertRaises(Blocked) as caught:
            create_run(self.repo, make_request(scope="Check source behavior"))
        self.assertEqual(caught.exception.code, "stage-base-drift")
        self.assertIn("Then run the same cc-focus review command.", str(caught.exception))

    def test_correction_restarts_reviews_preserves_target_and_no_code_route(self):
        self.start()
        target = dict(self.state["task"])
        self.cycle.correct("Also check empty input.")
        self.assertEqual(self.store.read()["phase"], "pair_a")
        self.assertEqual(self.state["task"], target)
        self.assertNotIn("publication_recovery", self.state["corrections"][-1])
        with self.assertRaises(Blocked): self.cycle.context("code")

    def test_queue_transition_is_atomic_and_finish_stage_keeps_next_target(self):
        (self.root / "PLAN.md").write_text(PLAN)
        self.repo.git("add", "PLAN.md")
        self.repo.git("commit", "-m", "Add plan")
        index = plan_index(self.root, "PLAN.md")
        self.start(make_request(index, ["S2-1", "S2-2a"]))
        self.review()
        self.cycle.publish()
        request_stage_stop(self.store)
        self.assertFalse(self.cycle.next_stage())
        self.assertEqual(self.state["task"]["id"], "S2-1")
        written = []
        original_save = self.store.save
        def save(state):
            written.append((state["phase"], state["task"]["id"]))
            original_save(state)
        with patch.object(self.store, "save", side_effect=save):
            self.cycle.next_stage()
        self.assertEqual(written, [("pair_a", "S2-2a")])
        self.assertEqual(self.state["sessions"], {})
        self.review()
        self.cycle.publish()
        self.cycle.next_stage()
        self.assertEqual(self.state["status"], "complete")
        self.assertEqual(len(self.state["review_run"]["results"]), 2)

    def push_notes(self, push=True):
        (self.root / "notes.md").write_text("Later commit\n")
        self.repo.git("add", "notes.md")
        self.repo.git("commit", "-m", "Add notes")
        if push:
            self.repo.git("push", "origin", "main")

    def test_a_review_run_reviews_a_target_again_after_pushed_commits_in_its_stage_pause(self):
        self.start()
        self.review()
        self.cycle.publish()
        request_stage_stop(self.store)
        self.assertFalse(self.cycle.next_stage())
        self.assertIn("0", self.state["review_run"]["results"])
        self.push_notes()  # The coverage directory of the target is the root, so this commit reaches it.
        self.assertTrue(self.cycle.next_stage())
        run = self.state["review_run"]
        self.assertNotIn("0", run["results"])
        self.assertEqual((run["current"], self.state["iteration"], self.state["phase"]), (0, 2, "pair_a"))
        self.assertEqual(self.state["baseline"]["head"], self.repo.text("rev-parse", "HEAD"))
        self.review()
        self.cycle.publish()
        self.cycle.next_stage()
        self.assertEqual(self.state["status"], "complete")
        self.assertIn("0", run["results"])

    def test_development_resumes_after_a_review_completes_on_pushed_commits_that_reach_no_target(self):
        (self.root / "sub").mkdir()
        (self.root / "sub/target.txt").write_text("target\n")
        self.repo.git("add", "sub/target.txt")
        self.repo.git("commit", "-m", "Add the target")
        self.remote()
        development = fresh_state(self.repo)
        development.update(phase="ci", status="paused", code_started=True, published={"sha": development["baseline"]["head"]},
                           stage_completed={"iteration": 1, "sha": development["baseline"]["head"]})
        Store(self.root).save(development)
        self.store, self.state = create_run(self.repo, make_request(scope="Check target behavior"))
        self.transport = SubdirectoryTransport(self.root)
        self.cycle = ReviewCycle(self.repo, self.store, self.state, self.transport, lambda: None, fixtures.REPO / "tools", "pwsh")
        self.review()
        self.cycle.publish()
        request_stage_stop(self.store)
        self.assertFalse(self.cycle.next_stage())
        self.push_notes()  # notes.md is outside sub/, so no target needs another review.
        self.assertTrue(self.cycle.next_stage())
        self.assertEqual((self.state["status"], list(self.state["review_run"]["results"])), ("complete", ["0"]))
        hand_back(self.repo, fixtures.REPO / "tools")
        updated = Store(self.root).read()
        self.assertEqual((updated["iteration"], updated["baseline"]["head"]), (2, self.repo.text("rev-parse", "HEAD")))

    def test_a_commit_pushed_during_the_stage_pause_checks_still_requeues_its_target(self):
        (self.root / "sub").mkdir()
        (self.root / "sub/target.txt").write_text("target\n")
        self.repo.git("add", "sub/target.txt")
        self.repo.git("commit", "-m", "Add the target")
        self.start()
        self.transport = self.cycle.transport = SubdirectoryTransport(self.root)
        self.review()
        self.cycle.publish()
        request_stage_stop(self.store)
        self.assertFalse(self.cycle.next_stage())
        original = self.cycle.assert_stage_base
        def check_then_push():
            original()
            # Another agent pushes a change to the target while the runtime checks main.
            (self.root / "sub/target.txt").write_text("changed during the check\n")
            self.repo.git("commit", "-am", "Change the target")
            self.repo.git("push", "origin", "main")
        with patch.object(self.cycle, "assert_stage_base", side_effect=check_then_push):
            self.assertTrue(self.cycle.next_stage())
        self.assertEqual((self.state["review_run"]["remaining"], self.state["review_run"]["current"]), ([], 0))
        self.assertNotIn("0", self.state["review_run"]["results"])
        self.assertEqual(self.state["baseline"]["head"], self.repo.text("rev-parse", "HEAD"))

    def complete_review_after_development_pause(self):
        self.remote()
        development = fresh_state(self.repo)
        development.update(phase="ci", status="paused", code_started=True, published={"sha": development["baseline"]["head"]},
                           stage_completed={"iteration": 1, "sha": development["baseline"]["head"]})
        Store(self.root).save(development)
        self.store, self.state = create_run(self.repo, make_request(scope="Check source behavior"))
        self.transport = CampaignTransport(self.root)
        self.cycle = ReviewCycle(self.repo, self.store, self.state, self.transport, lambda: None, fixtures.REPO / "tools", "pwsh")
        self.review()
        self.cycle.publish()
        self.cycle.next_stage()
        self.assertEqual(self.state["status"], "complete")

    def test_development_resumes_after_pushed_commits_on_a_completed_review(self):
        self.complete_review_after_development_pause()
        self.push_notes()
        hand_back(self.repo, fixtures.REPO / "tools")
        updated = Store(self.root).read()
        self.assertEqual((updated["iteration"], updated["phase"]), (2, "code"))
        self.assertEqual(updated["baseline"]["head"], self.repo.text("rev-parse", "HEAD"))
        self.assertEqual(updated["review_handover"]["id"], self.store.review_id)

    def test_development_handover_names_a_remote_that_moved_ahead_after_a_review(self):
        self.complete_review_after_development_pause()
        clone = Path(self.temp.name) / "other-clone"
        subprocess.run(["git", "clone", "--quiet", "--branch", "main", str(Path(self.temp.name) / "bare.git"), str(clone)], check=True)
        other = Repository(clone)
        other.git("config", "user.name", "Other agent")
        other.git("config", "user.email", "other@example.invalid")
        (clone / "notes.md").write_text("Pushed from another clone\n")
        other.git("add", "notes.md")
        other.git("commit", "-m", "Correct the plan elsewhere")
        other.git("push", "origin", "main")
        with self.assertRaises(Blocked) as caught:
            hand_back(self.repo, fixtures.REPO / "tools")
        self.assertEqual(caught.exception.code, "stage-base-unpublished")
        self.assertIn("Then run the same cc-focus command.", str(caught.exception))

    def test_development_handover_stops_when_main_moves_during_its_checks(self):
        self.complete_review_after_development_pause()
        before = Store(self.root).read()
        original = ReviewCycle.assert_stage_base
        def check_then_push(cycle):
            original(cycle)
            self.push_notes()  # Another agent pushes while the handover checks main.
        with patch.object(ReviewCycle, "assert_stage_base", check_then_push), self.assertRaises(Blocked) as caught:
            hand_back(self.repo, fixtures.REPO / "tools")
        self.assertEqual(caught.exception.code, "review-handover-drift")
        self.assertEqual(Store(self.root).read(), before)
        hand_back(self.repo, fixtures.REPO / "tools")  # A rerun hands over the current, pushed checkout.
        self.assertEqual(Store(self.root).read()["baseline"]["head"], self.repo.text("rev-parse", "HEAD"))

    def test_development_handover_stops_for_an_unpushed_commit_after_a_review(self):
        self.complete_review_after_development_pause()
        before = Store(self.root).read()
        self.push_notes(push=False)
        with self.assertRaises(Blocked) as caught:
            hand_back(self.repo, fixtures.REPO / "tools")
        self.assertEqual(caught.exception.code, "stage-base-unpublished")
        self.assertIn("Then run the same cc-focus command.", str(caught.exception))
        self.assertEqual(Store(self.root).read(), before)

    def test_failed_queue_transition_preserves_the_old_review_route(self):
        (self.root / "PLAN.md").write_text(PLAN)
        self.repo.git("add", "PLAN.md")
        self.repo.git("commit", "-m", "Add plan")
        self.start(make_request(plan_index(self.root, "PLAN.md"), ["S2-1", "S2-2a"]))
        self.review()
        self.cycle.publish()
        self.cycle.record_target()
        before = copy.deepcopy(self.state)
        with patch.object(self.store, "save", side_effect=OSError("Disk unavailable")), self.assertRaises(OSError):
            self.cycle.next_stage()
        self.assertEqual(self.state, before)
        self.assertEqual(self.state["phase"], "ci")
        self.cycle.next_stage()
        self.assertEqual(self.state["task"]["id"], "S2-2a")

    def test_review_reset_retires_credit_without_overwriting_target_evidence(self):
        self.start()
        self.review()
        self.cycle.publish()
        request_stage_stop(self.store)
        self.assertFalse(self.cycle.next_stage())
        run = self.state["review_run"]
        previous = copy.deepcopy(run["results"]["0"])
        record = read_record(self.store, previous)
        self.cycle.reset_reviews("CI repair requires fresh inspection")
        self.assertNotIn("0", run["results"])
        self.assertNotIn("recorded_iteration", run)
        self.review()
        self.cycle.publish()
        self.cycle.next_stage()
        self.assertEqual(read_record(self.store, previous), record)
        self.assertNotEqual(previous["path"], run["results"]["0"]["path"])

    def test_coverage_rejects_missing_items_and_nonexistent_source(self):
        scope = {"coverage_ids": ["P1", "P2"]}
        row = {"id": "P1", "paths": ["source.txt"], "checks": ["Boundary check"], "limitations": []}
        for rows in ([row], [row, row], [row, dict(row, id="P2", paths=["missing.txt"])]):
            with self.assertRaises(Blocked): validate_coverage({"coverage": rows}, scope, {"source.txt": "x"})
        with self.assertRaisesRegex(Blocked, "only once"):
            validate_coverage({"coverage": [dict(row, paths=["source.txt", "source.txt"])]}, {"coverage_ids": ["P1"]}, {"source.txt": "x"})

    def test_every_report_schema_uses_only_strict_codex_keywords(self):
        # Codex strict mode refused uniqueItems in the coverage schema with HTTP 400.
        from cycle_prompts import PROFILES
        from focus_review import report_schema
        text = {"type": "string"}
        for loose in ({"type": "object"}, {"type": ["object", "null"], "properties": {}, "required": []},
                      {"type": "object", "properties": {"note": text}, "required": [], "additionalProperties": False}):
            with self.subTest(loose=loose):
                self.assertFalse(fixtures.strict_objects({"type": "array", "items": loose}))
        for role in PROFILES:
            for existing in (False, True):
                with self.subTest(role=role, existing=existing):
                    schema = report_schema(role, existing)
                    self.assertLessEqual(fixtures.schema_keywords(schema), fixtures.STRICT_KEYWORDS)
                    self.assertTrue(fixtures.strict_objects(schema))

    def test_incomplete_inspection_can_report_failure_without_invented_paths(self):
        row = {"id": "scope", "paths": [], "checks": ["Inspector unavailable"], "limitations": ["Could not inspect source"]}
        validate_coverage({"status": "blocked", "coverage": [row]}, {"coverage_ids": ["scope"]}, {})
        with self.assertRaises(Blocked):
            validate_coverage({"status": "done", "coverage": [row]}, {"coverage_ids": ["scope"]}, {})

    def test_admission_rechecks_checkout_after_remote_verification(self):
        self.remote()
        original = self.repo.remote_head
        def mutate(remote):
            result = original(remote)
            (self.root / "source.txt").write_text("Concurrent operator change\n")
            return result
        with patch.object(self.repo, "remote_head", side_effect=mutate), self.assertRaisesRegex(Blocked, "changed during"):
            create_run(self.repo, make_request(scope="Inspect"))
        self.assertIsNone(pending_run(self.root))


class ProjectCampaignTests(unittest.TestCase):
    setUp = projects.ProjectTests.setUp
    tearDown = projects.ProjectTests.tearDown

    def test_no_change_project_retains_each_head_and_ci_gate(self):
        store, state = create_run(self.project, make_request(scope="Check Core and Root integration"))
        cycle = ProjectReviewCycle(self.project, store, state, None, lambda: None, fixtures.REPO / "tools", "pwsh")
        state["reviewed"] = self.project.snapshot()
        cycle.publish()
        cycle.wait_ci()
        cycle.assert_publication_current()
        self.assertEqual(set(state["published"]["repositories"]), set(self.members))
        self.assertEqual(state["display_ci"]["passed"], 3)
        self.assertEqual(self.project.snapshot(), state["baseline"])

    def test_imported_handoff_does_not_prevent_review_at_development_boundary(self):
        self.state["handoffs"] = [self.store.handoff(self.root / "HANDOFF.md")]
        self.state["last_snapshot"] = self.cycle.snapshot()
        self.store.save(self.state)
        _, state = create_run(self.project, make_request(scope="Inspect existing members"))
        self.assertEqual(state["phase"], "pair_a")
        self.assertEqual(state["handoffs"], [])

    def test_review_admission_rejects_a_changed_repository_set(self):
        self.store.save(self.state)
        path = self.root / "Extra"
        path.mkdir()
        extra = Repository(path)
        extra.git("init", "--initial-branch=main")
        extra.git("config", "user.name", "Test")
        extra.git("config", "user.email", "test@example.invalid")
        (path / "source.txt").write_text("original\n")
        extra.git("add", "source.txt")
        extra.git("commit", "-m", "Initial source")
        remote = Path(self.temp.name) / "Extra.git"
        subprocess.run(["git", "init", "--bare", str(remote)], check=True, capture_output=True)
        extra.git("remote", "add", "origin", str(remote))
        extra.git("push", "-u", "origin", "main")
        from focus_project import open_project
        with self.assertRaises(Blocked) as caught:
            create_run(open_project(self.root), make_request(scope="Inspect members"))
        self.assertEqual(caught.exception.code, "project-layout-changed")

    def complete_project_review(self):
        self.store.save(self.state)  # Development boundary: phase code, before the first coding invocation.
        store, state = create_run(self.project, make_request(scope="Inspect Core"))
        transport = MemberCoverageTransport(self.root)
        cycle = ProjectReviewCycle(self.project, store, state, transport, lambda: None, fixtures.REPO / "tools", "pwsh")
        transport.cycle = cycle
        for _ in range(80):
            if state["phase"] == "publish":
                break
            cycle.paired_review_step()
        cycle.publish()
        cycle.next_stage()
        self.assertEqual(state["status"], "complete")

    def test_changed_project_context_still_needs_development_acceptance(self):
        self.store.save(self.state)
        (self.root / "HANDOFF.md").write_text("Changed shared instructions.\n")
        with self.assertRaises(Blocked) as caught:
            create_run(self.project, make_request(scope="Inspect Core"))
        self.assertEqual(caught.exception.code, "review-context")
        self.tearDown()
        self.setUp()
        self.complete_project_review()
        before = Store(self.root).read()
        (self.root / "HANDOFF.md").write_text("Changed shared instructions after the review.\n")
        with self.assertRaises(Blocked) as caught:
            hand_back(self.project, fixtures.REPO / "tools")
        self.assertEqual(caught.exception.code, "review-handover-drift")
        self.assertEqual(Store(self.root).read(), before)

    def test_project_context_changed_during_a_review_pause_still_needs_development_acceptance(self):
        self.store.save(self.state)  # Development boundary: phase code, before the first coding invocation.
        store, state = create_run(self.project, make_request(scope="Inspect Core"))
        transport = MemberCoverageTransport(self.root)
        cycle = ProjectReviewCycle(self.project, store, state, transport, lambda: None, fixtures.REPO / "tools", "pwsh")
        transport.cycle = cycle
        for _ in range(80):
            if state["phase"] == "publish":
                break
            cycle.paired_review_step()
        cycle.publish()
        request_stage_stop(store)
        self.assertFalse(cycle.next_stage())
        (self.root / "HANDOFF.md").write_text("Changed shared instructions during the review pause.\n")
        self.assertTrue(cycle.next_stage())
        self.assertEqual(state["status"], "complete")
        before = Store(self.root).read()
        with self.assertRaises(Blocked) as caught:
            hand_back(self.project, fixtures.REPO / "tools")
        self.assertEqual(caught.exception.code, "review-handover-drift")
        self.assertEqual(Store(self.root).read(), before)

    def test_repairs_publish_only_the_changed_member(self):
        store, state = create_run(self.project, make_request(scope="Inspect Core and Root"))
        original = self.project.snapshot()
        cycle = ProjectReviewCycle(self.project, store, state, self.transport, lambda: None, fixtures.REPO / "tools", "pwsh")
        (self.root / "Core/source.txt").write_text("Reviewed repair\n")
        reviewed = self.project.snapshot()
        state.update(phase="publish", reviewed=reviewed, last_snapshot=reviewed, coordinated="publish")
        self.transport.actions = [("publish", fixtures.report())]
        cycle.publish()
        cycle.wait_ci()
        self.assertEqual(set(state["published"]["repositories"]), {"Core"})
        self.assertEqual(self.members["Core"].remote_head("origin"), self.members["Core"].text("rev-parse", "HEAD"))
        for name in ("Root", "Specification"):
            self.assertEqual(self.members[name].remote_head("origin"), original["head"][name])


def has_menu_packages():
    try:
        return (importlib.metadata.version("prompt_toolkit") == "3.0.52"
                and importlib.metadata.version("wcwidth") == "0.2.13")
    except importlib.metadata.PackageNotFoundError:
        return False


@unittest.skipUnless(has_menu_packages(), "optional pinned menu environment is not installed")
class MenuTests(unittest.TestCase):
    setUp = ScopeTests.setUp
    def run_menu(self, keys):
        from prompt_toolkit.input import create_pipe_input
        from prompt_toolkit.output import DummyOutput
        from focus_picker import picker_application
        async def run():
            with create_pipe_input() as pipe:
                app = picker_application(self.index, input=pipe, output=DummyOutput())
                async def send():
                    await asyncio.sleep(.05)
                    pipe.send_text(keys)
                sender = asyncio.create_task(send())
                result = await asyncio.wait_for(app.run_async(), 3)
                await sender
                self.assertFalse(app.mouse_support())
                return result
        return asyncio.run(run())

    def test_keyboard_toggle_group_integration_and_accept(self):
        selected, _, integration = self.run_menu(" i\r")
        self.assertEqual(selected, ["S2-1", "S2-2a", "S2-2c", "S2-10"])
        self.assertTrue(integration)

    def test_cancel_starts_nothing(self):
        self.assertIsNone(self.run_menu("\x03"))

    def test_search_space_and_accept(self):
        selected, _, _ = self.run_menu("/Second A\t \r")
        self.assertEqual(selected, ["S2-2a"])

    def test_pinned_environment_takes_precedence_over_a_global_library(self):
        fake = self.root / "prompt_toolkit"
        fake.mkdir()
        (fake / "__init__.py").write_text('__version__ = "unrelated-global-version"\n')
        code = ("from pathlib import Path; import sys; "
                f"sys.path.insert(0, {str(fixtures.REPO / 'tools')!r}); import focus_picker; "
                f"focus_picker.environment = lambda: Path({sys.prefix!r}); "
                "focus_picker.load_ui(); import prompt_toolkit; assert prompt_toolkit.__version__ == '3.0.52'")
        result = subprocess.run([sys.executable, "-B", "-c", code], cwd=self.root, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
