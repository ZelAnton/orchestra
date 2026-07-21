//! Small shared, read-only parse helpers for the `state` sources (line fields, id tokens).

use std::collections::BTreeSet;
use std::fs;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use super::snapshot::Snapshot;

/// Current wall clock as seconds since the Unix epoch (0 if the clock is before the epoch).
pub fn now_epoch_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// The set of completed task ids for readiness: every `### [T-NNN]` record header in
/// `Tasks_Done.md` — i.e. a task counts as a satisfied prerequisite only once it is published
/// AND archived. This mirrors `queue_contract.md` §12 / `tools/queue-tx.ps1 ready`'s
/// `Get-DoneIds` exactly: a `published`-but-not-yet-archived descriptor (`Статус: опубликована`)
/// does NOT satisfy a dependent's prerequisite here, closing the readiness-criterion mismatch
/// between the two resolvers in the "published, not yet archived" window (T-273). `snap` is kept
/// as a parameter for call-site/API stability even though this function no longer reads
/// descriptor state.
pub fn completed_ids(work: &Path, _snap: &Snapshot) -> BTreeSet<String> {
    let mut set = BTreeSet::new();
    if let Ok(text) = fs::read_to_string(work.join("Tasks_Done.md")) {
        set.extend(
            text.lines()
                .filter_map(archive_header_task_id)
                .map(str::to_owned),
        );
    }
    set
}

pub fn archive_header_task_id(line: &str) -> Option<&str> {
    let rest = line.trim_start().strip_prefix("###")?.trim_start();
    let rest = rest.strip_prefix('[')?;
    let close = rest.find(']')?;
    let id = rest[..close].trim();
    let digits = id.strip_prefix("T-")?;
    (!digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit())).then_some(id)
}

/// The value of the first line whose trimmed form starts with `key` (e.g. `"Статус:"`), i.e.
/// the trimmed text after the key. `None` if no such line exists. Used for the single-value
/// Markdown fields (`Статус:`, `Приём:`, `База:`, …).
pub(crate) fn line_field<'a>(text: &'a str, key: &str) -> Option<&'a str> {
    text.lines()
        .map(str::trim)
        .find_map(|l| l.strip_prefix(key).map(str::trim))
}

/// Parse a comma-separated `Предпосылки:` value into T-ids, dropping empties and any token that
/// is not a T-id (`нет`, dashes, stray words).
pub(crate) fn parse_task_id_list(value: &str) -> Vec<String> {
    value
        .split(',')
        .map(str::trim)
        .filter(|t| is_task_id(t))
        .map(String::from)
        .collect()
}

/// `^T-\d` — a T-id is `T-` followed by at least one digit (mirrors `events::parse`).
pub(crate) fn is_task_id(s: &str) -> bool {
    s.strip_prefix("T-")
        .and_then(|r| r.chars().next())
        .is_some_and(|c| c.is_ascii_digit())
}

/// `^B-\d` — a batch id is `B-` followed by at least one digit (a `B-<UTC-stamp>`).
fn is_batch_id(s: &str) -> bool {
    s.strip_prefix("B-")
        .and_then(|r| r.chars().next())
        .is_some_and(|c| c.is_ascii_digit())
}

/// The first whitespace-delimited `B-<stamp>` token anywhere in `text` (the batch id lives in
/// the leading `# … Batch B-…` / `# Batch B-…` heading of `cohort_state.md` / `batch.md`).
pub(crate) fn find_batch_id(text: &str) -> Option<String> {
    text.split_whitespace()
        .find(|t| is_batch_id(t))
        .map(String::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn completed_ids_ignore_task_mentions_in_archive_body() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock after epoch")
            .as_nanos();
        let work = std::env::temp_dir().join(format!(
            "orchestra-completed-ids-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir_all(&work).expect("create test work directory");
        fs::write(
            work.join("Tasks_Done.md"),
            "### [T-100] Archived task — статус: готово\n\nPrerequisites: T-101\nCross-reference: [T-102]\n",
        )
        .expect("write archive fixture");

        let snapshot = Snapshot::load(&work);
        let completed = completed_ids(&work, &snapshot);
        fs::remove_dir_all(&work).expect("remove test work directory");

        assert!(completed.contains("T-100"));
        assert!(!completed.contains("T-101"));
        assert!(!completed.contains("T-102"));
    }

    /// T-273: a descriptor that is `Статус: опубликована` (ff-merged into main but not yet
    /// archived into `Tasks_Done.md`) must NOT count as a completed prerequisite here — this is
    /// the exact strict `queue_contract.md` §12 / `tools/queue-tx.ps1 ready` (`Get-DoneIds`)
    /// criterion, and the two resolvers must agree in this window.
    #[test]
    fn completed_ids_excludes_published_but_not_yet_archived_descriptor() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock after epoch")
            .as_nanos();
        let work = std::env::temp_dir().join(format!(
            "orchestra-completed-ids-published-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir_all(work.join("tasks/T-200")).expect("create test work directory");
        fs::write(
            work.join("tasks/T-200/task.md"),
            "# Активная задача T-200\n\nСтатус: опубликована\n",
        )
        .expect("write published descriptor fixture");

        let snapshot = Snapshot::load(&work);
        let completed = completed_ids(&work, &snapshot);
        fs::remove_dir_all(&work).expect("remove test work directory");

        assert!(
            !completed.contains("T-200"),
            "a published-but-not-archived descriptor must not satisfy a dependent's prerequisite"
        );
    }

    #[test]
    fn line_field_returns_first_trimmed_match() {
        let text = "# Title\nСтатус: в работе\nПредпосылки: T-101\n";
        assert_eq!(line_field(text, "Статус:"), Some("в работе"));
        assert_eq!(line_field(text, "Предпосылки:"), Some("T-101"));
        assert_eq!(line_field(text, "Отсутствует:"), None);
    }

    #[test]
    fn task_id_list_keeps_only_t_ids() {
        assert_eq!(parse_task_id_list("T-101"), vec!["T-101"]);
        assert_eq!(parse_task_id_list("T-102, T-103"), vec!["T-102", "T-103"]);
        assert!(parse_task_id_list("нет").is_empty());
        assert_eq!(parse_task_id_list("T-1, —, foo"), vec!["T-1"]);
    }

    #[test]
    fn batch_id_found_in_heading() {
        assert_eq!(
            find_batch_id("# Cohort state — Batch B-20260711T113948Z\nПриём: открыт"),
            Some("B-20260711T113948Z".to_string())
        );
        // The integration branch token `integration/B-…` must not be mistaken for the id.
        assert_eq!(find_batch_id("Интеграционная ветка: integration/B-1"), None);
        assert_eq!(find_batch_id("# Когорта\nПриём: закрыт"), None);
    }
}
