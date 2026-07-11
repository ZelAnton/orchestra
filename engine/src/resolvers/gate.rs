//! Resolver 3 — **clean / with-findings review gate** (`agents/processor.md`, phases 2.6 / 2.7 /
//! 2.8).
//!
//! After a review pass the processor branches three ways on the `review.md` content and the
//! `date -u` mark it took just before the call. This resolver names that branch as a pure
//! function over the already-parsed [`ReviewParse`], **reusing** `ReviewParse::is_clean_pass`
//! for the clean determination (the freshness + zero-open-`R-` gate proved in `contract.rs`):
//!
//! * **Findings** (2.8) — open `R-` present → address them, then re-review.
//! * **Clean** (2.6) — a `SUMMARY-R` fresher than `since` AND no open `R-` → the task goes
//!   `на ревью → готова к слиянию`.
//! * **Incomplete** (2.7) — no open `R-` but no fresh `SUMMARY-R` either (the reviewer was cut
//!   short, e.g. by `maxTurns`) → re-run the SAME reviewer; never hand the coder an empty list.

use crate::contract::ReviewParse;

/// The three-way phase-2.6/2.7/2.8 review-gate branch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReviewGate {
    /// 2.6 — fresh `SUMMARY-R` and no open `R-`: clean pass, promote to `готова к слиянию`.
    Clean,
    /// 2.8 — open `R-` findings: dispatch a fix, then re-review.
    Findings,
    /// 2.7 — no open `R-` and no fresh `SUMMARY-R`: reviewer interrupted, re-run it unchanged.
    Incomplete,
}

/// Resolve the review-gate branch. `since` is the UTC ISO-8601 mark taken just before the review
/// call (the freshness cutoff for `SUMMARY-R`). Open `R-` findings take precedence (2.8); else a
/// fresh clean pass (2.6, via `is_clean_pass`); else the pass is incomplete (2.7).
pub fn review_gate(parse: &ReviewParse, since: &str) -> ReviewGate {
    if !parse.open_review_findings().is_empty() {
        ReviewGate::Findings
    } else if parse.is_clean_pass(since) {
        ReviewGate::Clean
    } else {
        ReviewGate::Incomplete
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::contract::parse_review;

    const SINCE: &str = "2026-07-10T17:00:00Z";

    #[test]
    fn open_findings_take_precedence() {
        // Open `R-` → Findings, even alongside a fresh SUMMARY-R.
        let dirty = "### [R-02] still broken — статус: новая\n";
        assert_eq!(
            review_gate(&parse_review(dirty), SINCE),
            ReviewGate::Findings
        );
        let with_summary = "\
### [R-02] still broken — статус: новая\n\
### [SUMMARY-R-2026-07-10T18:00:00Z] Итог — статус: готово к слиянию\n";
        assert_eq!(
            review_gate(&parse_review(with_summary), SINCE),
            ReviewGate::Findings
        );
    }

    #[test]
    fn fresh_summary_no_open_is_clean() {
        let clean = "\
### [R-01] fixed — статус: исправлено\n\
### [SUMMARY-R-2026-07-10T18:00:00Z] Итог — статус: готово к слиянию\n";
        assert_eq!(review_gate(&parse_review(clean), SINCE), ReviewGate::Clean);
    }

    #[test]
    fn stale_summary_is_incomplete_not_clean() {
        // A SUMMARY-R older than `since` is not a fresh clean pass (phase 2.6 freshness rule) and
        // there are no open findings → the pass is incomplete (2.7), re-run the reviewer.
        let stale = "### [SUMMARY-R-2026-07-10T16:00:00Z] Итог — статус: готово к слиянию\n";
        assert_eq!(
            review_gate(&parse_review(stale), SINCE),
            ReviewGate::Incomplete
        );
    }

    #[test]
    fn no_summary_no_findings_is_incomplete() {
        // Reviewer interrupted before writing anything actionable (e.g. maxTurns) → 2.7.
        let empty = "# review\n(no markers yet)\n";
        assert_eq!(
            review_gate(&parse_review(empty), SINCE),
            ReviewGate::Incomplete
        );
        // A resolved (`исправлено`) finding is NOT open, so with no fresh summary it is 2.7 too.
        let resolved = "### [R-01] done — статус: исправлено\n";
        assert_eq!(
            review_gate(&parse_review(resolved), SINCE),
            ReviewGate::Incomplete
        );
    }
}
