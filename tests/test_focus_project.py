"""Multi-repository fixtures with local Git remotes; no paid provider calls."""

import contextlib
import copy
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import test_cycle as fixtures
from cycle_state import Blocked, LocalLock, Repository, Store, changed, encode
from cycle_workflow import fresh_state
from focus_control import Control, runtime_active
from focus_control import FocusStop
from focus_project import Project, check_project_owner, lock_members, open_project, register_members
from focus_publication import MemberCycle, ProjectCycle
import focus_reconcile


class ProjectTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="focus-project-")
        self.root = Path(self.temp.name) / "project with spaces"
        self.root.mkdir()
        self.root = self.root.resolve()  # Match production root canonicalization.
        self.members = {}
        self.remotes = {}
        for name in ("Core", "Root", "Specification"):
            path = self.root / name
            path.mkdir()
            repo = Repository(path)
            repo.git("init", "--initial-branch=main")
            repo.git("config", "user.name", "Test")
            repo.git("config", "user.email", "test@example.invalid")
            (path / ".gitignore").write_text(".work/\n")
            (path / "source.txt").write_text("original\n")
            repo.git("add", ".gitignore", "source.txt")
            repo.git("commit", "-m", "Initial source")
            remote = Path(self.temp.name) / (name + ".git")
            subprocess.run(["git", "init", "--bare", str(remote)], check=True, capture_output=True)
            repo.git("remote", "add", "origin", str(remote))
            repo.git("push", "-u", "origin", "main")
            self.members[name], self.remotes[name] = repo, remote
        (self.root / "HANDOFF.md").write_text("Read Core/PLAN.md and Specification requirements.\n")
        self.project = open_project(self.root)
        self.store = Store(self.root)
        self.state = fresh_state(self.project)
        self.transport = fixtures.FixtureTransport(self.root)
        self.cycle = ProjectCycle(self.project, self.store, self.state, self.transport, lambda: None,
                                  fixtures.REPO / "tools", "pwsh")
        self.policy = patch.object(MemberCycle, "policy", return_value=subprocess.CompletedProcess(
            [], 0, b'{"verdict":"no-required-checks"}', b""))
        self.policy.start()
        self.quiet = contextlib.redirect_stdout(io.StringIO())
        self.quiet.__enter__()

    def tearDown(self):
        self.quiet.__exit__(None, None, None)
        self.policy.stop()
        self.temp.cleanup()

    def edit(self, name, file="source.txt", text="changed\n"):
        (self.members[name].root / file).write_text(text)

    def seal(self, names=("Core", "Specification")):
        for name in names:
            self.edit(name)
        reviewed = self.project.snapshot()
        self.state.update(phase="publish", coordinated="publish", reviewed=reviewed,
                          last_snapshot=reviewed, astra_clean=3, claude_clean=2)

    def commit(self, name, push=True, file="source.txt"):
        repo = self.members[name]
        repo.git("add", file)
        repo.git("commit", "-m", "Update source")
        if push:
            repo.git("push", "origin", "main")

    def test_discovery_preserves_single_repository_and_prefixes_member_snapshots(self):
        self.assertIsInstance(open_project(self.root / "Core"), Repository)
        self.assertEqual(list(self.project.repositories), ["Core", "Root", "Specification"])
        self.edit("Core")
        self.edit("Root")
        current = self.project.snapshot()
        self.assertEqual(set(changed(self.state["baseline"], current)), {"Core/source.txt", "Root/source.txt"})
        self.assertEqual(set(current["head"]), set(self.members))
        self.assertIn("HANDOFF.md", current["files"])

    def test_manifest_selects_nested_repositories_and_membership_is_pinned(self):
        (self.root / "products").mkdir()
        (self.root / "Core").rename(self.root / "products/Core")
        manifest = self.root / "focus-project.json"
        manifest.write_text(json.dumps({"version": 1, "repositories": ["products/Core", "Root", "Specification"]}))
        project = open_project(self.root)
        project.assert_main()
        with self.assertRaisesRegex(Blocked, "different repository set"):
            project.validate_state(self.state)
        manifest.write_text(json.dumps({"version": 1, "repositories": ["Root"]}))
        with self.assertRaisesRegex(Blocked, "membership changed"):
            project.snapshot()

    def test_manifest_rejects_escape_duplicates_missing_and_overlapping_roots(self):
        manifest = self.root / "focus-project.json"
        for paths in (["../Core"], [str(self.root / "Core")], ["Core", "Core"], ["Core/../Root"],
                      ["missing"], [".work"], ["Core", "Core/nested"]):
            with self.subTest(paths=paths):
                manifest.write_text(json.dumps({"version": 1, "repositories": paths}))
                with self.assertRaises(Blocked):
                    open_project(self.root)

    def test_project_inside_another_checkout_is_not_admitted(self):
        parent = Repository(Path(self.temp.name))
        parent.git("init", "--initial-branch=main")
        with self.assertRaisesRegex(Blocked, "inside another Git repository"):
            self.project.assert_main()

    @unittest.skipIf(os.name == "nt", "POSIX symlink fixture")
    def test_symlink_member_is_not_admitted(self):
        (self.root / "alias").symlink_to(self.root / "Core", target_is_directory=True)
        with self.assertRaisesRegex(Blocked, "symlinks"):
            open_project(self.root)

    def test_wrong_branch_names_the_member_before_creating_cycle_state(self):
        import cc_focus
        self.members["Root"].git("checkout", "--detach")
        output = io.StringIO()
        with patch("cc_focus.Path.cwd", return_value=self.root), contextlib.redirect_stderr(output):
            self.assertEqual(cc_focus.main(["--ui", "off"]), 3)
        self.assertIn("Root: HEAD is detached", output.getvalue())
        self.assertFalse(self.store.directory.exists())

    def test_root_context_changes_cannot_be_published_or_hidden_in_review(self):
        (self.root / "HANDOFF.md").write_text("mutated\n")
        with self.assertRaisesRegex(Blocked, "read-only cycle context"):
            self.cycle.check_protected(self.project.snapshot())

    def test_project_starts_without_handoff_input_or_file(self):
        (self.root / "HANDOFF.md").unlink()
        self.state = fresh_state(self.project)
        self.cycle.state = self.state
        self.transport.actions = [("coordinate", fixtures.report(status="complete"))]
        self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(self.state["status"], "complete")
        self.assertEqual(self.state["handoffs"], [])

    def test_imported_loose_source_can_disappear_during_coordination(self):
        source = self.root / "HANDOFF.md"
        imported = self.store.handoff(source)
        self.state["handoffs"] = [imported]
        baseline = copy.deepcopy(self.state["baseline"])
        def coordinate():
            source.unlink()  # Simulate the operator removing a transfer input.
            return fixtures.report(status="complete")
        self.transport.actions = [("coordinate", coordinate)]
        self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(self.state["baseline"], baseline)
        self.assertEqual(self.state["status"], "complete")
        self.assertFalse(source.exists())
        self.assertIn("Read Core/PLAN.md", Path(imported["path"]).read_text())
        self.assertIn('"optional_handoff_sources": ["HANDOFF.md"]', self.transport.calls[0][1])

    def test_imported_source_change_keeps_review_credit_and_publishes_only_members(self):
        source = self.root / "HANDOFF.md"
        self.state["handoffs"] = [self.store.handoff(source)]
        self.seal(names=("Core",))  # Legacy reviewed snapshot includes the source.
        source.write_text("New transfer notes must not enter the reviewed diff.\n")
        self.assertTrue(self.cycle.prepare_publish())
        self.assertEqual((self.state["astra_clean"], self.state["claude_clean"]), (3, 2))
        self.assertEqual(set(self.state["publication_targets"]), {"Core"})
        self.commit("Core")
        source.unlink()
        self.assertTrue(self.cycle.reconcile_publish())
        self.cycle.next_stage()
        self.assertEqual(self.state["iteration"], 2)
        self.assertNotIn("HANDOFF.md", self.state["baseline"]["files"])

    def test_legacy_cached_coding_result_survives_source_removal_without_rewriting_artifacts(self):
        source = self.root / "HANDOFF.md"
        self.state["handoffs"] = [self.store.handoff(source)]
        self.transport.actions = [("code", fixtures.report())]
        self.cycle.invoke("code")
        invocation = self.store.directory / "invocations" / self.state["pending"]["id"]
        result_path = invocation / "result.json"
        result = json.loads(result_path.read_text())
        # Simulate the old format, including physical source bytes in both snapshots.
        legacy = self.project.snapshot()
        self.state["pending"]["before"] = legacy
        result.update(before=legacy, after=legacy)
        result_path.write_bytes(encode(result))
        saved = result_path.read_bytes()
        source.unlink()
        self.transport.calls.clear()
        self.cycle.invoke("code")
        self.assertFalse(self.transport.calls)
        self.assertEqual(result_path.read_bytes(), saved)
        self.assertIn("HANDOFF.md", self.state["pending"]["before"]["files"])
        self.edit("Core", text="Unreviewed content must still reject the cached result.\n")
        with self.assertRaisesRegex(Blocked, "changed after the recorded result"):
            self.cycle.invoke("code")

    def test_source_is_not_read_again_but_imported_copy_remains_immutable(self):
        source = self.root / "HANDOFF.md"
        imported = self.store.handoff(source)
        self.state["handoffs"] = [imported]
        original = Path.open
        def guarded(path, *args, **kwargs):
            if path == source:
                raise AssertionError("Imported source must not be opened again")
            return original(path, *args, **kwargs)
        with patch.object(Path, "open", guarded):
            self.cycle.check_protected(self.cycle.snapshot())
        source.unlink()
        Path(imported["path"]).write_text("Tampered runtime copy\n")
        with self.assertRaisesRegex(Blocked, "handoff snapshot"):
            self.cycle.context("coordinate")

    def test_handoff_import_does_not_exempt_live_instructions_or_member_files(self):
        for name in ("AGENTS.md", "CLAUDE.md", "PLAN.md", "focus-project.json", "roadmap.md", "Core/source.txt"):
            with self.subTest(name=name):
                path = self.root / name
                if name == "focus-project.json":
                    path.write_text(json.dumps({"version": 1, "repositories": list(self.members)}))
                else:
                    path.write_text("Required live project document\n")
                self.state = fresh_state(self.project)
                self.cycle.state = self.state
                if name == "roadmap.md":
                    self.state["task"] = {"id": "stage", "plan": name, "title": "Current stage"}
                self.state["handoffs"] = [self.store.handoff(path)]
                path.write_text(path.read_text() + "\n")
                with self.assertRaises(Blocked):
                    self.cycle.check_protected(self.cycle.snapshot())

    def test_reconciliation_after_import_does_not_require_accepting_source_deletion(self):
        path, _ = self.reconciliation_fixture()
        self.state["handoffs"] = [self.store.handoff(self.root / "HANDOFF.md")]
        (self.root / "HANDOFF.md").unlink()
        updated = self.root / ".work/without-source.json"
        plan = focus_reconcile.write_plan(self.cycle, updated)
        self.assertEqual({row["path"] for row in plan["changes"]}, {"Core/AGENTS.md", "Root/source.txt"})
        focus_reconcile.apply(self.cycle, updated)
        self.cycle.check_protected(self.cycle.snapshot())
        self.assertIsNotNone(self.state["correction_pending"])

    def reconciliation_fixture(self):
        self.edit("Core", "AGENTS.md", "previous operator instructions\n")
        self.edit("Root", text="previous operator work\n")
        self.edit("Root", "untouched.txt", "other operator work\n")
        self.state = fresh_state(self.project)
        self.state.update(phase="astra", status="blocked", code_started=True, astra_clean=2, claude_clean=1,
                          task={"id": "P04.2", "plan": "Core/PLAN.md", "title": "Current stage"},
                          sessions={"code": "coding", "astra": "review", "heal": "healing"},
                          code_report=json.dumps(fixtures.report()),
                          blocker={"code": "project-context-changed", "status": "blocked"})
        self.cycle.state = self.state
        self.edit("Core", "AGENTS.md", "current authorized instructions\n")
        self.edit("Root", text="current authorized prerequisite\n")
        self.edit("Core", "owned.txt", "existing cycle work\n")
        (self.root / "HANDOFF.md").write_text("Current requirements for the SAME stage.\n")
        self.store.save(self.state)
        path = self.root / ".work" / "reconcile.json"
        plan = focus_reconcile.write_plan(self.cycle, path)
        return path, plan

    def test_reconciliation_hands_over_selected_files_and_keeps_all_work(self):
        path, plan = self.reconciliation_fixture()
        before, snapshot = copy.deepcopy(self.state), self.project.snapshot()
        self.assertEqual({row["path"] for row in plan["changes"]}, {"HANDOFF.md", "Core/AGENTS.md", "Root/source.txt"})
        self.assertEqual(self.store.read(), before)  # preparing is not accepting
        focus_reconcile.apply(self.cycle, path)
        self.assertEqual(self.project.snapshot(), snapshot)
        self.assertEqual((self.state["phase"], self.state["status"]), ("code", "paused"))
        self.assertEqual(self.state["sessions"], before["sessions"])
        self.assertEqual(self.state["task"], before["task"])
        self.assertEqual((self.state["astra_clean"], self.state["claude_clean"]), (0, 0))
        self.assertIsNotNone(self.state["correction_pending"])
        self.assertEqual(self.state["baseline"]["files"]["HANDOFF.md"], snapshot["files"]["HANDOFF.md"])
        self.assertNotIn("Core/AGENTS.md", self.state["protected"])
        self.assertNotIn("Root/source.txt", self.state["protected"])
        self.assertIn("Root/untouched.txt", self.state["protected"])
        self.assertNotIn("Core/AGENTS.md", self.state["baseline"]["files"])  # new in Git; prior dirty content is now owned
        self.assertEqual(self.state["baseline"]["files"]["Root/source.txt"], self.state["baseline"]["files"]["Core/source.txt"])
        self.cycle.check_protected(snapshot)
        correction = self.state["corrections"][-1]
        archived = json.loads(Path(correction["archive"]).read_text())
        self.assertEqual(archived["previous_state"], before)
        self.assertEqual(archived["reconciliation"], plan)
        self.cycle.validate_corrections()
        self.assertFalse(self.transport.calls)
        with self.assertRaises(Blocked):
            focus_reconcile.apply(self.cycle, path)  # cannot replay acceptance
        self.edit("Root", "untouched.txt", "unauthorized edit")
        with self.assertRaisesRegex(Blocked, "Pre-existing work"):
            self.cycle.check_protected(self.project.snapshot())

    def test_reconciliation_does_not_make_shared_context_writable(self):
        path, _ = self.reconciliation_fixture()
        focus_reconcile.apply(self.cycle, path)
        (self.root / "HANDOFF.md").write_text("Another change")
        with self.assertRaisesRegex(Blocked, "read-only cycle context"):
            self.cycle.check_protected(self.project.snapshot())

    def test_precode_context_handover_allows_exhausted_plan_without_inventing_work(self):
        (self.root / "HANDOFF.md").write_text("Current plan is exhausted.\n")
        path = self.root / ".work/precode-plan.json"
        plan = focus_reconcile.write_plan(self.cycle, path)
        self.assertEqual([(row["path"], row["action"]) for row in plan["changes"]],
                         [("HANDOFF.md", "refresh-context")])
        before = self.project.snapshot()
        focus_reconcile.apply(self.cycle, path)
        self.assertFalse(self.state["code_started"])
        self.assertIsNone(self.state["correction_pending"])
        self.assertEqual(self.project.snapshot(), before)
        self.transport.actions = [("coordinate", fixtures.report(status="complete"))]
        self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(self.state["status"], "complete")
        self.assertFalse(self.state["code_started"])

    def test_reconciliation_rejects_stale_work_state_and_edited_plan(self):
        path, plan = self.reconciliation_fixture()
        before = copy.deepcopy(self.state)
        for variant in ("work", "state", "plan", "typed-plan"):
            with self.subTest(variant=variant):
                self.state.clear()
                self.state.update(copy.deepcopy(before))
                self.edit("Core", "owned.txt", "existing cycle work\n")
                edited = copy.deepcopy(plan)
                if variant == "work":
                    self.edit("Core", "owned.txt", "new concurrent work")
                elif variant == "state":
                    self.state["astra_clean"] = 0
                elif variant == "plan":
                    edited["changes"].pop()
                else:
                    edited["iteration"] = True
                path.write_bytes(encode(edited))
                expected = copy.deepcopy(self.state)
                with self.assertRaisesRegex(Blocked, "changed since preparation"):
                    focus_reconcile.apply(self.cycle, path)
                self.assertEqual(self.state, expected)

    def test_reconciliation_ignores_only_admission_bookkeeping(self):
        path, _ = self.reconciliation_fixture()
        self.state.update(updated=42, lease_owner="new-owner", lease_owners=["new-owner"],
                          repository_leases={"Core": {"lease_owner": "new-child-owner"}})
        focus_reconcile.apply(self.cycle, path)
        self.assertEqual(self.state["lease_owner"], "new-owner")
        self.assertEqual(self.state["phase"], "code")

    def test_reconciliation_rechecks_work_before_the_state_transition(self):
        path, _ = self.reconciliation_fixture()
        before = copy.deepcopy(self.state)
        original = self.store.artifact
        def write(relative, data):
            result = original(relative, data)
            if relative.endswith(".md"):
                self.edit("Core", "owned.txt", "concurrent edit while archiving")
            return result
        with patch.object(self.store, "artifact", side_effect=write), self.assertRaisesRegex(Blocked, "not applied"):
            focus_reconcile.apply(self.cycle, path)
        self.assertEqual(self.state, before)
        self.assertEqual(self.store.read(), before)

    def test_reconciliation_rechecks_stop_before_acceptance(self):
        path, _ = self.reconciliation_fixture()
        before = copy.deepcopy(self.state)
        control = unittest.mock.Mock()
        control.boundary.return_value = False
        self.cycle.control = control
        original = self.store.artifact
        def write(relative, data):
            result = original(relative, data)
            if relative.endswith(".md"):
                control.boundary.return_value = True
            return result
        with patch.object(self.store, "artifact", side_effect=write), self.assertRaisesRegex(Blocked, "PAUSE/stop"):
            focus_reconcile.apply(self.cycle, path)
        self.assertEqual(self.state, before)
        self.assertEqual(self.store.read(), before)

    def test_reconciliation_failed_save_cannot_be_accepted_by_error_cleanup(self):
        path, _ = self.reconciliation_fixture()
        before = copy.deepcopy(self.state)
        with patch.object(self.store, "save", side_effect=OSError("failed state write")), self.assertRaises(OSError):
            focus_reconcile.apply(self.cycle, path)
        self.assertEqual(self.state, before)
        self.assertEqual(self.store.read(), before)
        # Simulate the CLI's subsequent persistence of an interrupted status.
        self.state["status"] = "interrupted"
        self.store.save(self.state)
        saved = self.store.read()
        self.assertEqual(saved["protected"], before["protected"])
        self.assertEqual(saved["baseline"], before["baseline"])
        self.assertNotIn("correction_pending", saved)
        new_plan = self.root / ".work/retry-plan.json"
        focus_reconcile.write_plan(self.cycle, new_plan)
        focus_reconcile.apply(self.cycle, new_plan)
        self.assertEqual((self.state["phase"], self.state["status"]), ("code", "paused"))

    def test_reconciliation_cannot_bypass_publication_head_or_staging(self):
        path, _ = self.reconciliation_fixture()
        before = copy.deepcopy(self.state)
        for field, value in (("phase", "publish"), ("phase", "ci"), ("published", {"sha": "published"}),
                             ("publication_started", True), ("code_started", False)):
            with self.subTest(field=field, value=value):
                self.state.clear()
                self.state.update(copy.deepcopy(before))
                self.state[field] = value
                with self.assertRaisesRegex(Blocked, "before publication"):
                    focus_reconcile.prepare(self.cycle)
        self.state.clear()
        self.state.update(before)
        self.members["Root"].git("add", "source.txt")
        with self.assertRaisesRegex(Blocked, "index entries changed"):
            focus_reconcile.prepare(self.cycle)
        self.members["Root"].git("commit", "-m", "External publication")
        with self.assertRaisesRegex(Blocked, "HEAD changed"):
            focus_reconcile.prepare(self.cycle)

    def test_reconciliation_respects_pause_messages_and_runtime_ownership(self):
        import cc_focus
        self.reconciliation_fixture()
        pause = self.root / "Root/.work/PAUSE"
        pause.parent.mkdir(exist_ok=True)
        pause.write_text("operator stop")
        with self.assertRaisesRegex(Blocked, "PAUSE"):
            focus_reconcile.prepare(self.cycle)
        pause.unlink()
        with patch.object(self.cycle.messages, "unresolved", return_value=[{}]), \
                self.assertRaisesRegex(Blocked, "operator messages"):
            focus_reconcile.prepare(self.cycle)
        with LocalLock(self.store.directory), patch("cc_focus.Path.cwd", return_value=self.root), \
                patch("cycle_transport.Transport.run", side_effect=AssertionError("No model")), \
                contextlib.redirect_stderr(io.StringIO()) as output:
            self.assertEqual(cc_focus.main(["reconcile"]), 3)
        self.assertIn("Another owner holds", output.getvalue())

    @unittest.skipIf(os.name == "nt", "POSIX symlink fixture")
    def test_reconciliation_does_not_admit_shared_symlinks(self):
        self.reconciliation_fixture()
        (self.root / "HANDOFF.md").unlink()
        (self.root / "HANDOFF.md").symlink_to(self.root / "Core/AGENTS.md")
        with self.assertRaisesRegex(Blocked, "not symlinks"):
            focus_reconcile.prepare(self.cycle)

    def test_reconciliation_plan_cannot_overwrite_work_or_accept_duplicate_keys(self):
        path, _ = self.reconciliation_fixture()
        with self.assertRaises(FileExistsError):
            focus_reconcile.write_plan(self.cycle, path)
        for output in (self.root / "HANDOFF.md", self.root / ".work/cycle/fake.json",
                       self.root / ".work/control_state.json"):
            with self.assertRaisesRegex(Blocked, "plan destinations"):
                focus_reconcile.write_plan(self.cycle, output)
        self.assertFalse((self.root / ".work/control_state.json").exists())
        path.write_text('{"schema":"orchestra/focus-reconcile@1","schema":"orchestra/focus-reconcile@1"}')
        with self.assertRaisesRegex(Blocked, "duplicate plan key"):
            focus_reconcile.apply(self.cycle, path)

    def test_reconciliation_cli_is_model_free(self):
        import cc_focus
        self.reconciliation_fixture()
        plan_path = self.root / ".work" / "cli-plan.json"
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.ProjectLease") as lease, \
                patch("cycle_transport.Transport.run", side_effect=AssertionError("No model during reconciliation")):
            lease.return_value.__enter__.return_value.pwsh = "pwsh"
            self.assertEqual(cc_focus.main(["reconcile", "--plan-out", str(plan_path)]), 0)
            self.assertEqual(self.store.read()["status"], "blocked")
            self.assertEqual(cc_focus.main(["reconcile", "--apply-plan", str(plan_path)]), 0)
        saved = self.store.read()
        self.assertEqual((saved["phase"], saved["status"]), ("code", "paused"))
        self.assertIsNotNone(saved["correction_pending"])

    def test_reconciliation_cli_rejects_mixed_actions(self):
        import cc_focus
        for args in (["--apply-plan", "plan.json"], ["reconcile", "--plan-out", "plan.json", "--apply-plan", "plan.json"],
                     ["reconcile", "--handoff", "HANDOFF.md"], ["reconcile", "--retry"], ["reconcile", "--message", "text"]):
            with self.subTest(args=args), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                cc_focus.main(args)
            self.assertEqual(error.exception.code, 2)

    def test_reconciliation_publishes_adopted_work_in_its_repositories(self):
        self.edit("Specification", "operator.txt", "preserved staged work\n")
        self.members["Specification"].git("add", "operator.txt")
        path, _ = self.reconciliation_fixture()
        focus_reconcile.apply(self.cycle, path)
        # Simulate completed coding and both reviews of the newly owned files.
        reviewed = self.project.snapshot()
        self.state.update(phase="publish", coordinated="publish", correction_pending=None,
                          reviewed=reviewed, astra_clean=3, claude_clean=2)
        self.assertTrue(self.cycle.prepare_publish())
        self.assertEqual(set(self.state["publication_targets"]), {"Core", "Root"})
        core = self.members["Core"]
        core.git("add", "AGENTS.md", "owned.txt")
        core.git("commit", "-m", "Apply current requirements")
        core.git("push", "origin", "main")
        self.commit("Root")
        self.assertTrue(self.cycle.reconcile_publish())
        self.assertEqual(set(self.state["published"]["repositories"]), {"Core", "Root"})
        self.assertEqual(self.project.index_entries(self.state["protected"]), self.state["protected_index"])
        self.assertEqual(self.members["Specification"].text("rev-parse", "HEAD"), self.state["baseline"]["head"]["Specification"])
        self.assertEqual((self.root / "Root/untouched.txt").read_text(), "other operator work\n")

    def test_reconciliation_keeps_preexisting_content_owned_when_coding_reverts_latest_edit(self):
        path, _ = self.reconciliation_fixture()
        focus_reconcile.apply(self.cycle, path)
        self.edit("Root", text="previous operator work\n")
        self.edit("Core", "AGENTS.md", "previous operator instructions\n")
        owned = changed(self.state["baseline"], self.project.snapshot())
        self.assertIn("Root/source.txt", owned)
        self.assertIn("Core/AGENTS.md", owned)
        self.edit("Root", text="original\n")  # reverting to Git HEAD requires no Root commit
        self.assertNotIn("Root/source.txt", changed(self.state["baseline"], self.project.snapshot()))

    def test_reconciliation_handles_deleted_untracked_work_and_checkout_line_endings(self):
        core = self.members["Core"]
        self.edit("Core", ".gitattributes", "source.txt text eol=crlf\n")
        core.git("add", ".gitattributes")
        core.git("commit", "-m", "Declare checkout line endings")
        self.edit("Core", text="preexisting content\n")
        path, _ = self.reconciliation_fixture()
        # Supersede the proposal after deleting a previously untracked file.
        (self.root / "Core/AGENTS.md").unlink()
        self.edit("Core", text="authorized revision\n")
        plan = self.root / ".work/updated-plan.json"
        focus_reconcile.write_plan(self.cycle, plan)
        focus_reconcile.apply(self.cycle, plan)
        self.assertNotIn("Core/AGENTS.md", changed(self.state["baseline"], self.project.snapshot()))
        core.git("restore", "--source=HEAD", "--worktree", "source.txt")
        self.assertEqual((core.root / "source.txt").read_bytes(), b"original\r\n")
        self.assertNotIn("Core/source.txt", changed(self.state["baseline"], self.project.snapshot()))

    def test_protected_member_staging_is_preserved(self):
        self.edit("Root", "operator.txt", "operator\n")
        self.members["Root"].git("add", "operator.txt")
        self.state = fresh_state(self.project)
        self.cycle.state = self.state
        self.seal()
        self.assertTrue(self.cycle.prepare_publish())
        self.commit("Core")
        self.commit("Specification")
        self.assertTrue(self.cycle.reconcile_publish())
        self.assertEqual(self.project.index_entries(self.state["protected"]), self.state["protected_index"])
        self.assertEqual(self.members["Root"].text("rev-parse", "HEAD"), self.state["baseline"]["head"]["Root"])

    def test_only_changed_repositories_publish_and_receive_separate_ci_evidence(self):
        self.seal()
        def publish():
            self.commit("Core")
            self.commit("Specification")
            return fixtures.report()
        self.transport.actions = [("publish", publish)]
        self.cycle.publish()
        self.assertEqual(self.state["phase"], "ci")
        self.assertEqual(set(self.state["published"]["repositories"]), {"Core", "Specification"})
        context = self.transport.calls[0][1]
        self.assertIn('"publication_targets"', context)
        self.assertNotIn('"path": "Root"', context)
        self.cycle.wait_ci()
        for name in ("Core", "Specification"):
            result = json.loads((self.store.directory / "repositories" / name / "ci/result.json").read_text())
            self.assertEqual(result["sha"], self.members[name].text("rev-parse", "HEAD"))
        self.assertFalse((self.store.directory / "repositories/Root").exists())
        self.cycle.next_stage()
        saved = self.store.read()
        self.assertEqual(saved["iteration"], 2)
        self.assertNotIn("publication_targets", saved)
        self.assertNotIn("publication_repositories", saved)
        self.assertNotIn("remote", saved)

    def test_partial_push_survives_resume_without_repeating_a_completed_commit(self):
        self.seal()
        self.assertTrue(self.cycle.prepare_publish())
        self.commit("Core")
        self.commit("Specification", push=False)
        self.assertFalse(self.cycle.reconcile_publish())
        first_head = self.members["Core"].text("rev-parse", "HEAD")
        saved = self.store.read()
        self.assertEqual(saved["publication_repositories"]["Core"]["published"]["sha"], first_head)
        restarted = ProjectCycle(open_project(self.root), self.store, saved, self.transport,
                                 lambda: None, fixtures.REPO / "tools", "pwsh")
        self.assertTrue(restarted.prepare_publish())
        self.members["Specification"].git("push", "origin", "main")
        restarted.publish()
        self.assertEqual(self.transport.calls, [])
        self.assertEqual(self.members["Core"].text("rev-parse", "HEAD"), first_head)
        self.assertEqual(saved["phase"], "ci")

    def test_interrupted_publisher_reconciles_each_member_before_resuming_its_intent(self):
        self.seal()
        def interrupted():
            self.commit("Core")
            raise FocusStop("fixture interruption")
        self.transport.actions = [("publish", interrupted)]
        with self.assertRaises(FocusStop):
            self.cycle.publish()
        saved = self.store.read()
        invocation = saved["pending"]["id"]
        first_head = self.members["Core"].text("rev-parse", "HEAD")
        restarted = ProjectCycle(self.project, self.store, saved, self.transport, lambda: None,
                                 fixtures.REPO / "tools", "pwsh")
        def finish():
            self.assertEqual(saved["pending"]["id"], invocation)
            self.assertEqual(saved["publication_repositories"]["Core"]["published"]["sha"], first_head)
            self.commit("Specification")
            return fixtures.report()
        self.transport.actions = [("publish", finish)]
        restarted.publish()
        self.assertEqual(self.members["Core"].text("rev-parse", "HEAD"), first_head)
        self.assertEqual(saved["phase"], "ci")

    def test_full_project_cycle_reviews_combined_scope_before_publishing(self):
        def code():
            self.edit("Core")
            self.edit("Specification")
            return fixtures.report(description="One project stage changes Core and Specification.")
        def publish():
            self.assertEqual((self.state["astra_clean"], self.state["claude_clean"]), (3, 2))
            self.commit("Core")
            self.commit("Specification")
            return fixtures.report()
        done = fixtures.report()
        self.transport.actions = [("coordinate", done), ("code", code), ("coordinate", done),
            ("astra", done), ("astra", done), ("astra", done), ("coordinate", done),
            ("claude", done), ("claude", done), ("coordinate", done), ("publish", publish),
            ("coordinate", fixtures.report(status="complete"))]
        self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(self.state["iteration"], 2)
        archived = json.loads((self.store.directory / "iterations/000001.json").read_text())
        self.assertEqual(set(archived["published"]["repositories"]), {"Core", "Specification"})
        self.assertEqual(archived["display_ci"]["status"], "not-configured")

    def test_member_ci_failure_cannot_advance_the_project(self):
        self.seal()
        self.cycle.prepare_publish()
        self.commit("Core")
        self.commit("Specification")
        self.cycle.reconcile_publish()
        wait = MemberCycle.wait_ci
        def fail(member):
            if member.name == "Specification":
                raise Blocked("ci-failed", "fixture red CI")
            return wait(member)
        with patch.object(MemberCycle, "wait_ci", fail), self.assertRaisesRegex(Blocked, "red CI"):
            self.cycle.wait_ci()
        self.assertEqual((self.state["iteration"], self.state["phase"]), (1, "ci"))
        self.assertEqual(self.state["display_ci"]["passed"], 1)
        self.cycle.wait_ci()
        self.assertEqual(self.state["display_ci"]["passed"], 2)
        self.cycle.next_stage()
        self.assertEqual(self.state["iteration"], 2)

    def test_explicit_retry_refreshes_each_member_ci_deadline_consistently(self):
        import cc_focus
        self.seal()
        self.cycle.prepare_publish()
        self.commit("Core")
        self.commit("Specification")
        self.cycle.reconcile_publish()
        for name in self.state["published"]["repositories"]:
            self.state["published"]["repositories"][name]["at"] = 1
            self.state["publication_repositories"][name]["published"]["at"] = 1
        self.state["blocker"] = {"signature": "fixture", "status": "blocked"}
        self.store.save(self.state)
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.ProjectLease") as lease, \
                patch("cycle_workflow.Cycle.run", return_value=0):
            lease.return_value.__enter__.return_value.pwsh = "pwsh"
            self.assertEqual(cc_focus.main(["--retry", "--ui", "off"]), 0)
        saved = self.store.read()
        for name, published in saved["published"]["repositories"].items():
            self.assertGreater(published["at"], 1)
            self.assertEqual(published, saved["publication_repositories"][name]["published"])

    def test_reviewed_fix_after_partial_push_reopens_that_repositorys_publication(self):
        self.seal()
        self.cycle.prepare_publish()
        self.commit("Core")
        self.assertFalse(self.cycle.reconcile_publish())
        self.assertTrue(self.state["publication_repositories"]["Core"]["confirmed"])
        self.edit("Core", text="reviewed correction\n")
        self.state.update(reviewed=self.project.snapshot(), publication_started=True)
        self.assertTrue(self.cycle.prepare_publish())
        self.assertFalse(self.cycle.reconcile_publish())
        details = json.loads(self.cycle.context("publish").split("\n\nProject context:\n")[1])
        core = next(item for item in details["publication_targets"] if item["path"] == "Core")
        self.assertIsNone(core["published"])
        self.commit("Core")
        self.commit("Specification")
        self.assertTrue(self.cycle.reconcile_publish())

    def test_member_pause_is_respected_before_a_project_invocation(self):
        work = self.members["Root"].root / ".work"
        work.mkdir()
        (work / "PAUSE").touch()
        self.assertEqual(self.cycle.run(), 0)
        self.assertEqual(self.state["status"], "paused")
        self.assertEqual(self.transport.calls, [])
        self.assertTrue((work / "PAUSE").exists())

    def test_reviewed_fix_may_add_another_locked_member_after_partial_publication(self):
        self.seal()
        self.cycle.prepare_publish()
        self.commit("Core")
        self.assertFalse(self.cycle.reconcile_publish())
        self.edit("Root", text="reviewed related fix\n")
        self.state.update(reviewed=self.project.snapshot(), publication_started=True)
        self.assertTrue(self.cycle.prepare_publish())
        self.assertEqual(set(self.state["publication_targets"]), set(self.members))
        self.assertTrue(self.state["publication_repositories"]["Core"]["confirmed"])
        self.commit("Root")
        self.commit("Specification")
        self.assertTrue(self.cycle.reconcile_publish())

    def test_started_publication_cannot_drop_a_target(self):
        self.seal()
        self.cycle.prepare_publish()
        self.state["publication_started"] = True
        self.edit("Specification", text="original\n")
        self.state["reviewed"] = self.project.snapshot()
        with self.assertRaisesRegex(Blocked, "removed after publication started"):
            self.cycle.prepare_publish()

    @unittest.skipIf(os.name == "nt", "POSIX CI artifact symlink fixture")
    def test_member_ci_artifacts_cannot_escape_project_state(self):
        self.seal()
        self.cycle.prepare_publish()
        directory = self.store.directory / "repositories"
        directory.mkdir()
        external = Path(self.temp.name) / "external"
        external.mkdir()
        (directory / "Core").symlink_to(external, target_is_directory=True)
        with self.assertRaisesRegex(Blocked, "outside project state"):
            self.cycle.reconcile_publish()
        self.assertEqual(list(external.iterdir()), [])

    @unittest.skipIf(os.name == "nt", "POSIX real launcher and leases")
    def test_launcher_pauses_and_releases_all_real_member_leases_without_a_provider(self):
        cli = Path(shutil.which("processkit-cli") or
                   (Path(os.environ.get("ORCHESTRA_HOME", Path.home() / ".orchestra")) / "processkit-cli"))
        if not cli.is_file():
            self.skipTest("Optional ProcessKit CLI is unavailable")
        config = Path(self.temp.name) / "isolated-runtime"
        config.mkdir()
        (config / "root-config.md").write_text(f"CC_PROCESSKIT_CLI: {cli}\n")
        forbidden = config / "provider-called"
        for name in ("claude", "codex"):
            executable = config / name
            executable.write_text('#!/bin/sh\nprintf unexpected > "$ORCHESTRA_FIXTURE_CALLED"\nexit 97\n')
            executable.chmod(0o755)
        (self.root / ".work").mkdir()
        (self.root / ".work/PAUSE").touch()
        env = dict(os.environ, ORCHESTRA_HOME=str(config), ORCHESTRA_PROCESSKIT_ROOT_RUN_ID="",
                   ORCHESTRA_FIXTURE_CALLED=str(forbidden), PATH=str(config) + os.pathsep + os.environ["PATH"])
        result = subprocess.run(["pwsh", "-NoProfile", "-File", str(fixtures.REPO / "tools/focus-runtime.ps1"),
                                 "--ui", "off", "--handoff", str(self.root / "HANDOFF.md")],
                                cwd=self.root, env=env, capture_output=True, timeout=45)
        self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
        self.assertFalse(forbidden.exists())
        self.assertEqual(self.store.read()["status"], "paused")
        for root in [self.root, *(repo.root for repo in self.members.values())]:
            self.assertFalse(runtime_active(Store(root)))
            self.assertFalse((root / ".work/orchestrator.lock/lease.json").exists())
            self.assertFalse((root / ".work/cycle/project-owner.json").exists())

    def test_untouched_repository_commit_cannot_be_credited(self):
        self.seal(("Core",))
        self.assertTrue(self.cycle.prepare_publish())
        self.members["Root"].git("commit", "--allow-empty", "-m", "Unrelated")
        with self.assertRaisesRegex(Blocked, "outside this iteration"):
            self.cycle.reconcile_publish()

    def test_later_member_policy_blocks_before_any_provider_or_push(self):
        self.seal()
        def policy(member, verb, *args):
            return subprocess.CompletedProcess([], 1 if member.name == "Specification" else 0, b"", b"fixture denied")
        with patch.object(MemberCycle, "policy", policy), self.assertRaisesRegex(Blocked, "fixture denied"):
            self.cycle.publish()
        self.assertEqual(self.transport.calls, [])
        self.assertEqual(self.project.snapshot()["head"], self.state["baseline"]["head"])

    def test_remote_url_change_is_detected_before_replay(self):
        self.seal()
        self.cycle.prepare_publish()
        self.members["Specification"].git("remote", "set-url", "--push", "origin", str(self.remotes["Root"]))
        with self.assertRaisesRegex(Blocked, "push URL changed"):
            self.cycle.prepare_publish()

    def test_review_rejects_a_commit_in_any_member(self):
        self.state.update(phase="astra", coordinated="astra")
        def bad_review():
            self.members["Root"].git("commit", "--allow-empty", "-m", "Unauthorized")
            return fixtures.report()
        self.transport.actions = [("astra", bad_review)]
        with self.assertRaisesRegex(Blocked, "changed HEAD outside publication"):
            self.cycle.review("astra")

    def test_member_and_project_locks_exclude_overlapping_cycles(self):
        with contextlib.ExitStack() as stack:
            stack.enter_context(LocalLock(self.store.directory))
            fds = lock_members(self.project, stack)
            self.assertEqual(len(fds), 3)
            for name in self.members:
                with self.assertRaises(Blocked):
                    with LocalLock(Store(self.members[name].root).directory):
                        pass
            control = Control(self.store)
            control.begin()
            register_members(self.project, control, stack)
            with self.assertRaisesRegex(Blocked, "running project"):
                check_project_owner(Store(self.members["Core"].root))
            control.finish(self.state, 0)
        self.assertFalse((self.members["Core"].root / ".work/cycle/project-owner.json").exists())
        with contextlib.ExitStack() as stack:
            lock_members(self.project, stack)

    def test_crashed_parent_with_unconfirmed_provider_blocks_member_admission(self):
        control = Control(self.store)
        control.begin()
        control.active["provider_run"] = {"unknown": True}
        self.store.artifact("active.json", encode(control.active))
        with contextlib.ExitStack() as stack:
            lock_members(self.project, stack)
            register_members(self.project, control, stack)
        with self.assertRaisesRegex(Blocked, "Provider exit is unconfirmed"):
            check_project_owner(Store(self.members["Core"].root))

    def test_member_status_and_stop_address_the_parent_instead_of_a_stale_member_run(self):
        import cc_focus
        member_store = Store(self.members["Core"].root)
        old_control = Control(member_store)
        old_control.begin()
        with contextlib.ExitStack() as stack:
            stack.enter_context(LocalLock(self.store.directory))
            lock_members(self.project, stack)
            control = Control(self.store)
            control.begin()
            register_members(self.project, control, stack)
            out, err = io.StringIO(), io.StringIO()
            with patch("cc_focus.Path.cwd", return_value=member_store.root), \
                    patch("cc_focus.request_stop") as stop, contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                self.assertEqual(cc_focus.main(["status"]), 0)
                self.assertEqual(json.loads(out.getvalue())["project_root"], str(self.root))
                self.assertEqual(cc_focus.main(["stop", "--now"]), 3)
                stop.assert_not_called()
            self.assertFalse((member_store.directory / "stop.json").exists())
            control.finish(self.state, 0)


if __name__ == "__main__":
    unittest.main()
