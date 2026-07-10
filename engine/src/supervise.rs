//! Supervise ONE child process outside Claude Code: enforce a wall-clock deadline,
//! drain stdout/stderr on threads (so a large output cannot deadlock the child), and on
//! timeout / cooperative cancel terminate the whole child tree, returning a structured,
//! non-sensitive verdict.
//!
//! The reason / exit-code contract is kept byte-compatible with `tools/supervisor.ps1`
//! (the existing PowerShell supervisor) so a future native port stays interchangeable
//! with it:
//!
//!   ok=0  timeout=3  cancelled=4  crash=5  error=6
//!
//! SPIKE SCOPE. Tree termination here is `taskkill /T /F` on Windows (reaches children)
//! and a direct `child.kill()` elsewhere. The production engine should use the Rust
//! line's `processkit` crate, whose kill-on-drop container (Windows Job Object /
//! Linux cgroup v2 / POSIX process group) guarantees no descendant outlives the parent —
//! exactly the guarantee `supervisor.ps1` gets from `Process.Kill($true)`.

use std::io::{Read, Write};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

/// The four supervised stop reasons (plus `ok`), matching tools/supervisor.ps1.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reason {
    Ok,
    Timeout,
    Cancelled,
    Crash,
    Error,
}

impl Reason {
    /// The exit code this reason maps to (identical to tools/supervisor.ps1).
    pub fn exit_code(self) -> i32 {
        match self {
            Reason::Ok => 0,
            Reason::Timeout => 3,
            Reason::Cancelled => 4,
            Reason::Crash => 5,
            Reason::Error => 6,
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Reason::Ok => "ok",
            Reason::Timeout => "timeout",
            Reason::Cancelled => "cancelled",
            Reason::Crash => "crash",
            Reason::Error => "error",
        }
    }
    /// Transient reasons a supervisor may safely retry (bounded): timeout / crash.
    pub fn is_transient(self) -> bool {
        matches!(self, Reason::Timeout | Reason::Crash)
    }
}

/// A structured, non-sensitive verdict for one supervised call.
#[derive(Debug, Clone)]
pub struct Verdict {
    pub reason: Reason,
    pub exit_code: Option<i32>,
    pub timed_out: bool,
    pub cancelled: bool,
    pub duration_ms: u128,
    pub stdout: String,
    pub stderr: String,
    pub outcome_reason: String,
}

/// What to spawn and how to bound it.
pub struct SpawnSpec {
    pub program: String,
    pub args: Vec<String>,
    pub stdin: String,
    pub deadline: Option<Duration>,
    /// Poll interval for the deadline / cancel watchdog.
    pub poll: Duration,
    /// If set, appearance of this file requests a cooperative cancel (e.g. .work/PAUSE).
    pub cancel_file: Option<std::path::PathBuf>,
}

impl SpawnSpec {
    pub fn new(program: impl Into<String>, args: Vec<String>) -> Self {
        SpawnSpec {
            program: program.into(),
            args,
            stdin: String::new(),
            deadline: None,
            poll: Duration::from_millis(50),
            cancel_file: None,
        }
    }
    pub fn stdin(mut self, s: impl Into<String>) -> Self {
        self.stdin = s.into();
        self
    }
    pub fn deadline(mut self, d: Option<Duration>) -> Self {
        self.deadline = d;
        self
    }
    pub fn cancel_file(mut self, p: Option<std::path::PathBuf>) -> Self {
        self.cancel_file = p;
        self
    }
}

/// Run one child under supervision and classify the outcome.
pub fn run(spec: &SpawnSpec) -> Verdict {
    let started = Instant::now();
    let mut cmd = Command::new(&spec.program);
    cmd.args(&spec.args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let mut child: Child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            // The process could not even be spawned — a tool/infrastructure crash.
            return Verdict {
                reason: Reason::Crash,
                exit_code: None,
                timed_out: false,
                cancelled: false,
                duration_ms: started.elapsed().as_millis(),
                stdout: String::new(),
                stderr: String::new(),
                outcome_reason: format!("spawn failed: {e}"),
            };
        }
    };

    // Feed stdin from a thread and drop the handle so the child sees EOF.
    if let Some(mut sin) = child.stdin.take() {
        let data = spec.stdin.clone().into_bytes();
        thread::spawn(move || {
            let _ = sin.write_all(&data);
            // sin dropped here => EOF for the child.
        });
    }

    // Drain stdout / stderr on their own threads (no deadlock against stdin / a full pipe).
    let out_rx = drain(child.stdout.take());
    let err_rx = drain(child.stderr.take());

    // Watchdog loop: poll for exit, deadline, or cancel-file.
    let mut timed_out = false;
    let mut cancelled = false;
    let exit_status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) => {}
            Err(_) => break None,
        }
        if let Some(d) = spec.deadline {
            if started.elapsed() >= d {
                timed_out = true;
                break None;
            }
        }
        if let Some(cf) = &spec.cancel_file {
            if cf.exists() {
                cancelled = true;
                break None;
            }
        }
        thread::sleep(spec.poll);
    };

    if timed_out || cancelled {
        kill_tree(&mut child);
    }
    // Reap (kill_tree already waited, but be sure) so no zombie remains.
    let _ = child.wait();

    let stdout = out_rx.recv().unwrap_or_default();
    let stderr = err_rx.recv().unwrap_or_default();
    let duration_ms = started.elapsed().as_millis();

    let (reason, exit_code, outcome_reason) = classify(exit_status, timed_out, cancelled, spec);
    Verdict {
        reason,
        exit_code,
        timed_out,
        cancelled,
        duration_ms,
        stdout,
        stderr,
        outcome_reason,
    }
}

fn classify(
    status: Option<std::process::ExitStatus>,
    timed_out: bool,
    cancelled: bool,
    spec: &SpawnSpec,
) -> (Reason, Option<i32>, String) {
    if cancelled {
        return (Reason::Cancelled, None, "cancel requested".into());
    }
    if timed_out {
        let secs = spec.deadline.map(|d| d.as_secs()).unwrap_or(0);
        return (
            Reason::Timeout,
            None,
            format!("deadline exceeded ({secs}s)"),
        );
    }
    match status {
        None => (
            Reason::Crash,
            None,
            "exit code unavailable after run".into(),
        ),
        Some(st) => {
            let code = st.code();
            match code {
                Some(0) => (Reason::Ok, Some(0), "exit code 0".into()),
                Some(rc) => (Reason::Error, Some(rc), format!("exit code {rc}")),
                // No code => killed by a signal (Unix): a crash, like supervisor.ps1.
                None => (Reason::Crash, None, "terminated by signal".into()),
            }
        }
    }
}

/// Drain a pipe to a String on a thread; the receiver gets the full text once EOF hits.
fn drain(handle: Option<impl Read + Send + 'static>) -> mpsc::Receiver<String> {
    let (tx, rx) = mpsc::channel();
    match handle {
        Some(mut h) => {
            thread::spawn(move || {
                let mut buf = Vec::new();
                let _ = h.read_to_end(&mut buf);
                let _ = tx.send(String::from_utf8_lossy(&buf).into_owned());
            });
        }
        None => {
            let _ = tx.send(String::new());
        }
    }
    rx
}

/// Terminate the child (and, on Windows, its whole tree) and wait briefly for it to die.
fn kill_tree(child: &mut Child) {
    #[cfg(windows)]
    {
        // taskkill /T reaches descendants; /F forces. Mirrors supervisor.ps1's 5.1 path.
        let _ = Command::new("taskkill")
            .args(["/PID", &child.id().to_string(), "/T", "/F"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
    // Direct kill of the immediate child on every platform (also a Windows backstop).
    let _ = child.kill();
    // Bounded wait so we do not hang if the OS is slow to reap.
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        match child.try_wait() {
            Ok(Some(_)) => break,
            _ => thread::sleep(Duration::from_millis(20)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reason_exit_codes_match_supervisor_ps1() {
        assert_eq!(Reason::Ok.exit_code(), 0);
        assert_eq!(Reason::Timeout.exit_code(), 3);
        assert_eq!(Reason::Cancelled.exit_code(), 4);
        assert_eq!(Reason::Crash.exit_code(), 5);
        assert_eq!(Reason::Error.exit_code(), 6);
        assert!(Reason::Timeout.is_transient());
        assert!(Reason::Crash.is_transient());
        assert!(!Reason::Error.is_transient());
        assert!(!Reason::Ok.is_transient());
    }

    #[test]
    fn spawn_failure_is_a_crash() {
        let spec = SpawnSpec::new("this-binary-does-not-exist-xyzzy", vec!["--nope".into()]);
        let v = run(&spec);
        assert_eq!(v.reason, Reason::Crash);
        assert!(v.outcome_reason.starts_with("spawn failed"));
    }
}
