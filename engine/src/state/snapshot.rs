//! The aggregated, read-only control-plane [`Snapshot`]: queue + descriptors + cohort +
//! integration + batch, loaded from a `.work/` directory per contract §13.
//!
//! Loading is **total**: every missing artifact degrades to empty / `none` (no active
//! cohort/integration/batch) rather than an error — an idle repository is a valid state. Nothing
//! here writes, locks, or emits: the snapshot only observes. Presentation is a compact JSON line
//! (`--json`, hand-built like `events::Event::to_json_line`) or a human-readable summary.

use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{json, Value};

use super::batch::{load_batch, BatchState, BatchTask};
use super::cohort::{load_cohort, CohortState};
use super::descriptor::{load_descriptors, Descriptor};
use super::integration::{load_integration, IntegrationSnapshot};
use super::queue::{parse_queue, QueueEntry};

/// A single deterministic snapshot of the control plane, sourced from one `.work/` directory.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    pub work_dir: PathBuf,
    pub queue: Vec<QueueEntry>,
    pub descriptors: Vec<Descriptor>,
    pub cohort: Option<CohortState>,
    pub integration: IntegrationSnapshot,
    pub batch: Option<BatchState>,
}

impl Snapshot {
    /// Load a read-only snapshot from a `.work/` directory. Missing files degrade to empty /
    /// `none`; this never returns an error.
    pub fn load(work_dir: impl AsRef<Path>) -> Snapshot {
        let work = work_dir.as_ref();
        let queue = fs::read_to_string(work.join("Tasks_Queue.md"))
            .map(|t| parse_queue(&t))
            .unwrap_or_default();
        Snapshot {
            work_dir: work.to_path_buf(),
            queue,
            descriptors: load_descriptors(work),
            cohort: load_cohort(work),
            integration: load_integration(work),
            batch: load_batch(work),
        }
    }

    /// Render the snapshot as one compact JSON object (stable field order, canonical ASCII
    /// state names, `null` for absent cohort/batch and optional fields).
    pub fn to_json(&self) -> String {
        json!({
            "work_dir": self.work_dir.display().to_string(),
            "queue": self.queue.iter().map(queue_entry_json).collect::<Vec<_>>(),
            "descriptors": self.descriptors.iter().map(descriptor_json).collect::<Vec<_>>(),
            "cohort": self.cohort.as_ref().map(cohort_json),
            "integration": integration_json(&self.integration),
            "batch": self.batch.as_ref().map(batch_json),
        })
        .to_string()
    }

    /// Render a human-readable multi-line summary (ends with a newline).
    pub fn to_human(&self) -> String {
        let mut s = String::new();
        let _ = writeln!(
            s,
            "Control-plane snapshot (WORK={})",
            self.work_dir.display()
        );
        let _ = writeln!(s);

        match &self.cohort {
            Some(c) => {
                let adm = c.admission.map(|a| a.as_str()).unwrap_or("?");
                let _ = write!(
                    s,
                    "Cohort: {} · admission={}",
                    c.batch_id.as_deref().unwrap_or("(no batch id)"),
                    adm
                );
                if let Some(r) = &c.admission_reason {
                    let _ = write!(s, " (reason={r})");
                }
                if let Some(w) = c.wave {
                    let _ = write!(s, " · wave={w}");
                }
                if let Some(a) = c.admitted_total {
                    let _ = write!(s, " · admitted={a}");
                }
                let _ = writeln!(s);
            }
            None => {
                let _ = writeln!(s, "Cohort: none (no active cohort)");
            }
        }

        let i = &self.integration;
        let _ = write!(s, "Integration: {}", i.state.as_str());
        if let Some(f) = i.f_cycles {
            let _ = write!(s, " · F-cycles={f}");
        }
        if let Some(sha) = &i.review_sha {
            let _ = write!(s, " · review-sha={sha}");
        }
        let _ = writeln!(s);

        match &self.batch {
            Some(b) => {
                let _ = writeln!(
                    s,
                    "Batch: {} · base={} · integration-branch={}",
                    b.batch_id.as_deref().unwrap_or("?"),
                    b.base.as_deref().unwrap_or("?"),
                    b.integration_branch.as_deref().unwrap_or("?"),
                );
                for t in &b.tasks {
                    let _ = writeln!(
                        s,
                        "  {} · level={} · wave={} · domain={}",
                        t.id,
                        t.level.as_deref().unwrap_or("?"),
                        t.wave.map(|w| w.to_string()).unwrap_or_else(|| "?".into()),
                        t.domain.as_deref().unwrap_or("?"),
                    );
                }
            }
            None => {
                let _ = writeln!(s, "Batch: none");
            }
        }
        let _ = writeln!(s);

        let _ = writeln!(s, "Queue ({} entries):", self.queue.len());
        for e in &self.queue {
            let st = e.state.map(|x| x.as_str()).unwrap_or("?");
            let _ = write!(s, "  {:<7} {:<12} {}", e.id, st, e.title);
            if let Some(a) = e.attempt {
                let _ = write!(s, " · attempt={a}");
            }
            if let Some(q) = &e.quarantine {
                let _ = write!(s, " · quarantine={q}");
            }
            if let Some(r) = &e.escalation_reason {
                let _ = write!(s, " · reason={r}");
            }
            if !e.prerequisites.is_empty() {
                let _ = write!(s, " · prereqs=[{}]", e.prerequisites.join(", "));
            }
            let _ = writeln!(s);
        }
        let _ = writeln!(s);

        let _ = writeln!(s, "Descriptors ({}):", self.descriptors.len());
        for d in &self.descriptors {
            let st = d.state.map(|x| x.as_str()).unwrap_or("?");
            let _ = write!(s, "  {:<7} {}", d.id, st);
            if !d.prerequisites.is_empty() {
                let _ = write!(s, " · prereqs=[{}]", d.prerequisites.join(", "));
            }
            let _ = writeln!(s);
        }
        s
    }
}

fn queue_entry_json(e: &QueueEntry) -> Value {
    json!({
        "id": e.id,
        "title": e.title,
        "state": e.state.map(|s| s.as_str()),
        "status_literal": e.status_literal,
        "attempt": e.attempt,
        "quarantine": e.quarantine,
        "escalation_reason": e.escalation_reason,
        "prerequisites": e.prerequisites,
    })
}

fn descriptor_json(d: &Descriptor) -> Value {
    json!({
        "id": d.id,
        "state": d.state.map(|s| s.as_str()),
        "status_literal": d.status_literal,
        "prerequisites": d.prerequisites,
    })
}

fn cohort_json(c: &CohortState) -> Value {
    json!({
        "batch_id": c.batch_id,
        "admission": c.admission.map(|a| a.as_str()),
        "admission_literal": c.admission_literal,
        "admission_reason": c.admission_reason,
        "started_at": c.started_at,
        "wave": c.wave,
        "admitted_total": c.admitted_total,
    })
}

fn integration_json(i: &IntegrationSnapshot) -> Value {
    json!({
        "state": i.state.as_str(),
        "review_sha": i.review_sha,
        "f_cycles": i.f_cycles,
    })
}

fn batch_json(b: &BatchState) -> Value {
    json!({
        "batch_id": b.batch_id,
        "base": b.base,
        "integration_branch": b.integration_branch,
        "tasks": b.tasks.iter().map(batch_task_json).collect::<Vec<_>>(),
    })
}

fn batch_task_json(t: &BatchTask) -> Value {
    json!({
        "id": t.id,
        "level": t.level,
        "branch": t.branch,
        "worktree": t.worktree,
        "domain": t.domain,
        "wave": t.wave,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static COUNTER: AtomicU64 = AtomicU64::new(0);

    /// A throwaway `.work/`-shaped directory populated by the caller.
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
                "orchestra-state-snap-{}-{nanos}-{n}",
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

    #[test]
    fn empty_work_dir_is_idle_and_json_valid() {
        let w = TmpWork::new();
        let snap = Snapshot::load(&w.dir);
        assert!(snap.queue.is_empty());
        assert!(snap.descriptors.is_empty());
        assert!(snap.cohort.is_none());
        assert!(snap.batch.is_none());
        assert_eq!(snap.integration.state.as_str(), "none");
        // The JSON must be well-formed and reflect the idle state.
        let v: Value = serde_json::from_str(&snap.to_json()).expect("valid JSON");
        assert!(v["cohort"].is_null());
        assert!(v["batch"].is_null());
        assert_eq!(v["integration"]["state"], "none");
    }

    #[test]
    fn full_work_dir_aggregates_all_sources() {
        let w = TmpWork::new();
        w.write(
            "Tasks_Queue.md",
            "### [T-102] TUI экран — статус: в работе · батч=B-1\nПредпосылки: T-101\n",
        );
        w.write("tasks/T-102/task.md", "# T-102\nСтатус: на ревью\n");
        w.write(
            "cohort_state.md",
            "# Cohort state — Batch B-1\nПриём: открыт\nВолна: 1\nAdmitted всего: 1\n",
        );
        w.write("integration_state.md", "# int\nF-циклов: 1\n");
        w.write(
            "batch.md",
            "# Batch B-1\nБаза: abc123\n## Задачи\n- [T-102] уровень=coder ветка=task/T-102 домен=tui/** волна=1\n",
        );

        let snap = Snapshot::load(&w.dir);
        assert_eq!(snap.queue.len(), 1);
        assert_eq!(snap.descriptors.len(), 1);
        assert_eq!(
            snap.descriptors[0].state.map(|s| s.as_str()),
            Some("in-review")
        );
        assert_eq!(
            snap.cohort.as_ref().unwrap().admission.map(|a| a.as_str()),
            Some("open")
        );
        assert_eq!(snap.integration.state.as_str(), "in-progress");
        assert_eq!(snap.batch.as_ref().unwrap().tasks.len(), 1);

        let v: Value = serde_json::from_str(&snap.to_json()).expect("valid JSON");
        assert_eq!(v["queue"][0]["state"], "working");
        assert_eq!(v["descriptors"][0]["state"], "in-review");
        assert_eq!(v["cohort"]["admission"], "open");
        assert_eq!(v["integration"]["state"], "in-progress");
        assert_eq!(v["batch"]["tasks"][0]["level"], "coder");

        // Human render mentions the key facts.
        let human = snap.to_human();
        assert!(human.contains("Integration: in-progress"));
        assert!(human.contains("admission=open"));
        assert!(human.contains("T-102"));
    }
}
