# cc-focus merge resolvers for parallel members: plan

Status: draft, revision 4.1. Each reviewer gave two consecutive clean passes. The operator decisions below are proposals. The operator must confirm them before the implementation starts.

Revisions:

- Revision 2 resolves in a temporary worktree, gives each resolver the exact versions of its files, and adds a check before the push.
- Revision 3 matches the patterns without Git attribute files, keeps a cleanup of the worktree until it succeeds, and orders the record steps.
- Revision 4 checks the attributes of both sides, keeps the cleanup entries across stages, and limits the pattern syntax.
- Revision 4.1 adds small corrections from two clean reviews.

## Goal

A parallel member gets commits from other writers during a stage. Before a push, P4 of `plans/FOCUS_PARALLEL_MEMBERS_PLAN.md` merges the stage commits with remote main.
A merge conflict stops the stage with `parallel-merge-conflict`, and the operator must merge in another clone.

Some files conflict often, but a project command can build them again from the merged sources. Examples are generated code and a frozen list of test methods.
This plan lets the operator name such commands in the manifest. The runtime then resolves these conflicts without a stop and without a model.
Every other conflict still stops the stage, as now.

This plan extends `plans/FOCUS_PARALLEL_MEMBERS_PLAN.md`. That plan stays valid.

## Decisions of the operator

These are proposals. The operator confirms or changes them.

1. The output of a resolver is published without a new review. An optional check command of the member runs on the resolved tree before the push. CI then checks the published commit.
2. Only the root manifest names resolvers and checks. The manifest belongs to the operator. A member repository cannot add a resolver.
3. A resolver resolves only a text conflict at one path. Both sides changed the same file at the same path, and Git wrote conflict markers into it.
   Every other conflict still stops the stage. Examples are a change against a deletion, a rename, a binary file, and a file with the `-merge` attribute.
   A file with a `filter`, `working-tree-encoding`, or `ident` attribute also stops it.
4. A resolver can change only the files in conflict that it resolves. If its output needs a change of another file, the resolver must fail. Then the stage stops before the push.

## Risks for the operator

- Nobody reviews a resolved file. A resolver can give a wrong file that passes the check and CI. Decision 1 accepts this.
- Without a check command, a wrong resolution reaches remote main, and CI goes red for every writer of the member.
  The manual remedy built and tested before its push. The check command does the same, so configure one.
- A resolver and the check run code from the merged tree. That tree contains commits of other writers that arrived after the stage start. No stage role ran that code.
  The other writers also run with full access, so this is the same trust as the parallel writers themselves.
- A resolver and the check run with full access to the computer. The runtime finds changes in the project and in the temporary worktree.
  It cannot find changes elsewhere, for example in `.work`, in `.git/config`, in the hooks, or in the credentials.
- A resolver and the check can take a long time, because they build in a new worktree without build output. The publication waits for them. An emergency stop interrupts them. A safe stop waits until the publication ends.
  Remote main can move during a publication. Then P4 integrates again, up to three times, and the rules and the check run again each time.
- `read-tree -u T` runs the smudge filters of T, for example LFS, before the attribute check of T. Thus a filtered tree can download objects first.
- On Windows, the build tools in the worktree need the long-path support of the operating system. `core.longpaths` helps only Git.
- A resolver runs only when Git reports a conflict. A merge without a conflict can still leave a generated file stale. For example, the stage changes a model, and another writer changes the generator. The check or CI must find such a file.
- A change of the `resolvers` key applies at the next stage, because the manifest is sealed root context. During a stage, the remedy is the manual merge in another clone.
  A change of the resolver code applies at once, because the merged tree contains it.

## Problems now

A live S0 review campaign stopped with `parallel-merge-conflict` in the code repository. Two files had conflicts:

- `tests/Interlink.Compiler.Tests/SuiteInventoryTests.The_tests_of_this_suite_are_frozen.verified.txt`, the frozen list of test methods. The stage renamed and added a test in one class. Development changed a case count and added a test in the same class.
- `tests/Interlink.IntegrationTests/S2Adaptation/Tabular/Generated/Manifest.g.cs`, a generated file. Each side changed the model, so the fingerprint of the generation input differed on both sides. Neither value was correct for the merged model.

The operator remedy took these steps:

1. Merge the stage commit with remote main in a separate workspace.
2. Merge the list: keep the changes of both sides.
3. Generate the fixture files again with the generator of the project.
4. Build, check the format, and run the tests.
5. Push the merge commit, wait for its CI, and retry the campaign.

Steps 2 to 4 are mechanical. Step 5 needed a runtime change: the stage commit had no CI of its own. `Cycle.wait_ci` now reads the CI of a later remote main for a parallel commit without any CI record. That change is already implemented and reviewed. It stays the manual fallback.

## Design

### R1. Resolvers in the manifest

`focus-project.json` version 1 gets an optional key `resolvers`. It maps a parallel member to its rules and its check:

```json
{"version": 1, "repositories": ["src", "docs", "plan"], "parallel": ["docs", "plan", "src"],
 "resolvers": {"src": {
   "rules": [
     {"name": "suite-inventory", "paths": ["tests/*/SuiteInventoryTests.*.verified.txt"],
      "command": ["python3", "tools/review/resolve.py", "inventory"]},
     {"name": "generated-fixtures", "paths": ["tests/**/Generated/*.g.cs", "samples/*/Generated/*.g.cs"],
      "command": ["python3", "tools/review/resolve.py", "generated"], "timeout": 3600}],
   "check": {"command": ["python3", "tools/review/resolve.py", "check"], "timeout": 3600}}}}
```

- Each key of `resolvers` must be a parallel member. A member has 1 to 16 rules and an optional check.
- `name` is a short identifier, unique in its member.
- `paths` is a list of 1 to 16 patterns. A pattern is relative to the member root, uses `/`, and has no `..` part.
  - `*` and `?` stay inside one directory. `**` crosses directories, and it must be a whole directory part.
  - A pattern without `/` matches the file name at any depth. Matching is case-sensitive.
  - The manifest refuses every other syntax:
    - brackets, `\`, and a `!` at the start;
    - a `**` inside a directory part, and a `/` at the end;
    - an empty part, and a `.` part.
  - This subset follows the pattern rules of `.gitattributes`. The runtime has its own matcher and reads no attribute file.
    Thus a `.gitattributes` file in a member cannot add a path to a rule or remove one. This is decision 2.
- `command` is a non-empty list of strings. The runtime does not use a shell. On Windows, the operator names the interpreter that the computer has, for example `py`.
- `timeout` is optional: 60 to 7200 seconds. The default is 1800.
- An older runtime rejects the new key with `project-manifest`. Thus it cannot ignore the rules.
- `parallel` and `resolvers` come from one read of the manifest. The runtime saves both at each point where it saves `state["parallel"]` now, so a stage and a campaign stage always use one manifest version.

### R2. When a resolver runs

P4 step 2 computes the merged tree T with `git merge-tree --write-tree -z`, now without `--name-only`. When Git reports a conflict:

1. Read the conflict entries `<mode> <object> <stage> TAB <path>`, and group them by path.
2. A path is resolvable only if all of these are true. This is decision 3.
   - It has stage 2 and stage 3, with a regular or executable file mode.
   - Stage 2 is the entry of the path in R, and stage 3 is the entry of the path in H. Thus no rename is involved.
   - Its blob in T has conflict markers. Thus Git made a text conflict. A binary file or a `-merge` file has none.
   - Its attributes in H and in T give no `filter`, no `working-tree-encoding`, and no `ident`. For example, it has no LFS filter.
     The runtime reads the attributes of H in the member and the attributes of T in the worktree, after R3 step 3.
   - A resolver gets the repository form of each blob. Without these attributes, only the line endings can differ from the working tree, and `git add` normalizes them.
   - Stage 1 can be absent. That is an add/add conflict, and the resolver gets no base version.
   - With more than one merge base, stage 1 is a virtual base. Its blob can contain conflict markers, so a resolver must not treat it as clean text.
3. Match each path against the rules of the member, in their order. The first rule that matches takes the path.
4. If a path is not resolvable, or no rule matches it, stop with `parallel-merge-conflict`, as now. The message also names the paths that no resolver covers.

### R3. The resolution in a temporary worktree

When every path in conflict has a rule, the runtime resolves them before step 3 of P4. The member checkout does not change in this section.

1. The member checkout must be clean. `commit_reviewed` makes it clean, and `dirty(repo)` checks it. Otherwise, stop with `parallel-dirty`.
2. Save the integration record with the step `resolving`. It holds B, R, H, T, the worktree path, the paths in conflict with their rules, and `"result": None`.
3. Make a temporary linked worktree with a short path in the project root, for example `<root>/.work/r/<8 hex>`. It is outside every member checkout, and `.work` is not project context.
   - Run `git worktree add --no-checkout --detach <dir> H`, then `git -C <dir> read-tree --reset -u T`. Neither command runs a hook.
   - On Windows, both commands get `-c core.longpaths=true`, because the prefix makes deep paths longer.
   - The worktree now holds the merged tree. The files in conflict contain the conflict markers of Git.
   - Check the attributes of T for the paths in conflict, as R2 step 2 says. A `filter`, `working-tree-encoding`, or `ident` attribute stops with `parallel-merge-conflict`.
4. Write a file `inputs.json` beside the worktree. For each path in conflict, it holds the rule, the mode, and the blob ids of stage 1, stage 2, and stage 3. Stage 1 is `null` for an add/add conflict.
5. Run the rules one by one, in manifest order. A rule gets only its own paths:
   - The working directory is the worktree.
   - The environment adds `CC_FOCUS_MERGE_INPUTS` (the path of `inputs.json`), `CC_FOCUS_MERGE_PATHS` (a file with the paths of the rule, separated by NUL), `CC_FOCUS_MERGE_BASE`, `CC_FOCUS_MERGE_REMOTE`, `CC_FOCUS_MERGE_STAGE`, and `CC_FOCUS_PROJECT_ROOT`.
   - A rule reads the three versions of a file with `git cat-file -p <blob>`.
   - The project root lets it find shared caches, for example an ICU cache. A cache must be outside the project or ignored, because R4 refuses other changes.
   - The command runs under the process control of `run_git`. That gives the heartbeat, the stop request, the deadline of its `timeout`, and a log under the store of the run.
   - A non-zero exit code or the deadline stops with `parallel-resolver-failed`.
   - The paths of a later rule still contain conflict markers while an earlier rule runs. Put rules that only merge text before rules that build.
6. After each rule, check the result as R4 describes.
7. After the last rule, write the tree T2 of the worktree.
8. If the member has a check, run it in the worktree with the same environment and process control.
   - A non-zero exit code or the deadline stops with `parallel-resolver-failed`.
   - After the check, the tree must still be T2, and the checks of R4 "Outside the worktree" apply.
9. Remove the worktree with `git worktree remove --force` and `git worktree prune`, as R5 describes for a failed removal.
10. Make C2 with `git commit-tree T2 -p R`, with the message and the author of H, as P4 step 3 does.

P4 then runs step 4 with C2. A stop at P4 step 4 removes the `resolving` record.
Only P4 step 5 changes the record from `resolving` to `saved`, with C2 and the list of resolved paths. Thus `resume` never moves local main to a C2 that P4 step 4 refused.

Every exit after step 2 removes the worktree and the record before it raises, also after a failed Git step. Thus a recovery agent never starts while a resolution is open.
A removal that fails keeps a cleanup entry, as R5 describes.

### R4. Checks after each rule

- **Scope.** Stage the worktree with `git -C <dir> add -A`, and write its tree. The paths from the previous tree must be a subset of the paths of this rule. This is decision 4.
  A change of any other path, also a new untracked file, stops with `parallel-resolver-scope`. Ignored files, for example build output, are not checked.
- **Each path changed.** Each path of the rule must differ from its blob in T. Thus the rule wrote it.
- **Markers.** A path of the rule must have no marker line. A marker line starts with seven or more `<`, `|`, or `>` characters and a space.
  A line of `=` characters alone is not checked, because some text formats use it.
- **Entry types.** A path of the rule must still be a regular or executable file, with its mode in T.
- **Outside the worktree.** The project snapshot without the temporary worktree must equal the snapshot before the rule.
  HEAD of the worktree must still be H, and the worktree must have no Git operation state. Otherwise, stop with `parallel-resolver-scope`. The message names the changed paths.

### R5. Recovery

`resume` handles the step `resolving` before any publication check of the member:

- Remove the worktree with `git worktree remove --force` and `git worktree prune`, if it still exists.
- Remove the record. P4 then integrates again from step 1, and the rules run again.

The member checkout did not change, so a recovery never restores it. A stale `.git/index.lock` of the worktree goes with the worktree.
The other steps of the record keep the recovery of P5.

A removal can fail, for example on Windows when a build server keeps a file open. Then:

- The runtime keeps a cleanup entry with the member and the worktree path in `state["resolver_cleanup"]`. The removal runs in the repository of that member.
  This key stays across stage changes and campaign targets. `advance_stage` does not remove it.
- After a successful resolution, the publication continues, because T2 is already in the object store.
- After a refusal, the original blocker stays.
- Each later integration and each stage start runs the removal of each entry again. A successful removal deletes the entry.
- A removal that fails again keeps its entry and does not stop the run. `cc-focus status` shows the entries as a warning.
- A new resolution always uses a new directory.
- If more than three entries remain, the next resolution stops with `parallel-resolver-cleanup`.
  The message names the directories and the remedy: stop the process that keeps their files, remove them, run `git worktree prune`, and run the retry command.

### R6. Blockers

| Code | Cause | Remedy in the message |
| --- | --- | --- |
| `parallel-merge-conflict` | A conflict that no rule covers, or that R2 cannot resolve. | Unchanged. The message also names the paths that no resolver covers. |
| `parallel-resolver-failed` | A rule or the check failed or timed out, or a rule left conflict markers. | Read the log, which the message names. Correct the resolver on remote main in another clone. The next attempt then uses it. A change of `timeout` applies at the next stage. The message also gives the manual merge of `parallel-merge-conflict`. Then run the retry command. |
| `parallel-resolver-scope` | A rule changed a path outside its paths, or the project changed outside the worktree. | The message names the paths. Correct the resolver on remote main in another clone, or undo a change of these paths. Then run the retry command. |
| `parallel-resolver-cleanup` | More than three temporary worktrees cannot be removed. | The message names the directories. Stop the process that keeps their files, remove them, and run `git worktree prune`. Then run the retry command. |

The three new codes are in `OPERATOR_CONTEXT_BLOCKERS`, so they start no healer. A healer cannot change the publication.

### R7. Status and evidence

- The integration record keeps the resolved paths with their rules. `cc-focus status` shows them in `parallel_integrations`. The status projection accepts a record with `"result": None`.
- For each resolution, the runtime saves an artifact with these values:
  - the paths in conflict, the rules, and the commands;
  - the exit codes and the log paths;
  - T, T2, C2, and the blob ids of the resolver files in T.
- The progress line names the rule and the member while a rule runs, for example "Resolver suite-inventory for src; no model is running".

### R8. Development and review campaigns

Both use `focus_parallel.integrate`, so the resolution works in a development stage and in a review campaign.
A second integration after a move of remote main runs the rules again on the new merged tree.
A campaign records the resolved paths in its target record. The report lists them for the target.
A resolved file differs from R, so it counts as a change of the target. It can thus queue earlier targets again, as other repairs do.

### R9. The resolvers of Interlink

The rules of the R1 example need three commands in Interlink. These are tasks for the Interlink plan, not for Orchestra.
Each command works in a worktree outside every member checkout, and reads its inputs as R3 step 5 describes.
A command that builds turns off the build servers, for example with `MSBUILDDISABLENODEREUSE=1` and `UseSharedCompilation=false`. A server that stays alive can keep files open and stop the removal of the worktree.

1. **`resolve.py inventory`** merges the frozen list of test methods.
   - First try `git merge-file --diff-algorithm=histogram` on the three versions. A clean result is the output.
   - Otherwise, merge by test identity. The key is the class and the method, and the value is the case count.
   - Keep a key that neither side changed. Take the change of the side that changed it. Remove a key that one side removed and the other side kept.
   - Fail in these cases:
     - both sides changed a key in different ways;
     - one side removed a key, and the other side changed it;
     - one side renamed or removed a class, and the other side added to it;
     - the base has conflict markers, because it is a virtual base.
   - Write the classes and the methods in the ordinal sort order of the inventory test, with its BOM and LF.
   - For an add/add conflict, there is no base. Fail unless both sides added the same keys with the same counts.
2. **`resolve.py generated`** generates the fixture files again.
   - Find the project of each path: the directory with `model/` and `Generated/`. Generate it again with the generator of that project.
   - Write only the paths that the rule got. Fail if another file of the same `Generated/` directory would change, or if the generation needs a new file. Thus a stale file stops before the push.
   - The registry generator needs a command line entry for this. Today only a contract test calls it.
3. **`resolve.py check`** builds and tests what the resolution can break.
   - Build the solution, check the format, and run the inventory tests and the generation contract tests.

The operator adds the `resolvers` key to the manifest of the development workspace and of each parallel workspace after these commands exist on main.

## Tests

- **Manifest.**
  - A valid `resolvers` key with rules and a check.
  - The refusal of these values:
    - an unknown key, and a member that is not parallel;
    - a repeated rule name, and an absolute pattern or a pattern with `..`;
    - an empty command, and a timeout outside 60 to 7200.
  - A stage and a campaign stage record `parallel` and `resolvers` together. A manifest change during a stage has no effect until the next stage.
- **Resolution.** A fixture repository with test resolver scripts.
  - A text conflict in a covered file: C2 has the resolved file, the push follows, and the record names the resolved path.
  - Two rules with different paths run in manifest order, each with its own paths.
  - `inputs.json` and the variables give the exact blobs, also for an add/add conflict without a base.
  - The check runs on the resolved tree, and its failure stops before the push. A check that changes the tree or the project stops too.
  - The member checkout is unchanged during the resolution, and a member `.work/PAUSE` stays in place.
  - A second integration after a move of remote main runs the rules again.
  - A mode change on one side keeps the mode of T.
  - A deep path resolves in the worktree.
  - A member `.gitattributes` that sets or unsets an attribute does not change which paths a rule covers.
  - The matcher agrees with `git check-attr` on a table of patterns. The comparison runs in an empty helper repository with a generated attribute file and `core.ignorecase=false`.
  - The manifest refuses each syntax that R1 refuses.
- **Refusals with `parallel-merge-conflict`.**
  - A conflict that no rule covers: the message names the uncovered path.
  - Each of these in a covered path: a change against a deletion, a rename with a content conflict, and a binary file.
  - A `filter`, `working-tree-encoding`, or `ident` attribute in H, and one that R adds, so that only T has it.
- **Refusals with `parallel-resolver-failed`.**
  - A non-zero exit, a deadline, and a stop request while a rule runs.
  - Remaining conflict markers, and a path that the rule did not change.
  - A line of `=` characters alone is accepted.
- **Refusals with `parallel-resolver-scope`.**
  - A change of a path of another rule, a change of another path, and a new untracked file.
  - A write into another member or into the project root.
  - A rule that moves HEAD of the worktree.
- **After each refusal.** The worktree is gone, no record remains, and the member checkout equals H.
- **P4 step 4 after a resolution.** A stop there removes the `resolving` record, and a later `resume` does not move local main.
- **Recovery.** An interruption during a rule and during `read-tree`: `resume` removes the worktree and the record, and the next attempt runs the rules again.
- **Cleanup.**
  - A removal that fails keeps a cleanup entry, and the publication continues after a success.
  - The entry survives the next stage start, and a later removal deletes it.
  - A fourth entry stops the next resolution with `parallel-resolver-cleanup`.
- **Status.** `cc-focus status` during a resolution shows the open record.
- **Campaign.** A review campaign resolves a conflict and lists the resolved paths in its target record and its report.
- **Compatibility.** A manifest without `resolvers` keeps the current behavior. An older state without `state["resolvers"]` has no rules.

## Documentation

- `docs/sequential-cycle.md`, the section on parallel member repositories: the `resolvers` key, R2 to R5, the blockers, and the risks.
- `README.md`: the manifest key and the example.
- `knowledge.md`: the module map and the recovery step.
- `docs/focus-review.md`: the resolved paths in the campaign report.

## Implementation steps

1. Manifest validation in `focus_project.read_manifest`. One read gives `parallel` and `resolvers`, and both are saved together.
2. The conflict entries from `git merge-tree`, the R2 tests, and the pattern matcher of R1.
3. The temporary worktree, `inputs.json`, the runner for commands with the process control of `run_git`, and the checks of R4.
4. The check command, the record step `resolving`, its recovery in `focus_parallel.resume`, and the cleanup entries.
5. The blockers in `cycle_workflow` and `OPERATOR_CONTEXT_BLOCKERS`.
6. Status, evidence, and the campaign report.
7. Tests and documentation.
8. The Interlink tasks of R9, through the Interlink plan.

## Out of scope

- A model role that resolves conflicts. A conflict in normal code still stops the stage.
- Git merge drivers. A driver can merge one file with its exact versions inside `merge-tree`, but it cannot build files from the merged tree. One mechanism serves both kinds of file.
- Conflicts between a change and a deletion, rename conflicts, binary files, and symbolic links.
- A resolver for an exclusive member or for a single repository. Only a parallel member integrates.
- A resolver that runs after a merge without a conflict, for example to generate stale files again.
- Built-in resolvers in Orchestra.
