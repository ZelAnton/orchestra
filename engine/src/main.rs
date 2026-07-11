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
//!   __fake-agent ...          Hidden: a deterministic stand-in child used by the
//!                             hermetic tests and by `selfcheck` (emits stream-json,
//!                             can sleep / exit with a chosen code).
//!
//! No subcommand ever mutates the repository or `.work/`. Live model calls are strictly
//! opt-in via `--live`; the default path is offline and token-free.

use std::env;
use std::process::exit;
use std::time::Duration;

use orchestra_engine_spike::claude::{ClaudeCall, PermissionPosture};
use orchestra_engine_spike::codex::{CodexCall, Sandbox};
use orchestra_engine_spike::events::TailReader;
use orchestra_engine_spike::state::Snapshot;
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
        "__fake-agent" => cmd_fake_agent(&args),
        "version" | "--version" => println!("orchestra-engine-spike 0.0.1"),
        _ => {
            eprintln!(
                "usage: orchestra-engine-spike <selfcheck|argv|claude|codex|events|state|version>\n\
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
