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
  `review.md`.
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
- **thinker** — interactively explores an idea with the user and, once agreed,
  creates queue entries for it.

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
  `launchers/*.sh` on macOS/Linux — plus `config.example.md` alongside them so
  `cc-config` can find its template from the mirror.

Neither variant purges other agents already present in the mirror. On Windows, if a
template-generated coder variant (`agents/coder.md`, `agents/coder_fast.md`,
`agents/coder_deep.md`) has drifted from `agents/coder.template.md`, `cc-sync.cmd`
regenerates it before mirroring; the POSIX `cc-sync.sh` mirrors the committed coder
variants as-is (the regeneration and agent-invariant checks are Windows-only PowerShell
steps — if you change `agents/coder.template.md`, regenerate the variants with
`generate-coders` on a machine with PowerShell before syncing). Re-run the sync launcher
after editing any agent definition or launcher — otherwise Claude keeps using the
previously mirrored copy.

## Quick start in a target project

Run these from the root of the project whose task queue you want Orchestra to
process (any project on your machine, not this repository). The command names below
are extensionless: on Windows they resolve to the `.cmd` launchers via `PATH`; on
macOS/Linux invoke the `.sh` variants instead (`cc-config.sh`, `cc-queue.sh`,
`cc-processor.sh`, and so on):

1. `cc-config` — seeds `.work\config.md` for the project from the template block in
   `config.example.md` (an existing `.work\config.md` is never overwritten).
2. Populate `.work\Tasks_Queue.md` with tasks. Add entries by hand following the
   queue format, or use `cc-queue <source or description>` (`queue_builder`) to
   turn a spec/backlog/description into deduplicated `T-NNN` entries, or
   `cc-thinker` to work out an idea interactively before it becomes tasks.
3. `cc-processor` — starts `processor`, which processes `.work\Tasks_Queue.md` end
   to end in parallel batches until no not-started tasks remain.

Other launchers: `cc-resume` continues an interrupted processor session,
`cc-status` / `cc-journal` read current/past run state, `cc-doctor` runs a
read-only Codex/configuration preflight, `cc-audit` and `cc-enhance` run
`code_auditor` and `enhancement_scout`, and `cc-github` runs `github_sync`.

## Further reading

- `config.example.md` — the canonical description of every `.work/config.md` key,
  its default, and the Codex/knowledge-base toggles.
- `knowledge.md` — the internal map of this repository (ownership, control flow,
  runtime artifacts, invariants); read it before making changes to Orchestra
  itself. It is distinct from a target project's own `.work/knowledge/`, which
  `knowledge_curator` maintains at runtime when `KB: on`.
- `plans/` — development plans: `LOOP_ORCHESTRA_ROADMAP.md` (strategic direction
  and sequencing) and `OBSERVABILITY_PLATFORM_PLAN.md` (human-in-the-loop
  observability, control plane, and event architecture). Both describe proposed,
  not yet active, runtime contracts.
