# Operator's Guide

This is the day-to-day guide for a human operating an Orchestra-managed project: what
to look at, and what to do, for the handful of situations that come up while
`processor` runs (or after it stops). It intentionally does not restate the full
`processor.md` algorithm — only the operator-facing surface. When something here is
silent about *why* the orchestrator behaves a certain way, `processor.md` is the
source of truth; this guide only needs to be self-sufficient for the actions listed
below.

All paths are relative to the target project's root; `.work/` is the orchestrator's
runtime state directory (gitignored). Launchers referenced below live in
`launchers/` and are invoked from that project's root.

## 1. Reading `status.md` and `journal.md`

Two files give you the orchestra's current and historical state without starting
Claude Code:

- `launchers/cc-status.cmd` prints the tail (~40 lines) of both `.work/status.md`
  (current overview) and `.work/journal.md` (run history) in the current directory.
- `launchers/cc-journal.cmd` prints only the `.work/journal.md` tail, if you just
  want history.

**`.work/status.md`** — the live overview, rewritten by `processor` at phase/round/
batch boundaries (not after every subagent step, so it can lag by a few minutes
during a busy round). Look at:
- `Оркестратор: processor — этап: …` — which phase processor is currently in
  (e.g. "исполнение когорты", "интеграция", "публикация", "очередь завершена").
- `Батч: <B-id> · активно N / cap <MAX_PARALLEL> · приём: открыт|закрыт` — how full
  the current cohort is and whether it is still admitting new tasks.
- The task table (`Задача | Название | Агент | Этап | Ветка | Worktree`) — which
  task each active leaf agent (coder/reviewer/merger/etc.) is working on right now,
  and where. If you need finer detail for one task than the overview shows, read its
  own `.work/tasks/<T-ID>/status.md` directly — that one updates live, per worker.

**`.work/journal.md`** — append-only, one block per finished cohort (batch), written
only at the end of Phase 6. This is the durable history to look at when nothing is
running, or when deciding whether to retune the config (see §7). Each block has, per
task, the level used, reviewer, review-cycle count (first-pass finds vs. fix-cycle
finds), diff size, and outcome (`merged=<SHA>`, `quarantined=<reason> (попытка=N)`,
or escalated). It also records how many admission waves the cohort took and why
admission closed (`COHORT_SIZE`, `COHORT_MAX_AGE`, `очередь-пуста`, or
`только-конфликты-с-готовыми` — the remaining queue candidates only overlap the
domain of tasks already at a terminal-for-admission state, so no further top-up is
possible this cohort), plus push/CI outcome and any rejected planner candidates. Don't
confuse this with `только-конфликты-с-активными`, which you will *not* see here: it's
a transient per-round state (a candidate overlaps a still-active task's domain and may
unblock later in the same cohort) that keeps admission open rather than closing it, so
it never appears as an admission-close reason.

If Claude Code isn't running at all and you want a fuller live view (or to resume
work), see §6 and `launchers/cc-resume.cmd`.

## 2. An escalated task

A task's queue entry with `— статус: эскалирована · причина=<кратко>` (in
`.work/Tasks_Queue.md`) is terminal: `processor`/`planner` will never pick it up
again on their own. Escalation happens when implementation/review genuinely failed
(Phase 2.3/2.8), when a quarantined task exhausted `QUARANTINE_MAX_ATTEMPTS`
(see §3), or when a batch's ff-merge/CI/interactive step required a manual call that
wasn't safe to automate.

When you see one (or the orchestrator reports "очередь стоит: N задач эскалированы,
нужен ручной разбор" at the end of a run):

1. Read the `причина=` on the queue line — it's intentionally short; for more detail
   check `.work/journal.md` for that batch (search for the `T-ID`) and, if the
   descriptor directory still exists at `.work/tasks/<T-ID>/`, its `task.md`/
   `review.md`. Terminal descriptors are cleaned up once the queue line is updated
   (Phase 6.3), so if you're investigating right after a crash, check before it's
   swept.
2. Decide what actually needs to happen: the task's own scope may need rewriting
   (ambiguous/incorrect criteria), a dependency it silently needs may be missing, or
   the underlying repository issue (e.g. a persistent conflict domain, a flaky test)
   needs a human fix first.
3. To retry: edit the queue entry back to a normal `— статус: не начата` line
   yourself (drop the `эскалирована · причина=…` suffix; also drop any stale
   `· попытка=N` counter unless you specifically want to preserve it) — this is a
   direct edit to `.work/Tasks_Queue.md`, not something a launcher does for you.
   If the task description itself needs to change, edit the task body directly (the
   queue entry is self-contained; there's no separate patch mechanism).
4. To drop it instead: delete the `[T-ID]` block from `.work/Tasks_Queue.md`
   entirely. Do not re-queue verbatim if you haven't addressed the root cause — you'll
   just spend another `QUARANTINE_MAX_ATTEMPTS`/review-loop budget re-discovering the
   same failure.

## 3. A quarantined task (returned to queue)

Quarantine happens when `merger` can't cleanly integrate a task's branch (real merge
conflict, or the integrated build/tests break — see `.work/merge_report.md` while it
still exists, before Phase 6.4 removes it). `processor` re-queues it automatically as:

```
### [T-NNN] Task title — статус: не начата · попытка=<N+1> · карантин=<кратко>
```

This is a normal `не начата` entry (matched by the substring `статус: не начата`) —
`planner` will pick it up again like any other pending task, just with a fresh
conflict domain relative to whatever merged in the meantime. You generally **don't
need to do anything**: leave it in the queue and let the next batch retry it. The
`· попытка=N` suffix is a crash-safe attempt counter that `processor` maintains
itself (see `.work/Tasks_Queue.md` format spec); don't strip it or hand-edit the
number.

Once a task's attempt count reaches `QUARANTINE_MAX_ATTEMPTS` (default 3, see
`.work/config.md` / `config.example.md`), `processor` stops re-queueing it and marks
it `эскалирована · причина=карантин повторился <N> раз: <причина>` instead — treat it
per §2 from that point on.

When it's worth intervening before the retry budget runs out:
- The `карантин=<причина>` on the queue line, or the fuller reason in
  `.work/journal.md` for its prior attempt(s), repeats the same conflict every time
  (e.g. two tasks keep landing on the same file despite disjoint conflict domains,
  or a real logical conflict that automatic re-planning can't route around). In that
  case, fix the underlying issue yourself (split the task, correct its conflict
  domain, or resolve the design conflict) rather than spending the remaining
  attempts on retries that will fail the same way.
- If a build/test break is environmental rather than task-specific (flaky CI runner,
  missing local tool), fix the environment — the task itself isn't at fault.

## 4. Red CI after publication

`processor` treats the ff-merge into the main branch as final and pushes before
watching CI (Phase 5.3/5.4). If CI comes back red after push, `processor` doesn't
revert the merge — it dispatches a leaf executor (`coder`/`coder_deep`, or
`coder_codex` when `CODEX_CIFIX=on`) directly in the main working copy to fix the
break, in a bounded loop (`CI_FIX_MAX` cycles, default 5), committing **only the
files the fix actually touched** (never a blanket `git add -A`, since that would
also pick up the `.work/` `.gitignore` housekeeping edit from earlier in the run if
it happens to still be unstaged).

As the operator, this loop is usually invisible to you — `processor` handles it and
reports the outcome. You need to step in when:

- **`processor` reports "требуется ручное вмешательство"** after `CI_FIX_MAX` cycles:
  the automated fix loop gave up. The already-pushed code is *not* rolled back.
  Pull main, look at the failing CI run, and fix it yourself with a normal commit —
  there's no special orchestrator state to restore first.
- **`processor` reports "CI не проверен автоматически, подтвердите вручную"**: `gh`
  wasn't available or no run was found for the pushed commit in time. Check your CI
  provider directly; if it's actually red, fix it manually (`processor` has already
  moved on to the next batch by this point, it won't come back to this on its own).
- **main diverged during the batch** (`processor` reports "main разошёлся с базой
  батча … — требуется ручное вмешательство" — but note: **only after auto-resolution
  is exhausted**). `processor` no longer stops at the first sign of divergence. If
  `main` (locally, at the ff-merge) or `origin/main` (on push) moved out from under a
  batch — an out-of-band writer committing/pushing to the trunk while the batch was
  in flight, which the ownership lease can *detect* but not *prevent* — `processor`
  auto-resolves without you: it fetches, re-anchors the integration branch on top of
  the new tip, re-runs the integration review (Phases 5.1/5.2) on the resulting tree,
  and republishes as a genuine fast-forward — **never** `--force`, never dropping the
  moved-in commit or the batch's merged work, and never publishing the un-re-reviewed
  combination. This holds across a crash too: a `processor` that restarts after the
  local ff-merge but before the push is confirmed treats the batch as *not yet
  published* (its recovery keys "already published" off `origin/main`, not the local
  `main`), so it re-publishes — re-running the CI gate — rather than mis-archiving an
  un-pushed batch as done. It falls back to the manual "требуется ручное вмешательство" halt only
  after `INTEGRATION_LOOP_MAX` re-anchor attempts — i.e. an external writer moving the
  trunk faster than re-integration can converge, or a foreign change the re-verification
  cannot reconcile with the batch. In that residual case it keeps the integration
  branch/worktree around (`.work/worktrees/_integration`, `integration/<B-id>`);
  reconcile by hand and push, or ask a fresh `processor` run to pick a new base once
  main is stable. The proactive habit that avoids this entirely: **don't commit or push
  to `main` while a batch is running** — that is exactly the situation this recovers
  from, and avoiding it keeps publication a trivial fast-forward.

In every case, avoid running a second `processor` while you're doing manual repair —
see §5.

## 5. `--force-lock`: when it's safe, and what you're risking

`processor` takes an exclusive **ownership lease** at `.work/orchestrator.lock` (a
directory whose `lease.json` record carries owner/session id, project root, host, a
heartbeat, a TTL, and — when available — a local liveness proof (pid + that process's
creation time); see `docs/queue_contract.md`, §14) and holds it for the entire run,
renewing the heartbeat on phase/round boundaries. Normally you do **not** need
`--force-lock`: a `processor` starting against a lease it can prove is **stale** (the
holder pid is gone or reused, or the heartbeat is past its TTL) takes it over safely on
its own. `launchers/cc-processor.cmd --force-lock` deletes the lease directory before
starting — an **operator force-takeover** for the cases the automatic staleness check
can't decide on its own (e.g. the holder appears alive but you know it is not).

**Only use it after you've confirmed the previous `processor` run is actually dead**
— e.g. its Claude Code session/terminal is gone, and there's no other machine or
window that could still be mid-run against the same `.work/`. A stale lease (old
heartbeat / a pid that is no longer running) is the normal, expected case after a
crash or a manually killed session, and is handled automatically without the flag.

**What you're risking if you're wrong**: if another `processor` instance genuinely is
still running and you force past the lock, you get two orchestrators mutating the
same coordination files concurrently — `.work/Tasks_Queue.md`, `.work/status.md`,
`.work/batch.md`, `.work/cohort_state.md`, `.work/journal.md`, and potentially the
same task worktrees. That's not a crash-safe scenario; you can end up with
interleaved/corrupted queue entries, two agents racing on the same `task/<T-ID>`
branch, or a lost journal entry. If you're unsure, it's cheaper to wait and check
(e.g. is the terminal/process that ran it still open? did anyone else on the team
start a run?) than to force it.

Note that resuming your **own** interrupted session doesn't need `--force-lock` at
all: `launchers/cc-resume.cmd` does an **addressed** resume — it uses `claude
--continue` only when an addressed `processor` lease for this project exists
(`.work/orchestrator.lock/lease.json` with `role=processor`), otherwise it does an
explicit cold recovery from scratch — and `processor`'s own recovery logic (its system
prompt's Фаза 0) re-adopts its own stale lease (matching role/root, holder not live)
via a safe takeover without you doing anything. Reach for `--force-lock` only when the
lease was left by a session that is confirmed gone but still looks live to the
automatic check (e.g. a hung process), or when you're deliberately starting a fresh
session rather than continuing the old one.

## 6. Cleaning up orphaned worktrees

`processor`'s own recovery logic (run automatically at the start of every session,
including via `launchers/cc-resume.cmd`) reconciles worktrees against task
descriptors and the queue on its own — in the common case, just running
`launchers/cc-processor.cmd` or `cc-resume.cmd` again after a crash is enough, and
you don't need to clean anything up by hand. Manual cleanup is for cases where you
want to fully reset state without resuming (e.g. abandoning a batch), or where you've
confirmed no `processor` will ever reconcile a given directory again.

An "orphaned" worktree is a leftover `.work/worktrees/<T-ID>` (or
`.work/worktrees/_integration`) directory/branch from a run that crashed before
Phase 6 cleanup, with no active `processor` going to revisit it. Signs to check
first, before deleting anything:
- Is a `processor` actually running right now (see §5)? If so, let it finish or
  crash on its own — don't delete a worktree out from under a live run.
- Does `.work/tasks/<T-ID>/task.md` still exist, with a non-terminal `Статус`? If
  so, prefer running `processor` again (it will reconcile the worktree against the
  descriptor) over manual deletion — deleting the worktree without also clearing the
  descriptor and queue entry will just confuse the next recovery pass.

If you do want to remove one by hand (project abandoned, batch you're discarding,
etc.), remove the worktree/branch **before** touching the descriptor or queue entry,
and in this order (worktree first, then branch — the VCS refuses to delete a branch
that's still checked out in a worktree):

- **git**: `git worktree remove --force ".work/worktrees/<T-ID>"`, then
  `git branch -D "task/<T-ID>"`; periodically follow up with `git worktree prune` to
  clear stale entries from `git worktree list`. For the integration worktree:
  `git worktree remove --force ".work/worktrees/_integration"`, then
  `git branch -D "integration/<B-id>"`.
- **jj**: `jj workspace forget <T-ID>` then `rm -rf ".work/worktrees/<T-ID>"` (order
  matters the other way from git — forget the workspace first); for the integration
  workspace, `jj workspace forget _integration; jj bookmark delete
  "integration/<B-id>"; rm -rf ".work/worktrees/_integration"`.

Then remove the now-orphaned `.work/tasks/<T-ID>/` descriptor directory and its
`.work/Tasks_Queue.md` entry (or reset the queue entry to `— статус: не начата` if
you want it retried instead of abandoned — see §2 for the exact edit). Both steps
are tolerant of partial state: if the worktree or branch is already gone, the
removal command failing is not a problem, just move on to the next step.

## 7. Tuning `MAX_PARALLEL` / `COHORT_*` / `REVIEW_*` from `journal.md`

`processor` never changes its own configuration — it only recommends changes in its
final report when it notices a skew. `.work/journal.md` is the durable signal to base
those changes on; read a handful of recent batch blocks and look for:

- **Conflict/quarantine rate** (`quarantined=<reason>` entries, and how many
  `попытка=N` retries a task needed before merging or escalating): frequent
  conflicts between concurrently-run tasks suggest lowering `MAX_PARALLEL` (fewer
  tasks in flight at once → less chance `planner` has to overlap conflict domains) —
  the practical ceiling is also bounded by how many genuinely non-overlapping domains
  `planner` can find, so raising `MAX_PARALLEL` past what the codebase's module
  boundaries support won't help.
- **Where review finds problems** (`циклов ревью=N (1-й прогон нашёл=X, фикс-циклы=Y)`
  per task): if most findings come from later fix-cycles rather than the first pass,
  a higher `REVIEW_MIN_PASSES` (more thorough first-pass search) may catch more
  before the fix-cycle loop, trading review time for fewer round-trips.
- **Escalation frequency**: recurring escalations for the same kind of task are a
  signal to look at the task/scope quality (see §2) more than at any single config
  knob — but a high rate of `REVIEW_LOOP_MAX`-exhausted escalations specifically
  suggests either `REVIEW_LOOP_MAX` is too low for the complexity of tasks being
  queued, or (more likely) the tasks themselves are too large/underspecified for the
  assigned coder tier.
- **Admission-wave count and close reason** (`волн приёма: W`, `Приём закрыт:
  <причина>`): many waves closed by `COHORT_MAX_AGE` rather than `COHORT_SIZE` means
  the cohort keeps timing out before it fills up — raise `COHORT_SIZE` (or lower
  `COHORT_MAX_AGE` if you'd rather publish sooner and accept smaller batches);
  closes dominated by `COHORT_SIZE` with `COHORT_MAX_AGE` never being the limiting
  factor suggest the opposite adjustment, or that the current values are already
  well matched to your task throughput.
- **`CI_FIX_MAX`/`QUARANTINE_MAX_ATTEMPTS` exhaustion**: if "требуется ручное
  вмешательство" (§4) or an escalation from exhausted quarantine attempts (§3) shows
  up repeatedly for reasons that *do* eventually get fixed by one more automated
  attempt, consider raising the corresponding limit; if the same failure just repeats
  identically every attempt, raising the limit won't help — fix the root cause
  instead (see §3/§4).

Apply changes in `.work/config.md` (seeded from `config.example.md` via
`launchers/cc-config.cmd`, which never overwrites an existing file) — see
`config.example.md` for the full key reference and defaults, including the
`COHORT_SIZE`/`COHORT_MAX_AGE` interaction described under its "rolling cohort
admission" section ("Роллинг-приём когорты").
Changes only affect batches started after the edit; nothing needs to be restarted for
them to take effect on the next `processor` invocation (there is no separate reload
step).

## 8. The operating toolchain: `cc-sync`, `cc-doctor`, and what CI actually checks

The launchers and their supporting scripts are one **cross-platform operating
toolchain**: `.cmd` on Windows and `.sh` on macOS/Linux invoke the *same* PowerShell 7
(`pwsh`) engine, so the two platforms behave identically rather than being two
hand-mirrored programs that can drift. This is what you can rely on, and how it is
verified.

**`cc-sync` — installing/refreshing the mirror (transactional).** `cc-sync.cmd`/
`cc-sync.sh` are thin wrappers over one engine, `tools/sync-runtime.ps1`, which mirrors
this repo's agent `*.md`, the launchers, `config.example.md` / `constraints.example.md`,
and the `cc-doctor` engine (`tools/doctor-runtime.ps1`) into your Claude environment
(`~/.claude`, `%USERPROFILE%\.claude` on Windows). Mirroring is **transactional**: every
file is published through a staging area with a journal-backed rollback, so an
interruption mid-publish (or a hard crash, recovered on the next run) is rolled back to
the exact prior state — you never get a half-applied mirror. The engine keeps a
**manifest** (`~/.claude/.orchestra-sync-manifest.json`) of the files it manages; on a
later sync it prunes only entries it previously wrote that are no longer sourced (a
renamed/deleted agent or launcher), and **never touches files it did not write** (agents
you added to the mirror by hand are safe). A destination that has been corrupted into an
empty directory where a file belongs is healed back into the file; a *non-empty*
directory blocking a file target is refused (it may hold real data) and the whole sync
rolls back. Re-run `cc-sync` from a checkout after editing any agent/launcher.

**`cc-doctor` — the read-only preflight (unified).** `cc-doctor.cmd`/`cc-doctor.sh` are
likewise thin wrappers over one engine, `tools/doctor-runtime.ps1`; run it from a target
project's root for a read-only readiness report (it never changes anything — not even a
stuck `orchestrator.lock` or an orphaned worktree, it only reports on them). It covers
the Codex preflight (binary/auth and the autonomous-runtime allow-rule), the effective
`CODEX_*` values and their fail-closed validation, KB status, the Windows sandbox
profile (a `N/A` line on POSIX, where the concept does not exist), and the task-queue /
lock / worktree / main-branch / agent-mirror audit. Because `cc-sync` mirrors the doctor
engine next to the launchers, `cc-doctor` works the same when run from the `~/.claude`
mirror as from a checkout. Its `OK`/`WARN`/`FAIL`/`N/A` lines are advisory text — it
always exits 0.

**CI (what runs automatically, on which OS).** `.github/workflows/ci.yml` runs on every
push and pull request on a **Windows + Linux matrix** (`windows-latest` and
`ubuntu-latest`), every step under `pwsh`. On both OSes it: regenerates the
template-driven `coder`/`reviewer` variants and fails on any drift from the committed
files; runs the mandatory validators `tools/validate-agents.ps1` and
`tools/check-consistency.ps1`; runs the Codex sandbox/config guard checks and the
Codex-runtime / reviewer-gate / policy tests; and runs the launcher test entry point
`tests/launchers/run-all.ps1`. On Windows that entry point runs the full launcher suite
(every `cc-*.cmd` test) plus the cross-platform engine tests; on Linux it runs the
cross-platform engine tests (`test-sync-runtime` / `test-doctor-runtime` /
`test-generate-coders`), so the unified `sync`/`doctor` runtimes are genuinely exercised
on Linux too. A **missing** mandatory validator or test entry point is a **hard CI
failure on that OS**, never a silent skip — the gates only mean something if they
actually run. If CI is red after a push, see §4.
