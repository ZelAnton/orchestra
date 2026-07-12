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
//! TREE TERMINATION (no-orphan guarantee). On timeout / cooperative cancel we tear down the
//! child's WHOLE process tree, never just the direct child:
//!   * Windows — `taskkill /PID <pid> /T /F` reaches every descendant (mirrors
//!     `supervisor.ps1`'s 5.1 path).
//!   * Unix (Linux / macOS) — the child is spawned as the leader of its OWN process group
//!     (`Command::process_group(0)`, so its PGID equals its PID and every descendant inherits
//!     that group), and `kill_tree` signals the whole group (`killpg` SIGTERM then SIGKILL). A
//!     bare `child.kill()` would reap only the direct child and orphan its grandchildren — the
//!     exact spike-grade gap this closes. This is the POSIX-process-group form of the guarantee
//!     `supervisor.ps1` gets from `Process.Kill($true)`.
//!
//! The Rust line's async `processkit` crate (kill-on-drop Job Object / cgroup v2 / process
//! group) remains the intended substrate once the engine itself goes async on tokio; it is
//! deliberately NOT pulled in here, because this supervisor is synchronous and dependency-lean
//! while `processkit` is tokio-async and `edition = "2024"` (above this crate's MSRV) — adopting
//! it would mean an async rewrite plus a large runtime for one syscall's worth of teardown.
//! Residual limitation shared with any pure process-group approach: if the engine process is
//! itself hard-killed BEFORE `kill_tree` runs, the group can outlive it — closing that last
//! window needs the Job Object / cgroup GC net that `processkit` (or a future cgroup-v2 path)
//! provides. The deterministic timeout / cancel teardown is fully covered.

use std::io::{Read, Write};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

// Keep PowerShell and console-based tool invocations invisible when the engine is itself
// started without a console. This is the Win32 CREATE_NO_WINDOW creation flag.
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

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

    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;

        cmd.creation_flags(CREATE_NO_WINDOW);
    }

    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;

        // Spawn the child as the leader of a NEW process group (pgroup 0 => group id equals
        // the child PID), so every descendant it later spawns inherits that group and a single
        // `killpg` in `kill_tree` tears the whole tree down — the POSIX no-orphan guarantee.
        // This is paired with `kill_tree`'s `killpg(child.id(), …)`, which relies on PGID==PID.
        cmd.process_group(0);
    }

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
    #[cfg(unix)]
    {
        // The child leads its own process group (`process_group(0)` in `run`), so its PGID
        // equals its PID and every descendant inherits it. Signalling the GROUP reaches the
        // whole tree; a bare `child.kill()` would orphan grandchildren. Graceful SIGTERM first
        // (let a well-behaved child flush and exit), a short grace, then SIGKILL forces any
        // survivor down. `child.id()` is the positive group id — `killpg` must never receive 0
        // (that would hit OUR own group), and a spawned child's PID is always > 1, so it can't.
        let pgid = child.id() as libc::pid_t;
        // SAFETY: `killpg` is a plain libc call with no memory effects; a failure (typically
        // ESRCH once the group is already gone) is expected here and safely ignored.
        unsafe {
            let _ = libc::killpg(pgid, libc::SIGTERM);
        }
        let grace = Instant::now() + Duration::from_millis(200);
        while Instant::now() < grace {
            match child.try_wait() {
                Ok(Some(_)) => break,
                _ => thread::sleep(Duration::from_millis(20)),
            }
        }
        // SAFETY: same as above; SIGKILL cannot be caught or ignored, so this guarantees the
        // whole group is torn down even if a member ignored SIGTERM.
        unsafe {
            let _ = libc::killpg(pgid, libc::SIGKILL);
        }
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

    // The no-orphan guarantee outside Windows: a supervised child that spawns a longer-lived
    // grandchild must, on deadline, have its WHOLE process group torn down. The old spike
    // behaviour (a bare `child.kill()`) killed only the shell and left the grandchild running
    // — under that behaviour the grandchild here would outlive the kill and create its marker
    // file; with the process-group kill it is terminated mid-sleep and the marker never appears.
    #[cfg(unix)]
    #[test]
    fn kill_tree_reaps_grandchildren_no_orphans() {
        // The parent shell backgrounds a "grandchild" subshell that writes MARKER only *after* a
        // 2s sleep, then blocks on `wait`. A 300ms deadline forces the supervisor to time out and
        // tear the whole group down well before that 2s elapses, so a correctly-killed grandchild
        // never reaches the write. We assert on that *side effect* (did later code run?) rather
        // than on PID existence — `kill(pid, 0)` cannot tell a live process from an unreaped
        // zombie, and in some environments (e.g. a container whose PID 1 is not a reaper) a
        // correctly-killed grandchild lingers as a zombie and would fool a bare existence probe.
        let marker =
            std::env::temp_dir().join(format!("orchestra-t130-{}.marker", std::process::id()));
        let _ = std::fs::remove_file(&marker);
        let script = format!("( sleep 2 && : > '{}' ) & wait", marker.display());
        let spec = SpawnSpec::new("/bin/sh", vec!["-c".into(), script])
            .deadline(Some(Duration::from_millis(300)));

        let v = run(&spec);
        assert_eq!(v.reason, Reason::Timeout, "expected the deadline to fire");

        // Wait past the grandchild's 2s sleep: if the tree-kill missed it, it is still running
        // and will have created MARKER by now; if the group was torn down, MARKER never appears.
        thread::sleep(Duration::from_millis(2600));
        let orphan_ran = marker.exists();
        let _ = std::fs::remove_file(&marker);
        assert!(
            !orphan_ran,
            "grandchild kept running after tree-kill — descendant was orphaned"
        );
    }
}
