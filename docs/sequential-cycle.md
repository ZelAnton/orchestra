# Focus: sequential main-branch processing

`cc-focus` is an opt-in workflow, separate from `cc-processor`. It works directly
in an existing Git `main` checkout or a project containing several such repositories,
with one provider invocation at a time across the whole project.
Queue configuration does not change its models, efforts, review thresholds,
publication behavior or permissions. It does not consume or rewrite the task queue.

```text
Luna coordination -> Claude implementation -> Astra review loop
    -> Claude review loop -> Luna readiness + runtime commit/push -> CI -> next stage
         | substantial implementation fixes |
         +--------------> Astra <-----------+
```

| Role | Model | Effort |
| --- | --- | --- |
| Coordinator | gpt-5.6-luna | xhigh |
| Implementation | claude-fable-5-1 | high |
| First review | gpt-6-astra | high |
| Second review | claude-fable-5-1 | xhigh |
| Publication preparation (read-only) | gpt-5.6-luna | high |
| Blocker resolution | gpt-6-astra | xhigh |

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

One iteration may change several member repositories. Coding and both review loops
cover their combined changes. Publication checks every changed repository's policy
and remote before starting the publisher, then commits/pushes each repository's
reviewed files to its own remote main. Untouched repositories receive no commit or
push. Existing unrelated files and index entries remain protected per repository.
Project-root shared instructions and the membership manifest are read-only cycle
context; place editable plans and source inside a member repository. An imported
handoff source outside member repositories is optional transfer input as described below.

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

Each role has its own persistent conversation. New repositories create sessions
automatically. Session identifiers are captured internally and never accepted as
CLI arguments. `--new-sessions` archives the internal session mapping and starts
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
background work. Claude receives `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` in its
environment and inline settings to disable automatic Bash backgrounding. Monitor,
cron creation, wakeup, remote-trigger and Workflow tools are disabled too. Bash's
default timeout is 30 minutes; long commands can request up to six hours within
the existing six-hour invocation deadline. These are subprocess-only settings;
the runtime never edits operator or project configuration. See the official
[Claude environment variables](https://code.claude.com/docs/en/env-vars).

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
`--output compact` still controls whether public provider payloads are displayed.

The panel uses six lines and a horizontal separator when the terminal has at
least 70 columns and 14 rows. For example, during an Astra review:

```text
Interlink · V9f-4 · Supplier disclosure and message retries
В РАБОТЕ · Ревью Astra · high · шаг 2/5 · этапов впереди: 3
✓ Реализация ─ ▶ Astra ─ ○ Claude ─ ○ Публикация ─ ○ CI
Astra: проход 4 выполняется · серия 1/3 · нужно ≥2
Claude: впереди · нужно 2 чистых подряд · завершено 0
Команда выполняется · вызов 04:12 · событие 3 с назад
────────────────────────────────────────────────────────────
```

The title comes from the selected stage in the project plan through the existing
coordinator/coder report. The coordinator can shorten it in that same call; no
extra model is started. Older saved runs show `Задача N` until a report identifies
the stage. The title is display metadata and cannot advance or select work.

The timeline shows the five main phases of this task, including returns to review.
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
once a second without scanning logs or reading files. Smaller terminals use up to
three compact lines with the mode, task, phase and review streaks; text is clipped
with an ellipsis. `/status` prints the full panel and recent review events regardless
of terminal size. `cc-focus status` also returns the panel as `dashboard` in its JSON.

| Input | Meaning |
| --- | --- |
| Ordinary text, Enter | Save an instruction for the active invocation and role |
| `/pause` | Finish the current invocation and pause; publication includes CI |
| `/stop` or Ctrl+C | Interrupt the active attempt; preserve partial work |
| `/resume` | Continue a stopped workflow, retrying a preserved blocker when appropriate |
| `/correct TEXT` | While stopped, correct the same stage and restart coding/reviews |
| `/messages` | List saved message IDs, target invocations and delivery states |
| `/retry-message ID` | While stopped, explicitly resend unresolved input to its original pending invocation |
| `/discard-message ID` | While stopped, abandon unresolved delivery without deleting its artifact |
| `/approve`, `/deny` | Answer only the currently displayed Codex approval |
| `/status`, `/help` | Show state or commands |
| `/exit` or Ctrl+D on empty input | Safely pause, then close the terminal |

PageUp/PageDown browse bounded scrollback; Up/Down recall input history. Arrow keys,
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
instructions invalidate previous clean credit; an intervened Claude review returns
to Astra before publication. Accepted instructions are referenced in later stage
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
cc-focus status
cc-focus                      # continue the preserved phase and native sessions
```

A safe stop completes the current invocation/pass, saves its result, and prevents
the next one from starting. Once publication has begun, its commit/push and CI
window finishes first. If an error blocks that window, the runtime preserves the
blocker and stops; it does not start a recovery model in response to a stop request.
Stop acknowledgement waits for the local lock and contained run to finish. A wait
timeout or Ctrl+C in the waiting terminal does not withdraw the stop request.

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

Requests are bound to one run. A later explicit `cc-focus` starts/resumes with a
new run identity, so an old stop request cannot stop it. Existing `.work/PAUSE`
remains an independent persistent switch: use `cc-unpause` yourself before resuming
when that switch is set. Focus never creates or removes PAUSE for its own stop API.

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
are ordered oldest to newest, and remain in context through both review loops.
All clean-pass credit and the publication seal are invalidated. Only a validated
coding result acknowledges the pending correction; all three Astra and two Claude
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
to that same stage and both review loops must run again. If the iteration stopped
before coding began, reconciliation preserves that fact and clears any provisional
task label: select the next stage
from the current project plan, without reopening the previous published stage from
an old conversation or handoff. Any adopted work must still complete coding and
both reviews before publication. A context-only handover with no unpublished
changes can finish if the plan is exhausted; it must not invent a stage.
Existing source files, index and Git history are preserved. The new correction
remains visible through publication and CI.

Handover requires a code iteration (including one not yet started) or an
already-started Astra/Claude stage, with unchanged HEADs and protected staging.
It refuses publication/CI, unresolved operator messages,
PAUSE, changed repository membership and unconfirmed provider shutdown. It cannot
rewind a commit or push, change runtime permission settings, or turn shared files
outside Git into implementation files. Do not edit `.work/cycle/state.json` by hand.

### Upgrading a running cc-cycle installation

The rename retains `.work/cycle/`, native role sessions and durable invocation
markers. Do not use `--new-sessions` just to rename the command. Installed managed
`cc-cycle` launchers are removed by `cc-sync` and replaced with `cc-focus`; internal
Python module names need not match the public command.

The already-running old runtime cannot receive the new stop protocol. In that
project use `cc-pause`, wait for its paused message and exit, or use Ctrl+C there
for an emergency interruption. Then run `cc-sync` from the Orchestra checkout.
Back in the project, run `cc-unpause` if needed and `cc-focus`. Do not replace the
installed runtime bundle while a processor is still using it.

## Reviews and short reports

The original step prompts are retained in `tools/cycle_prompts.py`. The runtime
adds a structured reporting protocol and invokes one complete review pass per
turn in the persistent reviewer conversation. It owns the counters:

- Astra requires three consecutive clean passes. During its first three passes,
  implementation and other substantive fixes reset the counter; afterward only
  implementation fixes count. Minor edits never reset it.
- Claude requires two consecutive passes without implementation fixes.
- Substantial Claude implementation fixes return to Astra, then Claude again.
  Contract, workflow, algorithm, permission or test-outcome changes are substantial;
  uncertain cases must be classified conservatively.

Incomplete/failed passes cannot count as clean. Reviewers report fix categories
and actual validation evidence; the runtime also compares repository fingerprints.
Semantic classification remains a reviewer judgment, not a file-extension heuristic.
New coding work can be substantial without fixing earlier review defects; a coding
report with `substantial=true` and `implementation_fixes=0` is accepted. Review and
healing reports still require a positive implementation-fix count when substantial
is true. Coding classification never grants clean-review credit.
The first reviewer receives the full coding final message. Luna receives only the
short outcome and artifact paths, with detailed evidence available when needed.

## Publication, CI and interruptions

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
Astra/xhigh recovery attempt before an operator-visible stop. An unchanged checkout
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

Claude's CLI can emit an API error as an `assistant` event with model `<synthetic>`
and `is_api_error_message=true`. This is classified as a provider failure before
checking the pinned answer model. In particular, `oauth_org_not_allowed` stops as
`claude-access-denied`: the provider says Claude Code subscription access is disabled
for the organization. Other marked synthetic errors, except structured quota
refusals described below, become `claude-api-error`
with the original error detail and receive the normal Astra/xhigh recovery attempt.
The explicit account-access refusal bypasses recovery because the agent cannot
restore the operator's subscription authority. Neither error replaces the native
session or earns review credit. Actual substituted model
answers continue to fail as `model-rerouted`.

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

Stop, emergency stop, PAUSE and uncertain-message checks remain active while
waiting. Restarting retains the deadline; corrections that replace an invocation
also retire its wait. Admission refusal before any model work on an unchanged
checkout preserves earlier clean passes and grants no new credit. Ownership and
HEAD are checked again before starting the retry. Work already
started or checkout drift uses the normal interrupted-review rules. Missing or
invalid reset data retains the ordinary provider-error recovery path. Existing
blocked runs need operator continuation after cc-sync and runtime restart; updating
the installation does not resume them or change an already-running process.

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
another agent. Operator stop/pause and uncertain message delivery retain their
existing separate continuation rules.

If recovery cannot resolve it, the cycle exits with code 3 and an operator action;
plain reruns do not spend tokens on the same unresolved blocker. Resolve the cause
and use `--retry`. Recovery may not grant operator approval, widen permissions or
discard work. If Codex itself is unavailable, automatic recovery can also be
unavailable and the problem is reported directly.
A recovery claim must be followed by a successfully completed work step. Another
failure before that boundary stops even if timestamps or error details changed;
coordinator acknowledgement alone does not count as progress.
The saved blocker includes `escalation_reason`, and terminal output distinguishes
recovery starting, healer failure, failed repair verification, repeated blockers,
manual actions and unsafe provider state. Older stopped records are retained as-is;
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
original report and native sessions, resets both review counters, and **exits
paused before Astra**. It starts no model, performs no review, changes no project
source or Git history, and does not push. A separate `cc-focus` resumes all three
required Astra passes and both Claude passes; only then may publication occur.
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
changes and finalize a fresh report for the same stage. Both reviews remain required.
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
