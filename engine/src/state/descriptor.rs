//! Parse a task descriptor `.work/tasks/<T-ID>/task.md` — its `Статус:` field (§13.1),
//! `Предпосылки:` list, and planner-provided `Конфликт-домен:` globs — and enumerate all
//! descriptors under `.work/tasks/`.
//!
//! The descriptor is the processor-owned per-task lifecycle record; its `Статус:` is the
//! authoritative task state once a task is captured (`не начата` lives only in the queue, before
//! a descriptor exists — §13.1). Read-only: files are opened for reading only.

use std::fs;
use std::path::Path;

use super::canonical::TaskState;
use super::util::{line_field, parse_task_id_list};

/// One decoded `task.md` descriptor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Descriptor {
    /// The T-ID (the descriptor directory name).
    pub id: String,
    /// Canonical state from `Статус:`, or `None` if absent/unrecognized.
    pub state: Option<TaskState>,
    /// The raw `Статус:` literal, when present.
    pub status_literal: Option<String>,
    /// T-ids from the descriptor's `Предпосылки:` line.
    pub prerequisites: Vec<String>,
    /// Path globs from `Конфликт-домен:`. `None` means the field was absent or malformed, so a
    /// caller admitting work must conservatively treat this task as conflicting with everything.
    pub conflict_domain: Option<Vec<String>>,
}

/// Decode one planner-provided conflict-domain into individual relative glob/path patterns.
/// A descriptor with an absent, empty, or non-path-shaped field stays unknown so admission fails
/// closed rather than packing it as conflict-free.
fn parse_conflict_domain(value: &str) -> Option<Vec<String>> {
    let globs: Vec<String> = value
        .split([',', ' ', '\t'])
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect();

    (!globs.is_empty()
        && globs.iter().all(|glob| {
            !glob.starts_with(['/', '\\'])
                && !glob.contains(':')
                && !glob.contains(['<', '>'])
                && !glob.split(['/', '\\']).any(|part| part == "..")
        }))
    .then_some(globs)
}

/// The persistent review-cycle counter `Циклов-ревью: N` a task's descriptor carries once it
/// enters the review fix cycle (`agents/processor.md` phases 2.5 / 2.8; `REVIEW_LOOP_MAX`). It is
/// the inverse of the writer the engine's review round emits, and — like the queue `попытка=N` and
/// the cohort wave — is the durable coordinate `docs/queue_contract.md` §19 reconstructs the
/// per-cycle `task.status_changed` event fingerprint from. Absent / non-numeric reads as `None`
/// (a task that has not yet been reviewed carries no counter), never an error.
pub fn parse_review_cycles(text: &str) -> Option<u32> {
    line_field(text, "Циклов-ревью:")?
        .split_whitespace()
        .next()?
        .parse()
        .ok()
}

/// Decode one descriptor's Markdown text under the given `id`.
pub fn parse_descriptor(id: &str, text: &str) -> Descriptor {
    let status_literal = line_field(text, "Статус:").map(str::to_string);
    let state = status_literal.as_deref().and_then(TaskState::from_markdown);
    let prerequisites = line_field(text, "Предпосылки:")
        .map(parse_task_id_list)
        .unwrap_or_default();
    let conflict_domain = line_field(text, "Конфликт-домен:").and_then(parse_conflict_domain);
    Descriptor {
        id: id.to_string(),
        state,
        status_literal,
        prerequisites,
        conflict_domain,
    }
}

/// Enumerate every `<work_dir>/tasks/<id>/task.md`, in id order. Directories without a `task.md`
/// (e.g. `_integration`, which carries only `status.md`) are skipped. A missing `tasks/`
/// directory reads as an empty list — never an error.
pub fn load_descriptors(work_dir: &Path) -> Vec<Descriptor> {
    let tasks_dir = work_dir.join("tasks");
    let mut dirs: Vec<_> = match fs::read_dir(&tasks_dir) {
        Ok(rd) => rd
            .flatten()
            .filter(|e| e.path().is_dir())
            .map(|e| e.file_name())
            .collect(),
        Err(_) => return Vec::new(),
    };
    dirs.sort();

    let mut out = Vec::new();
    for name in dirs {
        let id = name.to_string_lossy().to_string();
        let task_md = tasks_dir.join(&name).join("task.md");
        if let Ok(text) = fs::read_to_string(&task_md) {
            out.push(parse_descriptor(&id, &text));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const DESC: &str = "# Активная задача T-103\n\n\
Статус: в работе\n\
Исходная задача: [T-103] Дать движку read-only снимок control-plane\n\
Батч: B-20260711T113948Z\n\
Предпосылки: T-101\n\n\
## Критерии выполнения\n- ...\n";

    #[test]
    fn reads_status_and_prerequisites() {
        let d = parse_descriptor("T-103", DESC);
        assert_eq!(d.id, "T-103");
        assert_eq!(d.state, Some(TaskState::Working));
        assert_eq!(d.status_literal.as_deref(), Some("в работе"));
        assert_eq!(d.prerequisites, vec!["T-101"]);
    }

    #[test]
    fn every_lifecycle_literal_is_recognized() {
        for (lit, st) in [
            ("на ревью", TaskState::InReview),
            ("готова к слиянию", TaskState::Ready),
            ("слита", TaskState::Merged),
            ("опубликована", TaskState::Published),
            ("выполнена", TaskState::Done),
            ("конфликт", TaskState::Conflict),
        ] {
            let text = format!("# T\nСтатус: {lit}\n");
            assert_eq!(parse_descriptor("T-1", &text).state, Some(st));
        }
    }

    #[test]
    fn missing_status_is_none_not_error() {
        let d = parse_descriptor("T-9", "# T-9\nБатч: B-1\n");
        assert_eq!(d.state, None);
        assert_eq!(d.status_literal, None);
        assert!(d.prerequisites.is_empty());
    }

    #[test]
    fn review_cycles_counter_parses_and_is_optional() {
        // Present + numeric: the review round wrote `Циклов-ревью: N`.
        let text = "# T-1\nСтатус: на ревью\nЦиклов-ревью: 3\n";
        assert_eq!(parse_review_cycles(text), Some(3));
        // A trailing inline note after the number is tolerated (first token wins).
        let noted = "# T-1\nСтатус: на ревью\nЦиклов-ревью: 2 (fix cycle)\n";
        assert_eq!(parse_review_cycles(noted), Some(2));
        // Absent (a not-yet-reviewed task) or non-numeric reads as None, never an error.
        assert_eq!(parse_review_cycles("# T-1\nСтатус: в работе\n"), None);
        assert_eq!(parse_review_cycles("# T-1\nЦиклов-ревью: many\n"), None);
        // Adding the counter does not disturb the existing descriptor fields.
        let d = parse_descriptor("T-1", text);
        assert_eq!(d.state, Some(TaskState::InReview));
        assert_eq!(d.status_literal.as_deref(), Some("на ревью"));
    }

    #[test]
    fn load_descriptors_missing_tasks_dir_is_empty() {
        let dir = std::env::temp_dir().join("orchestra-state-no-such-work-xyz");
        assert!(load_descriptors(&dir).is_empty());
    }
}
