//! Resolver 4 — **review-cycle limit** (`agents/processor.md`, phases 2.5 / 2.8; `REVIEW_LOOP_MAX`).
//!
//! The processor caps how many review cycles a single task may run by the persistent
//! `Циклов-ревью: N` field (set to `1` at the first review in 2.5, incremented on entry to each
//! subsequent 2.8 — the field survives resume, so the cap is read off it, not off context). When
//! the count of the cycle about to run exceeds `REVIEW_LOOP_MAX`, the task escalates
//! `не сходится ревью после N циклов` instead of looping forever.
//!
//! This resolver is the pure comparison at that decision point; the same shape governs the
//! integration loop (`INTEGRATION_LOOP_MAX`) and the CI-fix loop (`CI_FIX_MAX`).

/// The review-cycle-limit decision.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CycleDecision {
    /// Under budget — run the cycle.
    Proceed,
    /// Over budget — escalate. `after_cycles` is the number of cycles already completed (the
    /// `N` in `не сходится ревью после N циклов`).
    Escalate { after_cycles: u32 },
}

impl CycleDecision {
    /// The canonical escalation reason literal, or `None` when proceeding.
    pub fn escalation_reason(&self) -> Option<String> {
        match self {
            CycleDecision::Escalate { after_cycles } => {
                Some(format!("не сходится ревью после {after_cycles} циклов"))
            }
            CycleDecision::Proceed => None,
        }
    }
}

/// Decide whether the review cycle numbered `cycle` (the current `Циклов-ревью` value for the
/// cycle about to run) may proceed under `limit` (`REVIEW_LOOP_MAX`). Escalate once the count
/// exceeds the limit — at that point `limit` cycles have already run without converging.
pub fn review_cycle_decision(cycle: u32, limit: u32) -> CycleDecision {
    if cycle > limit {
        CycleDecision::Escalate {
            after_cycles: cycle.saturating_sub(1),
        }
    } else {
        CycleDecision::Proceed
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proceeds_up_to_and_including_the_limit() {
        // Default REVIEW_LOOP_MAX = 8: cycles 1..=8 run, the 9th escalates.
        for cycle in 1..=8 {
            assert_eq!(
                review_cycle_decision(cycle, 8),
                CycleDecision::Proceed,
                "cycle {cycle}"
            );
        }
        assert_eq!(
            review_cycle_decision(9, 8),
            CycleDecision::Escalate { after_cycles: 8 }
        );
    }

    #[test]
    fn escalation_reason_names_completed_cycle_count() {
        let d = review_cycle_decision(9, 8);
        assert_eq!(
            d.escalation_reason().as_deref(),
            Some("не сходится ревью после 8 циклов")
        );
        assert_eq!(review_cycle_decision(3, 8).escalation_reason(), None);
    }

    #[test]
    fn boundary_and_tight_limits() {
        // Exactly at the limit proceeds; one past escalates naming the limit as N.
        assert_eq!(review_cycle_decision(8, 8), CycleDecision::Proceed);
        // A tight limit of 1 allows only the first cycle.
        assert_eq!(review_cycle_decision(1, 1), CycleDecision::Proceed);
        assert_eq!(
            review_cycle_decision(2, 1),
            CycleDecision::Escalate { after_cycles: 1 }
        );
    }
}
