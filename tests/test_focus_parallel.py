"""Parallel member repositories with local Git remotes and a second clone for another writer; no paid provider calls."""

import contextlib
import io
import json
import re
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

import test_cycle as fixtures
from cycle_state import Blocked, Repository, Store, digest, encode
from cycle_workflow import ESCALATION_REASONS, fresh_state
from focus_commit import commit_reviewed
import focus_parallel
from focus_project import open_project, parallel_members
from focus_publication import MemberCycle, ProjectCycle
from test_focus_project import SPLIT_FILES, SPLIT_PLAN, add_member, project_context, runtime_assignment

PARALLEL = ["Interlink-docs", "Interlink-plans"]
MEMBERS = ["Interlink", "Interlink-docs", "Interlink-plans"]
# Empty lines keep the stage status away from the text of other writers. Git merges such edits.
PLAN = ("# S2 adaptation\n\n## Stage 1\n\nStatus: open.\n\n## Stage 2\n\nStatus: open.\n\n"
        "## Notes\n\nOther writers edit this part.\n")
DONE = PLAN.replace("## Stage 1\n\nStatus: open.", "## Stage 1\n\nStatus: complete.")
PLAN_FILE = "plan/s2-adaptation.md"


class ParallelFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="focus-parallel-")
        self.root = Path(self.temp.name) / "Interlink"
        self.root.mkdir()
        self.root = self.root.resolve()
        self.members, self.remotes, self.other = {}, {}, {}
        files = dict(SPLIT_FILES, **{"Interlink-plans": dict(SPLIT_FILES["Interlink-plans"], **{PLAN_FILE: PLAN})})
        for name in MEMBERS:
            add_member(self, name, files[name])
        self.manifest(PARALLEL)
        for name in PARALLEL:
            clone = Path(self.temp.name) / ("other-" + name)
            subprocess.run(["git", "clone", "-q", "-b", "main", str(self.remotes[name]), str(clone)], check=True, capture_output=True)
            repo = Repository(clone)
            repo.git("config", "user.name", "Other")
            repo.git("config", "user.email", "other@example.invalid")
            self.other[name] = repo
        self.open()
        self.policy = patch.object(MemberCycle, "policy", return_value=subprocess.CompletedProcess(
            [], 0, b'{"verdict":"no-required-checks"}', b""))
        self.policy.start()
        self.quiet = contextlib.redirect_stdout(io.StringIO())
        self.quiet.__enter__()

    def tearDown(self):
        self.quiet.__exit__(None, None, None)
        self.policy.stop()
        self.temp.cleanup()

    def manifest(self, parallel):
        (self.root / "focus-project.json").write_text(json.dumps({"version": 1, "repositories": MEMBERS, "parallel": parallel}))

    def open(self, state=None):
        self.project = open_project(self.root)
        self.store = Store(self.root)
        self.state = state or fresh_state(self.project)
        self.transport = fixtures.FixtureTransport(self.root)
        self.cycle = ProjectCycle(self.project, self.store, self.state, self.transport, lambda: None,
                                  fixtures.REPO / "tools", "pwsh")
        return self.cycle

    def push_other(self, name, path, text, message="Other writer"):
        """Another writer changes PATH in its own clone and pushes to remote main. TEXT None deletes PATH."""
        repo = self.other[name]
        repo.git("pull", "-q", "--ff-only")
        file = repo.root / path
        if text is None:
            repo.git("rm", "-q", path)
        else:
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(text)
            repo.git("add", "-A")
        repo.git("commit", "-qm", message)
        repo.git("push", "-q", "origin", "main")
        return repo.text("rev-parse", "HEAD")

    def push_submodule(self, name, path="vendor/sub", remove=False):
        repo = self.other[name]
        repo.git("pull", "-q", "--ff-only")
        if remove:
            repo.git("rm", "-q", "--cached", path)
        else:
            repo.git("update-index", "--add", "--cacheinfo", "160000," + repo.text("rev-parse", "HEAD") + "," + path)
        repo.git("commit", "-qm", "Submodule")
        repo.git("push", "-q", "origin", "main")

    def head(self, name):
        return self.members[name].text("rev-parse", "HEAD")

    def remote(self, name):
        return self.members[name].remote_head("origin")

    def text(self, name, path=PLAN_FILE):
        return (self.root / name / path).read_text()

    def review(self, code=True, plan=DONE):
        if code:
            (self.root / "Interlink/source.txt").write_text("stage change\n")
        if plan is not None:
            (self.root / "Interlink-plans" / PLAN_FILE).write_text(plan)
        reviewed = self.project.snapshot()
        self.state.update(phase="publish", coordinated="publish", reviewed=reviewed,
                          last_snapshot=reviewed, sol_clean=3, claude_clean=2)

    def publish(self, **kwargs):
        self.review(**kwargs)
        self.transport.actions = [("publish", fixtures.report(summary="Mark stage 1 complete"))]
        self.cycle.publish()

    def commit_only(self, **kwargs):
        """The state after commit_reviewed and before the integration and the push."""
        self.review(**kwargs)
        self.assertTrue(self.cycle.prepare_publish())
        self.state["publication_prepared"] = {"reviewed_sha256": digest(encode(self.cycle.snapshot(self.state["reviewed"]))),
                                              "subject": "Mark stage 1 complete"}
        for name in self.state["publication_targets"]:
            commit_reviewed(self.cycle.member(name), "Mark stage 1 complete")

    def blocked(self, call, code):
        with self.assertRaises(Blocked) as caught:
            call()
        self.assertEqual(caught.exception.code, code, str(caught.exception))
        return caught.exception


class ManifestTests(ParallelFixture):
    def test_the_manifest_lists_parallel_members_and_rejects_bad_lists(self):
        self.assertEqual(self.project.parallel, PARALLEL)
        self.assertEqual(self.state["parallel"], PARALLEL)
        for parallel in (["Unknown"], ["Interlink-docs", "Interlink-docs"], "Interlink-docs", [1]):
            with self.subTest(parallel=parallel):
                (self.root / "focus-project.json").write_text(json.dumps(
                    {"version": 1, "repositories": MEMBERS, "parallel": parallel}))
                self.blocked(lambda: parallel_members(self.root), "project-manifest")
        (self.root / "focus-project.json").write_text(json.dumps({"version": 1, "repositories": MEMBERS}))
        self.assertEqual(parallel_members(self.root), [])

    def test_a_manifest_change_becomes_active_at_the_next_stage_and_a_leaving_member_gets_a_last_sync(self):
        self.manifest(["Interlink-plans"])
        self.assertEqual(self.state["parallel"], PARALLEL)  # The stage keeps its record.
        pushed = self.push_other("Interlink-docs", "guide.md", "Docs of another writer.\n")
        changed = self.cycle.sync_parallel("cc-focus --retry")
        self.assertEqual(changed["Interlink-docs"], ["guide.md"])
        self.assertEqual(self.head("Interlink-docs"), pushed)
        self.cycle.advance_stage(self.cycle.snapshot(), [], {})
        self.assertEqual(self.state["parallel"], ["Interlink-plans"])


class SyncTests(ParallelFixture):
    def test_the_continuous_transition_syncs_every_parallel_member(self):
        self.publish(plan=None)
        self.assertEqual(set(self.state["published"]["repositories"]), {"Interlink"})
        self.cycle.wait_ci()
        plan = self.push_other("Interlink-plans", "plan/s3.md", "# S3\n")
        docs = self.push_other("Interlink-docs", "guide.md", "Guide.\n")
        self.assertTrue(self.cycle.next_stage())
        self.assertEqual(self.head("Interlink-plans"), plan)
        self.assertEqual(self.head("Interlink-docs"), docs)
        self.assertEqual(self.state["baseline"]["head"]["Interlink-plans"], plan)
        self.assertIn("Interlink-plans/plan/s3.md", self.state["baseline"]["files"])
        self.assertEqual(self.state["parallel"], PARALLEL)

    def test_the_transition_after_a_stage_pause_checks_the_base_and_syncs(self):
        import time
        self.publish()
        self.cycle.wait_ci()
        self.state.update(status="paused", stage_completed={"iteration": 1, "sha": self.state["published"]["sha"], "at": time.time()})
        published = self.state["published"]["repositories"]["Interlink-plans"]["sha"]
        pushed = self.push_other("Interlink-plans", "plan/s3.md", "# S3\n")
        self.assertTrue(self.cycle.next_stage())
        self.assertEqual(self.head("Interlink-plans"), pushed)
        self.assertEqual(self.members["Interlink-plans"].text("rev-parse", pushed + "^"), published)

    def test_a_dirty_member_stops_also_without_a_remote_change(self):
        (self.root / "Interlink-docs/draft.md").write_text("Operator draft.\n")
        error = self.blocked(lambda: self.cycle.sync_parallel("cc-focus --retry"), "parallel-dirty")
        self.assertIn("draft.md", str(error))
        self.assertIn("cc-focus --retry", str(error))
        (self.root / "Interlink-docs/draft.md").unlink()
        repo = self.members["Interlink-docs"]
        (repo.root / "AGENTS.md").write_text("Staged rules.\n")
        repo.git("add", "AGENTS.md")
        (repo.root / "AGENTS.md").write_text(SPLIT_FILES["Interlink-docs"]["AGENTS.md"])  # Only the index differs.
        self.blocked(lambda: self.cycle.sync_parallel("cc-focus --retry"), "parallel-dirty")

    def test_diverged_history_and_a_submodule_stop_without_a_move(self):
        repo = self.members["Interlink-plans"]
        before = self.head("Interlink-plans")
        repo.git("commit", "--allow-empty", "-qm", "Local operator commit")
        self.push_other("Interlink-plans", "plan/s3.md", "# S3\n")
        self.blocked(lambda: self.cycle.sync_parallel("cc-focus --retry"), "parallel-diverged")
        repo.git("reset", "-q", "--hard", before)
        self.push_submodule("Interlink-plans")
        error = self.blocked(lambda: self.cycle.sync_parallel("cc-focus --retry"), "parallel-unsupported-path")
        self.assertIn("vendor/sub", str(error))
        self.assertEqual(self.head("Interlink-plans"), before)

    def test_a_failed_fetch_reports_the_redacted_url(self):
        url = str(self.remotes["Interlink-docs"])
        self.members["Interlink-docs"].git("remote", "set-url", "origin", url + ".missing")
        error = self.blocked(lambda: self.cycle.sync_parallel("cc-focus --retry"), "remote-query-failed")
        self.assertNotIn(url, str(error))


class AdmissionTests(ParallelFixture):
    def test_a_new_state_syncs_and_takes_the_parallel_entries_again(self):
        pushed = self.push_other("Interlink-plans", PLAN_FILE, PLAN + "\n## Stage 3\n")
        self.state["coordinated"] = "coordinate"
        self.cycle.admit_parallel()
        self.assertEqual(self.head("Interlink-plans"), pushed)
        for key in ("baseline", "last_snapshot"):
            self.assertEqual(self.state[key]["head"]["Interlink-plans"], pushed)
            self.assertEqual(self.state[key]["files"]["Interlink-plans/" + PLAN_FILE],
                             self.project.snapshot()["files"]["Interlink-plans/" + PLAN_FILE])
        self.assertIsNone(self.state["coordinated"])
        self.assertEqual(self.store.read()["baseline"]["head"]["Interlink-plans"], pushed)

    def test_a_rerun_after_parallel_dirty_has_no_stale_protected_entries(self):
        (self.root / "Interlink-docs/draft.md").write_text("Operator draft.\n")
        (self.root / "Interlink/notes.txt").write_text("Exclusive operator work.\n")
        self.open()
        self.assertIn("Interlink-docs/draft.md", self.state["protected"])
        error = self.blocked(self.cycle.admit_parallel, "parallel-dirty")
        self.assertIn("the same cc-focus command", str(error))
        (self.root / "Interlink-docs/draft.md").unlink()
        self.cycle.admit_parallel()
        self.assertEqual(self.state["protected"], ["Interlink/notes.txt"])  # The exclusive entry stays.
        self.assertNotIn("Interlink-docs/draft.md", self.state["baseline"]["files"])

    def test_no_sync_after_coding_started_or_with_an_unfinished_invocation(self):
        before = self.head("Interlink-plans")
        self.push_other("Interlink-plans", "plan/s3.md", "# S3\n")
        for fields in ({"code_started": True}, {"pending": {"id": "open", "role": "coordinate"}}):
            with self.subTest(fields=fields):
                self.state.update({"code_started": False, "pending": None, **fields})
                self.cycle.admit_parallel()
                self.assertEqual(self.head("Interlink-plans"), before)

    def test_admission_reads_the_manifest_again_and_checks_git(self):
        self.manifest(["Interlink-plans"])
        self.cycle.admit_parallel()
        self.assertEqual(self.state["parallel"], ["Interlink-plans"])
        original = Repository.git

        def without_merge_tree(repo, *args, check=True):
            if args[:2] == ("merge-tree", "--write-tree"):
                return subprocess.CompletedProcess(args, 129, b"", b"unknown option")
            return original(repo, *args, check=check)
        with patch.object(Repository, "git", without_merge_tree):
            self.blocked(self.cycle.admit_parallel, "parallel-git")

    def test_a_new_campaign_syncs_but_a_campaign_after_a_review_reset_does_not(self):
        from focus_review_run import ProjectReviewCycle, create_run
        from focus_review_scope import make_request
        store, state = create_run(self.project, make_request(scope="Inspect the migration"))
        cycle = ProjectReviewCycle(self.project, store, state, self.transport, lambda: None, fixtures.REPO / "tools", "pwsh")
        pushed = self.push_other("Interlink-plans", "plan/s3.md", "# S3\n")
        cycle.admit_parallel()
        self.assertEqual(self.head("Interlink-plans"), pushed)
        state["pair_round"] = 1  # A first pair ran. A review reset keeps this key.
        cycle.reset_pairs()
        (self.root / "Interlink-plans" / PLAN_FILE).write_text(DONE)  # The fix of the target.
        self.push_other("Interlink-plans", "plan/s4.md", "# S4\n")
        cycle.admit_parallel()
        self.assertEqual(self.head("Interlink-plans"), pushed)
        self.assertEqual(self.text("Interlink-plans"), DONE)

    def test_a_restart_after_a_completed_project_syncs_at_admission(self):
        pushed = self.push_other("Interlink-plans", "plan/s3.md", "# S3\n")
        self.state.update(status="complete", code_started=True)
        self.cycle.admit_parallel()
        self.assertNotEqual(self.head("Interlink-plans"), pushed)
        self.state.update(status="ready", coordinated=None, code_started=False)  # The --handoff restart update.
        self.cycle.admit_parallel()
        self.assertEqual(self.head("Interlink-plans"), pushed)
        self.assertEqual(self.state["baseline"]["head"]["Interlink-plans"], pushed)

    def test_an_exclusive_handover_before_coding_keeps_its_entries(self):
        adopted = "Interlink/source.txt"
        self.state["baseline"]["files"][adopted] = "f:" + "0" * 64  # A reconcile adoption sets the publication base.
        self.state["protected"] = []
        self.push_other("Interlink-plans", "plan/s3.md", "# S3\n")
        self.cycle.admit_parallel()
        self.assertEqual(self.state["baseline"]["files"][adopted], "f:" + "0" * 64)

    def test_cc_focus_runs_the_admission_inside_the_lease_before_the_run(self):
        import cc_focus
        order = []

        class FakeLease:
            pwsh = "pwsh"

            def __init__(self, *args):
                pass

            def __enter__(self):
                order.append("lease")
                return self

            def __exit__(self, *args):
                order.append("release")

            def heartbeat(self):
                pass
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.ProjectLease", FakeLease), \
                patch.object(ProjectCycle, "admit_parallel", lambda cycle: order.append("admit")), \
                patch.object(ProjectCycle, "run", lambda cycle: order.append("run") or 0), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(cc_focus.main(["--ui", "off"]), 0)
        self.assertEqual(order, ["lease", "admit", "run", "release"])

    def test_create_run_names_a_rewritten_remote_and_local_commits(self):
        from focus_review_run import create_run
        from focus_review_scope import make_request
        self.store.save(self.state)  # The development state knows the base of the member.
        repo = self.other["Interlink-plans"]
        repo.git("pull", "-q", "--ff-only")
        repo.git("checkout", "-q", "--orphan", "fresh")
        repo.git("commit", "-qm", "Rewritten history")
        repo.git("push", "-q", "--force", "origin", "fresh:main")
        error = self.blocked(lambda: create_run(self.project, make_request(scope="Inspect")), "parallel-remote-rewritten")
        self.assertIn("Do not reset local main", str(error))
        repo.git("push", "-q", "--force", "origin", self.state["baseline"]["head"]["Interlink-plans"] + ":refs/heads/main")
        self.members["Interlink-plans"].git("commit", "--allow-empty", "-qm", "Local operator commit")
        self.blocked(lambda: create_run(self.project, make_request(scope="Inspect")), "parallel-diverged")

    def test_create_run_during_an_unfinished_development_publication_names_the_development(self):
        from focus_review_run import create_run
        from focus_review_scope import make_request
        self.commit_only(code=False)  # The stage commit of the plan is not pushed yet.
        self.state.update(code_started=True, status="blocked")
        self.store.save(self.state)
        local = self.head("Interlink-plans")
        self.blocked(lambda: create_run(self.project, make_request(scope="Inspect")), "review-development")
        self.assertEqual(self.head("Interlink-plans"), local)

    def test_create_run_and_hand_back_change_no_checkout(self):
        from focus_review_run import create_run, hand_back
        from focus_review_scope import make_request
        before = self.head("Interlink-plans")
        self.push_other("Interlink-plans", "plan/s3.md", "# S3\n")
        store, state = create_run(self.project, make_request(scope="Inspect the migration"))
        self.assertEqual(self.head("Interlink-plans"), before)
        self.assertEqual(state["parallel"], PARALLEL)
        hand_back(self.project, fixtures.REPO / "tools")
        self.assertEqual(self.head("Interlink-plans"), before)


class IntegrationTests(ParallelFixture):
    def test_other_files_merge_and_the_merged_commit_is_published(self):
        other = self.push_other("Interlink-plans", "plan/s3.md", "# S3\n")
        self.publish()
        published = self.state["published"]["repositories"]["Interlink-plans"]["sha"]
        repo = self.members["Interlink-plans"]
        self.assertEqual(self.head("Interlink-plans"), published)
        self.assertEqual(self.remote("Interlink-plans"), published)
        self.assertEqual(repo.text("rev-parse", published + "^"), other)
        self.assertEqual(repo.text("log", "-1", "--format=%s", published), "Mark stage 1 complete")
        self.assertEqual(self.state["baseline"]["head"]["Interlink-plans"], other)
        self.assertEqual(self.state["phase"], "ci")
        self.cycle.wait_ci()
        self.assertEqual(self.state["display_ci"]["status"], "not-configured")

    def test_other_lines_of_the_same_file_merge_without_a_new_review(self):
        self.push_other("Interlink-plans", PLAN_FILE, PLAN.replace("Other writers edit this part.", "Another writer added a note."))
        self.publish()
        merged = self.text("Interlink-plans")
        self.assertIn("Status: complete.", merged)
        self.assertIn("Another writer added a note.", merged)
        self.assertIn("Interlink-plans/" + PLAN_FILE, self.state["publication_paths"])
        self.assertEqual(self.state["phase"], "ci")

    def test_conflicts_stop_before_the_first_push(self):
        cases = {"content": PLAN.replace("## Stage 1\n\nStatus: open.", "## Stage 1\n\nStatus: blocked."),
                 "adjacent": PLAN.replace("## Stage 1\n\nStatus: open.", "## Stage 1\nOwner: another writer.\nStatus: open."),
                 "deletion": None}
        for case, text in cases.items():
            with self.subTest(case=case):
                self.tearDown()
                self.setUp()
                self.push_other("Interlink-plans", PLAN_FILE, text)
                code = self.head("Interlink")
                self.commit_only()
                local = self.head("Interlink-plans")
                remote = self.remote("Interlink-plans")
                error = self.blocked(lambda: self.cycle.execute_publication("Mark stage 1 complete"), "parallel-merge-conflict")
                self.assertIn(PLAN_FILE, str(error))
                self.assertIn("diff", str(error))
                self.assertEqual(self.head("Interlink-plans"), local)
                self.assertEqual(self.remote("Interlink-plans"), remote)
                self.assertEqual(self.remote("Interlink"), code)  # The exclusive member was not pushed.
                self.assertNotIn("Interlink-plans", self.state.get("parallel_integrations", {}))

    def test_a_rename_of_a_stage_file_stops_before_the_push(self):
        repo = self.other["Interlink-plans"]
        repo.git("pull", "-q", "--ff-only")
        repo.git("mv", PLAN_FILE, "plan/s2.md")
        repo.git("commit", "-qm", "Rename")
        repo.git("push", "-q", "origin", "main")
        self.commit_only()
        error = self.blocked(lambda: self.cycle.execute_publication("Mark stage 1 complete"), "parallel-merge-conflict")
        self.assertIn("plan/s2.md", str(error))

    def test_a_submodule_stops_before_the_record_and_a_retry_after_its_removal_publishes(self):
        self.commit_only()
        self.push_submodule("Interlink-plans")
        local = self.head("Interlink-plans")
        self.blocked(lambda: self.cycle.execute_publication("Mark stage 1 complete"), "parallel-unsupported-path")
        self.assertEqual(self.head("Interlink-plans"), local)
        self.assertNotIn("Interlink-plans", self.state.get("parallel_integrations", {}))
        self.push_submodule("Interlink-plans", remove=True)
        self.cycle.execute_publication("Mark stage 1 complete")
        self.assertTrue(self.cycle.reconcile_publish())

    def test_a_retry_before_the_push_passes_the_preparation_rule(self):
        self.push_other("Interlink-plans", "plan/s3.md", "# S3\n")
        self.commit_only()
        self.assertTrue(self.cycle.prepare_publish())  # Local main is H.
        self.assertTrue(focus_parallel.integrate(self.cycle, "Interlink-plans"))
        self.assertTrue(self.cycle.prepare_publish())  # Local main is C2, and the base moved.
        self.assertFalse(self.cycle.reconcile_publish())

    def test_a_rewritten_remote_history_keeps_local_main(self):
        self.commit_only()
        repo = self.other["Interlink-plans"]
        repo.git("pull", "-q", "--ff-only")
        repo.git("checkout", "-q", "--orphan", "fresh")
        repo.git("commit", "-qm", "Rewritten history")
        repo.git("push", "-q", "--force", "origin", "fresh:main")
        local = self.head("Interlink-plans")
        error = self.blocked(self.cycle.prepare_publish, "parallel-remote-rewritten")
        self.assertIn("Do not reset local main", str(error))
        self.assertEqual(self.head("Interlink-plans"), local)

    def test_a_moved_remote_main_integrates_again_and_three_moves_stop(self):
        self.commit_only()
        original = focus_parallel.integrate
        moves = []

        def integrate_then_move(cycle, name):
            result = original(cycle, name)
            if result and len(moves) < self.moves:
                moves.append(self.push_other(name, f"plan/race-{len(moves)}.md", "Race.\n"))
            return result
        self.moves = 1
        with patch.object(focus_parallel, "integrate", integrate_then_move):
            self.cycle.execute_publication("Mark stage 1 complete")
        self.assertTrue(self.cycle.reconcile_publish())
        self.assertEqual(self.remote("Interlink-plans"), self.head("Interlink-plans"))
        self.assertEqual(self.members["Interlink-plans"].text("rev-parse", "HEAD^"), moves[0])
        self.tearDown()
        self.setUp()
        self.commit_only()
        moves.clear()
        self.moves = 5
        with patch.object(focus_parallel, "integrate", integrate_then_move):
            error = self.blocked(lambda: self.cycle.execute_publication("Mark stage 1 complete"), "parallel-remote-busy")
        self.assertEqual(ESCALATION_REASONS["operator-context"].split(".")[0], "This blocker needs the operator")
        self.assertIn("later", str(error))

    def test_another_rejection_keeps_publication_git(self):
        self.commit_only()
        import focus_commit
        original = focus_commit.run_git

        def reject(cycle, *args, **kwargs):
            if args[0] == "push" and (kwargs.get("repo") or cycle.repo).root.name == "Interlink-plans":
                raise Blocked("publication-git", "git push failed (1): protected branch")
            return original(cycle, *args, **kwargs)
        with patch.object(focus_commit, "run_git", reject):
            error = self.blocked(lambda: self.cycle.execute_publication("Mark stage 1 complete"), "publication-git")
        self.assertIn("protected branch", str(error))
        self.assertEqual(self.remote("Interlink"), self.head("Interlink"))  # The exclusive member was pushed first.

    def test_a_push_on_top_after_the_publication_keeps_the_confirmation(self):
        self.publish()
        self.push_other("Interlink-plans", "plan/s3.md", "# S3\n")
        self.assertTrue(self.cycle.reconcile_publish())
        self.cycle.assert_publication_current()

    def test_a_partial_publication_does_not_push_a_published_member_again(self):
        self.commit_only()
        focus_parallel.push(self.cycle, "Interlink-plans")  # The parallel member is published, the exclusive one is not.
        pushed = self.remote("Interlink-plans")
        self.assertEqual(pushed, self.head("Interlink-plans"))
        self.push_other("Interlink-plans", "plan/s3.md", "# S3\n")
        on_top = self.remote("Interlink-plans")
        self.cycle.execute_publication("Mark stage 1 complete")
        self.assertTrue(self.cycle.reconcile_publish())
        self.assertEqual(self.remote("Interlink-plans"), on_top)
        self.assertEqual(self.state["published"]["repositories"]["Interlink-plans"]["sha"], pushed)

    def test_two_unpushed_stage_commits_become_one_commit_with_the_last_message(self):
        self.push_other("Interlink-plans", "plan/s3.md", "# S3\n")
        self.review()
        repo = self.members["Interlink-plans"]
        self.assertTrue(self.cycle.prepare_publish())
        repo.git("commit", "-qam", "First stage commit")
        self.state["publication_prepared"] = {"reviewed_sha256": digest(encode(self.cycle.snapshot(self.state["reviewed"]))),
                                              "subject": "Second"}
        (repo.root / PLAN_FILE).write_text(DONE)  # The reviewed content is already committed.
        self.assertTrue(focus_parallel.integrate(self.cycle, "Interlink-plans"))
        self.assertEqual(repo.text("log", "-1", "--format=%s"), "First stage commit")
        self.assertEqual(repo.text("rev-list", "--count", self.state["baseline"]["head"]["Interlink-plans"] + "..HEAD"), "1")

    def test_a_signature_uses_the_signing_key(self):
        self.push_other("Interlink-plans", "plan/s3.md", "# S3\n")
        self.commit_only()
        repo = self.members["Interlink-plans"]
        repo.git("config", "commit.gpgSign", "true")
        repo.git("config", "user.signingKey", "ABC123")
        calls = []
        original = focus_parallel.command

        def capture(argv, cwd, **kwargs):
            calls.append(argv)
            return original([value for value in argv if not value.startswith("-S")], cwd, **kwargs)
        with patch.object(focus_parallel, "command", capture):
            focus_parallel.integrate(self.cycle, "Interlink-plans")
        self.assertIn("-SABC123", calls[0])


class RecoveryTests(ParallelFixture):
    def interrupted(self):
        """An integration record exists, and the run stopped right after its save."""
        self.push_other("Interlink-plans", "plan/s3.md", "# S3\n")
        self.commit_only()
        original = focus_parallel.resume
        calls = []

        def crash_after_record(cycle, name):
            calls.append(name)
            if len(calls) == 2:
                raise KeyboardInterrupt
            return original(cycle, name)
        with patch.object(focus_parallel, "resume", crash_after_record), self.assertRaises(KeyboardInterrupt):
            focus_parallel.integrate(self.cycle, "Interlink-plans")
        return self.state["parallel_integrations"]["Interlink-plans"]

    def test_each_interruption_point_completes_without_a_second_push(self):
        for point in ("record", "checkout", "base"):
            with self.subTest(point=point):
                self.tearDown()
                self.setUp()
                record = self.interrupted()
                repo = self.members["Interlink-plans"]
                if point in ("checkout", "base"):
                    repo.git("checkout", "-q", "-B", "main", record["result"])
                if point == "base":
                    focus_parallel.move_base(self.cycle, "Interlink-plans", record)
                remote = self.remote("Interlink-plans")
                self.assertTrue(self.cycle.prepare_publish())  # It resolves the record first.
                self.assertEqual(record["step"], "complete")
                self.assertEqual(self.head("Interlink-plans"), record["result"])
                self.assertEqual(self.state["baseline"]["head"]["Interlink-plans"], record["upstream"])
                self.assertEqual(self.remote("Interlink-plans"), remote)
                self.assertNotEqual(self.state["phase"], "pair_a")  # No review reset.

    def test_another_local_main_and_a_failed_base_move(self):
        record = self.interrupted()
        repo = self.members["Interlink-plans"]
        repo.git("checkout", "-q", "-B", "main", record["upstream"])
        error = self.blocked(self.cycle.prepare_publish, "parallel-integration-state")
        self.assertIn(record["result"][:12], str(error))
        repo.git("checkout", "-q", "-B", "main", record["local"])
        with patch.object(focus_parallel, "move_base", side_effect=Blocked("command-failed", "cat-file failed")):
            self.blocked(self.cycle.prepare_publish, "command-failed")
        self.assertEqual(self.head("Interlink-plans"), record["local"])
        self.assertNotIn("Interlink-plans", self.state.get("parallel_integrations", {}))
        self.assertTrue(self.cycle.prepare_publish())


class RestoreTests(ParallelFixture):
    def test_a_failed_save_in_the_base_move_restores_the_state(self):
        self.push_other("Interlink-plans", "plan/s3.md", "# S3\n")
        self.commit_only()
        base, local = self.state["baseline"]["head"]["Interlink-plans"], self.head("Interlink-plans")
        original, calls = self.cycle.save, []

        def fail_in_move(*args):
            import traceback
            if any(frame.name == "move_base" for frame in traceback.extract_stack()) and not calls:
                calls.append(1)
                raise OSError("disk full")
            return original(*args)
        self.cycle.save = fail_in_move
        with self.assertRaises(OSError):
            focus_parallel.integrate(self.cycle, "Interlink-plans")
        self.cycle.save = original
        self.assertEqual(self.state["baseline"]["head"]["Interlink-plans"], base)
        self.assertEqual(self.store.read()["baseline"]["head"]["Interlink-plans"], base)
        self.assertEqual(self.head("Interlink-plans"), local)
        self.assertNotIn("Interlink-plans", self.state.get("parallel_integrations", {}))

    def test_a_campaign_records_the_remote_values_of_r(self):
        self.push_other("Interlink-plans", PLAN_FILE, PLAN.replace("Other writers edit this part.", "Another note."))
        self.commit_only()
        self.state["review_run"] = {"id": "0" * 32}
        self.assertTrue(focus_parallel.integrate(self.cycle, "Interlink-plans"))
        path = "Interlink-plans/" + PLAN_FILE
        self.assertEqual(self.state["parallel_remote_files"][path], self.state["baseline"]["files"][path])
        self.assertNotEqual(self.state["parallel_remote_files"][path], self.project.snapshot()["files"][path])


OLD_PARALLEL_RULE = """The repositories field lists the member repositories with parallel writers.
Other writers change them at the same time as this stage. Their changes reach this checkout only at a stage start.

In these repositories, change or request only what the stage needs. In the active plan, change only the status of stages.
Do not revert or rewrite a change of another writer to make a check pass. If such a change stops your work, report a blocker.

This rule has priority over the instruction files of the repositories."""


class CatchUpTests(ParallelFixture):
    MEMBER = "Interlink-plans"

    def blocked_step(self, phase="pair_a", code="reported-blocker", message="The checks need commits of other writers."):
        """A step reported a blocker, and the run routes it to recovery."""
        self.state["phase"] = phase
        self.cycle.handle_block(Blocked(code, message))
        self.assertEqual(self.state["blocker"]["status"], "healing")

    def heal_without_agent(self):
        with patch.object(self.cycle, "invoke", side_effect=AssertionError("no recovery agent may start")):
            self.cycle.heal()

    def heal_with_agent(self):
        with patch.object(self.cycle, "invoke", side_effect=KeyboardInterrupt) as invoke, self.assertRaises(KeyboardInterrupt):
            self.cycle.heal()
        self.assertEqual(invoke.call_args.args[0], "heal")

    def test_a_reported_blocker_brings_remote_main_in_and_the_step_runs_again_without_a_recovery_agent(self):
        (self.root / self.MEMBER / PLAN_FILE).write_text(DONE)  # Local stage work of an earlier step.
        self.state["last_snapshot"] = self.project.snapshot()
        other = self.push_other(self.MEMBER, "plan/s3.md", "# S3\n")
        self.blocked_step()
        signature = self.state["blocker"]["signature"]
        self.heal_without_agent()
        self.assertEqual((self.state["blocker"], self.state["status"], self.state["phase"]), (None, "ready", "pair_a"))
        self.assertNotIn(signature, self.state["healed"])
        self.assertEqual(self.head(self.MEMBER), other)
        self.assertEqual(self.text(self.MEMBER), DONE)  # The local change stays.
        self.assertEqual(self.state["baseline"]["head"][self.MEMBER], other)
        self.assertIn(self.MEMBER + "/plan/s3.md", self.state["baseline"]["files"])
        self.assertEqual(self.cycle.changes(self.state["baseline"], self.project.snapshot()), [self.MEMBER + "/" + PLAN_FILE])
        self.assertEqual(self.cycle.changes(self.state["last_snapshot"], self.project.snapshot()), [])  # No review reset.
        record = self.state["parallel_integrations"][self.MEMBER]
        self.assertEqual((record["step"], record["catch_up"]), ("complete", True))
        self.assertEqual(self.store.read()["baseline"]["head"][self.MEMBER], other)

    def test_a_pair_in_progress_starts_again_on_the_new_candidate_with_its_obligations(self):
        (self.root / self.MEMBER / PLAN_FILE).write_text(DONE)
        self.state.update(phase="pair_a", pair_completed={"pair_a": {"path": "earlier"}}, pair_clean={"pair_a": 1, "pair_b": 0})
        pair = self.cycle.new_pair()
        issue = {"source_id": pair["id"] + "/pair_sol/f1", "id": "f1", "kind": "defect", "title": "Stale language version",
                 "body": "The checks need commits of other writers.", "severity": "high", "locations": []}
        pair.update(step="fix", issues=[issue], tasks=[{"source_id": issue["source_id"], "action": "verify", "check": "tests"}])
        self.cycle.save()
        self.push_other(self.MEMBER, "plan/s3.md", "# S3\n")
        self.blocked_step()
        self.heal_without_agent()
        self.assertIsNone(self.state["pair_review"])
        self.assertEqual([row["source_id"] for row in self.state["pair_carry"]], [issue["source_id"]])
        self.assertEqual(self.state["pair_clean"]["pair_a"], 0)
        self.assertEqual(self.state["pair_completed"], {"pair_a": {"path": "earlier"}})  # Completed pairs keep their credit.
        # The step runs again: a new pair on the current candidate, without a drift stop.
        with patch.object(self.cycle, "pair_inspection_step") as inspection:
            self.cycle.paired_review_step()
        started = inspection.call_args.args[0]
        self.assertEqual(started["snapshot"], self.project.snapshot())
        self.assertEqual([row["source_id"] for row in started["carry"]], [issue["source_id"]])

    def test_a_stage_commit_that_remote_main_contains_becomes_part_of_the_base(self):
        # The operator merged the stage commit into remote main in another clone.
        repo = self.members[self.MEMBER]
        (self.root / self.MEMBER / PLAN_FILE).write_text(DONE)
        repo.git("commit", "-qam", "Stage commit")
        stage = self.head(self.MEMBER)
        other = self.other[self.MEMBER]
        other.git("pull", "-q", "--ff-only")
        other.git("fetch", "-q", str(repo.root), stage)
        (other.root / "plan/s3.md").write_text("# S3\n")
        other.git("add", "-A")
        other.git("commit", "-qm", "Other writer")
        other.git("merge", "-q", "--no-edit", "FETCH_HEAD")
        other.git("push", "-q", "origin", "main")
        (self.root / self.MEMBER / "plan/repair.md").write_text("Repair after the reset.\n")
        self.blocked_step()
        self.heal_without_agent()
        self.assertEqual(self.head(self.MEMBER), self.remote(self.MEMBER))
        self.assertEqual(self.cycle.changes(self.state["baseline"], self.project.snapshot()), [self.MEMBER + "/plan/repair.md"])

    def test_no_move_without_a_safe_fast_forward_and_then_the_recovery_agent_starts(self):
        cases = ("current", "overlap", "local-commit", "publish", "fetch", "other-code", "published")
        for case in cases:
            with self.subTest(case=case):
                self.tearDown()
                self.setUp()
                head = self.head(self.MEMBER)
                if case != "current":
                    self.push_other(self.MEMBER, PLAN_FILE, PLAN.replace("Other writers edit this part.", "Note."))
                if case == "overlap":
                    (self.root / self.MEMBER / PLAN_FILE).write_text(DONE)
                if case == "local-commit":
                    (self.root / self.MEMBER / "plan/local.md").write_text("Local.\n")
                    self.members[self.MEMBER].git("add", "-A")
                    self.members[self.MEMBER].git("commit", "-qm", "Local commit")
                    head = self.head(self.MEMBER)
                if case == "published":
                    # A partial publication pushed this member. Its published commit is the stage result.
                    self.state["publication_repositories"] = {self.MEMBER: {"published": {"sha": head, "at": 0}}}
                self.blocked_step("publish" if case == "publish" else "pair_a",
                                  code="pair-report" if case == "other-code" else "reported-blocker")
                if case == "fetch":
                    with patch.object(focus_parallel, "fetch", side_effect=Blocked("parallel-sync-git", "offline")):
                        self.heal_with_agent()
                else:
                    self.heal_with_agent()
                self.assertEqual(self.head(self.MEMBER), head)
                self.assertNotIn(self.MEMBER, self.state.get("parallel_integrations", {}))

    def test_each_blocker_gets_one_catch_up_and_a_stage_at_most_three(self):
        self.push_other(self.MEMBER, "plan/s3.md", "# S3\n")
        self.blocked_step()
        self.heal_without_agent()
        # The same blocker comes again, and remote main moved again. Now the recovery agent starts.
        self.push_other(self.MEMBER, "plan/s4.md", "# S4\n")
        self.blocked_step()
        self.heal_with_agent()
        self.assertNotEqual(self.head(self.MEMBER), self.remote(self.MEMBER))
        for number in range(2):
            self.state.update(blocker=None, status="ready")
            self.blocked_step(message=f"Another blocker {number}.")
            self.heal_without_agent()
            self.push_other(self.MEMBER, f"plan/s{5 + number}.md", "# S\n")
        self.state.update(blocker=None, status="ready")
        self.blocked_step(message="A fourth blocker.")
        self.heal_with_agent()  # The stage used its three catch-ups.
        self.assertEqual(len(self.state["caught_up"]), 3)
        self.cycle.sync_parallel("cc-focus --retry")
        self.cycle.advance_stage(self.cycle.snapshot(), [], {})
        self.assertNotIn("caught_up", self.state)

    def test_an_edit_of_the_blocked_role_still_resets_the_reviews(self):
        self.state["last_snapshot"] = self.project.snapshot()
        (self.root / self.MEMBER / PLAN_FILE).write_text(DONE)  # The role edited a file, then reported a blocker.
        self.push_other(self.MEMBER, "plan/s3.md", "# S3\n")
        self.blocked_step()
        self.heal_without_agent()
        self.assertEqual(self.cycle.changes(self.state["last_snapshot"], self.project.snapshot()),
                         [self.MEMBER + "/" + PLAN_FILE])

    def test_a_failed_checkout_drops_the_record_and_the_recovery_agent_starts(self):
        self.push_other(self.MEMBER, "plan/s3.md", "# S3\n")
        head = self.head(self.MEMBER)
        self.blocked_step()
        import focus_commit
        original = focus_commit.run_git

        def refuse_checkout(cycle, *args, **kwargs):
            if args[0] == "checkout":
                raise Blocked("publication-git", "git checkout failed (1): a file is locked")
            return original(cycle, *args, **kwargs)
        with patch.object(focus_parallel, "run_git", refuse_checkout):
            self.heal_with_agent()
        self.assertEqual(self.head(self.MEMBER), head)
        self.assertNotIn(self.MEMBER, self.state.get("parallel_integrations", {}))

    def test_a_campaign_keeps_the_brought_values_out_of_the_requeue(self):
        self.state["review_run"] = {"id": "0" * 32}
        self.push_other(self.MEMBER, "plan/s3.md", "# S3\n")
        self.blocked_step()
        self.heal_without_agent()
        path = self.MEMBER + "/plan/s3.md"
        self.assertEqual(self.state["parallel_remote_files"][path], self.project.snapshot()["files"][path])

    def test_an_interrupted_catch_up_completes_before_the_next_step(self):
        other = self.push_other(self.MEMBER, "plan/s3.md", "# S3\n")
        self.blocked_step()
        def checkout_then_die(cycle, name):
            record = cycle.state["parallel_integrations"][name]
            cycle.repo.repositories[name].git("checkout", "-q", "-B", "main", record["result"])
            raise KeyboardInterrupt  # A hard stop after the checkout and before the base moved.
        with patch.object(focus_parallel, "resume", checkout_then_die), self.assertRaises(KeyboardInterrupt):
            self.cycle.heal()
        self.assertEqual(self.store.read()["parallel_integrations"][self.MEMBER]["step"], "saved")
        self.assertEqual(self.head(self.MEMBER), other)
        self.cycle.resume_catch_ups()  # The run loop calls it before any other step.
        self.assertEqual(self.state["parallel_integrations"][self.MEMBER]["step"], "complete")
        self.assertEqual(self.state["baseline"]["head"][self.MEMBER], other)
        self.assertEqual(self.cycle.changes(self.state["last_snapshot"], self.project.snapshot()), [])

    def test_roles_learn_that_a_blocker_brings_remote_main_in_and_saved_pair_prompts_still_match(self):
        from cycle_prompts import PARALLEL_REPOSITORIES_RULE
        from focus_pair_jobs import same_pair_prompt
        self.assertIn("If your work needs commits that remote main of such a repository has, report a blocker.",
                      PARALLEL_REPOSITORIES_RULE)
        self.assertIn("A pair inspector reports a finding instead of a blocker.", PARALLEL_REPOSITORIES_RULE)

        def prompt(rule):
            return "Contract\nRuntime assignment:\n" + json.dumps(
                {"parallel_repositories": {"repositories": PARALLEL, "rule": rule}, "role": "pair_sol"})
        self.assertTrue(same_pair_prompt(prompt(OLD_PARALLEL_RULE), prompt(PARALLEL_REPOSITORIES_RULE)))
        self.assertFalse(same_pair_prompt(prompt(OLD_PARALLEL_RULE + " Changed."), prompt(PARALLEL_REPOSITORIES_RULE)))


class CiTests(ParallelFixture):
    def test_a_later_push_passes_the_ci_wait_but_not_for_an_exclusive_member(self):
        self.publish()
        self.push_other("Interlink-plans", "plan/s3.md", "# S3\n")
        self.cycle.assert_publication_current()
        clone = Path(self.temp.name) / "other-code"
        subprocess.run(["git", "clone", "-q", "-b", "main", str(self.remotes["Interlink"]), str(clone)], check=True, capture_output=True)
        code = Repository(clone)
        code.git("-c", "user.name=O", "-c", "user.email=o@e", "commit", "--allow-empty", "-qm", "Code push")
        code.git("push", "-q", "origin", "main")
        self.blocked(self.cycle.assert_publication_current, "ci-head-drift")

    def ci_records(self, sha, conclusion="success"):
        return [{"name": "build", "source": "workflow", "head_sha": sha, "run_id": 1,
                 "status": "completed", "conclusion": conclusion}]

    def wait(self, member, records, gates):
        """Run the CI wait of MEMBER with fixture GitHub records and gate verdicts. Return the later-commit polls."""
        import cycle_workflow
        polls = []

        def gh(cycle, host, repo, sha):
            polls.append(sha)
            return records(sha, polls.count(sha))
        with patch.object(MemberCycle, "github", return_value=("github.com", "owner/plans")), \
                patch.object(MemberCycle, "gh_records", gh), \
                patch.object(MemberCycle, "ci_gate", lambda c, sha, recs, elapsed, artifact="ci/checks.json": {"verdict": gates(sha)}), \
                patch.object(cycle_workflow, "command", return_value=subprocess.CompletedProcess([], 0, b"", b"")), \
                patch.object(cycle_workflow.time, "sleep"):
            member.wait_ci()
        return polls

    def test_a_green_later_remote_main_passes_after_two_equal_polls_and_names_the_changed_stage_paths(self):
        self.publish()
        member = self.cycle.member("Interlink-plans")
        published = member.state["published"]["sha"]
        later = self.push_other("Interlink-plans", PLAN_FILE, DONE.replace("Other writers edit this part.", "Fixed the link."))

        def records(sha, count):
            if sha == published:
                return self.ci_records(sha, "failure")
            # The second workflow run appears late. Only two equal green polls pass.
            extra = [dict(self.ci_records(sha)[0], name="lint", run_id=2)] if count >= 2 else []
            return self.ci_records(sha) + extra
        polls = self.wait(member, records, lambda sha: "failed" if sha == published else "ready")
        self.assertEqual(polls.count(later), 3)
        display = self.state["publication_repositories"]["Interlink-plans"]["display_ci"]
        self.assertEqual(display["accepted_commit"], later)
        self.assertEqual(display["changed_stage_paths"], [PLAN_FILE])

    def test_a_published_commit_without_ci_of_its_own_uses_a_green_later_remote_main(self):
        # Another writer merged the stage commit into remote main, so the commit was never a pushed main.
        self.publish()
        member = self.cycle.member("Interlink-plans")
        published = member.state["published"]["sha"]
        later = self.push_other("Interlink-plans", "plan/s3.md", "# S3\n")
        def records(sha, count):
            if sha == published:
                self.assertLess(count, 5, "The wait did not use the later remote main")
                return []
            return self.ci_records(sha)
        polls = self.wait(member, records, lambda sha: "wait" if sha == published else "ready")
        self.assertEqual(polls.count(later), 2)
        self.assertEqual(self.state["publication_repositories"]["Interlink-plans"]["display_ci"]["accepted_commit"], later)

    def bounded(self, count):
        self.assertLess(count, 5, "The wait did not reach its deadline")
        return []

    def test_a_published_commit_without_any_ci_still_times_out(self):
        self.publish()
        member = self.cycle.member("Interlink-plans")
        member.state["published"]["at"] -= 1801
        self.blocked(lambda: self.wait(member, lambda sha, count: self.bounded(count), lambda sha: "wait"), "ci-timeout")

    def test_a_timeout_names_a_red_later_remote_main(self):
        self.publish()
        member = self.cycle.member("Interlink-plans")
        published = member.state["published"]["sha"]
        later = self.push_other("Interlink-plans", "plan/s3.md", "# S3\n")
        def records(sha, count):
            if sha != published:
                return self.ci_records(sha, "failure")
            if count == 3:
                member.state["published"]["at"] -= 1801  # The 30 minutes pass while remote main is red.
            return self.bounded(count)
        error = self.blocked(lambda: self.wait(member, records, lambda sha: "wait" if sha == published else "failed"), "ci-timeout")
        self.assertIn(f"Remote main {later[:12]} contains this commit. Its last CI result was red.", str(error))

    def test_required_checks_without_records_time_out_with_the_remote_main_text(self):
        # With required checks, the policy gives wait and then timeout at the deadline.
        self.publish()
        member = self.cycle.member("Interlink-plans")
        published = member.state["published"]["sha"]
        later = self.push_other("Interlink-plans", "plan/s3.md", "# S3\n")
        def records(sha, count):
            if sha != published:
                return self.ci_records(sha, "failure")
            if count == 3:
                member.state["published"]["at"] -= 1801
            return self.bounded(count)
        def gates(sha):
            if sha != published:
                return "failed"
            return "timeout" if time.time() - member.state["published"]["at"] >= 1800 else "wait"
        error = self.blocked(lambda: self.wait(member, records, gates), "ci-timeout")
        self.assertIn(f"Remote main {later[:12]} contains this commit. Its last CI result was red.", str(error))

    def test_an_exclusive_member_without_ci_does_not_read_remote_main(self):
        self.publish()
        member = self.cycle.member("Interlink")
        def records(sha, count):
            if count == 2:
                member.state["published"]["at"] -= 1801  # The first poll is inside the deadline.
            return self.bounded(count)
        with patch.object(MemberCycle, "later_ci", side_effect=AssertionError("An exclusive member read remote main")):
            self.blocked(lambda: self.wait(member, records, lambda sha: "wait"), "ci-timeout")

    def test_an_operator_merge_of_a_conflicting_stage_commit_passes_with_the_merge_ci(self):
        self.push_other("Interlink-plans", PLAN_FILE, PLAN.replace("## Stage 1\n\nStatus: open.", "## Stage 1\n\nStatus: blocked."))
        self.commit_only()
        stage = self.head("Interlink-plans")
        error = self.blocked(lambda: self.cycle.execute_publication("Mark stage 1 complete"), "parallel-merge-conflict")
        # The documented remedy: another clone runs the fetch of the message, merges the commit, and pushes the merge.
        source, commit = re.search(r"run git fetch (\S+) ([0-9a-f]{40}), merge FETCH_HEAD", str(error)).groups()
        self.assertEqual(commit, stage)
        other = self.other["Interlink-plans"]
        other.git("pull", "-q", "--ff-only")
        other.git("fetch", "-q", source, commit)
        other.git("merge", "-q", "--no-edit", "FETCH_HEAD", check=False)
        (other.root / PLAN_FILE).write_text(DONE.replace("Other writers edit this part.", "Resolved by the operator."))
        other.git("add", "-A")
        other.git("-c", "user.name=O", "-c", "user.email=o@e", "commit", "-qm", "Merge stage 1")
        other.git("push", "-q", "origin", "main")
        merge = other.text("rev-parse", "HEAD")
        self.cycle.execute_publication("Mark stage 1 complete")
        self.assertEqual((self.remote("Interlink-plans"), self.head("Interlink-plans")), (merge, stage))  # No push.
        self.assertTrue(self.cycle.reconcile_publish())
        member = self.cycle.member("Interlink-plans")
        self.assertEqual(member.state["published"]["sha"], stage)
        def records(sha, count):
            return self.bounded(count) if sha == stage else self.ci_records(sha)
        self.wait(member, records, lambda sha: "wait" if sha == stage else "ready")
        self.assertEqual(self.state["publication_repositories"]["Interlink-plans"]["display_ci"]["accepted_commit"], merge)

    def test_a_red_published_commit_without_a_green_later_commit_stops(self):
        self.publish()
        member = self.cycle.member("Interlink-plans")
        self.blocked(lambda: self.wait(member, lambda sha, count: self.ci_records(sha, "failure"), lambda sha: "failed"), "ci-failed")
        self.push_other("Interlink-plans", "plan/s3.md", "# S3\n")
        self.blocked(lambda: self.wait(member, lambda sha, count: self.ci_records(sha, "failure"), lambda sha: "failed"), "ci-failed")


class CampaignTests(ParallelFixture):
    def campaign(self):
        from focus_review_run import ProjectReviewCycle, create_run
        from focus_review_scope import make_request
        store, state = create_run(self.project, make_request(scope="Inspect the migration"))
        return ProjectReviewCycle(self.project, store, state, self.transport, lambda: None, fixtures.REPO / "tools", "pwsh")

    def test_a_target_without_a_fix_uses_the_confirmation_rule(self):
        cycle = self.campaign()
        cycle.state["reviewed"] = self.project.snapshot()
        self.push_other("Interlink-plans", "plan/s3.md", "# S3\n")
        cycle.publish()
        self.assertEqual(cycle.state["phase"], "ci")

    def test_a_target_without_a_fix_stops_on_a_rewritten_remote(self):
        cycle = self.campaign()
        cycle.state["reviewed"] = self.project.snapshot()
        repo = self.other["Interlink-plans"]
        repo.git("pull", "-q", "--ff-only")
        repo.git("checkout", "-q", "--orphan", "fresh")
        repo.git("commit", "-qm", "Rewritten history")
        repo.git("push", "-q", "--force", "origin", "fresh:main")
        self.blocked(cycle.publish, "parallel-remote-rewritten")

    def test_a_requeue_ignores_paths_that_only_a_sync_changed(self):
        cycle = self.campaign()
        run = cycle.state["review_run"]
        snapshot = self.project.snapshot()
        ref = __import__("focus_pair_view").artifact(cycle.store, "targets/old.json", {"snapshot": snapshot, "paths": ["Interlink-plans/" + PLAN_FILE]})
        run["results"]["0"] = ref
        self.push_other("Interlink-plans", PLAN_FILE, PLAN + "\n## Stage 3\n")
        focus_parallel.record_sync(cycle, {"Interlink-plans": focus_parallel.sync(cycle, "Interlink-plans", "cc-focus --retry")})
        cycle.requeue_changed_targets(self.project.snapshot())
        self.assertIn("0", run["results"])
        (self.root / "Interlink-plans" / PLAN_FILE).write_text(DONE)
        cycle.requeue_changed_targets(self.project.snapshot())
        self.assertNotIn("0", run["results"])


class BoundaryTests(ParallelFixture):
    def test_an_exclusive_member_keeps_its_remote_drift(self):
        self.commit_only(plan=None)
        clone = Path(self.temp.name) / "other-code"
        subprocess.run(["git", "clone", "-q", "-b", "main", str(self.remotes["Interlink"]), str(clone)], check=True, capture_output=True)
        code = Repository(clone)
        code.git("-c", "user.name=O", "-c", "user.email=o@e", "commit", "--allow-empty", "-qm", "Code push")
        code.git("push", "-q", "origin", "main")
        self.blocked(self.cycle.prepare_publish, "remote-drift")

    def test_a_missing_published_commit_at_the_boundary_is_a_rewritten_remote(self):
        import time
        self.publish()
        self.cycle.wait_ci()
        self.state.update(status="paused", stage_completed={"iteration": 1, "sha": self.state["published"]["sha"], "at": time.time()})
        repo = self.other["Interlink-plans"]
        repo.git("pull", "-q", "--ff-only")
        repo.git("checkout", "-q", "--orphan", "fresh")
        repo.git("commit", "-qm", "Rewritten history")
        repo.git("push", "-q", "--force", "origin", "fresh:main")
        error = self.blocked(self.cycle.next_stage, "parallel-remote-rewritten")
        self.assertIn("Do not reset local main", str(error))
        self.members["Interlink-plans"].git("commit", "--allow-empty", "-qm", "Unpublished local commit")
        self.other["Interlink-plans"].git("push", "-q", "--force", "origin", self.state["published"]["repositories"]["Interlink-plans"]["sha"] + ":refs/heads/main")
        self.blocked(self.cycle.next_stage, "parallel-diverged")

    def test_a_publication_scope_cannot_exclude_a_file_of_a_parallel_member(self):
        import focus_publication_scope as scope
        (self.root / "Interlink/source.txt").write_text("stage change\n")
        (self.root / "Interlink-plans" / PLAN_FILE).write_text(DONE)
        self.state.update(phase="pair_a", code_started=True, status="blocked")
        request = {"schema": scope.REQUEST_SCHEMA, "task": {"id": "S2.1", "title": "Adaptation", "plan": SPLIT_PLAN},
                   "paths": ["Interlink/source.txt"]}
        error = self.blocked(lambda: scope.prepare(self.cycle, request), "publication-selection-parallel")
        self.assertIn("Interlink-plans/" + PLAN_FILE, str(error))
        scope.prepare(self.cycle, dict(request, paths=["Interlink/source.txt", "Interlink-plans/" + PLAN_FILE]))

    def test_publication_recovery_refuses_a_parallel_target(self):
        import focus_publication_recovery
        self.commit_only()
        self.state.update(status="blocked", code_started=True, publication_started=True)
        self.blocked(lambda: focus_publication_recovery.prepare(self.cycle), "reconcile-publication-parallel")

    def test_parallel_codes_and_the_manifest_stop_start_no_recovery_agent(self):
        for code in ("parallel-dirty", "parallel-diverged", "parallel-merge-conflict", "parallel-remote-busy",
                     "parallel-remote-rewritten", "parallel-unsupported-path", "parallel-integration-state",
                     "parallel-git", "project-manifest"):
            with self.subTest(code=code):
                self.state.update(blocker=None, pending=None, healed=[], recovery_unverified=False)
                self.cycle.handle_block(Blocked(code, "Fixture diagnosis"))
                self.assertEqual(self.state["blocker"]["escalation_reason"], "operator-context")
                self.assertEqual(self.state["healed"], [])
        self.state.update(blocker=None, pending=None, healed=[])
        self.cycle.handle_block(Blocked("parallel-sync-git", "Fixture diagnosis"))
        self.assertIsNone(self.state["blocker"].get("escalation_reason"))  # A technical failure keeps the recovery agent.

    def test_the_transition_names_the_retry_command(self):
        (self.root / "Interlink-docs/draft.md").write_text("Draft.\n")
        error = self.blocked(lambda: self.cycle.sync_parallel(self.cycle.retry_command()), "parallel-dirty")
        self.assertIn(self.cycle.retry_command(), str(error))


class ContextTests(ParallelFixture):
    def test_main_roles_writers_and_version_two_readers_get_the_field(self):
        from cycle_prompts import PARALLEL_REPOSITORIES_RULE
        field = {"repositories": PARALLEL, "rule": PARALLEL_REPOSITORIES_RULE}
        for role in ("coordinate", "code", "heal"):
            with self.subTest(role=role):
                self.assertEqual(project_context(self.cycle.context(role))["parallel_repositories"], field)
        with patch.object(self.cycle, "pair_writer_context", return_value="Executor assignment:\n{}"):
            self.assertEqual(project_context(self.cycle.context("pair_fix"))["parallel_repositories"], field)
        (self.root / "Interlink/source.txt").write_text("stage change\n")
        self.state.update(phase="pair_a", last_snapshot=self.project.snapshot())
        pair = self.cycle.new_pair()
        self.assertEqual(pair["project_instructions_version"], 2)
        self.assertEqual(pair["parallel_repositories"], PARALLEL)
        for role in ("pair_opus", "pair_complexity", "repair_evidence"):
            with self.subTest(role=role):
                context = runtime_assignment(self.cycle.pair_prompt(pair, role, {"mode": "independent_initial"}))
                self.assertEqual(context["parallel_repositories"], field)
        copied = self.cycle.pair_instruction_record(pair)
        self.assertEqual(copied, {"project_instructions_version": 2, "parallel_repositories": PARALLEL})
        old = dict(pair, project_instructions_version=1)
        old.pop("parallel_repositories")
        self.assertNotIn("parallel_repositories", runtime_assignment(
            self.cycle.pair_prompt(old, "pair_opus", {"mode": "independent_initial"})))

    def test_the_publisher_and_the_recovery_agent_get_the_publication_rule(self):
        from cycle_prompts import PARALLEL_PUBLICATION_RULE
        # A publisher stopped a live publication only because remote main of a parallel member was ahead.
        self.state.update(remote="origin", reviewed=self.project.snapshot(),
                          publication_targets={name: {"remote": "origin", "push_url": "fixture"} for name in ("Interlink", "Interlink-plans")})
        for role in ("publish", "heal"):
            with self.subTest(role=role):
                self.assertEqual(project_context(self.cycle.context(role))["parallel_publication"], PARALLEL_PUBLICATION_RULE)
        targets = {t["path"]: t["parallel"] for t in project_context(self.cycle.context("publish"))["publication_targets"]}
        self.assertEqual(targets, {"Interlink": False, "Interlink-plans": True})
        for role in ("coordinate", "code"):
            with self.subTest(role=role):
                self.assertNotIn("parallel_publication", project_context(self.cycle.context(role)))

    def test_a_stage_without_parallel_members_gives_no_field(self):
        self.state["parallel"] = []
        self.assertNotIn("parallel_repositories", project_context(self.cycle.context("coordinate")))


if __name__ == "__main__":
    unittest.main()
