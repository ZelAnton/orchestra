# cc-focus parallel member repositories: plan

Status: accepted, revision 10.1. Each reviewer gave two consecutive clean passes on revision 10.
Revision 10.1 lets the CI gate read remote main at each red result, not only at a retry. The implementation follows this plan.

## Goal

After the split, other agents change plans and documentation at the same time as cc-focus develops code.
cc-focus must accept their commits on remote main of these repositories without a stop at each stage.
The code repository keeps the current rules: only cc-focus writes it.

This plan extends `plans/FOCUS_PROJECT_SPLIT_PLAN.md`. That plan stays valid.
A parallel member is a member repository with other writers. The docs already use "shared" for root context, so this plan uses "parallel".

## Decisions of the operator

1. Other agents work in their own clones outside the project root, on their own branches.
   Each agent merges its branch into main itself, through a pull request or a fast-forward push.
2. When cc-focus and another agent changed the same file, cc-focus merges the changes without a new review.
   A merge conflict still stops the stage, because Git cannot merge it.
3. In the active plan, cc-focus changes only the status of stages.
   Other agents change future stages and other plans.

## Risks for the operator

- Nobody reviews a merged file. Two changes can merge without a Git conflict and still contradict each other.
- A merge without a Git conflict can still stop the stage. An example is a rename of a stage file by another writer, because the stage change then lands outside the stage paths.
- A conflict can stop a publication after an exclusive member, for example the code repository, was already pushed.
  The project is then partly published until the other writer changes remote main and the retry continues.
- Git treats edits of adjacent lines as a conflict. Other agents should keep away from the stage status lines, for example with an empty line around each status line.
- The published commit of a parallel member contains the commits of other writers. Its CI result can come from their changes.
  After a fix on remote main, a retry accepts green CI at the later commit, if it contains the published commit.
  That later commit can also change or revert the stage work. The status names the changed stage paths.
- A change of the active stage by another agent reaches the cc-focus checkout only at the next stage start.
  A correction with `cc-focus correct` can describe the change for the current stage. The file itself arrives at the next stage.
- Decision 3 is a rule in the prompt, not a runtime check.
- cc-focus cannot tell an edit by another agent in its checkout from its own work. Only separate clones prevent this.
- cc-focus pushes directly to main. Branch protection on a parallel member must allow this push.
- A workflow with `concurrency: cancel-in-progress` on main can cancel the run of the cc-focus commit. A cancelled run counts as a CI failure.
- A review campaign does not queue a completed target again when only other writers changed its paths.
- One publication of a parallel member is one commit. Several unpushed stage commits become one commit with the message of the last commit.

## Problems now

cc-focus expects that only it changes main of each member during a stage, locally and on the remote.
The code shows these stops when another writer pushes to a member:

| Point | Check | Result now |
| --- | --- | --- |
| Publication preparation | `Cycle.prepare_publish`: remote main must be the baseline or a known head | `remote-drift` |
| Push | `push_reviewed`: a push runs whenever remote main differs from HEAD | `publication-git` (non-fast-forward) |
| Push confirmation | `Cycle.reconcile_publish`: remote main must equal HEAD | `publication-unconfirmed` |
| CI wait | `Cycle.assert_publication_current`: remote main must equal the published commit | `ci-head-drift` |
| CI gate | `wait_ci`: CI must be green at the exact published commit | `ci-failed` with no way back |
| Stage boundary after a pause | `check_stage_base`: remote main must equal local main | `stage-base-unpublished` |
| Review admission | `create_run`: remote main must equal local main in every member | `review-baseline` |
| Campaign target without a fix | `ReviewMode.publish`: remote main must equal HEAD in every member | `review-remote` |
| Campaign handover | `hand_back` calls `assert_stage_base` | `stage-base-unpublished` |
| Operator publication recovery | `reconcile --publication` pins live remote heads | refusal |

The normal stage transition without a pause checks only the members that the stage published.
It takes the next baseline from local main, so the remote changes of other writers never reach a stage.

A change in the working tree of a cc-focus checkout is stage work. Thus an edit by another agent in that checkout goes into the stage and its commit.

## Design

### P1. Parallel members in the manifest

- `focus-project.json` version 1 gets an optional key `parallel`: a list of member names.
  Each name must be in `repositories`, and no name can occur twice. Without the key, no member is parallel.
  ```json
  {"version": 1, "repositories": ["Interlink", "Interlink-docs", "Interlink-plans"], "parallel": ["Interlink-docs", "Interlink-plans"]}
  ```
- An older runtime rejects the new key with `project-manifest`. Thus it cannot ignore the parallel rules.
- Each stage records the set in `state["parallel"]` at its start. The stage uses this record, so a manifest change becomes active at the next stage.
- At a stage transition, the publication checks use the set of the finished stage. The sync and the new record use the set of the next stage.
- A review campaign records the set at its start in the same way. The restart of a completed project with `--handoff` also reads the manifest again and records the set.
- `next_stage` reads the manifest again for the set of the next stage, because `reconcile` can accept a manifest change in a stage.
- A member that is no longer parallel gets the exclusive rules at the next stage. Its local main must then equal remote main, as for every exclusive member.
- All rules below apply only to parallel members. An exclusive member keeps every current check.

### P2. The remote rules and the fetch

The base of a parallel member is its baseline head. P4 can move it from B to R.

- **Preparation rule.** Before a push, remote main must contain the base of the member. P4 then integrates when necessary.
  Otherwise, the run stops with `parallel-remote-rewritten`.
  This rule replaces the known-heads check of `prepare_publish`.
- **Confirmation rule.** After a push, remote main must contain local HEAD.
  This rule applies to `reconcile_publish`, `assert_publication_current`, `check_stage_base`, `ReviewMode.publish`, and the remote check of `create_run`.
  `push_reviewed` pushes only when remote main does not contain HEAD.
- The ancestry tests need the remote commits. The fetch uses the push URL and updates `refs/remotes/<remote>/main`.
- The fetch uses the environment of `remote_head`: no terminal prompt, a noninteractive credential helper, the timeout, the retries, and the URL redaction.
- Each Git command of this plan runs through `run_git`, so its hooks stay inside the process control.
  A sync gives `run_git` its own log directory `.work/cycle/sync/` and its own progress text, without the word publication.

### P3. Sync at a stage start

A sync brings remote main of a parallel member into its cc-focus checkout. It runs without a model.

1. The member must have no dirty paths and no staged change. The sync adds `git diff --cached --quiet` to the check of `dirty_paths`.
   Otherwise, stop with `parallel-dirty`. The message names the paths.
2. Fetch remote main. Call the result R, and call local main H.
3. If R equals H, the sync is complete.
4. If H is an ancestor of R, check the entry types of the paths from H to R with `git diff-tree -r --raw -z`.
   Only a regular file, an executable file, a symbolic link, or a deletion is accepted. Otherwise, stop with `parallel-unsupported-path`, and local main does not move.
   Then fast-forward local main to R with `git merge --ff-only`.
   Record the paths that changed from H to R for the campaign requeue rule.
5. Otherwise, stop with `parallel-diverged`. Local main has commits that remote main does not have, or the remote history changed.

Thus a parallel member has no protected paths at a stage start.

The sync runs only at two points:

- **Stage transition.** In `next_stage` on both paths, after the publication checks and before the next baseline.
  The sync covers the parallel members of the finished stage and of the next stage. Thus a member that leaves the set gets a last sync.
  The coordinator then reads the current plan.
- **Run admission.** Inside the lease block of `cc_focus.main`, right after the member leases, with the process control of the run.
  It runs only when the state is at a stage start and has no unfinished invocation:
  - a new state from `fresh_state`
  - a new campaign from `create_run`, before its first pair
  - a development state before coding, also after `hand_back`
  - a restart of a completed project with `--handoff`.

  After the sync, the state takes the entries of each parallel member again, also when local main did not move.
  These are its head, its files, and its index fingerprint in the baseline and in `last_snapshot`.
  The state also drops the protected paths and the protected-index entries of each parallel member, because the sync found the member clean.
  The entries of exclusive members and of the root stay unchanged, so an operator handover with `reconcile` before coding stays valid.
  The iteration does not change. A recorded coordination result is cleared, so the coordinator reads the current plan.

`create_run` and `hand_back` do not sync. They check remote main with the confirmation rule of P2.
Thus a refusal in them changes no checkout. No queue processor works in a member while its main moves.

The sync never runs during a stage, also not at a resume in the middle of a stage.
A run that resumes after coding started keeps the base of its stage start.

### P4. Integration before the push

`commit_reviewed` makes the stage commits on the base B, as now. Call local main H.
Before the first push of the project, each parallel target runs these steps without a push:

1. Fetch remote main R.
   - If H is an ancestor of R or equals R, the member is already pushed. It needs no integration and no push.
   - If R equals B, or if B is an ancestor of R and R is an ancestor of H, no integration is necessary. The second case follows an earlier partial push.
   - If B is not an ancestor of R, the remote history changed. Stop with `parallel-remote-rewritten`.
2. Compute the merged tree with `git merge-tree --write-tree R H`. Git finds the merge base.
   A merge conflict of any kind stops with `parallel-merge-conflict`. This includes a conflict in content, in a rename, or between a change and a deletion.
3. Make the commit C2 with `git commit-tree`. C2 has the merged tree, the parent R, and the message and the author of H.
   If `commit.gpgSign` is true, C2 gets a signature with `-S` and the key of `user.signingKey`. Commit hooks do not run for C2.
4. The paths from R to C2, with `git diff-tree --no-renames`, must be stage paths of the member. Otherwise, stop with `parallel-merge-conflict`.
   The remote paths, from B to R with `git diff-tree -r --raw -z`, must have the entry types that P3 step 4 accepts. Otherwise, stop with `parallel-unsupported-path`.
   Both checks run before the record, so local main does not move.
5. Save the integration record with B, R, H, C2, and the remote paths. The remote paths changed from B to R.
6. Move local main to C2 with `git checkout -B main C2`.
7. Move the base of the member from B to R in the parent project state. The step computes all values first and then saves the state once:
   - The baseline takes the head R and the values of R for the remote paths, also for added and deleted files.
     The values come from `git cat-file --filters` with the file-kind rule of `focus_reconcile.committed_base`.
   - The reviewed snapshot takes the working-tree values of the remote paths.
     A file that both sides changed thus keeps a difference from the baseline and stays a stage path.
   - The fingerprint in `publication_prepared` takes the new reviewed snapshot, so a retry does not start the publisher again.
8. Mark the record complete.

After all integrations, the pushes run as now. A conflict therefore stops the stage before the first push of the project.
A file that both sides edited gets the merged content without a new review. This is decision 2 of the operator.

Before each push of a parallel member, the runtime checks the preparation rule again.
If remote main moved, the runtime runs P4 again on top of C2.
If Git rejects the push, the runtime fetches remote main. If remote main moved, the runtime runs P4 again.
After three integrations in one publication attempt, the run stops with `parallel-remote-busy`.
Another rejection, for example from credentials or branch protection, keeps `publication-git`.

A conflict in such a repeated integration can come after another member was published.
The retry after the remedy then continues the members that are not published yet, as the current publication recovery does.

### P5. Recovery

An open integration record is resolved before any publication check of its member:

- Local main is H: run steps 6 to 8 again.
- Local main is C2, and the base did not move: run steps 7 and 8.
- The base moved: run step 8.
- Step 7 fails, for example on an error of `cat-file`. Restore local main to H with `git checkout -B main H`.
  Then discard the record, and run P4 again from step 1.
  Step 7 saves the state only after all values exist, so the state is unchanged. A needless restore is harmless, because P4 integrates again.
- Local main is another commit: stop with `parallel-integration-state`. The message names H and C2.

After step 8, the current reconcile logic covers the push with the rules of P2.
`reconcile --publication` refuses a parallel target. Its pinned remote heads do not fit parallel writers.

### P6. Context for the roles

The context gets the field `parallel_repositories` with the member names of `state["parallel"]` and the fixed rule `PARALLEL_REPOSITORIES_RULE`:

> The repositories field lists the member repositories with parallel writers.
> Other writers change them at the same time as this stage. Their changes reach this checkout only at a stage start.
>
> In these repositories, change or request only what the stage needs. In the active plan, change only the status of stages.
> Do not revert or rewrite a change of another writer to make a check pass. If such a change stops your work, report a blocker.
>
> This rule has priority over the instruction files of the repositories.

- `ProjectCycle.context` adds the field for the main roles and the pair writers.
- A new pair stores `project_instructions_version: 2`. Each reader of a version-2 pair gets the instruction list and this field from the pair state.
  A version-1 pair keeps its saved prompts and gets no new field.
- The rule is a constant in `tools/cycle_prompts.py`, and the checker scans it.
- A stage without parallel members gives no field.

### P7. Blockers

A recovery agent may not change the work of other writers, so no recovery agent starts for these codes.
They get the new escalation reason `operator-context` with the text: "This blocker needs the operator. A recovery agent may not change the work of other writers or the root context."
A `project-manifest` stop at `next_stage` gets this reason too.

| Code | Remedy in the message |
| --- | --- |
| `parallel-dirty` | The paths are not committed. This checkout belongs to cc-focus. Move the changes to another clone or remove them. Then run the command that the message names. |
| `parallel-diverged` | Only at a sync. Local main has commits that remote main does not have, or the remote history changed. Save the local commits that you need, for example on a branch. Then make local main equal to remote main, and run the command that the message names. |
| `parallel-remote-rewritten` | At a publication or a CI wait. Remote main no longer contains the named commit: the stage base or the published commit. Restore remote main so that it contains this commit. Do not reset local main, because it holds the stage commits. Then run the retry command. |
| `parallel-unsupported-path` | A change of another writer added a submodule or another entry that cc-focus cannot seal. The message names the path. Remove the entry on remote main in another clone. Then run the command that the message names. |
| `parallel-merge-conflict` | The message names the paths. Read the stage change with `git -C <member> diff <base> <H> -- <paths>`. Change remote main in another clone so that it does not conflict. Then run the retry command. |
| `parallel-remote-busy` | Remote main changed three times during the publication. Run the retry command later. |
| `parallel-integration-state` | Local main is not a commit of the integration record. Restore local main to the named H or C2. Then run the retry command. |
| `parallel-git` | This Git has no `merge-tree --write-tree`. Install Git 2.38 or later. Then run the same command again. |

The `parallel-git` check runs at admission with `git merge-tree --write-tree HEAD HEAD`, only when the stage has a parallel member.
A sync stop at a stage transition of a run names the retry command. A sync stop before a run names the same command again.

A technical failure of a new Git step keeps the recovery agent, because it changes no work of other writers.
Examples are a failed fetch, a failed signature, or a timeout. A fetch fails with the codes of `remote_head`.
A sync step fails with `parallel-sync-git` or `parallel-sync-timeout`. A step of P4 fails with `publication-git` or `publication-timeout`.

In a CI wait and in `ReviewMode.publish`, a confirmation failure of a parallel member gives `parallel-remote-rewritten`, not `ci-head-drift` or `review-remote`.
A `parallel-dirty` message after an interrupted sync says that the paths can come from that sync.

### P8. Review campaigns

- `create_run` and `hand_back` use the confirmation rule. The run admission of P3 syncs a new campaign before its first pair.
- A target without a fix uses the confirmation rule. A target with a fix uses the integration of P4.
- `requeue_changed_targets` ignores a path whose only change since the target came from a sync or an integration.
  Otherwise, the changes of other writers would queue completed targets again and again.

### P9. CI for a parallel member

- The gate first reads the CI result of the published commit, as now. A red result starts the normal recovery.
- The recovery agent can find that a change of another writer causes the failure. The rule of P6 then makes it report a blocker.
- The remedy: another writer fixes remote main in another clone. When CI is green and complete for the new remote main, run the retry command.
- When the result of the published commit is red, the gate of a parallel member also reads the CI result of remote main D. A retry repeats this.
  A green and complete result passes when D contains the last published commit P of the member.
- The CI record and `cc-focus status` name D and the stage paths that changed from P to D.
  Thus the operator sees when a later commit changed or reverted the stage work.
- A mechanical test of a revert is not part of the gate. Each simple test fails in a common case, for example when another writer edits the same paragraph twice.
- A fix of the stage work itself stays a task of the normal recovery, because the stage work belongs to cc-focus.

## Tests

The tests use the split fixture with `"parallel": ["Interlink-docs", "Interlink-plans"]` and a second clone for the other agent.

- Manifest: a valid list, an unknown name, a duplicate name, a manifest without the key.
  A manifest change in a stage becomes active at the next stage. A member that becomes parallel at a pause gets the sync and the dirty check.
- Sync:
  - The continuous transition: the other clone pushed a plan change during the CI wait. The next stage syncs, and the coordinator context sees the change.
  - The transition after a completed-stage pause, a new run, a new campaign, a development run after a handover, and the restart with `--handoff`.
  - The restart with `--handoff` reads the manifest again and records the set.
  - The restart with `--handoff` takes a new baseline. The other writer's paths are not stage paths.
  - A resume in the middle of a stage does not sync.
  - `create_run` and `hand_back` change no checkout. A refusal in them leaves local main unchanged.
  - The run admission syncs after the member leases. A state at a stage start then has the new baseline, and its coordination result is cleared.
  - A member that leaves the parallel set gets a last sync at the transition.
  - A member that the stage did not publish also syncs.
  - A dirty member stops with `parallel-dirty`, also when remote main did not change.
  - Remote main behind local main, and diverged history: `parallel-diverged`. A failed fetch reports the redacted error.
  - The run admission with an unfinished invocation does not sync.
  - The run admission after a `reconcile` handover before coding takes again only parallel members. The handover in an exclusive member stays valid.
  - A new run with a dirty parallel member stops with `parallel-dirty`. After the cleanup, a rerun has no protected entries for that member.
- Integration:
  - Other files: C2 is pushed, local main is C2, and CI uses C2.
  - The same file with other lines: the merge is published without a new review, and the file stays a stage path.
  - A content conflict, a rename conflict, and a conflict between a change and a deletion: each gives `parallel-merge-conflict` before the first push.
    Remote main and local main do not change.
  - A rename by the other agent of a stage file: the check of step 4 stops before the push.
  - Rewritten remote history at the publication: `parallel-remote-rewritten`, and local main keeps the stage commits.
  - An edit of an adjacent line by the other agent: `parallel-merge-conflict`.
  - A conflict after an exclusive member was published: the retry after the remedy continues the other member.
  - A retry before the push, with local main at H and at C2, passes the preparation rule.
  - Remote main changes before the push: the runtime integrates again. After three changes, `parallel-remote-busy`, and no recovery agent starts.
  - A push that branch protection rejects keeps `publication-git`.
  - A parallel member was pushed, another writer pushed on top, and another target failed. The retry does not push the parallel member again.
  - Remote main changes after the push and before the confirmation: the confirmation passes.
  - Two unpushed stage commits become one C2 with the message of the last commit.
  - A signature with `commit.gpgSign`.
- Recovery: an interruption after step 5, after step 6, and after step 7. The resume completes without a second push and without a review reset.
  Local main at another commit gives `parallel-integration-state`.
- CI:
  - The other agent pushes after the publication. A parallel member passes the CI wait. An exclusive member still stops with `ci-head-drift`.
  - Red CI at C2 from a change of the other agent, then green CI at a later remote main: the retry passes the gate.
  - A later remote main that changed a stage path passes with green CI. The CI record and the status name the path.
  - A later remote main with another edit of the active plan, and green CI, passes the gate.
- Campaigns:
  - Review admission with remote main ahead.
  - A target without a fix while remote main is ahead.
  - A handover.
  - No requeue for remote paths.
- Exclusive member: every current blocker stays. `reconcile --publication` refuses a parallel target.
- Blockers: each new code gets `operator-context`, and no recovery agent starts. The version check fails without `merge-tree`.
  - A `project-manifest` stop at `next_stage` gets `operator-context`.
  - A sync stop at a transition names the retry command. A sync stop before a run names the same command.
  - A submodule from another writer stops with `parallel-unsupported-path` and `operator-context`, at a sync and at an integration.
    Local main does not move, and no record is saved. After the removal on remote main, a retry publishes.
  - A record whose step 7 fails: the recovery restores H, discards the record, and integrates again.
  - A target without a fix whose remote main no longer contains HEAD gives `parallel-remote-rewritten`.
  - After an interrupted sync, the `parallel-dirty` message says that the paths can come from that sync.
  - A rewrite of remote main in a CI wait gives `parallel-remote-rewritten` and `operator-context`.
  - A failed signature in P4 gives `publication-git`, and the recovery agent starts. A failed sync fetch gives a code of `remote_head`.
  - A staged change without a working-tree change stops the sync with `parallel-dirty`.
- Context:
  - Main roles, writers, and readers of a version-2 pair get `parallel_repositories`.
    The readers include inner readers, the complexity assessor, the evidence auditor, and the final-gate evidence auditor.
  - The checker scans `PARALLEL_REPOSITORIES_RULE`.
  - A saved job of a version-1 pair keeps its prompt.
  - A stage without parallel members gives no field.

## Documentation

- `docs/sequential-cycle.md`:
  - A section about parallel members: the manifest key, the remote rules, the sync points, the integration, the blockers, the recovery, CI, and the risks.
  - A qualifier for parallel members in three current passages: the CI at the published commit, the CI gate, and the checks after a stage pause.
  - The escalation paragraph: the new reason `operator-context`.
  - The rule for other agents: each agent works in its own clone and branch, never in a checkout under the project root.
  - The requirements for GitHub: a direct push to main must be possible, and main workflows must not cancel earlier runs.
  - The migration guide gets the `parallel` key in step 5 and the rule for other agents.
    Its step 7 also says that main workflows must not cancel earlier runs.
  - The note about review campaigns changes. A parallel member uses the confirmation rule. A local-only member must be exclusive.
- `plans/FOCUS_PROJECT_SPLIT_PLAN.md`: the same changes in the Interlink guide.
- `docs/focus-review.md`: the start condition and the requeue rule for parallel members.
- `knowledge.md`: the remote rules, the sync points, the integration record, marker version 2, and the new blockers.
- The project-mode text about the instruction marker in `docs/sequential-cycle.md`: version 2 and its field.
- `docs/focus-instruction-style-audit.md`: an addendum for the new rule and messages.

## Implementation steps

1. `tools/focus_project.py`: the manifest key and `Project.parallel`. `tools/cycle_workflow.py`: `state["parallel"]` at a stage start.
2. A new module `tools/focus_parallel.py`: the fetch, the ancestry tests, the sync, the integration, and the recovery.
3. `tools/focus_commit.py`, `tools/focus_publication.py`, and `tools/cycle_workflow.py`: the remote rules, the integration before each push, and the recovery.
4. `tools/cycle_workflow.py`, `tools/focus_review_run.py`, and `tools/cc_focus.py`: the sync points, the restart baseline, and the campaign rules.
5. `tools/cycle_workflow.py`: the CI gate of P9. `tools/focus_control.py` or `tools/focus_status.py`: the CI fields in `cc-focus status`.
6. `tools/focus_publication_recovery.py`: the refusal of a parallel target.
7. `tools/cycle_workflow.py`: the blocker set and the reason `operator-context`.
8. The context field, its rule, and version 2:
   - `tools/cycle_prompts.py`: `PARALLEL_REPOSITORIES_RULE`. `tools/check_focus_instructions.py`: scan it.
   - `tools/focus_publication.py` and `tools/focus_pairs.py`: the field.
   - `tools/focus_pair_repair.py` and `tools/focus_repair_evidence.py`: the marker copies with version 2.
9. Tests:
   - A new `tests/test_focus_parallel.py`, registered in `tests/launchers/test-cc-focus.ps1`.
   - The blocker test in `tests/test_cycle.py` and the checker test in `tests/test_focus_instructions.py`.
10. Installation: `focus_parallel.py` in the file list of `tools/sync-runtime.ps1` and in both lists of `tests/launchers/test-sync-runtime.ps1`.
11. Documentation.

## Out of scope

- A merge of other agents' branches by cc-focus.
- A model role that resolves merge conflicts.
- A parallel code repository.
- A sync during a stage, after coding started.
- Protected work in a parallel member.
- A mechanical check that remote main kept the stage change. The status names the changed stage paths instead.
  A later change can add such a check as a signal in the status. It needs Git 2.40 for `merge-tree --merge-base`.
- Changes to models, efforts, review targets, or CI requirements.
