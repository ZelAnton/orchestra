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

/// The set of completed task ids for readiness: every archive-header task id in `Tasks_Done.md`
/// per the ONE normative header contract (`archive_header_task_id`) — i.e. a task counts as a
/// satisfied prerequisite only once it is published AND archived. This mirrors
/// `queue_contract.md` §12 / `tools/queue-tx.ps1 ready`'s `Get-DoneIds` (`Get-ArchiveHeaderIds`):
/// the SAME header shapes are accepted here, in that PowerShell resolver, and in
/// `tui/src/main.rs::done_task_ids` (which reuses `archive_header_task_id`), so one archive record
/// answers the readiness question identically for all three consumers (T-293). A
/// `published`-but-not-yet-archived descriptor (`Статус: опубликована`) does NOT satisfy a
/// dependent's prerequisite here, closing the readiness-criterion mismatch between the resolvers
/// in the "published, not yet archived" window (T-273). `snap` is kept as a parameter for
/// call-site/API stability even though this function no longer reads descriptor state.
pub fn completed_ids(work: &Path, _snap: &Snapshot) -> BTreeSet<String> {
    let mut set = BTreeSet::new();
    if let Ok(text) = fs::read_to_string(work.join("Tasks_Done.md")) {
        set.extend(text.lines().filter_map(archive_header_task_id));
    }
    set
}

/// Decode one `Tasks_Done.md` line into its archived task id, per the SINGLE normative
/// archive-header contract shared by all three readiness resolvers — this function, the
/// PowerShell `tools/queue-tx.ps1 Get-ArchiveHeaderIds`, and `tui/src/main.rs::done_task_ids`
/// (which reuses this exact function). Only these header shapes count as an archive record (a
/// `T-id` mentioned anywhere in an archive *body* must NEVER satisfy a prerequisite — K-018):
///   * a bracketed **H2 or H3** heading — `## [T-NNN] …` / `### [T-NNN] …` (the canonical shape
///     the archive writer emits today, see `run.rs::append_done`); and
///   * the legacy non-bracketed **H1** heading older processor revisions wrote —
///     `# Активная задача T-NNN` / `# Active task T-NNN` (case-insensitive, either language).
///
/// In every shape the id must be `T-` followed by at least one digit; a bare `T-` or a
/// non-numeric `T-abc` is rejected. Returns the canonical numeric id (`T-045` → `T-45`) or `None`.
pub fn archive_header_task_id(line: &str) -> Option<String> {
    let trimmed = line.trim_start();
    // `#` is ASCII (1 byte), so the count of leading '#' is a valid char boundary to slice at.
    let hashes = trimmed.len() - trimmed.trim_start_matches('#').len();
    let rest = &trimmed[hashes..];
    match hashes {
        // Bracketed H2/H3: `## [T-NNN] …` / `### [T-NNN] …` (whitespace before `[` optional).
        2 | 3 => {
            let inner = rest.trim_start().strip_prefix('[')?;
            let close = inner.find(']')?;
            valid_task_id(inner[..close].trim())
        }
        // Legacy non-bracketed H1: `#` then whitespace, the keyword, then the id token.
        1 => {
            if !rest.starts_with(char::is_whitespace) {
                return None;
            }
            let mut tokens = rest.split_whitespace();
            let (kw1, kw2) = (tokens.next()?, tokens.next()?);
            let keyword_ok = (eq_ci(kw1, "Active") && eq_ci(kw2, "task"))
                || (eq_ci(kw1, "Активная") && eq_ci(kw2, "задача"));
            if !keyword_ok {
                return None;
            }
            legacy_id_token(tokens.next()?)
        }
        _ => None,
    }
}

/// A bracketed `[T-NNN]` id (its content already trimmed) is valid iff it is `T-` followed by at
/// least one digit and NOTHING else — the strict, whole-token check mirroring queue-tx's
/// `\[\s*T-0*(\d+)\s*\]` (which allows only whitespace, never trailing text, before `]`). Rejects
/// a bare `T-` or a non-numeric `T-abc`.
fn valid_task_id(id: &str) -> Option<String> {
    canonical_task_id(id)
}

/// The id inside a legacy H1 token, mirroring queue-tx's `T-0*(\d+)\b`: `T-` then at least one
/// digit, ending at a word boundary — end of token, or a trailing non-alphanumeric char (`.`/`,`)
/// tolerated as queue-tx's `\b` does. `T-1abc` / `T-1_` (a word char right after the digits) is
/// rejected, exactly as `\b` fails there.
fn legacy_id_token(token: &str) -> Option<String> {
    let digits = token.strip_prefix("T-")?;
    let n = digits.chars().take_while(char::is_ascii_digit).count();
    if n == 0 {
        return None;
    }
    match digits[n..].chars().next() {
        Some(c) if c.is_alphanumeric() || c == '_' => None,
        // "T-" is 2 ASCII bytes and the digit run is `n` ASCII bytes, so `2 + n` is a valid slice.
        _ => canonical_task_id(&token[..2 + n]),
    }
}

/// Unicode-aware case-insensitive string equality — needed for the Cyrillic legacy-heading
/// keyword (`Активная задача`), which `str::eq_ignore_ascii_case` does not fold.
fn eq_ci(a: &str, b: &str) -> bool {
    a.chars()
        .flat_map(char::to_lowercase)
        .eq(b.chars().flat_map(char::to_lowercase))
}

/// The value of the first line whose trimmed form starts with `key` (e.g. `"Статус:"`), i.e.
/// the trimmed text after the key. `None` if no such line exists. Used for the single-value
/// Markdown fields (`Статус:`, `Приём:`, `База:`, …).
pub(crate) fn line_field<'a>(text: &'a str, key: &str) -> Option<&'a str> {
    text.lines()
        .map(str::trim)
        .find_map(|l| l.strip_prefix(key).map(str::trim))
}

/// Parse a comma-separated `Предпосылки:` value into canonical T-ids, dropping empties and any
/// invalid token (`нет`, dashes, stray words). Every consumer compares the canonical numeric form:
/// `T-45` and `T-045` are the same prerequisite, while `T-45abc` is not a T-id at all.
pub(crate) fn parse_task_id_list(value: &str) -> Vec<String> {
    value
        .split(',')
        .map(str::trim)
        .filter_map(canonical_task_id)
        .collect()
}

/// A canonicalizable T-id is exactly `T-` followed by one or more ASCII digits.
pub(crate) fn canonical_task_id(s: &str) -> Option<String> {
    let digits = s.strip_prefix("T-")?;
    if digits.is_empty() || !digits.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let value = digits.parse::<u64>().ok()?;
    Some(format!("T-{value}"))
}

/// Exact task-id validation used for record identities (not prerequisite aliases).
pub(crate) fn is_task_id(s: &str) -> bool {
    canonical_task_id(s).is_some()
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

    /// T-293: the ONE normative archive-header contract, shared byte-for-shape with
    /// `tools/queue-tx.ps1 Get-ArchiveHeaderIds` and `tui/src/main.rs::done_task_ids`. All the
    /// previously divergent shapes — H2 `##`, H3 `###`, and the legacy H1
    /// `# Активная задача`/`# Active task` — must be recognized identically; body mentions and
    /// digitless ids must not.
    #[test]
    fn archive_header_task_id_accepts_all_normative_shapes() {
        // H3 (canonical writer shape) and H2 bracketed headings.
        assert_eq!(
            archive_header_task_id("### [T-091] H3 entry — статус: завершена").as_deref(),
            Some("T-91")
        );
        assert_eq!(
            archive_header_task_id("## [T-090] H2 entry — статус: завершена").as_deref(),
            Some("T-90")
        );
        // Whitespace variants: leading indent, no space before `[`, spaces inside brackets.
        assert_eq!(
            archive_header_task_id("   ###[T-1] tight").as_deref(),
            Some("T-1")
        );
        assert_eq!(
            archive_header_task_id("### [ T-7 ] spaced").as_deref(),
            Some("T-7")
        );
        // Legacy non-bracketed H1, both languages, case-insensitive.
        assert_eq!(
            archive_header_task_id("# Активная задача T-092").as_deref(),
            Some("T-92")
        );
        assert_eq!(
            archive_header_task_id("# Active task T-093").as_deref(),
            Some("T-93")
        );
        assert_eq!(
            archive_header_task_id("# активная ЗАДАЧА T-094").as_deref(),
            Some("T-94")
        );
        assert_eq!(
            archive_header_task_id("# ACTIVE TASK T-095").as_deref(),
            Some("T-95")
        );
        // Legacy H1 id ends at a word boundary (queue-tx `\b`): a trailing `.` or extra token is
        // tolerated, so the resolvers agree on such a header too.
        assert_eq!(
            archive_header_task_id("# Активная задача T-096.").as_deref(),
            Some("T-96")
        );
        assert_eq!(
            archive_header_task_id("# Active task T-097 (note)").as_deref(),
            Some("T-97")
        );
    }

    #[test]
    fn archive_header_task_id_rejects_non_headers_and_bad_ids() {
        // Body prose / non-heading lines never satisfy a prerequisite (K-018).
        assert_eq!(archive_header_task_id("Prerequisites: T-101"), None);
        assert_eq!(
            archive_header_task_id("Cross-reference [T-102] in prose"),
            None
        );
        // H1 bracketed and H4+ are NOT part of the contract (only ##/### bracketed, single-# legacy).
        assert_eq!(archive_header_task_id("# [T-103] H1 bracketed"), None);
        assert_eq!(archive_header_task_id("#### [T-104] H4 heading"), None);
        // Strict id: a bare `T-` or a non-numeric `T-abc` must NOT pass (tightened for the TUI).
        assert_eq!(archive_header_task_id("### [T-] no digits"), None);
        assert_eq!(archive_header_task_id("### [T-abc] letters"), None);
        assert_eq!(archive_header_task_id("# Активная задача T-"), None);
        assert_eq!(archive_header_task_id("# Active task T-xyz"), None);
        // Word char glued right after the digits fails queue-tx's `\b`, so it fails here too.
        assert_eq!(archive_header_task_id("# Active task T-1abc"), None);
        // Wrong keyword / missing space after `#`.
        assert_eq!(archive_header_task_id("# Some heading T-1"), None);
        assert_eq!(archive_header_task_id("#Активная задача T-1"), None);
    }

    /// The three-resolver agreement fixture: one archive text carrying every normative shape plus
    /// a body mention. `completed_ids` (engine) must yield EXACTLY the four archived ids — the
    /// same set `tools/queue-tx.ps1` and `tui/src/main.rs::done_task_ids` derive from it.
    #[test]
    fn completed_ids_agrees_across_normative_header_shapes() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock after epoch")
            .as_nanos();
        let work = std::env::temp_dir().join(format!(
            "orchestra-completed-ids-shapes-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir_all(&work).expect("create test work directory");
        fs::write(
            work.join("Tasks_Done.md"),
            "# Выполненные задачи\n\n\
             ## [T-090] H2 archive entry — статус: завершена\n\
             ### [T-091] H3 archive entry — статус: завершена\n\
             # Активная задача T-092\nСостояние: завершена\n\
             # Active task T-093\n\n\
             Body mention of T-999 must not count\n\
             ### [T-] digitless header must not count\n",
        )
        .expect("write archive fixture");

        let snapshot = Snapshot::load(&work);
        let completed = completed_ids(&work, &snapshot);
        fs::remove_dir_all(&work).expect("remove test work directory");

        let expected: BTreeSet<String> = ["T-090", "T-091", "T-092", "T-093"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert_eq!(completed, expected);
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
        assert_eq!(parse_task_id_list("T-045, T-45"), vec!["T-45", "T-45"]);
        assert!(parse_task_id_list("T-45abc").is_empty());
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
