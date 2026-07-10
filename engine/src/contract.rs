//! Deterministic, machine-readable parse of the STRUCTURED markers leaf agents already
//! emit. The intent doc calls this the real prerequisite (§7/§8.2): the one "soft" place
//! where `processor.md` interprets free text today is a leaf agent's report, and a
//! deterministic engine needs every such return to be parseable WITHOUT free-text
//! guessing. This module shows that is tractable for the markers already in use:
//!
//!   * review findings   `### [R-NN] title — статус: новая|исправлено|отклонено`
//!   * integration finds  `### [F-NN] title — статус: ...`
//!   * clean-pass summary `### [SUMMARY-R-<UTC ISO-8601>] Итог ревью задачи — статус: готово к слиянию`
//!   * Codex sentinels    `CODEX_UNAVAILABLE`, `CODEX_FAILED`, `ЭСКАЛАЦИЯ codex: ...`
//!   * coder Mode-3 tail  `Изменённые файлы: <list>`
//!
//! The clean-pass GATE the processor applies (phase 2.6) is: a FRESH `SUMMARY-R` exists
//! AND there is no open (`статус: новая`) `R-` finding. Both halves are computed here as
//! pure functions over the review text — no model judgment involved.

/// A finding's lifecycle status (the four words the contract uses, plus a catch-all).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Status {
    New,      // новая
    Fixed,    // исправлено
    Rejected, // отклонено
    Ready,    // готово к слиянию (SUMMARY-R only)
    Other(String),
}

impl Status {
    fn parse(s: &str) -> Status {
        match s.trim() {
            "новая" => Status::New,
            "исправлено" => Status::Fixed,
            "отклонено" => Status::Rejected,
            "готово к слиянию" => Status::Ready,
            other => Status::Other(other.to_string()),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Finding {
    pub id: String, // e.g. "R-02", "F-01", "SUMMARY-R-2026-07-10T18:00:00Z"
    pub status: Status,
}

impl Finding {
    pub fn is_summary(&self) -> bool {
        self.id.starts_with("SUMMARY-R")
    }
    pub fn is_review(&self) -> bool {
        self.id.starts_with("R-")
    }
    pub fn is_integration(&self) -> bool {
        self.id.starts_with("F-")
    }
    /// The UTC ISO-8601 timestamp embedded in a SUMMARY-R id (after the `SUMMARY-R-` prefix).
    pub fn summary_timestamp(&self) -> Option<&str> {
        self.id.strip_prefix("SUMMARY-R-")
    }
}

#[derive(Debug, Clone, Default)]
pub struct ReviewParse {
    pub findings: Vec<Finding>,
}

impl ReviewParse {
    /// The freshest SUMMARY-R finding (latest ISO-8601 timestamp; ISO-8601 sorts lexically).
    pub fn latest_summary(&self) -> Option<&Finding> {
        self.findings
            .iter()
            .filter(|f| f.is_summary())
            .max_by(|a, b| a.summary_timestamp().cmp(&b.summary_timestamp()))
    }
    /// Open review findings = `R-` entries with status `новая`.
    pub fn open_review_findings(&self) -> Vec<&Finding> {
        self.findings
            .iter()
            .filter(|f| f.is_review() && f.status == Status::New)
            .collect()
    }
    /// The processor's phase-2.6 clean gate, made deterministic: a SUMMARY-R newer than
    /// `since` (the timestamp recorded just before the review call) AND no open `R-`.
    pub fn is_clean_pass(&self, since: &str) -> bool {
        let fresh_summary = self
            .latest_summary()
            .and_then(|f| f.summary_timestamp())
            .map(|ts| ts > since)
            .unwrap_or(false);
        fresh_summary && self.open_review_findings().is_empty()
    }
}

/// Parse a review.md / review_integration.md body into its findings.
pub fn parse_review(text: &str) -> ReviewParse {
    let mut out = ReviewParse::default();
    for line in text.lines() {
        if let Some(f) = parse_heading(line) {
            out.findings.push(f);
        }
    }
    out
}

/// Parse one `### [ID] ... — статус: X` heading. Returns None for non-heading lines.
fn parse_heading(line: &str) -> Option<Finding> {
    let l = line.trim_start();
    if !l.starts_with("###") {
        return None;
    }
    let lb = l.find('[')?;
    let rb = l[lb + 1..].find(']')? + lb + 1;
    let id = l[lb + 1..rb].trim().to_string();
    if id.is_empty() {
        return None;
    }
    // status after the last "статус:"
    let status = match l.rfind("статус:") {
        Some(p) => Status::parse(&l[p + "статус:".len()..]),
        None => Status::Other(String::new()),
    };
    Some(Finding { id, status })
}

/// A Codex adapter sentinel found in a leaf-agent report.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Sentinel {
    Unavailable, // CODEX_UNAVAILABLE — fall back to Claude
    Failed,      // CODEX_FAILED — substantive failure
    Escalation,  // "ЭСКАЛАЦИЯ codex: ..."
}

/// Detect the FIRST Codex sentinel present (order: escalation, unavailable, failed).
/// These are whole-token contracts, not free text.
pub fn detect_sentinel(text: &str) -> Option<Sentinel> {
    if text.contains("ЭСКАЛАЦИЯ codex") {
        return Some(Sentinel::Escalation);
    }
    if text.contains("CODEX_UNAVAILABLE") {
        return Some(Sentinel::Unavailable);
    }
    if text.contains("CODEX_FAILED") {
        return Some(Sentinel::Failed);
    }
    None
}

/// Parse the coder Mode-3 tail `Изменённые файлы: a, b, c` into a file list. The mode-3
/// contract REQUIRES this line, so its absence is a distinct, detectable condition (None).
pub fn parse_changed_files(text: &str) -> Option<Vec<String>> {
    for line in text.lines() {
        let l = line.trim();
        if let Some(rest) = l.strip_prefix("Изменённые файлы:") {
            let files: Vec<String> = rest
                .split([',', ';'])
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
            return Some(files);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    const REVIEW_DIRTY: &str = "\
# review\n\
### [R-01] Race in cohort open — статус: исправлено\n\
- Файл: x\n\
### [R-02] Missing error handling — статус: новая\n\
- Файл: y\n";

    const REVIEW_CLEAN: &str = "\
# review\n\
### [R-01] Race in cohort open — статус: исправлено\n\
### [SUMMARY-R-2026-07-10T18:00:00Z] Итог ревью задачи — статус: готово к слиянию\n\
- Открытых проблем: 0\n";

    #[test]
    fn parses_findings_and_statuses() {
        let p = parse_review(REVIEW_DIRTY);
        assert_eq!(p.findings.len(), 2);
        assert_eq!(p.findings[0].id, "R-01");
        assert_eq!(p.findings[0].status, Status::Fixed);
        assert_eq!(p.findings[1].status, Status::New);
        assert_eq!(p.open_review_findings().len(), 1);
    }

    #[test]
    fn dirty_pass_is_not_clean() {
        let p = parse_review(REVIEW_DIRTY);
        // No summary at all => never clean.
        assert!(!p.is_clean_pass("2026-07-10T17:00:00Z"));
        assert!(p.latest_summary().is_none());
    }

    #[test]
    fn clean_pass_requires_fresh_summary_and_zero_open() {
        let p = parse_review(REVIEW_CLEAN);
        assert!(p.latest_summary().is_some());
        assert_eq!(p.open_review_findings().len(), 0);
        // Summary at 18:00 is newer than a review started at 17:00 => clean.
        assert!(p.is_clean_pass("2026-07-10T17:00:00Z"));
        // But a STALE summary (review started at 19:00, after the summary) is NOT clean:
        // this is exactly the "fresh, not any historical SUMMARY-R" rule (phase 2.6).
        assert!(!p.is_clean_pass("2026-07-10T19:00:00Z"));
    }

    #[test]
    fn open_finding_blocks_clean_even_with_summary() {
        let text = format!("{REVIEW_CLEAN}### [R-09] still broken — статус: новая\n");
        let p = parse_review(&text);
        assert_eq!(p.open_review_findings().len(), 1);
        assert!(!p.is_clean_pass("2026-07-10T17:00:00Z"));
    }

    #[test]
    fn sentinels_are_whole_token() {
        assert_eq!(detect_sentinel("all good"), None);
        assert_eq!(
            detect_sentinel("... CODEX_UNAVAILABLE, falling back"),
            Some(Sentinel::Unavailable)
        );
        assert_eq!(
            detect_sentinel("CODEX_FAILED — ENV_LIMIT"),
            Some(Sentinel::Failed)
        );
        // Escalation takes precedence when both appear.
        assert_eq!(
            detect_sentinel("ЭСКАЛАЦИЯ codex: sandbox-init; CODEX_FAILED"),
            Some(Sentinel::Escalation)
        );
    }

    #[test]
    fn changed_files_tail_parsed_and_absence_detected() {
        let report = "did the fix.\nИзменённые файлы: src/a.rs, src/b.rs ; tools/x.ps1\n";
        let files = parse_changed_files(report).unwrap();
        assert_eq!(files, vec!["src/a.rs", "src/b.rs", "tools/x.ps1"]);
        // A report missing the mandatory line is a detectable condition, not a guess.
        assert!(parse_changed_files("no tail here").is_none());
    }

    #[test]
    fn integration_findings_recognized() {
        let text = "### [F-01] build break after merge — статус: новая\n";
        let p = parse_review(text);
        assert!(p.findings[0].is_integration());
        assert_eq!(p.findings[0].status, Status::New);
    }
}
