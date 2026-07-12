//! `engine run --once --work <sandbox>` — the engine's FIRST real end-to-end orchestration of
//! ONE cohort/phase (task T-109), driven strictly over a **sandbox** `.work` handed in as
//! `--work <dir>` and never against a live repository `.work`.
//!
//! This is where the primitives built up by the spike and the T-103…T-107 layers are finally
//! *composed* into a control loop, but only in the hermetic sandbox `tools/harness.ps1` builds:
//!
//! 1. **Lease.** Take the engine's owner lease (role `engine`) through [`crate::lease`] /
//!    `tools/state-tx.ps1` (never a direct lock write, never `--force`; K-003), heartbeat it on
//!    every step boundary, and release it on completion OR error (no dangling owner lease).
//! 2. **Cohort open.** Read a control-plane [`Snapshot`], admit ready, non-overlapping candidates
//!    via the T-106 [`plan_admission`] resolver, and COMMIT the decision transactionally —
//!    `tools/queue-tx.ps1 capture` for each admitted task and the cohort admission transition
//!    validated by `tools/state-tx.ps1 check-transition --kind cohort` — never by hand-editing the
//!    queue / control-plane state.
//! 3. **One execution round.** For each captured task, run ONE supervised leaf call — the
//!    deterministic, offline `__fake-agent` stand-in (a real `--live` model call is deliberately
//!    out of scope) — parse its structured report with [`crate::contract`], apply the T-105
//!    per-task decision (reviewer tier via [`base_reviewer`]), validate the descriptor status
//!    transition through `state-tx check-transition --kind task`, write the descriptor, and emit
//!    the round/task events through `tools/outbox.ps1` in the §19 outbox format.
//! 4. **Per-task review round (opt-in, `--review`).** After the execution round, every task that
//!    reached `in-review` enters the phase-2.4…2.6 review round: the base reviewer tier is picked
//!    by [`base_reviewer`] and the concrete reviewer by [`reelect_reviewer`], a supervised reviewer
//!    stand-in writes the task's `review.md`, [`crate::contract::parse_review`] parses it, and
//!    [`review_gate`] names the branch. A **clean** pass (`in-review -> ready`) and a **with-findings**
//!    pass (`in-review -> in-review`, kept under the T-128 fix cycle) are DIFFERENT transitions,
//!    each validated through `state-tx check-transition` before the descriptor is written; the
//!    review round brackets and its promotions are emitted through `tools/outbox.ps1`. The phase is
//!    off by default so the T-109 execution-only baseline (which stops at `in-review`) is unchanged.
//!
//! **Boundaries this module keeps.** It touches ONLY the `.work` passed as `--work` (the run
//! subcommand has NO default work dir, so it can never silently resolve the repo's live `.work`);
//! it CALLS `tools/*.ps1` as they are and never edits them; every mutation of the queue / lease /
//! outbox goes through those transactional tools; and it is not wired into `agents/processor.md`
//! or any launcher. It is exercised by `engine run --once` and the hermetic `run_fixture` e2e test.

use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::json;

use crate::claude::{ClaudeCall, PermissionPosture};
use crate::contract::{parse_changed_files, parse_outcome, parse_review};
use crate::lease::{self, AcquireVerdict};
use crate::resolvers::{
    base_reviewer, is_ready, plan_admission, reelect_reviewer, review_gate, ActiveClass,
    ActiveTask, AdmissionOutcome, BaseReviewer, Candidate, CloseReason, CodexReviewer, Domain,
    ImplBy, Level, ReviewGate, ReviewerRoute,
};
use crate::state::{Snapshot, TaskState};
use crate::supervise::{self, Reason, SpawnSpec};

/// Engine-side exit codes for `engine run` (a small, documented vocabulary).
pub mod exit {
    /// Success: the run completed (a cohort was opened and one round ran, or there was nothing
    /// admissible — an idle run is not an error).
    pub const OK: i32 = 0;
    /// A tool / supervision failure (a `queue-tx`/`state-tx`/`outbox` call failed, a leaf could
    /// not be supervised, or a descriptor could not be written). The lease is released first.
    pub const FAILED: i32 = 1;
    /// Usage / argument error.
    pub const USAGE: i32 = 2;
    /// Refused: a live foreign lease (a running `processor`) holds `.work/orchestrator.lock`, or
    /// the lock is legacy/corrupt. A clean refusal — the engine never forces its way in.
    pub const LEASE_REFUSED: i32 = 3;
}

/// A structured, non-panicking run failure: an engine exit code plus a human diagnostic.
#[derive(Debug, Clone)]
pub struct RunError {
    pub code: i32,
    pub message: String,
}

impl RunError {
    fn new(code: i32, message: impl Into<String>) -> RunError {
        RunError {
            code,
            message: message.into(),
        }
    }
}

/// Everything `run --once` needs, resolved from the CLI by the caller.
#[derive(Debug, Clone)]
pub struct RunConfig {
    /// The **sandbox** `.work` directory to orchestrate over (required — no default).
    pub work: PathBuf,
    /// The project root recorded in the lease (defaults to the work dir's parent).
    pub root: PathBuf,
    /// The directory holding `state-tx.ps1` / `queue-tx.ps1` / `outbox.ps1` (defaults to
    /// `<root>/tools`).
    pub tools: PathBuf,
    /// This binary's path, so the engine can spawn itself as the deterministic `__fake-agent`.
    pub self_exe: String,
    /// The batch id to open (defaults to a fresh `B-<epoch>`).
    pub batch_id: String,
    /// The base ref recorded in `batch.md`.
    pub base: String,
    /// Admission capacity for this cohort (`COHORT_SIZE`).
    pub cohort_size: usize,
    /// Whether the reviewer tiering resolver is on (`REVIEWER_TIERING`, default true).
    pub reviewer_tiering: bool,
    /// The lease TTL in seconds.
    pub ttl_secs: u64,
    /// Optional task id whose leaf call emits an `эскалация` verdict — deterministic
    /// fault-injection for the escalation branch of the round.
    pub inject_escalate: Option<String>,
    /// Whether the per-task review round (phases 2.4–2.6) runs after the execution round. Off by
    /// default so the T-109 execution-only baseline (which stops at `in-review`) is unchanged.
    pub review: bool,
    /// Optional task id whose reviewer stand-in writes an open `R-` finding instead of a fresh
    /// clean `SUMMARY-R` — deterministic fault-injection for the with-findings review branch.
    pub inject_findings: Option<String>,
    /// Wall-clock bound on one supervised leaf call.
    pub leaf_deadline: Duration,
}

impl RunConfig {
    fn state_tx(&self) -> PathBuf {
        self.tools.join("state-tx.ps1")
    }
    fn queue_tx(&self) -> PathBuf {
        self.tools.join("queue-tx.ps1")
    }
    fn outbox(&self) -> PathBuf {
        self.tools.join("outbox.ps1")
    }
}

/// The outcome of driving one task through the round.
#[derive(Debug, Clone)]
pub struct TaskOutcome {
    pub id: String,
    /// The executor level the task was planned for (default `coder` in the sandbox).
    pub level: Level,
    /// The base Claude reviewer tier the T-105 tiering resolver picks for it.
    pub reviewer: BaseReviewer,
    /// The parsed terminal `ИТОГ:` verdict from the leaf report (empty if none).
    pub verdict: String,
    /// The supervised leaf-call stop reason (`ok` / `timeout` / …).
    pub supervised: &'static str,
    /// The descriptor state it started the round in (`working`).
    pub from: TaskState,
    /// The descriptor state it ended the round in (`in-review` on success, else `escalated`).
    pub to: TaskState,
    /// The files the leaf reported changing (`Изменённые файлы:`), if any.
    pub changed_files: Vec<String>,
    /// The per-task review-round outcome, when the review phase (`--review`) ran for this task
    /// (only tasks that reached `in-review` after execution are reviewed).
    pub review: Option<ReviewOutcome>,
}

/// The outcome of driving one `in-review` task through the phase-2.4…2.6 review round.
#[derive(Debug, Clone)]
pub struct ReviewOutcome {
    /// The concrete reviewer the tiering + Codex-routing resolvers elected (e.g. `reviewer`).
    pub reviewer: &'static str,
    /// The clean / findings / incomplete gate branch [`review_gate`] named.
    pub gate: &'static str,
    /// The supervised reviewer-leaf stop reason (`ok` / `timeout` / …).
    pub supervised: &'static str,
    /// The descriptor state the review round transitioned to: `ready` on a clean pass, `in-review`
    /// when findings keep it under the fix cycle, `escalated` on a reviewer-supervision failure.
    pub to: TaskState,
}

/// The report of one `run --once`.
#[derive(Debug, Clone)]
pub struct RunReport {
    pub owner: String,
    pub batch_id: String,
    pub admitted: Vec<String>,
    /// Set when nothing was admitted: the planner/close reason.
    pub idle_reason: Option<String>,
    pub tasks: Vec<TaskOutcome>,
    pub events_appended: usize,
    pub lease_released: bool,
}

impl RunReport {
    /// Render the report as a human-readable block (ends with a newline).
    pub fn to_human(&self) -> String {
        let mut s = String::new();
        let _ = writeln!(s, "Engine run --once (owner={})", self.owner);
        if let Some(r) = &self.idle_reason {
            let _ = writeln!(s, "Cohort: nothing admitted · причина={r}");
        } else {
            let _ = writeln!(
                s,
                "Cohort: {} opened · admitted={} [{}]",
                self.batch_id,
                self.admitted.len(),
                self.admitted.join(", ")
            );
        }
        for t in &self.tasks {
            let _ = writeln!(
                s,
                "  {} · level={} · reviewer={} · leaf={} · verdict={} · {} -> {}",
                t.id,
                t.level.as_str(),
                t.reviewer.as_str(),
                t.supervised,
                if t.verdict.is_empty() {
                    "(none)"
                } else {
                    &t.verdict
                },
                t.from.as_str(),
                t.to.as_str(),
            );
            if let Some(r) = &t.review {
                let _ = writeln!(
                    s,
                    "      review · reviewer={} · gate={} · leaf={} · {} -> {}",
                    r.reviewer,
                    r.gate,
                    r.supervised,
                    t.to.as_str(),
                    r.to.as_str(),
                );
            }
        }
        let _ = writeln!(
            s,
            "Events appended: {} · lease released: {}",
            self.events_appended, self.lease_released
        );
        s
    }

    /// Render the report as one compact JSON object (stable field order).
    pub fn to_json(&self) -> String {
        json!({
            "owner": self.owner,
            "batch_id": self.batch_id,
            "admitted": self.admitted,
            "idle_reason": self.idle_reason,
            "events_appended": self.events_appended,
            "lease_released": self.lease_released,
            "tasks": self.tasks.iter().map(|t| json!({
                "id": t.id,
                "level": t.level.as_str(),
                "reviewer": t.reviewer.as_str(),
                "verdict": t.verdict,
                "supervised": t.supervised,
                "from": t.from.as_str(),
                "to": t.to.as_str(),
                "changed_files": t.changed_files,
                "review": t.review.as_ref().map(|r| json!({
                    "reviewer": r.reviewer,
                    "gate": r.gate,
                    "supervised": r.supervised,
                    "to": r.to.as_str(),
                })),
            })).collect::<Vec<_>>(),
        })
        .to_string()
    }
}

// ---------------------------------------------------------------------------------------
// Pure helpers (unit-tested) — the byte-level Markdown the engine writes and the small
// decisions the round makes. Kept pure so a test pins them without any tool call.
// ---------------------------------------------------------------------------------------

/// The Cyrillic status literal for a canonical [`TaskState`] — the inverse of
/// `TaskState::from_markdown`, used to write the descriptor `Статус:` line and the outbox
/// event `--from`/`--to` coordinates, byte-for-byte with §13.1.
fn task_literal(state: TaskState) -> &'static str {
    match state {
        TaskState::NotStarted => "не начата",
        TaskState::Working => "в работе",
        TaskState::InReview => "на ревью",
        TaskState::Ready => "готова к слиянию",
        TaskState::Merged => "слита",
        TaskState::Published => "опубликована",
        TaskState::Done => "выполнена",
        TaskState::Escalated => "эскалирована",
        TaskState::Conflict => "конфликт",
    }
}

/// The round's per-task decision: a supervised, cleanly-`готово` leaf advances `working ->
/// in-review`; anything else (an `эскалация` verdict, a supervision timeout/crash, or a missing
/// terminal `ИТОГ:` line) is a `working -> escalated` — a fail-closed transition, never a silent
/// "assume success".
fn decide_to_state(supervised_ok: bool, verdict: &str) -> TaskState {
    if supervised_ok && verdict == "готово" {
        TaskState::InReview
    } else {
        TaskState::Escalated
    }
}

/// The review round's per-task decision over the [`review_gate`] branch (phases 2.6/2.7/2.8): a
/// supervised **clean** pass promotes `in-review -> ready`; **findings** and an **incomplete**
/// pass both keep the task `in-review` for the fix cycle (the T-128 successor owns the loop); a
/// reviewer that could not be supervised is a fail-closed `in-review -> escalated`, never a
/// silent "assume clean".
fn decide_review_state(supervised_ok: bool, gate: ReviewGate) -> TaskState {
    if !supervised_ok {
        return TaskState::Escalated;
    }
    match gate {
        ReviewGate::Clean => TaskState::Ready,
        ReviewGate::Findings | ReviewGate::Incomplete => TaskState::InReview,
    }
}

/// The stable label of a [`review_gate`] branch for the report / event payload.
fn review_gate_label(gate: ReviewGate) -> &'static str {
    match gate {
        ReviewGate::Clean => "clean",
        ReviewGate::Findings => "findings",
        ReviewGate::Incomplete => "incomplete",
    }
}

/// The concrete reviewer name a [`ReviewerRoute`] dispatches to (the tier for a Claude route /
/// diversity augment, `reviewer_codex` for a full Codex replacement).
fn route_reviewer_name(route: ReviewerRoute) -> &'static str {
    match route {
        ReviewerRoute::Claude(base) | ReviewerRoute::Augment(base) => base.as_str(),
        ReviewerRoute::CodexFull => "reviewer_codex",
    }
}

/// The cohort-admission close reason for a `--once` run that admitted `admitted` of a `capacity`
/// window: filling the window closes on `COHORT_SIZE`; admitting fewer (the queue ran dry of
/// admissible candidates) closes on `очередь-пуста` (§13.2 vocabulary).
fn close_reason(admitted: usize, capacity: usize) -> CloseReason {
    if capacity > 0 && admitted >= capacity {
        CloseReason::CohortSize
    } else {
        CloseReason::QueueEmpty
    }
}

/// Render the descriptor `task.md` the engine writes on capture / on a status transition.
fn descriptor_md(
    id: &str,
    state: TaskState,
    batch: &str,
    prerequisites: &[String],
    conflict_domain: Option<&[String]>,
) -> String {
    let mut s = String::new();
    let _ = writeln!(s, "# {id}");
    let _ = writeln!(s, "Статус: {}", task_literal(state));
    let _ = writeln!(s, "Ветка: task/{id}");
    let _ = writeln!(s, "Батч: {batch}");
    if !prerequisites.is_empty() {
        let _ = writeln!(s, "Предпосылки: {}", prerequisites.join(", "));
    }
    if let Some(domain) = conflict_domain {
        let _ = writeln!(s, "Конфликт-домен: {}", domain.join(", "));
    }
    s
}

/// Render `batch.md` (the §13 manifest the snapshot / TUI read back).
fn batch_md(batch: &str, base: &str, tasks: &[String]) -> String {
    let mut s = String::new();
    let _ = writeln!(s, "# Batch {batch}");
    let _ = writeln!(s, "База: {base}");
    let _ = writeln!(s, "Интеграционная ветка: integration/{batch}");
    let _ = writeln!(s);
    let _ = writeln!(s, "## Задачи");
    for id in tasks {
        let _ = writeln!(
            s,
            "- [{id}] уровень=coder ветка=task/{id} worktree=.work/worktrees/{id} волна=1"
        );
    }
    s
}

/// Render `cohort_state.md` (`Приём:` admission state, §13.2).
fn cohort_md(batch: &str, admission_literal: &str, admitted: usize) -> String {
    let mut s = String::new();
    let _ = writeln!(s, "# Cohort state — Batch {batch}");
    let _ = writeln!(s, "Приём: {admission_literal}");
    let _ = writeln!(s, "Волна: 1");
    let _ = writeln!(s, "Admitted всего: {admitted}");
    s
}

/// Current wall clock as seconds since the Unix epoch (0 if before the epoch).
fn now_epoch_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Format epoch seconds as an ISO-8601 UTC timestamp `YYYY-MM-DDTHH:MM:SSZ` (second precision) —
/// the inverse of `main::parse_iso_utc`, via Howard Hinnant's `civil_from_days` (no external
/// dependency). Second precision matches the `SUMMARY-R-<ts>` id format so the two sort lexically
/// with each other, which is exactly what the phase-2.6 freshness gate compares.
fn epoch_to_iso(secs: u64) -> String {
    let secs = secs as i64;
    let days = secs.div_euclid(86400);
    let tod = secs.rem_euclid(86400);
    let (hour, min, sec) = (tod / 3600, (tod % 3600) / 60, tod % 60);
    // civil_from_days: (days since 1970-01-01) -> (year, month, day), proleptic Gregorian.
    let z = days + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let day = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    let month = if mp < 10 { mp + 3 } else { mp - 9 }; // [1, 12]
    let year = if month <= 2 { y + 1 } else { y };
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{min:02}:{sec:02}Z")
}

/// The current wall clock as an ISO-8601 UTC `date -u` mark — the freshness cutoff the review
/// round records JUST BEFORE a reviewer call (a clean `SUMMARY-R` must be newer than this).
fn now_utc_iso() -> String {
    epoch_to_iso(now_epoch_secs())
}

/// A fresh, sandbox-only batch id when the caller did not pin one.
pub fn default_batch_id() -> String {
    format!("B-{}", now_epoch_secs())
}

/// The first non-empty trimmed stderr line — a tool's refusal diagnostic.
fn first_line(text: &str) -> &str {
    text.lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .unwrap_or("(no diagnostic)")
}

/// The planner's typed domain for one descriptor, when it exists and is usable.
fn descriptor_globs<'a>(snap: &'a Snapshot, id: &str) -> Option<&'a [String]> {
    snap.descriptors
        .iter()
        .find(|descriptor| descriptor.id == id)
        .and_then(|descriptor| descriptor.conflict_domain.as_deref())
}

/// Resolve a descriptor domain fail-closed: absent or malformed fields block packing with every
/// other task instead of behaving like an empty, conflict-free domain.
fn descriptor_domain(snap: &Snapshot, id: &str) -> Domain {
    descriptor_globs(snap, id)
        .map(Domain::from_globs)
        .unwrap_or_else(Domain::unknown)
}

/// A task's prerequisite ids from the queue snapshot (the descriptor the engine writes on capture
/// and on each transition carries them forward).
fn prereqs_of(snap: &Snapshot, id: &str) -> Vec<String> {
    snap.queue
        .iter()
        .find(|e| e.id == id)
        .map(|e| e.prerequisites.clone())
        .unwrap_or_default()
}

// ---------------------------------------------------------------------------------------
// The orchestrator. `run_once` acquires the lease, runs the body, and ALWAYS releases the
// lease (success or error) so no owner lease is left dangling in the sandbox.
// ---------------------------------------------------------------------------------------

/// Drive ONE cohort/phase end-to-end over the sandbox `.work` in `cfg.work`.
pub fn run_once(cfg: &RunConfig) -> Result<RunReport, RunError> {
    if !cfg.work.is_dir() {
        return Err(RunError::new(
            exit::USAGE,
            format!("work directory not found: {}", cfg.work.display()),
        ));
    }
    for (name, path) in [
        ("state-tx.ps1", cfg.state_tx()),
        ("queue-tx.ps1", cfg.queue_tx()),
        ("outbox.ps1", cfg.outbox()),
    ] {
        if !path.exists() {
            return Err(RunError::new(
                exit::USAGE,
                format!(
                    "{name} not found at {} (pass --tools <dir> or --root <project root>)",
                    path.display()
                ),
            ));
        }
    }

    let mut r = Runner::new(cfg);
    let owner = r.acquire_lease()?;
    r.owner = owner.clone();

    // Run the body; whatever happens, release the lease afterwards.
    let body = r.run_body();
    let released = r.release_lease().unwrap_or(false);

    match body {
        Ok(mut report) => {
            report.owner = owner;
            report.events_appended = r.events;
            report.lease_released = released;
            Ok(report)
        }
        Err(mut e) => {
            if !released {
                e.message
                    .push_str(" (warning: lease could not be released cleanly)");
            }
            Err(e)
        }
    }
}

/// Mutable orchestration state for one run.
struct Runner<'a> {
    cfg: &'a RunConfig,
    work_s: String,
    root_s: String,
    owner: String,
    events: usize,
}

impl<'a> Runner<'a> {
    fn new(cfg: &'a RunConfig) -> Runner<'a> {
        Runner {
            cfg,
            work_s: cfg.work.to_string_lossy().into_owned(),
            root_s: cfg.root.to_string_lossy().into_owned(),
            owner: String::new(),
            events: 0,
        }
    }

    // --- tool spawning -----------------------------------------------------------------

    /// Run a `.ps1` tool under supervision and require a clean exit 0; otherwise a `RunError`.
    fn tool_ok(
        &self,
        script: &Path,
        args: &[String],
        ctx: &str,
    ) -> Result<supervise::Verdict, RunError> {
        let s = script.to_string_lossy().into_owned();
        let v = lease::run_state_tx(&s, args, lease::STATE_TX_DEADLINE)
            .map_err(|e| RunError::new(exit::FAILED, format!("{ctx}: {e}")))?;
        match v.exit_code {
            Some(0) => Ok(v),
            Some(code) => Err(RunError::new(
                exit::FAILED,
                format!(
                    "{ctx}: {} exit {code} — {}",
                    script.display(),
                    first_line(&v.stderr)
                ),
            )),
            None => Err(RunError::new(
                exit::FAILED,
                format!(
                    "{ctx}: {} did not complete ({}) — {}",
                    script.display(),
                    v.reason.as_str(),
                    v.outcome_reason
                ),
            )),
        }
    }

    // --- lease -------------------------------------------------------------------------

    /// Take the engine's owner lease via `state-tx.ps1` (role `engine`): acquire a free lock, or
    /// adopt a provably-stale one via the liveness-gated `takeover` (never `--force`). A live
    /// foreign lease, a legacy lock, or a corrupt record is a CLEAN refusal, not a crash.
    fn acquire_lease(&mut self) -> Result<String, RunError> {
        let script = self.cfg.state_tx();
        let s = script.to_string_lossy().into_owned();
        let ttl = self.cfg.ttl_secs.to_string();
        let argv = lease::acquire_argv(&self.work_s, &self.root_s, Some(&ttl), None, None, None);
        let v = lease::run_state_tx(&s, &argv, lease::STATE_TX_DEADLINE)
            .map_err(|e| RunError::new(exit::FAILED, format!("lease acquire: {e}")))?;
        let code = v.exit_code.ok_or_else(|| {
            RunError::new(
                exit::FAILED,
                format!(
                    "lease acquire: state-tx did not complete ({})",
                    v.reason.as_str()
                ),
            )
        })?;
        match lease::acquire_verdict(code) {
            AcquireVerdict::Acquired => Self::owner_from(&v.stdout),
            AcquireVerdict::Stale => {
                // A provably-stale lease: adopt it via the liveness-gated takeover.
                let targv = lease::takeover_argv(&self.work_s, &self.root_s, Some(&ttl), None);
                let tv = lease::run_state_tx(&s, &targv, lease::STATE_TX_DEADLINE)
                    .map_err(|e| RunError::new(exit::FAILED, format!("lease takeover: {e}")))?;
                let tcode = tv.exit_code.ok_or_else(|| {
                    RunError::new(
                        exit::FAILED,
                        format!(
                            "lease takeover: state-tx did not complete ({})",
                            tv.reason.as_str()
                        ),
                    )
                })?;
                match lease::takeover_verdict(tcode) {
                    AcquireVerdict::Acquired => Self::owner_from(&tv.stdout),
                    other => Err(Self::refusal(other, &tv.stderr)),
                }
            }
            other => Err(Self::refusal(other, &v.stderr)),
        }
    }

    fn owner_from(stdout: &str) -> Result<String, RunError> {
        lease::extract_owner(stdout).ok_or_else(|| {
            RunError::new(
                exit::FAILED,
                "lease acquired but owner id was not parseable from state-tx output".to_string(),
            )
        })
    }

    fn refusal(v: AcquireVerdict, stderr: &str) -> RunError {
        let code = match v {
            AcquireVerdict::HeldLive | AcquireVerdict::Legacy | AcquireVerdict::Corrupt => {
                exit::LEASE_REFUSED
            }
            AcquireVerdict::Usage => exit::USAGE,
            _ => exit::FAILED,
        };
        RunError::new(
            code,
            format!(
                "lease refused (a live/legacy/corrupt lock is present) — {}",
                first_line(stderr)
            ),
        )
    }

    /// Renew the engine's own lease at a step boundary. A heartbeat failure is a hard error (a
    /// lost lease means we can no longer safely mutate the sandbox).
    fn heartbeat(&self) -> Result<(), RunError> {
        let argv = lease::heartbeat_argv(&self.work_s, &self.owner);
        self.tool_ok(&self.cfg.state_tx(), &argv, "lease heartbeat")?;
        Ok(())
    }

    /// Release the engine's own owner lease (owner-checked; never `--force`). Best-effort:
    /// returns whether it was released.
    fn release_lease(&self) -> Result<bool, RunError> {
        if self.owner.is_empty() {
            return Ok(false);
        }
        let argv = lease::release_argv(&self.work_s, &self.owner);
        match self.tool_ok(&self.cfg.state_tx(), &argv, "lease release") {
            Ok(_) => Ok(true),
            Err(_) => Ok(false),
        }
    }

    // --- state-tx transition validation ------------------------------------------------

    /// Validate a lifecycle transition through `state-tx check-transition` (read-only). The
    /// engine validates BEFORE it writes the descriptor / cohort file, exactly as the processor
    /// does — a rejected transition aborts the run rather than writing an illegal state.
    fn check_transition(&self, kind: &str, from: &str, to: &str) -> Result<(), RunError> {
        let argv = vec![
            "check-transition".into(),
            "--kind".into(),
            kind.into(),
            "--from".into(),
            from.into(),
            "--to".into(),
            to.into(),
        ];
        self.tool_ok(
            &self.cfg.state_tx(),
            &argv,
            &format!("check-transition {kind} {from}->{to}"),
        )?;
        Ok(())
    }

    // --- outbox -----------------------------------------------------------------------

    /// Append one event through `outbox.ps1`, owner-bound (single-writer invariant, §19).
    fn emit(&mut self, args: &[&str], ctx: &str) -> Result<(), RunError> {
        let mut a: Vec<String> = vec![
            "append".into(),
            "--work".into(),
            self.work_s.clone(),
            "--owner".into(),
            self.owner.clone(),
        ];
        a.extend(args.iter().map(|s| s.to_string()));
        self.tool_ok(&self.cfg.outbox(), &a, ctx)?;
        self.events += 1;
        Ok(())
    }

    // --- descriptor / coordination-file writes -----------------------------------------

    fn write_descriptor(
        &self,
        id: &str,
        state: TaskState,
        prerequisites: &[String],
        conflict_domain: Option<&[String]>,
    ) -> Result<(), RunError> {
        let dir = self.cfg.work.join("tasks").join(id);
        fs::create_dir_all(&dir)
            .map_err(|e| RunError::new(exit::FAILED, format!("create {}: {e}", dir.display())))?;
        let path = dir.join("task.md");
        fs::write(
            &path,
            descriptor_md(
                id,
                state,
                &self.cfg.batch_id,
                prerequisites,
                conflict_domain,
            ),
        )
        .map_err(|e| RunError::new(exit::FAILED, format!("write {}: {e}", path.display())))
    }

    fn write_file(&self, rel: &str, contents: &str) -> Result<(), RunError> {
        let path = self.cfg.work.join(rel);
        fs::write(&path, contents)
            .map_err(|e| RunError::new(exit::FAILED, format!("write {}: {e}", path.display())))
    }

    // --- the body ----------------------------------------------------------------------

    fn run_body(&mut self) -> Result<RunReport, RunError> {
        let snap = Snapshot::load(&self.cfg.work);
        let completed = completed_ids(&self.cfg.work, &snap);

        // Candidates: every not-started queue entry, ready iff its prerequisites are complete.
        // Their planner-created descriptors carry the conflict-domain. A missing or malformed
        // descriptor field is deliberately an unknown domain, which blocks packing fail-closed.
        let candidates: Vec<Candidate> = snap
            .queue
            .iter()
            .filter(|e| e.state == Some(TaskState::NotStarted))
            .map(|e| Candidate {
                id: e.id.clone(),
                ready: is_ready(&e.prerequisites, &completed),
                domain: descriptor_domain(&snap, &e.id),
            })
            .collect();

        // Active descriptors use the same state-layer domains, so ongoing work also blocks an
        // overlapping candidate. Missing/malformed values remain conservative here as well.
        let active: Vec<ActiveTask> = snap
            .descriptors
            .iter()
            .filter_map(|d| {
                d.state
                    .and_then(ActiveClass::from_state)
                    .map(|class| ActiveTask {
                        domain: descriptor_domain(&snap, &d.id),
                        class,
                    })
            })
            .collect();

        let admitted = match plan_admission(&candidates, &active, self.cfg.cohort_size) {
            AdmissionOutcome::Admitted(ids) => ids,
            AdmissionOutcome::Empty(reason) => {
                // Nothing to do — an idle run is not an error. Release happens in `run_once`.
                return Ok(RunReport {
                    owner: self.owner.clone(),
                    batch_id: self.cfg.batch_id.clone(),
                    admitted: Vec::new(),
                    idle_reason: Some(reason.as_str().to_string()),
                    tasks: Vec::new(),
                    events_appended: self.events,
                    lease_released: false,
                });
            }
        };

        // --- open the cohort ------------------------------------------------------------
        self.write_file(
            "batch.md",
            &batch_md(&self.cfg.batch_id, &self.cfg.base, &admitted),
        )?;
        self.write_file(
            "cohort_state.md",
            &cohort_md(&self.cfg.batch_id, "открыт", admitted.len()),
        )?;
        self.emit(
            &[
                "--type",
                "cohort.opened",
                "--batch-id",
                &self.cfg.batch_id,
                "--payload",
                "{\"wave\":1}",
            ],
            "emit cohort.opened",
        )?;
        self.heartbeat()?;

        // --- capture each admitted task transactionally through queue-tx ----------------
        for id in &admitted {
            let capture_argv = vec![
                "capture".into(),
                "--work".into(),
                self.work_s.clone(),
                "--id".into(),
                id.clone(),
                "--batch".into(),
                self.cfg.batch_id.clone(),
            ];
            self.tool_ok(
                &self.cfg.queue_tx(),
                &capture_argv,
                &format!("queue-tx capture {id}"),
            )?;
            self.write_descriptor(
                id,
                TaskState::Working,
                &prereqs_of(&snap, id),
                descriptor_globs(&snap, id),
            )?;
            self.emit(
                &[
                    "--type",
                    "task.captured",
                    "--batch-id",
                    &self.cfg.batch_id,
                    "--task-id",
                    id,
                    "--attempt",
                    "1",
                    "--payload",
                    "{\"level\":\"coder\"}",
                ],
                &format!("emit task.captured {id}"),
            )?;
            self.heartbeat()?;
        }

        // --- one round of execution -----------------------------------------------------
        self.emit(
            &[
                "--type",
                "cohort.round_started",
                "--batch-id",
                &self.cfg.batch_id,
                "--wave",
                "1",
                "--payload",
                "{}",
            ],
            "emit cohort.round_started",
        )?;

        let mut outcomes = Vec::new();
        for id in &admitted {
            let outcome =
                self.run_one_task(id, &prereqs_of(&snap, id), descriptor_globs(&snap, id))?;
            outcomes.push(outcome);
            self.heartbeat()?;
        }

        self.emit(
            &[
                "--type",
                "cohort.round_closed",
                "--batch-id",
                &self.cfg.batch_id,
                "--wave",
                "1",
                "--payload",
                "{}",
            ],
            "emit cohort.round_closed",
        )?;

        // --- the opt-in per-task review round (phases 2.4–2.6) --------------------------
        self.run_review_round(&snap, &mut outcomes)?;

        // --- close the cohort's admission (validated cohort transition) -----------------
        let reason = close_reason(admitted.len(), self.cfg.cohort_size);
        self.check_transition("cohort", "open", "closed")?;
        self.write_file(
            "cohort_state.md",
            &cohort_md(
                &self.cfg.batch_id,
                &format!("закрыт · причина={}", reason.as_str()),
                admitted.len(),
            ),
        )?;
        self.emit(
            &[
                "--type",
                "cohort.admission_closed",
                "--batch-id",
                &self.cfg.batch_id,
                "--payload",
                "{}",
            ],
            "emit cohort.admission_closed",
        )?;

        Ok(RunReport {
            owner: self.owner.clone(),
            batch_id: self.cfg.batch_id.clone(),
            admitted,
            idle_reason: None,
            tasks: outcomes,
            events_appended: self.events,
            lease_released: false,
        })
    }

    /// Run ONE task's round: a supervised leaf call (deterministic `__fake-agent` stand-in),
    /// contract parse, T-105 reviewer-tier decision, a validated descriptor transition, and the
    /// `task.status_changed` event.
    fn run_one_task(
        &mut self,
        id: &str,
        prerequisites: &[String],
        conflict_domain: Option<&[String]>,
    ) -> Result<TaskOutcome, RunError> {
        // The executor level in the sandbox defaults to `coder`; the T-105 tiering resolver still
        // runs over it to pick the reviewer tier (the one per-task decision derivable statically).
        let level = Level::Coder;
        let reviewer = base_reviewer(self.cfg.reviewer_tiering, level);

        // Build the headless claude argv the engine WOULD spawn for a real leaf call (proving the
        // claude.rs adapter is on the real path), then spawn the deterministic, offline stand-in
        // instead — a real `--live` model call is out of scope for this hermetic run.
        let prompt = format!(
            "Use the coder subagent to implement task {id}. Worktree={} WORK={}",
            self.cfg.work.join("worktrees").join(id).display(),
            self.cfg.work.display()
        );
        let mut call = ClaudeCall::new(prompt);
        call.model = Some("sonnet".into());
        call.max_turns = Some(40);
        call.posture = PermissionPosture::BypassInSandbox;
        let _would_argv = call.to_argv();

        let verdict_arg = if self.cfg.inject_escalate.as_deref() == Some(id) {
            "эскалация"
        } else {
            "готово"
        };
        let spec = SpawnSpec::new(
            &self.cfg.self_exe,
            vec![
                "__fake-agent".into(),
                "--mode".into(),
                "leaf".into(),
                "--task".into(),
                id.to_string(),
                "--verdict".into(),
                verdict_arg.to_string(),
            ],
        )
        .deadline(Some(self.cfg.leaf_deadline));
        let v = supervise::run(&spec);

        // Parse the stream-json transcript, then the leaf's structured report (contract.rs).
        let parsed = crate::claude::parse_transcript(&v.stdout);
        let report = parsed.result_text.unwrap_or_default();
        let outcome = parse_outcome(&report);
        let verdict = outcome
            .as_ref()
            .map(|o| o.verdict.clone())
            .unwrap_or_default();
        let changed_files = parse_changed_files(&report).unwrap_or_default();

        let supervised_ok = v.reason == Reason::Ok && parsed.is_error != Some(true);
        let to = decide_to_state(supervised_ok, &verdict);

        // Validate working -> {in-review|escalated} through the state machine, then write it.
        self.check_transition("task", TaskState::Working.as_str(), to.as_str())?;
        self.write_descriptor(id, to, prerequisites, conflict_domain)?;

        // On an escalation, also reflect it in the queue transactionally (queue-tx escalate) so
        // the queue and descriptor agree; the happy path leaves the queue as captured (в работе).
        if to == TaskState::Escalated {
            let esc_argv = vec![
                "escalate".into(),
                "--work".into(),
                self.work_s.clone(),
                "--id".into(),
                id.to_string(),
                "--reason".into(),
                "leaf escalated in sandbox round".into(),
            ];
            self.tool_ok(
                &self.cfg.queue_tx(),
                &esc_argv,
                &format!("queue-tx escalate {id}"),
            )?;
        }

        let from_lit = task_literal(TaskState::Working);
        let to_lit = task_literal(to);
        let payload = format!("{{\"from\":\"{from_lit}\",\"to\":\"{to_lit}\"}}");
        self.emit(
            &[
                "--type",
                "task.status_changed",
                "--task-id",
                id,
                "--from",
                from_lit,
                "--to",
                to_lit,
                "--attempt",
                "1",
                "--round",
                "1",
                "--payload",
                &payload,
            ],
            &format!("emit task.status_changed {id}"),
        )?;

        Ok(TaskOutcome {
            id: id.to_string(),
            level,
            reviewer,
            verdict,
            supervised: v.reason.as_str(),
            from: TaskState::Working,
            to,
            changed_files,
            review: None,
        })
    }

    /// The opt-in per-task review round (phases 2.4–2.6). Every task that reached `in-review`
    /// after the execution round is reviewed by a supervised reviewer stand-in; the round is
    /// bracketed by `cohort.round_started`/`cohort.round_closed` (wave 2, the review wave) in the
    /// same §19 envelope the execution round uses. A no-op when `--review` is off or no task
    /// reached review (e.g. every task escalated), so no empty review round is emitted.
    fn run_review_round(
        &mut self,
        snap: &Snapshot,
        outcomes: &mut [TaskOutcome],
    ) -> Result<(), RunError> {
        if !self.cfg.review {
            return Ok(());
        }
        if !outcomes.iter().any(|o| o.to == TaskState::InReview) {
            return Ok(());
        }

        self.emit(
            &[
                "--type",
                "cohort.round_started",
                "--batch-id",
                &self.cfg.batch_id,
                "--wave",
                "2",
                "--payload",
                "{}",
            ],
            "emit cohort.round_started (review)",
        )?;

        for outcome in outcomes.iter_mut() {
            // Only a successfully-executed (`in-review`) task is reviewed; an escalated one is not.
            if outcome.to != TaskState::InReview {
                continue;
            }
            let id = outcome.id.clone();
            let level = outcome.level;
            let prereqs = prereqs_of(snap, &id);
            let domain = descriptor_globs(snap, &id);
            let review = self.run_one_review(&id, level, &prereqs, domain)?;
            outcome.review = Some(review);
            self.heartbeat()?;
        }

        self.emit(
            &[
                "--type",
                "cohort.round_closed",
                "--batch-id",
                &self.cfg.batch_id,
                "--wave",
                "2",
                "--payload",
                "{}",
            ],
            "emit cohort.round_closed (review)",
        )?;
        Ok(())
    }

    /// Review ONE `in-review` task (phases 2.4–2.6): pick the tier via [`base_reviewer`] and the
    /// concrete reviewer via [`reelect_reviewer`]; take the freshness mark; run the supervised
    /// reviewer stand-in (deterministic `__fake-agent --mode review`, which writes the task's
    /// `review.md`); parse it with [`parse_review`]; name the branch with [`review_gate`]; validate
    /// and write the resulting descriptor transition; and emit the review-phase events. A **clean**
    /// pass promotes `in-review -> ready`, **findings** keep it `in-review` under the T-128 fix
    /// cycle, and a reviewer that could not be supervised fail-closes to `escalated`.
    fn run_one_review(
        &mut self,
        id: &str,
        level: Level,
        prerequisites: &[String],
        conflict_domain: Option<&[String]>,
    ) -> Result<ReviewOutcome, RunError> {
        // Resolver 1 (tiering): the base Claude reviewer tier for this level.
        let base = base_reviewer(self.cfg.reviewer_tiering, level);
        // Resolver 2b (reviewer routing / re-election): elect the concrete reviewer off the range
        // author. The sandbox is Claude-only (CODEX_REVIEWER=off, the last range authored by the
        // Claude coder stand-in), so this resolves to the base Claude reviewer — but through the
        // real resolver, never a hard-coded name.
        let route = reelect_reviewer(CodexReviewer::Off, base, level, &[ImplBy::Claude]);
        let reviewer_name = route_reviewer_name(route);

        // The phase-2.6 freshness cutoff: the UTC mark taken JUST BEFORE the reviewer call. A
        // clean `SUMMARY-R` must be newer than this. The clean stand-in stamps its summary one
        // second later (a deterministic, always-fresh "the reviewer finished after the mark").
        let since = now_utc_iso();
        let summary_ts = epoch_to_iso(now_epoch_secs() + 1);
        let want_findings = self.cfg.inject_findings.as_deref() == Some(id);

        // Build the headless reviewer `claude` argv the engine WOULD spawn (proving the adapter is
        // on the real path), then spawn the deterministic, offline reviewer stand-in instead.
        let prompt = format!(
            "Use the {reviewer_name} subagent to review task {id}. Worktree={} WORK={}",
            self.cfg.work.join("worktrees").join(id).display(),
            self.cfg.work.display()
        );
        let mut call = ClaudeCall::new(prompt);
        call.model = Some("opus".into());
        call.max_turns = Some(40);
        call.posture = PermissionPosture::BypassInSandbox;
        let _would_argv = call.to_argv();

        let outcome_arg = if want_findings { "findings" } else { "clean" };
        let spec = SpawnSpec::new(
            &self.cfg.self_exe,
            vec![
                "__fake-agent".into(),
                "--mode".into(),
                "review".into(),
                "--task".into(),
                id.to_string(),
                "--work".into(),
                self.work_s.clone(),
                "--outcome".into(),
                outcome_arg.to_string(),
                "--summary-ts".into(),
                summary_ts,
            ],
        )
        .deadline(Some(self.cfg.leaf_deadline));
        let v = supervise::run(&spec);
        let parsed = crate::claude::parse_transcript(&v.stdout);
        let supervised_ok = v.reason == Reason::Ok && parsed.is_error != Some(true);

        // The gate reads the `review.md` the reviewer wrote (phase 2.6), exactly like the
        // processor — the terminal `ИТОГ:` line is NOT what decides clean/with-findings.
        let review_md = fs::read_to_string(self.cfg.work.join("tasks").join(id).join("review.md"))
            .unwrap_or_default();
        let gate = review_gate(&parse_review(&review_md), &since);
        let to = decide_review_state(supervised_ok, gate);

        // Validate `in-review -> {ready|in-review|escalated}` through the state machine, then write.
        self.check_transition("task", TaskState::InReview.as_str(), to.as_str())?;
        self.write_descriptor(id, to, prerequisites, conflict_domain)?;

        // A reviewer that could not be supervised is a fail-closed escalation; reflect it in the
        // queue transactionally (queue-tx escalate) so the queue and descriptor agree.
        if to == TaskState::Escalated {
            let esc_argv = vec![
                "escalate".into(),
                "--work".into(),
                self.work_s.clone(),
                "--id".into(),
                id.to_string(),
                "--reason".into(),
                "reviewer leaf failed in sandbox review round".into(),
            ];
            self.tool_ok(
                &self.cfg.queue_tx(),
                &esc_argv,
                &format!("queue-tx escalate {id}"),
            )?;
        }

        // Emit the review-phase transition only when the descriptor status actually changes
        // (`in-review -> ready` on a clean pass, `-> escalated` on a supervision failure). A
        // with-findings pass keeps the task `in-review` (no status change) — the review-round
        // bracket already records that the review phase ran.
        if to != TaskState::InReview {
            let from_lit = task_literal(TaskState::InReview);
            let to_lit = task_literal(to);
            let payload = format!(
                "{{\"from\":\"{from_lit}\",\"to\":\"{to_lit}\",\"gate\":\"{}\"}}",
                review_gate_label(gate)
            );
            self.emit(
                &[
                    "--type",
                    "task.status_changed",
                    "--task-id",
                    id,
                    "--from",
                    from_lit,
                    "--to",
                    to_lit,
                    "--attempt",
                    "1",
                    "--round",
                    "1",
                    "--payload",
                    &payload,
                ],
                &format!("emit task.status_changed (review) {id}"),
            )?;
        }

        Ok(ReviewOutcome {
            reviewer: reviewer_name,
            gate: review_gate_label(gate),
            supervised: v.reason.as_str(),
            to,
        })
    }
}

/// The set of completed task ids for readiness: every `[T-NNN]` in `Tasks_Done.md` plus any
/// descriptor already `done`/`published`. Mirrors the same computation `plan --dry-run` uses.
fn completed_ids(work: &Path, snap: &Snapshot) -> std::collections::BTreeSet<String> {
    let mut set = std::collections::BTreeSet::new();
    if let Ok(text) = fs::read_to_string(work.join("Tasks_Done.md")) {
        for seg in text.split('[') {
            if let Some(end) = seg.find(']') {
                let id = &seg[..end];
                if id
                    .strip_prefix("T-")
                    .and_then(|r| r.chars().next())
                    .is_some_and(|c| c.is_ascii_digit())
                {
                    set.insert(id.to_string());
                }
            }
        }
    }
    for d in &snap.descriptors {
        if matches!(d.state, Some(TaskState::Done) | Some(TaskState::Published)) {
            set.insert(d.id.clone());
        }
    }
    set
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn task_literal_round_trips_through_canonical() {
        for st in [
            TaskState::NotStarted,
            TaskState::Working,
            TaskState::InReview,
            TaskState::Ready,
            TaskState::Merged,
            TaskState::Published,
            TaskState::Done,
            TaskState::Escalated,
            TaskState::Conflict,
        ] {
            assert_eq!(TaskState::from_markdown(task_literal(st)), Some(st));
        }
    }

    #[test]
    fn decide_to_state_is_fail_closed() {
        // Only a supervised, cleanly-готово leaf advances to review.
        assert_eq!(decide_to_state(true, "готово"), TaskState::InReview);
        // Anything else escalates: an escalation verdict, a supervision failure, a missing ИТОГ.
        assert_eq!(decide_to_state(true, "эскалация"), TaskState::Escalated);
        assert_eq!(decide_to_state(false, "готово"), TaskState::Escalated);
        assert_eq!(decide_to_state(true, ""), TaskState::Escalated);
    }

    #[test]
    fn close_reason_matches_capacity() {
        assert_eq!(close_reason(3, 3).as_str(), "COHORT_SIZE");
        assert_eq!(close_reason(2, 3).as_str(), "очередь-пуста");
        assert_eq!(close_reason(0, 0).as_str(), "очередь-пуста");
    }

    #[test]
    fn decide_review_state_maps_every_gate_branch_fail_closed() {
        // A supervised clean pass promotes to `ready`; findings/incomplete keep the task in review
        // for the fix cycle; a reviewer that could not be supervised fail-closes to `escalated`.
        assert_eq!(
            decide_review_state(true, ReviewGate::Clean),
            TaskState::Ready
        );
        assert_eq!(
            decide_review_state(true, ReviewGate::Findings),
            TaskState::InReview
        );
        assert_eq!(
            decide_review_state(true, ReviewGate::Incomplete),
            TaskState::InReview
        );
        // Supervision failure escalates regardless of what (if anything) landed in review.md.
        for gate in [
            ReviewGate::Clean,
            ReviewGate::Findings,
            ReviewGate::Incomplete,
        ] {
            assert_eq!(decide_review_state(false, gate), TaskState::Escalated);
        }
    }

    #[test]
    fn review_gate_labels_are_stable() {
        assert_eq!(review_gate_label(ReviewGate::Clean), "clean");
        assert_eq!(review_gate_label(ReviewGate::Findings), "findings");
        assert_eq!(review_gate_label(ReviewGate::Incomplete), "incomplete");
    }

    #[test]
    fn route_reviewer_name_maps_each_route() {
        use crate::resolvers::ReviewerRoute::*;
        assert_eq!(
            route_reviewer_name(Claude(BaseReviewer::Reviewer)),
            "reviewer"
        );
        assert_eq!(
            route_reviewer_name(Claude(BaseReviewer::ReviewerStd)),
            "reviewer_std"
        );
        assert_eq!(route_reviewer_name(CodexFull), "reviewer_codex");
        assert_eq!(
            route_reviewer_name(Augment(BaseReviewer::Reviewer)),
            "reviewer"
        );
    }

    #[test]
    fn epoch_to_iso_formats_known_utc_instants() {
        // Well-known epochs (UTC): 1970-01-01 and 2021-01-01, plus a within-day offset.
        assert_eq!(epoch_to_iso(0), "1970-01-01T00:00:00Z");
        assert_eq!(epoch_to_iso(1_609_459_200), "2021-01-01T00:00:00Z");
        assert_eq!(epoch_to_iso(1_609_462_861), "2021-01-01T01:01:01Z");
    }

    #[test]
    fn epoch_to_iso_is_lexically_monotonic_across_boundaries() {
        // The freshness gate compares timestamps lexically, so `+1s` must sort strictly greater —
        // including across a minute rollover (…T00:00:59Z < …T00:01:00Z).
        let boundary = 1_609_459_200 + 59; // 2021-01-01T00:00:59Z
        assert_eq!(epoch_to_iso(boundary), "2021-01-01T00:00:59Z");
        assert_eq!(epoch_to_iso(boundary + 1), "2021-01-01T00:01:00Z");
        assert!(epoch_to_iso(boundary + 1) > epoch_to_iso(boundary));
    }

    #[test]
    fn descriptor_md_parses_back() {
        let md = descriptor_md(
            "T-201",
            TaskState::Working,
            "B-1",
            &["T-200".to_string()],
            Some(&["engine/src/**".to_string()]),
        );
        let d = crate::state::parse_descriptor("T-201", &md);
        assert_eq!(d.state, Some(TaskState::Working));
        assert_eq!(d.prerequisites, vec!["T-200"]);
    }

    #[test]
    fn batch_md_parses_back() {
        let md = batch_md(
            "B-20260712T000000Z",
            "abc123",
            &["T-201".to_string(), "T-202".to_string()],
        );
        let b = crate::state::parse_batch(&md);
        assert_eq!(b.batch_id.as_deref(), Some("B-20260712T000000Z"));
        assert_eq!(b.base.as_deref(), Some("abc123"));
        assert_eq!(b.tasks.len(), 2);
        assert_eq!(b.tasks[0].id, "T-201");
        assert_eq!(b.tasks[0].level.as_deref(), Some("coder"));
    }

    #[test]
    fn cohort_md_parses_back_open_and_closed() {
        let open = crate::state::parse_cohort(&cohort_md("B-1", "открыт", 2));
        assert_eq!(open.admission.map(|a| a.as_str()), Some("open"));
        assert_eq!(open.admitted_total, Some(2));
        let closed =
            crate::state::parse_cohort(&cohort_md("B-1", "закрыт · причина=COHORT_SIZE", 3));
        assert_eq!(closed.admission.map(|a| a.as_str()), Some("closed"));
        assert_eq!(closed.admission_reason.as_deref(), Some("COHORT_SIZE"));
    }
}
