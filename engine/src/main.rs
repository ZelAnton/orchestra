//! CLI for the T-097 Stage 1 spike.
//!
//! Subcommands:
//!   selfcheck                 Run the hermetic supervision + parse demo (no network,
//!                             no model call) and print a JSON verdict. This is what the
//!                             self-check / a future CI job runs.
//!   claude   --live "<prompt>"  Spawn a REAL `claude -p --output-format stream-json`
//!                             child (opt-in; needs auth; consumes tokens). Prints the
//!                             supervised verdict + parsed stream-json result.
//!   codex    --live "<prompt>"  Spawn a REAL `codex exec` child (opt-in).
//!   argv     claude|codex     Print the argv the engine WOULD spawn (offline, safe).
//!   events   tail [--follow] <file>
//!                             Read a `.work/events.jsonl`-shaped file and print each decoded
//!                             event (contract §19) as one normalized JSON line. Without
//!                             `--follow` it reads to EOF and exits; with `--follow` it keeps
//!                             polling for newly appended lines. Read-only.
//!   state    [--json] [<work-dir>]
//!                             Load a read-only control-plane snapshot (contract §13) from a
//!                             `.work/` directory (default `.work`) — queue, task descriptors,
//!                             cohort admission, integration/join state, batch manifest — and
//!                             print it human-readably, or as one JSON object with `--json`.
//!                             Read-only: never writes, locks, or emits.
//!   plan     --dry-run [--work <dir>]
//!                             Print the cohort + per-task decisions the engine WOULD make now
//!                             over a read-only snapshot (default `.work`): the cohort
//!                             budget/circuit-breaker gate, the admission plan the planner's
//!                             "Выбор батча" resolver yields, and the per-active-task reviewer tier
//!                             (T-105). STRICTLY read-only: takes no `.work/orchestrator.lock`,
//!                             calls no mutating `queue-tx`/`state-tx`, creates no worktree/branch,
//!                             writes nothing. `--dry-run` is required (the only mode).
//!   __fake-agent ...          Hidden: a deterministic stand-in child used by the
//!                             hermetic tests and by `selfcheck` (emits stream-json,
//!                             can sleep / exit with a chosen code).
//!
//! No subcommand ever mutates the repository or `.work/`. Live model calls are strictly
//! opt-in via `--live`; the default path is offline and token-free.

use std::collections::BTreeSet;
use std::env;
use std::fmt::Write as _;
use std::fs;
use std::path::Path;
use std::process::exit;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use orchestra_engine_spike::claude::{ClaudeCall, PermissionPosture};
use orchestra_engine_spike::codex::{CodexCall, Sandbox};
use orchestra_engine_spike::events::TailReader;
use orchestra_engine_spike::resolvers::{
    admission_gate, base_reviewer, is_ready, plan_admission, unmet_prerequisites, ActiveClass,
    ActiveTask, AdmissionGate, AdmissionOutcome, Candidate, CohortCounters, CohortThresholds,
    Domain, Level,
};
use orchestra_engine_spike::state::{Snapshot, TaskState};
use orchestra_engine_spike::supervise::{self, SpawnSpec};

fn main() {
    let args: Vec<String> = env::args().collect();
    let cmd = args.get(1).map(|s| s.as_str()).unwrap_or("");
    match cmd {
        "selfcheck" => cmd_selfcheck(),
        "argv" => cmd_argv(&args),
        "claude" => cmd_claude(&args),
        "codex" => cmd_codex(&args),
        "events" => cmd_events(&args),
        "state" => cmd_state(&args),
        "plan" => cmd_plan(&args),
        "__fake-agent" => cmd_fake_agent(&args),
        "version" | "--version" => println!("orchestra-engine-spike 0.0.1"),
        _ => {
            eprintln!(
                "usage: orchestra-engine-spike <selfcheck|argv|claude|codex|events|state|plan|version>\n\
                 (see src/main.rs; live model calls require --live and are opt-in)"
            );
            exit(2);
        }
    }
}

/// Locate this very binary so the spike can spawn itself as the hermetic `__fake-agent`.
fn self_exe() -> String {
    env::current_exe()
        .ok()
        .and_then(|p| p.to_str().map(|s| s.to_string()))
        .unwrap_or_else(|| "orchestra-engine-spike".to_string())
}

/// Hermetic proof: supervise a stand-in child that emits a stream-json transcript, then
/// parse it. Also proves the deadline path by supervising a child that would outlive it.
fn cmd_selfcheck() {
    let exe = self_exe();
    let mut ok = true;

    // (1) A well-behaved "agent": emits a stream-json transcript, exits 0.
    let spec = SpawnSpec::new(
        &exe,
        vec!["__fake-agent".into(), "--mode".into(), "success".into()],
    )
    .deadline(Some(Duration::from_secs(30)));
    let v = supervise::run(&spec);
    let parsed = orchestra_engine_spike::claude::parse_transcript(&v.stdout);
    let success_ok = v.reason == supervise::Reason::Ok
        && parsed.result_seen
        && parsed.is_error == Some(false)
        && parsed.subtype.as_deref() == Some("success");
    ok &= success_ok;

    // (2) The deadline path: a child that sleeps past a short deadline must be classified
    // as `timeout` (reason 3) and its tree terminated.
    let spec = SpawnSpec::new(
        &exe,
        vec!["__fake-agent".into(), "--mode".into(), "hang".into()],
    )
    .deadline(Some(Duration::from_millis(400)));
    let v2 = supervise::run(&spec);
    let timeout_ok = v2.reason == supervise::Reason::Timeout && v2.timed_out;
    ok &= timeout_ok;

    // (3) A substantive error exit (nonzero, not a crash code) must be `error` (reason 6).
    let spec = SpawnSpec::new(
        &exe,
        vec![
            "__fake-agent".into(),
            "--mode".into(),
            "success".into(),
            "--exit".into(),
            "6".into(),
        ],
    )
    .deadline(Some(Duration::from_secs(30)));
    let v3 = supervise::run(&spec);
    let error_ok = v3.reason == supervise::Reason::Error && v3.exit_code == Some(6);
    ok &= error_ok;

    // Emit a small JSON verdict (hand-built; the spike is dependency-free).
    println!(
        "{{\"selfcheck\":\"{}\",\"success_case\":{{\"reason\":\"{}\",\"result_seen\":{},\"subtype\":\"{}\"}},\"timeout_case\":{{\"reason\":\"{}\",\"timed_out\":{}}},\"error_case\":{{\"reason\":\"{}\",\"exit_code\":{}}}}}",
        if ok { "pass" } else { "fail" },
        v.reason.as_str(),
        parsed.result_seen,
        parsed.subtype.as_deref().unwrap_or(""),
        v2.reason.as_str(),
        v2.timed_out,
        v3.reason.as_str(),
        v3.exit_code.unwrap_or(-1),
    );
    if !ok {
        exit(1);
    }
}

fn cmd_argv(args: &[String]) {
    let which = args.get(2).map(|s| s.as_str()).unwrap_or("");
    match which {
        "claude" => {
            let mut call = ClaudeCall::new(
                "Use the coder subagent to implement task T-1. Worktree=<abs>. WORK=<abs>.",
            );
            call.model = Some("sonnet".into());
            call.max_turns = Some(40);
            call.allowed_tools = vec!["Read".into(), "Edit".into(), "Bash".into()];
            call.posture = PermissionPosture::Allowlisted;
            println!("claude {}", join_argv(&call.to_argv()));
        }
        "codex" => {
            let mut call = CodexCall::new("/abs/worktree", Sandbox::WorkspaceWrite);
            call.model = Some("gpt-5-codex".into());
            call.skip_git_repo_check = false;
            println!("codex {}", join_argv(&call.to_argv()));
        }
        _ => {
            eprintln!("usage: argv <claude|codex>");
            exit(2);
        }
    }
}

fn cmd_claude(args: &[String]) {
    if !args.iter().any(|a| a == "--live") {
        eprintln!(
            "refusing to spawn a real model call without --live (this consumes tokens and needs auth).\n\
             Use `argv claude` to see the argv offline, or `selfcheck` for the hermetic demo."
        );
        exit(2);
    }
    let prompt = args.last().cloned().unwrap_or_default();
    let mut call = ClaudeCall::new(prompt);
    call.model = Some("sonnet".into());
    call.max_turns = Some(40);
    let argv = call.to_argv();
    let spec = SpawnSpec::new("claude", argv).deadline(Some(Duration::from_secs(600)));
    let v = supervise::run(&spec);
    let parsed = orchestra_engine_spike::claude::parse_transcript(&v.stdout);
    println!(
        "reason={} exit={:?} duration_ms={} result_seen={} is_error={:?} subtype={:?}",
        v.reason.as_str(),
        v.exit_code,
        v.duration_ms,
        parsed.result_seen,
        parsed.is_error,
        parsed.subtype
    );
    exit(v.reason.exit_code());
}

fn cmd_codex(args: &[String]) {
    if !args.iter().any(|a| a == "--live") {
        eprintln!("refusing to spawn a real codex call without --live.");
        exit(2);
    }
    let prompt = args.last().cloned().unwrap_or_default();
    let call = CodexCall::new(
        env::current_dir()
            .map(|p| p.display().to_string())
            .unwrap_or_default(),
        Sandbox::ReadOnly,
    );
    let spec = SpawnSpec::new("codex", call.to_argv())
        .stdin(prompt)
        .deadline(Some(Duration::from_secs(600)));
    let v = supervise::run(&spec);
    println!(
        "reason={} exit={:?} duration_ms={} output_bytes={}",
        v.reason.as_str(),
        v.exit_code,
        v.duration_ms,
        v.stdout.len() + v.stderr.len()
    );
    exit(v.reason.exit_code());
}

/// `events tail [--follow] <file>` — decode a `.work/events.jsonl`-shaped file and print each
/// new, unique, fully-committed event as one normalized JSON line (contract §19). Read-only:
/// it opens the file for reading, never writes or locks it. A torn/unterminated tail is never
/// printed. With `--follow` it polls indefinitely for appended lines (like `tail -f`).
fn cmd_events(args: &[String]) {
    let sub = args.get(2).map(|s| s.as_str()).unwrap_or("");
    if sub != "tail" {
        eprintln!("usage: events tail [--follow] <file>");
        exit(2);
    }
    let follow = args.iter().any(|a| a == "--follow");
    // The file is the first non-flag argument after `events tail`.
    let path = args.iter().skip(3).find(|a| !a.starts_with("--")).cloned();
    let path = match path {
        Some(p) => p,
        None => {
            eprintln!("usage: events tail [--follow] <file>");
            exit(2);
        }
    };

    // Without --follow a missing file is a user error; with --follow we tolerate it and wait.
    if !follow && !std::path::Path::new(&path).exists() {
        eprintln!("events tail: file not found: {path}");
        exit(2);
    }

    let mut reader = TailReader::new(&path);
    let poll_interval = Duration::from_millis(200);
    loop {
        match reader.poll() {
            Ok(events) => {
                for ev in events {
                    println!("{}", ev.to_json_line());
                }
            }
            Err(e) => {
                eprintln!("events tail: read error on {path}: {e}");
                exit(3);
            }
        }
        if !follow {
            break;
        }
        std::thread::sleep(poll_interval);
    }
}

/// `state [--json] [<work-dir>]` — load a read-only control-plane snapshot (contract §13) from a
/// `.work/` directory and print it. Human-readable by default; one compact JSON object with
/// `--json`. The work directory is the first non-flag argument (default `.work`). Read-only: the
/// snapshot only reads `.work/`, never writes, locks, or emits.
fn cmd_state(args: &[String]) {
    let json = args.iter().any(|a| a == "--json");
    // The work dir is the first non-flag argument after `state`; default to the project `.work`.
    let work = args
        .iter()
        .skip(2)
        .find(|a| !a.starts_with("--"))
        .cloned()
        .unwrap_or_else(|| ".work".to_string());

    // A wholly missing work directory is a usage error (likely a wrong path); missing individual
    // artifacts inside a real `.work/` are tolerated by `Snapshot::load` as the idle state.
    if !std::path::Path::new(&work).is_dir() {
        eprintln!("state: work directory not found: {work}");
        exit(2);
    }

    let snap = Snapshot::load(&work);
    if json {
        println!("{}", snap.to_json());
    } else {
        print!("{}", snap.to_human());
    }
}

/// `plan --dry-run [--work <dir>]` — print the cohort + per-task decisions the engine WOULD make
/// now over a read-only snapshot (default `.work`): the cohort budget/circuit-breaker gate
/// ([`resolvers::budget`]), the admission plan ([`resolvers::admission::plan_admission`]), and the
/// per-active-task reviewer tier ([`resolvers::tiering::base_reviewer`], T-105). STRICTLY
/// read-only: it only reads `.work/` (snapshot + `config.md` + `Tasks_Done.md`) and the wall clock;
/// it takes no lock, calls no mutating `queue-tx`/`state-tx`, and creates no worktree/branch.
fn cmd_plan(args: &[String]) {
    if !args.iter().any(|a| a == "--dry-run") {
        eprintln!(
            "usage: plan --dry-run [--work <dir>]\n\
             (dry-run is the only mode: it prints the cohort + per-task decisions the engine WOULD\n\
              make now over a READ-ONLY snapshot — it never locks, mutates, spawns, or writes)"
        );
        exit(2);
    }
    // `--work <dir>`, or a bare positional after `plan` (like `state`), default `.work`.
    let work = opt(args, "--work")
        .or_else(|| args.iter().skip(2).find(|a| !a.starts_with("--")).cloned())
        .unwrap_or_else(|| ".work".to_string());

    if !Path::new(&work).is_dir() {
        eprintln!("plan: work directory not found: {work}");
        exit(2);
    }

    let snap = Snapshot::load(&work);
    let cfg = PlanConfig::load(&work);
    let completed = completed_ids(&work, &snap);
    print!("{}", render_plan(&snap, &cfg, &completed, now_epoch_secs()));
}

/// The config keys the dry-run needs (parsed read-only from `.work/config.md`, with the documented
/// defaults when a key is absent/commented).
struct PlanConfig {
    max_parallel: u32,
    reviewer_tiering: bool,
    thresholds: CohortThresholds,
}

impl PlanConfig {
    fn load(work: &str) -> PlanConfig {
        let text = fs::read_to_string(Path::new(work).join("config.md")).unwrap_or_default();
        let max_parallel = config_u64(&text, "MAX_PARALLEL").unwrap_or(1).max(1) as u32;
        let size =
            config_u64(&text, "COHORT_SIZE").unwrap_or((3 * max_parallel as u64).max(1)) as u32;
        let max_age_minutes = config_u64(&text, "COHORT_MAX_AGE").unwrap_or(90);
        // COHORT_BUDGET_SEC: 0 (or absent) = no budget circuit-breaker.
        let budget_sec = config_u64(&text, "COHORT_BUDGET_SEC").filter(|&b| b > 0);
        let reviewer_tiering = config_bool(&text, "REVIEWER_TIERING").unwrap_or(true);
        PlanConfig {
            max_parallel,
            reviewer_tiering,
            thresholds: CohortThresholds {
                size,
                max_age_minutes,
                budget_sec,
            },
        }
    }
}

/// Render the dry-run report as one human-readable block. Pure over its inputs (the wall clock is
/// passed in as `now_epoch`), so it prints exactly what the resolvers decide for this snapshot.
fn render_plan(
    snap: &Snapshot,
    cfg: &PlanConfig,
    completed: &BTreeSet<String>,
    now_epoch: u64,
) -> String {
    let mut s = String::new();
    let _ = writeln!(
        s,
        "Engine plan (dry-run) — WORK={}",
        snap.work_dir.display()
    );
    let _ = writeln!(
        s,
        "(read-only: no orchestrator.lock, no queue-tx/state-tx, no worktrees, no writes)"
    );
    let _ = writeln!(s);

    // --- Cohort + budget/circuit-breaker gate (resolvers::budget) -------------------------------
    match &snap.cohort {
        Some(c) => {
            let admitted = c.admitted_total.unwrap_or(0);
            let _ = write!(
                s,
                "Cohort: {} · admission={}",
                c.batch_id.as_deref().unwrap_or("(no batch id)"),
                c.admission.map(|a| a.as_str()).unwrap_or("?"),
            );
            if let Some(r) = &c.admission_reason {
                let _ = write!(s, " (reason={r})");
            }
            if let Some(w) = c.wave {
                let _ = write!(s, " · wave={w}");
            }
            let _ = write!(s, " · admitted={admitted}");
            let elapsed_sec = c
                .started_at
                .as_deref()
                .and_then(parse_iso_utc)
                .map(|start| now_epoch.saturating_sub(start));
            match elapsed_sec {
                Some(e) => {
                    let _ = writeln!(s, " · age={}m", e / 60);
                }
                None => {
                    let _ = writeln!(s, " · age=? (start time unknown)");
                }
            }

            let counters = CohortCounters {
                admitted_total: admitted,
                age_minutes: elapsed_sec.unwrap_or(0) / 60,
                elapsed_sec: elapsed_sec.unwrap_or(0),
            };
            let _ = write!(s, "Budget/circuit-breaker gate: ");
            match admission_gate(counters, cfg.thresholds) {
                AdmissionGate::Continue => {
                    let _ = write!(s, "keep admitting (Continue)");
                }
                AdmissionGate::Close(reason) => {
                    let _ = write!(s, "close admission · причина={}", reason.as_str());
                }
            }
            let budget_disp = cfg
                .thresholds
                .budget_sec
                .map(|b| b.to_string())
                .unwrap_or_else(|| "0".to_string());
            let _ = writeln!(
                s,
                "  [COHORT_SIZE={}, COHORT_MAX_AGE={}m, COHORT_BUDGET_SEC={}]",
                cfg.thresholds.size, cfg.thresholds.max_age_minutes, budget_disp
            );
        }
        None => {
            let _ = writeln!(
                s,
                "Cohort: none (no active cohort) — budget/circuit-breaker gate N/A"
            );
        }
    }
    let _ = writeln!(s);

    // --- Active tasks: blocking class + per-task base reviewer tier (T-105) ----------------------
    // Domains/classes come from the batch manifest joined with descriptor states.
    let mut active_tasks: Vec<ActiveTask> = Vec::new();
    let _ = writeln!(
        s,
        "Active tasks (status · blocking class · base reviewer tier — REVIEWER_TIERING={}):",
        cfg.reviewer_tiering
    );
    let mut any_active = false;
    if let Some(b) = &snap.batch {
        for t in &b.tasks {
            any_active = true;
            let state = snap
                .descriptors
                .iter()
                .find(|d| d.id == t.id)
                .and_then(|d| d.state);
            let class = state.and_then(ActiveClass::from_state);
            let domain = Domain::parse(t.domain.as_deref().unwrap_or(""));
            if let Some(cls) = class {
                active_tasks.push(ActiveTask { domain, class: cls });
            }
            let class_disp = match class {
                Some(ActiveClass::Active) => "active",
                Some(ActiveClass::Terminal) => "terminal",
                None => "non-blocking",
            };
            let _ = write!(
                s,
                "  {} · status={} · class={class_disp}",
                t.id,
                state.map(|st| st.as_str()).unwrap_or("?"),
            );
            match t.level.as_deref().and_then(Level::from_field) {
                Some(level) => {
                    let _ = writeln!(
                        s,
                        " · reviewer={}",
                        base_reviewer(cfg.reviewer_tiering, level).as_str()
                    );
                }
                None => {
                    let _ = writeln!(s, " · reviewer=? (level unknown)");
                }
            }
        }
    }
    if !any_active {
        let _ = writeln!(s, "  (none — no batch manifest)");
    } else {
        let _ = writeln!(
            s,
            "  (only base_reviewer of the T-105 per-task resolvers is derivable from a static"
        );
        let _ = writeln!(
            s,
            "   snapshot; route_coder/route_reviewer/review_gate/review_cycle_decision need"
        );
        let _ = writeln!(
            s,
            "   per-round inputs — review.md, config flags, Реализовано: history — not held here.)"
        );
    }
    let _ = writeln!(s);

    // --- Admission plan over not-started queue candidates (resolvers::admission) -----------------
    let active_working = snap
        .descriptors
        .iter()
        .filter(|d| {
            matches!(
                d.state,
                Some(TaskState::Working) | Some(TaskState::InReview)
            )
        })
        .count() as u32;
    let free_slots = cfg.max_parallel.saturating_sub(active_working);

    let not_started: Vec<&_> = snap
        .queue
        .iter()
        .filter(|e| e.state == Some(TaskState::NotStarted))
        .collect();
    // Fresh-candidate conflict-domains are NOT in the read-only snapshot (the planner derives them
    // from task text); an empty domain conflicts with nothing, so packing here reflects readiness +
    // capacity + known active-task domains only. This is stated in the NOTE below.
    let candidates: Vec<Candidate> = not_started
        .iter()
        .map(|e| Candidate {
            id: e.id.clone(),
            ready: is_ready(&e.prerequisites, completed),
            domain: Domain::parse(""),
        })
        .collect();

    let _ = writeln!(
        s,
        "Admission plan (capacity={free_slots} free slot(s) of MAX_PARALLEL={}):",
        cfg.max_parallel
    );
    match plan_admission(&candidates, &active_tasks, free_slots as usize) {
        AdmissionOutcome::Admitted(ids) => {
            let _ = writeln!(s, "  would admit: {}", ids.join(", "));
        }
        AdmissionOutcome::Empty(reason) => {
            let _ = write!(s, "  admit nothing · причина={}", reason.as_str());
            match reason.to_close_reason() {
                Some(cr) => {
                    let _ = writeln!(s, " (would close admission · причина={})", cr.as_str());
                }
                None => {
                    let _ = writeln!(s, " (keep admission open, retry next round)");
                }
            }
        }
    }
    let _ = writeln!(s);

    let _ = writeln!(s, "Not-started candidates ({}):", not_started.len());
    for e in &not_started {
        let unmet = unmet_prerequisites(&e.prerequisites, completed);
        if unmet.is_empty() {
            let _ = writeln!(s, "  {} · ready", e.id);
        } else {
            let _ = writeln!(
                s,
                "  {} · blocked (unmet prereqs: {})",
                e.id,
                unmet.join(", ")
            );
        }
    }
    let _ = writeln!(s);
    let _ = writeln!(
        s,
        "NOTE: fresh-candidate conflict-domains are derived by the planner from task text and are"
    );
    let _ = writeln!(
        s,
        "      NOT part of the read-only snapshot; the admission plan reflects readiness + capacity"
    );
    let _ = writeln!(s, "      + known active-task domains only.");
    s
}

/// Current wall clock as seconds since the Unix epoch (0 if the clock is before the epoch).
fn now_epoch_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Parse a `YYYY-MM-DDTHH:MM:SS` UTC timestamp (as `cohort_state.md` `Начало когорты:` writes;
/// any trailing zone suffix `Z`/`+00:00` is ignored and treated as UTC) into epoch seconds.
/// `None` for a malformed timestamp. Uses Howard Hinnant's `days_from_civil` — no dependency.
fn parse_iso_utc(s: &str) -> Option<u64> {
    let b = s.as_bytes();
    let year: i64 = s.get(0..4)?.parse().ok()?;
    if b.get(4) != Some(&b'-') || b.get(7) != Some(&b'-') {
        return None;
    }
    let month: i64 = s.get(5..7)?.parse().ok()?;
    let day: i64 = s.get(8..10)?.parse().ok()?;
    match b.get(10) {
        Some(&b'T') | Some(&b' ') => {}
        _ => return None,
    }
    let hour: i64 = s.get(11..13)?.parse().ok()?;
    let min: i64 = s.get(14..16)?.parse().ok()?;
    let sec: i64 = s.get(17..19)?.parse().ok()?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    // days_from_civil: days since 1970-01-01 for a civil (proleptic Gregorian) date.
    let y = if month <= 2 { year - 1 } else { year };
    let era = (if y >= 0 { y } else { y - 399 }) / 400;
    let yoe = y - era * 400; // [0, 399]
    let mp = if month > 2 { month - 3 } else { month + 9 }; // [0, 11]
    let doy = (153 * mp + 2) / 5 + day - 1; // [0, 365]
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    let days = era * 146097 + doe - 719468;
    let secs = days * 86400 + hour * 3600 + min * 60 + sec;
    u64::try_from(secs).ok()
}

/// The value of a non-commented `KEY: value` line in `config.md` (`.work/config.md` is a small
/// `KEY: value` file; `#`-prefixed lines are comments / defaults). The exact key must be followed
/// by `:` so `MAX_PARALLEL` never matches `MAX_PARALLELISM`.
fn config_value<'a>(text: &'a str, key: &str) -> Option<&'a str> {
    text.lines()
        .map(str::trim)
        .filter(|l| !l.starts_with('#'))
        .find_map(|l| {
            let rest = l.strip_prefix(key)?.trim_start();
            let rest = rest.strip_prefix(':')?.trim();
            Some(rest)
        })
}

/// The first whitespace token of a `config.md` numeric key (a trailing inline `# comment` is
/// ignored), parsed as `u64`.
fn config_u64(text: &str, key: &str) -> Option<u64> {
    config_value(text, key)?
        .split_whitespace()
        .next()?
        .parse()
        .ok()
}

/// A boolean `config.md` key (`true`/`false`), ignoring a trailing inline comment.
fn config_bool(text: &str, key: &str) -> Option<bool> {
    match config_value(text, key)?.split_whitespace().next()? {
        "true" => Some(true),
        "false" => Some(false),
        _ => None,
    }
}

/// The set of completed task ids for readiness: every `[T-NNN]` listed in `Tasks_Done.md` (done
/// tasks are removed from the queue) plus any descriptor already at `done`/`published`. Read-only.
fn completed_ids(work: &str, snap: &Snapshot) -> BTreeSet<String> {
    let mut set = BTreeSet::new();
    if let Ok(text) = fs::read_to_string(Path::new(work).join("Tasks_Done.md")) {
        for seg in text.split('[') {
            if let Some(end) = seg.find(']') {
                let id = &seg[..end];
                if is_task_id(id) {
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

/// `^T-\d` — a T-id is `T-` followed by at least one digit.
fn is_task_id(s: &str) -> bool {
    s.strip_prefix("T-")
        .and_then(|r| r.chars().next())
        .is_some_and(|c| c.is_ascii_digit())
}

/// Hidden deterministic stand-in child for hermetic tests / selfcheck.
///   --mode success   emit a valid stream-json transcript, exit (0 unless --exit given)
///   --mode hang      sleep 30s (so a short deadline fires) — the tree-kill target
///   --exit N         override the exit code
fn cmd_fake_agent(args: &[String]) {
    let mode = opt(args, "--mode").unwrap_or_else(|| "success".to_string());
    let exit_code: i32 = opt(args, "--exit")
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    match mode.as_str() {
        "success" => {
            println!(r#"{{"type":"system","subtype":"init","model":"fake"}}"#);
            println!(r#"{{"type":"assistant","message":{{"type":"message","role":"assistant"}}}}"#);
            println!(
                r#"{{"type":"result","subtype":"success","is_error":false,"num_turns":3,"result":"fake agent done"}}"#
            );
            exit(exit_code);
        }
        "hang" => {
            std::thread::sleep(Duration::from_secs(30));
            exit(exit_code);
        }
        other => {
            eprintln!("__fake-agent: unknown --mode {other}");
            exit(2);
        }
    }
}

fn opt(args: &[String], key: &str) -> Option<String> {
    args.iter()
        .position(|a| a == key)
        .and_then(|i| args.get(i + 1).cloned())
}

fn join_argv(argv: &[String]) -> String {
    argv.iter()
        .map(|a| {
            if a.chars().any(|c| c.is_whitespace()) {
                format!("\"{a}\"")
            } else {
                a.clone()
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}
