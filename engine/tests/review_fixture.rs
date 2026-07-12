//! Hermetic, offline end-to-end proof of `engine run --once --review` (task T-127): after the
//! execution round, drive the REAL built binary through the per-task **review round** over a
//! throwaway **sandbox** `.work` and the REAL transaction tools (`queue-tx.ps1` / `state-tx.ps1` /
//! `outbox.ps1`), and assert BOTH review-gate branches wire correctly:
//!
//!   * **clean** (a fresh `SUMMARY-R`, zero open `R-`) → the descriptor is promoted
//!     `на ревью -> готова к слиянию` through a `state-tx check-transition`-validated transition;
//!   * **with-findings** (an open `R-`) → the descriptor STAYS `на ревью` under the (T-128) fix
//!     cycle, through the equally-validated self-transition — a DIFFERENT, legal transition.
//!
//! The review is run by the deterministic `__fake-agent --mode review` reviewer stand-in (never a
//! live model call); the tier + concrete reviewer come from the real tiering/reviewer resolvers,
//! and the branch from the real `contract`/`gate`. Like `run_fixture`, the PowerShell-driven tools
//! need a `pwsh`/`powershell` host; when neither is available the tests self-skip (never fail).
//! Every sandbox lives in a per-test temp directory removed on drop; the run is offline/token-free.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

const BIN: &str = env!("CARGO_BIN_EXE_orchestra-engine");

static COUNTER: AtomicU64 = AtomicU64::new(0);

/// The real `tools/` directory, resolved from this crate's manifest dir (`.../engine`) → repo root.
fn tools_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("engine crate has a parent (repo root)")
        .join("tools")
}

/// The first PowerShell host that can actually launch, or `None` (then the caller self-skips).
fn pwsh_host() -> Option<String> {
    for host in ["pwsh", "powershell"] {
        let ok = Command::new(host)
            .args(["-NoProfile", "-Command", "exit 0"])
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);
        if ok {
            return Some(host.to_string());
        }
    }
    None
}

macro_rules! host_or_skip {
    () => {
        match pwsh_host() {
            Some(h) => h,
            None => {
                eprintln!(
                    "SKIP: no PowerShell host (pwsh/powershell) available for the .ps1 tools"
                );
                return;
            }
        }
    };
}

/// A throwaway sandbox `.work` directory, removed on drop.
struct Sandbox {
    work: PathBuf,
}

impl Sandbox {
    fn new() -> Sandbox {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        let work = std::env::temp_dir().join(format!(
            "orchestra-review-fixture-{}-{nanos}-{n}",
            std::process::id()
        ));
        fs::create_dir_all(&work).unwrap();
        Sandbox { work }
    }
    fn read(&self, rel: &str) -> String {
        fs::read_to_string(self.work.join(rel)).unwrap_or_default()
    }
    fn descriptor_status(&self, id: &str) -> String {
        let md = self.read(&format!("tasks/{id}/task.md"));
        for line in md.lines() {
            if let Some(rest) = line.trim().strip_prefix("Статус:") {
                return rest.trim().to_string();
            }
        }
        String::new()
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.work);
    }
}

/// Seed one not-started task into the sandbox queue through the REAL `queue-tx.ps1 propose`.
fn queue_propose(host: &str, work: &Path, id: &str, title: &str) -> Output {
    let script = tools_dir().join("queue-tx.ps1");
    let mut cmd = Command::new(host);
    cmd.args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"])
        .arg(&script)
        .args(["propose", "--work"])
        .arg(work)
        .args(["--id", id, "--title", title]);
    cmd.output().expect("spawn queue-tx propose")
}

/// Seed the planner-owned descriptor that supplies a task's typed conflict-domain to admission.
fn write_planned_descriptor(work: &Path, id: &str, state: &str, domain: &str) {
    let dir = work.join("tasks").join(id);
    fs::create_dir_all(&dir).expect("create planned descriptor directory");
    let text = format!("# {id}\nСтатус: {state}\nКонфликт-домен: {domain}\n");
    fs::write(dir.join("task.md"), text).expect("write planned descriptor");
}

/// Run `engine run --once` over the sandbox with the real tools.
fn engine_run(work: &Path, extra: &[&str]) -> Output {
    let mut cmd = Command::new(BIN);
    cmd.args(["run", "--once", "--work"])
        .arg(work)
        .arg("--tools")
        .arg(tools_dir())
        .args(["--base", "sandbox-base"]);
    for a in extra {
        cmd.arg(a);
    }
    cmd.output().expect("spawn engine run")
}

fn stdout_of(o: &Output) -> String {
    String::from_utf8_lossy(&o.stdout).into_owned()
}
fn stderr_of(o: &Output) -> String {
    String::from_utf8_lossy(&o.stderr).into_owned()
}

#[test]
fn review_round_wires_clean_and_with_findings_branches() {
    let host = host_or_skip!();
    let sb = Sandbox::new();

    // Two independent (non-overlapping) tasks so both are admitted in one cohort.
    for (id, title) in [("T-501", "clean pass"), ("T-502", "with findings")] {
        let out = queue_propose(&host, &sb.work, id, title);
        assert!(out.status.success(), "propose {id}: {}", stderr_of(&out));
    }
    write_planned_descriptor(&sb.work, "T-501", "не начата", "engine/src/**");
    write_planned_descriptor(&sb.work, "T-502", "не начата", "tui/**");

    // T-502's reviewer stand-in emits an open `R-` (with-findings); T-501's is a clean pass.
    let batch = "B-20260712T140000Z";
    let run = engine_run(
        &sb.work,
        &[
            "--batch",
            batch,
            "--cohort-size",
            "2",
            "--review",
            "--inject-findings",
            "T-502",
            "--json",
        ],
    );
    let out = stdout_of(&run);
    assert!(
        run.status.success(),
        "engine run --review exits 0: {out} / {}",
        stderr_of(&run)
    );

    // Both were admitted and executed to review first (the execution round is unchanged).
    assert!(
        out.contains("\"admitted\":[\"T-501\",\"T-502\"]"),
        "both independent tasks admitted: {out}"
    );

    // The review phase resolved the tier + reviewer through the real resolvers (coder → opus
    // `reviewer`) and named both gate branches.
    assert!(
        out.contains("\"gate\":\"clean\""),
        "the clean branch is exercised: {out}"
    );
    assert!(
        out.contains("\"gate\":\"findings\""),
        "the with-findings branch is exercised: {out}"
    );
    assert!(
        out.contains("\"reviewer\":\"reviewer\""),
        "the tiering/reviewer resolvers elected the opus reviewer: {out}"
    );
    // The clean task's review transitioned it to `ready`; the injected review never escalated.
    assert!(
        out.contains("\"to\":\"ready\""),
        "the clean pass promotes to ready: {out}"
    );
    assert!(
        !out.contains("\"to\":\"escalated\""),
        "a clean/with-findings review escalates nothing: {out}"
    );

    // The DESCRIPTORS are the strongest assertion: clean → готова к слиянию, findings → stays на
    // ревью (the two DIFFERENT, state-tx-validated review transitions this task wires).
    assert_eq!(
        sb.descriptor_status("T-501"),
        "готова к слиянию",
        "the clean pass promotes the descriptor to ready"
    );
    assert_eq!(
        sb.descriptor_status("T-502"),
        "на ревью",
        "the with-findings pass keeps the descriptor in review for the fix cycle"
    );

    // The review phase emitted its events through outbox: the clean promotion carries the
    // ASCII `gate` marker (host-agnostic — Cyrillic payload words are \u-escaped under WinPS).
    let events = sb.read("events.jsonl");
    assert!(
        events.contains("\"gate\":\"clean\""),
        "the review promotion event was emitted through outbox: {events}"
    );

    // The queue was never escalated by the review round (neither task fail-closed).
    let queue = sb.read("Tasks_Queue.md");
    assert!(
        !queue.contains("эскалирована"),
        "no task was escalated by the review round: {queue}"
    );

    // No dangling owner lease.
    assert!(
        !sb.work.join("orchestrator.lock").exists(),
        "the engine released its lease after the review round"
    );
    assert!(
        out.contains("\"lease_released\":true"),
        "the lease is released: {out}"
    );
}

#[test]
fn both_clean_tasks_are_both_promoted() {
    let host = host_or_skip!();
    let sb = Sandbox::new();

    for (id, title) in [("T-511", "clean one"), ("T-512", "clean two")] {
        let out = queue_propose(&host, &sb.work, id, title);
        assert!(out.status.success(), "propose {id}: {}", stderr_of(&out));
    }
    write_planned_descriptor(&sb.work, "T-511", "не начата", "engine/src/**");
    write_planned_descriptor(&sb.work, "T-512", "не начата", "tui/**");

    let run = engine_run(
        &sb.work,
        &[
            "--batch",
            "B-allclean",
            "--cohort-size",
            "2",
            "--review",
            "--json",
        ],
    );
    let out = stdout_of(&run);
    assert!(
        run.status.success(),
        "engine run --review exits 0: {out} / {}",
        stderr_of(&run)
    );
    // Both clean passes promote to ready; neither shows a findings branch.
    assert!(
        !out.contains("\"gate\":\"findings\""),
        "no task should have findings: {out}"
    );
    assert_eq!(sb.descriptor_status("T-511"), "готова к слиянию");
    assert_eq!(sb.descriptor_status("T-512"), "готова к слиянию");
}

#[test]
fn an_escalated_task_is_not_reviewed() {
    let host = host_or_skip!();
    let sb = Sandbox::new();

    for (id, title) in [("T-521", "reviewed"), ("T-522", "escalates in execution")] {
        let out = queue_propose(&host, &sb.work, id, title);
        assert!(out.status.success(), "propose {id}: {}", stderr_of(&out));
    }
    write_planned_descriptor(&sb.work, "T-521", "не начата", "engine/src/**");
    write_planned_descriptor(&sb.work, "T-522", "не начата", "tui/**");

    // T-522 escalates in the EXECUTION round, so the review round must skip it (only `in-review`
    // tasks are reviewed); T-521 is executed then cleanly reviewed to `ready`.
    let run = engine_run(
        &sb.work,
        &[
            "--batch",
            "B-escrev",
            "--cohort-size",
            "2",
            "--review",
            "--inject-escalate",
            "T-522",
            "--json",
        ],
    );
    let out = stdout_of(&run);
    assert!(
        run.status.success(),
        "engine run exits 0: {out} / {}",
        stderr_of(&run)
    );

    // T-521: executed → reviewed clean → ready. T-522: escalated in execution, never reviewed.
    assert_eq!(sb.descriptor_status("T-521"), "готова к слиянию");
    assert_eq!(sb.descriptor_status("T-522"), "эскалирована");
    assert!(
        out.contains("\"gate\":\"clean\""),
        "the surviving task was reviewed clean: {out}"
    );
    // The escalated task carries no review object (review is skipped for a non-`in-review` task).
    assert!(
        out.contains("\"id\":\"T-522\""),
        "the escalated task is still reported: {out}"
    );
}
