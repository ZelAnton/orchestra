# Focus: sequential main-branch processing

Provider instructions follow the [instruction style policy](instruction-style.md).
The policy uses ASD-STE100 Issue 9 with an internal 80 percent acceptance threshold.
Style changes preserve workflow rules, permissions, report schemas, and saved-session behavior.
New instructions and knowledge text use English unless the user explicitly requests another language.

`cc-focus` is an opt-in workflow, separate from `cc-processor`. It works directly
in an existing Git `main` checkout or a project containing several such repositories,
with one writer at a time. The runtime may run two read-only reviewers together;
no fixer, publication or recovery agent starts until both readers have exited.
Queue settings do not change this profile or its permissions.

Use [`cc-focus review`](focus-review.md) for completed plan items or an explicit integration scope.
That mode starts at Pair A and retains the same repair, publication, and CI gates.
It supports ID ranges and an optional menu with checkboxes.
Its campaign state stays separate from development state.

```text
Luna coordination → Opus/xhigh implementation
  → Pair A: Opus/xhigh + Sol/xhigh in parallel
  → Pair B: Astra/xhigh + late Opus/max in parallel
  → Final: Opus/max then Fable/xhigh, independent initial reports
  → optional final gate: one Opus/xhigh full run, when a final inspector requests it
  → Luna readiness → runtime commit/push → CI → next stage

Every pair: independent reports → at most two discussion exchanges
  → consensus on the exact proposal, or binding Astra/max arbitration
  → accepted assignments
  A: Codex GPT-6-Sol/high complexity assessment → Opus/high or xhigh fixes
  B/final: Opus/xhigh fixes → self or Opus/xhigh + Astra/xhigh read-only review
    → two clean passes on unchanged repair → targeted tests

Significant findings: fix → repeat the SAME pair, until none remain.
Only minor findings: fix → applicable inner gate → next pair (or publish).
No accepted assignments: next stage, without assessment or artificial fixes.
Unexpected substantial changes or disputed repairs require renewed inspection.
No A/B cross-return or fixed OUTER clean-streak gate applies.
```

| Role | Model | Effort |
| --- | --- | --- |
| Coordinator / publication preparation | gpt-5.6-luna | xhigh |
| Implementation | opus | xhigh |
| Pair A repair complexity assessment | gpt-6-sol | high |
| Pair A fixes / minor cleanup | opus | high or xhigh, chosen by assessment |
| Pair A, independent peers | opus + gpt-6.1-sol | xhigh + xhigh |
| Pair B, independent peers | gpt-6-astra + opus | xhigh + max |
| Final, independent initial inputs, sequential invocation | opus → claude-fable-5-1 | max → xhigh |
| B/final fixer and test executor | opus | xhigh |
| B/final inner review | same opus session, or independent opus + gpt-6-astra | xhigh |
| Binding arbiter, separate session | gpt-6-astra | max |
| Technical blocker recovery | gpt-6-astra | xhigh |

`opus` is the Claude Code model alias, rather than a pinned version or menu
display label. The runtime requires an Opus model
in the initialization event, records its resolved version in the invocation, and
rejects a different family or a version change during that invocation, including
retries. See [Claude model aliases](https://code.claude.com/docs/en/model-config#model-aliases).

Existing states from profile versions 1–7 upgrade to version 8 under normal
runtime ownership on the next run. Previous state, counters and session IDs are
archived under `.work/cycle/review-profiles/`. Reviewer conversations restart with
the new models and order; coding, coordinator, publisher and healer conversations
are retained. Interrupted coding preserves the same work intent and files and
continues with Opus, without an obsolete resolved-model pin. Model and effort are
explicitly selected and checked on every provider launch. No old review credit transfers.
An iteration awaiting review or publication preparation restarts at pair A. An
already-started commit/push or CI window retains its original reviewed snapshot
and pending publication through CI, preserving partial-push reconciliation; the
next stage uses the new profile. Unresolved operator messages must be resolved
before migration. No source, Git history, staging or ownership is changed.

## Start and resume

Install with `cc-sync`, then run from the target repository or project root:

```sh
cc-focus --handoff /path/to/handoff.md
cc-focus status
cc-focus
cc-focus --new-sessions --handoff /path/to/updated-handoff.md
cc-focus --retry
cc-focus stop
cc-focus stop --now
cc-focus finish-stage
cc-focus finish-stage --cancel
cc-focus correct --message "Keep this stage; also handle empty input."
cc-focus correct --file /path/to/correction.md
cc-focus reconcile --plan-out .work/focus-reconcile.json
cc-focus reconcile --apply-plan .work/focus-reconcile.json
cc-focus --output compact
cc-focus --ui off
cc-focus recover --review-from .work/cycle/invocations/CODE_INVOCATION_ID/result.json
```

Disjoint projects may run their own cycles concurrently. For a project root outside
Git, cc-focus automatically discovers its immediate Git child directories. To list
members explicitly, including deeper directories, use `focus-project.json`:

```json
{"version": 1, "repositories": ["Core", "Root", "Specification"]}
```

Member paths must stay inside the project, be nonoverlapping and contain independent
primary Git repositories on `main`. Symlink members, linked worktrees and detached
HEAD are rejected. A handoff imports context; it does not change the working
directory or create/convert repositories. Membership is fixed for the saved cycle.
Repository admission errors are printed before opening the interactive panel and
exit with code 3, preserving the diagnostic in shell scrollback.

One iteration may change several member repositories. Coding and the complete review sequence
cover their combined changes. Publication checks every changed repository's policy
and remote before starting the publisher, then commits/pushes each repository's
reviewed files to its own remote main. Untouched repositories receive no commit or
push. Existing unrelated files and index entries remain protected per repository.
Project-root shared instructions and the membership manifest are read-only cycle
context; place editable plans and source inside a member repository. An imported
handoff source outside member repositories is optional transfer input as described below.

In project mode, each role gets the instruction files of the project root and of each member in the field `project_instructions`.
The list contains `AGENTS.md`, `CLAUDE.md`, and `.claude/CLAUDE.md` of each directory, with paths relative to the project root.
A relative link to a regular file in the project also gives its target. Other links, directories, and absent files are not in the list.
The main roles and the pair writers get the list from the current files.
A pair reader gets the list from its frozen view, so a saved reader prompt does not change.

The field also contains a fixed rule. A role reads the instruction files of a repository before it uses, changes, or reviews files in that repository.
A repository instruction has priority over a project-root instruction for that repository.
The role contract, operator messages and corrections, and the review scope have priority over all instruction files.

A pair from an older runtime has no marker `project_instructions_version`, so its readers get no field.
A single repository and the coordinator of a review campaign also get no field. An empty list adds no field.
An unknown marker version stops the run with `instruction-version`. No recovery agent starts, because it can neither install a runtime nor repair a runtime defect.

A version-1 pair gives the list. A version-2 pair also gives its parallel repositories, as "Parallel member repositories" describes.

Publication across repositories is not atomic. After an interruption, the runtime
compares each member's reviewed files, local HEAD and remote main before invoking
the publisher again. Confirmed commits/pushes remain recorded; outstanding members
continue without creating duplicate commits in completed members. Each changed
repository must pass its own configured CI at its exact published SHA before the
next iteration. Evidence is stored separately under
`.work/cycle/repositories/<member-path>/ci/`, and parent state records every outcome.
An explicit `--retry` refreshes CI waiting deadlines for all published members.
Further reviewed fixes after a partial push reopen the affected repository's
publication. A `.work/PAUSE` file at the project or any member is respected at the
same safe boundary; publication and CI finish together before a safe pause.

A parallel member has other writers. It follows other rules for remote main and for CI, as "Parallel member repositories" describes.

On Windows use the same arguments with `cc-focus.cmd`. Quote paths containing
spaces. `--handoff` is optional, including on the first run; no file named
`HANDOFF.md` is required. A supplied handoff is a nonempty UTF-8 file, at most 4 MiB. Identify the project plan
and describe completed work, unfinished work and verification commands.
Each imported file is copied and hashed under `.work/cycle/handoffs/`.
Changing the original file later does not silently change the imported context.
Original sources outside member Git repositories may be moved, changed or deleted
after import. Their contents are excluded from cycle work comparisons, including
when replaying older saved snapshots/results; immutable artifacts are not rewritten.
The copied handoff remains checksummed historical context. Use current instructions
and plans to continue development; an old transfer description cannot override them.
Shared `AGENTS.md`, `CLAUDE.md`, `PLAN.md`, `focus-project.json` and the selected
task's plan retain their live context checks even if supplied as handoff input. Files inside a Git repository
retain normal work, staging and publication checks. Unimported shared files remain
read-only context; this is not a blanket exception for files named `HANDOFF.md`.

The current project plan is the source of stages; locate it through project
instructions and saved task metadata, using a handoff only as an optional reference.
Before selecting a new stage,
read its current contents and follow its order, dependencies and completion state;
do not substitute the queue or remembered conversation. Interrupted coding finishes
the same stage first. A missing, unreadable or ambiguous plan is a blocker, not
permission to invent a stage. The coding report identifies the plan and stage.

Each role keeps its own conversation within a stage. Each new stage starts new
role conversations. New repositories create sessions automatically. Session identifiers are captured internally and never accepted as
CLI arguments.

`--new-sessions` archives the internal session mapping and starts
fresh conversations while retaining the current phase, WIP, reports and publication
state. For another laptop, supply the handoff rather than copying native session
identifiers. Local runtime state is bound to its canonical repository path.

Requirements: Python 3.10+ (standard library only), PowerShell, Git, authenticated
Codex and Claude CLIs supporting the requested models/efforts, and a compatible
standalone `processkit-cli` with inherited stdio support. GitHub CI additionally
requires `gh` authentication. No paid model call is made by the regression suite.
Model availability is checked at runtime; no cheaper/different model is substituted.
Interactive input requires Codex app-server `turn/steer` and Claude stream-json
input with `--replay-user-messages`; unsupported delivery stops without changing models.
On Windows put native provider executables on PATH; batch shims are rejected to
avoid shell re-interpretation of structured arguments. In a colocated JJ repository,
this mode uses Git only and still requires a symbolic `main` checkout.

### Move plans and documentation to member repositories

This procedure moves the plans and the documentation of a repository to two new member repositories.
The outer path stays the same, and the code repository moves one level down.
The example uses the members `Example`, `Example-docs`, and `Example-plans`.

Set `ROOT` to the outer path, for example `ROOT=/srv/projects/Example`. Do not end it with a slash.
Run the commands with `$ROOT` in the same shell, because the variable exists only there.
The commands use absolute paths, except in step 5 and in the commands that run in `$ROOT`. Each step names its stop point.

```text
$ROOT/                    project root, not a Git repository
    focus-project.json    {"version": 1, "repositories": ["Example", "Example-docs", "Example-plans"]}
    AGENTS.md -> Example-docs/project/AGENTS.md
    CLAUDE.md -> Example-docs/project/CLAUDE.md
    Example/              code repository
    Example-docs/         documentation repository
    Example-plans/        plan repository
```

1. **Stop at a stage boundary.**
   - Use `/finish-stage`, wait for the pause, then use `/exit`.
   - Check `cc-focus status`: `running` is false, and `stage_completed` is set or `status` is `complete`.
     `active.provider_run` is null or absent, and `active.provider_runs` is empty or absent.
   - Check `cc-focus review --list`. Finish each unfinished campaign with `cc-focus review --resume ID`.
     Otherwise step 6 archives the campaign. Then a new campaign with the new plan path must cover the targets that it did not finish.
   - Check that `git -C "$ROOT" worktree list` shows only the main checkout. Finish or remove the queue worktrees.
     Keep a worktree only when you must, and repair it in step 4.
     If the repository is a colocated Jujutsu repository, also check `jj workspace list`.
   - Check that the code checkout is clean.

   Stop point: safe, the old setup still works.
2. **Install the runtime.** Run `cc-sync` from Orchestra. Stop point: safe.
3. **Split the repositories.**
   - Make regular clones with their own `.git` directory. Do not use linked worktrees or a separate Git directory.
   - In each new repository, commit a `.gitignore` with `.work/`, `.inbox/`, and `.claude/settings.local.json`.
   - Commit `Example-docs/project/AGENTS.md` and `Example-docs/project/CLAUDE.md` with the project-root instructions.
     They name the plan path, the members, and the directory of each command.
   - In the plan repository, write references to code as paths from the project root, for example `Example/src/...`.
     Name the directory of each verification command. The last completed stage must show as complete.
   - Add these changes to the removal commit of the code repository:
     - Rewrite `AGENTS.md` and `CLAUDE.md`. They must not describe plans or documentation inside the repository.
     - Name the directory of each verification command.
     - Update the scripts and the CI jobs that read the moved files.
     - Step 4 copies the tool configuration to the project root. If the originals must not stay, first save a copy outside the repositories.
       Then remove the originals in this commit.
   - Push each of the three repositories with `git push -u origin main`.
   - Check each repository with `git status -sb`: `## main...origin/main` with no ahead or behind mark, and one push URL.

   Stop point: the push that removes the plans and the documentation from the code repository cannot be undone easily.
4. **Make the project root.** Check that `$ROOT.code` and `$ROOT.project` do not exist.

   ```sh
   mv "$ROOT" "$ROOT.code"
   mkdir "$ROOT"
   mv "$ROOT.code" "$ROOT/Example"
   ```

   - Put `Example-docs` and `Example-plans` into `$ROOT`.
   - Do not run `git worktree prune`. For each worktree that you kept in step 1, run `git worktree repair` with its new path.
   - Copy tool configuration that must stay active to the project root, for example `.claude/settings.json` or `.mcp.json`.
     - The roles now run in the project root, so the providers no longer load these files in the code repository.
     - If step 3 removed the originals, use the copy that you saved in step 3.
     - Adjust the relative paths in the copies.
     - Do not delete the originals now. A removal must be part of the step 3 commit.
   - Root files are sealed project context. Do not keep files there that tools change, for example `.claude/settings.local.json`.

   Stop point: local, reversible.
5. **Write the project files.**

   ```sh
   cd "$ROOT"
   printf '%s\n' '{"version": 1, "repositories": ["Example", "Example-docs", "Example-plans"], "parallel": ["Example-docs", "Example-plans"]}' > focus-project.json
   ln -s Example-docs/project/AGENTS.md AGENTS.md
   ln -s Example-docs/project/CLAUDE.md CLAUDE.md
   ```

   - Do not use `ln -f`. `focus-project.json` must be a regular file.
   - The key `parallel` lists the members with other writers. Without other writers, leave out the key.
   - A link itself can change only before the first run or at a completed-stage pause. Its target changes like any member file.
   - Regular root files are the alternative. Reconcile can accept their changes, but they have no version control.

   Stop point: local, reversible.
6. **Archive the old state.**

   ```sh
   mkdir -p "$ROOT/.work"
   mv "$ROOT/Example/.work/cycle" "$ROOT/.work/single-repository-archive"
   rm -f "$ROOT"/*/.work/PAUSE
   ```

   The project-root `.work/` is excluded from the project context. Stop point: local, reversible.
   Before step 11, use these commands to undo steps 4 to 6. After step 11, first do the extra move in step 11.
   The undo restores only the layout, because the step 3 push stays.

   ```sh
   mv "$ROOT/.work/single-repository-archive" "$ROOT/Example/.work/cycle"
   mv "$ROOT" "$ROOT.project"
   mv "$ROOT.project/Example" "$ROOT"
   ```

7. **Configure the members.** `cc-config` is optional for cc-focus. A member needs `constraints.md` only for required checks or rules.
   - When CI jobs moved between repositories, update the required check names in each member `.work/constraints.md`.
   - Make sure that each workflow runs on every push to main.
   - In a parallel member, a main workflow must not cancel earlier runs, for example with `concurrency: cancel-in-progress`.

   Stop point: safe, no model.
8. **Check the repositories.** For each member `M`, use `git -C "$ROOT/M"`:
   - `git status --porcelain` shows nothing.
   - After `git fetch`, `git rev-parse HEAD` equals `git rev-parse @{u}`.
   - `git remote get-url --all --push origin` shows one URL.
   - cc-focus compares main with the push URL through `git ls-remote`. If the remote has a separate push URL, compare with it.

   Stop point: safe, no model.
9. **Check without a model.** In `$ROOT`, run
   `cc-focus review --plan Example-plans/plan/plan.md --scope "migration preflight" --preview`.
   It checks the layout, the main branch of each member, and the plan path. It starts no model.
   Then run `cc-focus status`. Stop point: safe, no model.
10. **Set the brief.** In `$ROOT`, run `cc-focus brief set FILE`. Keep the file outside the project.
    Stop point: safe, no model. The brief is now in `$ROOT/.work/cycle`.
11. **Start the first run.** In `$ROOT`, run `cc-focus --handoff FILE`. Keep the handoff outside the project. It names:
    - the plan path and the last completed stage
    - the unfinished work and the verification commands with their directories
    - the map from old paths to new paths

    Stop point: the project store now exists in `$ROOT/.work/cycle` and records the members.
    A later change of the members in `focus-project.json` stops the run with `project-layout-changed`.
    Change the members only with a new store.

    The run also made `$ROOT/Example/.work/cycle` for the member lock and the owner record.
    To undo the migration after this step, first move that directory to `$ROOT/.work/member-store-Example`.
    Then use the undo commands of step 6. The project store moves with `$ROOT.project`.
12. **Verify the first stage.** Run `cc-focus status` after the publication. Check the publication and the CI result of each changed member.
    Stop point: the completed first stage.

After the migration:

- Always run cc-focus in the project root. A run inside a member is a separate single-repository cycle.
- The iteration counter starts again at 1. The old review campaigns stay in the archive.
- Publication across repositories is not atomic. The runtime finishes an interrupted publication.
- All members of one publication get the same commit subject.
- With a root link, an edit of the link target changes the root instructions. Check such edits in the reviews and the published commits.
- Keep each repository owned by the user that runs cc-focus. Check the `gh` access to the new repositories.
- A review campaign requires a published main in every exclusive member. A development run accepts a local-only member that does not change.
- A parallel member must have a remote main. Other writers work in their own clones, as "Parallel member repositories" describes.

### Parallel member repositories

Other writers can change a member repository at the same time as cc-focus, for example the plans and the documentation.
List such members with the key `parallel` in `focus-project.json`:

```json
{"version": 1, "repositories": ["Example", "Example-docs", "Example-plans"], "parallel": ["Example-docs", "Example-plans"]}
```

An older runtime rejects the key, so it cannot ignore these rules. Each stage records the set at its start.
A manifest change becomes active at the next stage. An exclusive member, for example the code repository, keeps all current checks.
A local-only member must be exclusive, because a parallel member needs a remote main.

Rules for the other writers and for GitHub:

- Each other writer works in its own clone outside the project root, on its own branch.
  Never work in a checkout under the project root. cc-focus cannot tell such an edit from its own work.
- Each other writer merges its branch into main itself, through a pull request or a fast-forward push.
- In the active plan, only cc-focus changes the status of stages. Keep an empty line around each status line.
  Git treats edits of adjacent lines as a conflict.
- Branch protection must allow the direct push of cc-focus to main.
- A main workflow must not cancel earlier runs, for example with `concurrency: cancel-in-progress`. A cancelled run counts as a CI failure.

At a stage start, cc-focus brings remote main of each parallel member into its checkout with a fast-forward.
This sync runs at the stage transition, and at a run start when the state is at a stage start without an unfinished invocation.
During a stage, a sync runs only for a blocked step, as "Catch-up for a blocked step" describes. At a run start, the state then takes the entries of each parallel member again.

A dirty path or a staged change stops the sync with `parallel-dirty`. Local commits that remote main does not have stop it with `parallel-diverged`.
A submodule or another entry that cc-focus cannot seal stops it with `parallel-unsupported-path`. Local main then does not move.

Before a push, remote main must contain the base of the stage. After a push, remote main must contain the published commit.
Other writers can push on top at any time. For a parallel member, these two rules replace the exact comparison of local main and remote main.
This includes the publication checks, the CI wait, the stage boundary, and the review campaigns.

The fetch uses the push URL, no terminal prompt, and the timeout and the retries of the remote query. No hook runs during the fetch.

Before the first push of a publication, cc-focus merges the stage commits of each parallel member with remote main.
Git computes the merge without the working tree, so this needs Git 2.38 or later. An older Git stops with `parallel-git`.
A file that both sides changed gets the merged content without a new review.

cc-focus saves an integration record, moves local main to the merged commit, and moves the stage base to remote main. Then it pushes.
Several unpushed stage commits become one commit with the message of the last commit. Commit hooks do not run for this commit.
If `commit.gpgSign` is true, the commit gets a signature with the key of `user.signingKey`.

These stops need the operator:

- `parallel-merge-conflict`: a merge conflict, or a merge that moves stage changes outside the stage paths, for example after a rename.
  The message names the paths and a `git diff` command for the stage change. Change remote main in another clone. Then run the retry command.
  Another clone can also merge the stage commit into main, as the CI paragraph below describes.
- `parallel-remote-busy`: remote main changed three times during one publication. Run the retry command later.
- `parallel-remote-rewritten`: remote main no longer contains the base or the published commit. Restore remote main. Do not reset local main.
- `parallel-integration-state`: local main is not a commit of the integration record. Restore it to the named commit.

These stops and `parallel-dirty`, `parallel-diverged`, `parallel-unsupported-path`, `parallel-git`, and `project-manifest` start no recovery agent.
Their reason is `operator-context`.
A technical failure, for example of a fetch, a signature, or a sync command, keeps the recovery agent.
After an interruption, the runtime completes or undoes an open integration record before any other publication check.
`cc-focus reconcile --publication` refuses a parallel member.
A publication scope cannot exclude a file of a parallel member, because an excluded file becomes protected work.

The published commit of a parallel member can contain commits of other writers, so its CI result can come from their changes.
If that result is red, the gate also reads the result of the current remote main.
A green and complete result there passes the gate, if remote main contains the published commit and two polls give the same result.
The CI record and `cc-focus status` then name that commit and the stage paths that changed after the publication.
The recovery agent does not revert or rewrite a change of another writer. If such a change causes the failure, it reports a blocker.

If the published commit has no CI record, the gate also reads the result of the current remote main, with the same rule and deadline.
A timeout then names remote main and its last CI result.

This happens, for example, after a `parallel-merge-conflict`.
Another clone runs the `git fetch` command of the message, merges `FETCH_HEAD` into main, and pushes the merge.
Remote main then contains the stage commit, so the publication does not push, and the stage commit can have no CI.
Push the merge first and wait for its CI. Then run the retry command.

The main roles, the pair writers, and the readers of a version-2 pair get the field `parallel_repositories` with a fixed rule.
The rule says: change only what the stage needs, and in the active plan change only the status of stages. This is a rule in the prompt, not a runtime check.
It also says: if the work needs commits that remote main of a parallel member has, report a blocker, and do not copy their changes. A pair inspector reports a finding instead of a blocker.

The publisher and the recovery agent also get the field `parallel_publication`. It says that commits of other writers on remote main are not a blocker, because the runtime merges them before the push. A failure that they cause still is a blocker.

Risks:

- Nobody reviews a merged file. Two changes can merge without a Git conflict and still contradict each other.
- A later commit of remote main can change or revert the stage work. `cc-focus status` names the changed stage paths.
- A change of the active stage by another writer reaches cc-focus only at the next stage start. A correction can describe the change for the current stage.
- A conflict can stop a publication after an exclusive member was pushed. The project is then partly published until the retry.
- A review campaign does not queue a completed target again when only other writers changed its paths.
- A catch-up brings changes of other writers into a stage during its reviews. Nobody reviews these changes again.

#### Catch-up for a blocked step

A step can need commits of other writers. For example, a check compares the code with the documentation, and only the documentation has the new state.
The role then reports a blocker, as its rule says. Before a recovery agent starts, cc-focus fetches remote main of each parallel member.
A member moves to remote main only when its HEAD is in remote main and no remote change touches a local change.
Then the stage base moves, as after an integration, and the blocked step runs again without a recovery agent.

A pair in progress froze its candidate before the move. Its phase therefore starts a new pair on the current candidate with all open findings.
Completed pairs keep their credit, because the stage diff does not change. Another change of the checkout, for example an edit of the blocked role, still resets the reviews.

These limits apply:

- Only a blocker that a role reports gets a catch-up. A technical failure goes to the recovery agent at once.
- Each blocker gets one catch-up, and a stage gets at most three. After that, the recovery agent starts.
- A member that cannot move keeps its checkout, and the publication merges it later. If no member moves, the recovery agent starts.
- A member that a partial publication already pushed keeps its checkout. A blocker in the publication or in the CI wait gets no catch-up.

An integration record with `catch_up: true` makes the move recoverable. After an interruption, the next pass completes it before any other step.

#### Merge resolvers

Some files of a parallel member conflict often, but a project command can build them again. Examples are generated code and a frozen list of tests.
The key `resolvers` in `focus-project.json` names such commands. cc-focus then resolves these conflicts before the push, without a model and without a new review.
Every other conflict still stops the stage.

```json
{"version": 1, "repositories": ["Example", "Example-plans"], "parallel": ["Example", "Example-plans"],
 "resolvers": {"Example": {
   "rules": [{"name": "generated", "paths": ["tests/**/Generated/*.g.cs"],
              "command": ["python3", "tools/resolve.py", "generated"], "timeout": 3600}],
   "check": {"command": ["python3", "tools/resolve.py", "check"]}}}}
```

The values of the key:

- Each key is a parallel member. A member has 1 to 16 rules and an optional check.
- `name` is a short identifier, unique in its member. `paths` has 1 to 16 patterns, relative to the member root.
- `*` and `?` match inside one directory part. `**` crosses directories, and it must be a whole part.
- A pattern without `/` matches the file name at any depth. Matching is case-sensitive.
- The manifest refuses brackets, `\`, a `!` at the start, a `**` inside a part, an empty part, and a `.` or `..` part.
- cc-focus has its own matcher. Thus a `.gitattributes` file of a member cannot add a path to a rule or remove one.
- `command` is a non-empty list of strings. It runs without a shell. On Windows, name a program, for example `py`, not a batch file.
- `timeout` is 60 to 7200 seconds. The default is 1800.

An older runtime rejects the key. Each stage records the resolvers together with the parallel set, so a manifest change becomes active at the next stage.
A change of the resolver code applies at once, because the command runs from the merged tree.

A resolver runs only for a text conflict at one path. Both sides changed the same file, and Git wrote conflict markers into it.
Each path in conflict must match a rule. The first rule that matches takes the path.

A change against a deletion, a rename, a binary file, a symbolic link, and a `-merge` file still stop with `parallel-merge-conflict`.
A `filter`, `working-tree-encoding`, or `ident` attribute in the stage commit or in the merged tree also stops it.
Git names some conflicts only in its messages, for example a collision of directory renames. Such a conflict also stops.
The message names the paths that no resolver can resolve.

The resolution has these steps:

1. cc-focus saves the integration record with the step `resolving`. The member checkout must be clean, and it does not change.
2. It makes a temporary worktree in `.work/r/` of the project root. The worktree holds the merged tree with the conflict markers. No Git hook runs.
3. It runs the rules in manifest order, in the worktree. Each rule gets only its own paths.
4. It checks the result after each rule. Then it runs the optional check command on the resolved tree.
5. It removes the worktree and makes the merged commit. Then the publication continues, as the integration above describes.

Each command gets these environment variables:

- `CC_FOCUS_MERGE_INPUTS`: a JSON file. For each path, it gives the rule, the file mode, and the blob ids of the base, of remote main, and of the stage commit.
- `CC_FOCUS_MERGE_PATHS`: a file with the paths of the rule. A NUL character follows each path.
- `CC_FOCUS_MERGE_BASE`, `CC_FOCUS_MERGE_REMOTE`, and `CC_FOCUS_MERGE_STAGE`: the stage base, remote main, and the stage commit.
- `CC_FOCUS_PROJECT_ROOT`: the project root, for example to find a shared cache outside the project.

A command reads a version with `git cat-file -p <blob>`. An add/add conflict has no base, so its base id is `null`.
With more than one merge base, the base version can contain conflict markers. Do not use it as clean text.

Put rules that only merge text before rules that build, because the paths of a later rule still contain markers.
A command that builds must not use build servers. A server that stays alive can keep files open and prevent the removal of the worktree.
A process that keeps running after the command stops the publication with `cleanup-incomplete`. The message names the command.

The checks after each rule:

- The rule changed only its own paths. A change of another path, also a new untracked file, stops with `parallel-resolver-scope`. Ignored files are not checked.
- Each path of the rule changed, has no conflict marker line, and keeps its file mode. Otherwise, the stop is `parallel-resolver-failed`.
- A marker line starts with seven or more `<`, `|`, or `>` characters and a space. A line of `=` characters is not checked.
- The project outside the worktree did not change. HEAD of the worktree did not move, and no Git operation is open. Otherwise, the stop is `parallel-resolver-scope`.

The check command must not change the resolved tree or the project. A non-zero exit code or the timeout of a command stops with `parallel-resolver-failed`.
The progress line names the command and the member. An emergency stop with `cc-focus stop --now` interrupts the command.
A safe stop waits until the publication ends.

These stops need the operator, and they start no recovery agent:

- `parallel-resolver-failed`: read the log that the message names. Correct the resolver on remote main in another clone, or merge by hand, as the message says. Then run the retry command.
- `parallel-resolver-scope`: the message names the changed paths. Correct the resolver on remote main in another clone, or undo the change. Then run the retry command.
- `parallel-resolver-cleanup`: more than three temporary worktrees remain. Stop the process that keeps their files. Remove the directories, and run `git worktree prune`. Then run the retry command.

Each stop removes the worktree and the record. After an interruption, the next publication check removes them, and the next integration runs the rules again.
A new resolution always uses a new directory.

A removal that fails, for example on Windows, keeps an entry in `state["resolver_cleanup"]`. The entries stay across stages, and `cc-focus status` shows them as a warning.
Each later integration and each stage start tries the removal again. An entry goes when its directory is gone.
At a stage start, cc-focus also removes the other directories in `.work/r/`, for example of a completed review campaign.
A directory that it cannot remove also gets an entry.

The integration record and `cc-focus status` name the resolved paths and their rules. An artifact under `resolve/` in the run store keeps the evidence.
It holds the commands, the exit codes, the logs, the trees, and the merged commit. It also holds the blob ids of the resolver files in the merged tree.
A review campaign lists the resolved paths of each target in its report, with the last merged commit of the member.

Risks of the resolvers:

- Nobody reviews a resolved file. A wrong file can pass the check and CI.
- Without a check command, a wrong file reaches remote main, and CI fails for every writer. Configure a check.
- A resolver and the check run code of other writers from the merged tree, with full access. cc-focus finds changes only in the project and in the worktree.
- `read-tree` runs the smudge filters of the merged tree, for example LFS, before the attribute check.
- A merge without a conflict can still leave a generated file stale. The check or CI must find such a file.
- The commands build in a new worktree without build output, so they can take a long time. A moved remote main runs them again, up to three times.
- On Windows, the build tools need the long-path support of the operating system. cc-focus gives `core.longpaths` only to Git.

## Permissions and ownership

The command explicitly selects `codex -s danger-full-access -a on-request` and
`claude --permission-mode bypassPermissions`. Codex uses its stdio app-server
transport and pins/verifies the same permissions at thread start/resume. Actual
approval callbacks go to the operator, never to a fabricated automatic approval.
An unattended approval request stops the step and enters blocker handling.

Use this mode only in an appropriately isolated environment. It does not modify
root-config, project permission files or generated role frontmatter. Shared
ProcessKit discovery and the processor lease still apply. A live processor and a
cycle cannot own the same repository concurrently. A multi-repository cycle owns
the project and every member, so a separate cycle or queue processor cannot overlap
any member. Child ownership records guard against restarting beneath a crashed
parent whose provider exit is unconfirmed. While a member is owned by a project, its `status` names
that project and its `stop` refuses to act on an old independent member session;
run stop from the project root instead. An unknown/stale foreign lease
is not forcibly removed. Preflight ownership/containment failures stop without
starting a recovery process in an unsafe checkout.

Native delegation is disabled and prompts prohibit recursive CLI invocation and
background work. Every role, including Pair A executors and B/final `repair_execute`,
receives the shared command-execution contract on fresh and resumed invocations.
Where its role and operation permit checks, the executor runs builds, tests, mutation
batteries and diagnostics synchronously, with an adequate timeout. It must not detach
them with `nohup`, shell `&` or `run_in_background`, or replace completion waiting with
an estimated-duration `sleep`. A resumed command uses its existing completion mechanism;
if unavailable, inspect the known process/result immediately and check at intervals of
at most 30 seconds only while it runs. Collect its recorded outcome without duplicating
the command; process disappearance alone is not proof of success. These rules do not
grant tool access or override read-only roles, deferred tests or report-only correction.
Claude receives `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` in its
environment and inline settings to disable automatic Bash backgrounding; explicit shell
detachment is prohibited by the prompt, not intercepted by that setting. Monitor,
cron creation, wakeup, remote-trigger and Workflow tools are disabled too. Bash's
default timeout is 30 minutes; long commands can request up to six hours within
the existing six-hour invocation deadline. These are subprocess-only settings;
the runtime never edits operator or project configuration. See the official
[Claude environment variables](https://code.claude.com/docs/en/env-vars).

Claude also receives `CLAUDE_CODE_AUTO_COMPACT_WINDOW=400000` in the same two places.
The value is the constant `CLAUDE_COMPACT_WINDOW` in `cycle_prompts.py`, not a configuration key.
When the context of a conversation reaches this window, Claude Code compacts the conversation.
A compaction removes the first user message, which holds the runtime assignment and the report schema.

Before each launch, the transport writes a recovery copy of the prompt to `<store>/prompts/<role>.txt`.
`<store>` is the run store: `.work/cycle`, or `.work/cycle/review-runs/ID` in a review campaign.
The copy indents the JSON after each prompt marker, so a role can read it by line ranges.
The transport also adds each delivered operator message to the copy, under the heading "Operator messages".
The `prompt.txt` file of each attempt stays unchanged as evidence.

After the role contract, the system prompt gets a rule: after a compaction, read the copy again.
The path is fixed for each role, so a resumed session keeps the same system prompt and its prompt cache.
Only Claude roles get the copy and the rule.

A pair reader has no file access. It reads its copy with `focus_inspect` at the path `__runtime__/prompt.txt`.
Only `read` serves this path. `list` and `search` do not show it.
A project file with this path stops the freeze of the view with `pair-input`.

A Claude `result` event can precede completion of native tasks in older sessions
or CLI versions. While tasks or queued native turns remain, cc-focus records that
response as `deferred-*.txt` and continues reading events until a subsequent final
report. It leaves stdin open in interactive mode and delays operator input until
the native continuation finishes. Waiting prose earns no review credit. Fixes in
an intermediate structured report cannot be erased by a later clean report;
cumulative counts retain their maximum before normal operator-response summation.
EOF before a final report remains an interrupted invocation. The 30-second exit
grace applies only after the final response, not while native work continues.

Codex also receives `features.memories=false` at app-server startup
and at thread start/resume. Its memory consolidation agent is independent of ordinary
multi-agent delegation and can otherwise run tools alongside the selected role.
The flag disables the memory subsystem only in these provider processes; it leaves
global settings, existing memory files and persistent role conversations intact.
Already-injected conversation context is not erased. See the official
[memory feature configuration](https://learn.chatgpt.com/docs/config-file/config-reference).
These are orchestration controls, not a security sandbox around
arbitrary commands in full-access mode. Existing unrelated dirty files are recorded
as protected at first start, excluded from publication and checked for changes.
If the next task overlaps those files, reconcile ownership before retrying. Work
already owned by this cycle remains resumable after interruption.

## Live activity and stopping

### Persistent terminal input

On a capable interactive terminal, `cc-focus` automatically opens a scrolling log
with a permanent input line and a status panel above the log. `--ui on`
requires that interface; `--ui off` keeps ordinary output and no input reader.
Redirected input/output and `TERM=dumb` fall back to ordinary output automatically.
The terminal uses the Python standard library, with no package installation.
Long runs keep a bounded cache of wrapped output and reuse the visible log window
while typing. New output, scrolling and terminal resizing refresh that window;
ordinary typing redraws only the input row. Repeated unchanged status updates do
not repaint the screen. These UI optimizations retain the existing role sessions.
Periodic activity heartbeats update the panel without appending duplicate lines
to the interactive log; ordinary `--ui off` output retains its timed heartbeats.
Reading older log output keeps the visible position when new events arrive, until
those lines leave the bounded 3000-line history. The footer shows scroll position
and navigation keys. PageUp/PageDown scroll by a screen; Ctrl+Home/Ctrl+End jump
to the first/latest retained lines. POSIX terminals with mouse reporting also
support the wheel; hold Shift for terminal text selection/copy. Mouse reporting
is disabled again when the interface exits, including after an exception.
Normal and application-mode cursor keys are decoded as keys; unsupported key
sequences are discarded in full instead of inserting trailing `A`/`B` characters.
Wheel scrolling requires mouse reports from the terminal. If a terminal or
multiplexer translates the wheel into arrow keys, those keys select input history;
use PageUp/PageDown or enable mouse forwarding in that terminal. After updating
Orchestra, run `cc-sync` from its checkout to refresh installed scripts, then restart the terminal
interface to load the new input handling; an already running process keeps its old code.

A pending Codex approval automatically opens a separate request view, showing
the command, working directory, reason (when supplied) and complete request data.
It remains available independently of log output and history eviction until it
is answered or cancelled. Long requests use the same paging/wheel controls.
`/log` shows the journal while consent is pending; `/approval` returns to the
request. Only `/approve` or `/deny` answers that operation; browsing is not consent.
The request view clears on answer, stop or interrupted waiting.
Command replies (`/help`, `/status`, `/messages`) and input errors open the latest
log output so that feedback is visible even while consent is pending. The operation
remains available through `/approval`; showing feedback never answers it. Ctrl+C
interrupts even after a truncated keyboard/mouse packet; Ctrl+C inside bracketed
paste remains text data and does not issue a stop. A new escape sequence supersedes
an incomplete packet, so an embedded fragment cannot swallow the paste-end marker.
`--output compact` still controls whether public provider payloads are displayed.

The panel separates status from scrollable logs and shows both participants:

```text
Orbit · P05.2 · Content safety and redaction
В РАБОТЕ · Пара B · шаг 3/6 · этапов впереди: 3
✓ Реализация ─ ✓ Пара A ─ ▶ Пара B ─ ○ Финальная пара ─ ○ Публикация ─ ○ CI
A: ✓ завершён · B: до устранения значимых · Финал: до устранения значимых
Раунд 4 · discuss · обмен 1/2 · находок 2
gpt-6-astra/xhigh: отчёт сохранён
opus/max: работает
────────────────────────────────────────────────────────────
```

The title comes from the selected stage in the project plan through the existing
coordinator/coder report. The coordinator can shorten it in that same call; no
extra model is started. Older saved runs show `Задача N` until a report identifies
the stage. The title is display metadata and cannot advance or select work.

The timeline shows the seven main phases of this task, including returns to review.
Coordination, recovery, Git remote checks and CI waiting appear as actual current
activities. Remaining phases and the minimum clean passes still needed are counts,
not a time estimate: fixes can add more passes. Review rows distinguish pending,
running, clean, reset, interrupted and rejected attempts. Completed pass totals
survive a streak reset, with its reason retained in `/status`. Legacy totals are
shown with `≥` because old state did not record every completed pass. Counts reset
for a new task; historical iterations remain archived. CI without configured checks
is shown as `не требуется`, and displayed CI results belong to the published SHA.

Approvals, blockers, stop requests and uncertain/queued message delivery take
priority over routine activity. Color reinforces the text labels. Timers refresh
once a second without scanning logs. Stage-pause status reads only the small control record, at most once per second.
Smaller terminals use up to
three compact lines with the mode, task, phase and review streaks; text is clipped
with an ellipsis. `/status` prints the full panel and recent review events regardless
of terminal size. `cc-focus status` also returns the panel as `dashboard` in its JSON.

| Input | Meaning |
| --- | --- |
| Ordinary text, Enter | Save an instruction for the active invocation and role |
| `/pause` | Finish the current invocation and pause; publication includes CI |
| `/finish-stage` | Finish the current stage through publication and CI, then pause before the next stage |
| `/finish-stage cancel` | Cancel the scheduled stage pause without starting processing |
| `/stop` or Ctrl+C | Interrupt the active attempt; preserve partial work |
| `/resume` | Continue a stopped workflow, retrying a preserved blocker when appropriate |
| `/correct TEXT` | While stopped, correct the same stage and restart coding/reviews |
| `/messages` | List saved message IDs, target invocations and delivery states |
| `/retry-message ID` | While stopped, explicitly resend unresolved input to its original pending invocation |
| `/discard-message ID` | While stopped, abandon unresolved delivery without deleting its artifact |
| `/approve`, `/deny` | Answer only the currently displayed Codex approval |
| `/approval`, `/log` | Switch between the pending operation and the journal |
| `/status`, `/help` | Show state or commands |
| `/exit` or Ctrl+D on empty input | Safely pause, then close the terminal |

PageUp/PageDown and the mouse wheel browse the current view; Ctrl+Home/Ctrl+End
jump to its beginning/end. Up/Down recall input history. Arrow keys,
Home/End, Delete/Backspace and Ctrl+U edit input. Bracketed multiline paste becomes
one instruction and cannot execute embedded commands without Enter. Slash commands
are local workflow controls, not arbitrary shell execution. Ordinary text never
grants a tool approval. Native approval requests share the same input owner.

Codex receives instructions through active-turn steering with `expectedTurnId`.
Claude keeps its input stream open: saved instructions are sent one at a time
after the current response, without restarting the process or changing the role.
Each requires a replay acknowledgement and its own result. Earlier Claude response
reports remain in the invocation log and their fix counts are aggregated, so a
later clean response cannot erase earlier fixes. A receipt is not proof that the
instruction was applied, nor an interruption of a running tool. These boundaries
follow the [Codex app-server protocol](https://learn.chatgpt.com/docs/app-server)
and [Claude CLI streaming flags](https://code.claude.com/docs/en/cli-reference).

Instructions cannot steer publication, CI or recovery inside that window. Review
instructions invalidate previous clean credit; an intervened fixing review returns
to Sol before publication. Accepted instructions are referenced in later stage
context. Messages never silently move to the next invocation or stage. A message
arriving at completion instead pauses the workflow with its original target intact.
`/resume` can retry queued (not yet sent) input in that same invocation. Delivery
marked `sending` without acknowledgement, or `rejected`, requires an explicit
retry/discard decision; replay may duplicate an instruction already received.

Messages are atomically stored under `.work/cycle/messages/ITERATION/` with hashed
identity/text and separate delivery status. These files can contain sensitive text.
Input becomes durable only when the console says **saved**. A crash during delivery
does not fabricate acknowledgement or launch automatic healing. The ordinary CLI
also exposes model-free inspection and resolution for recovery without a TUI:

```sh
cc-focus messages
cc-focus retry-message --id MESSAGE_ID
cc-focus discard-message --id MESSAGE_ID
cc-focus --ui off
```

Retry/discard requires stopped processing. Resolve outstanding messages before a
stage correction; report-based review recovery cannot bypass message history.
At a safe pause or interruption the lease and runtime lock are released while the
terminal stays open for `/resume`. External `cc-focus stop` acknowledges that parked
state without waiting for the terminal window to close. An emergency does not undo
completed side effects. If the UI itself becomes unresponsive, the external
`cc-focus stop --now` remains the contained hard-stop mechanism.

### Provider output

The console shows the iteration, phase, role, model/effort, review counters, protocol
and result paths. Claude partial events and Codex item/plan events report actual
tool activity. Live output is the default: public messages appear as they arrive,
followed by tool names and arguments, command stdout/stderr, exit status, file
changes, tool results and provider errors. Codex command output streams in chunks;
Claude tool results appear when the CLI emits them, often after the command ends.
Structured final reports are displayed as readable results after validation.
Every 15 seconds a heartbeat shows elapsed time, event count and
time since the last event, even when a model or tool is silent. This proves the
runtime is servicing its loop, not that an unresponsive model is making progress.
Use `cc-focus --output compact` to keep only compact activity and final summaries.
Neither mode displays private reasoning or raw protocol envelopes. Terminal control
characters are neutralized; display is capped at 64 Ki characters per item with an
explicit truncation notice. Recent item snapshots suppress repeated streamed output.
Full original events remain in the invocation's private `protocol.jsonl`; the display
cap does not truncate that log. Output and command arguments can contain secrets:
this is not a secret-redaction guarantee. Use compact mode for shared terminals and
treat protocol logs as sensitive. Compact status snapshots never include tool output.
`cc-focus status` starts no model and reports current versus stale activity, the
last coordinator summary, pending stop, PAUSE state and process ownership.
Progress older than 30 seconds is marked stale even when the runtime lock is held;
an existing process is not proof of a responsive processing loop.

From another terminal at the same project root:

```sh
cc-focus stop                 # request a safe stop and wait for acknowledgement
cc-focus stop --timeout 600   # bound the wait; keep the request if it times out
cc-focus stop --now           # interrupt now and wait for contained cleanup
cc-focus finish-stage        # schedule a pause after this stage's publication and CI
cc-focus finish-stage --cancel # cancel that scheduled pause without resuming
cc-focus status
cc-focus                      # continue the preserved phase and native sessions
```

A safe stop completes the current invocation/pass, saves its result, and prevents
the next one from starting. Once publication has begun, its commit/push and CI
window finishes first. If an error blocks that window, the runtime preserves the
blocker and stops; it does not start a recovery model in response to a stop request.
Stop acknowledgement waits for the local lock and contained run to finish. A wait
timeout or Ctrl+C in the waiting terminal does not withdraw the stop request.
If the stopped run ends at an escalated blocker, the stop command refers to the run output.

An emergency stop does not wait for clean review or green CI. The runtime closes
the provider and preserves pending intent and partial work; if it cannot respond
within five seconds, the stop command targets that exact ProcessKit run for hard
termination. Providers have separately addressed containers as well, so a weak
process-group root cannot leave a provider's separate group running: emergency
cleanup stops the spawning root, then its last recorded provider container.
It never kills by process name, an unverified PID, or `--all`.
Ctrl+C in the processing terminal is also an interruption, not a safe-stop request.
Interrupted tests/edits may need recovery; a commit or push already performed is
not rolled back. On continuation, incomplete reviews repeat and Git publication
is reconciled before another commit/push. No stop procedure can undo external side
effects already produced by an interrupted command.

Safe and emergency stop requests belong to one run.
A later explicit `cc-focus` starts or resumes with a new run identity.
An old stop request cannot stop that run. Existing `.work/PAUSE`
remains an independent persistent switch: use `cc-unpause` yourself before resuming
when that switch is set. Focus never creates or removes PAUSE for its own stop API.

### Finish the current stage, then pause

Use `/finish-stage` in the terminal to schedule a pause after the current stage.
From another terminal, run `cc-focus finish-stage` at the same project root.
The command returns after it saves the request. It does not wait for completion or start a provider.
If processing is stopped, use `/resume` or run `cc-focus` to continue.
If the active runtime does not support this command, restart it with the updated runtime before scheduling the pause.

The cycle completes implementation, required reviews, publication, and the CI gate before this pause.
For a project with multiple repositories, all published members must pass their CI gates.
The existing policy still decides whether CI is required.
The runtime starts no coordinator or coding invocation for the next stage before it pauses.
The panel retains the completed stage and shows how to start the next one.

The request follows the current iteration across restarts, corrections, provider waits, and recovery.
A blocker can still stop the cycle before completion. Such a stop does not mean publication or CI succeeded.
Safe stop, emergency stop, and `.work/PAUSE` keep their existing priority and behavior.
The command neither answers approvals nor changes review requirements.

Use `/finish-stage cancel` or `cc-focus finish-stage --cancel` to cancel a pending request.
Cancellation does not resume processing or undo a completed pause.

After the completed-stage pause, use `/resume` or run `cc-focus` to start the next stage.
The runtime checks the completed stage again before that transition. It does not repeat the completed CI gate.
If the plan has no remaining stage, the cycle completes normally and retires the request.

During the pause, you can commit other work and push it to main.
The next stage then starts from the current main.
Protected work can also change during the pause.
The next stage protects every uncommitted path again.

Before the next stage starts, the runtime makes these checks:

- Main still contains the published commit of the completed stage.
- Local main and remote main point to the same commit. For a parallel member, remote main contains local main, and the sync then takes the commits of other writers.
- Uncommitted changes are only in protected work.

In a project with several repositories, the runtime checks each published repository.
It also checks each other repository with a changed main.
For such a repository, main must still contain the commit from the start of the stage.
Files outside the member repositories are project context.
The next stage reads their current content.

If a check or another step of this transition fails, the run stops for the operator.
Recovery does not start, because a recovery agent may not change main or its remote.
Correct the problem. Then run `cc-focus --retry`.

A review run makes the same checks after its stage pause.
It then queues a completed target again when later changes reach its recorded paths or their directories.

### Stop, correct and continue the same stage

Wait for the stop command to confirm shutdown before submitting a correction:

```sh
cc-focus stop                 # or: cc-focus stop --now
cc-focus correct --message "Keep the current stage. Handle empty input as well."
cc-focus status
cc-focus
```

For longer text, use `cc-focus correct --file /path/to/correction.md` instead of
`--message`. The file must be nonempty UTF-8, at most 64 KiB; quote paths with spaces.
The command starts no model. It acquires the runtime lock and shared processor
lease, archives the previous state, copies/hashes the correction, and exits paused.
`status` lists immutable correction paths and the latest pending correction ID.
Remove an operator PAUSE with `cc-unpause` before requesting this transition.

The current iteration and native role sessions are retained. Coding resumes the
same project-plan stage to apply the correction, even if that stage's earlier
implementation report said it was complete. This is a fresh turn in the retained
coding conversation, not a replay of the interrupted turn. The old invocation and
its result remain available, but cannot acknowledge the new correction. Corrections
are ordered oldest to newest, and remain in context through the complete review sequence.
All clean-pass credit and the publication seal are invalidated. Only a validated
coding result acknowledges the pending correction; both required pairs and the final pair
clean passes must then be earned again. New sessions or `--retry` do not erase it.

Corrections live under `.work/cycle/corrections/` with checksums for both text and
the archived stage context. Changing the original source file has no effect. The
state update is atomic: a crash before it leaves the old workflow authoritative;
unreferenced correction files are not automatically applied. After acceptance,
restart with `cc-focus`; do not edit `state.json` or copy old result files over it.
At most 32 corrections may be attached to one stage. Once its publication and CI
finish, they remain in the archived iteration and are removed from active context.

The command refuses a running processor, an unstarted or completed stage, changed
protected work, changed HEAD, and any possibly started publication/CI window.
After a safe stop that finishes publication and CI, the next iteration has not
started: an old stage cannot be silently reopened there. Use a new handoff/project
plan change for follow-up work. During an interrupted publication, first resume
its reconciliation/CI; corrections never roll back a push or bypass CI.

This is a stop-and-resume interface, not an interactive provider terminal. Typing
into the processing terminal does not send a correction to a running model.

### Project brief

The project brief is a short operator text about the project.
It names the purpose, the long-term direction, the users, the priorities, the limits, and the milestone goal.
Roles use it to find the effect of a change or a finding on these users and goals.
The brief adds no requirement, task, or stage, and it does not show the status of the work.
The role contract, operator messages and corrections, the review scope, the project instructions, and the plan take precedence over it.

Start from `project-brief.example.md` in the Orchestra checkout. Keep the file outside the project, for example `~/briefs/interlink.md`.
A file inside the project is ordinary project work. Commit it, or keep it in an ignored path.
Otherwise it becomes a stage file, protected work, or a `stage-base-dirty` stop, as any new file does.

```sh
cc-focus brief set ~/briefs/interlink.md   # import a copy, used from the next stage
cc-focus brief show                        # pointer, stage records, source observation
cc-focus brief show --review-run ID        # the record of one campaign
cc-focus brief clear                       # the next stage has no brief
cc-focus brief restore ~/briefs/interlink.md   # restore a damaged copy, keep the pointer
```

- Run the brief commands at the repository root or at the project root, not in a linked worktree.
  In project mode, use the project root. A pointer in a member repository applies only to standalone runs of that repository.
- `set`, `restore`, `clear`, and `show` start no model, take no lock, and change no workflow state.
  Thus they work while a run is active.
- The brief is a regular UTF-8 file with text, no NUL bytes, and at most 8 KiB. The recommended size is about 300 words.
- `set` stores an immutable copy as `.work/cycle/briefs/<sha256>.md` and writes the pointer `.work/cycle/project-brief.json`.
  Later edits of the source file have no effect until the next `set`.
- The brief is local to the machine. Handoffs do not carry it. On another machine, run `brief set` again.
- Snapshots exclude `.work/cycle/`. Thus the brief never becomes a stage file, a protected path, or a publication path.

Each stage captures the pointer once, at its start, in `state["project_brief"]`.
The record has the iteration and the hash. A pointer change takes effect at the next stage.
`cc-focus status` shows a pending change as "takes effect at the next stage".

To cancel a pending change, run `brief set` again with the earlier file. If the stage has no brief, run `brief clear` instead.
A state from an older runtime has no record. Its current stage has no brief, and the next stage captures the pointer.

The brief reaches these roles as the field `project_brief`, with the text, the hash, and the rule:

- the code role
- pair executors and `repair_execute`
- pair inspectors, discussion readers, and the arbiter
- inner repair readers, the final-pair inspections, and the final arbiter

The coordinator, the publisher, the healer, the complexity assessor, and the evidence auditor get no brief.
A pair stores the hash at its start. Its readers, its writers, its inner readers, and its final gate use that hash, not the current pointer.
A pair from an older runtime has no hash and gets no brief, so its saved jobs keep their prompts.

To change the brief of the stopped current stage, use `cc-focus brief apply`:

```sh
cc-focus stop
cc-focus brief set ~/briefs/interlink.md   # or: cc-focus brief clear
cc-focus brief apply                       # a campaign needs --review-run ID
cc-focus                                   # a campaign: cc-focus review --resume ID
```

- `apply` refuses a completed plan, unresolved messages, publication, CI, a stage pause, a changed HEAD, and changed protected work.
  There, the pointer takes effect at the next stage. If the stage already uses the pointer hash, `apply` changes nothing and exits with code 0.
- If no work, conversation, or pending invocation of the stage used the brief, `apply` updates the record directly.
  A saved blocker stays. After `apply`, run the retry command.
- Otherwise `apply` records a correction with a fixed text that contains no brief text.
  The correction resets the reviews and pairs. It sets no publication recovery, and it keeps an earlier pending correction.
  Roles receive the fixed text as `project_brief_notice`, not as a task correction.
  Thus a brief change alone never adds the same-stage selection text.
- `apply` keeps the role sessions. The notice tells these roles not to use the earlier brief text.

If the old brief caused a provider refusal, use this order:

```sh
cc-focus brief set FILE          # or: cc-focus brief clear
cc-focus --new-sessions          # new conversations, then a stop at the saved blocker
cc-focus brief apply
cc-focus
```

In a campaign, use the campaign ID throughout the same order:

```sh
cc-focus brief set FILE                       # or: cc-focus brief clear
cc-focus review --resume ID --new-sessions    # without --retry
cc-focus brief apply --review-run ID
cc-focus review --resume ID
```

These session replacement commands assume a saved refusal blocker. Without that blocker, they can start work.
If `apply` reports a direct update, the saved blocker stays. Then run the retry command that `apply` names.

After `status=complete`, a restart with `--handoff` is a stage start. It captures the pointer before any state change.
If the brief hash changes, the restart also starts new role conversations.
A bad pointer, an invalid handoff file, a lease failure, or an interrupt keeps `status=complete`. After the fix, repeat the command.

A malformed pointer, a missing or changed copy, or a damaged stage record stops the work with `brief-drift`.
A redirected `.work/cycle/briefs` directory stops the work with `brief-path`. Its message names the path fix.
No healer starts for either error. A `brief-drift` message names the remedy for its call site:

- At a stage start in the run: run `brief set` or `brief clear`. Then run the retry command.
- At a stage start before the run: run `brief set` or `brief clear`. Then repeat the same command.
- At a prompt build: run `brief restore` with the same file. Then run the retry command. The pending default stays.
- At a prompt build without that file, run these commands in this order:
  1. `brief set` with another file, or `brief clear`.
  2. `brief apply`. In a campaign, add `--review-run ID`.
  3. `cc-focus`. In a campaign, run `cc-focus review --resume ID` instead.
- For a damaged stage record: run `brief apply`. In a campaign, add `--review-run ID`.
  Then run `cc-focus`. In a campaign, run `cc-focus review --resume ID` instead.

Publication does not read the brief, so a drifted copy does not stop publication or CI.
`status` reports pointer and copy errors in its `project_brief` entry and never reads the original source file.

### Accept changed instructions and hand over protected files

`project-context-changed` means shared files outside member Git repositories no
longer match the iteration's saved context. `protected-work` means files that were
already dirty when the iteration started have changed. Importing a new handoff or
using `--retry` does not accept either difference. A healer cannot grant itself
ownership of that work or edit the saved baseline to hide the mismatch.

When these are intentional operator changes, stop the runtime and use the explicit
handover command from the project root:

```sh
cc-focus reconcile --plan-out .work/focus-reconcile.json
# Inspect the listed files and their current contents/diffs before acceptance.
cc-focus reconcile --apply-plan .work/focus-reconcile.json
cc-focus
```

Both reconciliation commands start no model and hold the project/member locks and
shared leases. Preparation accepts nothing. Without `--plan-out`, `reconcile`
prints the proposed plan. Output files must be new: use another name for a new
plan. Inside the project, write a JSON file directly under `.work`; source files
and runtime control paths cannot be output destinations. An external plan path is
also supported.
In a single Git repository the `.work` plan destination must be ignored, so
writing the plan cannot invalidate its own checkout fingerprint. Use an external
destination if `.work` is intentionally tracked; the command does not edit Git ignore rules.

The plan lists exact paths with before/after fingerprints and two actions:

- `refresh-context` accepts the current shared context outside Git. Those files
  remain read-only for every model and are never publication targets.
- `adopt-file` transfers the **whole protected member file, including its earlier
  uncommitted content**, to the current iteration for coding, review and publication
  in its own repository. Other protected files and their staging remain protected.

Review the entire contents/diff of every adopted file, not just the latest edit.
Its publication baseline becomes Git HEAD, using checkout line endings/filters;
new files have no Git baseline. The original dirty baseline remains in the archive.
The command does not infer consent from a healer report or from new instructions
written by a model. Only the operator may apply the plan; provider roles must never
approve their own handover. A plan currently covers all detected context/protected
file changes; editing the JSON to omit paths is rejected.

Application checks the plan against the saved task/state and the current work
snapshot, including repository HEADs and index. Already-imported loose handoff
sources are excluded as described above. A work change after preparation requires
a new plan; lease identities and save timestamps alone do not invalidate it. The
runtime rechecks immediately before the state transition. It archives the prior
state and exact plan in a checksummed correction, keeps sessions and the current
stage, clears the old pending invocation and all review credit, and exits paused
before coding. If coding already started, it must apply the current instructions
to that same stage and the complete review sequence must run again. If the iteration stopped
before coding began, reconciliation preserves that fact and clears any provisional
task label: select the next stage
from the current project plan, without reopening the previous published stage from
an old conversation or handoff. Any adopted work must still complete coding and
all required reviews before publication. A context-only handover with no unpublished
changes can finish if the plan is exhausted; it must not invent a stage.
Existing source files, index and Git history are preserved. The new correction
remains visible through publication and CI.

Handover requires a code iteration (including one not yet started) or an
already-started review stage, with unchanged HEADs and protected staging.
It refuses publication/CI, unresolved operator messages,
PAUSE, changed repository membership and unconfirmed provider shutdown. It cannot
rewind a commit or push, change runtime permission settings, or turn shared files
outside Git into implementation files. Do not edit `.work/cycle/state.json` by hand.

### Accepting an already-published protected scope

If an older publisher committed protected files beyond its supplied scope, an
operator may explicitly accept those exact files without rewriting published
history. This is a separate mode, not a relaxation of ordinary reconciliation:

```sh
cc-focus reconcile --publication --plan-out .work/publication-recovery.json
# Inspect the exact adopted paths, baseline/current commits and live remote main.
cc-focus reconcile --publication --apply-plan .work/publication-recovery.json
```

`focus_publication_recovery.py` requires a stopped publish phase with unchanged
reviewed working files. Every target HEAD must match live remote main at its
pinned push URL. History must descend linearly from the original baseline. Only
extra committed paths that were protected may be adopted; unrelated intermediate
paths, changed shared context, new content, altered staging or another destination
are rejected. Adopted paths must match the published content with no additional
staging. Other protected work and staging stay protected.

Preparation accepts nothing. Application requires the exact unedited plan and
rechecks state, files, HEADs, index and live remotes before acceptance under the
normal project/member ownership locks. The prior state and plan are archived in
an immutable correction. Original baseline HEADs and Git history remain intact;
adopted file baselines come from those original commits, so the full adopted work
remains visible in the iteration's review scope.

Acceptance grants ownership only. Review counters and publication/CI credit are
cleared, sessions and the same task are retained, and the command exits paused
before pair A. It starts no model, commits or pushes nothing, and never
resumes the cycle. After the operator resumes, the complete review sequence must finish
before runtime publication reconciles existing pushes and publishes any remaining
reviewed files. An archive omitted from an earlier commit remains pending work.
Provider roles must never apply this command to authorize their own scope changes.

### Upgrading a running cc-cycle installation

The rename retains `.work/cycle/`, native role sessions and durable invocation
markers. Do not use `--new-sessions` just to rename the command. Installed managed
`cc-cycle` launchers are removed by `cc-sync` and replaced with `cc-focus`; internal
Python module names need not match the public command.

An interactive process keeps its loaded Python runtime. After a processing epoch
and before a new `/resume`, `/correct` or message-resolution epoch, cc-focus compares
the installed Python bundle with its startup fingerprint. A changed or incomplete
bundle displays a persistent `/exit` + fresh-start notice and prevents continuing
with stale code. It does not hot-reload modules or restart a running provider.
After `/exit`, start `cc-focus --retry` in the project to load the new runtime.

A saved pair job keeps its saved prompt after an update.
The runtime accepts the prompt of a known earlier pair contract for the same assignment.
The test scope revision adds only the `full_run` and `final_gate` assignment fields.
A saved job without these fields continues with its earlier text.
New jobs use the current contract.
A resumed final-pair job gets the `final_gate` rule only from the current role contract.

The already-running old runtime cannot receive the new stop protocol. In that
project use `cc-pause`, wait for its paused message and exit, or use Ctrl+C there
for an emergency interruption. Then run `cc-sync` from the Orchestra checkout.
Back in the project, run `cc-unpause` if needed and `cc-focus`. Do not replace the
installed runtime bundle while a processor is still using it.

## Paired review protocol and context

All reviews inspect the **current stage diff**, including untracked files and all
changed member repositories. Related source is available to establish behavior;
this is not a whole-solution audit. A reviewer may flag an incidental defect, but
unrelated improvements are explicitly deferred instead of silently broadening scope.

For each pass the runtime freezes files, baseline diff, repository HEADs and index
fingerprints. Both initial reviewers see this same candidate. A and B start their
two readers concurrently. Final Opus runs before Fable, but neither initial prompt
includes the other's report. Each initial/discussion call gets a separate native session; a retry resumes only
that same job. Shared public reports carry context between calls. Each call returns
one complete structured report; only the runtime writes review artifacts. Reviewers never edit journals, build,
run tests, execute project commands, start agents or write source.

In project mode, each reader also gets the instruction list of its frozen view.
The list names current source files, not earlier review opinions.

The runtime unions every finding with a stable source ID. After both initial
reports finish, the reviewers receive each other's complete public report and any
carried closure obligations. They exchange at most two rounds of assessments.
Every finding requires a disposition: fix, reject, duplicate, targeted verification,
or explicit deferral of an unrelated improvement. A duplicate references a retained
finding. A proposal hash covers the exact decision document, including its wording
and impact classification. Both endorsements must name that hash. A changed proposal
invalidates previous endorsements. No-findings passes need no artificial discussion.

An endorsement sets `consensus` to the 64-character hash value only, with no other text.
Reasons go in the summary or description.
The discussion roles receive this format rule in their role contract.
The saved discussion prompt stays unchanged, so an interrupted discussion can resume.
After both readers finish, the runtime rejects an endorsement whose `consensus` is not exactly the proposal hash.
It also rejects an endorsement whose impact differs from the proposal.
The correction prompt names the exact expected hash and impact.
Without a proposal, the correction tells the reader to set `consensus` to null.
The check runs after both readers finish, so a slow peer keeps its completed report.
After two invalid corrections, the runtime stops with `pair-report`.
An operator `--retry` gives the unfinished reader a new correction budget.
A correction prompt replaces an older saved endorsement error with the exact expected values.

Remaining disagreements go to a separate **Astra/max arbiter**. Its exhaustive
ruling is binding; the operator is not asked to choose a reviewer. The arbiter may
reject a false positive, refine a repair, classify severity or assign a specific
diagnostic to the Opus executor. The executor returns observed results, then the
arbiter decides again. Repeating an answered assignment without new evidence invokes
normal autonomous recovery rather than silently granting credit or spinning forever.
Genuine missing authority, account access or unavailable provider capability still
uses the ordinary recovery/escalation boundary.

The arbiter can report a new finding in `new_findings`. Like a discussion finding,
it joins the registry. A second arbitration then decides the complete registry, with
the earlier ruling in `prior_rulings`. That second arbitration cannot add findings again,
so a later inspection must find any other defect. A later arbitration, for example after
an executor dispute, can add findings one more time.

In pair A, before an accepted fix or diagnostic, a separate read-only **Codex
GPT-6-Sol/high** assessor rates every assignment and chooses **Opus/high** for
clear localized work or **Opus/xhigh** for interacting changes, architectural/security
risks or uncertainty. The batch uses the maximum required effort. Complexity is
independent of severity: a serious defect can have a simple repair. The assessor
cannot alter accepted findings, severity, blocking or scope. Its report is sealed
against the exact candidate and complete assignment list; restart reuses that
assessment and the pinned executor effort. An unavailable model/effort is reported,
never silently substituted. The assessor is explicitly pinned to `gpt-6-sol/high`.

Pair A uses the selected **Opus/high or Opus/xhigh** executor; B/final always use **Opus/xhigh**. It
accounts for every source ID with a fixed/verified/disputed/deferred outcome and concrete
evidence. A verification assignment requires a verified outcome; a fix requires
fixed. Deferred means unfinished, never closure or review credit. Disputes return
to arbitration and cannot silently disappear.

Pair A's `pair_fix`/`pair_cleanup` (including `_high`) may build affected projects
and run assigned targeted tests as part of execution. The B/final two-clean-pass
inner gate does **not** apply to Pair A, even when a reviewer mistakenly refers to
it in a diagnostic assignment. Every assigned ID must appear in the report;
unrun checks must be reported honestly as deferred, not omitted or claimed passed.

Each outer pair starts the Pair A executors in new sessions.
`new_pair` removes the sessions of `pair_fix`, `pair_cleanup`, `pair_fix_high` and `pair_cleanup_high`.
Inside one pair, the continuation, the report-only correction and a repeated disputed execution keep the session.
The code role keeps its session for the stage. `repair_execute` starts a new session for each repair batch.
The final-gate pair does not start through `new_pair`, so its sessions do not change.

A new session does not have the earlier work of the stage, so the executor assignment has the field `stage_handoff`.
It lists the absolute paths of the handoff records of this stage: executor records, pair conclusions and repair seals.
An entry also shows the phase and the outer round of its record. Older records do not have these values.
A changed record stops the executor with `pair-evidence`.
The current assignment, operator corrections and operator messages have priority over the handoff.

`focus_pair_execution.py` retains completed closures in a sealed execution ledger.
Missing, deferred or incompatible outcomes trigger a continuation of the same
pinned executor, with only the outstanding assignments. It first reconstructs
missing accounting from saved evidence, or performs the remaining work; completed
repairs and successful checks must not be repeated. All obligations must close
before advancing or starting a fresh outer review. Later edits invalidate earlier
verification unless the new report certifies the new candidate. Earlier substantial
changes remain substantial even if the continuation only runs checks. Two consecutive
continuations without closure progress stop for normal recovery. Disputes send
both closed and unfinished obligations to arbitration, without premature testing.

Restart/retry can replay the exact saved original result without another provider
call, then continue its outstanding work. The runtime checks the original role,
iteration, correction revision, assignment/complexity binding, operator messages
and current files/HEAD/index. Legacy reports require the saved executor prompt;
a unique original can be found after healing overwrote `last`. Completed reports
are immutable, and no-op recovery preserves them. Later source drift, changed
instructions or corrupt records cannot adopt stale closures. This is compatible
with Profile 8 and does not reset its reviews through migration.

Executor counters and `substantial` describe this invocation, not the cumulative
batch. If an otherwise valid executor report has three zero counters and
`substantial=true` on an exactly unchanged files/HEAD/index snapshot, the runtime
requests one **REPORT-ONLY CORRECTION** in the same executor session. The strict
parser still rejects the original. The correction may change only the substantial
flag and explanatory summary/description; all checks, resolutions and other fields
must remain identical. No tool use, edits, builds or tests are requested. The
runtime separately retains cumulative impact and required outer re-review.

The immutable original and a separate correction invocation survive retry and
no-op recovery. In Pair A and in the B/final test step, interrupted corrections
resume their own marker, including after pending was cleared. The B/final fix
step has no saved-result discovery. There, recovery treats an interrupted
correction like a rejected report: changed work resets the pair, and unchanged
work runs again. A rejected correction cannot create another automatic
correction; normal recovery applies. The same accounting path covers B/final
executors without discarding their two clean static passes or rerunning completed
tests. Other malformed reports, changed work or stale bindings are not eligible
for this zero-counter correction. The counter corrections below cover changed work.

Executors receive the counter rules of the runtime parser in their role contract.
An executor report with substantial=true and implementation_fixes=0 gets one report-only correction in the same session.
An executor report that changed files but has zero counters gets the same correction.
An executor report without changed files but with edit counters or substantial=true also gets it.
The correction can change only the three counters, substantial, summary and description.
It must keep status, evidence, resolutions and every other field.
Only a completed report gets this correction. A correction that returns blocked stops the cycle with its reason.
A second invalid report uses normal recovery.
Other roles keep the `invalid-report` blocker. The publisher keeps its mutation check.
In Pair A and in the B/final test step, an accepted correction also marks the original invocation as used.
After a heal, discovery cannot adopt the original again.
The correction prompt names the fields that the executor can change and includes the original report.
If the executor is not sure about a change, it counts the change as an implementation fix.
If the original invocation changed no files, the correction sets all three counters to 0 and substantial=false.
If the original invocation changed files and its correction fails, discovery does not replay the correction.
The healer then resets the stale pair, and the pair reviews the changed candidate again.
The same applies to a changed late-pair test run whose valid report claims fixes or substantial impact.
It also applies to any test run that changed more than existing documentation files, also during its correction.
The runtime cannot accept such a test run, so discovery does not replay it.
A failed correction of a test run without changed files still replays its own failure. The tests do not run again.

A `repair_execute` report can list `repair.risks` but set `repair.mode=self`.
If every other field is valid, it gets one report-only correction in the same session.
The executor sets pair mode when a listed risk applies, or it removes that risk.
The correction can also change `repair.reason`, summary and description, but not tests, evidence or resolutions.
Without changed files, it sets all three counters to 0 and substantial=false.
With changed files and three zero counters, it counts the changes.

In the B/final test step, discovery adopts a saved test run with such a report, so its successful checks do not run again.
Test invocations list a risk only when their checks expose one, because a listed risk requires pair mode.

A pair executor report can have a value outside its allowed values, for example a `repair.risks` item in words.
A Claude executor gets the schema as text, so its provider does not refuse such a value.
If some choice of allowed values makes the report valid, it gets one report-only correction in the same session.
The correction lists each such field, its value, and the allowed values. The executor chooses the allowed values that apply.

In an array, the executor can also merge or remove items. Only these fields, summary, description, and the counters can change.
With a `repair.risks` problem, `repair.reason` can also change. `repair.mode` can change from self to pair, because listed risks require pair mode.
The correction cannot change pair to self. The counters follow the rules of the repair-mode correction.

A fix step can stop on such a report, for example in an older runtime. The retry then adopts the saved fix run and starts the correction.
The retry adopts only a saved run whose report a correction can save. Another saved report does not replay, so the executor runs again.

All three pairs use the same exit rule. A finding is **significant** when it blocks
publication or has critical/high/medium severity; only low, nonblocking findings
are minor. After significant findings are fixed or verified, the SAME pair performs
fresh independent inspection, even if the executor made no source edits. B/final first complete the inner repair gate below. Findings
and closure proofs survive as mandatory questions after both initial reports finish.
The outer pair repeats until significant findings are gone. There is no fixed OUTER clean-streak
requirement and no return from B to A.

When only minor findings remain, Opus closes them and proceeds to the
next pair, or publication from final, **without repeating the outer pair**. B/final
still require the inner repair gate, including for minor repairs. If the repair
unexpectedly changes contracts, algorithms, workflows, permission boundaries or test
expectations substantially, the same pair inspects that new candidate. Uncertain
impact is substantial; judge semantics, not extensions or line count. Missing,
duplicate, incompatible or unresolved resolutions cannot complete a pair or seal
publication. The publication seal records the actual post-cleanup snapshot and
closure evidence. No accepted assignments means no assessor or executor call.
Only explicitly unrelated low-severity improvements may be deferred in the conclusion;
accepted stage defects must be closed. Older backlog history remains unchanged.

### Inner repair gate for B and final

`focus_pair_repair.py` owns a durable subcycle inside the current pair. Opus/xhigh
implements the accepted assignments, then reports whether the actual patch needs
self-review or an independent Opus/xhigh + Astra/xhigh pair. This choice is in the
fix report, with reasons and risk flags; no extra complexity-model call runs here.
Simple local repairs can use self-review. Contracts, data/storage, security,
concurrency, algorithms, interacting components and uncertainty require a pair.
The runtime also forces pair mode for substantial/disputed repairs. Severity of the
original finding alone does not decide patch risk. A mode can escalate within the
batch, never downgrade.

Review is a separate invocation with inspection-only tools. Self-review resumes the
executor's native session in its original cwd, while `focus_inspect` reads the sealed
view. Pair readers get independent native sessions. An explicit `--new-sessions`
allows a same-role continuation from durable context when history was discarded.
The inner pair uses the same two exchanges and binding Astra/max arbitration.
Both forms inspect the **cumulative repair diff from the pre-fix candidate**, plus
necessary surrounding source; they do not reopen unrelated parts of the solution.

The inner view also contains the evidence that the outer pair of the same phase gets.
In B, this evidence is the coding report, the earlier pair records and `__review__/publication.json`.
In final, the evidence is only `__review__/publication.json`.
Each inner view also has `__review__/gate.json` with the fix, test and audit records of its open gate.
The evidence audit below also uses a view with this evidence.

A repair seal in the earlier records refers to other runtime records by path.
Examples are its fix and test reports, its inner reviews and its evidence audits.
The view copies each such record as `__review__/history-N-record-M.json`, but not frozen view manifests.
Each reference keeps its runtime path and gets the copy name in `exposed`.
A record that changed or disappeared gets `exposed` with the value null.

All evidence copies use indented JSON, so `focus_inspect` can read them page by page.
The inspector shows a line longer than 6,000 characters in numbered parts.
The page header then states that offsets count rows.
A page holds at most 30,000 UTF-8 bytes, so one page fits one tool result.
A clipped page ends at a whole part and names the next offset in its header.
An inner inspector can then compare a journal update with the retained test report.

An earlier runtime froze inner and audit views without this evidence.
On resume, such an inner review or audit gets a new view with the evidence.

Completed reports stay, so a completed negative verdict still counts.
A report under correction and a Codex turn that the runtime can recover also stay.
Kept independent jobs resume their sessions in the old view directory, and they read the new view.
Other jobs start again on the new view.
The review record and the audit approval name the legacy view of kept jobs in `earlier_views`.

Two consecutive clean static passes are required on the exact same candidate.
The first checks closure/completeness; the second checks regressions, side effects
and closure again. Confirmed relevant low findings also interrupt the streak and
return to the executor. Any source, test or expected-output edit resets credit.
Runtime report artifacts do not. Reviewers can request future tests as obligations;
waiting for scheduled tests is not itself a static defect or a circular review gate.

After both passes the same executor runs applicable checks in a separate invocation,
without editing project files or journals: put check results in the JSON report.
Build only affected projects and necessary dependencies;
run relevant tests. A justified `not_needed` outcome requires evidence of why checks
are inapplicable; it cannot skip an accepted diagnostic. A test defect returns to
fixing and two fresh static passes, then tests again. Defects missed by self-review
force pair mode. Infrastructure failure preserves static credit for an unchanged
candidate and uses normal recovery. No expensive outer reviewer runs before this
gate completes. Significant or substantial repairs then repeat the outer pair;
minor-only repairs advance. No accepted assignments means no inner subcycle.

An `infrastructure` report may retain `kind=verification` obstacles in `tests.failures`;
it cannot contain `kind=defect`. Candidate defects require `failed` with concrete defect
findings; successful/deferred reports cannot hide either kind of failure. Infrastructure
is never passing evidence. Keep incomplete verification resolutions deferred. Retry
prompts include saved test results for the unchanged candidate: reuse successful checks
and repeat only failed/incomplete checks and their required prerequisites.

Completed tests from earlier runtimes can contain a historical journal update.
`focus_repair_evidence.py` handles this exception without excluding any path from
candidate snapshots. Existing, regular UTF-8 documentation is eligible for a
separate **Opus/xhigh** inspection of the exact before/after diff through
`focus_inspect`; the inspector cannot edit, build or test. Every changed path must
be classified as a factual record of the completed checks. Requirements, behavior,
instructions, permissions, test oracles, future obligations and uncertain claims
do not qualify, regardless of filename or `minor_edits`. Source edits, new/deleted
files, symlinks, mode changes and HEAD/index changes cannot use this exception.

The sealed test receipt and independent verdict bind the two complete snapshot
hashes. Only this exact evidence delta preserves the two original static passes;
their recorded candidate hashes stay unchanged. Publication includes the actual
post-test journal. A changed or missing audit, later edits or a negative verdict
prevents completion. A test-phase `verified` resolution can confirm an assignment
only when a sealed earlier fix report recorded it as `fixed`; the combined closure
retains both pieces of evidence and does not rewrite the original report.

Retry reuses a matching completed test result instead of repeating its checks.
The runtime validates its original intent, operation, assignments, candidate,
iteration, correction revision, operator messages and exact current checkout.
Older reports require the saved test prompt; a unique matching original can be
found even after recovery overwrites `last`. Healer reports never earn test credit.
No-op recovery retains pending classification; consumed failed/infrastructure
results cannot be replayed as a new test attempt. This is a Profile 8 compatibility
fix, so existing clean static passes are not discarded by a profile migration.

The panel/status shows mode, reason, `0/2`–`2/2`, current action and destination.
The sealed repair evidence includes choices, snapshots, reports, checks, invocation
references and elapsed time. Restart preserves completed peers and exact credit;
operator steering preserves both outer and inner obligations and restarts review.

### Builds and tests

Inspection, discussion, complexity assessment and arbitration never run builds or tests.

Every other role runs only the checks that cover the current changes.
These checks test the new or changed behavior and the credible regression risks of these changes.
In the code role, the current changes are the new and changed behavior of the stage.
In other roles, they are the corrections of the current batch or recovery.
They also include the stage behavior that an assignment names.
In a review run, the supplied review scope counts as the current changes.

After a correction, a role runs again only the checks that the correction can affect.
A full run checks more than the current changes.
Examples are a run of all test projects and a complete run of one test project.
A repeated run of all mutants of a battery after a local correction is also a full run.
The first run of the new checks and mutants of a stage is not a full run.

Only two cases permit a full run:

- Pair B can assign one full run in each stage with `full_suite`.
  If the change type does not strictly require a full run, this exception does not apply.
  The benefit must justify the long wait, and the reason states the change type and the risk.
- The final gate permits one full run after the final pair passes.
  Each stage permits one final gate.
  Its threshold is lower than for a Pair B `full_suite` assignment.

Outside these two cases, no role starts a full run.
Without `full_suite`, the check text of an assignment must not request a full run.
If a check text breaks this rule, the executor runs only the part for the current changes.
The runtime does not check this text, so the role contract states the rule.

Project instructions can require broader runs, but the same limits apply.
The role runs the part of such a check that covers the current changes.
It names the omitted broader check and the reason in its report.
The omitted part is not a failed, incomplete, or skipped check.
The final pair can request the broader run for the final gate.

The runtime records each Pair B or final-gate full run after its test invocation passes or fails.
An infrastructure failure does not count as a run.
After a Pair B run, the runtime rejects each new `full_suite` decision in that stage.
This applies to discussion readers, the arbiter, and inner repair readers.
In the open batch, the runtime sets `full_suite` to false, so later tests run only targeted checks.
The stage transition removes these records.

Existing evidence can be reused when its inputs and environment still match.
A verification-only assignment is permitted even when no source fix is required.
B/final fix invocations never build or test.
All their checks wait for the two-pass inner gate.
A test invocation cannot use `not_needed` for a `full_suite` assignment.

Report failures and unrun checks honestly.
The absence of a full run alone is not a defect.

### Final gate

Each initial report of the final pair contains `final_gate` with `full_run` and `reason`.
If the changes justify a full run before publication, an inspector sets `full_run` to true.
These reasons can justify it: shared or cross-component effects, build or test configuration, or a project rule.
Specific risks that targeted checks do not cover can also justify it.
Local changes that targeted checks cover do not justify it.
A report saved before this field requests no gate.

The `full_runs` field of the assignment lists the passed full runs of the stage.
Each entry has the phase and tells whether the run tested this candidate.
These entries are runtime records, not review opinions.
After a passed run on an earlier candidate, an inspector evaluates only the later changes.
After the final gate of the stage, the `available` field is false.
The runtime rejects a current final report without `final_gate` and requests a report correction.

The runtime starts the gate when the final pair passes and an initial report requests it.
It skips the gate when the stage has no publication paths.
It also skips the gate when a passed full run tested the exact candidate.
After an earlier final gate in the stage, it skips the gate too.

The gate is a repair batch without a repair.
It starts at the test step of the inner repair gate, without a fix invocation or static passes.
The Opus/xhigh executor runs the requested checks one time.
It must not edit files.

Retained results, the evidence audit, and infrastructure recovery work as in other test invocations.
If the run passes, the runtime seals publication.
The seal names the final-pair conclusion and the requests.
Its `cleanup_without_rereview` value comes from that conclusion, because the gate makes no correction.

If the run finds a defect, the normal repair loop starts in pair mode.
The retest after that repair runs only targeted checks.
Then a new final pair inspects the corrected candidate.
The stage has no second final gate, so targeted checks close this repair.
The status no longer shows the final pair as complete.

The gate request does not move to a later pair.
This rule also applies after a restart of the reviews.

### Passing context without priming the final pair

Between early phases, pass compact **public engineering records**: decisions,
assumptions, verified facts, failed/unrun checks and open obligations, with references
to original reports. Do not request or copy hidden chain-of-thought. No separate
summarizer is required. The implementation summary and check list have an on-demand
full account; within a pair both reviewers receive complete structured public
reports. Original evidence is retained, not overwritten by summaries of summaries.
Agent opinions remain opinions, not new project requirements.

Final initial invocations use fresh sessions and omit prior agent reports, consensus,
fixer handoffs and arbitration. Explicit operator requirements and current project
source remain available. The project brief is also available to the final initial
inspections and to the final arbiter. It is operator text about the project, not an
earlier review opinion, so it is a neutral input. In project mode, the final initial
inspections also get the instruction list of their frozen view. It names current source files, so it is also a neutral input.

On a repeated final pass, carried findings are disclosed only **after both** initial
reports complete. The final arbiter receives only these inputs:

- that pair's reports
- relevant candidate source
- the final closure evidence
- the project brief
- in project mode, the instruction list of its frozen view

Both providers use the bounded `focus_inspect` search/read/list/diff interface over a checksummed source view.
Claude disables built-in tools and inherited MCP servers, and uses only `mcp__focus__inspect`.
Codex disables shell/execution, delegation, memory, hooks, plugins, apps, direct image reads and inherited MCP servers.
Its isolated Code Mode host stays enabled: some model catalogs require it even for dynamic `focus_inspect` calls.
Host availability does not enable shell tools.

The adapter pins these features and the read-only sandbox at process startup and at new or resumed thread configuration.
Each turn also uses the read-only sandbox.
Any command or file-change approval request fails closed, also for built-in patch calls through Code Mode.
Parent traversal, runtime histories and VCS internals are unavailable through this interface.
The interface does not follow symbolic links.

Existing source documentation can contain historical commentary.
The interface gives independence from earlier runtime conversations. It does not claim semantic redaction of all source.
The runtime widens no user permission or configuration.
It checks model and effort on every launch, with no silent substitute for an unavailable model or effort.

The `search` operation finds a literal, case-sensitive text in one file or in a directory of the view.
The path `.` is the whole view. The pattern has 1 to 200 characters on one line.
Each result row is `path:line (row N): text`. N is the `read` offset of the part with the match.
The text is a window of at most 400 characters around the first match in the line.

One call shows at most 200 matches. Results page by matches and stop at the page limit of 30,000 bytes.
The header counts the rows of the page and names the next offset.
A search skips binary files and link entries.

For `read`, `list` and `diff`, the value of `pattern` is null.
A resumed Codex thread keeps its old tool, so the view also accepts the earlier form without `pattern`.
The role contract of a pair reader tells it to search first and then read only the necessary lines.
Other read-only roles keep the tool without search.

### Durable artifacts and recovery

`pair_review` stores the candidate, phase, independent participants, discussion
version, decisions, executor obligations, the candidate-bound complexity assessment,
selected executor role/effort and per-job native sessions. Its `repair` object stores
the inner gate, pre-fix view, cumulative candidate, risk choice, clean credit, peer
reports, test obligations and execution records. The repair seal is linked from
the pair conclusion and publication seal. `pair_completed` retains
the sealed conclusion for each completed stage. Reports are
checksummed under `.work/cycle/invocations/<id>/`; frozen inputs, compact handoffs
and final seals live under `.work/cycle/pair-reviews/<iteration>/<pass-id>/`.
Source bytes are held in `source.zip` beside the view manifest; logical paths, hashes,
diffs and `focus_inspect` calls stay unchanged. The provider's `source` cwd stays empty.
This keeps runtime copies out of recursive source/project discovery in the consumer.
Before work begins, the lease-owning runtime archives legacy loose views, verifies every
file against the original manifest, persists an archive receipt, then removes only the
redundant verified copies. Manifests, source bytes, candidate hashes and review credit
are preserved. Interrupted retirement resumes from the verified archive; unknown or
changed files, symlinks and unsealed loose views block without discarding work.
Status/inspection commands never perform this maintenance.

If a saved infrastructure test predates successful archive maintenance, the runtime may
retry outstanding checks once using the retained evidence and two static passes. It does
not mark the old failure passed, change project tests or launch another implementation.
A fresh failure, or a failure recorded after that maintenance, uses normal recovery.
No profile migration or consumer-specific test exclusion is required.
A completed peer survives failure, quota wait or restart of its partner when the
candidate and assignment match. Invalid report format or incomplete dispositions
get up to two corrections from the same author; sealed peer reports are retained
and corrections earn no extra pass. Rejected versions remain available by hash. `--retry` also advances a saved participant's quota
wait after an account change. After a completed participant report says it could
not finish, the next attempt preserves that response and the native session but
uses a new invocation marker. It reruns inspection instead of recovering the same
completed refusal forever. Legacy failures are retired only after Codex confirms
the completed turn; an older response file cannot invalidate a newer active turn.
Completed peer results are retained. A changed snapshot never earns credit.

Each child process has its own durable ProcessKit address. Stop and crash cleanup
cover both; the writer barrier waits for both exits. Plain operator text during a
pair addresses **both** participants: stop current readers, save the shared instruction,
invalidate endorsements and restart at A. Instructions to an executor also invalidate
prior review credit. The panel displays both participant states, exchange count,
findings, arbitration and clean streaks independently of log scrolling.

Historical serial report correction remains available for retained artifacts. It
never turns malformed or incomplete work into extra review credit. New paired
inspectors write no project files, so recording review evidence no longer causes
an `unreported-fix` failure. Implementation and executor reports still account for
actual source edits; source/index/HEAD guards and publication scope remain enforced.

## Publication, CI and interruptions

Each outer pair receives `__review__/publication.json` through its frozen inspector.
Each inner repair review also receives this file.
This runtime manifest lists the planned paths, task identity, candidate, and protected files.
In an inner review, the manifest lists all planned paths, not only the repair paths.
It does not claim that reviews, publication, or CI passed.

The final pair receives this factual manifest without earlier review reports.
Executors receive the same publication fields in their assignment context.
Publication verification therefore has a runtime input before executor dispatch.

The first accepted code report can replace a coordinator's provisional task label.
Later reports cannot change that stage identity.
An explicit operator selection pins its own identity.

At a stage transition, the runtime records the published stage in `previous_stage`.
The record has the iteration, the task label, and the published commits.
Only a label from a code report or an operator selection names that stage.

If the record has a task label, the coordinator and the code role receive it with a rule.
They do not repeat published work or its reviews, even if the plan still shows the stage as unfinished.
They select the stage again only for plan work that the published commits do not contain.
A coordinator report that names this stage cannot set the label, and the runtime prints a note.
A code report can name the stage, because only the code role can continue its unfinished work.
A code report that already continues the stage keeps the label, and no note follows.

The coordinator names the stage that this iteration implements.
If this iteration continues the published stage, the coordinator uses null, and the code report names it.
Its report recovery route applies only when the context has `coding_recovery`.
That field means that coding of this iteration started without an accepted report.

If `previous_stage` has a label, the panel title shows the iteration and that stage.
This title stays until a report names the current stage.
An example is `Задача 48 · после S2-15g1`.

The record names only the stage of the previous iteration.
A state that an older runtime advanced gets the record from the archived iteration.
If that state has a coordinator label of the published stage, the runtime removes the label.

### Exclude concurrent work before publication

Use an exact selection when other agents changed files during the current stage.
The runtime cannot infer file ownership from prose or directory names.
Stop concurrent writers before preparing the selection.
Keep unrelated work in place.
Select whole files. Separate mixed ownership within one file before using this command.

Create a UTF-8 JSON request outside the project, or in its ignored `.work` directory:

```json
{
  "schema": "orchestra/focus-publication-selection@1",
  "task": {"id": "stage-id", "title": "Stage title", "plan": "plan/current.md"},
  "paths": ["plan/current.md", "src/changed.cs", "tests/changed.cs"]
}
```

Prepare and inspect the complete plan:

```sh
cc-focus reconcile --publication-scope /tmp/selection.json --plan-out /tmp/selection-plan.json
```

The plan records every excluded change and the exact state and candidate fingerprints.
Preparation does not accept scope changes or start a model.
Use the following command to accept that exact plan:

```sh
cc-focus reconcile --apply-plan /tmp/selection-plan.json
```

Acceptance preserves source files, HEAD, staging, sessions, and archived reports.
Excluded files become protected work at their current contents, including deletions.
The selected list replaces inferred publication paths. It is not added to them.

Changes outside the selection block the cycle.
Existing protected files cannot be adopted by this command.
Before selecting scope, use ordinary reconciliation for any protected-file handover.

The cycle pauses before Pair A and retains findings, resolutions, and recorded evidence.
All required reviews must run on the accepted scope.
Valid evidence for unchanged code can be reused.
Use `cc-focus --retry` when you want processing to continue.

Scope selection requires a development review before publication, with no pending invocation.
Changed HEAD, staging, shared project context, or protected work prevents acceptance.
A changed plan, candidate, or saved state requires a new plan.
This command does not recover an already-started publication or alter review campaigns.

### Commit and CI gates

The publishing model prepares a commit subject in its report's `summary` and
confirms readiness read-only. Only the runtime stages, commits and pushes, without
force or history rewriting. This supersedes older commit/push instructions in
saved publisher conversations; the model, effort and native session are retained.
The main upstream must point to a remote `refs/heads/main`. Verification uses that
remote's single push URL; fetch and push URLs may differ. Publication policy in
`.work/constraints.md` remains applicable. Reviewed content is sealed before
publication and rechecked afterward, together with actual local/remote Git state.
An already completed commit/push is reconciled before another publication call.
Changes made by hooks or recovery require renewed review.

`focus_commit.py` passes the exact reviewed file names through a NUL-delimited
pathspec file with literal matching. It never replaces files with directory
prefixes or glob patterns. `git commit --only` excludes unrelated staged entries;
protected untracked files and unstaged work remain outside the commit. The runtime
checks protected files/index entries and every new commit's paths before push,
including extra files introduced and removed again in intermediate commits.
Merge history is rejected in this serial publication flow. In a project, all
member commits validate before the first push, and the combined scope is checked
again before each remaining member. Push names the approved SHA and pinned push URL,
and disables automatic tag publication and recursive submodule pushes.
The iteration retains previously authorized `publication_paths`: a renewed review
can restore a published file's original bytes without making that file foreign
to the stage. Legacy state derives these paths only from an already-confirmed
published commit, never from an unconfirmed local commit or a failed push report.

Git commands and hooks use the existing process containment, heartbeat and stop
handling. Scope manifests and command logs live under `.work/cycle/publication/`,
or `.work/cycle/repositories/<member>/publication/` in a project. Prepared subjects
are sealed in `publication_prepared`; an interrupted Git operation resumes without
another model preparation when the reviewed snapshot is unchanged. Existing safe
publication artifacts remain reconcilable; completed pushes are never repeated.
A protected-index failure after HEAD moved can mean extra protected files were
committed, even when `git diff --cached` is empty. Inspect the saved scope and Git
history. `--retry` does not authorize those files or undo a push; an already
published out-of-scope commit needs an explicit operator decision.

Remote-main queries use at most three 60-second `git ls-remote` attempts, with a
two-second delay between transient network failures/timeouts. Progress names the
remote check instead of leaving the completed coordinator shown as active. Git
terminal prompts and Git Credential Manager interaction are disabled for this
read-only subprocess; existing credential helpers remain available. Provider
commands and persistent Git settings are unchanged.

Authentication, access and other non-transient failures end the Git query immediately. An
exhausted timeout is `remote-query-timeout`, not a missing Git executable; other
remote command failures are `remote-query-failed`. Both receive the normal
Astra/xhigh recovery attempt before an operator-visible stop.
At the transition after a completed-stage pause, they stop for the operator at once.
An unchanged checkout
retains its phase, review seal and sessions; implementation repairs require review.
Unconfirmed
remote state never counts as publication or green CI, including after a push.

Restore connectivity/credentials in the environment that launches `cc-focus` and
verify access to the configured push URL. Exit a parked terminal with `/exit`, sync
the updated runtime from Orchestra, then run `cc-focus --retry` in the consuming project. Legacy
`command-unavailable` Git timeouts use the same retry command; do not delete state
or repeat completed reviews. A push that already succeeded is reconciled before
another publisher invocation.

Run authentication diagnostics as the same OS user that launches `cc-focus`.
A successful `gh auth status` does not prove that Git can authenticate to an HTTPS
push URL: the account can be logged in with `git_protocol: ssh` while an existing
remote still uses HTTPS and has no credential helper. Verify the actual push URL
with `git ls-remote --refs <push-url> refs/heads/main`. To use the existing GitHub CLI
login for HTTPS, the operator can run
`gh auth setup-git --hostname github.com` as that user, then repeat the query.
This configures Git's credential helper ([GitHub CLI documentation](https://cli.github.com/manual/gh_auth_setup-git));
it does not require a new login. The runtime must not change credentials, rewrite
remote URLs or select another OS user's authentication automatically.

If published GitHub workflow files or local required checks are configured, the
next cycle starts only after successful CI for the exact published SHA. Without
configured CI, it may start after publication is verified. A pending, failed or
unconfirmed CI result does not permit another stage.
The runtime checks all observed workflows/checks/statuses and
enforces the required check set from `.work/constraints.md`. Configure that set to
make missing individual checks a strict barrier. Without an explicit set, the
observed green set must be stable across two polls; a missing run is not success.
Polling is every 30 seconds with a 30-minute deadline and uses no model tokens.
Known external CI files also block automatic progression unless their results are
covered by explicit required GitHub checks. Non-GitHub configured CI requires
operator resolution; it is not silently skipped. Unpublished CI drafts do not
enable the remote gate.

A parallel member can also pass with a later commit of remote main, as "Parallel member repositories" describes.

State, pending invocation intent, final reports and handoffs live under
`.work/cycle/`. State writes use flush, atomic replacement and a checksum; directory
flush is also used on POSIX. Power-loss guarantees still depend on filesystem and
hardware durability. Corrupt state is preserved and fails closed. Do not commit
runtime artifacts. A crash does not discard files or assume that a lost response
means no side effects occurred. Git publication is reconciled; incomplete model
turns resume the same role, and only validated final reports advance the phase.
The parser accepts one final JSON object on its own line after a prose preamble,
optionally enclosed in a single plain or `json` Markdown fence. It preserves the
original response in the artifact and coding handoff. It does not repair JSON or
choose among multiple objects: earlier braces/brackets, nested reports, trailing
commentary, duplicate fields and incomplete fences are rejected. Schema, role,
fix-count, evidence and checkout validation still apply. A harmless preamble does
not start a healer or repeat completed implementation.
The 1200-character summary budget limits coordinator context and the printed
result preview, not report validity. Longer summaries are marked and shortened in
those projections only; the saved report retains the full summary, description,
fix counts and evidence. Malformed fields, inconsistent fix counts, incomplete
reviews and reported blockers still stop progression.
If an older runtime stopped with `summary exceeds 1200 characters`, update the
installed runtime with `cc-sync` from the Orchestra checkout, then run
`cc-focus --retry` in the consuming project. This retries the saved phase with its
existing sessions and work; it does not retroactively credit the rejected pass or
skip required reviews. Do not delete `.work/cycle/` or use coding-report recovery
for a review-phase failure.
Both providers can have a saved identifier before native history is materialized.
If native resume specifically reports that no conversation exists, the runtime records
the missing mapping and starts a clean continuation of the same phase from durable
handoffs and reports. It does not treat authentication or policy errors this way.

Claude's CLI can emit an API error as an `assistant` event with model `<synthetic>` and `is_api_error_message=true`.
The transport classifies this event before it checks the required answer model.
An `oauth_org_not_allowed` error stops as `claude-access-denied`.
The provider reports disabled subscription access for the organization.
The recovery agent cannot restore subscription authority, so this refusal bypasses recovery.

Structured safeguard refusals, quota refusals, and transient server failures have separate paths, described below.
Other marked synthetic errors become `claude-api-error` with the original error detail.
They receive the normal Astra/xhigh recovery attempt.
These errors do not replace the native session or earn review credit.
An answer from another model still fails as `model-rerouted`.

A Claude response with `stop_reason=refusal` stops the cycle as `claude-refusal`.
The transport first checks the session and the response source.
It accepts a marked synthetic API error or an answer from the required model.

It also checks `stream_event` records with `message_delta.stop_reason=refusal`.
The matching message start supplies the model and message ID.
The assistant frame can supply the request ID before the terminal delta arrives.
The runtime rejects a refusal from another session, model, or child agent.
It stops before accepting a later successful CLI result.

The error retains the public explanation, category, and supplied request and message identifiers.
An error label or refusal text quoted in a normal answer does not activate this path.

The runtime does not start the recovery agent for this refusal.
It retries only a refused request with earlier history, one time in a new conversation, as described below.
It preserves partial work and grants no review credit.
It does not change models, credentials, or permissions to clear the refusal.
The operator must inspect the request and the provider guidance before continuation.
Installing an update does not clear an existing blocker.

For `reasoning_extraction`, check instructions and tool schemas for requests to disclose private reasoning.
Ask for short explanations and observable evidence instead.
The category alone does not identify the instruction that triggered the refusal.
Do not claim that provider approval is required unless the provider requires it.
If a permitted request still appears to be misclassified, contact support with the recorded identifiers.
See the [provider's refusal guidance](https://platform.claude.com/docs/en/build-with-claude/refusals-and-fallback#keep-reasoning-in-thinking-blocks).

The code role receives implementation instructions without the paired reviewers' tool restrictions or repair schedules.
It still performs required implementation checks and returns its report before the runtime starts the reviews.
The user message includes this contract.
Models, efforts, permissions, report fields, and required review gates do not change.

Claude writing roles retain the standard Claude Code system prompt.
The runtime adds the role contract with `--append-system-prompt`.
Its named `cycle_worker` agent has an empty prompt and no memory field.
This prevents a configured default agent from replacing the selected role.
This mode requires Claude Code 2.1.281 or later.

Read-only reviewers retain their custom prompt and restricted tools.
The runtime does not change provider safeguards or accept incomplete output.
See the [Claude Code prompt guide](https://code.claude.com/docs/en/cli-reference#system-prompt-flags).
The [agent reference](https://code.claude.com/docs/en/sub-agents#supported-frontmatter-fields) explains empty prompts.

The runtime does not add the writing contract to Claude instructions.
Claude writing roles load the same user policy from the user settings file.
Claude inspectors write findings, not instructions or knowledge text.
Codex roles still receive the writing contract.

In one project, every Claude coding run with that contract ended with a `reasoning_extraction` refusal.
This change removes a suspected trigger. It does not prove the cause of a refusal.

An existing provider conversation can retain earlier instructions.
After correcting the instructions, the operator can use `cc-focus --new-sessions --retry` to start with the corrected context.
This command preserves project work and runtime phase progress.
It does not prove that the provider accepts the corrected request.
Do not use new sessions to evade a safeguard or repeat an unchanged refused request.

Each new stage starts new role conversations.
At the stage transition, the runtime saves the session IDs in `.work/cycle/sessions/` and clears them.
The plan, the handoffs, and the project files carry the context into the next stage.
Thus a conversation never resends the history of earlier stages.
A state that an older runtime advanced keeps its role sessions until the next stage transition.

In one project, two refusal episodes started in the first call of the code role in a new stage.
Each call resumed a conversation with more than 650,000 tokens from earlier stages.
Later, the provider refused a new code conversation after 117 messages, at about 533,000 tokens.

A refused request can have earlier history: a resumed conversation, or a completed tool exchange in the same conversation.
After such a refusal, the runtime continues the same invocation one time in a new conversation.
The new request has no earlier history, so it differs from the refused request.
The role instructions, the model, the effort, the phase, and the current work stay the same.
The runtime adds only the note about the new conversation and the recovery note for an earlier attempt.
It keeps the launch record and the prompt of the refused attempt under the ID of that attempt.

The runtime does not continue in a new conversation in these cases:

- The refused request had no earlier history.
- The invocation is a report-only correction.
- The invocation is a self-review in the executor's conversation.
- Operator messages went to the refused conversation.
- The runtime already continued this invocation in a new conversation.

In these cases, the invocation stops for the operator.
The state records each restart in `refusal_restarts`.
The pending invocation or the pair reader job keeps `refusal_restart`.

After a restart in a serial review role, the runtime resets the clean passes of that role.
If files changed during the invocation, the review counts as substantial.

At each refusal stop, the pending invocation records the refused conversation in `refused_session`.
The state also keeps it in `refused_sessions` until the next stage transition.
A pause for operator messages, a correction, or a retry can keep the role session.
A later resume of that conversation stops before a provider starts.

A refused conversation keeps its refused history.
The provider sees that history again on each resumed request.
For a `claude-refusal` blocker, the runtime looks for refused conversations that a plain retry would resume.
It checks role sessions in the runtime state and unfinished pair reader jobs.
If it finds one, a plain `--retry` or `/resume` stops before the shared lease and starts no model.

The provider bills a repeated refusal of this kind.
If you know the cause, remove it from the instructions. Then run `cc-focus --new-sessions --retry`.
After a refusal with earlier history and without an automatic restart, `--new-sessions --retry` makes one new attempt.
After a refusal of the first request of a new conversation, do not repeat the unchanged request.
After a refusal of the conversation that the runtime started automatically, do not repeat the unchanged request.

If no instruction change explains the refusal, report the request ID to provider support.
If the provider also refuses that new attempt, stop and wait for support.

Use this command from the project root to inspect an existing invocation:

```sh
cc-focus diagnose --invocation 301cb5ae1d7945ccab8ba124fb13720d
```

Replace the example ID with the ID from your log.
The command reads existing artifacts without acquiring runtime ownership, changing state, or starting a provider.
It works while the cycle is blocked or active.
The report lists the Claude version, model, session, loaded tool names, and refusal identifiers.
It also lists recent tool names and whether their results arrived.
Tool arguments, message bodies, settings values, stderr, and private content blocks are excluded from this metadata report.

The report includes observed message counts and input-token sizes when the provider supplies all input counters.
Input size includes new tokens and both cache counters.
The report retains the first, last, and largest observed sizes.
Each refusal includes its own input size when known.
Missing counters remain unknown.
These measurements do not identify the cause of a refusal.

The last 128 message records show input sizes, output counts, response block types, and stop reasons.
Recent tool records include input and result sizes and hashes, without their contents.
Text uses UTF-8 bytes, while structured payloads use sorted-key JSON.
New invocations also record the requested model, effort, session reuse, and instruction hashes.
This launch record describes the adapter request, not the provider's hidden configuration.

To compare loaded instructions, provide the matching Claude native session log:

```sh
cc-focus diagnose --invocation INVOCATION_ID --native-log /path/to/SESSION_ID.jsonl
```

The reader requires matching session and project identities.
It reads known instruction attachments only and excludes child sessions.
It reports instruction and tool-schema hashes, sizes, and locations of selected terms.
These term matches can be prohibitions or unrelated references.
They do not establish a request for private content or identify a refusal cause.
The reader excludes assistant content and never sends data to a provider.

New Claude invocations save the same metadata in `claude-diagnostics.json` beside the protocol log.
The runtime keeps at most 20 refusal records and 12 recent tool records.
Missing metadata remains unknown. The report does not identify the offending instruction or prove that a refusal was incorrect.
No diagnostic result gives review credit or clears a blocker.

The launch record also lists instruction files that Claude Code can load for the role.
The candidates are the user `CLAUDE.md`, and `CLAUDE.md`, `CLAUDE.local.md` and `.claude/CLAUDE.md` in the project root and its parents.
Each entry has a scope, path, size and SHA-256 hash, without file text.
The runtime records these hashes before the Claude process starts.
The completion record hashes the same candidates again after the process stops.
A difference shows that a file changed during the invocation.
In older records, the runtime hashed the files only at completion. The diagnostic reports their timing as unknown.
A candidate file is not proof that Claude loaded it.
Paired inspectors start without user or project settings, so their list is empty.
The report also keeps up to 32 Claude Code events: compaction boundaries, refusal notices and refusals without a fallback model.

Each Claude attempt also writes `usage-<attempt>.json` into its invocation directory.
The record names the iteration, role, run store, session, attempt and Claude Code version.
It counts model turns, input tokens, cache reads, cache writes by duration, output tokens and the peak context.
It also lists the compactions with their `pre_tokens` and `post_tokens`.
The stream does not show the usage of a compaction call, so its `pre_tokens` estimate that read.
The result totals of a resumed session include earlier invocations, so the record does not use them.

`cc-focus status` shows the totals of the current iteration, also for each role.
`cc-focus diagnose --invocation ID` shows the usage of each attempt.
It sets `window_exceeded_without_compaction` when the peak passes the window by more than 50,000 tokens without a compaction.
This can show a newer Claude Code that ignores the window.
These values are measurements only. The runtime does not stop or change a role because of them.

To compare refusals across invocations, run this command from the project root:

```sh
cc-focus diagnose --refusals
```

The command reads up to 500 recent Claude attempts without a lease, state writes or a provider call.
It also works when the state file is damaged.
It lists each refusal with its session ID, message number, input size, category and request ID.
It groups invocations by native conversation and names the roles that still use a refused conversation.
For each conversation, it counts invocations and attempts separately.
These roles include unfinished paired readers.
A retry can append another Claude process to the log of the same invocation.
The runtime writes an attempt record into the log before each Claude process starts.
The report splits the log at these records and shows each process as a separate attempt.
In older logs without these records, an event with a new session starts a new attempt.
Only the attempt that owns the saved launch record has its launch metadata.
An older launch record without an attempt ID can own only an attempt before the first attempt record.
The prompt file belongs to the last attempt.
The report lists an attempt without a known start time, but does not use it for the onset part.

The onset part compares the first refusal with an earlier completed Claude invocation.
A completed invocation has a terminal result with subtype `success` and `is_error=false`, and no refusal.
An error result, a refusal, or a missing result does not qualify.
As in the transport, a result is not terminal while native tasks or queued turns remain.
A later turn without its own result also makes the attempt incomplete.
The report names this reference `last_completed_before`. It does not prove that the runtime accepted the report.
The comparison prefers the same role. Without a qualifying invocation, the reference is `null`.
It shows changed Claude Code versions, models, roles and role-contract hashes.
It also shows changed instruction-file hashes and the first lines of added or removed instruction paragraphs.
It names only paragraphs of the current runtime instructions.
A prompt also contains reports, plans and handoffs. The report counts these other paragraphs but does not show them.
The `not_compared` list names the values that are unknown for one of the two attempts.
For older records, the instruction-file hashes come from completion.
Their changes appear under `instruction_files_timing_unknown`, and `not_compared` names `instruction_files`.
Paired inspectors load no instruction files. A comparison with them lists `instruction_files` under `not_compared`.
It also names the native log files that `--native-log` can read.
The path uses the process directory of the attempt. Most paired readers run in a frozen view directory.
The file name of a native log is its session ID. The diagnostic selects the attempt with that session.

The retry part lists refused conversations that a plain `--retry` would resend.
The protocol log decides which attempt of an invocation is the last one.
The saved diagnostics count only when their launch record names that attempt.
Logs without attempt marks combine both sources for the same session.
Without a protocol log, the saved file is the only evidence.
So a failed diagnostic write cannot hide a later refusal.

For each refused conversation, the retry part also tells if the current role contract differs from the refused one.
`cc-focus correct`, `cc-focus recover`, `cc-focus reconcile --apply-plan` and `cc-focus brief apply` keep role sessions.
If a refused conversation belongs to a role session, the runtime rejects these commands.

These commands drop paired reader jobs. A new repair batch drops the `repair_execute` session.
The next outer pair drops the Pair A executor sessions. Their refusals do not stop these commands.
After a rejection, run `cc-focus --new-sessions` first. It keeps work, phase and blocker, and starts no model while the blocker remains.

The report excludes message bodies, tool input and output, thinking content and runtime JSON context.
A correlation in time does not prove the cause of a refusal.
If a changed request is still refused, contact provider support with the recorded request IDs.

For public messages and command results, add `--public-output` to the diagnostic command.
This view uses the terminal output filter and its existing size limits.
It omits structured private content blocks and raw protocol envelopes.

Public output can contain project data or values printed by commands. Inspect it before sharing it.
Recovery instructions use this view instead of asking agents to read raw provider transcripts.
Read-only reviewers retain their assigned inspection tools and cannot use this command to read excluded history.

A structured Claude `server_error` or `overloaded_error` is a server error. An
API-error result with HTTP status 500, 502, 503, 504 or 529 is also a server error.
For these errors, the outer runtime retries the same invocation and native
conversation. It retries up to three times in a row, after 15, 30 and 60 seconds.
Unknown errors, authentication failures and error text merely quoted by the model
do not trigger this path. The next Claude turn for an operator message in the same
process starts with three new retries.

Each retry requires confirmed cleanup of the previous process. This also covers a
server error mid-response: existing work stays in place, and the continuation
finishes the same stage. The provider and healer do not launch recursive calls.

Exhausted retries stop the run for the operator. The runtime starts no recovery
agent, because a recovery agent cannot retry a provider. The saved blocker has the
`escalation_reason` value `provider-unavailable`. For a server error of the healer
itself, the value is `healer-failed`. There is no infinite polling loop.

The blocker message tells the operator to wait for the provider and then run
`cc-focus --retry`. A review run names its own retry command. After its retries,
a pair participant gets the same instructions in a text that names its role.

A Codex turn that fails with a server error uses the same path. Its blocker code
is `codex-transient`. These `codexErrorInfo` values are server errors:

- `serverOverloaded`, with the text "Selected model is at capacity"
- `internalServerError`
- an HTTP connection or stream error with status 500, 502, 503, 504 or 529

Other turn errors stay `codex-failed` and use the usual blocker handling. Examples
are `usageLimitExceeded`, `contextWindowExceeded` and `badRequest`.

A retry starts a new turn in the same Codex thread. If the failed turn has a model
item or a tool call, the attempt counts as started work. The input message of the
turn is not a model item.

A pair reader on Codex uses the retries of its pair job. It gets at most three
retries in a row, after 15, 30 and 60 seconds. A report correction of a pair
participant starts with three new retries.

The healer also runs on Codex. A server error of the healer waits for the same
delays. If the healer uses all its retries, the run stops with `healer-failed`
for the operator.

For a sequential role other than the healer, the saved deadline and retry budget
survive stop/restart, including `--retry`. For an unfinished pair job, `--retry`
starts a new budget and retries at once. `--retry` removes a waiting healer
together with its blocker and its retry budget.

Already-blocked runs keep their
saved state and require `/resume` or `--retry`; installing an update does not
automatically resume them.

The panel shows **ОЖИДАНИЕ ПОВТОРА**, the attempt number and countdown;
`cc-focus status` exposes `transient_wait`. Stop, PAUSE, lease checks and message
delivery checks remain active during the wait. The publication window is an
exception: Stop and PAUSE take effect after it ends. Pending delivery requires an
operator decision before another provider attempt. The runtime checks protected
files, HEAD and staging before scheduling and before retrying.

An interrupted review must complete a full pass again; its previous clean streak
is reset unless the failure preceded all work and the entry snapshot is unchanged.
No failure earns review credit. A report-only correction remains read-only across
retries.

For an access refusal, first check the active login and subscription/payment status
in the same machine/user environment as cc-focus. The runtime retains the actual
provider detail; the word "organization" alone does not identify a company-managed
account or establish its billing state. For managed access, ask the administrator
to restore authorization. For a personal subscription that still fails after these
checks, contact Anthropic support with the error code and request ID. The
[official error reference](https://code.claude.com/docs/en/errors#your-organization-has-disabled-claude-subscription-access)
documents a server-side organization setting for this error; local flags cannot
override that setting. Account type and current subscription status still require
inspection of the actual account rather than inference from the error label.
The runtime never switches billing credentials, accounts, models or permissions
to work around the refusal. After access is restored, use `/resume` or `--retry`.
An old `model-rerouted` blocker also resumes this way after cc-sync and a restart;
the healer's report is not a completed review and must not be used for recovery credit.

A structured Claude quota refusal with a valid `resetsAt` deadline is a runtime
wait. A matching-session `rate_limit_event` with status `rejected` must be followed
by a synthetic `rate_limit` error or an HTTP 429 API-error result. Warnings,
successful results and reset times mentioned only in text do not trigger this path.
The runtime confirms provider cleanup, saves the deadline with the pending
invocation and waits without starting Astra or another provider. The panel shows
the UTC retry time and countdown; `cc-focus status` exposes `quota_wait`.
At reset plus five seconds it retries the same phase, invocation and native
conversation. Every refusal imposes at least a 60-second delay, including stale
reset times. A new refusal schedules another wait; the timestamp alone never
proves that the provider admitted the request.

The runtime also records the login of the refused launch, as a hash of its account and organization IDs.
The hash keeps no address.

During the wait, the runtime reads the current Claude login at most every 10 seconds.
After a login change, it retries the same invocation at once, like an explicit `--retry`, also for a pair participant that waits.
A wait from before this change has no login, and an API key in the environment leaves the login unknown.
In these cases, the wait keeps its deadline until an explicit retry. The panel shows which case applies.

Stop, emergency stop, PAUSE and uncertain-message checks remain active while
waiting. A plain restart retains the deadline. After changing the Claude login or
otherwise restoring quota, exit the waiting process and run `cc-focus --retry` to
attempt the same invocation immediately with the current login. `/resume` from a
stopped quota wait has the same effect. This explicit retry advances only the local
retry deadline; it preserves the refusal evidence, invocation and conversation,
checks ownership and HEAD normally, and cannot bypass uncertain message delivery.
A fresh refusal schedules a new wait rather than polling. No credentials, billing
settings or models are changed. Corrections that replace an invocation
also retire its wait. Admission refusal before any model work on an unchanged
checkout preserves earlier clean passes and grants no new credit. Ownership and
HEAD are checked again before starting the retry. Work already
started or checkout drift uses the normal interrupted-review rules. Missing or
invalid reset data retains the ordinary provider-error recovery path. Existing
blocked runs need operator continuation after cc-sync and runtime restart; updating
the installation does not resume them or change an already-running process.

A pair participant can also wait for quota while its peer has finished.
If no participant runs, a stop request takes effect at once.
A safe stop, such as `/pause` or `/exit`, saves the pause.
An emergency stop, such as `/stop` or Ctrl+C, interrupts the run.
The completed peer report and the saved deadline stay in the state.
`/resume` and `cc-focus --retry` then retry that participant at once.

On recoverable blockers, the runtime starts the dedicated Astra/xhigh `heal` role,
whose persisted conversation is separate from coding and review. It receives the
original diagnosis and invocation artifacts. This includes technical Git/provider
failures and a coding/review report that asks for human intervention: such a report
is a claim for the healer to check, not automatic proof that human action is needed.
The healer checks existing authorization, makes routine engineering decisions and
implements/verifies necessary prerequisites within the current authorized task,
including its listed member repositories. Product authentication/authorization
code is distinct from the agent's own execution permissions and account access.
Protected existing files and project boundaries remain enforced.

One recovery invocation can investigate and try several safe repairs. It may stop
for the operator only after it cannot resolve the problem or establishes an actual
human prerequisite (such as payment, interactive login, missing secrets or consent).
Its evidence must identify the attempts, their results and the exact remaining
action, citing a concrete rule/refusal when additional authority is necessary.

Explicit runtime approval/refusal and account-access barriers skip recovery;
unconfirmed provider cleanup or an already-active provider also prevent starting
another agent. Exhausted server-error retries also skip recovery. A failure at
the transition after a completed-stage pause also skips recovery. Operator
stop/pause and uncertain message delivery retain their existing separate
continuation rules.

If recovery cannot resolve it, the cycle exits with code 3 and an operator action;
plain reruns do not spend tokens on the same unresolved blocker. Resolve the cause
and use `--retry`. Recovery may not grant operator approval, widen permissions or
discard work. If Codex itself is unavailable, automatic recovery can also be
unavailable and the problem is reported directly.

A recovery claim must be followed by a successfully completed work step. Another
failure before that boundary stops even if timestamps or error details changed;
coordinator acknowledgement alone does not count as progress.
In a pair phase, an accepted reader report, executor report, repair record or completed pair is that work step.

The saved blocker includes `escalation_reason`, and terminal output distinguishes
a recovery start, healer failure, failed repair verification, repeated blockers,
manual actions and unsafe provider state. Terminal output also names an
unavailable provider. The same output names a stage transition that needs the
operator. It also names a project brief that needs the operator and a saved record that needs a newer runtime or a repair.
It also names a blocker of a parallel member or of the root context, with the reason `operator-context`.
A safe stop at an escalated blocker gives the same output
and exit code as a plain rerun.

Older stopped records are retained as-is;
the operator's `--retry` or `/resume` re-enters the current routing after the cause
has been addressed. Installing an update does not restart another project's cycle.

### Recovering a rejected coding report

`--retry` retries the saved phase after an external blocker is resolved; it does
not mean "skip coding and start review". Older installations could reject a
completed coding report because new implementation was marked substantial but
the number of review fixes was zero. A healer's report-only correction did not
advance the runtime phase, and the coordinator could then reject `code` because
the implementation was already finished. The current parser distinguishes coding
from review classification, and coordination explicitly allows finalizing a lost
coding report without repeating implementation.

For an already blocked run, stop processing and update the installed runtime from
the Orchestra checkout with `cc-sync`. At the consuming repository root, select the
original **coding** invocation's `result.json`; its adjacent `intent.json` must have
`role: "code"`. Do not use a healer or coordinator result. Then run:

```sh
cc-focus recover --review-from .work/cycle/invocations/CODE_INVOCATION_ID/result.json
cc-focus status
cc-focus
```

Replace `CODE_INVOCATION_ID` with that directory's actual identifier. Recovery
requires stopped, already-started coding, a `done` report, matching current files,
HEAD and index, the current iteration/baseline, and unchanged protected work.
It refuses stale, external, incomplete and non-coding results, or a phase that has
already entered review/publication. Clear `.work/PAUSE` yourself before requesting
the transition. No phase transition is inferred from a healer's prose.

Recovery holds the same local lock and shared lease as processing. It archives
the previous state and source hash under `.work/cycle/recoveries/`, retains the
original report and native sessions, resets all review counters, and **exits
paused before Opus**. It starts no model, performs no review, changes no project
source or Git history, and does not push. A separate `cc-focus` resumes the complete
required review sequence: pair A, pair B and the independent final pair; only then may publication occur.
Never edit checksummed state by hand or overwrite files to force a snapshot match.

If recovery observes tests or edits that were not in its own tool transcript,
check the provider's process ancestry and native logs before calling them external
work. A Codex memory-consolidation thread can share the provider PID while its tool
calls are absent from the selected role's app-server events. Disabling ordinary
delegation alone did not prevent this. Update Orchestra with `cc-sync` after exiting
the parked terminal so the next `cc-focus` process loads the fixed runtime.
This does not stop independent Codex processes that are already running.

When later source or plan edits have invalidated the original coding snapshot,
`recover --review-from` must still refuse it, even if its JSON can now be parsed.
Once competing work has stopped, use `cc-focus --retry` to reconcile the preserved
changes and finalize a fresh report for the same stage. All required reviews remain required.
Do not treat a stopped mutation test as proof that its temporary source edits were
restored; reconciliation must inspect the current files and verification evidence.

`.work/PAUSE` is checked at safe phase/pass boundaries, not during provider waits.
Publication and its CI wait form one publication window. The cycle leaves PAUSE
untouched and releases its lease on an orderly stop. Ctrl+C preserves the pending
phase for a subsequent `cc-focus`. `status` is read-only and starts no model.

## Protocol references

The Codex adapter follows the [app-server protocol](https://developers.openai.com/codex/app-server).
The Claude adapter uses [headless structured events](https://code.claude.com/docs/en/headless)
and the documented [model and effort controls](https://code.claude.com/docs/en/model-config).
CI discovery uses [GitHub workflow runs](https://docs.github.com/en/rest/actions/workflow-runs)
plus commit checks and statuses; explicit required check names remain the strict
expected-set contract.
