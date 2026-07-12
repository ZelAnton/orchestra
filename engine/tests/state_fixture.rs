//! Hermetic, offline proof of the `engine state` subcommand end to end: build a temporary
//! `.work/`-shaped directory from Markdown fixtures (shapes copied from the real control-plane
//! artifacts), drive the REAL built binary against it, and assert the snapshot it prints reflects
//! each source and maps the Cyrillic status literals to canonical ASCII names (contract §13). No
//! network, no live `.work/`: everything is a temp directory. Also covers the idle case where the
//! cohort/integration/batch artifacts are absent — the snapshot must report "no active
//! cohort/integration", not fail.

use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

const BIN: &str = env!("CARGO_BIN_EXE_orchestra-engine");

static COUNTER: AtomicU64 = AtomicU64::new(0);

struct TmpWork {
    dir: PathBuf,
}

impl TmpWork {
    fn new() -> TmpWork {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "orchestra-state-fixture-{}-{nanos}-{n}",
            std::process::id()
        ));
        fs::create_dir_all(&dir).unwrap();
        TmpWork { dir }
    }
    fn write(&self, rel: &str, contents: &str) {
        let path = self.dir.join(rel);
        if let Some(p) = path.parent() {
            fs::create_dir_all(p).unwrap();
        }
        fs::write(path, contents).unwrap();
    }
}
impl Drop for TmpWork {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn run_state(work: &PathBuf, extra: &[&str]) -> std::process::Output {
    let mut cmd = Command::new(BIN);
    cmd.arg("state");
    for a in extra {
        cmd.arg(a);
    }
    cmd.arg(work);
    cmd.output().expect("spawn engine state")
}

#[test]
fn state_json_reflects_every_source_and_canonical_names() {
    let w = TmpWork::new();
    // Queue: a captured task and a re-queued (quarantined) one — statuses in Cyrillic.
    w.write(
        "Tasks_Queue.md",
        "### [T-102] TUI экран — статус: в работе · батч=B-1 · worktree=.work/worktrees/T-102\n\
Предпосылки: T-101\n\n\
### [T-104] Decision Inbox — статус: не начата · попытка=2 · карантин=merge-conflict\n\
Предпосылки: T-102, T-103\n",
    );
    // Descriptor: authoritative `Статус:` for the captured task.
    w.write(
        "tasks/T-102/task.md",
        "# T-102\nСтатус: на ревью\nПредпосылки: T-101\n",
    );
    // Cohort admission (§13.2).
    w.write(
        "cohort_state.md",
        "# Cohort state — Batch B-1\nНачало когорты: 2026-07-11T11:39:48Z\nПриём: открыт\nВолна: 1\nAdmitted всего: 2\n",
    );
    // Integration join state (§13.3): file present -> in-progress.
    w.write(
        "integration_state.md",
        "# int\nРевью-SHA: abc123\nF-циклов: 1\n",
    );
    // Batch manifest.
    w.write(
        "batch.md",
        "# Batch B-1\nБаза: deadbeef\nИнтеграционная ветка: integration/B-1\n## Задачи\n- [T-102] уровень=coder_deep ветка=task/T-102 домен=tui/** волна=1\n",
    );

    let out = run_state(&w.dir, &["--json"]);
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success(),
        "state --json exited nonzero: {stdout} / {}",
        String::from_utf8_lossy(&out.stderr)
    );

    let v: serde_json::Value = serde_json::from_str(stdout.trim()).expect("valid JSON line");

    // Queue: Cyrillic literals mapped to canonical names; suffixes captured.
    assert_eq!(v["queue"][0]["id"], "T-102");
    assert_eq!(v["queue"][0]["state"], "working");
    assert_eq!(v["queue"][1]["state"], "not-started");
    assert_eq!(v["queue"][1]["attempt"], 2);
    assert_eq!(v["queue"][1]["quarantine"], "merge-conflict");
    assert_eq!(v["queue"][1]["prerequisites"][1], "T-103");

    // Descriptor: `Статус: на ревью` -> in-review.
    assert_eq!(v["descriptors"][0]["id"], "T-102");
    assert_eq!(v["descriptors"][0]["state"], "in-review");

    // Cohort / integration / batch.
    assert_eq!(v["cohort"]["batch_id"], "B-1");
    assert_eq!(v["cohort"]["admission"], "open");
    assert_eq!(v["cohort"]["admitted_total"], 2);
    assert_eq!(v["integration"]["state"], "in-progress");
    assert_eq!(v["integration"]["f_cycles"], 1);
    assert_eq!(v["batch"]["integration_branch"], "integration/B-1");
    assert_eq!(v["batch"]["tasks"][0]["level"], "coder_deep");
}

#[test]
fn state_idle_when_cohort_integration_batch_absent() {
    let w = TmpWork::new();
    // Only a queue — no cohort/integration/batch artifacts (the normal idle state).
    w.write(
        "Tasks_Queue.md",
        "### [T-200] Задача — статус: не начата\nОписание.\n",
    );

    let out = run_state(&w.dir, &["--json"]);
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(out.status.success(), "idle snapshot must exit 0: {stdout}");
    let v: serde_json::Value = serde_json::from_str(stdout.trim()).expect("valid JSON line");
    assert!(v["cohort"].is_null(), "no active cohort");
    assert!(v["batch"].is_null(), "no active batch");
    assert_eq!(v["integration"]["state"], "none", "no active integration");
    assert_eq!(v["queue"][0]["state"], "not-started");
}

#[test]
fn state_human_readable_default() {
    let w = TmpWork::new();
    w.write(
        "cohort_state.md",
        "# Когорта\nПриём: закрыт · причина=COHORT_SIZE\nВолна: 2\n",
    );
    let out = run_state(&w.dir, &[]);
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(out.status.success());
    assert!(stdout.contains("Control-plane snapshot"));
    assert!(stdout.contains("admission=closed"));
    assert!(stdout.contains("Integration: none"));
}

#[test]
fn state_missing_work_dir_errors() {
    let missing = std::env::temp_dir().join("orchestra-state-absent-work-xyz-404");
    let out = Command::new(BIN)
        .arg("state")
        .arg(&missing)
        .output()
        .expect("spawn engine state");
    assert!(
        !out.status.success(),
        "missing work dir should exit nonzero"
    );
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("work directory not found"),
        "stderr should explain the missing work dir"
    );
}
