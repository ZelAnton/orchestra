"""Explicit publication recovery against disposable repositories and remotes."""

import copy
import json
import unittest
from unittest.mock import patch

import test_cycle as fixtures
import test_focus_project as project_fixtures
from cycle_state import Blocked, LocalLock, encode
from cycle_workflow import fresh_state
import focus_publication_recovery as recovery
import focus_reconcile


class PublicationRecoveryTests(unittest.TestCase):
    setUp = project_fixtures.ProjectTests.setUp
    tearDown = project_fixtures.ProjectTests.tearDown
    edit = project_fixtures.ProjectTests.edit
    seal = project_fixtures.ProjectTests.seal
    commit = project_fixtures.ProjectTests.commit

    def publication(self):
        core = self.members["Core"]
        self.edit("Core", "tracked.txt", "committed baseline\n")
        core.git("add", "tracked.txt")
        core.git("commit", "-m", "Add original tracked content")
        core.git("push", "origin", "main")
        self.edit("Core", "tracked.txt", "preexisting operator edit\n")
        self.edit("Core", "operator.txt", "preexisting untracked work\n")
        self.edit("Root", "staged.txt", "other staged work\n")
        self.members["Root"].git("add", "staged.txt")
        self.state = fresh_state(self.project)
        self.cycle.state = self.state
        self.seal()
        self.edit("Specification", "missing.zip", "reviewed archive\n")
        self.state.update(reviewed=self.project.snapshot(), code_started=True,
                          task={"id": "current", "iteration": 1, "plan": "Core/PLAN.md", "title": "Current stage"},
                          code_report="Original completed coding report", sessions={"sol": "old-review-session"})
        self.cycle.prepare_publish()
        core.git("add", "source.txt", "operator.txt", "tracked.txt")
        core.git("commit", "-m", "Publish expanded scope")
        core.git("push", "origin", "main")
        self.commit("Specification")
        self.state.update(phase="publish", status="blocked", publication_started=True,
                          publication_prepared={"subject": "Old subject", "reviewed_sha256": "old"})
        self.store.save(self.state)
        return self.root / ".work/publication-recovery.json"

    def test_acceptance_preserves_work_history_sessions_and_restarts_both_reviews(self):
        path = self.publication()
        before = self.project.snapshot()
        old = copy.deepcopy(self.state)
        plan = recovery.write_plan(self.cycle, path)
        self.assertEqual([row["path"] for row in plan["changes"]], ["Core/operator.txt", "Core/tracked.txt"])
        self.assertEqual(self.state, old)
        with self.assertRaisesRegex(Blocked, "before publication"):
            focus_reconcile.prepare(self.cycle)
        recovery.apply(self.cycle, path)
        self.assertEqual(self.project.snapshot(), before)
        self.assertEqual(self.state["baseline"]["head"], old["baseline"]["head"])
        self.assertNotEqual(self.state["baseline"]["files"]["Core/tracked.txt"], old["baseline"]["files"]["Core/tracked.txt"])
        self.assertNotIn("Core/operator.txt", self.state["baseline"]["files"])
        self.assertEqual(self.state["sessions"], old["sessions"])
        self.assertEqual(self.state["task"], old["task"])
        self.assertEqual((self.state["phase"], self.state["status"]), ("sol", "paused"))
        self.assertEqual((self.state["sol_passes"], self.state["sol_clean"], self.state["claude_clean"]), (0, 0, 0))
        self.assertIsNone(self.state["reviewed"])
        self.assertIsNone(self.state["published"])
        self.assertIsNone(self.state["correction_pending"])
        self.assertNotIn("publication_prepared", self.state)
        self.assertTrue(self.state["publication_started"])
        self.cycle.check_protected(before)
        self.assertEqual(self.transport.calls, [])
        correction = self.state["corrections"][-1]
        self.assertTrue(correction["publication_recovery"])
        archive = json.loads(fixtures.Path(correction["archive"]).read_text())
        self.assertEqual(archive["previous_state"], old)
        self.assertEqual(archive["publication_reconciliation"], plan)
        self.assertIn('"publication_recovery"', self.cycle.context("sol"))
        done = fixtures.report()
        self.transport.actions = [("coordinate", done), ("sol", done), ("sol", done), ("sol", done),
            ("coordinate", done), ("claude", done), ("claude", done), ("coordinate", done), ("astra", done),
            ("coordinate", done), ("publish", done),
            ("coordinate", fixtures.report(status="complete"))]
        self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(self.members["Core"].text("rev-parse", "HEAD"), before["head"]["Core"])
        self.assertEqual(self.members["Root"].text("rev-parse", "HEAD"), before["head"]["Root"])
        self.assertNotEqual(self.members["Specification"].text("rev-parse", "HEAD"), before["head"]["Specification"])
        self.assertEqual(self.members["Specification"].git("show", "HEAD:missing.zip").stdout, b"reviewed archive\n")
        self.assertEqual(self.members["Root"].text("diff", "--cached", "--name-only"), "staged.txt")

    def test_rejects_changed_work_and_protected_staging(self):
        self.publication()
        before = copy.deepcopy(self.state)
        self.edit("Core", "source.txt", "new unreviewed edit")
        with self.assertRaisesRegex(Blocked, "differ from the reviewed"):
            recovery.prepare(self.cycle)
        self.edit("Core", "source.txt", "changed\n")
        self.members["Root"].git("restore", "--staged", "staged.txt")
        with self.assertRaisesRegex(Blocked, "outside the proposed"):
            recovery.prepare(self.cycle)
        self.assertEqual(self.state, before)

    def test_rejects_staging_on_an_adopted_path_even_if_worktree_matches(self):
        self.publication()
        self.edit("Core", "operator.txt", "different staged version")
        self.members["Core"].git("add", "operator.txt")
        self.edit("Core", "operator.txt", "preexisting untracked work\n")
        with self.assertRaisesRegex(Blocked, "staging beyond"):
            recovery.prepare(self.cycle)

    def test_does_not_adopt_shared_context_even_if_a_prior_review_included_it(self):
        self.publication()
        (self.root / "HANDOFF.md").write_text("changed shared context")
        self.state["reviewed"] = self.project.snapshot()
        with self.assertRaisesRegex(Blocked, "shared context outside"):
            recovery.prepare(self.cycle)

    def test_rejects_unpublished_head(self):
        path = self.publication()
        recovery.write_plan(self.cycle, path)
        self.members["Core"].git("commit", "--allow-empty", "-m", "Unpublished commit")
        before = copy.deepcopy(self.state)
        with self.assertRaisesRegex(Blocked, "live remote main"):
            recovery.apply(self.cycle, path)
        self.assertEqual(self.state, before)

    def test_rejects_live_remote_drift_after_plan_preparation(self):
        path = self.publication()
        recovery.write_plan(self.cycle, path)
        before = copy.deepcopy(self.state)
        fixtures.subprocess.run(["git", "--git-dir", str(self.remotes["Core"]), "update-ref", "refs/heads/main",
                                 self.state["baseline"]["head"]["Core"]], check=True, capture_output=True)
        with self.assertRaisesRegex(Blocked, "live remote main"):
            recovery.apply(self.cycle, path)
        self.assertEqual(self.state, before)

    def test_rechecks_work_after_slow_remote_verification(self):
        self.publication()
        member = self.project.repositories["Specification"]
        query = member.remote_head
        def changed_during_query(*args, **kwargs):
            result = query(*args, **kwargs)
            self.edit("Specification", "missing.zip", "concurrent edit after initial snapshot")
            return result
        before = copy.deepcopy(self.state)
        with patch.object(member, "remote_head", side_effect=changed_during_query), self.assertRaisesRegex(Blocked, "during publication verification"):
            recovery.prepare(self.cycle)
        self.assertEqual(self.state, before)

    def test_rejects_committed_bytes_different_from_preserved_reviewed_work(self):
        self.publication()
        self.edit("Core", "operator.txt", "unreviewed committed content")
        self.commit("Core", file="operator.txt")
        self.edit("Core", "operator.txt", "preexisting untracked work\n")
        with self.assertRaisesRegex(Blocked, "Published adopted content differs"):
            recovery.prepare(self.cycle)

    def test_rejects_extra_intermediate_paths_outside_protected_work(self):
        self.publication()
        core = self.members["Core"]
        self.edit("Core", "foreign.txt", "intermediate unreviewed data")
        core.git("add", "foreign.txt")
        core.git("commit", "-m", "Add intermediate content")
        core.git("rm", "foreign.txt")
        core.git("commit", "-m", "Remove intermediate content")
        core.git("push", "origin", "main")
        with self.assertRaisesRegex(Blocked, "outside protected"):
            recovery.prepare(self.cycle)

    def test_rejects_stale_or_tampered_plan_and_wrong_mode(self):
        path = self.publication()
        plan = recovery.write_plan(self.cycle, path)
        before = copy.deepcopy(self.state)
        with self.assertRaisesRegex(Blocked, "unsupported reconciliation plan"):
            focus_reconcile.apply(self.cycle, path)
        for field, value in (("changes", []), ("iteration", True)):
            edited = copy.deepcopy(plan)
            edited[field] = value
            path.write_bytes(encode(edited))
            with self.assertRaisesRegex(Blocked, "changed since preparation"):
                recovery.apply(self.cycle, path)
            self.assertEqual(self.state, before)
        path.write_bytes(encode(plan))
        self.state["sol_clean"] = 0
        with self.assertRaisesRegex(Blocked, "changed since preparation"):
            recovery.apply(self.cycle, path)

    def test_rechecks_after_archiving_and_preserves_failed_save_state(self):
        path = self.publication()
        recovery.write_plan(self.cycle, path)
        before = copy.deepcopy(self.state)
        write = self.store.artifact
        def mutate(relative, data):
            result = write(relative, data)
            if relative.endswith(".md"):
                self.edit("Specification", "missing.zip", "concurrent change")
            return result
        with patch.object(self.store, "artifact", side_effect=mutate), self.assertRaises(Blocked):
            recovery.apply(self.cycle, path)
        self.assertEqual(self.state, before)
        self.assertEqual(self.store.read(), before)
        self.edit("Specification", "missing.zip", "reviewed archive\n")
        with patch.object(self.store, "save", side_effect=OSError("failed persistence")), self.assertRaises(OSError):
            recovery.apply(self.cycle, path)
        self.assertEqual(self.state, before)
        self.assertEqual(self.store.read(), before)

    def test_respects_phase_pause_messages_and_cli_lock_without_a_provider(self):
        import cc_focus
        path = self.publication()
        for phase in ("code", "sol", "ci"):
            self.state["phase"] = phase
            with self.assertRaisesRegex(Blocked, "stopped, already-started publication"):
                recovery.prepare(self.cycle)
        self.state["phase"] = "publish"
        with patch.object(self.cycle.messages, "unresolved", return_value=[{}]), self.assertRaisesRegex(Blocked, "operator messages"):
            recovery.prepare(self.cycle)
        with patch.object(self.project, "paused", return_value=True), self.assertRaisesRegex(Blocked, "PAUSE"):
            recovery.prepare(self.cycle)
        with LocalLock(self.store.directory), patch("cc_focus.Path.cwd", return_value=self.root), \
                fixtures.contextlib.redirect_stderr(fixtures.io.StringIO()):
            self.assertEqual(cc_focus.main(["reconcile", "--publication"]), 3)
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.ProjectLease") as lease, \
                patch("cycle_transport.Transport.run", side_effect=AssertionError("No provider in operator recovery")):
            lease.return_value.__enter__.return_value.pwsh = "pwsh"
            self.assertEqual(cc_focus.main(["reconcile", "--publication", "--plan-out", str(path)]), 0)
            self.assertEqual(cc_focus.main(["reconcile", "--publication", "--apply-plan", str(path)]), 0)
        self.assertEqual((self.store.read()["phase"], self.store.read()["status"]), ("sol", "paused"))

    def test_publication_flag_requires_reconciliation(self):
        import cc_focus
        with fixtures.contextlib.redirect_stderr(fixtures.io.StringIO()), self.assertRaises(SystemExit):
            cc_focus.main(["--publication"])


class SinglePublicationRecoveryTests(unittest.TestCase):
    setUp = fixtures.CycleTests.setUp
    tearDown = fixtures.CycleTests.tearDown
    remote = fixtures.CycleTests.remote
    edit = fixtures.CycleTests.edit

    def test_single_repository_acceptance_keeps_original_baseline_and_unrelated_staging(self):
        self.remote()
        self.edit("operator.txt", "preexisting content")()
        self.edit("staged.txt", "separate staging")()
        self.repo.git("add", "staged.txt")
        self.state = fresh_state(self.repo)
        self.cycle.state = self.state
        self.edit()()
        self.state.update(phase="publish", status="blocked", code_started=True, publication_started=True,
                          reviewed=self.repo.snapshot(), remote="origin")
        self.repo.git("add", "operator.txt", "source.txt")
        self.repo.git("commit", "--only", "-m", "Publish an extra file", "--", "operator.txt", "source.txt")
        self.repo.git("push", "origin", "main")
        self.store.save(self.state)
        before = self.repo.snapshot()
        baseline = self.state["baseline"]["head"]
        path = self.root / ".work/accept-publication.json"
        recovery.write_plan(self.cycle, path)
        recovery.apply(self.cycle, path)
        self.assertEqual(self.repo.snapshot(), before)
        self.assertEqual(self.state["baseline"]["head"], baseline)
        self.assertEqual(self.state["phase"], "sol")
        self.cycle.check_protected(before)
        self.assertEqual(self.repo.text("diff", "--cached", "--name-only"), "staged.txt")


if __name__ == "__main__":
    unittest.main()
