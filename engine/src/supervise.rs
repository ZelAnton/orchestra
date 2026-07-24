//! Supervise ONE child process outside Claude Code: enforce a wall-clock deadline,
//! drain stdout/stderr on threads (so a large output cannot deadlock the child), and on
//! timeout / cooperative cancel / watchdog failure terminate the whole child tree, returning a structured,
//! non-sensitive verdict.
//!
//! The reason / exit-code contract is kept byte-compatible with `tools/supervisor.ps1`
//! (the existing PowerShell supervisor) so a future native port stays interchangeable
//! with it:
//!
//!   ok=0  timeout=3  cancelled=4  crash=5  error=6
//!
//! TREE TERMINATION (no-orphan guarantee). On timeout / cooperative cancel / a failed watchdog
//! poll we tear down the child's WHOLE process tree, never just the direct child:
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
//!
//! BOUNDED OUTPUT COLLECTION (no-hang guarantee). stdout / stderr are drained on threads that
//! append to a shared buffer; `read_to_end`-style completion only fires once the LAST write end
//! of the pipe is closed. If a descendant survived `kill_tree` (the same taskkill / setsid gaps
//! noted above) it can keep an inherited copy of that write end open, so EOF — and the drain
//! thread's completion signal — may NEVER arrive. Collection therefore waits for the drain
//! threads only up to a bounded grace (`SpawnSpec::collect_grace`) after teardown; on expiry it
//! takes whatever bytes were captured so far and flags `Verdict::output_collection_timed_out`,
//! so a fired deadline / cancel can never silently degrade into an unbounded block on `recv`.

use std::io::{Read, Write};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

/// Default bound on how long output collection waits for the drain threads to reach EOF after
/// the child (and, on teardown, its tree) has been reaped. In the normal case EOF is already
/// present and this is never approached; it only caps the pathological "a survivor still holds
/// the pipe" case so supervision cannot block forever.
const DEFAULT_COLLECT_GRACE: Duration = Duration::from_secs(5);

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
    /// True when the bounded post-teardown collection grace expired before stdout / stderr
    /// reached EOF (a survivor still held an inherited pipe): `stdout` / `stderr` then carry
    /// only the bytes captured so far. Orthogonal to `reason` — the deadline / cancel / exit
    /// classification is unchanged; this only records that the captured output may be partial.
    pub output_collection_timed_out: bool,
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
    /// Upper bound on how long to wait for stdout / stderr to finish draining after teardown
    /// before degrading to the bytes captured so far (see the module's BOUNDED OUTPUT
    /// COLLECTION note). Defaults to `DEFAULT_COLLECT_GRACE`.
    pub collect_grace: Duration,
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
            collect_grace: DEFAULT_COLLECT_GRACE,
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
    pub fn collect_grace(mut self, d: Duration) -> Self {
        self.collect_grace = d;
        self
    }
}

fn configured_command(spec: &SpawnSpec) -> Command {
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

    cmd
}

/// Run one child under supervision and classify the outcome.
pub fn run(spec: &SpawnSpec) -> Verdict {
    let started = Instant::now();
    let mut cmd = configured_command(spec);

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
                output_collection_timed_out: false,
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
    let out = drain(child.stdout.take());
    let err = drain(child.stderr.take());

    // Watchdog loop: poll for exit, deadline, or cancel-file.
    let mut timed_out = false;
    let mut cancelled = false;
    let exit_status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) => {}
            Err(_) => {
                // A failed poll leaves the child's liveness unknown. Tear down the whole tree
                // before leaving the watchdog, but keep timeout/cancel flags false so `classify`
                // reports the distinct infrastructure-crash outcome for the missing status.
                kill_tree(&mut child);
                break None;
            }
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

    // Bounded output collection. Reaping the child closes OUR handle, so in the normal case the
    // drain threads hit EOF and finish immediately; but a descendant that survived `kill_tree`
    // can keep an inherited copy of the pipe's write end open, so EOF never arrives and the
    // drain thread never signals completion. Wait for both drains only up to a shared grace,
    // then take whatever was captured — never an unbounded `recv` that would silently break the
    // deadline / cancel contract. `output_collection_timed_out` records any such shortfall.
    let collect_deadline = Instant::now() + spec.collect_grace;
    let stdout_done = wait_drain(&out.done, collect_deadline);
    let stderr_done = wait_drain(&err.done, collect_deadline);
    let output_collection_timed_out = !stdout_done || !stderr_done;
    let stdout = snapshot(&out.buf);
    let stderr = snapshot(&err.buf);
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
        output_collection_timed_out,
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

/// A pipe being drained on a background thread: `buf` accumulates bytes as they are read (so a
/// partial capture is always readable), and `done` fires once the thread reaches EOF or a read
/// error. A survivor holding the write end open can leave `done` silent indefinitely — the
/// caller therefore waits on it only up to a bounded grace (see [`wait_drain`]).
struct Drain {
    buf: Arc<Mutex<Vec<u8>>>,
    done: mpsc::Receiver<()>,
}

/// Drain a pipe on a thread, appending to a shared buffer chunk-by-chunk (not one final
/// `read_to_end`) so whatever was produced before any wedge stays retrievable. `done` is
/// signalled on EOF or a read error; if `handle` is absent it fires at once with an empty buffer.
fn drain(handle: Option<impl Read + Send + 'static>) -> Drain {
    let buf = Arc::new(Mutex::new(Vec::new()));
    let (tx, done) = mpsc::channel();
    match handle {
        Some(mut h) => {
            let sink = Arc::clone(&buf);
            thread::spawn(move || {
                let mut chunk = [0u8; 8192];
                loop {
                    match h.read(&mut chunk) {
                        Ok(0) => break, // EOF: the last write end closed.
                        Ok(n) => append(&sink, &chunk[..n]),
                        Err(ref e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                        Err(_) => break,
                    }
                }
                let _ = tx.send(());
            });
        }
        None => {
            let _ = tx.send(());
        }
    }
    Drain { buf, done }
}

/// Append bytes to a drain buffer, recovering a poisoned lock so a reader-thread panic can never
/// lose bytes already captured (nor propagate the panic into the supervisor).
fn append(buf: &Arc<Mutex<Vec<u8>>>, bytes: &[u8]) {
    let mut guard = match buf.lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    };
    guard.extend_from_slice(bytes);
}

/// Snapshot whatever a drain buffer currently holds as lossy UTF-8 (poison-tolerant).
fn snapshot(buf: &Arc<Mutex<Vec<u8>>>) -> String {
    let guard = match buf.lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    };
    String::from_utf8_lossy(&guard).into_owned()
}

/// Wait for a drain thread to finish, but never past `deadline`. Returns true if it signalled
/// completion (EOF / read error) in time, false if the grace expired first — i.e. a survivor is
/// still holding the pipe's write end open and the capture is partial.
fn wait_drain(done: &mpsc::Receiver<()>, deadline: Instant) -> bool {
    let remaining = deadline.saturating_duration_since(Instant::now());
    match done.recv_timeout(remaining) {
        Ok(()) => true,
        // Sender dropped without an explicit signal (a panicked drain thread): it will not run
        // again, so treat collection as finished rather than falsely "still draining".
        Err(mpsc::RecvTimeoutError::Disconnected) => true,
        // A zero/near-zero `remaining` can time out even when a signal is already queued; re-poll
        // once so an already-finished drain is not misreported as partial.
        Err(mpsc::RecvTimeoutError::Timeout) => done.try_recv().is_ok(),
    }
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

    // A real `Child::try_wait` error cannot be induced portably without corrupting or closing
    // the child's private OS handle. Exercise the error branch's two observable contracts with
    // equivalent inputs instead: emergency tree-kill makes reap immediate, while absent
    // timeout/cancel flags keep the unavailable status classified as a crash.
    #[test]
    fn try_wait_error_cleanup_kills_child_without_masking_crash() {
        let test_exe = std::env::current_exe().expect("resolve current test executable");
        let spec = SpawnSpec::new(
            test_exe.to_string_lossy(),
            vec![
                "--ignored".into(),
                "--exact".into(),
                "supervise::tests::emergency_kill_test_child".into(),
            ],
        );
        // Reuse the production command builder so this test spawn gets CREATE_NO_WINDOW on
        // Windows and the dedicated process group required by `kill_tree` on Unix.
        let mut child = configured_command(&spec)
            .spawn()
            .expect("spawn long-lived test child");
        thread::sleep(Duration::from_millis(100));
        assert!(
            matches!(child.try_wait(), Ok(None)),
            "test child must still be running before emergency cleanup"
        );

        kill_tree(&mut child);
        let reap_started = Instant::now();
        child.wait().expect("reap emergency-killed test child");
        assert!(
            reap_started.elapsed() < Duration::from_secs(1),
            "reap blocked after emergency tree-kill"
        );

        let (reason, exit_code, outcome_reason) = classify(None, false, false, &spec);
        assert_eq!(reason, Reason::Crash);
        assert_eq!(exit_code, None);
        assert_eq!(outcome_reason, "exit code unavailable after run");
    }

    #[test]
    #[ignore = "spawned explicitly by try_wait_error_cleanup_kills_child_without_masking_crash"]
    fn emergency_kill_test_child() {
        thread::sleep(Duration::from_secs(30));
    }

    // The no-hang guarantee this task adds: a descendant that survived `kill_tree` and still
    // holds an inherited pipe write end means EOF NEVER arrives, so the drain thread never
    // signals completion. `PartialThenBlock` reproduces exactly that shape portably — it yields
    // the output produced before the wedge, then blocks forever with no further data and no EOF.
    // Bounded collection must still return promptly, keep the partial bytes, and report the drain
    // as unfinished (so `run` can flag `output_collection_timed_out`) — never block on `recv`.
    struct PartialThenBlock {
        sent: bool,
    }
    impl Read for PartialThenBlock {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            if !self.sent {
                self.sent = true;
                let msg = b"partial-before-wedge";
                let n = msg.len().min(buf.len());
                buf[..n].copy_from_slice(&msg[..n]);
                Ok(n)
            } else {
                // The survivor keeps the write end open: no more data, and no EOF, ever.
                loop {
                    thread::park();
                }
            }
        }
    }

    #[test]
    fn bounded_collection_returns_partial_without_blocking_on_a_survivor() {
        let d = drain(Some(PartialThenBlock { sent: false }));
        // Let the drain thread read + append the partial bytes before it wedges.
        thread::sleep(Duration::from_millis(100));
        let started = Instant::now();
        let done = wait_drain(&d.done, Instant::now() + Duration::from_millis(200));
        let elapsed = started.elapsed();
        assert!(
            !done,
            "a wedged survivor pipe must be reported as an unfinished drain (partial capture)"
        );
        assert!(
            elapsed < Duration::from_secs(2),
            "bounded collection blocked instead of degrading (waited {elapsed:?})"
        );
        assert!(
            snapshot(&d.buf).contains("partial-before-wedge"),
            "output captured before the wedge must be retained, not discarded"
        );
    }

    #[test]
    fn bounded_collection_captures_full_output_on_clean_eof() {
        // The normal path must not regress: a finite reader reaches EOF, the drain finishes well
        // within the grace, and the full content is present with no partial-collection shortfall.
        let d = drain(Some(std::io::Cursor::new(b"complete-output".to_vec())));
        let done = wait_drain(&d.done, Instant::now() + Duration::from_secs(5));
        assert!(
            done,
            "a finite reader must finish draining within the grace"
        );
        assert_eq!(snapshot(&d.buf), "complete-output");
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
