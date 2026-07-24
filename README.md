# Orchestra

Orchestra is a kit of Claude Code system prompts, Codex CLI adapters, and
cross-platform launchers for autonomously processing a task queue with Claude Code /
Codex agents. It is not an application or a library you import; it is agent
definitions plus launcher entry points — `.cmd` on Windows, `.sh` on macOS/Linux —
that you install into your Claude Code environment and then run against any target
project.

## What problem it solves

Running an agentic coding pipeline by hand — plan a task, implement it in an
isolated branch, review the diff, merge it, resolve conflicts, integrate with the
rest of a batch, publish, watch CI — is repetitive and easy to get wrong when done
task by task, one at a time, by a human operator. Orchestra turns that pipeline into
an autonomous, parallel, self-recovering conveyor: point it at a project's task
queue (`.work/Tasks_Queue.md`) and it works through the queue end to end — planning,
implementing in parallel isolated worktrees, per-task review, integration, merge to
`main`, push, and CI — with retry, escalation, and quarantine handling built in, so
a human only needs to seed the queue and periodically check status or escalations.

## What Orchestra is made of

### Roles

- **processor** — the orchestrator. Owns the whole cycle: takes the lock, opens a
  rolling cohort of conflict-free tasks, creates an isolated worktree (or
  workspace) per task, runs the leaf agents concurrently, commits their results,
  drives per-task and integration review, merges to `main`, pushes, and watches CI.
  It is the only role that invokes subagents; see `processor.md` for the full phase
  state machine.
- **planner** — turns a queue entry into `.work/tasks/<T-ID>/task.md`: picks a
  conflict domain that doesn't overlap with active tasks, writes acceptance
  criteria and, for larger work, a staged plan.
- **coder_fast / coder / coder_deep** — the three tiers of implementer, identical
  in algorithm and differing only in model/effort (see `agents/coder.template.md`,
  the single source `generate-coders.ps1` expands into all three). They implement a
  task, address review findings, or apply a targeted CI/build fix in the worktree
  they're pointed at; they never touch the queue or VCS state directly.
- **coder_codex** — a thin `codex exec` adapter for implementation and per-task
  fixes, with mandatory fallback to a Claude coder.
- **reviewer_std / reviewer** — per-task review of a finished branch (fast-tier vs.
  standard/deep-tier work respectively), logging `R-NN` findings in the task's
  `review.md`. Both are generated from the single source `agents/reviewer.template.md`
  by `generate-coders.ps1`, the same way the coder variants are.
- **reviewer_codex** — a read-only Codex adapter for per-task review.
- **full_reviewer** — reviews the integrated result of the whole cohort in
  `_integration`, logging `F-NN` findings in `.work/review_integration.md`.
- **merger** — sequentially merges the batch's ready branches into `_integration`,
  resolving or quarantining conflicts, and writes `merge_report.md`.
- **populators** — agents that only add entries to the queue, never touch code:
  `queue_builder` (turns a source/spec/backlog into deduplicated `T-NNN` entries),
  `code_auditor` (finds defects), `enhancement_scout` (finds improvements), and
  `github_sync` (syncs GitHub issues/PRs into the queue via `gh`).
- **knowledge_curator** — the sole writer of the optional runtime knowledge base
  `.work/knowledge/` in a target project, harvesting agents' `learnings.md` notes.
- **inbox_curator** — critically evaluates cross-project requests, converts only
  locally justified outcomes into queue tasks, and sends routed replies to the sender.
- **thinker** — interactively explores an idea with the user and, once agreed,
  creates queue entries for it.
- **proposal_curator** — batch-curates the raw `P-NNN` proposal lane (`kind: proposal`)
  in the unified backlog: for each proposal it decides one outcome (`converted` — creating
  executable `T-NNN` tasks with a provenance link, `rejected`, `duplicate`, `needs_human`,
  or `deferred`), keeping the original proposal text immutable. The engine never executes a
  proposal until it is `converted`.

### Pipeline, top level

```text
task source -> Tasks_Queue.md -> planner -> task.md
    -> coder in its own worktree <-> reviewer
    -> merger in _integration <-> full_reviewer
    -> ff-merge to main -> push/CI -> knowledge_curator -> journal/cleanup
```

`processor` owns this whole cycle end to end. See `processor.md` for the canonical,
authoritative phase-by-phase state machine (phases 0-6), resume behavior, retry
limits, and Claude/Codex routing; the roles above and this diagram are only a
summary.

## Installation

Orchestra is installed by mirroring this repository's agent definitions and
launchers into your Claude Code environment. Run the sync launcher from a checkout of
this repository:

```
launchers\cc-sync.cmd      # Windows
launchers/cc-sync.sh       # macOS/Linux
```

It mirrors:

- the agent `*.md` files under `agents/` into your Claude agents directory
  (`%USERPROFILE%\.claude\agents` on Windows, `~/.claude/agents` on macOS/Linux),
  where `claude --agent <name>` loads them from;
- the launchers into your Claude scripts directory (`%USERPROFILE%\.claude\scripts`
  or `~/.claude/scripts`, which should be on `PATH`) — `launchers\*.cmd` on Windows,
  `launchers/*.sh` on macOS/Linux — plus `config.example.md` and
  `constraints.example.md` alongside them so `cc-config` can find its templates,
  and `docs/inbox_contract.md` as `~/.claude/specs/Inbox_Contract.md`,
  from the mirror, and `tools/doctor-runtime.ps1` (the shared engine the thin
  `cc-doctor` wrappers delegate to) so `cc-doctor` runs the same from the mirror.

Both launchers are thin wrappers around one cross-platform engine,
`tools/sync-runtime.ps1` (run under PowerShell 7 — `pwsh` — on both Windows and
macOS/Linux), so the two platforms mirror identically. Before mirroring, the runtime
regenerates any template-generated coder/reviewer variant (`agents/coder.md`,
`agents/coder_fast.md`, `agents/coder_deep.md`, `agents/reviewer.md`,
`agents/reviewer_std.md`) that has drifted from `agents/coder.template.md` /
`agents/reviewer.template.md`, and validates the agent `.md` invariants — on **both**
platforms, no longer Windows-only. (The POSIX launcher therefore now requires `pwsh`
on `PATH`; install it from <https://aka.ms/powershell> if it is missing.)

Mirroring is transactional: files are published through a staging area with a
journal-backed rollback, so an interruption mid-publish is rolled back to the exact
prior state rather than leaving a half-applied mirror. The runtime keeps a manifest
(`~/.claude/.orchestra-sync-manifest.json`) of the files it manages; on a later sync it
prunes only entries it previously wrote that are no longer sourced (a renamed/deleted
agent or launcher). Files it never wrote — other agents you added to the mirror by hand
— are never touched. The same command generates namespaced Codex custom agents under
`codex/` and installs only those managed files into `$CODEX_HOME/agents` (normally
`~/.codex/agents`) with a separate transactional manifest. Foreign Codex agents are
never touched. Re-run the sync launcher after editing any canonical role or launcher,
otherwise the selected provider keeps using its previous mirror.

## Quick start in a target project

Run these from the root of the project whose task queue you want Orchestra to
process (any project on your machine, not this repository). The command names below
are extensionless: on Windows they resolve to the `.cmd` launchers via `PATH`; on
macOS/Linux invoke the `.sh` variants instead (`cc-config.sh`, `cc-queue.sh`,
`cc-processor.sh`, and so on):

1. `cc-config` — seeds `.work\config.md` for the project from the template block in
   `config.example.md`, and `.work\constraints.md` from the whole of
   `constraints.example.md` (an existing target file is never overwritten). It also
   creates `.inbox/messages/` and idempotently registers the canonical project root in
   the user-global `~/.orchestra/projects.json`, making the project addressable by other
   Orchestra agents.
2. Populate `.work\Tasks_Queue.md` with tasks. Add entries by hand following the
   queue format, or use `cc-queue <source or description>` (`queue_builder`) to
   turn a spec/backlog/description into deduplicated `T-NNN` entries, or
   `cc-thinker` to work out an idea interactively before it becomes tasks.
3. Start one provider:
   - `cc-processor` or `cc-processor claude` — legacy Claude root processor;
   - `cc-processor codex` — fully Codex-native root processor and Codex custom-agent
     roles, with no Claude process or fallback.

The provider can instead be selected for every project in a new terminal:

```powershell
[Environment]::SetEnvironmentVariable('ORCHESTRA_PROVIDER', 'codex', 'User')
```

Allowed values are `claude` and `codex`; an explicit launcher argument wins over the
environment. `cc-resume codex` resumes the exact Codex processor thread recorded in
`.work/codex_processor_session.json`; if no valid addressed thread exists it performs
the normal Phase-0 cold recovery. The Codex root defaults to `high` reasoning,
`danger-full-access`, approval policy `never`, and six agent threads. Operator-owned
overrides are `ORCHESTRA_CODEX_MODEL`, `ORCHESTRA_CODEX_REASONING`,
`ORCHESTRA_CODEX_SANDBOX`, and `ORCHESTRA_CODEX_MAX_THREADS`.

For a fully unattended machine, the operator can pre-grant all fresh Orchestra human
approval gates once, for every target project:

```powershell
[Environment]::SetEnvironmentVariable('ORCHESTRA_AUTO_APPROVE', 'on', 'User')
```

Open a new terminal, run `cc-sync`, then verify with `cc-doctor`. This is separate from
Claude/Codex sandbox permissions: `policy.ps1` still creates the normal one-time approval
artifact, binds it to the current diff and policy, and records
`decided_by=system-env:ORCHESTRA_AUTO_APPROVE`; it simply does not park the processor.
Use `off` (or remove the variable) to restore interactive approvals.

Install the standalone `processkit-cli` on `PATH` to enable kernel-backed containment
automatically for the whole processor session. To pin an exact binary (also useful until a
new terminal sees an updated system `PATH`), set a user/system environment variable:

```powershell
setx CC_PROCESSKIT_CLI "C:\Tools\processkit-cli.exe"
```

An explicit user/machine `CC_PROCESSKIT_CLI` is re-read by the runtime and works even from an
already-open Windows terminal. A `PATH`-only installation still needs a new terminal.
`cc-doctor` verifies the versioned probe contract.
`cc-processor` and `cc-resume` use `processkit-cli run` for noninteractive roots and persist
lifecycle JSONL under `.work/processes/_processor`. Interactive Claude roots require the
probe surface `run:--inherit-stdio`; older CLI releases automatically use a direct
console-attached fallback so the Claude TUI cannot disappear behind redirected stdio.
ProcessKit CLI 0.2.2 provides that surface, so current interactive roots remain contained.
Its `run:--stdin-file` surface also keeps supervised calls with mediated input inside the
ProcessKit container. Explicitly broken backends fail
closed. Set `CC_PROCESSKIT_CLI=off` to disable standalone
discovery. `CC_PROCESSKIT_PYTHON` remains a deprecated compatibility fallback when no CLI is
selected. With or without ProcessKit, those launchers disable
persistent MSBuild worker/server reuse in their child environment, and leaf build/test
commands use Orchestra's per-command supervisor cleanup and process diagnostics. They also
keep the bounded `codex-runtime.ps1` calls in the foreground by supplying 1,900,000 ms Claude
Bash timeout defaults when those variables are not already set; this avoids the extra
background-operator approval prompt without widening the permission allow-list.

Other launchers: `cc-resume` continues an interrupted processor session,
`cc-status` / `cc-journal` read current/past run state, `cc-doctor` runs a
read-only Codex/configuration/orchestration preflight (a thin wrapper, like
`cc-sync`, over one cross-platform `pwsh` engine, `tools/doctor-runtime.ps1`, so
Windows and macOS/Linux report identically), `cc-audit` and `cc-enhance` run
`code_auditor` and `enhancement_scout`, `cc-github` runs `github_sync`, and
`cc-proposal` runs `proposal_curator` to curate the `P-NNN` proposal lane.
`cc-inbox` performs an on-demand critical inbox pass. Normal processor runs do the same
cheap actionable check before the first planning wave, before rolling top-up, and after
archiving completed tasks; no background poller is left running. See
`docs/inbox_contract.md` for message fields, status transitions, routing and replies.

## Further reading

- `config.example.md` — the canonical description of every `.work/config.md` key,
  its default, and the Codex/knowledge-base toggles.
- `constraints.example.md` — the template for `.work/constraints.md`, an optional
  project policy file (e.g. a denylist of paths agents must not edit).
- `docs/inbox_contract.md` — the global repository registry and cross-project message
  contract, including critical intake, task provenance and reply lifecycle.
- `knowledge.md` — the internal map of this repository (ownership, control flow,
  runtime artifacts, invariants); read it before making changes to Orchestra
  itself. It is distinct from a target project's own `.work/knowledge/`, which
  `knowledge_curator` maintains at runtime when `KB: on`.
- `docs/operations.md` — the operator's guide: running and monitoring a processor
  session, interpreting status/journal output, and handling escalations.
- `plans/` — development plans: `LOOP_ORCHESTRA_ROADMAP.md` (strategic direction
  and sequencing) and `OBSERVABILITY_PLATFORM_PLAN.md` (human-in-the-loop
  observability, control plane, and event architecture). Both describe proposed,
  not yet active, runtime contracts.
