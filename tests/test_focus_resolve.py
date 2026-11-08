"""Merge resolvers of parallel members with local Git remotes and test resolver scripts; no paid provider calls."""

import contextlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from test_focus_parallel import DONE, MEMBERS, PARALLEL, PLAN, PLAN_FILE, ParallelFixture  # It adds the tools directory.
from cycle_state import Blocked
from cycle_workflow import OPERATOR_CONTEXT_BLOCKERS
import focus_commit
from focus_control import FocusStop, status
import focus_parallel
from focus_project import parallel_config
import focus_resolve

MEMBER = "Interlink-plans"
BLOCKED = PLAN.replace("## Stage 1\n\nStatus: open.", "## Stage 1\n\nStatus: blocked.")
SUBJECT = "Mark stage 1 complete"
RESOLVER = r'''
import json, os, pathlib, subprocess, sys, time
mode = sys.argv[1]
paths = [os.fsdecode(p) for p in pathlib.Path(os.environ["CC_FOCUS_MERGE_PATHS"]).read_bytes().split(b"\0") if p]
inputs = json.loads(pathlib.Path(os.environ["CC_FOCUS_MERGE_INPUTS"]).read_text())
root = pathlib.Path(os.environ["CC_FOCUS_PROJECT_ROOT"])
with open(os.environ["RESOLVER_RECORD"], "a") as stream:
    stream.write(json.dumps({"mode": mode, "paths": paths, "cwd": os.getcwd(), "inputs": inputs,
                             "member": (root / "Interlink-plans" / "plan" / "s2-adaptation.md").read_text(),
                             "pause": (root / "Interlink-plans" / ".work" / "PAUSE").exists(),
                             "text": {path: pathlib.Path(path).read_text() for path in paths},
                             "env": {k: v for k, v in os.environ.items() if k.startswith("CC_FOCUS_")}}) + "\n")
def version(path, side):
    oid = inputs["paths"][path][side]
    return subprocess.run(["git", "cat-file", "blob", oid], capture_output=True, check=True).stdout if oid else b""
if mode == "fail":
    print("resolver output before the failure")
    sys.exit(3)
if mode == "sleep":
    pathlib.Path(os.environ["RESOLVER_RECORD"] + ".started").write_text("started")
    time.sleep(60)
for path in paths:
    text = version(path, "stage") + ("Resolved by " + sys.argv[-1] + ".\n").encode()
    if mode == "markers":
        text = b"<<<<<<< ours\n" + text
    if mode == "equals":
        text = b"=======\n" + text
    if mode != "keep" and mode != "remove":
        pathlib.Path(path).write_bytes(text)
    if mode == "remove":
        pathlib.Path(path).unlink()
if mode == "other":
    pathlib.Path("source.txt").write_text("changed by the resolver\n")
if mode == "untracked":
    pathlib.Path("plan/new-file.md").write_text("new\n")
if mode == "ignored":
    pathlib.Path(".work").mkdir(exist_ok=True)
    pathlib.Path(".work/build-output").write_text("ignored\n")
if mode == "member":
    (root / "Interlink" / "source.txt").write_text("changed by the resolver\n")
if mode == "root":
    (root / "notes.md").write_text("changed by the resolver\n")
if mode == "head":
    subprocess.run(["git", "-c", "user.name=R", "-c", "user.email=r@example.invalid", "commit", "-q", "--allow-empty",
                    "-m", "Resolver commit"], check=True)
if mode == "check-change":
    for path in inputs["paths"]:
        pathlib.Path(path).write_text("changed by the check\n")
'''


class ResolverFixture(ParallelFixture):
    def setUp(self):
        super().setUp()
        self.script = Path(self.temp.name) / "resolver.py"
        self.script.write_text(RESOLVER)
        self.records = Path(self.temp.name) / "records.jsonl"
        self.environment = patch.dict(os.environ, RESOLVER_RECORD=str(self.records))
        self.environment.start()
        self.write_manifest()
        self.open()

    def tearDown(self):
        self.environment.stop()
        super().tearDown()

    def rule(self, name="plan", paths=("plan/*.md",), mode="merge", timeout=None):
        rule = {"name": name, "paths": list(paths), "command": [sys.executable, str(self.script), mode, name]}
        if timeout:
            rule["timeout"] = timeout
        return rule

    def write_manifest(self, rules=None, check=None, member=MEMBER):
        entry = {"rules": rules or [self.rule()]}
        if check:
            entry["check"] = check
        (self.root / "focus-project.json").write_text(json.dumps(
            {"version": 1, "repositories": MEMBERS, "parallel": PARALLEL, "resolvers": {member: entry}}))

    def use(self, rules=None, check=None):
        """Change the resolvers of the current stage. The manifest gives them only at the next stage."""
        spec = {"rules": [dict(rule, timeout=rule.get("timeout", 1800)) for rule in (rules or [self.rule()])]}
        if check:
            spec["check"] = dict(check, timeout=check.get("timeout", 1800))
        self.state["resolvers"] = {MEMBER: spec}

    def check(self, mode="keep"):
        return {"command": [sys.executable, str(self.script), mode, "check"]}

    def conflict(self, text=BLOCKED, path=PLAN_FILE):
        return self.push_other(MEMBER, path, text)

    def calls(self):
        return [json.loads(line) for line in self.records.read_text().splitlines()] if self.records.exists() else []

    def worktrees(self):
        folder = self.root / ".work" / "r"
        return sorted(path.name for path in folder.iterdir()) if folder.exists() else []

    def registered(self):
        output = self.members[MEMBER].text("worktree", "list", "--porcelain")
        return [line for line in output.splitlines() if line.startswith("worktree ")][1:]

    def assert_closed(self, local):
        """After a refusal: no worktree, no record, and the member checkout is the stage commit."""
        self.assertEqual(self.worktrees(), [])
        self.assertEqual(self.registered(), [])
        self.assertNotIn(MEMBER, self.state.get("parallel_integrations", {}))
        self.assertNotIn(MEMBER, self.store.read().get("parallel_integrations", {}))
        self.assertEqual(self.head(MEMBER), local)
        self.assertEqual(self.members[MEMBER].dirty_paths(), [])

    def refused(self, code):
        local = self.head(MEMBER)
        remote = self.remote(MEMBER)
        error = self.blocked(lambda: self.cycle.execute_publication(SUBJECT), code)
        self.assert_closed(local)
        self.assertEqual(self.remote(MEMBER), remote)
        return error

    def published(self, path=PLAN_FILE):
        repo = self.members[MEMBER]
        return repo.git("show", self.remote(MEMBER) + ":" + path).stdout.decode()


class ManifestTests(ResolverFixture):
    def test_a_valid_key_gives_the_rules_and_the_check_with_default_timeouts(self):
        self.write_manifest([self.rule(), self.rule("other", ("*.txt",), timeout=3600)], check=self.check())
        parallel, resolvers = parallel_config(self.root)
        self.assertEqual(parallel, PARALLEL)
        rules = resolvers[MEMBER]["rules"]
        self.assertEqual([rule["name"] for rule in rules], ["plan", "other"])
        self.assertEqual([rule["timeout"] for rule in rules], [1800, 3600])
        self.assertEqual(resolvers[MEMBER]["check"]["timeout"], 1800)
        self.write_manifest()
        self.assertNotIn("check", parallel_config(self.root)[1][MEMBER])

    def test_the_manifest_refuses_bad_values(self):
        good = self.rule()
        cases = {
            "unknown member key": {MEMBER: {"rules": [good], "extra": 1}},
            "not parallel": {"Interlink": {"rules": [good]}},
            "no rules": {MEMBER: {"rules": []}},
            "seventeen rules": {MEMBER: {"rules": [dict(good, name=f"r{n}") for n in range(17)]}},
            "repeated name": {MEMBER: {"rules": [good, good]}},
            "bad name": {MEMBER: {"rules": [dict(good, name="a b")]}},
            "unknown rule key": {MEMBER: {"rules": [dict(good, shell=True)]}},
            "no paths": {MEMBER: {"rules": [dict(good, paths=[])]}},
            "empty command": {MEMBER: {"rules": [dict(good, command=[])]}},
            "empty program": {MEMBER: {"rules": [dict(good, command=[""])]}},
            "string command": {MEMBER: {"rules": [dict(good, command="python3 resolve.py")]}},
            "short timeout": {MEMBER: {"rules": [dict(good, timeout=59)]}},
            "long timeout": {MEMBER: {"rules": [dict(good, timeout=7201)]}},
            "boolean timeout": {MEMBER: {"rules": [dict(good, timeout=True)]}},
            "bad check": {MEMBER: {"rules": [good], "check": {"command": [], "timeout": 60}}},
            "check key": {MEMBER: {"rules": [good], "check": {"command": ["x"], "paths": []}}},
            "list": [],
        }
        for pattern in ("/plan/*.md", "plan/../x", "plan/[ab].md", "plan\\x.md", "!plan.md", "plan/**.md", "a**",
                        "plan/", "plan//x.md", "./plan.md", "plan/./x.md", ""):
            cases["pattern " + pattern] = {MEMBER: {"rules": [dict(good, paths=[pattern])]}}
        for case, resolvers in cases.items():
            with self.subTest(case=case):
                (self.root / "focus-project.json").write_text(json.dumps(
                    {"version": 1, "repositories": MEMBERS, "parallel": PARALLEL, "resolvers": resolvers}))
                self.blocked(lambda: parallel_config(self.root), "project-manifest")

    def test_a_stage_and_a_campaign_stage_record_the_resolvers_with_the_parallel_set(self):
        self.assertEqual(self.state["resolvers"][MEMBER]["rules"][0]["name"], "plan")
        self.write_manifest([self.rule("next")])
        self.assertEqual(self.state["resolvers"][MEMBER]["rules"][0]["name"], "plan")  # The stage keeps its record.
        self.cycle.sync_parallel("cc-focus --retry")
        self.cycle.advance_stage(self.cycle.snapshot(), [], {})
        self.assertEqual(self.state["resolvers"][MEMBER]["rules"][0]["name"], "next")
        from focus_review_run import create_run
        from focus_review_scope import make_request
        self.open()
        _, state = create_run(self.project, make_request(scope="Inspect the migration"))
        self.assertEqual(state["resolvers"][MEMBER]["rules"][0]["name"], "next")
        self.assertEqual(state["parallel"], PARALLEL)

    def test_the_admission_records_the_resolvers_of_the_manifest(self):
        self.write_manifest([self.rule("admitted")])
        self.cycle.admit_parallel()
        self.assertEqual(self.state["resolvers"][MEMBER]["rules"][0]["name"], "admitted")
        self.assertEqual(self.store.read()["resolvers"][MEMBER]["rules"][0]["name"], "admitted")

    def test_a_manifest_without_the_key_and_an_older_state_have_no_rules(self):
        (self.root / "focus-project.json").write_text(json.dumps({"version": 1, "repositories": MEMBERS, "parallel": PARALLEL}))
        self.open()
        self.assertEqual(self.state["resolvers"], {})
        del self.state["resolvers"]
        self.conflict()
        self.commit_only()
        error = self.refused("parallel-merge-conflict")
        self.assertNotIn("No resolver", str(error))
        self.assertEqual(self.calls(), [])


class MatcherTests(unittest.TestCase):
    PATTERNS = ["*.g.cs", "Generated", "a/*.txt", "a/**", "**/b.txt", "a/**/b.txt", "**", "a/*/c/*.txt", "?.txt",
                "tests/*/Suite*.verified.txt", "tests/**/Generated/*.g.cs", "**/**", ".hidden", "a/**/**/b.txt", "*",
                "x?y/*", "a/b.txt", "**/a/**", "A/b.txt"]
    PATHS = ["x.g.cs", "a/x.g.cs", "a/b/x.g.cs", "Generated", "a/Generated", "a/Generated/x", "a/x.txt", "a/b/x.txt", "a",
             "a/b.txt", "b.txt", "x/b.txt", "a/x/y/b.txt", "a/c/x.txt", "a/x/c/y.txt", "a.txt", "ab.txt",
             "tests/One/SuiteInventoryTests.x.verified.txt", "tests/One/Two/Suite.verified.txt", "tests/Generated/x.g.cs",
             "tests/p/q/Generated/x.g.cs", ".hidden", "d/.hidden", "xzy/f", "x/y/f", "a/b/c", "q/a/r", "A/b.txt"]

    def test_the_matcher_agrees_with_git_check_attr(self):
        with tempfile.TemporaryDirectory(prefix="focus-matcher-") as temp:
            subprocess.run(["git", "init", "-q", temp], check=True)
            subprocess.run(["git", "-C", temp, "config", "core.ignorecase", "false"], check=True)
            for pattern in self.PATTERNS:
                Path(temp, ".git", "info", "attributes").write_text(pattern + " probe\n")
                output = subprocess.run(["git", "-C", temp, "check-attr", "-z", "--stdin", "probe"], check=True,
                                        input=b"".join(path.encode() + b"\0" for path in self.PATHS),
                                        capture_output=True).stdout.split(b"\0")
                git = {path.decode(): value == b"set" for path, value in zip(output[0::3], output[2::3])}
                for path in self.PATHS:
                    with self.subTest(pattern=pattern, path=path):
                        self.assertEqual(focus_resolve.matches(pattern, path), git[path])


class ResolutionTests(ResolverFixture):
    def test_a_text_conflict_in_a_covered_file_is_resolved_and_published(self):
        other = self.conflict()
        (self.root / MEMBER / ".work").mkdir(exist_ok=True)
        (self.root / MEMBER / ".work" / "PAUSE").write_text("")
        self.commit_only()
        local = self.head(MEMBER)
        self.cycle.execute_publication(SUBJECT)
        self.assertTrue(self.cycle.reconcile_publish())
        repo = self.members[MEMBER]
        self.assertEqual(repo.text("rev-parse", "HEAD^"), other)
        self.assertEqual(self.published(), DONE + "Resolved by plan.\n")
        self.assertEqual(repo.text("log", "-1", "--format=%s"), SUBJECT)
        record = self.state["parallel_integrations"][MEMBER]
        self.assertEqual(record["step"], "complete")
        self.assertEqual(record["resolved"], {PLAN_FILE: "plan"})
        self.assertEqual(self.state["publication_resolutions"][0]["paths"], {PLAN_FILE: "plan"})
        call = self.calls()[0]
        self.assertEqual(call["paths"], [PLAN_FILE])
        self.assertIn("<<<<<<<", call["text"][PLAN_FILE])
        self.assertEqual(call["member"], DONE)  # The member checkout did not change during the resolution.
        self.assertTrue(call["pause"])
        self.assertEqual(Path(call["cwd"]).parent, self.root / ".work" / "r")
        self.assertEqual(call["env"]["CC_FOCUS_MERGE_REMOTE"], other)
        self.assertEqual(call["env"]["CC_FOCUS_MERGE_STAGE"], local)
        self.assertEqual(call["env"]["CC_FOCUS_PROJECT_ROOT"], str(self.root))
        self.assertTrue((self.root / MEMBER / ".work" / "PAUSE").exists())
        self.assertEqual(self.worktrees(), [])
        self.assertEqual(self.registered(), [])
        evidence = json.loads(Path(record["evidence"]).read_text())
        self.assertEqual(evidence["result"], record["result"])
        self.assertEqual([run["exit"] for run in evidence["runs"]], [0])
        self.assertEqual(evidence["paths"][PLAN_FILE]["rule"], "plan")
        self.assertIn("result_tree", evidence)

    def test_a_resolver_of_the_merged_tree_runs_and_the_evidence_names_its_blob(self):
        script = self.push_other(MEMBER, "tools/resolve.py", RESOLVER, "Add the resolver")
        self.use([dict(self.rule(), command=[sys.executable, "tools/resolve.py", "merge", "merged-tree"])])
        self.conflict()
        self.commit_only()
        self.cycle.execute_publication(SUBJECT)
        self.assertTrue(self.published().endswith("Resolved by merged-tree.\n"))
        evidence = json.loads(Path(self.state["parallel_integrations"][MEMBER]["evidence"]).read_text())
        self.assertEqual(evidence["resolver_files"],
                         {"tools/resolve.py": self.members[MEMBER].text("rev-parse", script + ":tools/resolve.py")})

    def test_inputs_give_the_exact_blobs_also_for_an_add_add_conflict(self):
        base = self.members[MEMBER].text("rev-parse", "HEAD:" + PLAN_FILE)
        self.conflict()
        self.conflict("Added by another writer.\n", "plan/added.md")
        (self.root / MEMBER / "plan/added.md").write_text("Added by the stage.\n")
        self.commit_only()
        repo = self.members[MEMBER]
        self.cycle.execute_publication(SUBJECT)
        inputs = self.calls()[0]["inputs"]
        self.assertEqual(sorted(inputs["paths"]), ["plan/added.md", PLAN_FILE])
        added = inputs["paths"]["plan/added.md"]
        self.assertIsNone(added["base"])
        self.assertEqual(repo.git("cat-file", "blob", added["remote"]).stdout, b"Added by another writer.\n")
        self.assertEqual(repo.git("cat-file", "blob", added["stage"]).stdout, b"Added by the stage.\n")
        self.assertEqual(inputs["paths"][PLAN_FILE]["base"], base)
        self.assertEqual(inputs["paths"][PLAN_FILE]["mode"], "100644")
        self.assertEqual(self.published("plan/added.md"), "Added by the stage.\nResolved by plan.\n")

    def test_two_rules_run_in_manifest_order_with_their_own_paths(self):
        self.use([self.rule("second", ("plan/added.md",)), self.rule("first", ("s2-*.md",))])
        self.conflict()
        self.conflict("Added by another writer.\n", "plan/added.md")
        (self.root / MEMBER / "plan/added.md").write_text("Added by the stage.\n")
        self.commit_only()
        self.cycle.execute_publication(SUBJECT)
        self.assertEqual([(call["paths"], call["mode"]) for call in self.calls()],
                         [(["plan/added.md"], "merge"), ([PLAN_FILE], "merge")])
        self.assertIn("<<<<<<<", self.calls()[0]["text"].get("plan/added.md"))
        self.assertTrue(self.published().endswith("Resolved by first.\n"))

    def test_the_check_runs_on_the_resolved_tree(self):
        self.use(check=self.check())
        self.conflict()
        self.commit_only()
        self.cycle.execute_publication(SUBJECT)
        check = self.calls()[1]
        self.assertEqual(check["paths"], [PLAN_FILE])
        self.assertEqual(check["text"][PLAN_FILE], DONE + "Resolved by plan.\n")

    def test_a_failed_check_and_a_check_that_changes_the_tree_or_the_project_stop_before_the_push(self):
        for mode, code in (("fail", "parallel-resolver-failed"), ("check-change", "parallel-resolver-scope"),
                           ("member", "parallel-resolver-scope")):
            with self.subTest(mode=mode):
                self.tearDown()
                self.setUp()
                self.use(check=self.check(mode))
                self.conflict()
                self.commit_only()
                self.refused(code)

    def test_a_second_integration_after_a_move_runs_the_rules_again(self):
        self.conflict()
        self.commit_only()
        original, moves = focus_parallel.integrate, []

        def integrate_then_move(cycle, name):
            result = original(cycle, name)
            if result and name == MEMBER and not moves:
                moves.append(self.conflict(BLOCKED.replace("Status: blocked.", "Status: blocked again.")))
            return result
        with patch.object(focus_parallel, "integrate", integrate_then_move):
            self.cycle.execute_publication(SUBJECT)
        self.assertTrue(self.cycle.reconcile_publish())
        self.assertEqual(self.members[MEMBER].text("rev-parse", "HEAD^"), moves[0])
        self.assertEqual(len(self.calls()), 2)
        # One entry for the member: the paths of both resolutions and the published merge commit.
        resolutions = self.state["publication_resolutions"]
        self.assertEqual(len(resolutions), 1)
        self.assertEqual(resolutions[0]["paths"], {PLAN_FILE: "plan"})
        self.assertEqual(resolutions[0]["result"], self.remote(MEMBER))
        self.assertEqual(len(resolutions[0]["evidence"]), 2)
        self.assertIn("Status: blocked again.", self.calls()[1]["text"][PLAN_FILE])

    def test_a_clean_second_integration_names_the_published_merge_commit(self):
        self.conflict()
        self.commit_only()
        original, moves = focus_parallel.integrate, []

        def integrate_then_move(cycle, name):
            result = original(cycle, name)
            if result and name == MEMBER and not moves:
                moves.append(self.push_other(MEMBER, "plan/race.md", "Race.\n"))
            return result
        with patch.object(focus_parallel, "integrate", integrate_then_move):
            self.cycle.execute_publication(SUBJECT)
        self.assertEqual(len(self.calls()), 1)
        resolutions = self.state["publication_resolutions"]
        self.assertEqual(len(resolutions), 1)
        self.assertEqual(resolutions[0]["result"], self.remote(MEMBER))
        self.assertEqual(resolutions[0]["paths"], {PLAN_FILE: "plan"})

    def test_a_mode_change_on_one_side_keeps_the_mode_of_t(self):
        repo = self.other[MEMBER]
        repo.git("pull", "-q", "--ff-only")
        (repo.root / PLAN_FILE).write_text(BLOCKED)
        repo.git("add", "-A")
        repo.git("update-index", "--chmod=+x", PLAN_FILE)
        repo.git("commit", "-qm", "Executable plan")
        repo.git("push", "-q", "origin", "main")
        self.commit_only()
        self.cycle.execute_publication(SUBJECT)
        tree = self.members[MEMBER].text("ls-tree", self.remote(MEMBER), "--", PLAN_FILE)
        self.assertTrue(tree.startswith("100755 "), tree)
        self.assertEqual(self.calls()[0]["inputs"]["paths"][PLAN_FILE]["mode"], "100755")

    def test_a_deep_path_resolves_in_the_worktree(self):
        deep = "plan/" + "/".join("level-%02d" % n for n in range(12)) + "/deep.md"
        self.conflict("Deep of another writer.\n", deep)
        (self.root / MEMBER / deep).parent.mkdir(parents=True)
        (self.root / MEMBER / deep).write_text("Deep of the stage.\n")
        self.use([self.rule(paths=("plan/**/deep.md", "plan/*.md"))])
        self.commit_only()
        self.cycle.execute_publication(SUBJECT)
        self.assertEqual(self.published(deep), "Deep of the stage.\nResolved by plan.\n")

    def test_a_member_attribute_file_does_not_change_the_covered_paths(self):
        # The stage adds an attribute file that sets and unsets attributes. The rules still cover the same paths.
        for covered in (True, False):
            with self.subTest(covered=covered):
                self.tearDown()
                self.setUp()
                (self.root / MEMBER / ".gitattributes").write_text(
                    "plan/*.md -diff -plan\n* plan resolvers=plan\nplan/s2-adaptation.md -text\n")
                if not covered:
                    self.use([self.rule(paths=("other/*.md",))])
                self.conflict()
                self.commit_only()
                if covered:
                    self.cycle.execute_publication(SUBJECT)
                    self.assertEqual(self.state["parallel_integrations"][MEMBER]["resolved"], {PLAN_FILE: "plan"})
                else:
                    self.refused("parallel-merge-conflict")

    def test_the_progress_line_names_the_rule_and_the_member(self):
        notes = []

        class Progress:
            on_update = None

            def runtime(self, operation):
                pass

            def note(self, text):
                notes.append(text)

            def finish(self):
                pass
        self.use(check=self.check())
        self.conflict()
        self.commit_only()
        self.cycle.progress = Progress()
        self.cycle.execute_publication(SUBJECT)
        self.assertIn(f"Resolver plan for {MEMBER}; no model is running", notes)
        self.assertIn(f"The check command for {MEMBER}; no model is running", notes)

    def test_a_line_of_equal_signs_is_accepted(self):
        self.use([self.rule(mode="equals")])
        self.conflict()
        self.commit_only()
        self.cycle.execute_publication(SUBJECT)
        self.assertTrue(self.published().startswith("=======\n"))

    def test_status_shows_an_open_resolution(self):
        self.conflict()
        self.commit_only()
        seen = []

        def look(*args, **kwargs):
            seen.append(status(self.store, self.store.read()))
            return original(*args, **kwargs)
        original = focus_resolve.run_rules
        with patch.object(focus_resolve, "run_rules", look):
            self.cycle.execute_publication(SUBJECT)
        record = seen[0]["parallel_integrations"][MEMBER]
        self.assertEqual((record["step"], record["result"], record["resolved"]), ("resolving", None, {PLAN_FILE: "plan"}))


class ConflictRefusalTests(ResolverFixture):
    def test_an_uncovered_conflict_names_the_path(self):
        self.use([self.rule(paths=("other/*.md",))])
        self.conflict()
        self.commit_only()
        error = self.refused("parallel-merge-conflict")
        self.assertIn("No resolver of focus-project.json can resolve " + PLAN_FILE, str(error))
        self.assertEqual(self.calls(), [])

    def test_a_conflict_that_git_names_only_in_its_messages_stops(self):
        for resolvers in (True, False):
            with self.subTest(resolvers=resolvers):
                self.tearDown()
                self.setUp()
                self.push_other(MEMBER, "plan/a/x.md", "x\n")
                self.push_other(MEMBER, "plan/b/y.md", "y\n")
                self.cycle.admit_parallel()  # The stage starts with both directories.
                repo = self.other[MEMBER]
                repo.git("pull", "-q", "--ff-only")
                (repo.root / "plan" / "c").mkdir()
                repo.git("mv", "plan/a/x.md", "plan/c/x.md")
                repo.git("mv", "plan/b/y.md", "plan/c/y.md")
                repo.git("commit", "-qm", "Move both directories")
                repo.git("push", "-q", "origin", "main")
                for name in ("a", "b"):
                    (self.root / MEMBER / "plan" / name / "z.md").write_text(name + "\n")
                if not resolvers:
                    self.state["resolvers"] = {}
                self.commit_only()
                error = self.refused("parallel-merge-conflict")
                merged = self.members[MEMBER].git("merge-tree", "--write-tree", "--no-messages", "-z", "origin/main",
                                                  "HEAD", check=False)
                self.assertEqual((merged.returncode, focus_resolve.conflict_entries(merged.stdout)[1]), (1, {}))
                self.assertIn("plan/c/z.md", str(error))
                self.assertEqual("No resolver" in str(error), resolvers)
                self.assertEqual(self.calls(), [])

    def test_message_paths_read_only_conflict_messages(self):
        output = (b"tree\0\0" + b"1\0plan/x.md\0Auto-merging\0Auto-merging plan/x.md\n\0"
                  + b"2\0plan/c/z.md\0plan/a/z.md\0CONFLICT (directory rename collision)\0Text\0")
        self.assertEqual(focus_resolve.message_paths(output), ["plan/a/z.md", "plan/c/z.md"])
        self.assertEqual(focus_resolve.message_paths(b"tree\0\0bad\0"), [])

    def test_a_deletion_a_rename_and_a_binary_file_stop(self):
        for case in ("deletion", "rename", "binary"):
            with self.subTest(case=case):
                self.tearDown()
                self.setUp()
                if case == "deletion":
                    self.conflict(None)
                elif case == "rename":
                    repo = self.other[MEMBER]
                    repo.git("pull", "-q", "--ff-only")
                    repo.git("mv", PLAN_FILE, "plan/s2.md")
                    (repo.root / "plan/s2.md").write_text(BLOCKED)
                    repo.git("commit", "-qam", "Rename and change")
                    repo.git("push", "-q", "origin", "main")
                else:
                    self.conflict("binary\0remote\n", "plan/data.md")
                    (self.root / MEMBER / "plan/data.md").write_text("binary\0stage\n")
                self.commit_only()
                error = self.refused("parallel-merge-conflict")
                self.assertIn("No resolver", str(error))
                self.assertEqual(self.calls(), [])

    def test_a_filter_attribute_in_h_or_only_in_t_stops(self):
        for case in ("stage", "remote"):
            with self.subTest(case=case):
                self.tearDown()
                self.setUp()
                if case == "stage":
                    (self.root / MEMBER / ".gitattributes").write_text("plan/*.md ident\n")
                    self.conflict()
                else:
                    self.push_other(MEMBER, ".gitattributes", "plan/*.md filter=fixture\n")
                    self.conflict()
                self.commit_only()
                error = self.refused("parallel-merge-conflict")
                self.assertIn("No resolver of focus-project.json can resolve " + PLAN_FILE, str(error))
                self.assertEqual(self.calls(), [])
                self.assertNotIn("resolver_cleanup", self.state)


class FailureTests(ResolverFixture):
    def test_a_failed_rule_and_a_rule_output_with_errors_stop(self):
        cases = {"fail": "exited with code 3", "markers": "left conflict markers", "keep": "did not change",
                 "remove": "removed " + PLAN_FILE}
        for mode, text in cases.items():
            with self.subTest(mode=mode):
                self.tearDown()
                self.setUp()
                self.use([self.rule(mode=mode)])
                self.conflict()
                self.commit_only()
                error = self.refused("parallel-resolver-failed")
                self.assertIn(text, str(error))
                self.assertIn("Read the log", str(error))
                self.assertIn("merge FETCH_HEAD into main", str(error))
                if mode == "fail":
                    self.assertIn("resolver output before the failure", str(error))
                evidence = sorted((self.store.directory / "resolve").glob("resolution-*.json"))
                self.assertEqual(len(evidence), 1)
                self.assertIn("error", json.loads(evidence[0].read_text()))

    def test_a_deadline_stops_the_rule(self):
        self.use([dict(self.rule(mode="sleep"), timeout=1)])
        self.conflict()
        self.commit_only()
        error = self.refused("parallel-resolver-failed")
        self.assertIn("did not complete in 1 seconds", str(error))

    def test_a_stop_request_interrupts_the_rule(self):
        self.use([self.rule(mode="sleep")])
        self.conflict()
        self.commit_only()
        started = Path(str(self.records) + ".started")

        def heartbeat():
            if started.exists():
                raise FocusStop("Emergency stop requested by the operator.")
        self.cycle.heartbeat = heartbeat
        local = self.head(MEMBER)
        with self.assertRaises(FocusStop):
            self.cycle.execute_publication(SUBJECT)
        self.assert_closed(local)

    @unittest.skipIf(os.name == "nt", "A Windows job ends every child process, also a detached one.")
    def test_a_process_that_keeps_running_stops_with_the_command_in_the_message(self):
        pidfile = Path(self.temp.name) / "daemon.pid"
        daemon = ("import subprocess, sys; process = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(40)'], "
                  "start_new_session=True); open(sys.argv[1], 'w').write(str(process.pid))")
        self.use(check={"command": [sys.executable, "-c", daemon, str(pidfile)]})
        self.conflict()
        self.commit_only()
        try:
            error = self.refused("cleanup-incomplete")
        finally:
            if pidfile.exists():
                with contextlib.suppress(ProcessLookupError):
                    os.kill(int(pidfile.read_text()), signal.SIGKILL)
        self.assertIn("the check command left a running process", str(error))
        self.assertIn("turn off the build server", str(error))

    def test_a_program_that_cannot_start_stops(self):
        self.use([dict(self.rule(), command=[str(Path(self.temp.name) / "missing-program")])])
        self.conflict()
        self.commit_only()
        error = self.refused("parallel-resolver-failed")
        self.assertIn("could not start", str(error))


class ScopeTests(ResolverFixture):
    def test_changes_outside_the_rule_paths_stop(self):
        cases = {"other": "source.txt", "untracked": "plan/new-file.md", "member": "Interlink/source.txt",
                 "root": "notes.md", "head": "HEAD"}
        for mode, path in cases.items():
            with self.subTest(mode=mode):
                self.tearDown()
                self.setUp()
                self.use([self.rule(mode=mode)])
                self.conflict()
                self.commit_only()
                error = self.refused("parallel-resolver-scope")
                self.assertIn(path, str(error))
                self.assertIn("Correct the resolver on remote main", str(error))

    def test_a_change_of_a_path_of_another_rule_stops(self):
        self.use([self.rule("first", ("s2-*.md",)), self.rule("second", ("plan/added.md",))])
        self.conflict()
        self.conflict("Added by another writer.\n", "plan/added.md")
        (self.root / MEMBER / "plan/added.md").write_text("Added by the stage.\n")
        self.commit_only()
        original = focus_resolve.run_step

        def write_both(cycle, name, repo, head, label, spec, worktree, *args):
            original(cycle, name, repo, head, label, spec, worktree, *args)
            if label == "resolver first":
                (worktree / "plan/added.md").write_text("Written by the first rule.\n")
        with patch.object(focus_resolve, "run_step", write_both):
            error = self.refused("parallel-resolver-scope")
        self.assertIn("plan/added.md", str(error))

    def test_ignored_build_output_is_not_checked(self):
        self.use([self.rule(mode="ignored")])
        self.conflict()
        self.commit_only()
        self.cycle.execute_publication(SUBJECT)
        self.assertEqual(self.worktrees(), [])

    def test_the_three_codes_start_no_recovery_agent(self):
        for code in ("parallel-resolver-failed", "parallel-resolver-scope", "parallel-resolver-cleanup"):
            with self.subTest(code=code):
                self.assertIn(code, OPERATOR_CONTEXT_BLOCKERS)
                self.state.update(blocker=None, pending=None, healed=[], recovery_unverified=False)
                self.cycle.handle_block(Blocked(code, "Fixture diagnosis"))
                self.assertEqual(self.state["blocker"]["escalation_reason"], "operator-context")


class RecoveryTests(ResolverFixture):
    def crash(self, where):
        """The run dies during a resolution: the record and the worktree stay."""
        self.conflict()
        self.commit_only()
        original = focus_commit.run_git

        def stop_at_read_tree(cycle, *args, **kwargs):
            if args[0] == "read-tree":
                raise KeyboardInterrupt
            return original(cycle, *args, **kwargs)
        rule = patch.object(focus_resolve, "run_step", side_effect=KeyboardInterrupt)
        tree = patch.object(focus_commit, "run_git", stop_at_read_tree)
        with (rule if where == "rule" else tree), patch.object(focus_resolve, "discard"), self.assertRaises(KeyboardInterrupt):
            self.cycle.execute_publication(SUBJECT)
        record = self.store.read()["parallel_integrations"][MEMBER]
        self.assertEqual((record["step"], record["result"]), ("resolving", None))
        self.assertTrue(Path(record["worktree"]).exists())
        self.assertEqual(record["local"], self.head(MEMBER))
        # A stale index lock of the worktree goes with the worktree.
        gitdir = subprocess.run(["git", "-C", record["worktree"], "rev-parse", "--absolute-git-dir"], check=True,
                                capture_output=True, text=True).stdout.strip()
        Path(gitdir, "index.lock").write_text("")
        return record

    def test_resume_removes_the_worktree_and_the_record_and_the_next_attempt_resolves_again(self):
        for where in ("rule", "read-tree"):
            with self.subTest(where=where):
                self.tearDown()
                self.setUp()
                record = self.crash(where)
                self.assertTrue(self.cycle.prepare_publish())  # It resolves the record first.
                self.assertFalse(Path(record["worktree"]).exists())
                self.assert_closed(record["local"])
                self.cycle.execute_publication(SUBJECT)
                self.assertTrue(self.cycle.reconcile_publish())
                self.assertEqual(len(self.calls()), 1)

    def test_a_stop_at_the_checks_after_the_commit_removes_the_record(self):
        self.conflict()
        self.commit_only()
        local = self.head(MEMBER)
        with patch.object(focus_parallel, "unsealable", return_value=["vendor/sub"]):
            self.blocked(lambda: self.cycle.execute_publication(SUBJECT), "parallel-unsupported-path")
        self.assert_closed(local)
        self.assertTrue(self.cycle.prepare_publish())
        self.assertEqual(self.head(MEMBER), local)  # resume does not move local main to the refused commit.


class CleanupTests(ResolverFixture):
    def test_a_failed_removal_keeps_an_entry_that_a_later_stage_start_removes(self):
        self.conflict()
        self.commit_only()
        with patch.object(focus_resolve, "remove_worktree", return_value=False):
            self.cycle.execute_publication(SUBJECT)
        self.assertTrue(self.cycle.reconcile_publish())  # The publication continued.
        entries = self.state["resolver_cleanup"]
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["member"], MEMBER)
        self.assertTrue(Path(entries[0]["path"]).exists())
        brief = status(self.store, self.state)
        self.assertEqual(brief["resolver_cleanup"], entries)
        self.assertIn("could not be removed", brief["warnings"][0])
        with patch.object(focus_resolve, "remove_worktree", return_value=False):
            self.cycle.sync_parallel("cc-focus --retry")
        self.cycle.advance_stage(self.cycle.snapshot(), [], {})
        self.assertEqual(self.state["resolver_cleanup"], entries)  # The entry survives the stage change.
        self.cycle.sync_parallel("cc-focus --retry")
        self.assertNotIn("resolver_cleanup", self.state)
        self.assertEqual(self.worktrees(), [])
        self.assertEqual(self.registered(), [])

    def test_more_than_three_entries_stop_the_next_resolution(self):
        self.state["resolver_cleanup"] = [{"member": MEMBER, "path": str(self.root / ".work" / "r" / ("%08x" % n))}
                                          for n in range(4)]
        self.conflict()
        self.commit_only()
        with patch.object(focus_resolve, "remove_worktree", return_value=False):
            error = self.refused("parallel-resolver-cleanup")
        self.assertIn("git worktree prune", str(error))
        self.assertEqual(self.calls(), [])
        self.state["resolver_cleanup"].pop()
        self.cycle.execute_publication(SUBJECT)  # Removable entries go at the next integration.
        self.assertNotIn("resolver_cleanup", self.state)

    def test_an_entry_goes_when_its_directory_is_gone(self):
        moved = Path(self.temp.name) / "old-root" / ".work" / "r" / "0000abcd"
        self.state["resolver_cleanup"] = [{"member": MEMBER, "path": str(moved)},
                                          {"member": "Removed-member", "path": str(self.root / ".work" / "r" / "0000abce")},
                                          {"member": MEMBER, "path": str(Path(self.temp.name) / "keep")}]
        (Path(self.temp.name) / "keep").mkdir()
        focus_resolve.retry_cleanup(self.cycle)
        self.assertEqual(self.state["resolver_cleanup"], [{"member": MEMBER, "path": str(Path(self.temp.name) / "keep")}])
        self.assertTrue((Path(self.temp.name) / "keep").exists())  # The runtime removes only its own directories.

    def test_a_stage_start_removes_other_worktrees_of_the_root(self):
        # A completed campaign can leave a worktree. The development state has no entry for it.
        self.conflict()
        self.commit_only()
        with patch.object(focus_resolve, "remove_worktree", return_value=False):
            self.cycle.execute_publication(SUBJECT)
        self.state.pop("resolver_cleanup")
        self.assertEqual(len(self.registered()), 1)
        stray = self.root / ".work" / "r" / "notours"
        stray.mkdir()
        self.cycle.sync_parallel("cc-focus --retry")
        self.assertEqual(self.worktrees(), ["notours"])
        self.assertEqual(self.registered(), [])
        self.assertNotIn("resolver_cleanup", self.state)
        # A directory that the removal cannot delete gets an entry, so the status and the limit count it.
        held = self.root / ".work" / "r" / "0000abd1"
        held.mkdir()
        with patch.object(focus_resolve, "delete"):
            self.cycle.sync_parallel("cc-focus --retry")
        self.assertEqual(self.state["resolver_cleanup"], [{"member": None, "path": str(held)}])
        self.cycle.sync_parallel("cc-focus --retry")
        self.assertNotIn("resolver_cleanup", self.state)
        self.assertFalse(held.exists())

    def test_a_directory_without_access_keeps_the_entry_and_raises_nothing(self):
        path = self.root / ".work" / "r" / "0000abcf"
        (path / "locked").mkdir(parents=True)
        (path / "locked" / "file").write_text("x")
        original = os.open

        def refuse(name, flags, *args, **kwargs):
            if str(name).endswith("locked") or (kwargs.get("dir_fd") is not None and name == "locked"):
                raise PermissionError(13, "Permission denied", str(name))
            return original(name, flags, *args, **kwargs)
        with patch.object(os, "open", refuse):
            self.assertFalse(focus_resolve.remove_worktree(self.cycle, self.members[MEMBER], path))
        self.assertTrue(focus_resolve.remove_worktree(self.cycle, self.members[MEMBER], path))

    def test_a_retry_does_not_change_the_target_of_a_link(self):
        path = self.root / ".work" / "r" / "0000abd0"
        path.mkdir(parents=True)
        outside = Path(self.temp.name) / "outside.txt"
        outside.write_text("outside\n")
        outside.chmod(0o644)
        (path / "link").symlink_to(outside)
        original, failed = os.unlink, []

        def fail_once(name, *args, **kwargs):
            if str(name).endswith("link") and not failed:
                failed.append(name)
                raise PermissionError(13, "Permission denied", str(name))
            return original(name, *args, **kwargs)
        with patch.object(os, "unlink", fail_once):
            focus_resolve.delete(path)
        self.assertTrue(failed)
        self.assertFalse(path.exists())
        self.assertEqual(outside.stat().st_mode & 0o777, 0o644)

    def test_only_runtime_directories_are_removed(self):
        outside = Path(self.temp.name) / "keep"
        outside.mkdir()
        self.assertFalse(focus_resolve.remove_worktree(self.cycle, self.members[MEMBER], outside))
        self.assertTrue(outside.exists())


class CampaignTests(ResolverFixture):
    def test_a_campaign_records_and_reports_the_resolved_paths(self):
        from focus_pair_view import read_record
        from focus_review_run import ProjectReviewCycle, create_run
        from focus_review_scope import make_request
        store, state = create_run(self.project, make_request(scope="Inspect the migration"))
        cycle = ProjectReviewCycle(self.project, store, state, self.transport, lambda: None,
                                   Path(__file__).resolve().parents[1] / "tools", "pwsh")
        self.cycle, self.state, self.store = cycle, state, store
        self.conflict()
        self.commit_only()
        cycle.execute_publication(SUBJECT)
        self.assertTrue(cycle.reconcile_publish())
        self.assertEqual(state["publication_resolutions"][0]["paths"], {PLAN_FILE: "plan"})
        state.update(pair_completed={}, display_ci={"status": "ready"})
        with patch.object(ProjectReviewCycle, "target_coverage", return_value=([], [{"checks": ["Checked."]}])):
            cycle.record_target()
        result = read_record(store, state["review_run"]["results"][str(state["review_run"]["current"])])
        self.assertEqual(result["resolutions"][0]["paths"], {PLAN_FILE: "plan"})
        state["review_run"]["remaining"] = []
        cycle.advance_stage(cycle.snapshot(), [], {})
        report = (store.directory / "report.md").read_text()
        self.assertIn(f"- {MEMBER}/{PLAN_FILE}: plan, merge commit", report)


if __name__ == "__main__":
    unittest.main()
