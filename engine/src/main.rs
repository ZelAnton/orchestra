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
//!   lease    <acquire|heartbeat|release|status> [--work <dir>] [--root <dir>]
//!            [--script <state-tx.ps1>] [--owner <id>] [--ttl <sec>] [--session <id>]
//!            [--pid <n>] [--json]
//!                             Take / renew / release / inspect the engine's owner lease on
//!                             `.work/orchestrator.lock`, the mutual-exclusion interlock with a
//!                             running `processor` (contract §14–§17, T-107). This is the ONE
//!                             subcommand that mutates `.work/` — but only via `tools/state-tx.ps1`
//!                             (owner-checked, liveness-checked) under the engine's own role
//!                             (`engine`). It never force-removes a foreign lease: `acquire`
//!                             succeeds when the lock is free or provably stale and cleanly refuses
//!                             a live processor lease; `release` presents the engine's own owner id
//!                             so it can only remove its own lease. See `src/lease.rs`.
//!   run      <--once|--drain> --work <sandbox> [--root <dir>] [--tools <dir>] [--base <ref>]
//!            [--batch <id>] [--cohort-size <n>] [--ttl <sec>] [--inject-escalate <T-ID>]
//!            [--live] [--codex-coder <off|fast|fast+std>] [--codex-network] [--json]
//!                             Drive ONE cohort/phase end-to-end over a SANDBOX `.work` (task
//!                             T-109): take the engine lease, admit a cohort (T-106), capture each
//!                             task through `queue-tx`, run ONE supervised leaf round, validate every
//!                             descriptor/cohort transition through `state-tx check-transition`, emit
//!                             the events through `outbox`, and release the lease. By default the leaf
//!                             round drives the deterministic offline `__fake-agent` stand-in;
//!                             `--live` (task T-244) opts into REAL `claude -p`/`codex exec` leaf
//!                             calls routed through the executor resolvers, each stating its
//!                             permission posture on its own argv. `--work` is REQUIRED and has no
//!                             default, so this can never touch the repository's live `.work`.
//!                             Select exactly one mode: `--once` runs one cohort; `--drain`
//!                             keeps the owner lease and opens consecutive cohorts until the
//!                             queue is empty, `.work/PAUSE` appears, or `--max-cohorts` is met.
//!   __fake-agent ...          Hidden: a deterministic stand-in child used by the
//!                             hermetic tests, by `selfcheck`, and by `run`'s round (emits
//!                             stream-json; `--mode leaf` carries a parseable leaf report, and
//!                             other modes can sleep / exit with a chosen code).
//!
//! The `lease` and `run` subcommands are the ONLY ones that mutate `.work/` — `lease` strictly
//! through the owner-checked `tools/state-tx.ps1`, and `run` strictly over a sandbox `.work` via
//! the transactional `tools/{state-tx,queue-tx,outbox}.ps1`. Every other subcommand is read-only.
//! Live model calls are strictly opt-in via `--live`; the default path is offline and token-free.

use std::collections::BTreeSet;
use std::env;
use std::fmt::Write as _;
use std::fs;
use std::path::Path;
use std::process::exit;
use std::time::Duration;

use orchestra_engine::claude::{ClaudeCall, PermissionPosture};
use orchestra_engine::codex::{CodexCall, Sandbox};
use orchestra_engine::events::TailReader;
use orchestra_engine::lease::{self, exit as lease_exit, AcquireVerdict, LeaseOp};
use orchestra_engine::resolvers::{
    admission_gate, base_reviewer, is_ready, plan_admission, unmet_prerequisites, ActiveClass,
    ActiveTask, AdmissionGate, AdmissionOutcome, Candidate, CodexCoder, CohortCounters,
    CohortThresholds, Domain, Level,
};
use orchestra_engine::run::{self, RunConfig};
use orchestra_engine::state::{completed_ids, now_epoch_secs, DeliveryTarget, Snapshot, TaskState};
use orchestra_engine::supervise::{self, SpawnSpec};
use orchestra_engine::time::days_from_civil;
use orchestra_engine::toolscript;

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
        "lease" => cmd_lease(&args),
        "run" => cmd_run(&args),
        "__fake-agent" => cmd_fake_agent(&args),
        "version" | "--version" => println!("orchestra-engine 0.0.1"),
        _ => {
            eprintln!(
                "usage: orchestra-engine <selfcheck|argv|claude|codex|events|state|plan|lease|run|version>\n\
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
        .unwrap_or_else(|| "orchestra-engine".to_string())
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
    let parsed = orchestra_engine::claude::parse_transcript(&v.stdout);
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

/// Failure modes of [`parse_live_prompt`]: kept distinct so each `cmd_claude`/`cmd_codex`
/// caller can print its own `--live`-specific refusal (they already had different wording)
/// while sharing the actual parsing/validation logic.
#[derive(Debug)]
enum LivePromptError {
    /// The required `--live` opt-in flag was never given.
    MissingLive,
    /// `--live` was present, but the prompt itself is missing, duplicated, or ambiguous.
    Bad(String),
}

/// Parse the arguments to `claude --live <prompt>` / `codex --live <prompt>` (T-272).
///
/// The prompt is deliberately NOT `args.last()`: with that, a bare `--live` (no prompt)
/// spawns a REAL, paid model call using the literal string `--live` as the prompt, and any
/// flag placed after (or instead of) the prompt silently steals its slot. Instead the prompt
/// must be given as a single explicit positional argument — which must be the FINAL token;
/// nothing, flag or otherwise, may follow it — or via `--prompt <value>`. Any other `--flag`,
/// a second positional, or a flag trailing the prompt is a hard parse error, never a silent
/// prompt substitution.
///
/// `rest` is the subcommand's own arguments, i.e. everything after `claude`/`codex`.
fn parse_live_prompt(rest: &[String]) -> Result<String, LivePromptError> {
    let mut live = false;
    let mut prompt: Option<String> = None;
    let n = rest.len();
    let mut i = 0;
    while i < n {
        let a = rest[i].as_str();
        match a {
            "--live" => live = true,
            "--prompt" => {
                i += 1;
                let value = rest
                    .get(i)
                    .ok_or_else(|| LivePromptError::Bad("--prompt requires a value".into()))?;
                if prompt.is_some() {
                    return Err(LivePromptError::Bad("prompt given more than once".into()));
                }
                prompt = Some(value.clone());
            }
            _ if a.starts_with("--") => {
                return Err(LivePromptError::Bad(format!("unrecognized flag: {a}")));
            }
            _ => {
                if prompt.is_some() {
                    return Err(LivePromptError::Bad("prompt given more than once".into()));
                }
                if i != n - 1 {
                    return Err(LivePromptError::Bad(format!(
                        "unexpected argument after the prompt: {}",
                        rest[i + 1]
                    )));
                }
                prompt = Some(a.to_string());
            }
        }
        i += 1;
    }
    if !live {
        return Err(LivePromptError::MissingLive);
    }
    match prompt {
        Some(p) if !p.is_empty() => Ok(p),
        _ => Err(LivePromptError::Bad(
            "missing prompt: pass it as a positional argument, or as --prompt <value>".into(),
        )),
    }
}

fn cmd_claude(args: &[String]) {
    let prompt = match parse_live_prompt(&args[2..]) {
        Ok(p) => p,
        Err(LivePromptError::MissingLive) => {
            eprintln!(
                "refusing to spawn a real model call without --live (this consumes tokens and needs auth).\n\
                 Use `argv claude` to see the argv offline, or `selfcheck` for the hermetic demo."
            );
            exit(2);
        }
        Err(LivePromptError::Bad(msg)) => {
            eprintln!(
                "usage: claude --live <prompt>  (the prompt must be a single positional \
                 argument, or --prompt <value>, with nothing after it): {msg}"
            );
            exit(2);
        }
    };
    let mut call = ClaudeCall::new(prompt);
    call.model = Some("sonnet".into());
    call.max_turns = Some(40);
    let argv = call.to_argv();
    let spec = SpawnSpec::new("claude", argv).deadline(Some(Duration::from_secs(600)));
    let v = supervise::run(&spec);
    let parsed = orchestra_engine::claude::parse_transcript(&v.stdout);
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
    let prompt = match parse_live_prompt(&args[2..]) {
        Ok(p) => p,
        Err(LivePromptError::MissingLive) => {
            eprintln!("refusing to spawn a real codex call without --live.");
            exit(2);
        }
        Err(LivePromptError::Bad(msg)) => {
            eprintln!(
                "usage: codex --live <prompt>  (the prompt must be a single positional \
                 argument, or --prompt <value>, with nothing after it): {msg}"
            );
            exit(2);
        }
    };
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
    let completed = completed_ids(Path::new(&work), &snap);
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
    // delivery lane (§11.1 — `next_major` is parked) + capacity + known active-task domains only.
    // This is stated in the NOTE below.
    let candidates: Vec<Candidate> = not_started
        .iter()
        .map(|e| Candidate {
            id: e.id.clone(),
            ready: is_ready(&e.prerequisites, completed),
            domain: Domain::parse(""),
            delivery: e.delivery_target,
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
        // A next_major entry is parked out of the ordinary current-lane admission (§11.1), so it
        // is never "ready" for capture regardless of its prerequisites — label it as such.
        if e.delivery_target == DeliveryTarget::NextMajor {
            let _ = writeln!(s, "  {} · next_major (parked, not admitted)", e.id);
            continue;
        }
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

/// Parse a `YYYY-MM-DDTHH:MM:SS` UTC timestamp (as `cohort_state.md` `Начало когорты:` writes;
/// any trailing zone suffix `Z`/`+00:00` is ignored and treated as UTC) into epoch seconds.
/// `None` for a malformed timestamp.
///
/// This is deliberately MORE LENIENT than the engine's strict `orchestra_engine::time::is_iso_utc`
/// / `iso_to_epoch` pair: the date/time separator may be `T` or a space, no trailing `Z` is
/// required, and fractional seconds are not supported — the historical shape `cohort_state.md`
/// emits. So it keeps its own lenient field scan here and reuses only the shared calendar core
/// `orchestra_engine::time::days_from_civil` (previously duplicated inline), which is the actual
/// arithmetic this task consolidates.
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
    // Shared calendar core: days since 1970-01-01 for this civil (proleptic Gregorian) date.
    let days = days_from_civil(year, month, day);
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

/// `engine lease <acquire|heartbeat|release|status>` — take / renew / release / inspect the
/// engine's owner lease on `.work/orchestrator.lock` (the mutual-exclusion interlock with a live
/// `processor`, contract §14–§17, T-107) STRICTLY through `tools/state-tx.ps1`. The engine holds
/// the lease under its own role (`engine`); it never impersonates the processor, never passes
/// `--force`, and never removes a foreign lease by hand. Exit-code / argv contract: `src/lease.rs`.
fn cmd_lease(args: &[String]) {
    let op = match args.get(2).map(|s| s.as_str()).and_then(LeaseOp::from_arg) {
        Some(op) => op,
        None => {
            eprintln!(
                "usage: lease <acquire|heartbeat|release|status> [--work <dir>] [--root <dir>]\n\
                 \x20            [--script <state-tx.ps1>] [--owner <id>] [--ttl <sec>] [--session <id>]\n\
                 \x20            [--pid <n>] [--json]\n\
                 (takes/renews/releases/inspects the engine's owner lease via tools/state-tx.ps1,\n\
                  role=engine — never impersonates processor, never --force, never rm -rf a lease)"
            );
            exit(lease_exit::USAGE);
        }
    };

    // Resolve --work (default `.work`), --root (default the work dir's parent), and the
    // `state-tx.ps1` script. All are absolutised so the child tool gets stable paths regardless of
    // the engine's own cwd; `--script` lets a test point at the real tool while using a throwaway
    // `.work`.
    let work = abs_path(&opt(args, "--work").unwrap_or_else(|| ".work".to_string()));
    let root = match opt(args, "--root") {
        Some(r) => abs_path(&r),
        None => work
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| work.clone()),
    };
    // An explicit `--script` is used as-is (existence-checked — this is the path the lease tests
    // use). The DEFAULT follows the shared checkout-vs-mirror identity rule (see
    // `toolscript::resolve_tool_script`, `docs/queue_contract.md` §9): `<root>/tools/state-tx.ps1`
    // ONLY when `root` is a proven Orchestra checkout (all three identity markers), else the
    // cc-sync mirror `~/.claude/scripts/state-tx.ps1`, else a clean "not found" — never a silent
    // run of a foreign/stale target-local `tools/state-tx.ps1`.
    let script = match opt(args, "--script") {
        Some(s) => {
            let p = abs_path(&s);
            if !p.exists() {
                eprintln!(
                    "lease: state-tx.ps1 not found at {} (pass --script <path> or --root <project root>)",
                    p.display()
                );
                exit(lease_exit::FAILED);
            }
            p
        }
        None => match toolscript::resolve_tool_script(&root, "state-tx.ps1") {
            Some(p) => p,
            None => {
                eprintln!(
                    "lease: state-tx.ps1 not found (no Orchestra checkout identity markers under {} \
                     and no cc-sync mirror at ~/.claude/scripts/state-tx.ps1; pass --script <path> \
                     or --root <project root>)",
                    root.display()
                );
                exit(lease_exit::FAILED);
            }
        },
    };

    let work_s = work.to_string_lossy().into_owned();
    let root_s = root.to_string_lossy().into_owned();
    let script_s = script.to_string_lossy().into_owned();
    let json = args.iter().any(|a| a == "--json");
    let ttl = opt(args, "--ttl");
    let session = opt(args, "--session");
    let pid = opt(args, "--pid");
    let owner = opt(args, "--owner");

    let code = match op {
        LeaseOp::Acquire => lease_acquire(
            &script_s,
            &work_s,
            &root_s,
            ttl.as_deref(),
            session.as_deref(),
            pid.as_deref(),
            owner.as_deref(),
        ),
        LeaseOp::Heartbeat => lease_heartbeat(&script_s, &work_s, owner.as_deref()),
        LeaseOp::Release => lease_release(&script_s, &work_s, owner.as_deref()),
        LeaseOp::Status => lease_status(&script_s, &work_s, json),
    };
    exit(code);
}

/// Make a path absolute against the current working directory without resolving symlinks
/// (so it stays a plain, tool-friendly path rather than a Windows `\\?\` extended path).
fn abs_path(p: &str) -> std::path::PathBuf {
    let path = Path::new(p);
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        env::current_dir()
            .map(|c| c.join(path))
            .unwrap_or_else(|_| path.to_path_buf())
    }
}

/// Run one `state-tx.ps1` operation under supervision. On a hard supervision failure
/// (spawn failure / timeout / crash — no clean exit code) print a diagnostic and return the
/// engine's `FAILED` code via `Err`; otherwise return the state-tx exit code and its verdict.
fn run_lease_op(script: &str, argv: &[String]) -> Result<(i32, supervise::Verdict), i32> {
    match lease::run_state_tx(script, argv, lease::STATE_TX_DEADLINE) {
        Err(e) => {
            eprintln!("lease: {e}");
            Err(lease_exit::FAILED)
        }
        Ok(v) => match v.exit_code {
            Some(code) => Ok((code, v)),
            None => {
                eprintln!(
                    "lease: state-tx did not complete ({}) — {}",
                    v.reason.as_str(),
                    v.outcome_reason
                );
                Err(lease_exit::FAILED)
            }
        },
    }
}

/// The first non-empty (trimmed) line of `state-tx`'s stderr — its refusal diagnostic.
fn state_tx_reason(stderr: &str) -> String {
    stderr
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .unwrap_or("(no diagnostic)")
        .to_string()
}

/// Print a clean refusal line (never a panic): the context, the raw state-tx exit code, and
/// its human diagnostic. Goes to stderr since the outcome is a nonzero exit.
fn print_lease_refusal(context: &str, stderr: &str, state_tx_code: i32) {
    eprintln!(
        "lease {context}: refused (state-tx exit {state_tx_code}) — {}",
        state_tx_reason(stderr)
    );
}

/// Print an acquire/takeover success, surfacing the owner id (for the caller to present on
/// later `heartbeat`/`release`) plus the raw state-tx line for generation/ttl detail.
fn print_acquire_success(state_tx_stdout: &str, adopted: bool) {
    let line = state_tx_stdout.trim();
    let owner = lease::extract_owner(line).unwrap_or_default();
    if adopted {
        println!("lease acquired (adopted a stale lease; previous owner provably not live) role=engine owner={owner}");
    } else {
        println!("lease acquired role=engine owner={owner}");
    }
    if !line.is_empty() {
        println!("state-tx: {line}");
    }
}

/// `engine lease acquire` — take the lease when the lock is free; on a provably **stale**
/// lease (state-tx exit 11) escalate to the liveness-gated `takeover` (never `--force`,
/// which still refuses a lease that raced live); cleanly refuse a live/legacy/corrupt lease.
fn lease_acquire(
    script: &str,
    work: &str,
    root: &str,
    ttl: Option<&str>,
    session: Option<&str>,
    pid: Option<&str>,
    owner: Option<&str>,
) -> i32 {
    let argv = lease::acquire_argv(work, root, ttl, session, pid, owner);
    let (code, v) = match run_lease_op(script, &argv) {
        Ok(x) => x,
        Err(c) => return c,
    };
    match lease::acquire_verdict(code) {
        AcquireVerdict::Acquired => {
            print_acquire_success(&v.stdout, false);
            lease_exit::OK
        }
        AcquireVerdict::Stale => {
            eprintln!(
                "lease acquire: a stale lease is present; adopting it via safe takeover \
                 (state-tx refuses a lease that is live)"
            );
            let targv = lease::takeover_argv(work, root, ttl, pid);
            let (tcode, tv) = match run_lease_op(script, &targv) {
                Ok(x) => x,
                Err(c) => return c,
            };
            match lease::takeover_verdict(tcode) {
                AcquireVerdict::Acquired => {
                    print_acquire_success(&tv.stdout, true);
                    lease_exit::OK
                }
                other => {
                    print_lease_refusal("acquire (takeover)", &tv.stderr, tcode);
                    lease::acquire_exit(other)
                }
            }
        }
        other => {
            print_lease_refusal("acquire", &v.stderr, code);
            lease::acquire_exit(other)
        }
    }
}

/// `engine lease heartbeat --owner <id>` — renew the engine's own lease (owner-checked).
fn lease_heartbeat(script: &str, work: &str, owner: Option<&str>) -> i32 {
    let owner = match owner {
        Some(o) if !o.is_empty() => o,
        _ => {
            eprintln!("lease heartbeat: --owner <id> is required (renew only your own lease)");
            return lease_exit::USAGE;
        }
    };
    let argv = lease::heartbeat_argv(work, owner);
    let (code, v) = match run_lease_op(script, &argv) {
        Ok(x) => x,
        Err(c) => return c,
    };
    let ec = lease::heartbeat_exit(code);
    if ec == lease_exit::OK {
        println!("lease heartbeat renewed owner={owner}");
        let line = v.stdout.trim();
        if !line.is_empty() {
            println!("state-tx: {line}");
        }
    } else {
        print_lease_refusal("heartbeat", &v.stderr, code);
    }
    ec
}

/// `engine lease release --owner <id>` — owner-checked release of the engine's OWN lease.
/// The engine always presents its owner id and never `--force`/`rm -rf`, so it can never
/// tear down a foreign lease (state-tx returns exit 13 for that — the late-cleanup guard).
fn lease_release(script: &str, work: &str, owner: Option<&str>) -> i32 {
    let owner = match owner {
        Some(o) if !o.is_empty() => o,
        _ => {
            eprintln!(
                "lease release: --owner <id> is required — the engine releases only its OWN \
                 lease (never --force, never rm -rf a foreign lease)"
            );
            return lease_exit::USAGE;
        }
    };
    let argv = lease::release_argv(work, owner);
    let (code, v) = match run_lease_op(script, &argv) {
        Ok(x) => x,
        Err(c) => return c,
    };
    let ec = lease::release_exit(code);
    if ec == lease_exit::OK {
        let line = v.stdout.trim(); // "released" or the idempotent "not-held"
        let word = if line.is_empty() { "released" } else { line };
        println!("lease {word} owner={owner}");
    } else {
        print_lease_refusal("release", &v.stderr, code);
    }
    ec
}

/// `engine lease status [--json]` — inspect the lease (live/stale, owner, role, TTL, heartbeat
/// age). A read-only query: it exits 0 whenever state-tx reported a state — including "no lease"
/// (the lock is free), a legacy lock, or a corrupt record — with the state carried in the output
/// (verbatim compact JSON with `--json`, like `engine state --json`). It fails only on a usage or
/// hard supervision error.
fn lease_status(script: &str, work: &str, json: bool) -> i32 {
    let argv = lease::status_argv(work, json);
    let (code, v) = match run_lease_op(script, &argv) {
        Ok(x) => x,
        Err(c) => return c,
    };
    if code == 2 {
        print_lease_refusal("status", &v.stderr, code);
        return lease_exit::USAGE;
    }
    let out = v.stdout.trim();
    if json {
        // state-tx prints one compact JSON object on stdout for every present/absent case;
        // pass it through verbatim so `--json` stays machine-parseable.
        if out.is_empty() {
            println!("{{\"present\":false}}");
        } else {
            println!("{out}");
        }
    } else if code == 14 || out == "no-lease" || out.is_empty() {
        println!("lease: none (free — no owner holds .work/orchestrator.lock)");
    } else {
        println!("lease: {out}");
    }
    lease_exit::OK
}

/// `run <--once|--drain> --work <sandbox>` — drive one or more cohort/phases over a SANDBOX `.work`
/// (task T-109). `--work` is REQUIRED and has NO default, so `run` can never silently resolve the
/// repository's live `.work`; exactly one mode is required. Offline by DEFAULT: each round drives the
/// deterministic `__fake-agent` stand-in. Opt into real leaf model calls with `--live` (task
/// T-244): each leaf then spawns a real `claude -p`/`codex exec` child with its permission posture
/// stated explicitly on its own argv; the transactional invariants (K-006) are unchanged.
fn cmd_run(args: &[String]) {
    let once = args.iter().any(|a| a == "--once");
    let drain = args.iter().any(|a| a == "--drain");
    if once == drain {
        eprintln!(
            "usage: run <--once|--drain> --work <sandbox> [--root <dir>] [--tools <dir>] [--base <ref>]\n\
             \x20          [--batch <id>] [--cohort-size <n>] [--ttl <sec>] [--inject-escalate <T-ID>]\n\
             \x20          [--review] [--inject-findings <T-ID>] [--review-loop-max <n>]\n\
             \x20          [--converge-after <n>] [--join] [--integration-loop-max <n>]\n\
             \x20          [--inject-merge-conflict <T-ID>] [--inject-f-findings]\n\
             \x20          [--integration-converge-after <n>] [--live] [--leaf-deadline <sec>]\n\
             \x20          [--codex-coder <off|fast|fast+std>] [--codex-network] [--max-cohorts <n>] [--json]\n\
             (--once runs one cohort; --drain runs consecutive cohorts; --work is REQUIRED and has no default.\n\
             \x20 --live opts into real claude/codex leaf calls — off by default the round stays hermetic.\n\
             \x20 --leaf-deadline overrides the per-leaf wall-clock budget; the default is 60s offline, minutes under --live)"
        );
        exit(run::exit::USAGE);
    }
    let work = match opt(args, "--work") {
        Some(w) if !w.is_empty() => abs_path(&w),
        _ => {
            eprintln!("run: --work <sandbox-dir> is required (run has no default work dir)");
            exit(run::exit::USAGE);
        }
    };
    let root = match opt(args, "--root") {
        Some(r) => abs_path(&r),
        None => work
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| work.clone()),
    };
    // An explicit `--tools <dir>` (harness/tests/fixtures) is used as-is — the current contract for
    // fixtures is unchanged. The DEFAULT follows the SAME checkout-vs-mirror identity rule
    // `cmd_lease` already uses for its `--script` (`toolscript::resolve_tool_script`,
    // `docs/queue_contract.md` §9, K-052): resolve `state-tx.ps1` (present in both a proven
    // checkout's `tools/` and the cc-sync mirror) and take its containing directory as `tools`.
    // This must NEVER silently fall back to a bare `root.join("tools")`: a non-checkout `root` may
    // itself carry a foreign/stale `tools/` directory, and trusting it unconditionally would let
    // `run` execute an unproven script tree from a caller-controlled `--root` — the exact
    // trust-boundary bug this resolver exists to close.
    let tools = match opt(args, "--tools") {
        Some(t) => abs_path(&t),
        None => match toolscript::resolve_tool_script(&root, "state-tx.ps1") {
            Some(p) => p
                .parent()
                .map(Path::to_path_buf)
                .unwrap_or_else(|| root.join("tools")),
            None => {
                eprintln!(
                    "run: tools directory not found (no Orchestra checkout identity markers under {} \
                     and no cc-sync mirror at ~/.claude/scripts; pass --tools <dir> or --root <project root>)",
                    root.display()
                );
                exit(run::exit::USAGE);
            }
        },
    };
    let batch_id = opt(args, "--batch")
        .filter(|s| !s.is_empty())
        .unwrap_or_else(run::default_batch_id);
    let base = opt(args, "--base").unwrap_or_else(|| "sandbox-base".to_string());
    let cohort_size = opt(args, "--cohort-size")
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(3)
        .max(1);
    let ttl_secs = opt(args, "--ttl")
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(900);
    let inject_escalate = opt(args, "--inject-escalate").filter(|s| !s.is_empty());
    let review = args.iter().any(|a| a == "--review");
    let inject_findings = opt(args, "--inject-findings").filter(|s| !s.is_empty());
    let review_loop_max = opt(args, "--review-loop-max")
        .and_then(|s| s.parse::<u32>().ok())
        .unwrap_or(8)
        .max(1);
    let converge_after_cycles = opt(args, "--converge-after").and_then(|s| s.parse::<u32>().ok());
    // The join barrier (phases 4–6) is opt-in and implies --review (it consumes the ready tasks the
    // review round produces).
    let join = args.iter().any(|a| a == "--join");
    let review = review || join;
    let integration_loop_max = opt(args, "--integration-loop-max")
        .and_then(|s| s.parse::<u32>().ok())
        .unwrap_or(8)
        .max(1);
    let inject_merge_conflict = opt(args, "--inject-merge-conflict").filter(|s| !s.is_empty());
    let inject_f_findings = args.iter().any(|a| a == "--inject-f-findings");
    let integration_converge_after =
        opt(args, "--integration-converge-after").and_then(|s| s.parse::<u32>().ok());
    // Opt-in live mode (task T-244): real `claude`/`codex` leaf calls instead of the offline
    // `__fake-agent` stand-in. Off by default, so the run stays hermetic and token-free.
    let live = args.iter().any(|a| a == "--live");
    // The Codex maker-routing flag fed to the coder resolver (default `off` = Claude-only). Only
    // meaningful under `--live`; an unrecognized value falls back to `off`.
    let codex_coder = opt(args, "--codex-coder")
        .as_deref()
        .and_then(CodexCoder::parse)
        .unwrap_or(CodexCoder::Off);
    let codex_network = args.iter().any(|a| a == "--codex-network");
    // Wall-clock budget for one supervised leaf. Separate fake/live defaults (60s vs minutes) so
    // the offline baseline is untouched while a real `--live` leaf gets a budget adequate for a
    // headless call; `--leaf-deadline <sec>` overrides either (clamped to ≥1s) for retuning without
    // a rebuild — a shared 60s cap would time-out→tree-kill every live leaf into escalation (R-01).
    let leaf_deadline_override = opt(args, "--leaf-deadline").and_then(|s| s.parse::<u64>().ok());
    let json = args.iter().any(|a| a == "--json");
    let max_cohorts = match opt(args, "--max-cohorts") {
        Some(raw) => match raw.parse::<usize>() {
            Ok(value) if value > 0 => value,
            _ => {
                eprintln!("run: --max-cohorts must be a positive integer");
                exit(run::exit::USAGE);
            }
        },
        None => usize::MAX,
    };

    let cfg = RunConfig {
        work,
        root,
        tools,
        self_exe: self_exe(),
        batch_id,
        base,
        cohort_size,
        reviewer_tiering: true,
        ttl_secs,
        inject_escalate,
        review,
        inject_findings,
        review_loop_max,
        converge_after_cycles,
        join,
        integration_loop_max,
        inject_merge_conflict,
        inject_f_findings,
        integration_converge_after,
        live,
        codex_coder,
        codex_network,
        leaf_deadline: run::resolve_leaf_deadline(leaf_deadline_override, live),
    };

    if drain {
        match run::run_drain(&cfg, max_cohorts) {
            Ok(report) => {
                if json {
                    println!("{}", report.to_json());
                } else {
                    print!("{}", report.to_human());
                }
            }
            Err(e) => {
                eprintln!("run: {}", e.message);
                exit(e.code);
            }
        }
        return;
    }
    match run::run_once(&cfg) {
        Ok(report) => {
            if json {
                println!("{}", report.to_json());
            } else {
                print!("{}", report.to_human());
            }
        }
        Err(e) => {
            eprintln!("run: {}", e.message);
            exit(e.code);
        }
    }
}

/// Hidden deterministic stand-in child for hermetic tests / selfcheck.
///   --mode success   emit a valid stream-json transcript, exit (0 unless --exit given)
///   --mode hang      sleep 30s (so a short deadline fires) — the tree-kill target
///   --mode leaf      emit a stream-json transcript whose `result` carries a parseable leaf
///                    report (contract markers) — used by `run`'s execution round. `--task <id>`
///                    names the task; `--verdict готово|эскалация` selects the terminal `ИТОГ:` line.
///   --mode review    the reviewer stand-in for `run`'s review round: write the task's `review.md`
///                    (the phase-2.6 gate input) under `--work`, then emit a reviewer transcript.
///                    `--task <id>` names the task; `--outcome clean|findings` selects a fresh
///                    `SUMMARY-R` (clean) vs an open `R-` (with-findings); `--summary-ts <iso>` is
///                    the fresh clean-pass summary timestamp the engine hands it.
///   --mode merge     the merger stand-in for `run`'s join barrier: write `merge_report.md` under
///                    `--work` (one `- [T-ID] merged=<SHA>` line per `--tasks T-101,T-102`, or
///                    `quarantined=<reason>` for each id in `--quarantine`), then emit a merger
///                    transcript. Deterministic, offline; no real VCS.
///   --mode integration-review  the full_reviewer stand-in for `run`'s integration review cycle:
///                    write `review_integration.md` under `--work` (a fresh `SUMMARY-F` for
///                    `--outcome clean`, an open `F-` for `findings`; `--summary-ts <iso>` is the
///                    fresh clean-pass timestamp), then emit a reviewer transcript.
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
        "leaf" => {
            // A deterministic leaf-agent stand-in for `run`'s round: emit a stream-json
            // transcript whose final `result` carries a parseable leaf report (the contract
            // markers `Изменённые файлы:` + the terminal `ИТОГ:` line). Offline, token-free.
            let task = opt(args, "--task").unwrap_or_else(|| "T-000".to_string());
            let verdict = opt(args, "--verdict").unwrap_or_else(|| "готово".to_string());
            let itog: &str = if verdict == "эскалация" {
                "ИТОГ: эскалация \u{00B7} режим=1 \u{00B7} причина=sandbox-fault"
            } else {
                "ИТОГ: готово \u{00B7} режим=1"
            };
            let report = format!(
                "Реализовал {task} в песочнице.\nИзменённые файлы: engine/src/{task}.rs\n{itog}"
            );
            println!(r#"{{"type":"system","subtype":"init","model":"fake"}}"#);
            println!(r#"{{"type":"assistant","message":{{"type":"message","role":"assistant"}}}}"#);
            // Build the result line via serde_json so the report (newlines, Cyrillic, the
            // middle-dot separator) is escaped correctly and round-trips through parse_transcript.
            let result_line = serde_json::json!({
                "type": "result",
                "subtype": "success",
                "is_error": false,
                "num_turns": 3,
                "result": report,
            });
            println!("{result_line}");
            exit(exit_code);
        }
        "review" => {
            // The reviewer stand-in for `run`'s review round. It writes the task's `review.md`
            // (the phase-2.6 gate input the engine reads back) and returns a machine-readable
            // reviewer report. Offline, token-free.
            let task = opt(args, "--task").unwrap_or_else(|| "T-000".to_string());
            let work = opt(args, "--work").unwrap_or_default();
            let outcome = opt(args, "--outcome").unwrap_or_else(|| "clean".to_string());
            let summary_ts =
                opt(args, "--summary-ts").unwrap_or_else(|| "2026-01-01T00:00:00Z".to_string());
            let findings = outcome == "findings";
            // A with-findings pass leaves ONE open `R-`; a clean pass writes a fresh `SUMMARY-R`
            // (newer than the engine's freshness mark) plus a resolved `R-` to exercise that the
            // gate ignores non-`новая` findings.
            let review_md = if findings {
                format!(
                    "# Review {task}\n\
                     ### [R-01] Missing error handling in the sandbox change — статус: новая\n\
                     - Файл: engine/src/{task}.rs\n"
                )
            } else {
                format!(
                    "# Review {task}\n\
                     ### [R-01] Minor naming nit (addressed) — статус: исправлено\n\
                     ### [SUMMARY-R-{summary_ts}] Итог ревью задачи — статус: готово к слиянию\n\
                     - Открытых проблем: 0\n"
                )
            };
            if !work.is_empty() {
                let dir = Path::new(&work).join("tasks").join(&task);
                let _ = fs::create_dir_all(&dir);
                let _ = fs::write(dir.join("review.md"), &review_md);
            }
            let itog: &str = if findings {
                "ИТОГ: есть находки \u{00B7} режим=ревью \u{00B7} открытых=1"
            } else {
                "ИТОГ: готово к слиянию \u{00B7} режим=ревью \u{00B7} открытых=0"
            };
            let report = format!("Ревью {task} в песочнице.\n{itog}");
            println!(r#"{{"type":"system","subtype":"init","model":"fake"}}"#);
            println!(r#"{{"type":"assistant","message":{{"type":"message","role":"assistant"}}}}"#);
            let result_line = serde_json::json!({
                "type": "result",
                "subtype": "success",
                "is_error": false,
                "num_turns": 3,
                "result": report,
            });
            println!("{result_line}");
            exit(exit_code);
        }
        "merge" => {
            // The merger stand-in for `run`'s join barrier. It writes `merge_report.md` (the Phase
            // 4.3 decision input the engine reads back) in the `agents/merger.md` format: one line
            // per task, `merged=<SHA>` by default or `quarantined=<reason>` for a `--quarantine` id.
            // Offline, token-free; no real VCS.
            let work = opt(args, "--work").unwrap_or_default();
            let batch = opt(args, "--batch").unwrap_or_else(|| "B-sandbox".to_string());
            let tasks: Vec<String> = opt(args, "--tasks")
                .unwrap_or_default()
                .split(',')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
            let quarantine: Vec<String> = opt(args, "--quarantine")
                .unwrap_or_default()
                .split(',')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
            let mut report_md = format!(
                "# Merge Report — Batch {batch}\nИнтеграционная ветка: integration/{batch}\nБаза: sandbox-base\n\n## Результаты\n"
            );
            let mut any_quarantine = false;
            for t in &tasks {
                if quarantine.iter().any(|q| q == t) {
                    any_quarantine = true;
                    report_md.push_str(&format!(
                        "- [{t}] quarantined=конфликт слияния в песочнице\n"
                    ));
                } else {
                    report_md.push_str(&format!("- [{t}] merged=sandbox-{t}\n"));
                }
            }
            report_md.push_str("\nИтоговая сборка интеграционной ветки: ok\n");
            if !work.is_empty() {
                let _ = fs::write(Path::new(&work).join("merge_report.md"), &report_md);
            }
            let merged_n = tasks
                .len()
                .saturating_sub(quarantine.iter().filter(|q| tasks.contains(q)).count());
            let itog = if any_quarantine {
                format!(
                    "ИТОГ: есть карантин \u{00B7} слито={merged_n} \u{00B7} карантин={} \u{00B7} сборка=ok",
                    quarantine.iter().filter(|q| tasks.contains(q)).count()
                )
            } else {
                format!("ИТОГ: слито всё \u{00B7} слито={merged_n} \u{00B7} карантин=0 \u{00B7} сборка=ok")
            };
            let report = format!("Слил ветки батча {batch} в песочнице.\n{itog}");
            println!(r#"{{"type":"system","subtype":"init","model":"fake"}}"#);
            println!(r#"{{"type":"assistant","message":{{"type":"message","role":"assistant"}}}}"#);
            let result_line = serde_json::json!({
                "type": "result",
                "subtype": "success",
                "is_error": false,
                "num_turns": 3,
                "result": report,
            });
            println!("{result_line}");
            exit(exit_code);
        }
        "integration-review" => {
            // The full_reviewer stand-in for `run`'s integration review cycle. It writes
            // `review_integration.md` (the phase-5.2 gate input the engine reads back): a fresh
            // `SUMMARY-F` for a clean pass, an open `F-` for a with-findings pass. Offline.
            let work = opt(args, "--work").unwrap_or_default();
            let outcome = opt(args, "--outcome").unwrap_or_else(|| "clean".to_string());
            let summary_ts =
                opt(args, "--summary-ts").unwrap_or_else(|| "2026-01-01T00:00:00Z".to_string());
            let findings = outcome == "findings";
            let review_md = if findings {
                "# Integration review\n\
                 ### [F-01] Build break after integrating the batch — статус: новая\n\
                 - Область: интеграционная ветка\n"
                    .to_string()
            } else {
                format!(
                    "# Integration review\n\
                     ### [F-01] Minor integration nit (addressed) — статус: исправлено\n\
                     ### [SUMMARY-F-{summary_ts}] Итог интеграционного ревью — статус: готово к слиянию\n\
                     - Открытых F-: 0\n"
                )
            };
            if !work.is_empty() {
                let _ = fs::write(Path::new(&work).join("review_integration.md"), &review_md);
            }
            let itog = if findings {
                "ИТОГ: есть находки \u{00B7} режим=ревью \u{00B7} открытых=1"
            } else {
                "ИТОГ: готово к слиянию \u{00B7} режим=ревью \u{00B7} открытых=0"
            };
            let report = format!("Интеграционное ревью в песочнице.\n{itog}");
            println!(r#"{{"type":"system","subtype":"init","model":"fake"}}"#);
            println!(r#"{{"type":"assistant","message":{{"type":"message","role":"assistant"}}}}"#);
            let result_line = serde_json::json!({
                "type": "result",
                "subtype": "success",
                "is_error": false,
                "num_turns": 3,
                "result": report,
            });
            println!("{result_line}");
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

#[cfg(test)]
mod live_prompt_tests {
    use super::{parse_live_prompt, LivePromptError};

    fn s(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    /// T-272: `claude --live` / `codex --live` with no prompt at all must refuse (not spawn
    /// with `--live` itself as the prompt).
    #[test]
    fn missing_prompt_is_rejected() {
        let err = parse_live_prompt(&s(&["--live"])).unwrap_err();
        assert!(matches!(err, LivePromptError::Bad(_)));
    }

    /// T-272: a flag placed after the prompt must never silently steal the prompt slot —
    /// the whole call is rejected instead.
    #[test]
    fn flag_after_prompt_is_rejected() {
        let err = parse_live_prompt(&s(&["--live", "do the thing", "--live"])).unwrap_err();
        assert!(matches!(err, LivePromptError::Bad(_)));

        let err = parse_live_prompt(&s(&["--live", "do the thing", "--bogus"])).unwrap_err();
        assert!(matches!(err, LivePromptError::Bad(_)));
    }

    /// The plain, valid call must keep working exactly as before.
    #[test]
    fn normal_prompt_without_trailing_flags_is_accepted() {
        let prompt = parse_live_prompt(&s(&["--live", "do the thing"])).expect("valid call");
        assert_eq!(prompt, "do the thing");
    }

    /// `--live` missing entirely is its own distinct, more specific error so callers can
    /// print the "needs --live" refusal rather than a generic usage error.
    #[test]
    fn missing_live_flag_is_reported_distinctly() {
        let err = parse_live_prompt(&s(&["do the thing"])).unwrap_err();
        assert!(matches!(err, LivePromptError::MissingLive));
    }

    /// `--prompt <value>` is accepted as an explicit alternative to a bare positional.
    #[test]
    fn prompt_flag_form_is_accepted() {
        let prompt =
            parse_live_prompt(&s(&["--live", "--prompt", "do the thing"])).expect("valid call");
        assert_eq!(prompt, "do the thing");
    }

    /// A stray unrecognized flag before the prompt must also be rejected, not ignored.
    #[test]
    fn unrecognized_flag_before_prompt_is_rejected() {
        let err = parse_live_prompt(&s(&["--live", "--bogus", "do the thing"])).unwrap_err();
        assert!(matches!(err, LivePromptError::Bad(_)));
    }
}

#[cfg(test)]
mod parse_iso_utc_tests {
    use super::parse_iso_utc;

    /// The lenient `cohort_state.md` timestamp parser must keep its distinctive contract after
    /// moving the calendar arithmetic into `orchestra_engine::time::days_from_civil`: it accepts a
    /// `T` OR a space separator, needs no trailing `Z`, and computes the same epoch either way.
    #[test]
    fn accepts_both_t_and_space_separators() {
        // 2021-01-01T00:00:00Z == 1_609_459_200 epoch seconds.
        assert_eq!(parse_iso_utc("2021-01-01T00:00:00"), Some(1_609_459_200));
        assert_eq!(parse_iso_utc("2021-01-01 00:00:00"), Some(1_609_459_200));
        assert_eq!(parse_iso_utc("1970-01-01T00:00:00"), Some(0));
    }

    /// A trailing zone suffix (`Z`, `+00:00`, …) past the seconds is ignored, and within-day
    /// components land on the right second.
    #[test]
    fn ignores_trailing_zone_suffix_and_reads_time_of_day() {
        assert_eq!(parse_iso_utc("2021-01-01T00:00:00Z"), Some(1_609_459_200));
        assert_eq!(
            parse_iso_utc("2021-01-01T01:01:01+00:00"),
            Some(1_609_462_861)
        );
        // A leap-day instant confirms the shared calendar core: 2020-02-29T12:00:00 == 1_582_977_600.
        assert_eq!(parse_iso_utc("2020-02-29 12:00:00"), Some(1_582_977_600));
    }

    /// Malformed timestamps and out-of-range calendar fields are rejected (None), unchanged.
    #[test]
    fn rejects_malformed_and_out_of_range() {
        assert_eq!(parse_iso_utc(""), None);
        assert_eq!(parse_iso_utc("2021/01/01T00:00:00"), None); // wrong date separators
        assert_eq!(parse_iso_utc("2021-01-01X00:00:00"), None); // bad date/time separator
        assert_eq!(parse_iso_utc("2021-13-01T00:00:00"), None); // month out of range
        assert_eq!(parse_iso_utc("2021-01-32T00:00:00"), None); // day out of range
        assert_eq!(parse_iso_utc("2021-01-01T0a:00:00"), None); // non-digit time field
    }
}
