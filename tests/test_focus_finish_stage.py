"""Stage-boundary pause tests with disposable Git repositories and fake providers."""

import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import unittest
from unittest.mock import patch

import test_cycle as fixtures
from test_focus_pairs import PairTransport
import test_focus_project as project_fixtures
from test_focus_terminal import Display
from cycle_state import Blocked, LocalLock, Store, encode
from cycle_workflow import Cycle, fresh_state
from focus_control import Control, request_stage_stop, stage_stop_lock, stage_stop_request, status
from focus_input import Interaction
from focus_status import build_panel


class FinishStageTests(unittest.TestCase):
    setUp = fixtures.CycleTests.setUp
    tearDown = fixtures.CycleTests.tearDown
    edit = fixtures.CycleTests.edit
    remote = fixtures.CycleTests.remote
    commit_stage = fixtures.CycleTests.commit_stage
    focus_control = fixtures.CycleTests.focus_control
    stop_request = fixtures.CycleTests.stop_request

    def prepare_ci(self):
        self.remote()
        self.edit()()
        self.state.update(phase="publish", reviewed=self.repo.snapshot(), remote="origin",
                          task={"id": "S2-15e2", "title": "External delivery", "plan": "source.txt", "iteration": 1})
        self.commit_stage()
        self.cycle.reconcile_publish()
        self.store.save(self.state)

    def test_request_is_durable_idempotent_and_does_not_change_work_or_state(self):
        self.store.save(self.state)
        before, state_bytes = self.repo.snapshot(), self.store.path.read_bytes()
        request_stage_stop(self.store)
        saved = (self.store.directory / "finish-stage.json").read_bytes()
        request_stage_stop(self.store)
        self.assertEqual((self.store.directory / "finish-stage.json").read_bytes(), saved)
        self.assertEqual(self.store.path.read_bytes(), state_bytes)
        self.assertEqual(self.repo.snapshot(), before)
        self.assertFalse((self.root / ".work/PAUSE").exists())
        self.assertEqual(stage_stop_request(Store(self.root), self.store.read())["iteration"], 1)
        self.assertIsNone(Control(self.store).request())

    def test_full_stage_runs_all_pairs_publishes_and_pauses_without_next_coordinator(self):
        self.remote()
        self.state.update(coordinated="code")
        pairs = PairTransport(self.root)
        original = self.transport
        class Combined:
            interaction = None
            fork = pairs.fork
            run = original.run
        self.cycle.transport = Combined()
        def implement():
            request_stage_stop(self.store)
            return self.edit(implementation_fixes=1)()
        original.actions = [("code", implement), ("coordinate", fixtures.report()), ("publish", fixtures.report())]
        with patch.object(self.cycle, "ci_gate", return_value={"verdict": "no-required-checks"}):
            self.assertEqual(self.cycle.run(), 0)
        self.assertEqual((self.state["phase"], self.state["status"], self.state["iteration"]), ("ci", "paused", 1))
        self.assertEqual(self.state["display_ci"]["status"], "not-configured")
        self.assertEqual(set(self.state["pair_completed"]), {"pair_a", "pair_b", "final"})
        self.assertEqual({role for role, _ in pairs.calls},
                         {"pair_opus", "pair_sol", "pair_astra", "pair_opus_max", "pair_final_opus", "pair_final_fable"})
        self.assertEqual([role for role, _ in original.calls], ["code", "coordinate", "publish"])
        self.assertEqual(self.repo.remote_head("origin"), self.state["published"]["sha"])
        self.assertNotEqual(self.repo.text("rev-parse", "HEAD"), self.state["baseline"]["head"])
        self.assertFalse(self.repo.dirty_paths())

    def test_green_ci_pause_keeps_task_and_explicit_resume_advances_once(self):
        self.prepare_ci()
        request_stage_stop(self.store)
        sha = self.state["published"]["sha"]
        records = [{"name": "CI", "head_sha": sha, "status": "completed", "conclusion": "success", "run_id": 1}]
        with patch.object(self.cycle, "ci_gate", return_value={"verdict": "ready"}), \
                patch.object(self.cycle, "github", return_value=("github.com", "owner/repo")), \
                patch("cycle_workflow.command"), patch("cycle_workflow.time.sleep"), \
                patch.object(self.cycle, "gh_records", return_value=records):
            self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(self.state["task"]["id"], "S2-15e2")
        self.assertEqual(self.state["display_ci"]["status"], "ready")
        self.assertFalse(self.transport.calls)
        saved = self.store.read()
        resumed = Cycle(self.repo, self.store, saved, self.transport, lambda: None, fixtures.REPO / "tools", "pwsh")
        self.transport.actions = [("coordinate", fixtures.report(status="complete"))]
        with patch.object(resumed, "wait_ci", side_effect=AssertionError("Completed CI must not repeat")):
            self.assertEqual(resumed.run(), 0)
        self.assertEqual(saved["iteration"], 2)
        self.assertNotIn("stage_completed", saved)
        self.assertIsNone(stage_stop_request(self.store, saved))
        archive = json.loads((self.store.directory / "iterations/000001.json").read_text())
        self.assertEqual(archive["stage_completed"]["sha"], sha)

    def test_request_during_ci_is_seen_at_the_final_boundary(self):
        self.prepare_ci()
        with patch.object(self.cycle, "wait_ci", side_effect=lambda: request_stage_stop(self.store)):
            self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(self.state["iteration"], 1)
        self.assertTrue(self.cycle.stage_completed())

    def test_cancel_allows_normal_advance_and_old_request_cannot_stop_new_iteration(self):
        self.prepare_ci()
        request_stage_stop(self.store)
        request_stage_stop(self.store, cancel=True)
        self.transport.actions = [("coordinate", fixtures.report(status="complete"))]
        with patch.object(self.cycle, "wait_ci"):
            self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(self.state["iteration"], 2)
        self.assertFalse(self.state.get("stage_completed"))
        self.assertIsNone(stage_stop_request(self.store, self.state))

    def test_failed_ci_preserves_request_and_never_claims_completion(self):
        self.prepare_ci()
        request_stage_stop(self.store)
        self.transport.actions = [("heal", fixtures.report(status="blocked"))]
        with patch.object(self.cycle, "wait_ci", side_effect=Blocked("ci-failed", "CI failed")):
            self.assertEqual(self.cycle.run(), 3)
        self.assertEqual(self.state["iteration"], 1)
        self.assertFalse(self.state.get("stage_completed"))
        self.assertIsNotNone(stage_stop_request(self.store, self.state))
        self.state.update(blocker=None, pending=None, status="ready")
        with patch.object(self.cycle, "wait_ci"):
            self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(self.state["status"], "paused")
        self.assertEqual([role for role, _ in self.transport.calls], ["heal"])

    def test_safe_and_emergency_stops_still_take_precedence(self):
        self.store.save(self.state)
        request_stage_stop(self.store)
        control = self.focus_control()
        self.stop_request(control)
        self.assertEqual(self.cycle.run(), 0)
        self.assertIsNotNone(stage_stop_request(self.store, self.state))
        self.assertFalse(self.transport.calls)
        self.stop_request(control, "now")
        from focus_control import FocusStop
        with self.assertRaises(FocusStop):
            self.cycle.run()
        self.assertIsNotNone(stage_stop_request(self.store, self.state))

    def test_pause_switch_and_new_run_identity_keep_scheduled_stage_pause(self):
        self.prepare_ci()
        request_stage_stop(self.store)
        first = self.focus_control()
        next_run = self.focus_control()
        self.assertNotEqual(first.active["nonce"], next_run.active["nonce"])
        # In code, an operator PAUSE still stops before any provider.
        self.state.update(phase="code", published=None)
        (self.root / ".work/PAUSE").write_text("operator pause")
        self.assertEqual(self.cycle.run(), 0)
        self.assertFalse(self.transport.calls)
        self.assertIsNotNone(stage_stop_request(self.store, self.state))

    def test_request_cannot_cross_an_iteration_transition(self):
        self.prepare_ci()
        entered = threading.Event()
        failures = []
        def late_request():
            entered.set()
            try:
                request_stage_stop(self.store, expected_iteration=1)
            except Blocked as error:
                failures.append(error.code)
        with stage_stop_lock(self.store):
            worker = threading.Thread(target=late_request)
            worker.start()
            self.assertTrue(entered.wait(2))
            self.state["iteration"] = 2
            self.store.save(self.state)
        worker.join(3)
        self.assertFalse(worker.is_alive())
        self.assertEqual(failures, ["finish-stage-changed"])
        self.assertFalse((self.store.directory / "finish-stage.json").exists())

    def test_pending_request_prevents_advance_even_if_arriving_after_final_git_check(self):
        self.prepare_ci()
        verify = self.cycle.assert_publication_current
        def checked():
            verify()
            request_stage_stop(self.store)
        with patch.object(self.cycle, "assert_publication_current", side_effect=checked):
            self.assertFalse(self.cycle.next_stage())
        self.assertEqual(self.state["iteration"], 1)

    def test_resume_rejects_uncommitted_changes_and_review_reset_discards_completion(self):
        self.prepare_ci()
        request_stage_stop(self.store)
        with patch.object(self.cycle, "wait_ci"):
            self.assertEqual(self.cycle.run(), 0)
        self.edit(content="late drift\n")()
        with self.assertRaises(Blocked) as caught:
            self.cycle.next_stage()
        self.assertEqual(caught.exception.code, "stage-base-dirty")
        self.cycle.reset_reviews()
        self.assertNotIn("stage_completed", self.state)
        self.assertIsNotNone(stage_stop_request(self.store, self.state))

    def pause_after_the_stage(self):
        self.prepare_ci()
        request_stage_stop(self.store)
        with patch.object(self.cycle, "wait_ci"):
            self.assertEqual(self.cycle.run(), 0)
        self.assertTrue(self.cycle.stage_completed())

    def operator_commit(self, name="plan.md", push=True):
        (self.root / name).write_text("Plan corrected between stages\n", encoding="utf-8")
        self.repo.git("add", name)
        self.repo.git("commit", "-m", "Correct the plan")
        if push:
            self.repo.git("push", "origin", "main")
        return self.repo.text("rev-parse", "HEAD")

    def resume(self):
        resumed = Cycle(self.repo, self.store, self.store.read(), self.transport, lambda: None, fixtures.REPO / "tools", "pwsh")
        with patch.object(resumed, "wait_ci", side_effect=AssertionError("Completed CI must not repeat")), \
                contextlib.redirect_stdout(io.StringIO()):
            code = resumed.run()
        self.assertNotIn("heal", [role for role, _ in self.transport.calls])
        return code, resumed.state

    def test_resume_accepts_pushed_operator_commits_and_protected_work_changes(self):
        self.edit(name="operator.txt", content="Operator notes\n")()
        self.state = self.cycle.state = fresh_state(self.repo)
        self.assertEqual(self.state["protected"], ["operator.txt"])
        self.pause_after_the_stage()
        head = self.operator_commit()
        self.edit(name="operator.txt", content="Operator notes, revised between stages\n")()
        self.repo.git("add", "operator.txt")  # The operator also stages the protected work.
        self.assertEqual(self.store.read()["protected_index"], {})
        self.transport.actions = [("coordinate", fixtures.report(status="complete"))]
        code, state = self.resume()
        self.assertEqual((code, state["iteration"], state["status"]), (0, 2, "complete"))
        self.assertIsNone(state["blocker"])
        self.assertEqual(state["baseline"]["head"], head)
        self.assertEqual(state["protected"], ["operator.txt"])
        self.assertEqual(state["protected_index"], self.repo.index_entries(["operator.txt"]))
        self.assertTrue(state["protected_index"])

    def test_resume_stops_for_the_operator_when_main_is_not_the_published_stage_base(self):
        cases = {
            "stage-base-unpublished": lambda: self.operator_commit(push=False),
            "stage-base-dirty": self.edit(name="draft.md", content="Uncommitted draft\n"),
            "stage-base-drift": lambda: (self.repo.git("reset", "--hard", "HEAD~1"),
                                         self.repo.git("push", "--force", "origin", "main")),
        }
        for code, change in cases.items():
            with self.subTest(code=code):
                self.tearDown()
                self.setUp()
                self.pause_after_the_stage()
                change()
                exit_code, state = self.resume()
                blocker = state["blocker"]
                self.assertEqual((exit_code, blocker["code"], blocker["status"], blocker["escalation_reason"]),
                                 (3, code, "blocked", "stage-boundary"))
                self.assertIn("Then run cc-focus --retry.", blocker["message"])
                self.assertEqual(state["iteration"], 1)

    def test_any_failure_at_the_completed_stage_boundary_stops_without_a_healer(self):
        # One failure is in a check of main. The other is in a later step of the same transition.
        for target, code in (("remote_head", "remote-query-failed"), ("index_entries", "index-read-failed")):
            with self.subTest(failure=code):
                self.tearDown()
                self.setUp()
                self.edit(name="operator.txt", content="Operator notes\n")()
                self.state = self.cycle.state = fresh_state(self.repo)
                self.pause_after_the_stage()
                self.operator_commit()
                self.edit(name="operator.txt", content="Operator notes, revised between stages\n")()
                # A healer call fails the fixture: only the coordinator of the next stage may run.
                self.transport.actions = [("coordinate", fixtures.report(status="complete"))]
                with patch("cycle_state.Repository." + target, side_effect=Blocked(code, "Git is unavailable.")):
                    exit_code, state = self.resume()
                blocker = state["blocker"]
                self.assertEqual((exit_code, blocker["code"], blocker["escalation_reason"]), (3, code, "stage-boundary"))
                state.update(blocker=None, status="ready")  # The operator restores Git access and runs --retry.
                self.store.save(state)
                exit_code, state = self.resume()
                self.assertEqual((exit_code, state["iteration"], state["status"]), (0, 2, "complete"))
                self.assertEqual([role for role, _ in self.transport.calls], ["coordinate"])

    def test_terminal_command_status_and_cancel_do_not_steer_or_answer_approval(self):
        self.store.save(self.state)
        control = self.focus_control()
        display = Display()
        interaction = Interaction(display)
        interaction.bind(control, self.state, self.store.save)
        interaction.approval = {"command": "operator check"}
        interaction.submit("/finish-stage")
        self.assertIsNone(interaction.approval_answer)
        self.assertIsNone(control.request())
        self.assertFalse(interaction.messages.records(1))
        self.assertIn("пауза после этапа и CI", "\n".join(interaction.panel().lines))
        self.assertIn("НУЖНО СОГЛАСИЕ", "\n".join(interaction.panel().lines))
        self.assertIsNotNone(status(self.store, self.state)["finish_stage"])
        interaction.unbind()
        interaction.submit("/finish-stage cancel")
        self.assertIsNone(stage_stop_request(self.store, self.state))
        self.assertTrue(interaction.commands.empty())

    def test_completed_stage_panel_keeps_title_and_explains_resume(self):
        self.prepare_ci()
        request_stage_stop(self.store)
        with patch.object(self.cycle, "wait_ci"):
            self.cycle.run()
        panel = build_panel(self.state, paused=True)
        self.assertIn("S2-15e2", panel.lines[0])
        self.assertIn("ЭТАП ЗАВЕРШЁН", panel.lines[1])
        self.assertIn("начать следующий этап", panel.lines[-1])
        with self.assertRaisesRegex(Blocked, "already complete"):
            request_stage_stop(self.store)

    def test_panel_does_not_read_files_and_tick_caches_external_requests(self):
        self.store.save(self.state)
        interaction = Interaction(Display())
        interaction.bind(self.focus_control(), self.state, self.store.save)
        request_stage_stop(self.store)
        with patch("focus_input.time.monotonic", return_value=interaction.stage_request_updated + 2), \
                patch("focus_input.stage_stop_request", wraps=stage_stop_request) as read:
            for _ in range(20):
                interaction.panel()
            read.assert_not_called()
            for _ in range(20):
                interaction.tick()
            read.assert_called_once()
        self.assertIn("пауза после этапа и CI", "\n".join(interaction.panel().lines))

    def test_cli_schedules_without_runtime_ownership_or_provider_and_rejects_invalid_flags(self):
        import cc_focus
        self.store.save(self.state)
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.Control", side_effect=AssertionError), \
                patch("cc_focus.Transport", side_effect=AssertionError), patch("cc_focus.Lease", side_effect=AssertionError):
            self.assertEqual(cc_focus.main(["finish-stage"]), 0)
            self.assertIsNotNone(stage_stop_request(self.store, self.state))
            self.assertEqual(cc_focus.main(["finish-stage", "--cancel"]), 0)
        for args in (["--cancel"], ["finish-stage", "--now"], ["finish-stage", "--retry"], ["finish-stage", "--timeout", "1"]):
            with self.subTest(args=args), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                cc_focus.main(args)

    def test_wrapper_schedules_without_a_processkit_root(self):
        self.store.save(self.state)
        config = Path(self.temp.name) / "isolated-config"
        config.mkdir()
        (config / "root-config.md").write_text("CC_PROCESSKIT_CLI: off\n")
        result = subprocess.run(["pwsh", "-NoProfile", "-File", str(fixtures.REPO / "tools/focus-runtime.ps1"), "finish-stage"],
                                cwd=self.root, env=dict(os.environ, ORCHESTRA_HOME=str(config)), capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(stage_stop_request(self.store, self.state))

    def test_missing_state_completed_plan_and_damaged_requests_are_not_accepted(self):
        with self.assertRaises(Blocked):
            request_stage_stop(self.store)
        self.state["status"] = "complete"
        self.store.save(self.state)
        with self.assertRaises(Blocked):
            request_stage_stop(self.store)
        self.state["status"] = "ready"
        self.store.save(self.state)
        for value in ([], {"iteration": True, "enabled": True}, {"iteration": 1, "enabled": "yes"}):
            (self.store.directory / "finish-stage.json").write_text(json.dumps(value))
            with self.assertRaises(Blocked):
                request_stage_stop(self.store)

    def test_command_rejects_an_active_runtime_without_support(self):
        self.store.save(self.state)
        self.store.artifact("active.json", encode({"nonce": "old-runtime"}))
        with LocalLock(self.store.directory), self.assertRaisesRegex(Blocked, "does not support"):
            request_stage_stop(self.store)
        self.assertFalse((self.store.directory / "finish-stage.json").exists())
        self.focus_control()
        with LocalLock(self.store.directory):
            request_stage_stop(self.store)
        self.assertIsNotNone(stage_stop_request(self.store, self.state))

    def test_plan_exhaustion_retires_the_request_before_a_later_handoff(self):
        self.store.save(self.state)
        request_stage_stop(self.store)
        self.transport.actions = [("coordinate", fixtures.report(status="complete"))]
        self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(self.state["status"], "complete")
        self.assertIsNone(stage_stop_request(self.store, self.state))
        self.assertFalse(self.state.get("stage_completed"))
        self.state["status"] = "ready"
        self.assertIsNone(stage_stop_request(self.store, self.state))

    def test_cancellation_after_completion_cannot_rearm_on_review_reset(self):
        self.prepare_ci()
        request_stage_stop(self.store)
        with patch.object(self.cycle, "wait_ci"):
            self.cycle.run()
        request_stage_stop(self.store, cancel=True)
        self.assertEqual(self.state["status"], "paused")
        self.cycle.reset_reviews()
        self.assertIsNone(stage_stop_request(self.store, self.state))


class ProjectFinishStageTests(unittest.TestCase):
    setUp = project_fixtures.ProjectTests.setUp
    tearDown = project_fixtures.ProjectTests.tearDown
    edit = project_fixtures.ProjectTests.edit
    seal = project_fixtures.ProjectTests.seal
    commit = project_fixtures.ProjectTests.commit

    def test_all_changed_repositories_publish_and_pass_ci_before_pause(self):
        self.seal()
        self.store.save(self.state)
        request_stage_stop(self.store)
        self.transport.actions = [("publish", fixtures.report())]
        self.assertEqual(self.cycle.run(), 0)
        self.assertEqual((self.state["iteration"], self.state["status"]), (1, "paused"))
        self.assertEqual(self.state["display_ci"]["passed"], 2)
        self.assertEqual(set(self.state["published"]["repositories"]), {"Core", "Specification"})
        for name in ("Core", "Specification"):
            self.assertEqual(self.members[name].remote_head("origin"), self.members[name].text("rev-parse", "HEAD"))
        self.assertTrue(self.cycle.stage_completed())
        self.assertEqual([role for role, _ in self.transport.calls], ["publish"])

    def pause_after_the_project_stage(self):
        self.seal()
        self.store.save(self.state)
        request_stage_stop(self.store)
        self.transport.actions = [("publish", fixtures.report())]
        self.assertEqual(self.cycle.run(), 0)
        self.assertTrue(self.cycle.stage_completed())

    def resume_project(self):
        from focus_publication import ProjectCycle
        resumed = ProjectCycle(self.project, self.store, self.store.read(), self.transport, lambda: None,
                               fixtures.REPO / "tools", "pwsh")
        with contextlib.redirect_stdout(io.StringIO()):
            code = resumed.run()
        self.assertNotIn("heal", [role for role, _ in self.transport.calls])
        return code, resumed.state

    def test_resume_accepts_pushed_commits_in_published_and_other_repositories(self):
        self.pause_after_the_project_stage()
        for name in ("Core", "Root"):
            self.edit(name, file="plan.md", text="Plan corrected between stages\n")
            self.commit(name, file="plan.md")
        self.transport.actions = [("coordinate", fixtures.report(status="complete"))]
        code, state = self.resume_project()
        self.assertEqual((code, state["iteration"], state["status"]), (0, 2, "complete"))
        for name in ("Core", "Root"):
            self.assertEqual(state["baseline"]["head"][name], self.members[name].text("rev-parse", "HEAD"))

    def test_resume_stops_for_an_unpushed_commit_in_any_repository(self):
        for name in ("Core", "Root"):  # Core was published; Root was outside the publication.
            with self.subTest(repository=name):
                self.tearDown()
                self.setUp()
                self.pause_after_the_project_stage()
                self.edit(name, file="plan.md", text="Local plan\n")
                self.commit(name, push=False, file="plan.md")
                code, state = self.resume_project()
                self.assertEqual((code, state["blocker"]["code"], state["blocker"]["escalation_reason"]),
                                 (3, "stage-base-unpublished", "stage-boundary"))
                self.assertTrue(state["blocker"]["message"].startswith(name + ": Local main and remote main differ"))

    def test_resume_stops_when_a_published_repository_lost_its_stage_commit(self):
        self.pause_after_the_project_stage()
        core = self.members["Core"]
        core.git("reset", "--hard", "HEAD~1")
        core.git("push", "--force", "origin", "main")
        self.assertEqual(core.text("rev-parse", "HEAD"), self.store.read()["baseline"]["head"]["Core"])
        code, state = self.resume_project()
        self.assertEqual((code, state["blocker"]["code"], state["blocker"]["escalation_reason"]),
                         (3, "stage-base-drift", "stage-boundary"))
        self.assertTrue(state["blocker"]["message"].startswith("Core: Main no longer contains commit"))

    def test_failed_member_ci_preserves_stage_request(self):
        from focus_publication import MemberCycle
        self.seal()
        self.store.save(self.state)
        request_stage_stop(self.store)
        self.transport.actions = [("publish", fixtures.report()), ("heal", fixtures.report(status="blocked"))]
        original = MemberCycle.wait_ci
        def check(member):
            if member.name == "Specification":
                raise Blocked("ci-failed", "Member CI failed")
            return original(member)
        with patch.object(MemberCycle, "wait_ci", check):
            self.assertEqual(self.cycle.run(), 3)
        self.assertEqual(self.state["display_ci"]["passed"], 1)
        self.assertEqual(self.state["iteration"], 1)
        self.assertFalse(self.state.get("stage_completed"))
        self.assertIsNotNone(stage_stop_request(self.store, self.state))


if __name__ == "__main__":
    unittest.main()
