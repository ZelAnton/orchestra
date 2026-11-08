# База знаний Orchestra

## Как пользоваться этим файлом

Это постоянная карта **данного репозитория**. Перед поиском по проекту сначала прочитайте
этот файл, затем открывайте только названные здесь источники истины. Обновляйте карту в той
же правке, если меняются роли, поток обработки, конфигурация, runtime-артефакты или команды.
Не путайте её с опциональной `.work/knowledge/`: та база создаётся в подключённом проекте,
накапливает опыт его прогонов и обслуживается агентом `knowledge_curator`.

## Жёсткая граница рабочей области

При диагностике Orchestra подключённые проекты под `D:\GitHub\Personal\` служат только
read-only источниками фактов: их код, очереди и `.work/knowledge/pitfalls/` можно читать,
чтобы установить первопричину поведения Orchestra. Исправления, форматирование, VCS-
операции, изменение очередей/lease и любые другие записи выполняются только в checkout
`D:\GitHub\Personal\orchestra`. Обнаруженная в чужом проекте задача не становится задачей
текущего прогона; устраняется породивший её дефект Orchestra, а внешний проект остаётся
нетронутым. Если исправление невозможно на стороне Orchestra, результатом является
диагноз и требование к внешнему проекту, но не изменение этого проекта.

## Назначение и установка

Orchestra — не приложение и не библиотека. Это комплект канонических ролевых промптов,
Claude Code runtime, полностью Codex-native runtime, адаптера Codex CLI и
кросс-платформенных launchers для автономной обработки очереди задач.
Агентские описания лежат в каталоге `agents/` и устанавливаются в
`%USERPROFILE%\.claude\agents`; provider launchers устанавливаются в `%USERPROFILE%\.claude\scripts`,
а общий runtime, конфигурация и спецификации — в `%USERPROFILE%\.orchestra`.
После изменения ролей или launcher выполните `launchers\cc-sync.cmd` (или `cc-sync.sh`),
иначе Claude продолжит использовать старую копию. Установленный в PATH `cc-sync` тоже
работает, если текущий каталог — checkout Orchestra: launcher узнаёт его по трём identity-
маркерам (`agents/processor.md`, `generate-codex-agents.ps1`, `tools/sync-runtime.ps1`) и
запускает runtime из checkout. В другом каталоге mirror-команда остаётся явным no-op; это
не позволяет случайной target-local `tools/` затенить источник Orchestra.
On POSIX, every user-facing `launchers/cc-*.sh` file is executable in the checkout, and
`tools/sync-runtime.ps1` mirrors both the canonical `.sh` name and a managed extensionless
command copy (`cc-sync.sh` -> `cc-sync`), applying the executable bit to both. After a
successful sync it reports when the mirror's `scripts` directory is absent from `PATH`;
the operator then adds that directory to the shell startup file.
An extensionless destination that exists outside the provider manifest is operator-owned:
sync fails closed instead of overwriting or adopting it.
Failure to apply the executable bit aborts the transactional sync and rolls back the
provider mirror; an unusable launcher is never reported as a successful installation.
The POSIX launcher suite also runs the queue and state transaction tests, including
concurrent writers and OS-native root normalization; their fixtures use the platform temp
directory rather than relying on the Windows-only `TEMP` environment variable.
Стратегические направления и порядок развития зафиксированы в
`LOOP_ORCHESTRA_ROADMAP.md`; это план, а не действующий runtime-контракт.
Архитектура неблокирующего human in the loop, web/Android control plane, событий и PoC
описана в `OBSERVABILITY_PLATFORM_PLAN.md`. Там же определены proposal-curation и разделение
исполняемых задач на `current` и `next_major`; это пока проектируемые, не действующие
runtime-контракты.

## Основной поток

### Instruction and knowledge style

`docs/instruction-style.md` defines the ASD-STE100 Issue 9 writing policy and its internal 80 percent acceptance measure.
New instructions and knowledge text use English unless the user explicitly requests another language.
`cycle_prompts.WRITING_CONTRACT` supplies this rule to every Codex role of cc-focus.
`role_contract` omits it for Claude roles, because Claude coding runs with it ended in `reasoning_extraction` refusals.
Claude writing roles load the same user policy through `--setting-sources user,project,local`.
Claude paired inspectors write findings, not instructions or knowledge text.
The rule preserves requirements, permissions, machine syntax, and the user's conversation language.

`tools/check_focus_instructions.py` checks measurable prose limits without executing runtime code.
It does not certify the full dictionary or semantic equivalence.
`tests/test_focus_instructions.py` checks those limits, role coverage, and saved-prompt compatibility.
`focus_pair_jobs.same_pair_prompt` accepts only known earlier pair contracts, in the plain or review-mode form.
The style revision can also change named instruction fields.
The test scope revision adds only the `full_run` and `final_gate` assignment fields.
`same_pair_prompt` preserves exact task data and saved prompt bytes.
Historical compatibility fixtures are evidence, not instructions for new work.

The shared user policy resides in both `~/.codex/AGENTS.md` and `~/.claude/CLAUDE.md`.
Keep their text identical.
It includes language, attribution, instruction style, PAUSE, and task-queue rules.

### Opt-in sequential main-branch workflow

`cc-focus review` reuses the pair, repair, publication, and CI engine without initial coding.
See `docs/focus-review.md` for selectors, the menu, and development handover.
`focus_review_scope.py` parses completed plan items and seals requirement selections. Several scope files become separate targets.
`focus_review_cli.py` validates selection arguments before ownership or providers start.
`focus_picker.py` provides an optional keyboard menu with pinned packages in a user virtual environment.
Its requirement file and all review modules are shared cc-sync assets.

`focus_review_run.py` owns isolated campaigns under `.work/cycle/review-runs/ID/`.
Each campaign has its own sessions, messages, progress, and finish-stage request.
Development and review share the root runtime lock, active process record, and project lease.
An unfinished campaign prevents a development run or another campaign.
Start requires clean published repositories and a safe development boundary.
Completed campaign evidence permits a checked transfer back to the unchanged saved development state.

`focus_review_contract.py` distinguishes existing implementation scope from the new repair diff.
Independent outer reports must cover every selected requirement with snapshot paths and checks.
Inner repair inspections retain their existing narrow scope and report format.
The normal development prompts and report schemas stay unchanged.
Later repairs requeue earlier targets when recorded coverage paths or their directories change.
This uses declared coverage, not a complete semantic dependency graph.

A target without repairs checks the existing remote revision and its CI policy without a commit or push.
Other targets use normal publication of reviewed changes in affected repositories.
`ReviewMode.prepare_next_stage` selects the next review target before the atomic state save.
The transition cannot leave a campaign in an initial coding phase.
Campaign corrections also restart Pair A, never coding.

The final `report.md` and `result.json` link target evidence without rewriting source-plan completion history.
In a review campaign, the decide step of each outer pair round saves its decisions in `pair_decisions`.
A target record keeps these references and the `pair_handoff` references of its stage.
`ReviewMode.finding_lines` joins the decisions and executor results by `source_id`, and the report
ends with the deferred findings. A target that was reviewed again also lists the deferrals of its
earlier records in `review_run.history`.

`launchers/cc-focus.sh` and `cc-focus.cmd` delegate to `tools/focus-runtime.ps1`.
This is a separate operator-selected profile, not a queue processor variant.
The wrapper requires Python 3.10+ and a ProcessKit root with inherited stdio.
`tools/cc_focus.py` owns CLI arguments and lifecycle; `cycle_state.py` owns durable
state, Git fingerprints and the shared processor lease; `cycle_transport.py`
owns Claude print/Codex app-server sessions and operator approval callbacks;
`cycle_workflow.py` owns phase barriers, review counters, recovery and exact-SHA CI.
It also requests one frozen report-only correction for an unchanged executor that
wrongly carries cumulative `substantial=true` into a zero-edit invocation.
`cycle_transport.repairable_executor_accounting` recognizes only that otherwise
valid report; strict parsing is unchanged and the original is never rewritten.
`focus_pairs.py` owns paired review phases, agreement, arbitration and publication
seals. `focus_pair_execution.py` owns Pair A executor closure, retained partial
reports, exact-result replay and bounded continuation of outstanding assignments.
`focus_pair_repair.py` owns the B/final inner repair gate,
risk choice, two static passes and deferred targeted tests. `focus_repair_evidence.py`
owns exact test-result replay and independently audited historical journal deltas,
without excluding any files from candidate snapshots. `focus_pair_jobs.py` saves and joins independent reader jobs;
`focus_pair_view.py` creates frozen source views and exposes bounded search/read/list/diff
through a Codex dynamic tool or Claude stdio MCP. `focus_pair_protocol.py` owns strict
reports and exhaustive dispositions; `focus_pair_profile.py` owns pair identities.
`focus_snapshot_archive.py` stores frozen bytes in `source.zip` under each view, with
logical names and hashes in the unchanged inspector interface. Empty source directories
remain provider working directories; runtime copies no longer enter project/source scans.
On run/resume, `Cycle.prepare_snapshot_storage` archives legacy loose views under the
lease after pause/input guards, verifies all bytes and keeps original sealed manifests.
A per-view receipt precedes retirement of verified duplicates, allowing crash recovery.
Unknown/changed files, symlinks or unsealed loose copies are preserved and block.
Read-only status and inspection never compact storage. The module is a shared cc-sync
asset; `tests/test_focus_snapshot_archive.py` exercises storage and migration boundaries.

`focus_brief.py` owns the project brief, a shared cc-sync asset. `cc-focus brief set|restore|clear|show`
run before the runtime lock and change no workflow state. `brief apply` runs under the normal admission.
The pointer `.work/cycle/project-brief.json` names an immutable copy `.work/cycle/briefs/<sha256>.md`.
Each stage start records `state["project_brief"]` with the iteration and the hash. A new pair stores
`project_brief_sha256`, and its readers, writers, inner readers, and final gate use that hash.

The code role, the pair executors, and all pair readers except the complexity assessor and the evidence
auditor get `project_brief` with the text and `PROJECT_BRIEF_RULE`. A brief correction has
`brief_change: true` and reaches the roles only as `project_brief_notice`. `brief-drift` and `brief-path` start no healer.
`tests/test_focus_brief.py` exercises import, capture, delivery, application, and integrity.

`focus_review.py` retains historical serial-report compatibility. `focus_readonly.py`
owns the bounded legacy inspector and shared Codex inspection feature overrides:
the isolated `code_mode_host` must remain enabled for Code Mode-only models, while
shell/execution, direct image reads, delegation and external tools stay disabled.
`cycle_transport.py` pins read-only sandboxing at process, thread and turn scope
and rejects every reader request for command/file-change approval. A native-host
smoke must exercise list/read/diff and denied writes; a fake dynamic-tool callback
alone cannot detect a disabled Code Mode host. `focus_pair_jobs.py` archives a
completed incomplete report before retrying with a new native marker in the same
session, without invalidating a newer turn or a completed peer.
All are shared cc-sync assets.
`cycle_prompts.py` is the canonical fixed profile and prompt source, independent
of generated agent roles. Its `role_contract` always includes the shared
`COMMAND_EXECUTION_CONTRACT`, including paired executors, for both providers and
fresh/resumed invocations. Permitted checks run synchronously; shell detachment and
estimated-duration sleeps are prohibited. Resumed work reuses its completion mechanism,
or immediate status inspection followed by checks no more than 30 seconds apart while
running. Role, operation and report-only restrictions still govern whether checks may run.
These runtime files are shared cc-sync assets.

Codex strict structured output refuses some JSON Schema keywords with HTTP 400, for
example `uniqueItems`. Report schemas use only the keywords in `STRICT_KEYWORDS` of
`tests/test_cycle.py`. Each object requires all its properties and forbids other
properties. The tests check every role and the request that the transport sends.
A rule that needs another keyword is an explicit validator check, for example unique
coverage paths in `validate_coverage`.

`focus_publication_scope.py` owns explicit file selection before development publication.
`reconcile --publication-scope FILE` prepares a fingerprint-bound plan without accepting it.
`reconcile --apply-plan FILE` accepts that plan and pauses before Pair A.
Excluded changes become protected work without changing files, HEAD, or staging.
The selected paths are an exact limit, not a union with inferred changes.
The correction archive preserves the earlier state, findings, resolutions, and evidence.

Multi-repository publication projects the selection into each affected member.
New iterations clear the selection.

Outer frozen inspectors expose `__review__/publication.json` before verification dispatch.
The final pair receives only factual publication metadata, not earlier review reports.
Executor assignments also contain the planned publication manifest.
The first accepted code report replaces a provisional coordinator label.
Subsequent reports cannot relabel the stage or override an operator selection.
See `docs/sequential-cycle.md` for selection commands and whole-file ownership limits.

Inner repair views expose the same manifest for all planned paths.
In B, inner repair views also copy the coding report and the pair history.
A history copy adds an `exposed` copy name to each record reference, except view manifests.
Repair views also hold `__review__/gate.json` with the records of the open gate.
Evidence copies use indented JSON, and `ViewInspector` shows any line longer than 6,000 characters in parts.
A page has at most 30,000 UTF-8 bytes, and a clipped page names the next offset.

`RepairReview.renew_legacy_view` renews an inner or audit view without a `publication` pointer or `__review__/gate.json`.
It keeps jobs with a result, a report under correction or a recoverable Codex turn.
It marks them with `frozen_view`, and independent jobs keep sessions in the old view directory.
For such jobs, `same_saved_job` ignores only the evidence fields, and the job takes the current prompt.
A completed negative audit verdict therefore stays in force.

`CODE_IMPLEMENTATION_CONTRACT` gives the code role its implementation and verification instructions.
It excludes reviewer-only inspection, discussion, arbitration, and repair schedules.
The code role retains the common project boundaries, report schema, counter rules, and required later reviews.
The initial user message and the system prompt addition for Claude use this contract.
Reviewer roles retain `PAIR_CONTRACT`.

This separation removes conflicting role instructions. It does not prove why a provider refused an earlier request.

Claude writing roles use `--append-system-prompt` to keep the standard Claude Code instructions.
The named `cycle_worker` has an empty prompt and no memory field, which requires Claude Code 2.1.281 or later.
This selection still overrides any configured default agent.
Read-only roles keep their custom prompt and tool restrictions.
Saved native conversations can retain the earlier system prompt until compaction or an explicit new session.

`focus_diagnostics.ClaudeTrace` records message counts and input sizes from public usage counters.
The input total includes new tokens, cache creation, and cache reads.
Repeated frames for a retained message ID do not increase its count.
The bounded diagnostic keeps first, last, and peak input sizes, plus the refused message's size when available.
Missing counters remain unknown.
These measurements do not establish why the provider refused a request.

The diagnostic retains 128 message records and the refusal's response block types.
Recent tool inputs and results have size and hash metadata, without their contents.
New transport records include requested model, effort, session reuse, and instruction hashes.
`cc-focus diagnose --native-log PATH` reads known instruction attachments from a matching native session and project.
It reports hashes and selected term locations, without exporting instruction text or assistant content.
Term matches are inspection aids, not evidence of a causal instruction.

`focus_project.py` discovers a project outside its member repositories, either
from direct Git children or `focus-project.json` (version 1, repositories: relative
paths). Member roots must be nonoverlapping primary Git main checkouts without
symlink escapes. `focus_publication.py` applies one coding/review cycle to their
combined diff, with separate policy, commit/push reconciliation and CI per changed
repository. Unchanged repositories are never publication targets. These two modules
are shared cc-sync assets; `tests/test_focus_project.py` covers their integration.

`instruction_entries` in `focus_project.py` lists `AGENTS.md`, `CLAUDE.md`, and `.claude/CLAUDE.md` of the root and of each member.
A relative link to a regular file of the same source also gets `target`.
`ProjectCycle.context` gives the list and `PROJECT_INSTRUCTIONS_RULE` as `project_instructions` to the main roles and the pair writers.
A new project pair stores `project_instructions_version: 2`, and inner readers, the final gate, and the evidence reader copy it.
`view_instructions` in `focus_pair_view.py` gives each reader of a marked pair the list of its frozen view.
`SplitLayoutTests` in `tests/test_focus_project.py` cover a root with code, documentation, and plan members.

`focus_parallel.py` handles the members in the manifest key `parallel`. Each stage records them in `state["parallel"]`.
`sync` fast-forwards a clean parallel member at a stage transition and at a run start before coding. `admit_parallel` then takes its entries again.
Before a push, remote main must contain the base. After a push, it must contain the published commit.

`integrate` merges the stage commits with remote main through `merge-tree` and `commit-tree`, saves `parallel_integrations`, and moves the base.
`resume` completes or undoes an open record before any publication check. `OPERATOR_CONTEXT_BLOCKERS` start no healer.
New pairs store `project_instructions_version: 2` and `parallel_repositories`. `tests/test_focus_parallel.py` uses a second clone as the other writer.
The `publish` and `heal` roles also get `PARALLEL_PUBLICATION_RULE`, and each publication target names `parallel`.

`focus_resolve.py` handles the manifest key `resolvers`. `parallel_config` reads `parallel` and `resolvers` in one read.
Each stage saves both, in `state["parallel"]` and `state["resolvers"]`. `integrate` reads the conflict entries of `merge-tree`.
`classify` accepts only a text conflict at one path that a rule covers. `resolve` then runs the rules in a worktree under `.work/r/`.

The record step `resolving` has `"result": None`. `resume` removes its worktree and the record, and the next integration starts again.
A failed removal keeps an entry in `state["resolver_cleanup"]`. `advance_stage` keeps it, and `retry_cleanup` removes it later.
At a stage start, `retry_cleanup` also removes other directories in `.work/r/`.

`run_contained` in `focus_commit.py` gives a command the stop, heartbeat, and containment of `run_git`. `tests/test_focus_resolve.py` covers the resolvers.

For a `reported-blocker`, `heal` first calls `catch_up_parallel`, one time for each signature and at most `CATCH_UPS` times in a stage.
`focus_parallel.catch_up` fast-forwards a parallel member to remote main when HEAD is in remote main and no remote change touches a local path.
It saves an integration record with `catch_up: true`, and `resume` moves the base. `move_base` accepts a state without a reviewed snapshot.

`after_catch_up` updates HEAD, the index, and the moved paths in `last_snapshot`, and starts the open pair again with `pair_obligations`. `resume_catch_ups` runs at each pass of the run loop.
If a member moved, the blocked step runs again without the healer. `CatchUpTests` in `tests/test_focus_parallel.py` cover it.

`CLAUDE_COMPACT_WINDOW` in `cycle_prompts.py` is the compaction window of every Claude role, 400,000 tokens.
`Transport._claude` puts it into the environment and `--settings` as `CLAUDE_CODE_AUTO_COMPACT_WINDOW`.
Before each launch, it writes the recovery copy `<store>/prompts/<role>.txt` with `readable_prompt`, and `remember` adds delivered operator messages.
After `role_contract()`, the system prompt gets `COMPACTION_RULE` with this fixed path, or `READER_COMPACTION_RULE` for a pair reader.
Thus a resumed session keeps the same system prompt, and `role_contract_sha256` does not change.

`focus_pair_view.py` serves the recovery copy of a Claude reader at the reserved path `__runtime__/prompt.txt`, through `read` only.
`freeze_view` refuses a project file at this path with `pair-input`.
`ViewInspector.search` finds literal text with the exact name rule of `read` or the prefix rule of `list`.
It skips links and binary files, stops at `PAGE`, and keeps up to `TEXT_CACHE` bytes of verified text.
`open_archive` opens `source.zip` once for each call.

`VIEW_TOOL` in `focus_readonly.py` is the tool of the frozen view. `READ_TOOL` and the legacy `Inspector` do not have search.
`role_contract()` adds `READER_SEARCH_CONTRACT` only for `PAIR_READONLY`. `_STYLE_TEXT` maps both earlier `inspection` texts to the current text.

`new_pair` removes the `PAIR_A_WRITERS` sessions. `pair_writer_context` adds `stage_handoff` with the absolute paths of the `pair_handoff` records.
Executor records and conclusions have `phase` and `round`. A repair seal has `phase` and `pair_round`, because its `round` counts inner reviews.
`selected_refusals(correction=True)` skips all `PAIR_WRITERS`.

`ClaudeTrace.count` counts each message ID once, and its `usage_totals` go into `invocations/<id>/usage-<attempt>.json`.
`usage_summary` gives the totals of one iteration for `cc-focus status`. `window_ignored` sets `window_exceeded_without_compaction` in diagnose.
`tests/test_focus_context_budget.py` covers the window, the recovery copy, usage records, writer sessions, and search.

`Cycle.wait_ci` calls `later_ci` for a red parallel commit, and also for one without any CI record.
The second case happens, for example, after another writer merged the stage commit. Both need two equal green polls.
`later_ci` restores the "ci" progress operation after its fetch. Its `later_state` names remote main in a timeout.

`PairedReview.pair_instruction_context` raises `instruction-version` for an unknown `project_instructions_version`.
`RUNTIME_VERSION_BLOCKERS` routes it to `runtime-version`, and no healer starts.
Unless publication started, the message names the `cc-focus correct` form of the current run, with `--review-run` in a campaign.

`focus_reconcile.py` owns explicit operator handover of changed shared context and
protected member files; it is also installed by cc-sync.
`focus_publication_recovery.py` provides the separate operator-only
`reconcile --publication --plan-out/--apply-plan` mode for an already-pushed
protected scope. It pins state, snapshot and live remote HEADs, rejects content,
staging, destination and history drift, and adopts only the exact published
protected paths. It preserves original baseline HEADs and all Git/source state;
adopted file baselines use the original commits, not the expanded current HEAD.
The checksummed correction archives the prior state/plan and pauses the same task
before Opus with all review streaks and publication/CI credit cleared. No model
or Git write runs during acceptance. This shared cc-sync asset is covered by
`tests/test_focus_publication_recovery.py`; normal reconciliation stays unchanged.
`focus_commit.py` owns publication Git writes after a read-only Luna preparation.
It is a shared cc-sync asset. Exact reviewed file names go through literal NUL
pathspecs and `commit --only`, preserving unrelated staged, unstaged and untracked
work. Git/hook processes reuse transport containment, stop and lease heartbeats.
`Cycle.validate_publication_commit` checks protected work/index and every new
commit's path scope (not just the final net diff); merge history is rejected.
Project publication validates all local commits before the first push and again
before each remaining member. Pushes name a verified SHA and pinned push URL,
disabling automatic tags and recursive submodule publication.
Prepared subjects are sealed in `publication_prepared`, so interrupted Git work
can resume without another model call. New publisher attempts must leave their
entry snapshot unchanged; legacy cached publication artifacts still pass the
ordinary scope and remote reconciliation. Publication scope manifests and raw Git
logs live in the cycle's `publication/` directory, per member for projects, and
their paths are supplied to the publisher/healer. A post-commit `protected-index`
failure can identify extra committed protected files despite an empty staged diff;
retry neither adopts those files nor rewrites an already-published commit.
The iteration retains `publication_paths` across renewed reviews/CI fixes, including
files restored to their original bytes. For legacy state only an already-certified
published SHA can supply historical scope; an unconfirmed local commit cannot.
`focus_progress.py` renders bounded actual provider events and a 15-second activity
heartbeat, persisting `.work/cycle/progress.json` without raw commands or reasoning.
`focus_output.py` renders public message deltas, actions, command results and errors
in live mode (the CLI default); `--output compact` disables these payloads. It
neutralizes terminal controls, caps per-item display, deduplicates recent streamed
and final snapshots, and excludes reasoning/protocol envelopes. Transport logs keep
the original events, including trailing stderr; logs and live payloads can contain
secrets and must not be treated as redacted. A reduced Claude tool record and a rejected
oversized line are the exceptions described below.
`focus_control.py` owns addressed stop requests, run identity, acknowledgement and
exact-ProcessKit-run emergency cleanup. The public command is now `cc-focus`;
each provider has its own durable ProcessKit run address, including on weak
process-group backends where the root's container cannot cover another group.
Internal `cycle_*` modules, `.work/cycle/` and old invocation markers are retained
to resume existing sessions without migrating another project's files.

`/finish-stage` and `cc-focus finish-stage` schedule a pause after the current stage's publication and CI.
`finish-stage.json` stores the request in `.work/cycle/` and binds it to the iteration, independent of the run identity.
`stage-stop.lock` serializes requests with the durable transition to the next iteration.
The command starts no provider and changes no cycle snapshot, review credit, or approval.

The active run must advertise `supports_finish_stage` before the command can schedule a pause for it.
It also works while processing is stopped. The operator must then resume processing separately.
The `cancel` terminal argument and CLI `--cancel` flag cancel only the pending stage pause.

`Cycle.next_stage` saves `stage_completed` and pauses before it increments the iteration when a request exists.
The state retains the task, publication record, and CI result for the terminal panel.
The terminal caches the stage-pause request for one second. Panel formatting performs no file reads.

An explicit resume checks the publication again and advances without repeating the completed CI gate.
Review reset clears the completion record and keeps the pending stage request.
All published member repositories must finish their CI gates before the project pauses.

After the pause, `Cycle.next_stage` calls `assert_stage_base` instead of `assert_publication_current`.
It accepts pushed commits on top of the published commit as operator work.
Main must contain the published commit, and local main must equal remote main.
Uncommitted paths must be protected work, and protected content and staging can change during the pause.
The check accepts changed project context outside the member repositories.
`ProjectCycle.assert_stage_base` validates the repository set and checks each other repository with a changed main.

At that boundary, `handle_block` gives every blocker the reason `stage-boundary` and starts no healer.
This also applies to `remote-query-timeout` and `remote-query-failed`, which otherwise go through recovery.
The runtime would check a healer result against the finished stage, and a provider may not change main.

`ReviewMode.next_stage` uses the same check after a review stage pause.
Then `ReviewMode.advance_stage` queues a completed target again when the new baseline changes its paths or directories.
`hand_back` always uses `assert_stage_base` for the last review publication.
`create_run` and `hand_back` first validate the repository set of the development state.
At another development boundary, `create_run` uses `assert_checkpoint_base` for pushed commits.
Outside a completed stage, both reject changed project context outside the member repositories.

`tests/test_focus_finish_stage.py` covers completion, cancellation, restart, control priority, and concurrent requests.
Plan exhaustion retires the request, so a later handoff does not inherit it.

`focus_terminal.py` owns the optional standard-library TTY composer, bounded
scrollback, key decoding, terminal restoration and redirected-output fallback.
It caches wrapped output at the current width and the visible log window, so typing
in old scrollback does not rescan history. Cached lines stay bounded by the retained
3000 lines plus one tail entry; output/scroll/resize invalidate the visible window.
Only changed terminal rows are emitted, unchanged status ticks do not redraw, and
provider-text sanitization runs outside the input lock. Session reuse is unchanged.
Pending approvals have a separate persistent, scrollable request view, opened by
`Interaction.approve` and cleared on answer/cancellation. It shows command/cwd/reason
and the full sanitized payload independently of log eviction. `/approval` and `/log`
switch views without answering; only explicit `/approve` or `/deny` grants/refuses
the operation. Page keys navigate the current view; Ctrl+Home/End jump to its ends.
POSIX SGR/X10 mouse-wheel input never enters the composer; reporting modes are
restored on exit. Incoming output adjusts the log offset to preserve the visible
history, subject to the existing bound. Cached approval wrapping keeps typing cheap.
The footer exposes navigation and log position. A horizontal rule separates the
log/request viewport from the footer above the composer; four-row terminals omit
the rule to retain one visible log row. Interactive `Progress` disables
periodic log heartbeats while maintaining panel timers and durable progress; plain
output keeps its timed activity lines. Actual events continue to enter the log.
Explicit command replies and input errors use `Interaction.respond` to reveal the
latest log while preserving the pending request; `/approval` returns to it. Ctrl+C
clears incomplete keyboard/mouse escape input before issuing `/stop`, while pasted
control bytes remain non-executing. A fresh escape packet also discards an incomplete
one, allowing paste-end markers to restore normal input. Terminal regressions cover
these boundaries.
Cursor keys accept both normal CSI and application-mode SS3 encodings. Unsupported
CSI/SS3 packets are consumed through the final byte, with bounded buffering, so
their suffixes cannot become composer text. Native mouse reports scroll the active
view without changing the draft or command history; arrow-key encodings still
select command history because they do not identify a wheel event.
`focus_status.py` projects workflow state into an eight-line panel separated from the
log, with a three-line compact layout for narrow/short terminals. It shows the
task, actual role/model, seven-phase timeline, review streaks and completed totals,
invocation/event timers and priority operator notices. `/status` retains full
details. Timer ticks run once a second without disk access or history scans;
message notices use an iteration-scoped cache refreshed on delivery changes.
`task` is nullable display metadata from the existing coordinate/code report:
plan-relative path, selected stage ID and title. Paths must resolve inside the
project; later reports cannot switch the current iteration's task identity.
Older reports can omit it, and invalid metadata cannot block the workflow.
Provider output schemas require the nullable field; the saved-report parser keeps
the original required fields. Unknown legacy titles use `Задача N` until a valid
report supplies one. No additional model call or stage-selection authority is added.
`display_reviews` counts validated completed passes separately from the existing
gate counters; `display_review_events` keeps the latest 12 outcomes/reset reasons.
Interrupted/rejected passes earn no completed credit. Legacy totals remain marked
as lower bounds. Metadata is archived and reset on the next iteration; CI display
is bound to the publication SHA. All display fields are observational and do not
grant review, publication or CI credit. `focus_status.py` is a shared cc-sync asset;
`tests/test_focus_status.py` covers projections, workflow transitions and rendering.
`cc_focus.runtime_fingerprint` records the Python bundle at import. A parked UI
checks it after an epoch and before resume/correction/message-resolution commands.
Changed or missing sources set `Interaction.runtime_notice`, visible over blocker
activity in both layouts, and prevent a stale processing epoch. The operator exits
and starts a new process; providers are never hot-reloaded or automatically restarted.

`focus_input.py` is the single input owner for slash commands, explicit approvals
and active-invocation targeting. `/exit` requests a safe pause and closes the terminal
after ownership is released; empty-input Ctrl+D uses the same command. `/resume`
continues a stopped workflow and retries an escalated blocker when needed; the
noninteractive `--retry` flag and message-delivery retry commands remain available.
Repository admission runs before opening the interactive composer, so an invalid
root or detached HEAD exits with a visible shell diagnostic instead of parking at
`starting`. The check is repeated before ownership on initial entry and UI resume.
Cycles in disjoint projects have independent conversations. A project cycle holds
its own lock/lease plus every member's lock/lease, excluding overlapping project,
single-member and queue-processor runs. Provider processes inherit all POSIX lock
descriptors. Member `project-owner.json` records also require confirmation of the
parent provider's exit after a crash; they are removed after confirmed shutdown.
Member `status` identifies the owning project; member `stop` refuses to target a
stale independent member run and directs the operator to the parent project.
`--handoff` only imports context. Every member still requires Git `main`; detached
colocated Jujutsu checkouts are not admitted or automatically converted.
Handoff is optional on initial and resumed runs. The current project plan and
instructions govern stage selection; an imported snapshot is historical context.
`Project.handoff_sources` identifies imported source paths outside member Git
repositories, excluding shared AGENTS/CLAUDE/PLAN files, the selected task's plan
and the membership manifest.
`Cycle.snapshot` and `Cycle.changes` omit these disposable input paths from work
comparisons; project scanning does not read them again. Old baseline, pending and
result snapshots are projected the same way without rewriting immutable artifacts.
Deleting or updating an imported loose source cannot block coordination, invalidate
review credit, prevent cached-result recovery or become a publication target.
Files in Git and unimported shared context keep their existing protections; the
checksummed imported copies remain protected. New runtime behavior takes effect on
the next process launch, without changing an already running consuming cycle.
Project snapshots prefix file paths and store HEAD/index per repository, retaining
the existing single-repository snapshot/state format. Membership is pinned across
resume. Files outside member repositories are sealed read-only context; they cannot
be implementation changes with no publication owner. Per-member lease owner intent
lives in the parent state; per-member CI artifacts live under
`.work/cycle/repositories/<relative-path>/ci/`. Publication targets pin remote and
push URL before any publisher call. Partial commits/pushes are reconciled separately
before retry; all changed repositories must finish publication and CI before the
next iteration. The aggregate publication hash is display identity, never a Git SHA
sent to a remote or CI API. Cross-repository pushes are not atomic.
An explicit retry refreshes every published member's CI deadline consistently.
New reviewed fixes after a partial push reopen that member's publication; an old
confirmed push cannot hide remaining changes. A PAUSE file at the project or any
member is honored at the normal safe boundary, including stopped-state recovery.
`focus_messages.py` stores hashed message identity
and delivery state under `.work/cycle/messages/ITERATION/`; uncertain delivery is
an operator pause, never automatic healing or implicit resend. Codex delivery uses
asynchronous `turn/steer` replies correlated alongside normal protocol events.
Claude keeps stream-json stdin open and sends queued input after the current
response, requiring its replay acknowledgement and its own result; fix counts
from earlier responses are retained. Accepted stage messages enter later context.
Review intervention clears earlier clean credit; Fixing-review intervention returns to
Sol. Publication/CI cannot be steered. Pending delivery prevents phase advancement
and cannot be bypassed by a cached result, stopped-stage correction or old-report
recovery. The terminal may remain parked after releasing runtime ownership; external
stop distinguishes a parked UI from a still-running provider. Root termination
holds the control-identity lock to avoid killing a newer epoch in the same UI.
Before a live parked UI is replaced, admission requires confirmation that its
recorded provider exited; losing the local lock is not itself proof of leaf exit.
The model-free `messages`, `retry-message --id` and `discard-message --id` commands
support non-TTY recovery. All three new modules are shared cc-sync runtime assets;
`tests/test_focus_terminal.py` adds protocol, lifecycle and POSIX PTY fixtures.

One protocol record has at most 8 MiB. After a file edit, Claude repeats the whole original
file in the `tool_use_result` field of the next `user` record. The runtime does not use that field.
`cycle_transport.py` reads such a record up to 128 MiB through a 1 MiB buffer and removes the field.
The log keeps the reduced record and `tool_echo_removed_bytes`. Any other record over 8 MiB
stops the invocation with `provider-output`. The log keeps only its size as `rejected_bytes`.
For a line over 128 MiB, each part over 8 MiB gets its own `rejected_bytes` frame.

Profile 8 flows from Luna/xhigh coordination and Opus/xhigh coding to pair A
(Opus/xhigh + Sol/xhigh), pair B (Astra/xhigh + Opus/max), and the independent final
pair (Opus/max then Fable/xhigh). A/B initial readers run concurrently on one frozen
candidate; the final initial reports stay hidden from each other until both finish.
Two exchanges seek endorsement of the exact proposal hash; a separate Astra/max
arbiter binds remaining disputes. Reviewers, arbiter and complexity assessor never
edit, build or test. In pair A, after agreement, Codex `gpt-6-sol/high` assesses every
accepted assignment and selects Opus/high or xhigh (maximum of the batch).
The sealed assessment binds the exact candidate and all assignment details; restart
retains it and its chosen effort. Severity and repair complexity are independent.
Only the selected Opus executor fixes or verifies assignments with closure evidence.
Pair A `pair_fix`/`pair_cleanup` (including `_high`) may build and run assigned
targeted checks now; the B/final inner gate must not leak into its instructions.
Every source ID has an outcome; `deferred` is representable but never closes work.
`focus_pair_execution.py` seals partial reports and continues the same pinned
executor on missing/deferred/incompatible closures without redoing completed work.
No advance or outer review occurs until all obligations close. Later edits invalidate
earlier verified outcomes; substantial changes survive a check-only continuation.
Two stalled continuations route to recovery; disputes preserve unfinished work for
arbitration. Exact cached originals, including legacy executor prompts, can replay
after restart/no-op healing; current snapshots, correction/message history and
assignment/complexity bindings prevent stale adoption. Reports are immutable and
each execution batch has its own artifact namespace. The panel/status exposes
closed/remaining counts. `tests/test_focus_pair_execution.py` covers this compatible
Profile 8 correction; it adds no migration or new review credit.
Executor counters and `substantial` always describe the current invocation. A
check-only continuation cannot inherit the batch's flag. Exact rejected results
can be restored for report-only correction, preserving their checks/resolutions;
the runtime retains the earlier cumulative impact and late static-review credit.
The correction has its own durable marker in the same native session, cannot edit
the candidate or invent counters, and does not repeat builds/tests. An interrupted
correction resumes that marker even after recovery clears pending. Changed source,
instructions, correction revision or proof cannot be silently adopted. Invalid
corrections use normal recovery instead of another automatic correction loop.
`tests/test_focus_executor_accounting.py` covers fresh and already-blocked results,
restart/quota, exact proof retention, and both late repair phases.
Every pair repeats after significant findings (blocking or critical/high/medium);
low nonblocking findings are fixed then advance without another OUTER review.
B/final always fix with Opus/xhigh, which selects self-review in its native session
or independent Opus/xhigh + Astra/xhigh based on actual patch risk. Contracts,
storage, security, concurrency, interacting components, algorithms or uncertainty
require a pair; the mode never downgrades within a batch. Both forms use immutable
repair diffs and inspection-only tools, no builds/tests. Two clean passes on the
exact cumulative repair are required before a separate targeted test invocation.
Any repair resets credit. Test defects restart repair/review/test and force pair
mode; infrastructure-only failure preserves unchanged static credit. A required
diagnostic cannot be skipped. Only then may significant repairs return to the
expensive outer pair, or minor repairs advance. Shared `focus_pair_repair.py` owns
this state machine and its seals; `tests/test_focus_repair.py` covers it.
Infrastructure reports can retain verification obstacles but never candidate defects;
they do not close the test gate. Exact saved results that predate a runtime archive
migration get at most one automatic retry with preserved static credit. The next test
prompt includes retained successful checks and unresolved obstacles; only outstanding
checks and prerequisites need rerunning. New/repeated failures use normal recovery.
Test invocations put evidence in their JSON reports, without editing journals.
For older completed tests, `focus_repair_evidence.py` can preserve the two original
static passes only through a separate read-only Opus/xhigh audit of every changed
documentation hunk. Full before/after hashes, the original test receipt and the
audit are sealed; behavioral docs, expected results, uncertainty, added/deleted or
nonregular files and VCS changes do not qualify. Publication retains actual journal
bytes, and later changes invalidate the exception. Tests may report `verified` for
a fix only by citing an earlier sealed `fixed` resolution; original reports remain
intact. Retry authenticates and reuses the exact completed result, including legacy
test prompts, never healer credit; consumed failures cannot replay as fresh checks.
No-op healing preserves pending classification. `tests/test_focus_repair_evidence.py`
covers these boundaries and restart/recovery. This does not change Profile 8.

The test scope rules are in `COMMAND_EXECUTION_CONTRACT`, so every cc-focus role receives them.
Each role runs only the checks that cover the current changes.
A full run checks more than these changes.
An example is a repeated run of all mutants after a local correction.
The first run of the new checks and mutants of a stage is not a full run.

Only a Pair B `full_suite` assignment and the final gate permit a full run.
Each stage permits one Pair B run, and `PairedReview.full_run_used` enforces this limit through `validate_decisions`.
The same method limits the final gate to one run in each stage.

`accept_repair_result` records each passed or failed full run in `pair_full_runs`.
In the open batch, it also sets `full_suite` to false, so later tests run only targeted checks.
`advance_stage` removes these records.

Only the initial final-pair reports have the `final_gate` field.
`finish_pair` calls `start_final_gate` after a passed final pair.
The gate needs a request and publication paths.
An earlier final gate or a passed full run of this candidate prevents it.
The gate is a repair batch that starts at the test step without static passes.
`direct_gate` names this state.

A passed gate seals publication.
A defect starts the normal repair loop and a new final pair.
`final_gate_row` removes the gate request from carried obligations.
This rule also applies after a restart of the reviews.
`tests/test_focus_repair.py` covers the gate and the Pair B limit.
`tests/test_focus_pairs.py` covers the protocol, the schema, and saved jobs from the previous contract.

Unexpected substantial repairs require renewed inspection of the same pair.
No fixed OUTER clean streak or B→A return remains. With no accepted assignments, skip
assessment/execution. `pair_completed` retains conclusions, including post-cleanup
snapshots. Profile 1–7 migration restarts unpublished reviews at A, carries open
findings and preserves already-started publication/CI seals and all working files.

`pair_review`, per-job sessions/reports and `pair-reviews/` artifacts make a completed
peer reusable while only its interrupted partner resumes. Both ProcessKit leaf
addresses live in `active.json.provider_runs`; cleanup joins both before any writer.
Group input is a durable instruction to both, invalidates endorsements and restarts A.
Malformed/incomplete reports get two author corrections without rerunning the peer;
rejected versions remain sealed. A partial disputed fix goes to the arbiter on a new
frozen view, then requires fresh independent inspection before any clean credit.
`--retry` resets participant wait deadlines without discarding completed peer reports.
Early context is compact public decisions/checks with original evidence references;
final initial inputs omit prior runtime judgments and use fresh sessions. Inspection
tools can read only the frozen manifest, not hidden state/logs or arbitrary paths.
Source documents are not semantically redacted. Late
fix invocations cannot test until the inner static gate completes. Panel and JSON
status expose the inner mode/reason/clean count and active nested reader jobs;
retry/new-session handling includes those jobs. Native self-review uses the original
cwd with the frozen tool manifest, independent reviewers use frozen-view cwd.

Profiles 1–7 migrate under ownership, archive former state and discard old review
credit. Unpublished reviews restart at A; already-started publication/CI retains its
original seal. Coding, coordinator, publisher and healer sessions are preserved.

`tests/test_focus_pairs.py` covers concurrency, interrupted peers, independent final
inputs, consensus/arbitration, closure and returns; native fixtures verify model,
effort and bounded tool profiles. Legacy final tests retain artifact compatibility.

Opus uses the `opus` CLI alias, validates its family at initialization and pins the
resolved version throughout each invocation and retries.

Recoverable blockers receive one Astra/xhigh recovery attempt before an operator-visible stop.
The `heal` role has its own persisted conversation, separate from coding and all required
review roles. Technical failures, including remote Git queries, generic provider
API errors and model-reported requests for human intervention go to that role.
The healer verifies the diagnosis and existing authorization, performs necessary
engineering repairs within the task/member scope and tests them before escalating.
Product authentication code is not the agent's own runtime/account permissions;
protected existing work and actual permission boundaries remain enforced.
A failure at the transition after a completed-stage pause stops for the operator instead.

Explicit account-access and approval barriers bypass model recovery.
Structured Claude safeguard refusals also bypass this recovery.
`cleanup-incomplete` and `turn-active` prevent the safe start of another provider.
The blocker records `escalation_reason` for manual action, unsafe provider state,
provider refusal or an unavailable provider. Other values name a failed healer, failed post-repair verification, a repeated blocker or a stage transition.
Terminal output explains whether recovery starts or why human action remains.

`brief-input` names a project brief blocker.
`runtime-version` names a saved record that needs a newer runtime or a repair.

Claude-generated API errors (`assistant`, `<synthetic>`, `is_api_error_message=true`
and a matching session) are classified before model pin validation.
`oauth_org_not_allowed` becomes `claude-access-denied`.
Structured safeguard refusals, quota refusals, and transient server failures have separate paths, described below.
Other marked synthetic errors become `claude-api-error` with their provider detail.
Access refusals retain the provider detail and identify the active login and subscription/payment status as checks for the operator.
The word "organization" in an error does not establish managed billing.

`cycle_transport.claude_refusal` describes `stop_reason=refusal` after the transport validates the response source and session.
It uses public explanation text, categories, and supplied request and message identifiers.
It does not copy thinking blocks or infer a refusal from quoted error text.
`Cycle.handle_block` records `claude-refusal` with `escalation_reason=provider-refusal`.
It preserves partial work and starts no healer or other model.
Before this blocker, `Transport.restart_refused` can start one new conversation, as described below.
The operator guidance distinguishes request inspection from optional support contact for a suspected false positive.

`focus_diagnostics.ClaudeTrace` also joins streamed refusals with their message and request identifiers.
The transport stops on a matching streamed refusal before accepting a later native continuation.
Each Claude invocation saves bounded metadata in `claude-diagnostics.json`.
`cc-focus diagnose --invocation ID` reads this metadata from existing protocol events without a lease or state writes.
It reports loaded tool names, recent tool completion, model identity, and public refusal details.
It excludes prompt text, tool arguments, message bodies, settings values, stderr, and private content blocks.

The optional `--public-output` view uses `focus_output.LiveOutput` to display public messages and command results.
Recovery instructions prefer this view to raw provider transcripts.
Public command output can contain project data and is not a secret-scrubbing export.
The diagnostic command does not start providers, clear blockers, or grant review credit.
The module is a shared cc-sync asset, tested by `tests/test_focus_diagnostics.py`.

`ClaudeTrace.cli_events` keeps compaction boundaries, refusal notices and refusals without a fallback model.
The launch record adds `instruction_files`: path, size and hash of each loadable `CLAUDE.md` candidate.
`Transport.instruction_snapshot` hashes them before the process starts and again in the `completion` record.
`instruction_files_captured: before-start` marks new records. Older records have completion-time hashes and show unknown timing.
`focus_diagnostics.refusal_history` backs `cc-focus diagnose --refusals`.
It compares the first refusal with `last_completed_before` and reports instruction-paragraph first lines only.
That reference needs a terminal `success` result with `is_error=false` and no refusal. It is not runtime acceptance.
`ClaudeTrace` marks a result `deferred` while native tasks or queued turns remain, like the transport.
`Transport.mark_attempt` writes a `runtime` attempt record into `protocol.jsonl` before each Claude process.
The attempt and launch records keep the process directory, which names the native log of paired readers.
The launch record sets `instruction_files_enabled: false` for paired inspectors. The history then compares no files.
The launch record names the same attempt ID.
`claude_attempts` splits the log at these records. Older logs split at an event with a new session.
Only the attempt that owns the launch record gets the launch metadata. The prompt file belongs to the last attempt.
A launch record without an attempt ID can own only an attempt before the first attempt record.
`runtime_instruction_blocks` limits named prompt paragraphs to the current runtime instructions.
It also tells if a plain retry would resend the refused native conversation.
`tests/test_focus_refusals.py` covers this report, and `tests/test_cycle.py` covers the retry check.

A refused native conversation keeps its history. Each resumed request sends that history again.

`focus_diagnostics.selected_refusals` finds refused conversations that a plain retry would resume.
`saved_claude_call` takes the last attempt from `claude_attempts` on the protocol log.
It uses `claude-diagnostics.json` only when `launch.attempt` names that attempt, or when the log cannot decide.
It checks role sessions and unfinished pair reader jobs, because a pair blocker names only its group.
`cc_focus.main` rejects such a `--retry` for a `claude-refusal` blocker.
It also rejects `correct`, `recover` and `reconcile --apply-plan` when the refused conversation is a role session that they keep.
The check runs before the shared lease and starts no model.
`--new-sessions --retry` starts new conversations and passes the check.

`Transport.restart_refused` allows one new conversation after a refusal with earlier history.
Earlier history is a resumed conversation, or a completed tool exchange in the same conversation.
`Transport._claude` counts tool results and sets `history` on each refusal.
A stream that broke before its first answer completed is not earlier history.

The limit is one restart in each invocation, through `pending["refusal_restart"]`.
A refused first request of a new conversation stops for the operator.
A report-only correction, a `repair_self` review, and operator messages also stop for the operator.
`Transport._run` uses `NEW_CONVERSATION` for this restart and for a lost native history.
The final refusal message tells which limit stopped the invocation.
`tests/test_cycle.py` covers the restart and its limits.

The new conversation also gets `RECOVERY`, because the refused attempt can have changed files.
`Transport.keep_refused_attempt` keeps the launch record and the prompt of the refused attempt under its attempt ID.
`focus_diagnostics.kept_attempt` reads these files, so the refusal history keeps that attempt's role contract and prompt.
`run_jobs` copies the restarts and the refused conversations of pair participants into `refusal_restarts` and `refused_sessions`.
It also gives each pair participant the refused conversations of the cycle.

`Transport.mark_refused` records the refused conversation in `pending["refused_session"]` and `state["refused_sessions"]`.
`Transport._run` then refuses to resume that conversation and starts no provider.
`advance_stage` removes `refused_sessions` together with the role sessions.
After a restart in a serial review role, `Cycle.invoke` resets that role's clean passes and saves the state.
If files changed, it also sets `review_substantial`.

`cycle_prompts.EXECUTOR_ACCOUNTING_CONTRACT` gives pair writers the counter rules that `parse_report` enforces.
`PAIR_CONTRACT` stays unchanged, so saved reader prompts remain valid.
`repairable_substantial_accounting` and executor `changed-file-accounting` start one report-only correction.
Both apply only to `PAIR_WRITERS`. Other roles keep the blocker and their own guards.
`validate_executor_correction` then permits changes only to counters, substantial, summary and description.
For an original without changed files, it requires all three counters at 0 and substantial=false.
`Cycle.with_correction_source` marks the corrected original as consumed, so discovery after a heal cannot adopt it again.
`executor_candidate_report` rejects a failed correction when the original changed files. The heal then resets the stale pair.
`read_saved_repair_test` also skips a changed test run whose valid report claims fixes or substantial impact.
It also skips any changed test run that fails `evidence_eligible`, the prefilter of `queue_repair_evidence`.
The test step cannot accept it. Unchanged work replays, so `invoke` can correct its counters.
`invoke` starts an `unchanged-accounting` correction for an executor without changed files but with counters.
`retry_after_storage_repair` dates a corrected test run by its original invocation.
`Cycle.pair_step` clears `recovery_unverified` after accepted pair work, so a later new blocker gets a healer.
`tests/test_focus_report_accounting.py` covers these paths.

`repairable_repair_mode` starts a `repair-mode` correction for a `repair_execute` report
that lists risks but sets self mode. `validate_executor_correction` then permits changes
to `repair.mode`, `repair.risks`, `repair.reason`, summary and description.
For an unchanged invocation, it also requires zero counters and substantial=false.
For changed work with three zero counters, it requires a positive counter.
For other changed work, the counters stay fixed.

`executor_candidate_report` recognizes the same report, so `read_saved_repair_test` can
replay a saved test run, and its successful checks do not run again. Test invocations get
`TEST_RISKS`: they list only the risks that their checks expose.

`enum_problems` in `cycle_transport.py` recognizes a pair writer report whose only invalid values are outside their enums.
`valid_choice` searches a few choices of allowed values, item removals, and both repair modes. `repairable_enum` starts a `report-enum` correction.
`enum_fields` names what the correction can change, and `validate_executor_correction` checks it. `saved_repair_fix` lets a retried fix step adopt such a saved run.

`cycle_prompts.DISCUSSION_CONSENSUS_CONTRACT` gives discussion roles the exact `consensus` format.
Both Claude and Codex discussion readers put prose around the hash. The old rule said "name the hash".
The parser does not check the format of `consensus`. `pair_inspection_step` rejects a wrong value after both readers finish.
An endorsement with assessments or new findings still fails the parser. Its error says to set `consensus` to null to disagree.
A parse failure on the third attempt would stop the running peer and discard its report.
The `pair-consensus` error names the exact expected hash and impact for the correction prompt.
Without a proposal, it tells the reader to set `consensus` to null. The arbiter keeps its own null rule.
`cc-focus --retry` clears `report_repairs` of unfinished pair jobs.
`run_jobs` replaces a saved `LEGACY_CONSENSUS_ERROR` with `consensus_error` in the correction prompt.

The parser accepts `new_findings` from the arbiter. `pair_inspection_step` adds them to the registry
and records `arbiter_extension`. The next arbitration decides the complete registry, and its `rule`
gets one more paragraph. If that arbitration adds findings again, the step refuses its report with
`pair-report`. Without an extension, the arbitration prompt is unchanged, so a saved arbitration
job still matches.

For a job with the exact `LEGACY_ARBITER_ERROR`, `run_jobs` parses the saved report again, and a
valid completed report is accepted without a provider call. Another saved report gets a current
correction text instead of the old parser error.

`ProviderTransient` classifies only matching-session synthetic `server_error` /
`overloaded_error`, or initialized error results with `terminal_reason=api_error`
and integer HTTP status 500/502/503/504/529. Quoted text and unknown failures keep
ordinary recovery.

After confirmed cleanup, `Cycle.defer_transient` stores
`pending.transient_retries` and `transient_wait`. The same invocation/session gets
at most three outer-runtime retries in a row after 15/30/60 seconds. Exhaustion goes to
`handle_block`. Except for the healer, it stops the run with `provider-unavailable`
for both provider codes in `PROVIDER_UNAVAILABLE_BLOCKERS`. Neither the healer nor a provider
launches a retry. The budget and deadline survive
pause/restart, including `--retry`; retiring an invocation retires its budget.

`wait_transient` yields through normal stop, PAUSE, message and lease checks.
Unresolved message delivery prevents automatic retry. Protected files, HEAD and
staging are checked before scheduling and launching; report-only corrections
retain their frozen snapshot checks. Panel/progress/status
expose the retry count and countdown with no active model. Inside the publication
window, Stop and PAUSE wait until the window ends.

Work is preserved, but an interrupted review loses its current streak and file
edits latch substantial changes. Only a no-work failure on an unchanged snapshot
preserves prior clean credit. No failed attempt earns a pass.

Escalated blockers saved before an update still need operator continuation.
Installing an update does not resume them.

For Codex, `codex_transient` finds a failed turn with a server error. Its
`codexErrorInfo` is `serverOverloaded` or `internalServerError`. An HTTP
connection or stream error with status 500/502/503/504/529 is also a server error.
The code is `codex-transient`. Model items, tool calls and approval requests in the
failed turn count as started work. `Rpc.server_requests` counts the tool calls and
approval requests.

`Cycle.run` checks a saved quota or server-error wait before it starts the healer.
A Codex healer with a server error therefore also waits. If the healer uses all its
retries, the run stops with `healer-failed`. `--retry` retires a waiting healer
with its blocker.

After exhausted retries, every sequential role and pair participant gets the same
closing sentences from `transient_exhausted`. They tell the operator to wait for
the provider and then run `--retry`. In a review run, they name the retry command
of that run. For a pair participant, the text names the
participant role, because the blocker names the pair group invocation. A server
error of the healer keeps `healer-failed`, with the same text as its resolution.

`run_jobs` removes `transient_retries` of a pair job when `transport.run` returns.
A later report correction of that job then starts with three retries. Before Claude
gets the next operator message in the same process, the transport also removes
`pending.transient_retries`. `--retry` also resets `transient_retries` and `retry_at`
of unfinished pair jobs.

A safe stop at an escalated blocker does not pause the run. The next loop pass
prints the blocker and returns 3. `request_stop` then says that the run output
names the blocker and the retry command.

Claude quota refusals are a separate transport/runtime path: `ProviderQuota` requires
a matching-session rejected `rate_limit_event` with a finite positive `resetsAt`
and a synthetic `rate_limit` refusal or HTTP 429 API-error result. Telemetry alone,
warnings and model prose do not trigger it. After confirmed provider cleanup,
`Cycle.defer_quota` stores `pending.quota_wait`; `wait_quota` yields through the
normal stop/PAUSE/message/lease boundary until reset plus five seconds, with a
60-second minimum backoff on every refusal. No healer runs. The same invocation,
phase and session retry automatically; stopping/restarting preserves the deadline,
while retiring the invocation retires its wait. Explicit `--retry` (or `/resume`
from a stopped quota wait) advances only `retry_at` to the current time, allowing
one immediate provider attempt with the current login after an operator account
switch. The refusal's `resets_at`, `no_work`, invocation and session are preserved
for normal ownership/HEAD checks and interrupted-review handling. Unresolved
messages prevent this override; a fresh quota refusal schedules another wait.
Initial no-work refusal plus an
unchanged full snapshot preserves prior clean passes; partial work or drift uses
normal interrupted-review resets. Ownership and HEAD are checked again before
the retry starts a provider. No refusal earns review credit. Progress and
the status panel show runtime waiting, UTC deadline and countdown; status JSON
exposes `quota_wait`. Invalid/missing reset data uses ordinary API-error recovery.

A pair participant waits in `run_jobs` instead.
When no pair participant runs, `run_jobs` checks the stop control, for example during a quota wait.
An emergency stop raises `FocusStop`, and a safe stop returns `None` to the run boundary.
`cc_focus.resume_retries` adds `--retry` to `/resume` for a blocker, a quota wait, or a quota wait of a pair participant.
`tests/test_focus_pairs.py` covers both rules.

The access refusal stops directly;
other generic API failures receive the normal Astra/xhigh recovery attempt. Neither
replaces the session or earns review credit. They preserve the required model, phase and
conversation for operator continuation after access/provider recovery. Ordinary
answers from another model still fail as `model-rerouted`; quoted error text does
not trigger the API classifier. Synthetic errors are terminal failures, never
successful reports, even if the CLI has not emitted initialization yet.
Claude also receives `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` in its process and
inline settings, with Bash timeouts of 30 minutes by default and six hours maximum.
Monitor, cron creation, wakeups, remote triggers and Workflow are disabled alongside
native delegation. The six-hour outer deadline remains in force. Automatic backgrounding
is disabled without changing user/project settings or conversation identity; explicit
shell `nohup`/`&` is constrained by the common prompt rather than that CLI setting.
For native continuation from older sessions/CLI versions, task start/completion
events and queued turns keep a result provisional. The runtime stores it under
`deferred-*.txt`, keeps consuming events and requires a later final report; it does
not close stdin, send queued operator input or grant review credit at that point.
Any fixes reported provisionally remain a lower bound in the final response, then
the normal operator-response aggregation applies. Native EOF without the final
report still blocks. Only a final response starts the 30-second process-exit grace.
An unresolved blocker does not cause model polling. Luna gets short results and
artifact paths; Sol gets the complete coding final message. Review invocations
each perform one pass; the runtime owns clean counters and rejects incomplete
reports; evidence entries must contain non-whitespace text. Only the runtime may
stage/commit/push after publisher preparation; existing dirty files are protected.
The report parser preserves long summaries instead of treating the 1200-character
presentation budget as a workflow blocker. `concise_summary` bounds only printed
previews and persisted coordinator/status summaries, including coding recovery;
saved reports and Claude multi-response aggregation retain the full content.
Report types, fix-count consistency and mandatory review evidence stay strict.
Review accounting includes new journals/logs/evidence/snapshots/digest indexes in
`minor_edits` (one per changed evidence file) when they merely record completed
checks. This preserves clean credit without inventing substantive defects. Evidence
corrections are `other_fixes`, or implementation fixes when they change behavior,
checks, acceptance rules or instructions. Paths never grant a category exemption;
changed files with all counters zero trigger one report-only correction before
`unreported-fix` escalation. `Cycle.begin_report_repair` creates a fresh durable
invocation marker in the same role/session, links the immutable rejected result
and pins its post-review snapshot. `report_repair_context` verifies the source
hash and unchanged files/HEAD/index on every entry and before accepting a result.
The author corrects classification without new review, tests or evidence writes;
runtime never infers minor edits from paths or invents counts. The corrected result
retains the original before/after scope and provenance, earning at most one pass.
Interrupted correction and quota refusal preserve completed-pass credit until
validation; implementation fixes in the corrected report use normal review gates.
Input targeting is disabled during correction; existing operator restart markers
are carried forward. A second invalid report or mutation uses ordinary recovery.
Historical escalated reports are not silently accepted or rewritten.
`report_object` unwraps one final JSON object after plain prose or a single Markdown
fence; the raw artifact/handoff stays unchanged. It rejects multiple/nested objects,
trailing commentary, duplicate keys and malformed JSON without guessing a repair.
Formatting-only wrappers no longer launch a healer. Recovery still requires the
exact original checkout snapshot; later healer/other edits need a fresh coding report.
An older summary-length blocker is retried with `--retry` after runtime sync;
the rejected pass is not automatically credited or used to skip review gates.
Remote-main evidence is queried at the single push URL, with at most three
60-second attempts and a two-second delay on transient network errors/timeouts.
`Repository.remote_head` disables terminal/GCM login only for that query, preserving
credential helpers and operator settings. `Cycle.remote_head` labels progress as
a runtime Git check instead of an active coordinator. Exhausted timeouts and other
remote access failures become `remote-query-timeout`/`remote-query-failed` and go
through Astra/xhigh recovery; unchanged review seals, phase and sessions survive.
Any repair changing reviewed files must pass all required reviews. After restoring access,
`--retry` also resumes legacy `command-unavailable` Git timeouts. Publication and CI
still require live remote evidence; successful pushes reconcile before model replay.
Check authentication as the launcher OS user: root's missing login says nothing
about an operator account. `gh auth status` can succeed with SSH selected while the
actual push URL remains HTTPS without a Git credential helper. Diagnose the push
URL directly; the operator can connect an existing GitHub login to HTTPS Git with
`gh auth setup-git --hostname github.com`. The runtime never changes credentials or
remote URLs automatically; see the publication recovery guide in `docs/sequential-cycle.md`.

State, invocation intents/results and immutable handoffs live in `.work/cycle/`.
Internal role session IDs persist automatically within a stage.
`advance_stage` saves them in `sessions/generation-N.json` and clears them, so each stage starts new conversations.

`advance_stage` also records the published stage in `previous_stage` through `stage_record`.
Only a code or operator label names that stage.
`Cycle.previous_stage` gets the record from the archived iteration for a state of an older runtime.
It also removes a coordinator label of that stage.

`Cycle.context` gives that record to the coordinator and the code role.
The rule permits the stage again only for plan work that the published commits do not contain.
`accept_task` rejects a coordinator label that names that stage, but a code report can name it.

`PROMPTS["coordinate"]` permits its report recovery route only with `coding_recovery` in the context.
The coordinator names the stage that this iteration implements, and never a stage in `previous_stage`.
If the iteration continues that stage, the coordinator uses null, and the code report names it.
`build_panel` shows `Задача N · после <previous stage>` until a report names the current stage.

`--handoff FILE` imports context. The current project plan referenced in that handoff is the source of stages, not
the task queue or conversation memory. Missing or ambiguous plans block selection.

`--new-sessions` resets conversations without resetting progress or deleting WIP;
`--retry` is the operator action after a blocked stop. Session ID import is absent.

`cc-focus recover --review-from <saved-code-result>` is a separate, model-free
operator transition for already completed coding whose report was rejected.
`Cycle.recover_review` validates the original coding intent/result, current
iteration, unchanged HEAD/index/files and protected work; it archives the previous
state under `.work/cycle/recoveries/` and exits paused at Sol with zero review
credit. It does not accept healer prose as phase authority. Coding report parsing
allows substantial new implementation with no review-fix count; review/healing
classification remains strict. The code recovery context permits finalizing a
lost report instead of selecting another implementation stage.

`cc-focus correct --message <text>` or `--file <path>` is a stopped-only, model-free
transition under the local lock and shared lease. It copies/hashes operator text
and the previous stage context under `.work/cycle/corrections/`, retains the current
iteration and sessions, replaces pending intent with a new correction revision,
and returns the same stage to coding with zero review credit. Context validates
the immutable artifacts and carries corrections through all required reviews; old coding
results cannot acknowledge a newer revision. Publication/CI, changed HEAD/protected
work and unstarted stages fail closed. After coding, `correction_pending` clears;
after publication/CI, the archived iteration retains corrections and the new stage
starts without them. `--retry` and `--new-sessions` do not remove corrections.

`cc-focus reconcile --plan-out .work/focus-reconcile.json` prepares a model-free
handover plan for `project-context-changed`/`protected-work`; `--apply-plan FILE`
is explicit operator acceptance, never an action for a healer/provider to grant
itself ownership. Plans seal all work, HEADs/index and semantic runtime state;
only admission timestamps and lease bookkeeping are ignored. Applying a stale or
edited plan fails, including work changing during correction artifact creation.
Changed loose context receives new read-only expectations.

Listed protected member
files are handed over in full, including their pre-existing uncommitted content;
their publication baselines become Git HEAD checkout fingerprints (absent for new
files), so earlier dirty content stays owned even if coding reverts the latest edit.
The archive retains the original dirty baselines. Unlisted work
stays protected. The original state and exact plan are archived through
`Cycle.record_correction`; the same stage returns to code with sessions preserved,
a fresh correction revision and no review credit. Source/index/HEAD are untouched.

An iteration blocked before its first coding invocation can also be reconciled.
Its correction records `before_code=true`, preserves `code_started=false`, clears
the provisional task label, and guides selection from the current plan instead of reopening the prior published
stage. It has no mandatory correction acknowledgement for a nonexistent stage;
the usual unpublished-diff barrier still requires coding and all required reviews for
adopted work. A loose-context-only handover may finish an exhausted plan without
inventing implementation.

Admission holds normal project/member locks and leases, honors PAUSE and uncertain
messages, and refuses changed HEAD/protected staging, layout changes and any
publication/CI phase. Plans never widen provider permissions or publication scope
to files outside Git. Neither handoff import nor retry implicitly accepts these
ownership changes. See the handover guide in `docs/sequential-cycle.md`.
Plan destinations exclude shared runtime control files such as `.work/control_state.json`,
even when those files do not exist yet.

Publication/CI validation also rechecks protected staging in single-repository mode
before it archives an iteration. Without a completed-stage pause, the next stage cannot
silently accept a changed index. After that pause, the new stage records the protected index again.

Fresh coding prompts no longer describe an initial
invocation as report recovery; resumed/previously attempted invocations still do.

Focus tests use the launcher's UTF-8 Python profile, canonical temporary roots
(including Windows 8.3 aliases), and check lock contents only after releasing a
Windows byte-range lock; probing a held lock still checks that metadata is unchanged.

`cc-focus stop` waits for a safe boundary, including CI if publication has started;
`stop --now` interrupts the current attempt and may hard-kill only its recorded
contained run. Stop requests never launch blocker recovery; continuation does.
Run control uses `.work/cycle/active.json`, `stop.json`, `runs/<nonce>.json` and
`control.lock`. These are separate from operator-owned `.work/PAUSE`, which is
still checked only at boundaries. An old request cannot stop a newly started run.

The mode explicitly pins Codex full-access/on-request and Claude bypass permissions
without changing global settings or role frontmatter. Read `docs/sequential-cycle.md`
for the ownership, CI, crash-recovery and filesystem-durability boundaries.

Codex processes and thread start/resume also pin `features.memories=false`:
memory consolidation is a separate tool-using agent, not covered by
`features.multi_agent=false`. Diagnostic evidence showed such a background thread
editing stage files and launching mutation tests in the consuming checkout while
the healer itself performed only report repair. Its calls were present in native
Codex logs under a different thread ID with the same provider PID, but absent from
the healer's app-server tool transcript. The override preserves global settings,
memory files and role sessions; it does not erase already-injected context or stop
independent running providers. Do not infer an external overlapping run from the
healer's prose alone, and do not force an old report onto a changed snapshot.

`tests/test_cycle.py`, invoked by `tests/launchers/test-cc-focus.ps1`, uses only
protocol fixtures and disposable Git repositories; it never starts paid models.

### Queue processor workflow

```text
источник задачи -> Tasks_Queue.md -> planner -> task.md
    -> coder в отдельном worktree -> reviewer <-> coder
    -> merger в _integration -> full_reviewer <-> coder
    -> ff-merge main -> push/CI -> knowledge_curator -> журнал/очистка
    -> inbox_curator(finalize linked requests)
```

Защищённый remote trunk совместим с этим потоком, когда оператор заранее настроил для
Orchestra-аккаунта/токена bypass-исключение: processor по-прежнему делает локальный ff-merge
и прямой обычный non-force push, не создаёт PR и не ослабляет branch protection. Отказ remote
оставляет батч в состоянии «слит локально, не опубликован» для безопасного resume; force-push
запрещён. Это host-side разрешение не считается `policy-bypass` Orchestra и не создаёт
approval gate, пока `tools/policy.ps1 check-publish` разрешает фактические branch/remote.

Всем циклом владеет processor state machine: в legacy Claude-provider это
`agents/processor.md`, в Codex-provider — сгенерированный из него `codex/processor.md` с
узким provider-overlay. Он берёт `orchestrator.lock`, восстанавливает
прерванное состояние, выбирает параллельно безопасный батч, создаёт Git worktree или Jujutsu
workspace, коммитит результаты листовых агентов, публикует их и чистит runtime-состояние.
Листовые coder/reviewer не должны самостоятельно управлять очередью, коммитами или push.
Processor и merger формируют описательные англоязычные сообщения коммитов без внутренних
идентификаторов очереди: `T-NNN`/`P-NNN` запрещены и в subject, и в body, и в trailers;
связь задачи с ревизией остаётся в `.work/`-артефактах.

## Карта исходных файлов

Все перечисленные ниже агентские `.md` лежат в каталоге `agents/` (в тексте — краткими
именами файлов, например `agents/processor.md`); там же — шаблоны `coder.template.md` и
`reviewer.template.md`. Документация (`AGENTS.md`, `knowledge.md`, `config.example.md`,
`constraints.example.md`, `README.md`, `plans/`) и генератор `generate-coders.ps1`/`.cmd`
остаются в корне репозитория. Отдельно, в подкаталоге `docs/`, лежат: `docs/operations.md` —
руководство оператора (запуск и мониторинг сессии processor, чтение status/journal,
обработка эскалаций); `docs/contributing.md` — руководство разработчика самой Orchestra
(чеклисты добавления роли, config-ключа, tools-раннера и изменения контракта очереди,
карта guard-скриптов и CI-гейтов); `docs/queue_contract.md` — единый нормативный источник механического
контракта постановки задач в `.work/Tasks_Queue.md` (форма заголовка, нумерация `T-NNN`,
статусы, тело, дедуп по трём источникам, поведение под локом, запреты), на который ссылаются
все пять популяторов очереди вместо переизложения правил; `docs/roadmap_contract.md` —
единый нормативный источник формата рантайм-артефакта дорожной карты подключённого проекта
`.work/roadmap.md` (упорядоченные вехи со статусами `запланирована`/`текущая`/`достигнута`,
проверяемый критерий достижения, связь веха↔`T-ID`), машинно-локального (как `.work/knowledge/`),
а не сеемого шаблона; на него ссылаются будущие потребители осведомлённости о дорожной карте;
`docs/environment-variables.md` — операторский справочник по root-config, project config,
defaults и границе между пользовательскими настройками и внутренними runtime-переменными.

### Координация и интеграция

- `processor.md` — канонический state machine: фазы 0–6, resume, лимиты циклов,
  маршрутизация Claude/Codex, публикация и CI; координатор работает как Sonnet/high.
  При споре между кратким описанием и фазами ориентируйтесь на алгоритм фаз.
- `planner.md` — выбирает непересекающиеся conflict domains и создаёт
  `.work/tasks/<T-ID>/task.md`; код и очередь не меняет. Processor передаёт ему полный
  committed `BASE`: названные как существующие файлы/символы проверяются в этой ревизии,
  а не только в live checkout. Target только из незакоммиченного WIP не захватывается;
  `queue_builder`/`thinker` применяют тот же committed-base гейт при постановке задач.
- `executor.md` — только механические переходы строк очереди: capture, requeue,
  escalation, delete.
- `merger.md` — последовательно сливает готовые ветки в `_integration`, разрешает или
  карантинит конфликты, пишет `merge_report.md`. `SMOKE_CMD` сохраняется для быстрых
  per-merge самопроверок и как legacy fallback, но финальную вершину всегда проводит через
  `tools/verification.ps1`: ordered `VERIFICATION_COMMANDS` выполняются supervisor'ом,
  evidence привязано к profile fingerprint, commit/change id и стабильному несекретному
  environment fingerprint (ОС/архитектура, PowerShell host/version, эффективный
  ProcessKit/containment mode и hash supervisor). Schema `orchestra/verification@2` не
  хранит абсолютные пользовательские пути/stdout/stderr/env blobs и считает команду
  reusable только при `reason=ok`, `exit_code=0`, `survivors=0`,
  `cleanup_attempted=true`; `check --require-pass` дополнительно отвергает любой `exempt`.
  В jj `--revision <bookmark> --head <full commit id>` проверяет запечатанную вершину
  (не пустой WIP workspace `@`) и fail-closed требует exactly-one full commit id.
  Config читается из `--config-root` (default `--work`), а transient supervisor-файлы
  каждого `run` лежат в уникальном invocation-каталоге, привязанном к `--result-file`;
  параллельные reviewer-вызовы не делят artifacts. Один логический supervisor/
  verification-вызов адресуется стабильным result path и на всё время исполнения держит
  sibling `<result-file>.run.lock`: внешний shell/tool timeout не считается terminal
  verdict, а повтор с тем же path получает rc=2 как уже активный логический вызов и
  fail-closed не порождает второй дочерний процесс. Дедлайн
  дочерней команды не сокращается ниже effective `CALL_DEADLINE_SEC` и повышается до 125%
  известной terminal-green длительности; внешний wait timeout обязан превышать рассчитанный
  completion bound минимум на 120 секунд. Второй обязательный clean review-pass на
  неизменном SHA повторяет содержательный анализ, но не идентичную уже terminal-green
  focused-команду без нового сигнала риска.
  Processor повторно проверяет evidence перед ff/push и на resume. Missing-profile для исполняемого diff блокирует
  публикацию; допустимы только механический docs-only и operator-owned `disabled` exemptions.
  Перед каждым merge `tools/policy.ps1 guard-revision` связывает branch/bookmark с полным
  `Ревью-SHA` из `task.md` и требует непустой diff от BASE: пустой init-коммит, divergence
  или непроверенный post-review tip детерминированно карантинятся до интеграции.

- `tests/launchers/run-all.ps1` владеет scheduler launcher-suite: явный reviewed allow-list
  герметичных suites выполняется максимум четырьмя отдельными supervised PowerShell
  процессами, timing/process-sensitive и все новые/unclassified suites — сериализованно.
  Discovery фиксируется до запуска, результаты и вывод сводятся детерминированно по имени,
  а missing/invalid terminal result, nonzero exit или `survivors>0` fail-closed ломают
  aggregate verdict. Reusable in-process worker, affected-scope skipping и меж-SHA cache
  здесь намеренно отсутствуют. У каждого supervisor process есть также parent-side
  deadline (`suite deadline + bounded grace`): зависший supervisor ограниченно получает
  tree cleanup, фиксируется как `parent-timeout`, не блокирует сбор остальных results и
  не оставляет потомков.

### Полностью Codex-native provider

- `generate-codex-agents.ps1` — единственный генератор Codex-пакета. Он снимает YAML
  frontmatter с канонических `agents/*.md`, не меняет их тела и добавляет provider-overlay:
  `codex/processor.md` для root-сессии и двенадцать namespaced custom agents
  `codex/agents/orchestra_*.toml`. Каталог generated-ролей приводится к точному набору:
  старый namespaced TOML после удаления/rename роли удаляется генератором, затем `cc-sync`
  удаляет его из managed destination. Generated-файлы напрямую не редактируются.
- `tools/codex-processor-runtime.ps1` запускает самостоятельный интерактивный root через
  Codex TUI (`codex` / `codex resume <UUID>`), пинит `approval_policy=never`,
  `multi_agent=true`, `agents.max_depth=1`, sandbox/reasoning/thread cap из operator-owned
  `ORCHESTRA_CODEX_*` и наследует терминальные stdin/stdout/stderr. Новый start/cold recovery
  получает короткий bootstrap с точным путём к полному canonical prompt и обязан прочитать
  его до любых действий; exact resume отправляет только короткий continuation prompt.
  Runtime находит созданный root rollout под `$CODEX_HOME/sessions`, проверяет
  `session_meta` (`originator=codex-tui`, точный root и уникальный invocation marker) и
  атомарно сохраняет адресованный `.work/codex_processor_session.json`. `resume` использует
  только этот UUID, никогда не `--last`. Если UUID невалиден/не совпадает с root, runtime
  механически ищет durable in-flight markers (`batch`/cohort/integration state, task
  descriptors/worktrees, processor lease, queue `в работе`): при их наличии выбирает новый
  Codex thread с `last_action=handoff`, без них — обычный Phase-0 cold recovery. Явный
  `cc-resume codex --from claude` выбирает `handoff` даже при старом валидном UUID.
  Перед handoff read-only `state-tx status` fail-closed запрещает live, legacy, corrupt,
  wrong-role/root lease; matching stale lease не удаляется и передаётся Phase 0 для
  повторного `verify` и безопасного `takeover`. Только после preflight runtime инвалидирует
  прежний Codex UUID. Transcript Claude не импортируется: prompt объявляет `.work/`, VCS,
  существующие worktree/ветки и WIP источником истины и запрещает отбрасывать начатую работу
  из-за смены provider. Структура и checkout-freshness установленного custom-agent пакета остаются
  обязательным preflight. Project-local либо второй global
  TOML с любым managed `name = "orchestra_*"` считается конфликтом и останавливает preflight:
  Codex идентифицирует роль по `name`, поэтому такое переопределение недетерминированно.
  Новый `start` заранее инвалидирует
  UUID прежней сессии, поэтому ранний сбой не направит последующий `resume` в старый thread.
  Runtime не содержит и не вызывает Claude fallback.
- `tools/codex-role-runtime.ps1` тем же способом с наследуемыми stdin/stdout/stderr открывает
  обычный Codex TUI для напрямую запускаемых `thinker`, `code_auditor` и
  `enhancement_scout`. У top-level Codex CLI нет аналога `claude --agent`, поэтому короткий
  bootstrap указывает точный полный канонический `agents/<role>.md` (в checkout или
  sibling-mirror `~/.claude/agents`) и требует прочитать его до действий; полный prompt в
  argv не копируется. Runtime пинит `approval_policy=never`, применяет operator-owned
  model/reasoning/sandbox, не использует `codex exec`/JSONL и не имеет Claude fallback.
  Свободная тема `thinker` пересекает Windows argv-границу во временной process-scoped
  `ORCHESTRA_CODEX_ROLE_TOPIC`; runtime читает и удаляет её до запуска дочернего Codex,
  поэтому текст не может перевязать runtime-параметр и не наследуется TUI.
  Эти одно-ролевые сессии не пишут processor UUID: продолжение выполняется нативными
  средствами Codex, а `.work/codex_processor_session.json` принадлежит только processor.
- `ORCHESTRA_PROVIDER: claude|codex` в `~/.orchestra/root-config.md` задаёт системный default;
  литеральный аргумент
  `codex|claude` у `cc-processor`, `cc-resume`, `cc-thinker`, `cc-audit` и `cc-enhance`
  имеет приоритет. Default остаётся `claude` для обратной совместимости. В Codex-provider
  processor все planner/coder/reviewer/merger/
  curator-вызовы — отдельные `orchestra_*` Codex threads; старые `coder_codex`/
  `reviewer_codex`, их `CODEX_*` routing и Claude fallback не участвуют.
  Provider не переключает себя внутри живого root run. Единственный межprovider-переход —
  operator-owned cold-recovery handoff от уже остановленного Claude через
  `cc-resume codex --from claude` (либо автоматический эквивалент без Codex UUID при durable
  in-flight state).
- `ORCHESTRA_CLAUDE_PERMISSION_MODE: auto|bypassPermissions` в root-config — operator-owned режим
  всех Claude-launcher’ов; default `auto`, любое иное значение fail-closed останавливает
  launcher до старта Claude. Режим родителя `bypassPermissions` имеет приоритет
  над frontmatter subagent’а и наследуется всеми создаваемыми ролями, поэтому
  канонический `agents/*.md` и mirror по-прежнему хранят `permissionMode: auto`.
  Opt-in предназначен только для изолированного контейнера/ВМ; агенту запрещено
  выставлять его или перезапускать себя для саморасширения прав. На внутренние
  `policy.ps1` gates этот Claude-режим не влияет; Codex-native runtime его не использует.
  Windows-resolver в `cc-common.cmd` читает ещё невалидированное значение только через
  delayed expansion, материализует в дочернее окружение один из двух фиксированных
  литералов и держит результат под `setlocal`: cmd-метасимволы не исполняются, а внутренний
  `CLAUDE_PERMISSION_MODE` не утекает в вызывающий shell.
- Maker/checker в Codex-provider изолирован отдельным thread: reviewer никогда не является
  maker-thread. Гибридный Claude-root по умолчанию и для legacy-значений
  `CODEX_REVIEWER=fast|fast+std|deep` сохраняет cross-provider развязку «Codex сделал —
  Claude проверяет»; явное `CODEX_REVIEWER=all` использует ту же thread-based границу,
  что native provider: новый checker-вызов Codex без resume maker-треда.
- `cc-sync` после обычной генерации запускает Codex-генератор, зеркалирует root prompt рядом
  с provider runtime в `~/.claude/scripts/codex-processor.md` и управляемо устанавливает только
  `orchestra_*.toml` в `$CODEX_HOME/agents` с отдельным manifest. `CODEX_HOME` резолвится
  из root-config и передаётся каждому native и leaf Codex child, поэтому sync, роли,
  сессии и `codex exec` используют один home. Чужие custom agents не
  удаляются. Пути из обоих manifest/journal считаются недоверенными: stale-pruning и crash
  recovery принимают только canonical descendants соответствующего destination root;
  traversal и внешние absolute paths игнорируются. И containment, и manifest sets используют
  один платформенный comparer: OrdinalIgnoreCase на Windows, Ordinal на POSIX, поэтому
  case-only rename на POSIX удаляет старое написание в Claude и Codex mirrors. `cc-doctor` проверяет выбранный provider
  и полноту пакета.

### Реализация и ревью

- `coder.template.md` — **единственный источник** общей логики Claude-coder.
  `generate-coders.ps1` создаёт `coder_fast.md`, `coder.md`, `coder_deep.md`; их нельзя
  редактировать по отдельности. В Режиме 1 уже существующая строка `Ограничение радиуса:`
  в `task.md` обязательна для минимального diff в указанном файле, символе или заголовке;
  `coder_codex` передаёт её в prompt только при наличии, включая отсутствие при `KB=off`.
  Уровни: fast = Sonnet/medium, standard = Sonnet/high, deep = Opus/xhigh.
- `reviewer_std.md` — дешёвое per-task ревью fast-задач; `reviewer.md` — полное ревью
  standard/deep; оба ведут `R-NN` в task-local `review.md`.
- `full_reviewer.md` — ревью совокупного результата в `_integration`, ведёт `F-NN` в
  `review_integration.md`.
- `coder_codex.md` и `reviewer_codex.md` — тонкие адаптеры `codex exec` с обязательным
  fallback на Claude. Codex-coder поддерживает реализацию, `R-` и при
  `CODEX_CIFIX=on` точечный Режим 3, но не интеграционные `F-`. Codex-reviewer работает
  read-only. Значение `all` у `CODEX_CODER`/`CODEX_REVIEWER` включает все task-level
  уровни; для `coder_deep` оба адаптера игнорируют общие `CODEX_MODEL`/`CODEX_REASONING`:
  reasoning всегда `xhigh`, модель — `gpt-5.6-sol`, если не задан соответствующий
  deep-ключ (следующий пункт).
- **Модели ролей coder/reviewer настраиваются оператором (ключи `config.md` с
  fallback на `~/.orchestra/root-config.md`).** Пять `CLAUDE_*_MODEL` (`CLAUDE_CODER_FAST_MODEL`, `CLAUDE_CODER_MODEL`,
  `CLAUDE_CODER_DEEP_MODEL`, `CLAUDE_REVIEWER_STD_MODEL`, `CLAUDE_REVIEWER_MODEL`;
  `haiku|sonnet|opus|fable`) processor резолвит один раз на Фазе 1.1 и передаёт
  параметром `model` инструмента `Agent(...)` при каждом вызове роли — frontmatter
  сгенерированных `agents/*.md` при этом **не** переписывается (пустой ключ = модель
  frontmatter). Четыре `CODEX_*_MODEL` (`CODEX_CODER_MODEL`/`CODEX_CODER_DEEP_MODEL`,
  `CODEX_REVIEWER_MODEL`/`CODEX_REVIEWER_DEEP_MODEL`) читают сами адаптеры: не-deep
  разрешается «ключ роли → `CODEX_MODEL` → дефолт codex», deep — «deep-ключ роли →
  `gpt-5.6-sol`», общий `CODEX_MODEL` в deep-ветку не течёт. Тиринг и маршрутизацию эти
  ключи не меняют — только модель уже выбранной роли; `planner`/`merger`/`full_reviewer`/
  кураторов не затрагивают. Копии контракта `CLAUDE_*` живут в `tools/doctor-runtime.ps1`
  (`$claudeModelAllowed` — допустимые значения, `$claudeModelFrontmatter` — модель роли
  при пустом ключе) и машинно сверяются в `check-consistency.ps1` (Class 4) с enum'ами и
  дефолтами `tools/policy-schema.ps1`, а фолбэк-модели — ещё и с `model:` во frontmatter
  самих ролей.
- **Единый исполняемый runtime `tools/codex-runtime.ps1` (T-075).** Механическая часть
  протокола обоих адаптеров вынесена из Markdown-инструкций в тестируемый кросс-платформенный
  pwsh-скрипт (по образцу `tools/queue-tx.ps1`): **безопасная сборка argv** нормализованной
  формы `codex exec` (массив аргументов, без строковой конкатенации/`Invoke-Expression` —
  иммунитет к shell-инъекции), приём промпта через stdin, раздельный захват stdout/stderr/RC,
  fail-closed пин `-c approval_policy=never` (T-069) и, только у coder при `--network on`,
  оверрайды сети T-063, **классификация отказов** (`ENV_LIMIT`-таблица T-062/T-067,
  расширяемая), **порог негабаритного diff** (T-074, дефолт 4000), **проверка «чистого
  прогона»** reviewer-вывода (RECHECK/NEW), **валидация брокер-команд** по allowlist (T-063),
  **проверка состояния активной рабочей копии** (`working-copy-status`: обязательный
  `--vcs`, для jj — только `jj -R <worktree> diff`, без ложного fallback на Git в
  colocated jj+git), **гарантия отсутствия коммитов** (`guard-commit`, git soft-reset,
  никогда `--hard`) и
  **безопасная очистка только своей рабочей копии** (`cleanup`; в основном дереве Фазы 5.4 —
  `--main-tree`, никогда `git clean -fd`, `.work/` не трогается), плюс маппинг сентинелов
  `ЭСКАЛАЦИЯ codex: …`. Оба адаптера зовут его коротким стабильным контрактом (команды
  `run`/`build-argv`/`classify`/`check-diff`/`working-copy-status`/
  `validate-reviewer`/`broker-validate`/`broker-run`/
  `guard-head`/`guard-commit`/`cleanup`/`map-sentinel`) — **один** источник сборки команды, без двух
  расходящихся вариантов. Публичное поведение (сентинелы, «нет коммитов от codex»,
  нормализованный `codex exec`, форматы `codex_out.md`/`codex_review_out.md`) сохранено.
  Все четыре VCS-чувствительные команды (`working-copy-status`, `guard-head`,
  `guard-commit`, `cleanup`) требуют явный `--vcs git|jj` через один fail-closed
  валидатор (exit 2 при отсутствии/неподдерживаемом значении): ни fingerprint вершины,
  ни post-guard, ни потенциально деструктивная очистка не имеют скрытого Git-default.
  Детерминированные тесты с fake `codex` — `tests/test-codex-runtime.ps1` (в CI
  `.github/workflows/ci.yml`, шаг «Check Codex runtime behaviour»); написаны переносимо и
  готовы к POSIX-прогону; при наличии jj отдельно воспроизводят colocated-состояние, где
  `git status`/`git diff` чисты, но `jj diff` содержит изменения, и требуют
  `clean=false`. **Зеркалирование в другие проекты (T-114 → обобщено T-115).**
  `tools/sync-runtime.ps1` изначально (T-114) мирроил в `<dest>/scripts` только
  provider runtime; теперь он разделяет provider mirror и общий home: `codex-runtime.ps1`
  остаётся в `~/.claude/scripts`, а общие раннеры (`state-tx.ps1`, `queue-tx.ps1`, `outbox.ps1`,
  `policy.ps1`, `redaction.ps1`, `notify.ps1`, …) устанавливаются в
  `~/.orchestra/scripts`. Конфигурация и спецификации также устанавливаются в `~/.orchestra`;
  адаптеры и агенты резолвят путь к раннеру по обеим
  раскладкам (чекаут/зеркало — см. «Резолвинг раннеров `tools/*.ps1`» ниже, «Разрешение на
  запуск codex — предвыдаётся, а не выпрашивается по ходу» и `agents/coder_codex.md`,
  «Резолвинг пути к runtime»), иначе вне чекаута orchestra голый относительный путь
  `tools/<script>.ps1` не резолвился бы вовсе.
  Shared tools that spawn another PowerShell process use
  `Get-PowerShellHostExecutable` from `tools/common.ps1`. They must not reuse
  `MainModule.FileName`: for a framework-dependent global-tool installation that value
  is `dotnet`, while the reusable console host is the `pwsh` apphost under `$PSHOME`.
- **`CODEX_NETWORK` (дефолт `on`) — сеть в песочнице `coder_codex`.** При `on` `coder_codex`
  добавляет к вызову (после литерального префикса `codex exec`, не ломая грант) оверрайд
  `-c sandbox_workspace_write.network_access=true` (проверено на codex-cli 0.142.5: без него
  в `workspace-write` исходящие соединения блокируются) и пробрасывает git на openssl-бэкенд
  через `-c shell_environment_policy.set={GIT_CONFIG_COUNT="1",GIT_CONFIG_KEY_0="http.sslBackend",GIT_CONFIG_VALUE_0="openssl"}`;
  constraints-блок промпта при этом описывает доступную сеть. При `off` вызов и промпт
  полностью офлайновые (прежнее поведение). Ключ читает **только** `coder_codex`;
  `reviewer_codex` всегда `--sandbox read-only` и сеть игнорирует. TLS-матрица Windows
  (песочница = restricted token, schannel не работает — `SEC_E_NO_CREDENTIALS`, и
  `sandbox_permissions=["disk-full-read-access"]` не спасает: ограничение на уровне LSA):
  node/npm, python/pip, uv — работают напрямую (OpenSSL/rustls); git — только с
  `http.sslBackend=openssl`; cargo (libcurl+schannel) не работает даже с сетью → его сетевые
  шаги идут через брокер (T-063). Актуальный Codex снова поддерживает два native Windows
  режима: `[windows] sandbox="elevated"` (официально рекомендуемый, требует admin setup) и
  fallback `unelevated` с restricted token. Orchestra не меняет пользовательский профиль
  сама и сохраняет fail-closed fallback для `unelevated`.
- **Классификация средовых сбоев codex (`ENV_LIMIT`, T-062).** Часть провалов `codex exec`
  — не качество правок, а ограничения песочницы, которые повторный прогон не лечит; поэтому
  `coder_codex`/`reviewer_codex` распознают их сигнатуры **первой же** итерацией (не «в лоб»
  до лимита 3) и реагируют по классу. Классы и сигнатуры (эмпирически проверены на
  codex-cli 0.142.5 / Windows, restricted-token-песочница; перечень расширяемый, уточняется
  аудитом T-067): `sandbox-init-worktree` (`cannot enforce split writable root sets
  directly` — unelevated Windows sandbox отверг именно nested task-worktree root shape);
  `sandbox-init` (`CreateProcessAsUserW failed: 5` — отказ поднять
  restricted-token песочницу; исполнять команду вне неё запрещено — fail-closed, T-069);
  `network` (`Failed to connect` / `Could not resolve host` / ошибки registry
  crates.io·npm·PyPI — сеть закрыта, `CODEX_NETWORK: off`); `tls-schannel`
  (`schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS` — cargo и дефолтный git
  на schannel); `vcs-write` (`Unable to create … index.lock: Permission denied` — запись в
  git-метаданные запрещена всегда, часть гарантии «без коммитов»); `profile-denied`
  (`Permission denied` на части профиля `~/.config/git/ignore`·`~/.ssh/config`). Runtime
  проактивно создаёт `<WT>/.work/codex-cache`, перенаправляет туда TEMP и writable caches
  uv/pip/npm/XDG/Python. В `workspace-write` cache уже внутри writable workspace и
  избыточный `--add-dir` не передаётся (иначе unelevated Windows мог сформировать split-root
  отказ); узкое исключение `--add-dir` остаётся только у `read-only` reviewer;
  поэтому повторяющийся `%LOCALAPPDATA%\uv\cache: Access is denied` устраняется без
  расширения записи за worktree. `~/.cargo`/NuGet homes намеренно не перенаправляются, чтобы
  не скрыть предзагруженные зависимости. Кроме `codex exec -C <WT>`, runtime механически
  ставит `ProcessStartInfo.WorkingDirectory=<WT>`: Codex и унаследовавшие cwd helpers не
  могут стартовать из default/main workspace processor'а и оставить draft не в той jj-копии.
  Реакция: в `coder_codex` для `network`/`tls-schannel` — передать
  сетевой шаг **брокеру зависимостей** (реализован T-063, см. ниже); эскалация с классом —
  только если брокер за 2 цикла не снял барьер или запрошенная `NEED_NET`-команда вне
  allowlist; для `vcs-write`/`profile-denied`/неизвестного — немедленная эскалация без
  брокера. В `reviewer_codex`
  (read-only, без сетевых шагов) на любой класс — **всегда** эскалация без брокера. Сентинел
  обратно совместим: префикс `ЭСКАЛАЦИЯ codex: CODEX_FAILED` не меняется (processor
  распознаёт его без правок), класс лишь дописывается в причину —
  `CODEX_FAILED — ENV_LIMIT/<класс>: <кратко>`; в отчёте `ENV_LIMIT/<класс>` = «среда не
  позволяет», обычный `CODEX_FAILED` = «codex не справился». Несредовые (логика/качество)
  сбои идут прежним циклом до 3 итераций.
- **Fail-closed при отказе инициализации песочницы codex (T-069).** На Windows
  restricted-token-песочница codex **структурной** изоляции записи не гарантирует, а при её
  сбое запуска (`CreateProcessAsUserW failed: 5`, доступ запрещён) неинтерактивный `codex exec`
  под дефолтной `approval_policy` (`on-request`/`on-failure`) мог бы молча продолжить
  выполнение **без** изоляции (fail-open, подтверждено архивом T-067/T-068). Закрыто двумя
  мерами в обоих адаптерах: (1) на **каждом** вызове пинится Orchestra-фиксируемая политика
  `-c approval_policy=never` (config-оверрайд, не CLI-флаг — `--ask-for-approval` `codex exec`
  0.142.5 не принимает; значение **не** зависит от пользовательского `~/.codex/config.toml`),
  под ней codex не повышает режим исполнения вне песочницы; (2) сигнатура отказа песочницы —
  новый ENV_LIMIT-класс `sandbox-init` — распознаётся первой же итерацией и ведёт к
  немедленной эскалации `CODEX_FAILED — ENV_LIMIT/sandbox-init` **до любых правок** (без
  брокера/ретрая: единственный «обход» отказа песочницы — исполнение без изоляции, а его и
  закрываем). `coder_codex` при этом не оставляет изменений в рабочей копии (откат как при
  любом `CODEX_FAILED`), `reviewer_codex` не трогает `review.md`; сентинел обратно совместим
  (префикс `CODEX_FAILED` не меняется), processor штатно откатывается на Claude. `error 5`
  (отказ песочницы, эскалируем) не путать с `error 2` (файл не найден — восстановимо, вызов
  абсолютным путём работает). Контрактный тест — `tools/check-codex-sandbox-guard.ps1`.
- **Fail-closed валидация значений Codex-ключей (T-072).** Шесть ключей —
  `CODEX_CODER`/`CODEX_REVIEWER`/`CODEX_CIFIX`/`CODEX_REASONING`/`CODEX_SANDBOX`/
  `CODEX_NETWORK` — имеют строго ограниченные множества значений; невалидное значение —
  ошибка конфигурации, останавливающая запуск когорты **до захвата задач** (processor
  Фаза 1.1) с указанием ключа/значения/допустимых, а не молча заменяемая default. Единый
  источник множеств+defaults — таблица «Допустимые значения Codex-ключей» в
  `config.example.md`; её копию несёт `cc-doctor` (единый движок `tools/doctor-runtime.ps1`,
  зеркалируемый рядом с launcher'ами для mirror-совместимости) и ветвление `processor.md`
  (`KEY ∈ {…}`). `CODEX_SANDBOX` исключает `danger-full-access` (граница записи песочницы);
  `reviewer_codex` всегда принудительно read-only. Копии не расходятся — стережёт
  контрактный тест `tools/check-codex-config-guard.ps1` (та же архитектура «hardcode +
  guard», что и allowlist ключей в `tools/check-consistency.ps1`, класс 4).
- **Исполняемая граница policy/config (T-084).** Единый versioned schema source
  `tools/policy-schema.ps1` (`Get-OrchestraSchema`) описывает и `config.md` (типы, defaults,
  enum/range, scope precedence, чувствительность), и разделы политики `constraints.md`.
  Каноническое извлечение `KEY: value` и отсечение Markdown inline-комментария живёт отдельно
  в `tools/common.ps1::ConvertFrom-OrchestraConfigLine`: `#` внутри токена сохраняется,
  whitespace-delimited `#` начинает комментарий, а значение с ведущим `[` сохраняется целиком
  для JSON-массива `VERIFICATION_COMMANDS`. `policy-schema`, `verification`, `notify`,
  `metrics` и зеркалируемый `doctor-runtime` используют этот один примитив и оставляют у себя
  только доменную валидацию/first-vs-last-match политику. CLI `tools/policy.ps1` (companion
  `state-tx.ps1`/`queue-tx.ps1`) исполняет: `validate-config`
  (при `--work` проверяет и project config, и effective root-config; неизвестный/
  дублирующийся/невалидный ключ fail-closed, а не тихий default),
  `validate-policy`, `migrate` (перенос старого `config.md` на схему без потери
  значений/комментариев, append-only), `guard-path` (гард destructive-операций: реальная
  канонизация пути по symlink/junction, корень/объект/leaf, id задачи/батча, VCS-регистрация
  worktree и **точное совпадение** VCS-root с адресованным worktree; pure-jj workspace
  отклоняется как Git, даже если `git rev-parse` нашёл родительский `.git`; отказ на
  `..`/escape/подмену), `check-paths` (фактические пути против denylist
  после каждого возврата исполнителя и перед commit/merge/publication) и `check-publish`
  (allowed branch/remote + push/merge policy как технический precondition, не текстовый
  отчёт). `Get-PathComparer` применяется только к файловым путям; git refs, remotes и SHA
  сравниваются ordinal case-sensitive на всех ОС. processor встраивает эти вызовы в Фазы
  1.5/5.3, merger — в свой merge-self-check.
  Список ключей и Codex-enum'ы схемы **машинно-сверяются** с `config.example.md`
  (`tools/check-consistency.ps1`, класс 5), а та — с `cc-doctor` (класс 4): движок
  `cc-doctor` (`tools/doctor-runtime.ps1`) держит копию хардкодом (mirror-совместимость),
  но со схемой разойтись не может. Класс 1 того же guard отличает operator config от
  производных reviewer-handoff полей: `REVIEW_STRICT`, `REVIEW_FINAL_CLEAN_PASSES` и
  `VERIFICATION_EVIDENCE` входят в явный non-key allow-list, а не раздувают публичную
  config-схему. Класс 9 проверяет каждый **отдельный** шаблон dispatch в
  `agents/processor.md`: если инструкция передаёт `SMOKE_CMD=`, в ней же обязательны
  `CALL_DEADLINE_SEC=` и `CALL_OUTPUT_MAX_BYTES=`. Единица проверки — непрерывная цепочка
  полей `KEY=` одной инструкции (её обрывают пустая строка и проза вне inline-кода), а не
  Markdown-абзац целиком: в одном абзаце их регулярно два (Фаза 2.8 держит R-фикс
  исполнителя и повторное ревью рядом), и бюджеты соседнего вызова за неполный dispatch не
  отвечают. Положительный, отрицательные и смешанный (неполный и полный dispatch в одном
  абзаце) фикстурные случаи выполняет `tests/test-consistency.ps1`; дрейф копий класса 4,
  которые схема (а не `config.example.md`) держит единственным источником —
  root-config descriptors, `$claudeModelAllowed`, `$claudeModelFrontmatter`, — ловит
  `tests/test-consistency-model-keys.ps1`. Тесты policy — `tests/test-policy.ps1`.
  В полностью автономном режиме operator-owned root-config key
  `ORCHESTRA_AUTO_APPROVE: on` в `~/.orchestra/root-config.md` заранее разрешает внутренние human gates во всех проектах:
  `approval-request` всё равно сохраняет обычный одноразовый артефакт, fingerprint кода,
  snapshot политики и deadline, но сразу записывает `decision=approve` с
  `decided_by=root-config:ORCHESTRA_AUTO_APPROVE`; `approval-status` также может безопасно
  потребить существующий свежий pending-запрос при crash recovery. Весь read-check-write
  цикл ручного решения и обеих веток auto-approve сериализуется общим
  `.work/approvals/approvals.lock` через `Acquire-Lock`/`Release-Lock`, поэтому одноразовый
  ID не может получить два решения, а системное решение не перетирает конкурентное
  операторское. `Write-JsonAtomic` остаётся атомарной записью отдельного артефакта; лок
  защищает именно составную транзакцию. `off`/unset оставляет ручное решение, любое другое
  значение fail-closed. Это не Claude/Codex permission и не ключ `.work/config.md`; агенту
  запрещено устанавливать переменную самому.
- **Read-only агрегация эксплуатационных метрик (T-249).** `tools/metrics.ps1 aggregate`
  читает `.work/events.jsonl` ленивым построчным forward-decode (битая/оборванная строка
  пропускается независимо, последующие валидные события сохраняются), дедуплицирует по
  `event_id` и дополняет только отсутствующие поля из завершённых batch-блоков
  `.work/journal.md`. Срез задаётся взаимоисключающими `--last N` / `--since YYYY-MM-DD`
  (default `--last 10`); таблица показывает средние/nearest-rank p95 R-, F-, CI-попыток,
  lead time `task.captured` → verified, доли эскалаций/карантинов и recovery после
  наблюдаемого прерывания. Стоимость на завершённую задачу считается только из явных
  token-usage/cost полей событий; до появления T-248 она выводится `недоступно`, не нулём и
  не оценкой из prose-журнала. Инструмент не пишет в `.work/` и не берёт
  `orchestrator.lock`. The `cc-metrics.cmd`/`.sh` wrappers resolve checkout
  `tools/metrics.ps1`, then the `cc-sync` shared mirror at
  `~/.orchestra/scripts/metrics.ps1`, with a legacy flat-mirror fallback beside the
  launcher. Детерминированный тест — `tests/test-metrics.ps1`,
  явно подключённый к job `validate` в `.github/workflows/ci.yml` (K-007).
- **Пер-задачная архивная проекция.** `tools/metrics.ps1 task --work <.work> --task-id
  <T-ID> --batch-id <B-id>` соединяет строгие `operation.completed` с `usage.recorded` по
  replay-stable координатам вызова и строит блок `orchestra/task-execution-metrics@1` для
  `Tasks_Done.md`: lead time, каждую итерацию, полную/распределённую длительность (включая
  точные `ms`) и раздельные
  actual/estimated/unavailable токены. Общие cohort/integration вызовы материализуются на
  каждую затронутую задачу, но делятся на `shared_task_count`, поэтому сумма архивных итогов
  отражает стоимость вызова с точностью округления, не умножая её на размер когорты.
  `EVENTS_OUTBOX:off`, битые/пропущенные события и
  недоступный provider usage сохраняются как `partial|no_data|error`/`недоступно`, не нули.
  Processor строит дескриптор+метрики до удаления task-артефактов и добавляет их одной
  replay-safe архивной записью. Crash-residue «заголовок есть, marker нет, живой descriptor
  остался» пересобирается заменой всей секции; terminal `выполнена` с живым descriptor имеет
  явный resume-маршрут и idempotent re-emit `published→done` перед проекцией. Старые записи
  без живого descriptor не переписываются.
  Для `operation.completed` её explicit `batch_id` авторитетен (он входит в UUIDv5), поэтому
  planning recaptured-задачи не наследует прошлый batch до нового `task.captured`.
  Общий vocabulary model/non-model/core операций живёт в `tools/events-common.ps1`; writer
  `outbox.ps1` и consumer `metrics.ps1` используют одни и те же наборы без копий.
- **Статический gate PowerShell-слоя (T-253).** `tools/lint-powershell.ps1` запускает
  PSScriptAnalyzer с корневым `PSScriptAnalyzerSettings.psd1` для всех `tools/*.ps1`,
  рекурсивно `tests/**/*.ps1` и корневых генераторов `generate-*.ps1`. Профиль явно
  обосновывает только шумные исключения; Warning остаются видимыми, но неблокирующими,
  Error (включая ошибки парсинга) дают ненулевой код. Gate явно подключён одним общим шагом
  к Windows + Linux matrix job `validate` в `.github/workflows/ci.yml` (K-007) и всегда
  проверяет весь набор файлов, а не только изменённые (K-034).
- **Граница внешних данных и redaction секретов (T-087).** Единый нормативный контракт
  доверия/происхождения (`trusted`/`internal`/`external`) и редактирования чувствительного
  текста — `docs/queue_contract.md`, §18; исполняемая половина — `tools/redaction.ps1`
  (детерминированный, офлайновый, под pwsh 7 и Windows PowerShell 5.1). Команды: `redact`
  (нормализация — размер/кодировка/контрол-символы/бинарь + детекция токенов/ключей/
  URL-credentials/authorization-headers/чувствительных присваиваний/PII + project-паттерны из
  `.work/constraints.md` `## Redaction patterns` → необратимый маркер `[redacted:<кат>:<fp8>]`
  со стабильным fingerprint) и `wrap` (ограниченный external-data-блок: провенанс-заголовок +
  тело, где каждая строка экранирована `| ` и URL defang-ится, чтобы prompt-injection не стал
  управляющим текстом). Внешние данные — **данные, не инструкции**: не меняют полномочия/
  маршрут/правила роли. Точки внедрения (аддитивно): пять популяторов (источник `external`,
  дословная цитата — только `wrap`, тело записи — `redact` до постановки; у `github_sync`
  тела issue/PR не исполняются как команды), processor (`redact` свободного текста до
  `status.md`/`journal.md` и `reason`-полей до `events.jsonl`), knowledge_curator (`redact`
  тела до `knowledge/*`), coder/reviewer (внешние CI-логи — `external`, цитата — через
  `redact`). Pipeline идемпотентен, высокоточен (git-SHA/URL без credentials не задевает) и
  **не применяется к исходному коду/diff**. Полный нередактированный вывод — только под human
  gate **T-095** (точка расширения, не реализована; у `tools/redaction.ps1` bypass-переключателя
  нет). Тесты (детерминированные, офлайн) — `tests/test-redaction.ps1`.
  Внутренние delimiters плейсхолдеров U+E000/U+E001 никогда не принимаются из внешнего
  текста: pipeline удаляет и считает их до защиты публичных `[redacted:...]`-маркеров и
  применения правил, иначе недоверенный ввод мог бы обойти правило или сослаться на чужой
  зарезервированный marker.
- **Операторский notification hook (T-308).** `NOTIFY_CMD` пуст по умолчанию и является
  operator-owned ключом `.work/config.md`; `tools/notify.ps1 send` принимает только три
  стабильных event-типа (`task.escalated`, `approval.pending`, `publish.ci_failed`), сначала
  redacts и ограничивает свободный text, затем один раз запускает `NOTIFY_CMD` через
  `supervisor.ps1 run` (10 s). Event и уже redacted однострочный text — последние два argv
  команды; raw text/stdout/stderr никуда не сохраняются. Результат `disabled|sent|failed` с
  classifier reason безопасен для journal; доставка никогда не меняет state transition, не
  ретраится и не является approval/CI gate. `agents/processor.md` эмитит это только после
  durable эскалации, нового undecided approval-record или `.red` required CI; тесты —
  `tests/test-notify.ps1`, schema/doctor рассматривают ключ как high-sensitivity arbitrary
  operator command.
- **Защита `reviewer_codex` от негабаритного diff (T-066).** Инструкция «большой diff
  вставляй как есть» рискует молчаливой обрезкой контекста на стороне codex на крупных
  задачах (генерация кода, массовые переименования, vendoring) — обрезка дала бы формально
  пройденный гейт `SUMMARY-R` при фактически неполном ревью, что хуже честного отказа.
  Порог — **4000 строк** unified diff (`wc -l`, до вставки в промпт), считается на первом и
  на инкрементальном (повторном) ревью одинаково. `≤ 4000` — как раньше, вставляется целиком.
  `> 4000` — codex не запускается вовсе (0 прогонов, `review.md` не трогается), сразу
  эскалация `ЭСКАЛАЦИЯ codex: CODEX_FAILED — DIFF_TOO_LARGE: <N> строк …` — совместимый
  сентинел (тот же префикс `CODEX_FAILED`, что и у `ENV_LIMIT`), processor штатно откатывает
  ревью на Claude-`reviewer_std`/`reviewer` по уровню задачи. Выбрана эскалация, а не
  чанкование ревью по файлам отдельными прогонами: агрегация находок из непересекающихся
  чанков плохо сочетается с правилами fast-path/«стоп после 5 прогонов» (рассчитаны на
  повторные прогоны **одного** diff) и не ловит межфайловые связи (вызывающий код в одном
  файле, изменённая сигнатура — в другом); при необходимости чанкование может быть добавлено
  позже как отдельный fallback на этом же пути эскалации.
- **Петля обучения по ENV_LIMIT (T-065).** `ENV_LIMIT/<класс>`-эскалации — устойчивое
  свойство репозитория/окружения (если область задачи требует сеть/`schannel`/запись в
  git-метаданные, которых codex-песочница не даёт, повторный прогон это не лечит), поэтому
  знание о них замкнуто в петлю: `knowledge_curator` на джойн-барьере (Фаза 5.5) харвестит
  такие эскалации из дайджеста батча в pitfall-записи `.work/knowledge/pitfalls/` со
  `scope` по области задачи и литералом класса в теле записи (формат — см.
  `knowledge_curator.md`); `processor.md`, прежде чем в Фазах 2.2/2.8 отдать задачу
  `coder_codex`, сверяется с такими записями (раздел «Codex-исполнитель и маршрутизация»)
  — область покрыта записью с классом, не разрешимым текущей обвязкой (`vcs-write` —
  никогда; `network`/`tls-schannel` — пока не включены брокер T-063/`CODEX_NETWORK`) →
  сразу роутит на Claude-уровень задачи вместо пустого codex-прогона. Записи подчиняются
  штатным TTL/инвалидации куратора (см. `knowledge_curator.md`) — отдельного постоянного
  бан-листа codex нет: включили `CODEX_NETWORK`, обновили codex, diff батча задел
  `scope` — запись переоценивается на следующем харвесте.
  После расширения брокера capability текущей Orchestra важнее исторической причины:
  project-wide `ENV_LIMIT/network` запись о NuGet/dotnet не блокирует задачу с явным
  `Экосистема: nuget`, потому что `broker-run` теперь даёт ей поддерживаемый путь. Первый
  штатный вызов служит живой перепроверкой; реальный повторный отказ всё равно уйдёт в
  fallback и будет заново захарвещен, поэтому это не fail-open и не вечное игнорирование KB.
  `sandbox-init-worktree` — отдельное project-wide исключение: хранится со scope
  `runtime:codex-worktree`, не смешивается с общим host `sandbox-init`, требует exact-
  worktree no-model probe и одного последовательного Codex canary перед повторным включением.
  Подтверждённая дважды запись защищена от обычного TTL/cap и снимается только после двух
  успешных canary в разных сессиях либо проверенной поправки. Куратор в начале каждого
  прохода восстанавливает производный `INDEX.md` из shard-файлов, поэтому пропавшая строка
  индекса не делает запись невидимой и не является основанием удалить shard.
- **Codex sandbox-init: непостоянство и preflight (T-117).** Прямое воспроизведение на этом
  Windows-хосте (codex-cli **0.144.1**, несколько прогонов, разные диски C:/D:, каталоги и
  задачи — и spawn команды в песочнице, и реальная запись файла): `codex exec --sandbox
  workspace-write` и дешёвый `codex sandbox -c sandbox_mode=workspace-write` поднимали
  split-writable-root песочницу **успешно** (`sandbox: workspace-write [workdir, /tmp,
  $TMPDIR]`), сигнатура `CreateProcessAsUserW failed: 5` / «cannot enforce split writable
  root» **не воспроизвелась ни разу**. Гипотеза о недостающих привилегиях **опровергнута**:
  токен процесса НЕ содержит `SeAssignPrimaryTokenPrivilege`/`SeIncreaseQuotaPrivilege`
  (`whoami /priv`), но restricted-token-песочница всё равно поднимается — эти привилегии для
  codex-spawn в данной конфигурации не требуются, а значит их ручная выдача через
  `secpol.msc`/групповую политику ремедиумом **не является**. Определённый исход
  исследования (не оставлен открытым): **это не постоянная misconfiguration хоста, а
  непостоянное/интермиттентное ограничение codex-песочницы на Windows** — уже в прошлой
  сессии оно было недетерминированным (6 из 8 эскалаций, 2 успеха), а на 0.144.1 не
  воспроизводится вовсе (таблица ENV_LIMIT выше калибровалась на 0.142.5 — сигнатура
  зависит от версии/состояния). Никакого ручного шага оператора как обязательного **не
  требуется**; конвейер привилегии сам НЕ повышает (это в любом случае был бы ручной шаг
  человека, а не действие агента). Поскольку отказ непостоянен и самовосстанавливается, его
  **нельзя** фиксировать вечной KB-записью — надо **измерять живьём каждую сессию**. Отсюда
  механизм снижения издержек: дешёвый однократный **preflight** `tools/codex-preflight.ps1`
  — запускает `codex sandbox -c sandbox_mode=workspace-write -- <noop>` (та же
  restricted-token-песочница, что у `codex exec`, но ~1 c, БЕЗ модельного вызова, сети,
  токенов и без касания VCS) и классифицирует исход **той же** таблицей сигнатур, что
  `codex-runtime.ps1` (дот-сорсит её — `sandbox-init` = `CreateProcessAsUserW failed: 5`
  живёт в одном месте). processor зовёт его **один раз за сессию**, лениво перед первым
  реальным диспетчем в `coder_codex`/`reviewer_codex` и только при включённой
  Codex-маршрутизации (`CODEX_CODER`/`CODEX_REVIEWER`/`CODEX_CIFIX` ≠ `off`): `decision=
  downgrade` (лимит живой сейчас) → на остаток сессии codex-исполнитель/ревьюер меняются на
  Claude уровня задачи с явной пометкой в обзор/`journal.md`, **без** пустого модельного
  codex-прогона; `decision=unchanged` (штатный случай, в т.ч. когда сигнатура не
  воспроизводится) → маршрутизация не меняется; codex не найден/проб неоднозначен → тоже
  `unchanged` (деградация без ошибок, preflight не блокирует конвейер). Инвариант fail-closed
  T-069 не ослаблен: preflight — чисто **маршрутизирующее** решение ДО вызова (убирает
  заведомо обречённые вызовы), codex по-прежнему никогда не исполняется вне песочницы —
  авторитетом остаётся fail-closed-эскалация адаптеров (`tools/check-codex-sandbox-guard.ps1`
  зелён без изменения условий). На хостах, где сигнатура не встречается, поведение прежнее, а
  проб и вовсе не запускается, если сессия не роутит в codex.
- **Worktree-specific Windows sandbox probe.** Общий T-117 probe в throwaway-каталоге не
  покрывает подтверждённый `ENV_LIMIT/sandbox-init-worktree`: unelevated restricted-token
  sandbox мог отказать только для `.work/worktrees/<T-ID>`, при успешных reviewer/read-only
  и main-tree CI-fix в той же сессии. Поэтому processor перед первым worktree-coder вызовом
  запускает `codex-preflight.ps1 --workspace <точный WT>`; runner механически задаёт этот
  `WorkingDirectory`. Отказ отключает только Codex coder для task worktree до конца сессии,
  не reviewer/main-tree. Активная KB-запись требует после чистого probe ровно одного
  последовательного canary; успех включает последующие волны, повтор класса сразу ведёт
  остаток на Claude. Сам runtime устраняет известную причину: cwd и `-C` совпадают с WT,
  `workspace-write` не получает redundant nested `--add-dir`.
- **Первопричина split writable-root и её устранение в runtime (T-279).** Предметно
  установлено, что «split writable root» codex видит **не** из-за `-C`, **не** из-за
  вложенности task worktree в основной чекаут и **не** из-за того, что общий jj-стор лежит вне
  worktree (`.work/worktrees/<T-ID>/.jj/repo` — файл-указатель `../../../../.jj/repo`; op-log/
  view/backing store физически в корне основного чекаута, а первый `.git` при подъёме вверх —
  тоже корень основного чекаута, 4 уровня выше): codex jj-неосведомлён и в `.jj/repo` сам не
  пишет. Причина — **дефолт самого codex для `workspace-write`**: он выдаёт не один корень, а
  **набор** — эмпирически `sandbox: workspace-write [workdir, /tmp, $TMPDIR]` (три
  разъединённых корня). Windows unelevated restricted-token backend не умеет форсить *split*
  (мульти-корневой) writable-набор и отказывает ровно этой сигнатурой; POSIX-backend
  (landlock/seccomp) такой набор форсит штатно — отсюда Windows-only характер класса и то, что
  reviewer (`read-only`) и main-tree CI-fix (workdir=корень репо) не задеты. Runtime закрывает
  причину у источника: на native Windows для `workspace-write` он добавляет
  `-c sandbox_workspace_write.exclude_slash_tmp=true` и
  `-c sandbox_workspace_write.exclude_tmpdir_env_var=true`, убирая **собственные** лишние корни
  codex `/tmp` и `$TMPDIR`; остаётся ровно `[workdir]` — единственный корень, который backend
  форсить умеет (проверено на codex-cli 0.144.6: под `--strict-config` оба ключа приняты,
  строка песочницы становится `workspace-write [workdir]`). Безопасно: runtime и так
  перенаправляет TEMP/TMP внутрь `<WT>/.work/codex-cache` (вложено в workdir, остаётся
  writable), поэтому ни одна легитимная временная запись Windows не покидает единственный
  корень. Ключи идут **без** `--strict-config` (runtime его не ставит): старый codex, не
  знающий их, молча игнорирует (graceful no-op), новый — применяет. Preflight/exact-worktree
  probe/canary/фолбэк на Claude сохранены как defense-in-depth для иных версий/хостов; на POSIX
  `/tmp`/`$TMPDIR` остаются writable для инструментов. Дополняет K-038 (нельзя доверять прозе
  эскалации codex про `ENV_LIMIT/sandbox-init` — всегда сверяйся с живым worktree): сигнатура
  не только ненадёжна в самоотчёте, но и недетерминирована у источника, а её контролируемая
  из orchestra часть теперь закрыта. Покрытие: `tests/test-codex-runtime.ps1` (секция 10a,
  argv-уровень, платформо-зависимо) и статический guard `tools/check-codex-sandbox-guard.ps1`
  (`worktree-single-root-collapse`).
- **Сетевой брокер зависимостей `coder_codex` (T-063).** Единственное **исключение** из
  инварианта «код правит только codex»: адаптер `coder_codex` **сам** (не codex) выполняет
  строго ограниченный **allowlist** канонических lock/fetch-команд по экосистемам
  (`cargo update`/`cargo fetch`, `npm install`/`npm ci`, `pip install -r`/`pip download`,
  `uv lock`/`uv sync`, `dotnet tool restore`, `dotnet restore [relative
  project-or-solution]`; расширяемо) в worktree задачи **вне** песочницы codex через
  `codex-runtime.ps1 broker-run`. Runtime повторно валидирует allowlist, запускает tool/args
  как argv без shell-интерполяции и применяет общий timeout/whole-process-tree cleanup;
  поэтому broker-команда использует уже предвыданный runtime-grant и не оставляет
  dotnet/MSBuild workers. Мотив — TLS-матрица Windows: schannel в restricted-token-песочнице
  мёртв, а NuGet/dotnet в реальных проектах повторяемо падает на TLS/проверке подписи
  репозитория даже при `CODEX_NETWORK: on`; у адаптера TLS и сеть рабочие. Брокер
  регенерирует lock-файлы (легитимная часть результата задачи, а не нарушение инварианта) и
  наполняет кэш (`~/.cargo`, npm/pip/NuGet cache), который песочница codex затем **читает**
  для офлайн-сборки; сам VCS брокер не мутирует (гарантия «без коммитов» цела).
  **Проверенный сквозной пример:** `cargo update`+`cargo fetch` снаружи
  песочницы (от имени адаптера, у которого есть сеть) → `cargo build --offline` внутри
  песочницы — сборка успешна, кэш `~/.cargo` изнутри читается. Два триггера: (а)
  детерминированная постлюдия — изменён манифест зависимостей + сборка/smoke упала с
  сигнатурой `network`/`tls-schannel` (адаптер сам выбирает команду из таблицы — инъекция
  произвольной команды невозможна); (б) явный протокол codex `NEED_NET: <команда>`,
  валидируемый по allowlist (метасимволы оболочки и всё вне таблицы отклоняются). Брокер-шаг
  не тратит бюджет 3 адаптерных итераций; на задачу — ≤2 брокер-цикла, дальше эскалация тем
  же классом `CODEX_FAILED — ENV_LIMIT/<класс>`. `reviewer_codex` брокера **не имеет**
  (read-only, сетевых шагов нет).
- **Маршрутизация сетевых задач по полю `Сеть:` (T-064).** `planner.md` при составлении
  дескриптора проставляет задаче с сетевым признаком (правка манифеста зависимостей,
  апгрейд-формулировки, сетевые тесты) поле `Сеть: требуется` + `Экосистема:
  <cargo|npm|pip|uv|nuget|прочее>`. `processor.md`, прежде чем по обычному резолверу (`CODEX_CODER`)
  отдать задачу `coder_codex`, сверяет по этому полю доступность сетевого пути — класс
  сетевой задачи → путь codex:
  - `cargo`/`npm`/`pip`/`uv`/`nuget` (манифест/lock менеджера зависимостей) — сетевой брокер
    обслуживает эти экосистемы **безусловно** (плюс прямая сеть песочницы при
    `CODEX_NETWORK: on` для npm/pip/uv/openssl-git) → `coder_codex` доступен **всегда**;
  - `прочее` (сетевые тесты, скачивание внешних ресурсов, произвольные сетевые вызовы — вне
    allowlist брокера) — единственный путь codex это прямая сеть песочницы →
    `coder_codex` доступен только при `CODEX_NETWORK: on`; при `off` processor сразу
    использует Claude-исполнителя уровня задачи, без пустого codex-прогона.
  Отсутствие поля `Сеть:` в дескрипторе — прежнее поведение (маршрутизация только по
  `CODEX_CODER`, обратная совместимость со старыми дескрипторами).
- **Разрешение на запуск codex — предвыдаётся, а не выпрашивается по ходу.** В auto-режиме
  classifier Claude Code отклоняет автономный запуск codex как «запуск автономного агента»,
  причём посреди прогона. С T-075 адаптеры гонят codex через runtime-обёртку — реально
  исполняемая Bash-строка это `pwsh -File <runtime> …` (сам `codex exec` обёртка
  порождает дочерним процессом мимо permission-гейта Bash), где **`<runtime>` — одна из ДВУХ
  литеральных форм резолвинга пути (T-114)**: `tools/codex-runtime.ps1` (чекаут репозитория
  orchestra) либо `~/.claude/scripts/codex-runtime.ps1` (тильда литеральна, не раскрывается
  адаптером — зеркало `cc-sync` в любом целевом проекте без трёх identity-маркеров Orchestra;
  наличие собственной `tools/` этого не меняет; см.
  `agents/coder_codex.md`, «Резолвинг пути к runtime»). Обе формы — самостоятельные
  Bash-паттерны, ниже равноправны, если не оговорено иное. Launcher'ы
  `cc-processor`/`cc-resume` (`.cmd` и `.sh`) передают сессии **два** сессионных гранта
  `--allowedTools`, покрывающих только checkout-форму: `Bash(pwsh -File
  tools/codex-runtime.ps1:*)` и `Bash(codex exec:*)` (исторический якорь); запуск launcher'а
  пользователем = согласие, explicit allow-правило проверяется permission-движком **до**
  classifier'а и снимает отказ. Правила **префиксные**. Нестандартный `CODEX_CMD` передаётся
  обёртке аргументом `--codex-cmd`, поэтому под соответствующий грант попадает тоже — своего
  правила не требует; отказ classifier'а → штатная эскалация `CODEX_UNAVAILABLE`, адаптерам
  запрещено править `.claude/settings*` для самопредоставления прав. Комплементарно:
  `cc-config` обеспечивает **постоянный** канонический allow-список — ТРИ правила
  (`Bash(pwsh -File tools/codex-runtime.ps1 *)` и `Bash(pwsh -File
  ~/.claude/scripts/codex-runtime.ps1 *)` — обе формы фактической команды — плюс якорь
  `Bash(codex exec *)`) в `.claude/settings.local.json`: если файла нет — создаёт его; если
  файл есть, но какого-то канонического правила в нём нет — **домерживает** только
  недостающее правило (или правила) в существующий `permissions.allow` (add-only, атомарная
  запись; прочие ключи/allow/deny/hooks сохраняются; идемпотентно по подстрочной
  pre-проверке), задача T-078. Это узкий пересмотр T-058 (тот убрал прежний авто-домердж,
  опасаясь «молча раздуть» файл оператора): домердж восстановлен только как добавление
  недостающего правила при явном ручном запуске launcher'а оператором — launcher никогда не
  переписывает и не удаляет чужое содержимое; вырожденные случаи (невалидный JSON,
  неожиданная форма, файл недоступен для записи, нет `jq` в `.sh`) дают явную инструкцию
  добавить правило вручную, а не тихий отказ. Канонический список — одна точка истины,
  задокументирована в `config.example.md` и повторена байт-в-байт в `cc-config.cmd`/`.sh` и в
  подсказках `cc-doctor`. Единый контракт проверки (T-071): launcher'ы `cc-processor`/
  `cc-resume` вместе с `--allowedTools` экспортируют явный признак сессионного гранта
  `CC_CODEX_EXEC_GRANT=codex exec`; при его наличии (launcher-сессия, выдавшая и runtime-грант,
  чей якорь покрывает префикс `<CODEX_CMD> exec`) постоянное allow-правило не требуется и
  статический поиск не запускается. Иначе проверяется строго массив `permissions.allow`
  settings-файлов на подстроку **любой** из двух форм фактической команды-обёртки
  (`pwsh -File tools/codex-runtime.ps1` или `pwsh -File ~/.claude/scripts/codex-runtime.ps1`)
  (совпадения в `deny`/`hooks`/комментариях **не** считаются — исключены ложные `OK`).
  Необходимость проверки — объединение всех трёх Codex-маршрутов: `CODEX_CODER` **или**
  `CODEX_REVIEWER` **или** `CODEX_CIFIX` ≠ `off`. `cc-doctor` применяет тот же контракт
  read-only и выдаёт `WARN`, когда активна любая из трёх маршрутизаций, а разрешение не
  подтверждено (при всех трёх выключенных — `OK` без гранта, WARN был бы шумом); тот же
  контракт проверяет и пер-сессионный гейт Фазы 1.1 processor'а. Нестандартный `CODEX_CMD`
  отдельного правила не требует — реально исполняемая Bash-команда остаётся той же обёрткой
  независимо от него, её и покрывает runtime-грант. Запасной путь, если версия Claude Code всё равно откажет, —
  PreToolUse-хук, возвращающий `allow` для валидированной формы; сейчас не задействован.
- **Codex-runtime всегда запускается в foreground.** Allow-правило покрывает обычный
  `pwsh -File …/codex-runtime.ps1 run …`, но добавленный агентом shell-суффикс `&` меняет
  модель исполнения: команда переживает permission-time safety check, и Claude Code снова
  запрашивает подтверждение даже для разрешённого префикса. Поэтому `coder_codex` и
  `reviewer_codex` обязаны выполнять каждый проход последовательно, без `&`, `nohup`,
  `Start-Process`, shell jobs и `sleep`+polling. Runtime ограничивает один вызов через
  `--timeout-sec 1800` и сам очищает дерево процесса. Чтобы Claude Code не перевёл долгий
  foreground tool call в фон автоматически раньше этого срока, `cc-processor`/`cc-resume`
  задают только для дочерней сессии отсутствующие `BASH_DEFAULT_TIMEOUT_MS` и
  `BASH_MAX_TIMEOUT_MS` в `1900000` (31 мин 40 с, запас 100 с); уже заданные пользователем
  или системой значения имеют приоритет. Если foreground-вызов выполнить невозможно,
  адаптер выдаёт `CODEX_UNAVAILABLE`, а не обходит границу разрешений фоновым запуском.
- **`coder_codex` не видит сгенерированные им же изображения — routing-исключение и
  частичный фикс (T-222).** У `codex exec` **нет** способа посмотреть картинку **внутри**
  одного вызова — вложение `-i/--image` работает только на **старте** конкретного вызова CLI
  (подтверждено `codex exec --help`/`codex exec resume --help`, codex-cli `0.144.1`). Следствие:
  любая задача, чьи критерии готовности требуют **реальной** визуальной проверки отрендеренного
  результата (сверка UI/CSS со скриншотом, вычисленные стили и т.п.), **предпочитает**
  Claude-`coder` с headless-браузером (на Windows-хосте подтверждено: `chrome.exe --headless
  --disable-gpu --screenshot=<out.png> --window-size=W,H file:///<path>` + мультимодальный
  `Read`) вместо `coder_codex` — даже там, где обычный резолвер `CODEX_CODER` выбрал бы codex.
  Capability-scoped исключение, не общее суждение о надёжности codex; `planner`/`processor`
  распознают такую задачу по упоминаниям скриншотов/визуального сравнения/computed style в
  критериях готовности и роутят в обход `CODEX_CODER`. Наблюдалось на исходной задаче: codex
  честно сообщил об отсутствии in-app браузера, но вместо чистой эскалации молча сузил объём
  поставки (угадал семейство тёмной темы по именам классов вместо проверки рендерингом — неверно)
  и отрапортовал завершение при внутренне противоречивом `codex_out.md`; per-task ревьюер поймал
  расхождение на первом же прогоне.
  **Частичный структурный фикс (не отменяет routing-рекомендацию выше, а закрывает пробел там,
  где задачу всё же направили на `coder_codex`).** Двухвызовный протокол под управлением
  адаптера — подтверждён эмпирически, не только по `--help`: (1) `run --emit-json` добавляет
  `--json`, чей самый первый JSONL-элемент stdout — `{"type":"thread.started","thread_id":
  "<uuid>"}`; (2) отдельный, следующий вызов `codex exec resume <thread_id> -i <картинка>
  "<промпт>"` реально вкладывает картинку как мультимодальный ввод в продолжение **той же**
  сессии — модель её видит (проверено: сплошной сгенерированный PNG цвета crimson-red, без
  единого текстового намёка на цвет в промпте, дал корректный ответ «red» именно на
  возобновлённом вызове). Важная поправка к наивному предположению: `codex exec resume` **не**
  принимает `--sandbox` вовсе (`error: unexpected argument '--sandbox' found`) — политика
  песочницы наследуется из исходного `run` этой сессии и не может быть переопределена на
  резюмировании. Реализация — `tools/codex-runtime.ps1` (команды `run --emit-json` →
  `threadId` в результате; новая `resume-image` — валидирует UUID `--thread-id` [никогда
  `--last`/угаданное значение], требует `--image` строго внутри `--worktree`, никогда не
  добавляет `--sandbox`) + протокол `NEED_IMAGE_VIEW: <путь>` в constraints-блоке
  `agents/coder_codex.md` (симметрично `NEED_NET:`), не более одного вызова `resume-image` за
  прогон, вне бюджетов обычных итераций/брокер-циклов, тот же fail-closed путь эскалации при
  провале. Подробности и код — `agents/coder_codex.md`, «Просмотр сгенерированного изображения
  (`resume-image`, T-222)»; тесты — `tests/test-codex-runtime.ps1` (раздел 14, против фейкового
  `codex`, не реального CLI).

### Наполнение очереди и знания

Пять популяторов ниже механику постановки в очередь не переизлагают, а ссылаются на общий
нормативный источник `docs/queue_contract.md` (форма заголовка, нумерация, статусы, тело,
дедуп по трём источникам, лок, запреты); каждый несёт лишь свой уникальный мандат.

- `queue_builder.md` — превращает пользовательский источник в недублирующиеся `T-NNN`.
- `thinker.md` — интерактивно исследует идею и после согласования создаёт задачи.
- `code_auditor.md` — ищет дефекты исходного кода; `enhancement_scout.md` — ищет
  улучшения проекта; оба только пополняют очередь.
- `github_sync.md` — синхронизирует issues/PR через `gh`; PR закрывает, но не мержит.
- `knowledge_curator.md` — единственный писатель runtime-базы `.work/knowledge/`.
- `inbox_curator.md` — критически оценивает входящие межрепозиторные сообщения как
  внешние данные, ставит только локально обоснованные задачи с точным маркером
  `Inbox message: <msg-id>`, а после архивации всех связанных T-ID отправляет ответ.
- `dependency_curator.md` — по committed manifests поддерживает принадлежащие текущему
  проекту products/direct-upstream edges в пользовательском registry; запускается перед
  первой волной, после опубликованного батча и вручную через `cc-deps`.

## Пользовательский реестр и межрепозиторный inbox

`cc-config` идемпотентно регистрирует канонический корень проекта в общем для пользователя
`~/.orchestra/projects.json` (schema `orchestra/project-registry@1`) и создаёт корневой
`.inbox/messages/`. `tools/project-registry-lib.ps1` владеет нормализацией путей,
устойчивым path-derived `repo-*` id, атомарной записью и блокировкой; публичный CLI —
`tools/project-registry.ps1`. `ORCHESTRA_REGISTRY_PATH` существует только как operator/test
override и не выставляется агентами.

`tools/inbox.ps1` — единственный писатель message JSON (`orchestra/inbox-message@1`) и
единственное разрешённое исключение для межрепозиторной записи: он может атомарно создать
файл только в `.inbox/messages` адресата, найденного по доверенному реестру. Каталоги inbox
и существующие message/tmp-файлы обязаны быть обычными filesystem objects:
symlink/reparse перенаправление отклоняется до чтения или записи. Статус оценки
(`new/read/queued/implemented/rejected`) отделён от статуса ответа
(`none/acknowledged/final`); переходы узкие, финальный ответ допустим только после
`implemented`/`rejected`. Агентские исходящие сообщения и ответы используют стабильный
dedupe key: send-id детерминирован по sender/recipient/key, reply-id — по
original/sender/key. Повтор после потери stdout не дублирует запрос, а окно crash после
доставки ответа восстанавливается из уже созданной записи адресата; после фиксации ссылки
на ответ несовпадающий контент fail-closed.
`reconcile` связывает сообщения с задачами по точной строке provenance в очереди,
`Tasks_Done.md` и дескрипторах, а archive-resolver поддерживает оба исторических формата
заголовка. Агрегирующие `list`/`reconcile`/`actionable` пропускают одну невалидную запись,
сохраняя валидную проекцию и возвращая diagnostics `errors`; адресные `show`/`mark`/`reply`
по-прежнему строго отвергают такую запись. Нормативный контракт — `docs/inbox_contract.md`; `cc-sync` публикует его как
`~/.orchestra/specs/Inbox_Contract.md`.

`project-registry.ps1 unregister --project <id-or-name>` удаляет только registry entry;
при live inbound dependency оно fail-closed, а явный `--detach-dependents` атомарно убирает
подтверждённо устаревшие edges и повышает generation каждого затронутого graph. Frozen release
target, недоступный до доставки, не исчезает молча: оператор завершает именно эту аудиторию
`release --resume --skip-target <repo-id> --skip-reason <text>`; запись хранит причину skip и
последующие resume больше не пытаются доставить его.

Registry entry дополнительно несёт project-owned `products`/`dependencies`. Полный
snapshot `orchestra/project-graph-snapshot@1` заменяется только через
`project-registry.ps1 graph-sync`; candidate несёт `base_graph_generation`, поэтому
меняющая stale-запись получает CAS-отказ и не перетирает новый аудит. Неизменный stale
snapshot остаётся идемпотентным. Reverse lookup `dependents` не сканирует диск.
Каждый curator пишет unique candidate под `.work/dependency_graph_candidates/`; ручной
`cc-deps` (`CALLER=manual`) при live processor lease завершается без мутации, а
processor-вызовы передают `CALLER=processor`. Общий candidate filename запрещён, чтобы
manual refresh не гонялся с post-publication refresh.
Processor-режим `release-sync` после доказанного fast-forward pull/tag создаёт под
`.inbox/releases/` каноническую `orchestra/release-notification@1`, фиксирует аудиторию и
идемпотентно рассылает `message_type=release`. Частичный retry использует `--resume`, так
что текст и target set не меняются между доставками.

Processor механически проверяет `actionable` и вызывает умного куратора только перед первой
волной planner, перед rolling top-up и после архивации. Постоянного poller нет.
`launchers/cc-inbox` даёт тот же цикл по требованию. Остальные исследующие/реализующие/
ревьюирующие роли могут отправлять подтверждённые upstream-запросы, но это не заменяет
локальный фикс/находку и не позволяет навязывать принимающему проекту дизайн.

## Резолвинг контрактов очереди/roadmap и ограничение поиска

Голые ссылки `docs/queue_contract.md` и `~/.orchestra/specs/Tasks_Queue_Format.md` в
агентских инструкциях **не являются заданием искать файл на диске**. Если роль действительно
должна прочитать контракт, она строит точный путь без обхода файловой системы:

1. Возьми уже определённый стандартным VCS-паттерном корень текущего репозитория `ROOT` и
   открой абсолютный путь `$ROOT/docs/queue_contract.md`. Не трактуй эту ссылку как путь
   относительно произвольного текущего каталога worktree.
2. Полная спецификация формата лежит ровно в `$HOME/.orchestra/specs/Tasks_Queue_Format.md`
   (PowerShell: `$env:USERPROFILE\.orchestra\specs\Tasks_Queue_Format.md`). Раскрой `HOME` /
   `USERPROFILE` в путь и открой его напрямую.
3. Для roadmap используй только `$ROOT/docs/roadmap_contract.md`; проектный runtime-артефакт
   открывай только по `$ROOT/.work/roadmap.md`. Голые `docs/roadmap_contract.md` и
   `.work/roadmap.md` подчиняются тому же правилу и не разрешают поиск файла по диску.

**Запрещён** `find /`, `find C:/`, `find / -maxdepth N`, обход всего профиля или любой иной
неограниченный от корня поиск по диску — в Git Bash/MSYS `/` означает весь системный диск и такой
вызов может остановить роль. `-maxdepth N` от `/` — **недостаточное** смягчение (не считай
ограничение глубины безопасным): на Windows обход остаётся широким уже на малой глубине (Program
Files/Windows/Users и т.п. — много подпапок), поэтому ограничивать нужно **поддеревом**, а не
глубиной. Для точного известного пути используй `Read`; для проверки используй доступный всем
ролям `Glob` либо `find`, ограниченный малым известным поддеревом (`$ROOT/docs` или
`$HOME/.orchestra/specs`).

### Классификация 71 ссылок в `agents/*.md` (T-118 → пересмотрено T-122)

Проверка T-118 разделила ссылки на **6 чтений** и **65 цитат** и дала резолвинг+запрет только
шести «чтениям» (у `queue_builder.md`, `code_auditor.md`, `enhancement_scout.md`, `thinker.md` —
`docs/queue_contract.md`; у `github_sync.md` — он же и полная спецификация `Tasks_Queue_Format.md`),
предполагая, что «чистая цитата» (номер раздела, trust/redaction `§18`, модель состояния,
резолвинг раннеров) никогда не открывается буквально. **Эта предпосылка эмпирически не
подтвердилась (T-122):** уже после публикации T-118 живой агент одной из «цитирующих» ролей
(семейство `coder`/`reviewer` несёт голую цитату `docs/queue_contract.md, §18` и вызывается чаще
прочих) всё же открыл файл буквально и, не имея дешёвого пути, импровизировал
`find / -maxdepth 6 -iname "queue_contract.md"` — частично смягчённый (глубина 6), но по-прежнему
стартующий от `/` и потому зависающий на Windows. Раскрыть, какая именно роль, по сохранённым
артефактам (`journal.md`/`events.jsonl` — только событийный outbox processor, без сырых bash-строк
агентов; транскрипты не удержаны) точно нельзя — сужено до семейства `coder`/`reviewer`.

**Пересмотренный подход (T-122).** Ручную классификацию «чтение vs цитата» заменяет
механическое правило: **каждый** `agents/*.md` (и оба `*.template.md`, откуда `generate-coders.ps1`
генерирует `coder*`/`reviewer*`), упоминающий `docs/queue_contract.md`/`Tasks_Queue_Format.md`,
несёт канонический guard «резолвинг обоих путей + запрет `find /`/`find C:/`/`find / -maxdepth N`».
**Расширение T-269:** то же механическое правило отдельно применяется к каждому агенту,
упоминающему `docs/roadmap_contract.md`/`.work/roadmap.md`: обязательны оба точных `$ROOT`-пути
из пункта 3 и общий anti-disk-walk блок. Регрессию ловит CI-проверка
`tools/check-queue-contract-path-guard.ps1` (job `validate`): любая из двух contract-семей без
своего resolution-блока либо общего запрета роняет сборку. Guard fail-closed также требует, чтобы
в `agents/*.md` оставался хотя бы один потребитель каждой семьи, и проверяет согласованность
`knowledge.md`, `docs/queue_contract.md`, `docs/roadmap_contract.md`. Файлы, не упоминающие ни
одну contract-семью (`executor.md`, `full_reviewer.md`), вне охвата.
Таблица ниже сохранена как исторический снимок классификации T-118.

| Файл | Чтение | Цитаты |
|---|---:|---:|
| `code_auditor.md` | 1 | 5 |
| `coder_codex.md` | 0 | 1 |
| `coder_deep.md` | 0 | 2 |
| `coder_fast.md` | 0 | 2 |
| `coder.md` | 0 | 2 |
| `coder.template.md` | 0 | 2 |
| `enhancement_scout.md` | 1 | 5 |
| `github_sync.md` | 2 | 8 |
| `knowledge_curator.md` | 0 | 2 |
| `merger.md` | 0 | 1 |
| `planner.md` | 0 | 2 |
| `processor.md` | 0 | 15 |
| `queue_builder.md` | 1 | 5 |
| `reviewer_codex.md` | 0 | 1 |
| `reviewer_std.md` | 0 | 2 |
| `reviewer.md` | 0 | 2 |
| `reviewer.template.md` | 0 | 2 |
| `thinker.md` | 1 | 6 |

### Конфигурация и запуск

- `config.example.md` — каноническое описание `.work/config.md`, всех defaults и
  Codex/KB-переключателей; `root-config.example.md` документирует глобальные и те же
  project-ключи для fallback. `launchers\cc-config.cmd`/`.sh` fail-closed creates a missing
  `~/.orchestra/root-config.md`, then renders `.work/config.md` as a fully commented catalog
  of every schema project key. Each block includes its schema default, allowed values,
  effect, and a generated comment with the current root-config value; an existing file is
  never regenerated. Immediately after creating or detecting that local file,
  `config-runtime.ps1` synchronously opens it through `VISUAL`, `EDITOR`, or a discovered
  console editor; only after the editor exits successfully does the launcher continue
  with constraints, permissions, registration, and inbox initialization. The same launcher
  still copies `.work/constraints.md` in full.
- `constraints.example.md` — шаблон человекочитаемой политики ограничений проекта
  (`.work/constraints.md`): denylist путей, ветки/remotes, push/merge policy, обязательные
  проверки, пороги размера, human-review категории. Сеется целиком через `cc-config`.
- `cc-processor` запускает цикл выбранного provider, `cc-resume` адресно продолжает
  Claude processor lease/session либо точный Codex thread; `cc-resume codex --from claude`
  безопасно открывает новый Codex thread поверх durable state остановленного Claude root,
  `cc-status`/`cc-journal` читают состояние, `cc-metrics` агрегирует историю read-only,
  `cc-doctor` проверяет Codex, `cc-queue`,
  `cc-thinker`, `cc-audit`, `cc-enhance`, `cc-github` запускают соответствующие роли;
  первые три принимают `codex|claude`/`--provider`, а Codex-ветка открывает обычный TUI
  через `tools/codex-role-runtime.ps1`;
  `cc-inbox` запускает ручной полный проход `inbox_curator`.
- `cc-processor`/`cc-resume` создают изолированное окружение сборок для обоих provider:
  принудительно экспортируют
  `MSBUILDDISABLENODEREUSE=1` и `DOTNET_CLI_USE_MSBUILD_SERVER=0`. Единый resolver
  `tools/processkit-runtime.ps1` предпочитает standalone `processkit-cli`: системная
  `CC_PROCESSKIT_CLI` задаёт точный executable, пустое значение включает автообнаружение в
  PATH, `off` отключает CLI. На Windows явное process-значение имеет приоритет, затем resolver
  перечитывает User/Machine scopes, поэтому операторская переменная начинает действовать даже
  в уже открытом терминале; `.cmd` launchers всегда входят через общий runtime, если он
  установлен рядом с ними. Resolver fail-closed проверяет `probe` schema 1, reserved band
  100–119 и run/control/list surfaces; legacy `CC_PROCESSKIT_PYTHON` используется только как
  fallback. Неверный явный backend — exit 10. Неинтерактивная корневая сессия получает
  durable lifecycle `.work/processes/_processor/*.processkit.jsonl`. Интерактивные Claude
  и Codex roots передают `--interactive`: CLI используется только при probe surface
  `run:--inherit-stdio`, иначе runtime предупреждает и запускает root напрямую с консолью;
  такой compatibility-root не может взять processor lease. Каждый CLI-root получает
  внутреннюю per-run `ORCHESTRA_PROCESSKIT_ROOT_RUN_ID`; `state-tx`
  acquire/takeover/verify/heartbeat для `role=processor` без валидной launcher-attestation
  fail-closed возвращают код 20 до мутации. Поэтому прямой Claude Desktop/Cowork либо
  `claude --agent processor` не запускает Orchestra вне контейнера; агенту запрещено
  выставлять/копировать marker самому. Supervisor leaf-команды всё равно сохраняют свои
  fallback. Это runtime gate, а не project config.
  `tools/codex-runtime.ps1` независимо пинит те же две .NET-переменные для каждого `codex
  exec` и уже очищает его дерево после любого исхода.
  `tools/supervisor.ps1` dot-source'ит тот же resolver и оборачивает backend'ом каждый отдельный
  внешний build/test/smoke-вызов; это закрывает Windows-разрыв, когда промежуточный parent уже
  исчез и ретроспективный PPID-walk не способен связать worker с исходным shell. На POSIX
  быстро переподчинённый background child поэтому может попасть в temporal-candidates вместо
  lineage; собственный snapshot-helper `ps` исключается, чтобы не создавать ложный candidate.
  При включённой process-диагностике Windows-fallback использует уже снятые lineage-записи:
  после tree-kill он повторно завершает и ограниченно ждёт только точные пары PID+start-time,
  поэтому snapshot survivors не опережает фактическое исчезновение потомка и PID reuse не
  может направить cleanup в чужой процесс.
  Для standalone CLI supervisor читает terminal `runner_exit`: только `source=child_exit`
  трактуется как код целевого процесса (даже если тот лежит в 100–119), тогда как
  `spawn_error`/`container_error`/`setup` являются infrastructure crash. При deadline/cancel
  он сначала адресно вызывает `processkit-cli kill --run-id`, затем оставляет прежний
  PID/PGID cleanup как защитный fallback. ProcessKit JSONL переносится рядом с process-
  diagnostics JSON и сохраняет redacted lifecycle/mechanism/cleanup evidence.
  CLI 0.3.0 имеет `run:--stdin-file`: при непустом supervisor `--stdin-text`/`--stdin-file`
  runtime создаёт случайный временный UTF-8 файл, передаёт только путь и удаляет файл после
  завершения вызова, сохраняя kernel containment. Для интерактивного root `run:--inherit-stdio`
  наследует stdin/stdout/stderr с terminal semantics. Старые CLI без surfaces по-прежнему
  безопасно деградируют: mediated input — на Python/PID-PGID с
  `containment_degraded_reason=processkit-cli-no-mediated-stdin`, Claude root — на direct
  console-attached запуск; Codex root и обычные leaf-команды используют CLI.
  Тот же capability-gate использует 0.3.0 `run:--capture-dir` +
  `run:--capture-max-bytes` + `run:--no-echo`: при положительном supervisor
  `--output-max-bytes` raw stdout/stderr ограничиваются в ProcessKit pump во время вызова,
  полный счётчик produced bytes читается из `output_captured`, а временный capture удаляется
  после построения transient output/verdict. Это устраняет прежнее неограниченное
  `ReadToEndAsync`-накопление перед постфактум-обрезкой; неполный surface или явный лимит `0`
  сохраняют старый совместимый путь. `run --detach`/`wait` сознательно не меняют foreground-
  семантику launchers: они полезны только адаптеру, который перестал быть родителем runner.
  Resource caps 0.3.0 не включаются глобальным default, потому что fail-fast `limit_hit` на
  macOS и Linux без enforceable cgroup превратил бы переносимую verification-команду в отказ.
  Если target executable не резолвится, supervisor не прячет native spawn failure за
  `setsid` exit 127 и одинаково классифицирует его как `crash` на всех ОС.
- Windows-лаунчеры `cc-processor.cmd`/`cc-resume.cmd` вычисляют корень проекта через
  `for %%I in (.) do %%~fI`, а не через `%CD%`: обычная переменная окружения `CD`
  затеняет одноимённое динамическое значение `cmd.exe` (в частности, на GitHub runner) и
  иначе может направить Codex runtime в чужой каталог.
- В `cc-resume.cmd` остаточные аргументы Codex после разбора provider собираются заново из
  сдвигаемых `%1`…`%9`: batch-команда `shift` не меняет `%*`, поэтому прямой проброс `%*`
  повторно передал бы уже потреблённый токен `codex` в runtime. Launcher-owned пара
  `--from claude` тем же разбором превращается в runtime action `handoff -HandoffFrom
  claude` и не утекает в произвольные Codex args.

## Резолвинг раннеров `tools/*.ps1` (чекаут vs зеркало)

**Единое правило для всех раннеров `tools/*.ps1`** (обобщение T-115 codex-специфичного
паттерна T-114; каноничный источник, на который ссылаются `agents/processor.md` и листовые
роли). Агенты вызывают раннеры `tools/` голым относительным путём `tools/<script>.ps1`
(`state-tx.ps1`, `queue-tx.ps1`, `outbox.ps1`, `policy.ps1`, `policy-schema.ps1`,
`redaction.ps1`, `notify.ps1`, `supervisor.ps1`, `harness.ps1`, `codex-runtime.ps1`, …). Этот путь
существует в **двух** раскладках; каждый агент, вызывающий раннер, определяет раскладку
**один раз** и держит её до конца прогона:

1. **Чекаут репозитория orchestra** — наличие `tools/<script>.ps1` само по себе не
   доказывает checkout-раскладку: целевой проект может иметь собственную либо оставшуюся от
   старой установки gitignored-копию `tools/`, которая затенит свежий runtime. Checkout
   считается доказанным, только если корень одновременно содержит три identity-маркера:
   `agents/processor.md`, `generate-codex-agents.ps1` и `tools/sync-runtime.ps1`. Используй
   **буквально** относительный путь
   `tools/<script>.ps1` — не переписывай его в абсолютный: эта литеральная форма совпадает с
   давно предвыданным Bash-грантом launcher'ов и seed-правилами `cc-config`.
2. **Зеркало `cc-sync`** (любой целевой проект, не прошедший identity-проверку checkout,
   использует provider mirror через `~/.claude`, а общий runtime через `~/.orchestra`) — его собственная/старая/gitignored папка `tools/`,
   если существует, **никогда не является источником runtime Orchestra** и не исполняется;
   `tools/sync-runtime.ps1` зеркалирует provider runtimes в `<dest>/scripts`, а общие
   `tools/*.ps1` — в `<shared>/scripts` (по умолчанию `~/.orchestra/scripts`), так что общий раннер лежит в
   `~/.orchestra/scripts/<script>.ps1`. Держи **тильду литеральной прямо в тексте команды** (не
   подставляй заранее раскрытый `$HOME` и **не** проводи путь через shell-переменную):
   **тильда раскрывается shell только как литерал в начале слова текста команды, не через
   переменную или подстановку** — `~`, пришедший из `$VAR` или иной подстановки, остаётся
   нераскрытым, и `pwsh -File` получает буквальный `~/…`, не найдя такой файл (корневая
   причина отказа T-119). Запускай раннер только через `pwsh -File …` (PowerShell 7):
   Windows PowerShell 5.1 (`powershell.exe`) под дефолтной политикой Restricted валит скрипт с
   «running scripts is disabled», а зеркальный путь **нельзя** пересобирать через
   `$env:USERPROFILE`/`$HOME` или `powershell -Command "& '…'"` (обе ловушки наблюдались у
   популяторов на `allocate-id`) — только литеральная тильда. Неизменный литеральный текст с тильдой — это ещё и то, под что
   заведены allow-правила `cc-config` (важно для codex-раннера; см. ниже).

Processor сохраняет результат как `RUNTIME_LAYOUT=checkout|mirror` и передаёт его каждому
Codex adapter. Адаптеры не повторяют filesystem-probe: это исключает
ложную локальную диагностику «runtime not found» после того, как processor уже выбрал и
использовал зеркало. Наличие runtime проверяет фактический foreground-вызов выбранной
литеральной команды; отсутствующий/невалидный handoff является ошибкой контракта вызова.

**Гранты (аудит T-115, факт, не предположение).** Дополнительных предвыдаваемых Bash-грантов
под зеркальную форму путей **прочих** раннеров (`state-tx`, `queue-tx`, `outbox`, `policy`,
`redaction`, `supervisor`, `harness`, …) заводить **не нужно**: classifier auto-режима
особым образом отклоняет автономный model runtime (`codex exec`), а
локальный `pwsh -File tools/<script>.ps1 …`/`pwsh -File ~/.orchestra/scripts/<script>.ps1 …`
для остальных раннеров он пропускает без явного гранта в **обеих** раскладках (это обычная
локальная запись в `.work/`, не автономный внешний агент). Поэтому точечная предвыдача
остаётся под `codex-runtime.ps1`, а
зеркальная форма прочих раннеров работает и без расширения `--allowedTools`/
seed-правил. `cc-sync` мирроит их файлы (Этап 1 T-115); классификатор их вызовам не мешает —
двух частей достаточно, третья (гранты) для не-codex раннеров не требуется.

`codex-runtime.ps1` — экземпляр этого же правила с одним отличием: его запуску (он гонит
автономный codex) грант **нужен**, и он предвыдаётся точечно в обеих формах (`Bash(pwsh -File
tools/codex-runtime.ps1 *)` и `Bash(pwsh -File ~/.claude/scripts/codex-runtime.ps1 *)`; см.
«Разрешение на запуск codex» ниже и `agents/coder_codex.md`, «Резолвинг пути к runtime»).
**Ловушка T-119:** зеркальную (тильдовую) форму нельзя проводить через shell-переменную
(`CODEX_RT=~/…; pwsh -File $CODEX_RT`) — `~` из переменной не раскрывается, и pwsh получает
буквальный `~/.claude/...` и падает; тильду держи литералом **прямо в тексте команды**.
Контрактный тест — `tools/check-codex-runtime-path-guard.ps1` (allow-правила чекаут/зеркало
согласованы в `cc-config.{sh,cmd}`/`config.example.md`, identity-маркеры checkout защищают
от target-local затенения, оба адаптера документируют ту же
литеральную команду, что разрешает правило, без `CODEX_RT=~`, и несут единую тильдо-оговорку).

## Разрешения auto-режима и политика «согласие — заранее»

В permission-mode `auto` classifier Claude Code может **посреди прогона** отклонить
автономную Bash-операцию, которую сочтёт рискованной, — и без пользователя за клавиатурой
это застопорит весь конвейер. Ниже — аудит автономных Bash-операций конвейера (processor +
листовые исполнители) по категориям отказа classifier'а и выбранный способ предвыдачи
согласия/обработки отказа для каждой. Единственный **эмпирически подтверждённый** отказ —
категория «Self Modification» на коммите/мёрдже, который сам добавлял грант в
`.claude/settings*` (инцидент T-057, см. `journal.md`); прочие операции в `auto` обычно
проходят, поэтому центральный allow-список держится минимальным, а остаточный риск закрывает
политика ниже (эскалация, а не стоп/самопредоставление).

| Операция | Роль(и) | Категория classifier'а | Риск отказа | Способ предвыдачи согласия / обработка отказа |
|---|---|---|---|---|
| `pwsh -File <tools/codex-runtime.ps1 \| ~/.claude/scripts/codex-runtime.ps1> …` (runtime-обёртка codex, T-075; две формы резолвинга пути — T-114) | coder_codex, reviewer_codex | запуск автономного агента | **высокий (подтверждён)** | сессионный грант launcher'ов `--allowedTools "Bash(pwsh -File tools/codex-runtime.ps1:*)"` (checkout-форма; + якорь `Bash(codex exec:*)`) + канонические `Bash(pwsh -File tools/codex-runtime.ps1 *)`, `Bash(pwsh -File ~/.claude/scripts/codex-runtime.ps1 *)` и `Bash(codex exec *)` (`cc-config`, покрывает обе формы); нестанд. `CODEX_CMD` — аргумент обёртки, покрыт тем же грантом; отказ → сентинел `CODEX_UNAVAILABLE`, фолбэк на Claude |
| Коммит/мёрдж, **изменяющий `.claude/settings*`** или сам грант | processor, merger | самомодификация конфигурации («Self Modification») | **высокий (подтверждён)** | согласие оператора должно быть **видно в контексте самого финализирующего вызова** (не пересказ через субагента — см. политику ниже); правку settings делает только оператор/`cc-config`; отказ → чистая остановка + эскалация оператору, без обхода |
| `git push` / `git push -u` / `jj git push` | processor | сеть/публикация | низкий (в `auto` обычно проходит) | не в центральном списке; отказ → штатная эскалация «требуется ручное вмешательство», уже запушенное не откатывается; при необходимости — пер-репо локальный грант через `cc-config` |
| `gh run list/watch`, `gh pr close`, `gh issue`, `gh api` | processor, github_sync | сеть/публикация | низкий–средний | не в центральном списке; отказ/недоступность → штатная эскалация роли (processor: «CI не проверен, подтвердите вручную»; github_sync: пометка `заблокировано`); пер-репо локальный грант |
| `git worktree add/remove --force/prune`, `jj workspace add/forget`, `git branch -D`, `jj bookmark delete` | processor | деструктивная (worktree/ветка) | низкий | не в центральном списке; отказ → штатная эскалация; пер-репо локальный грант |
| `rm -rf "$WORK/…"` (lock, worktree, служебные файлы когорты) | processor | деструктивная | низкий (пути `.work/` — собственный scratch оркестратора) | как выше |
| `git commit` / `git add <файлы>` (точечно, **не** `-A` в main) | processor, merger | локальная запись VCS | низкий | как выше |
| read-only `git diff`/`jj diff`/`git status`, просмотр файлов | coder\*, reviewer\*, full_reviewer, merger | read-only осмотр | нет | грант не требуется (classifier пропускает read-only) |
| `SMOKE_CMD` (произвольная команда проекта) | coder\*, merger | произвольная команда | **зависит от команды** | **не** в центральном списке (широкий грант на все проекты недопустим); пер-репо локальный грант оператора через `cc-config`/`/permissions` (см. `config.example.md`, ключ `SMOKE_CMD`); отказ → эскалация роли |

**Вывод аудита по центральному allow-списку.** Новые канонические правила сверх трёх
codex-правил (`Bash(pwsh -File tools/codex-runtime.ps1 *)` и `Bash(pwsh -File
~/.claude/scripts/codex-runtime.ps1 *)` — обе формы фактической команды, T-075/T-114 — и
якорь `Bash(codex exec *)`) **не заводятся**: расширять список, который `cc-config` сеет во
**все** репозитории, включая широкие права (`git push`, `gh`, `rm`, `SMOKE_CMD`), значило бы
неявно раздуть полномочия агентов во всех проектах. Остаточный риск (конкретная операция
отклонена в конкретном репозитории) закрывают два механизма без второго источника истины:
(1) универсальная политика эскалации ниже; (2) пер-репозиторный локальный грант оператора
(тот же `.claude/settings.local.json`, но правила добавляет оператор под свой репозиторий).
Обобщение зеркалирования всего `tools/*.ps1` (T-115) новых грантов **не добавляет**: прочие
раннеры (`state-tx`, `queue-tx`, `outbox`, `policy`, `redaction`, `supervisor`, `harness`, …)
исполняются как локальный `pwsh -File …` — classifier пропускает их без гранта в **обеих**
раскладках (checkout `tools/<script>.ps1` и mirror `~/.orchestra/scripts/<script>.ps1`); особый
грант нужен только Codex model-runner'у; прочие раннеры работают без расширения
`--allowedTools` (см. «Резолвинг раннеров `tools/*.ps1`»).

**Политика «согласие — заранее» (единая для всех автономных Bash-операций всех ролей).**
- Режим `ORCHESTRA_CLAUDE_PERMISSION_MODE: bypassPermissions` — явный
  operator-owned opt-in всей Claude-сессии, а не грант от агента. Он отключает
  permission-проверки и наследуется subagent’ам, но не отменяет `policy.ps1`.
  Ролям запрещено устанавливать переменную или порождать новую bypass-сессию.
- Разрешения на рискованные операции выдаёт **пользователь заранее** — через launchers
  (сессионный `--allowedTools`) и/или настройки (`.claude/settings*`, сеет `cc-config`), а
  не агент по ходу прогона.
- Агентам **категорически запрещено** самостоятельно расширять свои полномочия: править
  `.claude/settings.json`/`.claude/settings.local.json` (**любой** роли, не только
  codex-адаптерам), обходить classifier переформулировкой команды/коммит-сообщения или
  подменой тулов. Permission-файлы пишет только оператор (в т.ч. запуском `cc-config`) или
  человек.
- **Отказ classifier'а посреди прогона → штатная эскалация той роли, где он произошёл**, а
  не остановка всего прогона и не самопредоставление прав. Для codex-адаптеров это сентинел
  `CODEX_UNAVAILABLE` (фолбэк на Claude); для processor/merger — чистая остановка с
  сообщением оператору «требуется ручное вмешательство: <операция> отклонена classifier'ом»;
  для листовых coder/reviewer — эскалация в отчёте processor. Это **дополняет**, а не
  заменяет известные сентинелы (`CODEX_UNAVAILABLE`/`CODEX_FAILED`).
- **В `auto` согласие не наследуется через субагента.** Classifier не принимает согласие
  пользователя, пересказанное родителем-processor'ом субагенту: эмпирика T-057 — `merger`
  не смог финализировать грант-несущий мёрдж по «переданному» согласию, потребовалось, чтобы
  `/permissions`-подтверждение было видно в контексте самого финализирующего вызова.
  Практическое следствие: операцию, затрагивающую собственные permission-настройки
  (`.claude/settings*`), доводит роль, в контексте которой согласие реально видно (обычно
  processor в прямом диалоге с оператором); субагент при отказе — эскалирует, не обходит.

## Runtime-артефакты подключённого проекта

| Путь | Владелец / назначение |
|---|---|
| `~/.orchestra/root-config.md` | единственный пользовательский глобальный конфиг: root-only provider/runtime ключи и fallback для всех project-ключей; OS environment не является источником настроек |
| `~/.orchestra/projects.json` | пользовательский глобальный реестр адресуемых проектов (`orchestra/project-registry@1`); меняется только `project-registry.ps1 register`, который явно запускает оператор через `cc-config`; агенты читают его для маршрутизации |
| `~/.orchestra/specs/Inbox_Contract.md` | установленная `cc-sync` копия нормативного `docs/inbox_contract.md`, которую читают роли в target-проектах (`Inbox_Contract.md`) |
| `.inbox/messages/<msg-id>.json` | долговечное межрепозиторное сообщение (`orchestra/inbox-message@1`) со статусами оценки/ответа, task links и remarks; мутируется только `tools/inbox.ps1`, единственное разрешённое исключение cross-project записи |
| `.inbox/releases/<rel-id>.json` | канонический аудит release fan-out (`orchestra/release-notification@1`): immutable version/notes/products, замороженные target ids и crash-recoverable delivery ids; пишет только `tools/inbox.ps1 release` |
| `.inbox/inbox.lock` | краткоживущий атомарный лок создания/перехода message records; держит только `tools/inbox.ps1` |
| `.work/Tasks_Queue.md` | входная очередь; новые задачи имеют ID `T-NNN`; мутируется только через транзакционный интерфейс `tools/queue-tx.ps1` |
| `.work/Tasks_Done.md` | архив завершённых задач; источник «предпосылка завершена» для readiness-резолвера. Новая запись содержит полный дескриптор и один immutable-блок `orchestra/task-execution-metrics@1` (операции/итерации, длительности, actual/estimated/unavailable tokens, полнота); исторические записи без блока не мигрируются. Старый PowerShell runtime читает только заголовки, но принимает реально существующие варианты `## [T-NNN]`, `### [T-NNN]` и legacy `# Активная задача T-NNN`; упоминание ID в теле завершением не считается |
| `.work/queue_state.json` | счётчик поколения очереди (generation/CAS) транзакционного интерфейса `tools/queue-tx.ps1`; см. `docs/queue_contract.md`, §10 |
| `.work/queue-tx.lock` | краткоживущий атомарный лок мутации очереди (отдельный от `orchestrator.lock`); держит `queue-tx.ps1` на время одной транзакции |
| `.work/queue_inbox/` | горячие, ещё не обработанные предложения популяторов, поданные при активном `orchestrator.lock` (`queue-tx inbox-add`); processor вливает их `inbox-drain` на границе когорты (`docs/queue_contract.md`, §7/§9) |
| `.work/queue_inbox/rejected/` | append-only audit-карантин записей inbox с неверными зависимостями или неразбираемым JSON; `inbox-drain` сохраняет исходный `.json` и companion `.metadata.txt` с точной ошибкой/UTC-временем и больше их не сканирует (`docs/queue_contract.md`, §7) |
| `.work/Github_Sync.md` | таблица соответствия GitHub issues/PR и задач очереди; ведёт `github_sync` |
| `.work/config.md` | локальные переопределения, ключи `UPPER_SNAKE_CASE` |
| `.work/constraints.md` | человекочитаемая политика ограничений проекта (denylist путей, ветки/remotes, push/merge policy, обязательные проверки, пороги, human-review категории); шаблон — `constraints.example.md`, сеет `cc-config`; читают processor/planner/coder/reviewer, нет файла — деградация без ошибок |
| `.work/orchestrator.lock` | аренда владельца прогона (каталог; защита от двух processor независимо от provider). Содержит `lease.json` — запись аренды (owner/session id, корень, host, heartbeat, TTL, pid+время создания как доказательство живости, поколение и опциональный `processkit_run_id`); ведётся через `tools/state-tx.ps1`, см. `docs/queue_contract.md`, §14-§16 |
| `.work/codex_processor_session.json` | адресованный UUID root-thread Codex-provider (`orchestra/codex-processor-session@1`), provider/root/timestamps и `last_action=start\|resume\|handoff`; атомарно пишет только `tools/codex-processor-runtime.ps1`, читает `cc-resume codex`; handoff инвалидирует старый UUID после lease-preflight и записывает новый thread, файл не заменяет lease и не используется Claude-provider |
| `.work/cycle/` | Separate sequential-profile state: checksummed phase/session state, invocation intents and reports, immutable handoffs, publication/CI evidence, session archives and an OS-held runtime lock. Each Claude attempt adds a `usage-<attempt>.json` record, and each Claude role has the recovery copy `prompts/<role>.txt`. Frozen views reserve the path `__runtime__/prompt.txt`. Owned only by the cycle runtime, never by queue roles; the shared processor lease still excludes concurrent owners. |
| `.work/codex-processor-runtime.lock` | OS-held exclusive file lock внешнего Codex TUI root process; сериализует `start`/`resume`/`handoff` до модельного `orchestrator.lock`, чтобы конкурентные rollout `session_meta` не перезаписали addressed UUID. Пустой файл может оставаться, владение определяется только открытым handle и автоматически исчезает при crash |
| `.work/orchestrator.lock/lease.json` | запись аренды (`schema: orchestra/lease@1`); мутируется только транзакционно через `tools/state-tx.ps1` (acquire/heartbeat/release/takeover) |
| `.work/state-tx.lock` | краткоживущий атомарный лок мутации control plane (аренда/поколение состояния); держит `state-tx.ps1` на время одной транзакции; отдельный от `orchestrator.lock` и `queue-tx.lock` |
| `.work/control_state.json` | счётчик поколения control plane (state-плоскостной аналог `queue_state.json`) для CAS мутаций состояния когорты/задачи; ведёт `tools/state-tx.ps1` |
| `.work/PAUSE` | kill switch: при наличии processor штатно останавливается на границе фазы/раунда (освобождает lock, состояние подхватит Фаза 0); ставит/снимает `cc-pause`/`cc-unpause` |
| `.work/batch.md` | append-only манифест текущей когорты (строки волн приёма дописываются, не переписываются) |
| `.work/cohort_state.md` | состояние роллинг-приёма когорты (открыт/закрыт, волна, счётчики) |
| `.work/tasks/<T-ID>/task.md` | дескриптор и критерии от planner |
| `.work/tasks/<T-ID>/review.md` | per-task находки `R-NN` |
| `.work/tasks/<T-ID>/status.md` | статус листового агента |
| `.work/tasks/<T-ID>/supervisor_checkpoint.json` | resume-checkpoint вызова исполнителя на отмене/таймауте (`tools/supervisor.ps1`, T-093): задача/батч/попытка/причина/elapsed + `owner_id`/heartbeat/ttl — совместим с арендой Фазы 0 (`lease.json`), которую **не** трогает; неконфиденциальный (без сырого вывода вызова) |
| `.work/processes/<T-ID|_integration>/*.json` | сохраняемый после Phase-6 удаления task-дескриптора process-lineage одного внешнего запуска через `tools/supervisor.ps1 --process-diagnostics`: root PID, PID/PPID/имя потомков до cleanup, survivors после, hash и безопасный classifier hint командной строки; raw argv не хранится. Global before/after diff добавляет `temporal-candidate` для worker за уже умершим intermediate parent (при concurrency это кандидат, не доказанное владение); на POSIX reparented child может быть только temporal, а собственный snapshot-helper `ps` фильтруется. Пустой diff сохраняется типизированными пустыми массивами и не падает под PowerShell 7 `Set-StrictMode`. Supervisor чистит дерево после любого исхода (`ok`/`error` включительно), а перед survivor-snapshot ограниченно ждёт точные PID+start-time наблюдавшихся lineage-потомков; ProcessKit-backend даёт отдельный kernel container, на POSIX fallback использует отдельную process group; внутренний Claude `Agent(...)` здесь не притворяется внешним PID-вызовом |
| `.work/processes/<T-ID|_integration>/*.processkit.jsonl` | versioned lifecycle standalone ProcessKit для того же supervised call: redacted run metadata, kernel mechanism, members snapshots, root/cleanup и terminal `runner_exit`; создаётся только вместе с process diagnostics, путь связан из соседнего `.json` |
| `.work/processes/_processor/*.processkit.jsonl` | lifecycle корневых `cc-processor`/`cc-resume` Claude/Codex-сессий через standalone CLI; остаётся после завершения для диагностики, а живой `run_id` доступен через `processkit-cli list/inspect/cancel/kill` |
| `.work/worktrees/<T-ID>` | изолированная рабочая копия задачи |
| `.work/worktrees/_integration` | join-барьер и совокупный результат батча |
| `.work/review_integration.md` | интеграционные находки `F-NN` |
| `.work/integration_state.md` | служебное состояние джойна (Ревью-SHA предыдущего интеграционного ревью, F-циклов); ведёт processor, создаётся в Фазе 5, удаляется в 6.4 |
| `.work/merge_report.md` | результаты merge и причины карантина |
| `.work/verification.json` | атомарное exact-SHA evidence обязательного pre-push verification-гейта (`tools/verification.ps1`, schema `orchestra/verification@2`): точные упорядоченные команды, безопасный environment/profile fingerprint и terminal supervisor facts без путей/stdout/stderr; `check` отвергает crash-residue `running`, смену профиля/окружения и старую вершину, а `check --require-pass` разрешает review-reuse только для `pass` с `reason=ok`, `exit_code=0`, `survivors=0` каждого запуска; exemptions остаются только pre-publish policy semantics и никогда не доказывают выполнение дорогой команды |
| `<supervisor/verification result-file>.run.lock` | краткоживущий sibling-lock одного логического foreground-вызова; предотвращает второй запуск с тем же стабильным result path, пока оболочка могла прекратить ожидание, но исходный supervisor/verification process ещё жив. Освобождается владельцем при terminal outcome; crash-residue ломается только после bound, включающего все попытки/команды и cleanup |
| `.work/status.md` | текущий обзор processor |
| `.work/journal.md` | постоянный журнал завершённых прогонов; read-only fallback для отсутствующих в событиях полей `tools/metrics.ps1` |
| `.work/events.jsonl` | append-only машинный event-outbox; пишет только processor (одна JSON-строка на событие) при `EVENTS_OUTBOX:on` через транзакционный интерфейс `tools/outbox.ps1` (валидация конверта/payload, детерминированный `event_id`-дедуп-ключ, строгие scalar-only `operation.completed` как timing spine архива, отказ с rc=5 для многострочного raw-ввода `--json-line`/`--stdin`, игнорирование whitespace-only строк, ремонт оборванного хвоста, single-writer); основной источник read-only агрегатора/пер-задачной проекции `tools/metrics.ps1`; машинный контракт для будущей платформы наблюдаемости (`docs/queue_contract.md`, §19); не привязан к одной когорте, переживает очистку Фазы 6, никогда не переписывается/не усекается; Markdown-артефакты остаются источником истины для человека |
| `.work/outbox-tx.lock` | краткоживущий атомарный лок дозаписи event-outbox (отдельный от `orchestrator.lock`/`queue-tx.lock`/`state-tx.lock`); держит `tools/outbox.ps1` на время одной дозаписи; обеспечивает single-writer инвариант `events.jsonl` |
| `.work/events_cursor.json` | курсор референсного потребителя outbox (`tools/outbox.ps1 read`): монотонный byte-offset — exactly-once граница штатного single-writer потока; `delivered_ids` персистентно хранится как пустой массив (старый исторический набор учитывается один раз при компактизации), дедуп действует только внутри текущего непрочитанного суффикса, поэтому поздний ручной/внешний дубль после сохранённого offset выдаётся повторно как at-least-once аномалия; ведёт потребитель/тесты, не processor |
| `.work/approvals/<apr-id>.json` | персистентный одноразовый запрос на человеческое подтверждение (T-095): subject (task/batch), причина (human-review/force-lock/policy-bypass), diff-фингерпринт затронутых путей, снапшот применённой политики, срок действия и решение; ведёт `tools/policy.ps1 approval-request`; approve/reject оператора потребляют ID ровно один раз; `approval-status` сверяет свежесть (истекает при смене кода/политики или к дедлайну — fail-closed). Системный operator pre-grant `ORCHESTRA_AUTO_APPROVE: on` из `~/.orchestra/root-config.md` автоматически потребляет только свежий pending-запрос с `decided_by=root-config:ORCHESTRA_AUTO_APPROVE`, не отменяя audit/fingerprint/policy checks; `off`/unset сохраняет ручной gate, invalid fail-closed. |
| `.work/approvals/approvals.lock` | краткоживущий атомарный лок мутаций approval-артефактов: `tools/policy.ps1` держит его на всём read-check-write для ручного approve/reject, auto-approve существующей записи в `approval-request` и crash-recovery auto-approve в `approval-status`; атомарность отдельного JSON по-прежнему обеспечивает `Write-JsonAtomic` |
| `.work/knowledge/` | runtime-KB целевого проекта при `KB:on` |
| `.work/roadmap.md` | опциональная дорожная карта подключённого проекта: упорядоченные вехи (название/цель, статус `запланирована`/`текущая`/`достигнута`, проверяемый критерий достижения `Достижение:`) + сводка текущего состояния + машиночитаемая связь веха↔`T-ID` (поле `Задачи:` — какие задачи поставлены под веху; завершены = лежат в `Tasks_Done.md`, как readiness §11–§12); нормативный формат — `docs/roadmap_contract.md`. **Машинно-локальный рантайм-артефакт** (как `.work/knowledge/`), а не сеемый версионируемый шаблон (`config.example.md` этой задачей намеренно не трогается) и **без tx-интерфейса** на первом шаге (редкие, эффективно однопользовательские записи — обоснование в контракте, §11). Пишут человек-оператор/`thinker` (создание/переупорядочивание вех, пометка достигнутой); конвейер (`processor`)/популяторы в текущем шаге не пишут, лишь могут читать. Нет файла — деградация без ошибок (плоский бэклог, как раньше); не путать с `plans/LOOP_ORCHESTRA_ROADMAP.md` (план развития самой Orchestra, версионируемый) |

## Инварианты, которые нужно сохранять

- runtime-KB — по одному писателю на каждом этапе; не добавляйте параллельную запись без
  нового механизма синхронизации. **Очередь `Tasks_Queue.md` мутируется только через
  транзакционный интерфейс `tools/queue-tx.ps1`** (атомарный лок `queue-tx.lock` +
  счётчик поколения + inbox для приёма под активной когортой — см.
  `docs/queue_contract.md`, §7-§12): это и есть механизм синхронизации, допускающий
  безопасную конкурентную постановку задач несколькими популяторами без lost update и без
  повторного `T-NNN`. Lifecycle `--id` принимает только полный anchored `T-NNN`/`P-NNN`
  токен; не возвращайте substring-разбор, который молча превращает `XT-12` в T-012.
  Proposal normalized-title dedup читает и backlog, и `[P-NNN]`-заголовки архива — те же
  источники, что P-ID нумерация; direct propose и inbox-drain должны оставаться симметричны.
  Ручной read-modify-write очереди в обход интерфейса не вводите.
- Per-task изменения изолированы; пересечение conflict domains запрещает общий батч.
- Терминальная эскалация сохраняет последний закоммиченный продукт до cleanup как локальный
  ref `escalated/<B-id>/<T-ID>` (одинаковая политика для git branch и jj bookmark), поэтому
  повторный заход того же `T-ID` не конфликтует с recovery-точкой. Обычный карантинный
  re-queue recovery-точку не создаёт; удерживаются 19 последних прочих recovery refs плюс
  текущая точка ensure (не более 20 всего), а
  processor никогда их не публикует.
- Processor выбирает VCS jj-first один раз, механически проверяет точный root каждого
  созданного workspace через `policy.ps1 guard-path --expect-vcs` и передаёт `VCS=jj|git`
  всем worktree-ролям. Листовая роль не переопределяет этот выбор: при `VCS=jj` Git
  запрещён даже для чтения, потому что из pure-jj `.work/worktrees/**` он молча адресует
  `.git` основного дерева.
- Maker/checker должны быть независимы. В гибридном Claude-root режиме legacy-значения
  после Codex-реализации выбирают Claude-reviewer. Явный `CODEX_REVIEWER=all`, как и
  полностью Codex-native provider, выполняет ревью отдельным новым checker-thread, который
  не реализовывал и не исправлял этот diff и не продолжает maker-сессию.
- `R-NN` относятся к одной задаче, `F-NN` — к интеграции всего батча.
- В основном дереве точечный CI-фикс коммитится явным списком файлов, не `git add -A`.
- **Аренда владельца (`.work/orchestrator.lock`) мутируется только через `tools/state-tx.ps1`**
  (acquire/heartbeat/release/takeover, атомарный лок `state-tx.lock` + owner_id + поколение +
  heartbeat/TTL/pid-живость): это механизм синхронизации «один processor», допускающий
  безопасный takeover устаревшей аренды и адресный resume без второго управляющего цикла.
  Корневая роль `processor` до любой такой операции обязана нести launcher-attestation
  `ORCHESTRA_PROCESSKIT_ROOT_RUN_ID`, созданную `processkit-runtime.ps1` внутри standalone
  CLI-run; `acquire`/`takeover`/`verify`/`heartbeat` без неё дают код 20 до мутации. Marker
  не является пользовательской настройкой, и агент не может выставлять его себе сам.
  Продлить/снять аренду может только её владелец (owner_id) — безусловный `rm -rf` каталога в
  обход owner-check не вводите (снял бы чужую свежую аренду после takeover, см.
  `docs/queue_contract.md`, §15). Каталог `orchestrator.lock` с legacy-содержимым (`info` без
  `lease.json`, degraded-режим при отсутствии PowerShell) `state-tx acquire` видит как **занятый**
  (код 19), а не как «аренды нет» — иначе получили бы два управляющих цикла в общем `.work`
  (§14, «Аренда ↔ legacy-лок»). `release` сообщает `released` только если каталог действительно
  исчез; persistent I/O error даёт код 6 и точную диагностику. Короткие file-locks из
  `tools/common.ps1` также снимаются только процессом, чей PID всё ещё записан в lock-файле:
  поздний former holder не удаляет лок, уже пересозданный другим писателем. `Acquire-Lock`
  считает contention только I/O-ошибку CreateNew при реально существующем lock-файле либо
  при нативном коде atomic-collision (`EEXIST`/`ERROR_FILE_EXISTS`), даже если быстрый holder
  успел удалить файл до последующего `Test-Path`. Windows delete-pending handoff после
  `DeleteOnClose` может временно дать `UnauthorizedAccessException`/`ERROR_ACCESS_DENIED`;
  только эта точная форма получает короткое ограниченное повторение, а постоянный access
  denial сохраняет исходную диагностику. Если файл отсутствует повторно и код ошибки не
  доказывает collision либо тип ошибки иной, примитив немедленно пробрасывает исходную
  I/O-причину, а не маскирует её 30-секундным `held by another writer`. `Read-Lease` до liveness валидирует
  `ttl_seconds`/`pid`/`pid_started`, поэтому битые scalar-поля всегда дают структурный код 18.
- **`cc-doctor` диагностирует современную аренду через `state-tx status --json`.**
  `tools/doctor-runtime.ps1` резолвит `state-tx.ps1` в обеих поддерживаемых раскладках
  (`tools/state-tx.ps1` в чекауте и `~/.orchestra/scripts/state-tx.ps1` в зеркале `cc-sync`) и
  показывает owner/role/возраст heartbeat/liveness структурного `lease.json`. Только
  degraded mkdir-lock без `lease.json` проходит через прежнюю эвристику `info` с
  `started=`/`host=`; её совместимый вывод не менять.
- **Переходы состояния processor гардит в рабочем потоке фаз, а не по памяти.** Каждую смену
  статуса задачи/когорты/интеграции он сверяет `state-tx check-transition` (код 8 — стоп) и
  фиксирует CAS поколения `state-tx bump-generation --expected-generation` (код 3 — гонка, стоп)
  **перед** атомарной записью — это обязательный шаг всех фаз, а не только конвенция (см.
  `agents/processor.md`, «Гард переходов и поколения состояния»; нормативная модель переходов —
  `docs/queue_contract.md`, §13).
- `--force-lock` (операторский force-takeover) допустим только после проверки, что прежний
  processor действительно умер; безопасный авто-takeover — лишь при доказанном stale
  (pid мёртв/переиспользован или heartbeat за пределами TTL).
- YAML frontmatter обязан начинаться с первого байта; агентские Markdown-файлы хранятся
  как UTF-8 без BOM.
- Windows-launchers `launchers/*.cmd` хранятся как UTF-8 без BOM с чистым CRLF: смешанные
  или LF-only окончания при `chcp 65001` могут заставить `cmd.exe` отбросить первый байт
  более поздней команды. `.gitattributes` использует `*.cmd -text`, тестовый harness
  копирует исходные байты без маскирующей нормализации, а `cc-sync` fail-closed проверяет
  этот контракт до публикации пользовательского mirror.
- Каждая логическая попытка `coder_codex`/`reviewer_codex` в пер-таск Фазе 2 завершает
  безопасное событие `codex.attempt`: стабильный ключ `(task_id, role, mode,
  attempt_number)` отображается в UUIDv5, а временная reservation в `task.md` делает
  append идемпотентным на resume. Payload хранит только timing/effective config/RC и
  машинный outcome-класс — без prompt, diff, вывода, env, credentials и абсолютных путей.
  Durable verdict `tools/supervisor.ps1 supervise` в `--result-file` содержит фактические
  `attempts`, `budget_remaining_ms` и `total_duration_ms`, совпадающие с stdout; `observe`
  использует этот `attempts` как координату `attempt_number`, поэтому реальный retry не
  дедуплицируется с первой попыткой.
  `status.md` показывает дедуплицированный running total текущей когорты, `journal.md` —
  итог батча; сбои этой наблюдательной телеметрии никогда не меняют control-flow, кроме
  включённого enforceable-token-gate ниже.
- Каждая существенная операция до перехода задачи в `выполнена` завершает scalar-only
  `operation.completed` на каждый затронутый реальный T-ID. Task-local scope имеет долю 1;
  cohort/integration scope хранит `shared_task_count=N` и использует matching usage под
  `_cohort`/`_integration`. Номер попытки, роль и режим совпадают с `usage.recorded`; append
  replay-idempotent. Pre-archive `knowledge_curator` входит как общая операция;
  post-archive dependency/inbox finalize остаются batch-level затратой и в итог задачи не
  входят.
- **Токенный circuit-breaker когорты (T-309).** `COHORT_TOKEN_BUDGET: 0` отключён по
  умолчанию; при `>0` `tools/metrics.ps1 budget --batch-id <B-id>` dedup-ит
  `usage.recorded` и считает только явное `estimated=false`. Проекция сортирует события по
  `occurred_at` и применяет действовавший в этот момент `task.captured` mapping, поэтому
  delayed/batchless/stale-batch события одного повторно захваченного task_id не переходят в
  последнюю когорту. UUIDv5 usage включает `batch_id` — обязательную координату дедуп-ключа
  (T-321): `tools/supervisor.ps1 observe` требует `--batch-id`, как только usage реально
  захвачен (rc=2 без него, вместо тихой best-effort потери события на дозаписи), а
  `tools/outbox.ps1` write-валидация envelope принимает `task_id` формы `T-<n>` **и** два
  зарезервированных псевдо-id `_cohort`/`_integration` (для фактов уровня когорты/интеграции
  без отдельной задачи). Внутренний Claude `Agent(...)` без provider token counts пишет
  `usage_availability=unavailable`, который никогда не превращается в нулевой расход, но что он
  значит для гейта — управляет `COHORT_TOKEN_BUDGET_STRICT` (по умолчанию `false`, T-321 R-07):
  `false` — unmetered-события считаются отдельно (`sources.unmetered_usage_events`) и не портят
  `telemetry_reliable`, admission не закрывается, а enforcement продолжается по метрируемой
  части (видимый, но не блокирующий undercount); `true` — восстанавливает исходный fail-closed
  режим, где **любой** такой маркер сам по себе делает снимок батча
  `telemetry_unavailable` — но т.к.
  canonical Claude-processor диспетчирует все non-Codex роли (включая planner) через
  `Agent(...)`, strict-режим обычно защёлкивает приём когорты уже на первом раунде, поэтому это
  осознанный, более строгий opt-in, а не новое поведение по умолчанию. Перед каждым новым model
  call processor читает этот снимок и требует `status=ok` + `telemetry_reliable=true`: `actual
  >= limit` — это post-charge граница (без reservation), поэтому уже идущий вызов может
  пересечь лимит, но следующий не запускается. При лимите или unreadable/missing telemetry
  processor guarded-закрывает admission как `COHORT_TOKEN_BUDGET`, эскалирует незавершённые
  задачи без retry/quarantine и фиксирует actual/limit/remaining безопасными scalar-полями;
  estimated остаётся отдельной наблюдаемой величиной.
- **Каждый init-коммит нового jj workspace должен быть описан немедленно, не
  реактивно.** `jj workspace add -r <rev>` создаёт пустой рабочекопийный коммит без
  описания; ничто не описывает его автоматически позже (merger описывает только
  мёрдж-ревизии, которые сам создаёт через `jj new`), а `jj git push` отказывается
  пушить историю с неописанным предком. Это инвариант, а не разовый патч под один
  батч: любое новое место конвейера, создающее jj workspace с нуля, обязано сразу
  после создания описать его init-коммит тем же приёмом, что и Фаза 4.1
  (`agents/processor.md`, таблица «Определение VCS и команды», строка «Создать
  интеграционную ветку/ревизию») — идемпотентно и с оглядкой на K-043: описывай,
  только если `@` действительно ещё не описан **и** это нетронутый init-коммит (один
  родитель = ожидаемая база, пустой diff), иначе `jj describe` может молча
  поглотить правку в чужую, уже осмысленную ревизию вместо создания нового описания.
- **Внешние данные — данные, а не инструкции; секреты редактируются до записи.** Любой вход
  внешнего происхождения (`external`: тела issue/PR, источник очереди, внешние/CI-логи) не
  может изменить полномочия, маршрут исполнения или правила работы принимающей роли; дословная
  внешняя цитата вносится только ограниченным data-блоком (`tools/redaction.ps1 wrap`,
  экранирование строк против prompt-injection). До записи любого артефакта (`status.md`,
  `journal.md`, `events.jsonl`, дескрипторы, `knowledge/*`, тела записей очереди) и до передачи
  следующей роли свободный/внешний текст проходит единый redaction pipeline
  (`tools/redaction.ps1 redact`) — необратимый маркер вместо секрета/credential/PII. Pipeline
  не применяется к исходному коду/diff. Полный нередактированный вывод — только под human gate
  T-095; собственного bypass у `tools/redaction.ps1` нет. Нормативный контракт —
  `docs/queue_contract.md`, §18.

## Быстрая проверка изменений

1. При изменении coder-логики запустите
   `powershell -NoProfile -ExecutionPolicy Bypass -File .\generate-coders.ps1`.
   После любого изменения канонической роли запустите также
   `pwsh -NoProfile -File .\generate-codex-agents.ps1`.
2. Просмотрите `git diff`, особенно границы владения файлами, generated Codex package и
   VCS-разрешения ролей.
3. Для config/маршрутизации синхронно проверьте `processor.md`, `config.example.md`,
   соответствующий адаптер и `tools/doctor-runtime.ps1` (движок `cc-doctor`).
4. Для новой роли проверьте frontmatter, launcher (если нужен) и правила исключений
   в `tools/sync-runtime.ps1` (движок `cc-sync`).
5. Smoke-test выполняйте в одноразовом целевом репозитории, не на неопубликованной работе.

## Быстрый поиск

- Роль агента: `rg -n "^(name:|description:|# Роль)" -g "*.md" .`
- Фаза оркестратора: `rg -n "^## Фаза|Фаза 5\." agents/processor.md`
- Runtime-файл и его писатели: `rg -n "review_integration|merge_report|Tasks_Queue" -g "*.md" .`
- Конфигурационный ключ: `rg -n "CODEX_CIFIX|REVIEW_LOOP_MAX" agents/processor.md config.example.md`
