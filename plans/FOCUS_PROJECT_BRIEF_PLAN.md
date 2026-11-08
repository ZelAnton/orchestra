# cc-focus project brief: implementation plan

Status: reviewed, revision 13. Both reviewers gave two consecutive clean passes, on revisions 11 and 12.
Revision 13 applies only cosmetic findings of the last pass. Implementation remains pending.
See [the review record](FOCUS_PROJECT_BRIEF_REVIEW.md) for findings, checks, and review passes.

## Goal

Give the cc-focus roles that make engineering judgments a short, stable description of the project.
The description names the purpose, the long-term direction, the users, the priorities, the limits, and the goal of the current milestone.
The roles use it for decisions that depend on the purpose and priorities of the project.
Examples are the effect and severity of a finding, the scope of a stage, and the choice of the smallest compatible solution.

The brief is context for judgment.
It adds no requirement, task, or stage, and it does not show the status of the work.
The role contract, operator messages and corrections, the review scope, the project instructions, and the plan take precedence over it.

## Background

- Writing roles (code, pair executors, `repair_execute`, `heal`) load the project instruction files.
  In Interlink, the purpose section of `AGENTS.md` is short, and most of that section is stage status.
- Claude pair inspectors start without user or project settings.
  Codex pair readers run in a frozen view directory inside the project tree.
  It is not verified whether Codex then loads the `AGENTS.md` of the repository. The design does not depend on it.
  Readers use the frozen view: source files, the stage diff, and the runtime records under `__review__/`.
- The Codex coordinator loads `AGENTS.md`.

Stage status in project documents becomes out of date.
In Interlink, the stale plan status ("S2-15g1 waits for review") caused wrong stage labels in two stages.
Thus the brief contains no status. The plan and the runtime facts (`previous_stage`, `published`) give the status.

The brief is a separate input, not a section of `AGENTS.md`, for three reasons:

- Claude inspectors do not load `AGENTS.md`, and the design does not depend on Codex loading it.
- `AGENTS.md` mixes binding rules with context, and its status text drifts.
- An operator-owned input can stay outside the stage diff, the reviews, and the publication.

## Rejected design

Revision 1 used a file `PROJECT-BRIEF.md` in the checkout.
The first review found many conflicts with that design:

- An edit appears in the stage diff, resets reviews, and enters the publication.
- An untracked or dirty file becomes protected work, and the reconcile advice moves it into the stage.
- In project mode, the root is not a Git repository, so the file has no history and a change raises `project-context-changed`.
- A gitignored file is invisible to snapshots, and file names that differ only in case break the snapshot key.
- A commit at a review pause queues completed review targets again.

Thus the brief is an operator import into the runtime store, similar to a handoff.

## Design decisions

### D1. Import commands

- `cc-focus brief set FILE` validates `FILE` and stores an immutable copy as `briefs/<sha256>.md` in the control store `.work/cycle/`.
  It then writes the pointer file `project-brief.json` in the same store, with the hash, the absolute source path, and the time.
  Thus `show` can check the source file from any later working directory.
  The copy path is always derived from the hash. The pointer does not store it.
- If a copy with the same hash already exists but its bytes differ, `set` replaces it atomically.
- `cc-focus brief restore FILE` stores the copy of `FILE` and does not change the pointer.
  It accepts only a hash that the pointer, the development stage record, or the stage record of an unfinished campaign names.
  Thus a restore of a damaged copy keeps a pending default.
- `cc-focus brief clear` writes a pointer with no brief.
- `cc-focus brief show` prints the pointer, the stage records, and whether the source file changed since the import.
  - Without `--review-run`, it prints the development record and the record of an unfinished campaign, if one exists.
  - With `--review-run ID`, it prints the record of that campaign.
  - If a record cannot be read, `show` reports that error. It still prints the pointer and the other records.
- The parser gets the command `brief` with an action `set`, `restore`, `clear`, `show`, or `apply`.
  `set` and `restore` take a file argument.
  With `brief`, the parser refuses all other options, except `--review-run ID` with `show` and `apply`.
- `set`, `restore`, `clear`, and `show` start no provider, take no lock, and do not change `state.json`.
  `set` writes the copy first and the pointer second, each with `atomic_write`.
  Thus these commands work while a run is active and cannot block a run start or a stop.
- `cc_focus.main` runs these four commands before `LocalLock`, always on `Store(root).control_directory`.
  It runs them before its generic `choose_store` call, which refuses a missing review run.
- For these four commands, the current directory must be the top-level directory of a primary Git checkout or a project root.
  The check refuses a linked worktree, as runs do, because no run would read a pointer there.
  It does not need branch `main`, and it accepts a Git operation in progress. It does not use `assert_main`.
- `apply` uses the normal admission of `main`, including `assert_main`.
- The brief commands call `check_project_owner`, as `stop` does. Thus they refuse a member repository of a running project.
  In project mode, run the brief commands at the project root.
  A pointer in a member repository applies only to standalone runs of that repository.
- `tools/focus-runtime.ps1` runs `brief set`, `brief restore`, `brief clear`, and `brief show` directly, like `status`.
- Keep the source file outside the project directory, for example `~/briefs/interlink.md`.
  A source file inside the project is ordinary project work: commit it, or keep it in an ignored path.
  Otherwise the runtime handles it like any other new file.
  Thus it becomes a stage file, protected work, or a `stage-base-dirty` stop, as for any file that appears at that time.
- The brief is local to the machine. Handoffs do not carry it. On another machine, run `brief set` again.
- The pointer is a default for future stages, not a control command for an active stage.
  Concurrent commands follow the atomic ordering in D9.
  Stored bytes remain available for every stage and review record that refers to their hash.
  This change introduces no automatic deletion of brief copies.

### D2. Content and limits

- Validation accepts a regular UTF-8 file, with no symbolic link or NUL bytes, at most 8 KiB.
  Its decoded text must contain a non-whitespace character.
  Otherwise the command fails with a clear message, and the pointer does not change.
- The recommended size is about 300 words. The brief can be in any language.
- Templates and assistant-written briefs use English by default, under the instruction style policy.
  An explicit user request can select another language. Imported operator text keeps its original language.
- `project-brief.example.md` in the Orchestra root gives the template with five sections:
  - purpose and long-term direction
  - users
  - priorities, for example correctness and evidence before speed
  - limits and non-goals
  - goal of the current milestone
- The template tells the operator to write facts and priorities, not instructions. Hard rules belong in the project instructions.
- Long-term direction and the current milestone use separate paragraphs.
  Future capabilities are aspirations, unless the plan or project instructions already require them.
- The milestone goal is one or two sentences about the intended result and its reason.
  It has no stage IDs, no progress, no dates, and no words such as done, in progress, or waits for review.
  The operator changes it only when a new milestone starts.
- `cc-config` does not seed the template. A seeded placeholder would become a valid brief.

### D3. One frozen brief for each stage

- At each stage start, the runtime reads the pointer, verifies the copy, and records `state["project_brief"]`.
  The record has the iteration and the hash. A missing pointer or a cleared pointer gives `{"iteration": N, "sha256": null}`.
- Before a stage transition changes state, the runtime reads and validates its brief once.
  It then saves the brief record with the new stage in one state update.
  A failed read leaves the earlier stage and its sessions intact.
- Stage starts are:
  - `fresh_state`, also for the first review target, because `create_run` calls it.
    `main` calls `fresh_state` before `control.begin()`.
  - The base `advance_stage`. It reads and verifies the brief at its start and sets the record in the same update.
    The callers are `next_stage` in the run, `hand_back` before the run, and the review-run `advance_stage` for later targets.
    The review-run `advance_stage` calls `requeue_changed_targets` before the base method. That step is idempotent, so a repeat after a failed read gives the same state.
    When no target remains, the review run completes and does not read the brief.
  - The restart with `--handoff` after `status=complete`, which starts a new stage in the same iteration.
    `main` reads and verifies the pointer right after it reads the state, before `control.begin()` and the inner `try`.

    In the lease, the handoff import, the restart, and the record are one update.
    Until the restart update is saved, no inner error handler of `main` saves the state. This includes the interrupt handler.
    Thus a bad pointer, an invalid handoff file, a lease failure, or an interrupt cannot change the status `complete`.
    A repeat of the command after the fix restarts the stage.

    If the captured hash differs from the hash of the stage record, this restart archives and clears the role sessions.
    The new generation prevents the earlier brief from remaining in a reused conversation.
    Equal hashes, including two null hashes, retain the existing session behavior.
    With `--new-sessions`, the same restart advances the session generation only once.

    An absent legacy record counts as null. A malformed record counts as a different hash.
    Before the restart replaces a malformed record, it stores the earlier state as an artifact and prints a notice.
- A missing key is the legacy case described below.
  A present record with an invalid hash, type, or iteration raises `brief-drift`.
  Corruption must not silently remove an input from a reviewed stage.
- A null hash adds no field, so the prompts stay unchanged.
- In a state made by an older runtime, the missing key reads as a null record for its current stage.
  The runtime does not write that record. It writes the first record at the next stage start, or at an `apply` that changes the record.
  The brief then starts at the next stage. Without `brief apply`, prompts within a stage never change.
- A pointer change takes effect at the next stage. `cc-focus status` shows a pending change as "takes effect at the next stage".
  To cancel a pending change, run `brief set` again with the earlier file.
  If the stage record has no brief, run `brief clear` instead.
  The pointer then agrees with the stage record again.

### D4. Change in the middle of a stage

#### Scope

- `cc-focus brief apply` applies the current pointer to the current stage. It requires a stopped run.
- The command uses the root lock, member locks, and provider-exit checks of the selected run.
  A change also uses the shared lease of the run. The equal-hash exit happens before the lease.
- For the development store, `apply` first runs the existing review handover of `main`, as `correct` does.
  Without the handover, a direct update changes the development state.
  `hand_back` then finds a difference from the saved development record and skips the completed campaign permanently.
  A handover can start the next stage. That stage captures the current pointer, as every stage start does.
- `apply` does not create a campaign, migrate a profile, or start the workflow.
  It does not compact snapshots, replace sessions, retry a provider, or shorten a provider wait.
  These are run operations, not part of brief acceptance.
  A correction can retire a pending invocation and its wait under the existing correction rules.
- `tools/focus-runtime.ps1` runs `apply` like `correct`.
- Use cases are a brief that misleads the reviews or a brief that causes provider refusals.

#### Order of checks

`apply` makes its checks in this order. The first failed check stops the command.

0. The existing admission of `main`: `choose_store` and `review-state`, `assert_main`, the root lock, `check_project_owner`, `check_parked_provider`, and the member locks.
1. The existing checks of `main` before the state read: `review-active`, then the review handover.
2. The existing checks of `main` after the state read: the project layout check, the refusal check for commands that keep sessions, then `recovery-state`.
3. The saved-state refusals, before `control.begin()` and the inner `try`:
   - `status=complete`, unresolved messages, and a completed or started publication, as in `correct()` and `ReviewMode.correct()`.
   - The phases `publish` and `ci`. Unlike `correct()`, `apply` refuses all of these phases.
4. The pointer capture and the equal-hash check, also before `control.begin()`.
5. After the lease is acquired: `recovery-paused`, HEAD equal to the baseline, and `check_protected`.

- A completed-stage pause is in phase `ci`, so step 3 refuses it.
  After `status=complete` and at a completed-stage pause, the pointer takes effect at the next stage.
- For a valid stage record, an equal pointer hash means that the brief is already active.
  Then `apply` reports this, changes no workflow state, and exits with code 0.
  This also covers a handover that started a stage with the current pointer.
  This equality check does not prevent replacement of a malformed stage record.

#### Messages

- With no saved state, the `recovery-state` message for `apply` says that no stage exists.
  It also says that the next stage start captures the pointer.
- In a review run, `apply` requires `--review-run ID`, as `correct` does.
  Without it, the `review-active` message names `cc-focus brief apply --review-run ID`.
- After a refusal blocker, a plain `apply` stops with `refusal-retry`.
  In development, the message names `cc-focus --new-sessions`, then `cc-focus brief apply`.
  In a campaign, it names `cc-focus review --resume ID --new-sessions`, then `cc-focus brief apply --review-run ID`.
- The result prints the accepted hash, the selected run, and the path: direct update, correction, or no change.

#### Persistence

- For `apply`, the inner error handlers of `main` do not save the workflow state.
  Lease ownership and timestamps can change through the existing lease protocol.
  A rejected application changes no brief record, phase, review credit, corrections, or pending work.
  An accepted review handover remains, as for `correct`.
- The command captures and validates one pointer value under the runtime lock.
  The application uses that value throughout its checks and save.
  A later `set` or `clear` remains pending for the next stage.
- A failed save before atomic replacement leaves the prior workflow state intact.
  After an error during replacement, directory synchronization, or lease release, reread the saved state under the lock.
  Report whether the intended change was committed. Never overwrite a committed change with the earlier state.
  If the result is uncertain, preserve the artifacts and report the uncertainty. Do not start a provider.

#### Direct update

If no work of the stage used the brief, `apply` updates the stage record directly. All of these conditions must be true:

- `code_started` is false. In a review run, it is always false, so the other conditions decide.
- The state has no `pair_review`, no `pair_completed` entry, no `pair_handoff`, and no `final_review`.
- The saved `sessions` contain no session of a role that receives the brief.
- No pending invocation of a role that receives the brief exists. A pending coordinator or healer can remain, because they receive no brief.
- The stage record is not malformed.

The direct update keeps a saved blocker. After `apply`, run the retry command.

#### Correction

- Otherwise `apply` calls `record_correction` with the metadata key `brief_change` and the new record in the `candidate` state.
- The resume phase is `code` when the phase is `code`. Otherwise it is `pair_a`. Review runs use `pair_a`, as today.
- The `brief_change` key suppresses `publication_recovery` and sets its own reset reason for the panel.
- A `brief_change` correction sets no new `correction_pending` ID. It keeps an existing value.
  Thus an earlier operator correction still blocks a `complete` report, and a brief change alone adds no such block.
- `record_correction` clears `coordinated`, so the coordination runs again.
  Before coding in development, it also clears the provisional task.
- The correction file contains the fixed constant `BRIEF_CHANGE_CORRECTION` from `tools/cycle_prompts.py`. It contains no brief text:
  "The operator changed the project brief for this stage. If your context contains a project brief, use that brief instead of earlier brief text. If your context contains no project brief, do not use earlier brief text. This changes no requirement, task, or stage."
- The correction entry has the field `brief_change: true`. Task corrections are the entries without `brief_change`.
  The contexts handle brief entries apart from task corrections:
  - `operator_corrections` lists only task corrections.
  - `before_code`, the selection text, the correction instructions, and `publication_recovery` use the latest task correction.
  - Without a task correction, the context has none of these fields.
    Non-pair contexts then omit `operator_corrections` and `correction_pending`, as they do today without corrections.
  - The contexts deliver the brief entries as the field `project_brief_notice` with the fixed text, not as corrections.
  - Pair contexts keep the `corrections` key, also as an empty list, because saved pair prompts contain it.
    They add `project_brief_notice` only when a brief entry exists.
  Thus a brief change alone never adds the same-stage selection text, also after a `--handoff` restart.
- The notice reaches every role that receives corrections today, also the roles without a brief.
  It remains for the rest of the iteration, also after a `--handoff` restart.
  Thus one text covers a new brief, a removed brief, and a later restart. It names the brief only on a condition.
- `reset_reviews` calls `reset_pairs`, which removes the pair record and its saved jobs.
  Saved executor results and saved test results check `correction_revision`, so they do not continue.
- Like `correct`, the correction removes a pending invocation, also when that invocation has a saved result.
- `apply` keeps the role sessions, like `correct`. The code, executor, and `repair_execute` conversations then still contain the old text.
  The correction text tells these roles not to use it.
- A malformed stage record requires the correction path, even when no earlier work is recorded.
  The archive retains the malformed value, and the new record replaces it through normal state persistence.
  A damaged state envelope still requires the existing state recovery. Brief commands must not repair its checksum.

#### Recovery after a provider refusal

If the old brief caused a provider refusal, use this order in development:

1. `cc-focus brief set FILE` or `cc-focus brief clear`.
2. `cc-focus --new-sessions`. It starts new conversations and stops at the saved blocker.
3. `cc-focus brief apply`.
4. `cc-focus`.

For a blocked review campaign, use its ID throughout the same sequence:

1. `cc-focus brief set FILE` or `cc-focus brief clear`.
2. `cc-focus review --resume ID --new-sessions`, without `--retry`.
3. `cc-focus brief apply --review-run ID`.
4. `cc-focus review --resume ID`.

These session replacement commands assume a saved refusal blocker. Without that blocker, they can start work.

### D5. Delivery to the roles

| Role | Delivery |
| --- | --- |
| `code` | `context["project_brief"]` with the text, the hash, and the rule |
| Pair executors and `repair_execute` | The same field in the executor assignment |
| Pair inspectors, discussion readers, the arbiter | The same field in the pair assignment |
| Inner repair readers | The same field in the pair assignment |
| Final pair initial inspections and the final arbiter | The same field in the pair assignment |
| `coordinate`, `publish`, `heal`, the complexity assessor, the evidence auditor | No brief |

- The context contains the text itself, not only a path. The role does not need a tool call to read it.
- A pair record stores the brief hash when the pair starts.
  - `new_pair` copies the hash of the stage record.
  - `repair_reader` and `start_final_gate` copy the hash of the outer pair. An absent hash stays absent.
  - The prompts of a pair take the text from the copy with the stored hash. Peers of one pair thus always get the same input.
  - The evidence-audit reader of `queue_repair_evidence` gets no brief.
- Pair writers also use the stored hash of their outer pair, not the current pointer.
  Only code outside a pair reads the stage record directly.
- An excluded role gets no `project_brief` field, even when its parent pair has a hash.
  Exclusion controls direct delivery. It does not redact project references from ordinary reports that the role already receives.
- A pair record without a stored hash, made by an older runtime, gets no brief.
  Its saved jobs then have the same prompts as before, so `same_pair_prompt` needs no change.
- The coordinator gets no brief, because its main decisions are the stage and the `complete` result.
  The code role also selects the stage and can report `complete`. The rule therefore forbids these uses of the brief.
- The publisher, the complexity assessor, and the evidence auditor make no decision that uses the brief.
- The healer repairs a blocker. The brief would only add noise.
- The final pair keeps its independence.
  The brief is operator text about the project, not an earlier review opinion, so it is a neutral input.

### D6. Integrity

- The runtime verifies the brief where it uses it: at a stage start and when it builds a prompt that contains the brief.
  Only these two points stop provider work on a bad brief.
  `apply` and the `--handoff` restart also refuse a malformed pointer before they change state, except an accepted review handover.
  `status` and `show` only report errors.
- The copy at the derived path must be a regular file, not a symbolic link.
  The check repeats the hash, size, UTF-8, and NUL checks of D2. A copy that only drifted does not stop publication.
- A malformed pointer, or a missing or changed copy, stops the work with `brief-drift`, raised as `Blocked`.
- `brief-drift` starts no healer, because the healer may not change operator inputs.
  Its escalation reason `brief-input` says that the brief needs the operator.
- The message names the remedy for its call site:
  - A bad pointer or copy at a stage start in the run (`next_stage`, a later review target): the runtime saves the blocker.
    Run `cc-focus brief set FILE` or `cc-focus brief clear`.
    Then run the retry command of the cycle, `cc-focus --retry` or `cc-focus review --resume ID --retry`.
  - A bad pointer or copy at a stage start before the run (`fresh_state`, `create_run`, `hand_back`, the `--handoff` restart): no state changes.
    Run `brief set` or `brief clear`. Then repeat the same command.
  - A missing or changed copy of the current stage at a prompt build: the runtime saves the blocker.
    Run `cc-focus brief restore FILE` with the same file. Then run the retry command. A pending default stays unchanged.
    Without that file, run these commands in this order:
    1. `cc-focus brief set FILE` with another file, or `cc-focus brief clear`.
    2. `cc-focus brief apply`. In a campaign, add `--review-run ID`.
    3. `cc-focus`. In a campaign, run `cc-focus review --resume ID` instead.
  - A damaged stage record: run `cc-focus brief apply`. In a campaign, add `--review-run ID`.
    Then run `cc-focus`. In a campaign, run `cc-focus review --resume ID` instead.
    To change the pointer, first run `brief set` or `brief clear`. `apply` must not load the old brief text to replace the record.
- `cc-focus status` shows a malformed pointer or a bad copy as an error in its `project_brief` entry. It does not fail.
- The copies and the pointer are under `.work/cycle/`. Snapshots exclude `.work/cycle/` in a single repository, and project-mode loose files exclude `.work/`.
  Thus the brief never becomes a stage path, a protected path, or a publication path.
- The existing contracts already forbid changes to `.work/cycle` for all provider roles.
- Validate the pointer and stage-record schemas in D9 before constructing a copy path.
  Resolve every runtime path within the control store.
  Reject symbolic links, directory redirects, and nonregular files at the pointer or copy paths.
  Reject a redirected `briefs` directory before any read or write.
  Use bounded reads for source files, copies, and pointers. Do not read an oversized file before checking its limit.
- `show` and `status` distinguish pointer errors, stage-copy errors, and source-file observations.
  A missing, changed, unreadable, or invalid original source is informational after a successful import.
  It neither changes the saved copy nor blocks a run.

  Read the original only for explicit `brief show`, with the input limits from D2.
  Ordinary `status` never reads the original source.
  When no run exists, `status` still shows the imported default and reports that no stage has captured it.
  Apply `terminal_text` to all displayed paths and operator text, also in the JSON output of `status` and `show`.
- Invalid metadata in an existing pair uses the normal state or pair-evidence recovery.
  Do not repair that metadata through `set` or `restore`.
  Do not claim that restoring a copy repairs an invalid pair record.

### D7. Rule text

The rule follows the proposal from the first review. The text is in the context, so it needs no "read the brief" sentence.

> The project brief is operator text about the purpose, direction, users, priorities, limits, and milestone goal of the project.
> Use the brief to find the effect of a change or a finding on these users and goals.
> The brief does not add requirements, tasks, or stages.
> It does not show the status of the work.
> Future direction does not define acceptance criteria for the current stage.
>
> If the brief does not agree with another source, obey the other source.
> These sources are your role contract, operator messages and corrections, the review scope, the project instructions, and the plan.
>
> Do not use the brief to select a stage or to decide that the plan is complete.
> Assess severity from actual effects and binding requirements.
> Do not use the brief to dismiss a correctness, safety, security, or required-contract failure, or to lower its severity.
> The brief alone is not a reason for a full run.
> Do not change the brief. Do not request a change to the brief.

The rule is a constant `PROJECT_BRIEF_RULE` in `tools/cycle_prompts.py`.
It is not part of `PAIR_CONTRACT`, so the earlier contract digests stay valid.
The third paragraph has six sentences, which is the limit of the checker. Do not add a sentence to it.

Saved pair prompts contain the rule and the notice.
Before a later change of `PROJECT_BRIEF_RULE` or `BRIEF_CHANGE_CORRECTION`, add a `_STYLE_TEXT` entry in `tools/focus_pair_jobs.py`.
Otherwise a saved pair job stops with `pair-intent`.

### D8. Project mode and review mode

- The pointer and the copies are under the development store `.work/cycle/` of the project root. This works the same in project mode.
- A review run keeps its own state under `.work/cycle/review-runs/ID/`.
  It reads the development pointer and the shared copies in `.work/cycle/briefs/`.
- The review-run coordinator has its own prompt and gets no brief, as in D5.
- The brief does not change the review checkout, so it causes no review-work, requeue, or handover problem.
- A completed review target retains the brief that its reviewers used.
  A changed default does not reopen completed targets or change their recorded conclusions.
  To reassess those targets under another brief, start a new campaign with those targets.
  `brief apply` affects only the current unfinished target.

### D9. Data and concurrency contract

The pointer has exactly these fields:

| Field | Value |
| --- | --- |
| `schema` | `orchestra/project-brief@1` |
| `sha256` | 64 lowercase hexadecimal characters, or null |
| `source` | Absolute source path, or null when cleared |
| `updated` | Finite, nonnegative timestamp, not a boolean |

A pointer has at most 16 KiB of UTF-8 JSON. Duplicate keys and unknown fields are invalid.
`sha256` and `source` must both be null or both contain values.
A missing pointer means no default. A malformed pointer does not mean no default.

The byte hash covers the exact imported bytes, with no newline, Unicode, or BOM normalization.
A UTF-8 BOM can remain in the stored bytes. Decode with `utf-8-sig` for the prompt.
The size limit includes the BOM. Empty text after decoding remains invalid.

The stage record has exactly `iteration` and `sha256`.
Its iteration is a positive integer, not a boolean, equal to the current state iteration.
The hash follows the pointer hash format. Null explicitly means no brief.
An absent stage key remains valid for legacy states. A present invalid record does not.

New pair records use `project_brief_sha256`, with a valid hash or null.
An absent pair field means a legacy pair without a brief.
The runtime copies the field into inner readers and the final gate without consulting the current pointer.
Evidence auditors remain excluded.

The delivered `project_brief` object has exactly `sha256`, `text`, and `rule`.
It has no source path, timestamp, status, or previous brief.
The field `project_brief_notice` is a string with the fixed text `BRIEF_CHANGE_CORRECTION`.

`set` validates and reads the source once, with an 8 KiB limit plus one byte to detect overflow.
It checks the path with `lstat` before it opens the file. It refuses a symbolic link and, on Windows, a reparse point.
On POSIX, it opens the file with `O_NOFOLLOW` and `O_NONBLOCK`. On Windows, it opens the file with `O_RDONLY` and `O_BINARY`.
`fstat` must then show a regular file with the same `st_dev` and `st_ino` as the `lstat` result.

`set` prepares the pointer bytes before writing any destination.
It then stores the verified copy before replacing the pointer atomically.

`restore` uses the same reads and checks as `set`. It writes only the copy.
It reads each hash source alone: the pointer, the development state, and the unfinished campaign.
It skips a source that it cannot read, with a notice. Thus a malformed pointer does not prevent a restore for a stage record.
If no readable source names the hash, `restore` refuses.

`clear` replaces the pointer atomically, without reading or deleting any old copy.
A malformed old pointer therefore does not prevent `set` or `clear`.
Path integrity failures still prevent writes.

The final atomic pointer replacement orders concurrent `set` and `clear` commands.
The last replacement becomes the default. No command promises that its value remains the latest after return.

A stage captures one complete pointer value. A concurrent replacement applies either to that stage or to the next stage.
Both readers of a pair still use the one captured hash.
There is no second pointer read during the same stage transition or application.

A crash after copy storage but before pointer replacement leaves an unused valid copy.
It does not select that copy. A crash cannot produce a pointer to a partly written copy.
A failed copy verification keeps the previous pointer.

Restoring a corrupt copy writes only bytes whose hash matches its existing name.
Concurrent readers either see the earlier file or the complete restored file.
A reader that sees corruption keeps the normal `brief-drift` result and requires a retry.

### D10. Evidence and acceptance boundaries

New invocation intents record the selected brief hash for included roles.
Pair conclusions and repair seals record the hash used by that pair.
Review target results record their stage hash, including null.
Retain all earlier records unchanged. Missing legacy fields mean that no brief was supplied through this feature.

The recorded prompts already contain the delivered text. Do not copy the text into status, progress, or CI output.

The new fields do not require a review-profile migration.
A legacy pair keeps its original input even when a default exists.
A changed default alone must not reset sessions, invalidate saved jobs, or give review credit.
An explicit `apply` retains earlier evidence but resets the affected review credit through the correction path.
Existing rules still decide whether a completed check applies to unchanged code.

Publication does not need to read a brief used by completed reviews.
It relies on the existing sealed reports, candidate checks, and scope checks.
A missing historical copy must not block publication or cause new publication work.
The next stage still validates its selected default before starting a provider.

## Implementation steps

1. `tools/focus_brief.py` (new): validation, copy, restore, pointer read and write, hash verification, and the stage record.
   Add it to `$script:SharedRuntimes` in `tools/sync-runtime.ps1` and to the shared-asset list in `knowledge.md`.
2. `tools/cc_focus.py`:
   - The `brief` command with `set`, `restore`, `clear`, `show`, and `apply`, its parser rules, and the root check (D1 and D4).
   - The check order of `apply`, its messages, and the no-save rule of the inner error handlers.
   - The `--handoff` restart as a stage start, with the pointer read before `control.begin()`.
     No inner error handler, including the interrupt handler, saves the state before the restart update.
   - An acceptance route for `apply` after the review handover of `main`, without workflow startup.
   - A success exit for `apply` when the stage already uses the pointer hash.
   - Status output when a default exists but no run exists, with `terminal_text` for brief paths and text.
3. `tools/focus_control.py`: the `project_brief` status entry defined in D6.
   Keep pointer, stage-copy, and source observations separate. Do not read the original source during ordinary status updates.
4. `tools/focus-runtime.ps1`: direct dispatch of `brief set|restore|clear|show`, and `apply` like `correct`. Add a launcher test.
5. `tools/cycle_workflow.py`:
   - The record in `fresh_state` and `advance_stage`, plus the context field for `code`.
   - The `brief_change` correction path, without `publication_recovery` and without a new `correction_pending` ID.
   - The context handling of brief entries, with `project_brief_notice`.
   - Invocation evidence, integrity checks, and the escalation reason `brief-input` for `brief-drift`.
   - Validation before stage mutation. Handle save failures under D4 without restoring stale state over a committed change.
6. `tools/focus_pairs.py` and `tools/focus_pair_repair.py`: the hash in new pair records, and the field in reader and executor assignments.
   The complexity assessor and the evidence auditor get no field.
   Record hashes in conclusions and repair seals.
   In `pair_prompt`, `pair_writer_context`, and `repair_writer_context`, filter brief entries out of `corrections`.
   In the same functions, add `project_brief_notice`.
   In `tools/focus_pair_jobs.py`, record the hash in new job intents without changing saved-prompt equality.
7. `tools/focus_review_run.py`: `apply` in `ReviewMode` and the hash in target results.
   Later targets get the record from the base `advance_stage`.
8. `tools/cycle_prompts.py`: the constants `PROJECT_BRIEF_RULE` and `BRIEF_CHANGE_CORRECTION`.
9. `tools/check_focus_instructions.py`: add the two constants to the scanned names.
10. `project-brief.example.md`: the template.
11. `tests/launchers/test-cc-focus.ps1`: add a new test module if one is created.

## Tests

### Validation and commands

- Validation accepts a valid file. It refuses an empty, whitespace-only, BOM-only, oversize, non-UTF-8, NUL, symbolic-link, directory, and FIFO input.
- A BOM remains in the stored bytes and counts toward the size limit.
- After a failed validation, the pointer does not change.
- The read rules of D9 hold on POSIX and on Windows, in CI or with a platform stub.
- `set`, `restore`, `clear`, and `show` work while a run is active and while it is stopped.
- The four commands refuse a subdirectory, a linked worktree, and a member repository of a running project.
- They accept a member repository after the project run, a branch other than `main`, and a Git operation in progress.
- `set` replaces a corrupt copy with the same hash.
- `restore` replaces a corrupt copy and keeps the pointer. It refuses a hash that no pointer or stage record names.
- `restore` skips an unreadable source with a notice. With a malformed pointer, it still restores a hash that a stage record names.
- `show` reports whether the source file changed since the import.
- `show` without `--review-run` prints the development record and the record of an unfinished campaign.
- `show --review-run ID` prints that record. When a record cannot be read, `show` still prints the pointer and the other records.
- The parser refuses other options with `brief`.

### Pointer schema, concurrency, and storage

- The pointer refuses unknown fields, duplicate keys, a size over 16 KiB, and a `sha256` and `source` pair with only one null.
- The pointer refuses an `updated` value that is a boolean, negative, or not finite.
- Concurrent `set` and `clear` produce a complete valid pointer, with the last atomic replacement effective.
- A pointer change during stage capture or `apply` cannot change the already captured hash.
- A crash between copy and pointer writes leaves the earlier selection effective.
- A missing original source does not affect prompts, ordinary status, or publication.
- Bounded reads refuse growing files and nonregular opened sources.
- Malformed JSON, invalid hash types, and redirected runtime directories fail without external writes.
- `set` and `clear` recover a malformed pointer without reading its old value.

### Stage record

- Each stage has one record. A pointer change takes effect at the next stage.
- `set` with the earlier file, and `clear` when the stage record has no brief, cancel a pending change.
- A failed read at a stage start leaves no state of the new stage. A review-run repeat gives the same state.
- In an older state, the missing key reads as a null record, and no record is written. The brief starts at the next stage.
- A present record with the wrong iteration or an invalid hash raises `brief-drift`.

### The `--handoff` restart

- The restart after `complete` records the brief.
- A bad pointer, an invalid handoff file, a lease failure, and an interrupt during the lease acquisition keep `status=complete`.
- A repeat of the command after the fix restarts the stage.
- A restart with a different hash retires the old conversations. A malformed old record also retires them, with an artifact and a notice.
- An absent legacy record with a null pointer keeps the conversations. With a brief, it retires them.
- Equal or null hashes preserve the existing behavior.
- With `--new-sessions`, the restart creates only one new session generation.

### `apply`

- Refusals:
  - It refuses an active run, `status=complete`, the publication and CI window, a completed-stage pause, and unresolved messages.
  - It refuses HEAD drift and a `check_protected` failure after the lease is acquired.
  - `recovery-state` with no saved state, and `recovery-paused` with a pause file or a stop request, refuse it.
  - The `recovery-state` message says that no stage exists and that the next stage start captures the pointer.
  - The `review-active` message names `cc-focus brief apply --review-run ID`.
  - After a refusal blocker, a plain `apply` stops. The message names the session command of development or of the campaign.
  - A malformed pointer at `apply` makes no state change, except an accepted review handover.
  - The checks run in the order of D4.
- No change:
  - An unchanged hash of a valid record changes nothing and exits with code 0.
  - After a handover that starts a stage with the current pointer, it exits with code 0.
- Persistence:
  - A refusal before or inside the lease saves no workflow state.
  - A lease acquisition failure can update ownership metadata but cannot accept a brief or change workflow status.
  - A lease release failure after acceptance keeps the committed record and reports it.
  - Failures before and after atomic state replacement preserve the actual committed result and its correction archive.
- Direct update:
  - Before any work used the brief, it updates the record directly. A saved blocker, a pending coordinator, and a pending healer remain.
  - A pending reader or writer forces the correction path.
  - After an equal-hash `--handoff` restart that kept the code session, it takes the correction path.
  - In a review run, a writer session kept after a review reset forces the correction path.
  - In a review run after a completed Pair A, it takes the correction path.
  - After a completed review campaign without changes, a direct update keeps the handover of that campaign.
- Correction:
  - The correction resets the reviews and pairs, records the new hash, and keeps the resume phase rules.
  - It sets no `publication_recovery` and no new `correction_pending` ID.
  - Without an earlier pending correction, a later `complete` report is accepted. An earlier pending correction still blocks `complete`.
  - The correction clears `coordinated`. Before coding in development, it also clears the provisional task.
  - The contexts deliver the entry as `project_brief_notice`, not as a correction.
  - Selection text, correction instructions, and `publication_recovery` come from the latest task correction.
  - A `--handoff` restart after a brief change alone gets no same-stage selection text.
  - The correction text is `BRIEF_CHANGE_CORRECTION` and contains no brief text.
  - An invalid old stage record uses correction, retains its old value, and never loads its old text.
  - An invalid iteration with the same hash still permits explicit replacement through correction.
- Route:
  - It accepts a pending review handover like `correct`. It performs no profile migration, storage migration, or provider startup.
  - In a review run, it requires `--review-run ID` and acts on that store.
  - The result prints the accepted hash, the selected run, and the path.
  - The refusal recovery sequence works in development and in a review campaign without starting a provider before acceptance.

### Delivery and pairs

- The field with text and rule is in the code context, executor assignments, and every reader assignment.
  This includes discussion, arbitration, inner repair readers, and the final pair.
- The coordinator, publisher, healer, complexity assessor, and evidence auditor get no field.
- The initial prompt of the final pair contains the brief and no earlier report.
- Peers get the same brief. Inner repair readers and the final gate copy the hash of the outer pair.
- A pair record from an older runtime gets no brief, and its saved jobs continue.
- Pair writers use the pair hash. Saved prompts and report-only corrections retain their exact input.

### Integrity and status

- A changed, missing, or symbolic-link copy and a malformed pointer stop with `brief-drift`, and no healer starts.
- The blocked run prints the `brief-input` reason, not the consent or account reason.
- The message names the remedy for each call site: in the run, before the run, at a prompt build, and for a damaged record.
- A drifted copy does not stop publication.
- `cc-focus status` reports a bad pointer and does not fail.
- `status` shows a pending change as "takes effect at the next stage".
- With no run, `status` shows the default and says that no stage has captured it.
- `show` and `status` escape control characters in paths and operator text.

### Other

- Launcher: `brief set|restore|clear|show` run directly, and `apply` runs like `correct`.
- Review runs: `create_run` and later targets record the brief. The review-run coordinator gets none.
- Review runs: completed target results retain their hashes. A default change alone does not queue them again.
- Evidence: new intents, pair conclusions, repair seals, and target results record the applicable hash.
- Evidence: legacy artifacts remain unchanged. Status and progress do not export brief text.
- Project mode: the pointer and copies work at a project root.
- `cc-config` does not seed the template.
- No brief: all existing tests pass, and no prompt changes.
- Checker: the rule and the correction text pass `tools/check_focus_instructions.py`.

## Documentation

- `docs/sequential-cycle.md`: a new section "Project brief".
  It describes the purpose, the commands, the limits, the stage record, the change path, the refusal order, the delivery, and the integrity rule.
- `docs/sequential-cycle.md`, section "Passing context without priming the final pair": add the brief as a neutral operator input.
  It is an input of the final initial inspections and of the final arbiter.
- `docs/sequential-cycle.md`: state that the brief is local to the machine and that a new machine needs `brief set` again.
  State that project mode uses the project root.
- `docs/focus-review.md`: the brief in review runs, and `apply --review-run ID`.
- `docs/instruction-style.md`: add "project brief" and "milestone goal" to the terms.
- `knowledge.md`: the module, the commands, the state record, the delivery, and the shared-asset entry.
- `README.md`: one sentence in the cc-focus summary.
- `docs/focus-instruction-style-audit.md`: an addendum that assesses all 53 rules for the new text.
  The current audit is exactly at its target for some scopes.
  Thus the new text must not add a deviation to a rule that is satisfied now.

## Rollout

1. Implement, test, and review the change. Then smoke-test the commands and one stage in a disposable repository.
2. On an explicit operator request, the assistant drafts a brief for Interlink read-only, from its documents.
   The assistant does not write the file into Interlink. The operator edits the draft and decides on the final text.
3. In Interlink: `/finish-stage`, wait for the pause, then `/exit`. Then `cc-sync`.
4. Save the brief outside the project, for example `~/briefs/interlink.md`.
   Run `cc-focus brief set ~/briefs/interlink.md` in the Interlink root. Then run `cc-focus`. The next stage uses the brief.
5. Rollback: run `cc-focus brief clear`. The next stage then has no brief.
   To remove the brief from the stopped current stage, also run `cc-focus brief apply`. In a campaign, add `--review-run ID`.
6. Optional: the assistant proposes a text that removes the stage status from the purpose section of Interlink `AGENTS.md`. The operator decides.

## Risks

- Priming: a brief can make reviewers lenient toward findings that fit the stated priorities.
  Actual effects and binding requirements determine severity.
  The rule forbids use of the brief to dismiss a correctness, safety, security, or required-contract failure, or to lower its severity.
- Staleness: the brief contains no status, so it changes rarely. The template says so.
- Size: the 8 KiB limit keeps the cost small.
  A byte limit does not impose a token limit. Token cost depends on the language and content.
- Provider refusals: the rule uses plain engineering words and asks for no disclosure of reasoning.
  The operator text is outside the control of the runtime. In the middle of a stage, the order in D4 removes it.
- Ownership: anyone with write access to `.work/cycle/` can change the pointer. That access already allows changes to the runtime state.
- Same-stage replacement: preserved role conversations still contain earlier brief text.
  The correction explicitly replaces its authority. This is a semantic instruction, not deletion from native history.

## Out of scope

- Automatic generation or editing of the brief by a role.
- A brief for the queue processor (`cc-processor`).
- Changes to models, efforts, review targets, or CI requirements.
- The same handler and completed-campaign hazards in `correct`, `recover`, and `reconcile`. The review record lists them as follow-up work.
