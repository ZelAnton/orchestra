//! Resolver — the cohort **budget / circuit-breaker gate** (`agents/processor.md` "Роллинг-приём
//! когорты", Фаза 2.0/2.9, and the `COHORT_BUDGET_SEC` circuit-breaker of "Supervisor вызова
//! исполнителя").
//!
//! After a top-up round the processor decides whether to keep the cohort's admission open. Three
//! parsed config thresholds gate it — `COHORT_SIZE` (capacity), `COHORT_MAX_AGE` (admission
//! window), `COHORT_BUDGET_SEC` (a total wall-clock budget circuit-breaker), and
//! `COHORT_TOKEN_BUDGET` (actual observed model-token ceiling) — weighed against the already-read
//! counters `Admitted всего`, the cohort's age, elapsed wall-clock, and deduplicated actual usage.
//! This resolver ports those gates into pure functions.
//!
//! Its close reasons reuse the SAME `Приём: закрыт · причина=<…>` vocabulary as
//! [`super::admission::CloseReason`] (§13.2) — it never invents a new word. The wall-clock budget
//! is a *time* circuit-breaker, so on exhaustion it closes with the existing time reason
//! `COHORT_MAX_AGE` (the §13.2 vocabulary has no separate budget literal).

use super::admission::CloseReason;

/// The parsed size / age / wall-clock-budget thresholds a cohort's admission is gated on — the
/// config keys `COHORT_SIZE`, `COHORT_MAX_AGE`, `COHORT_BUDGET_SEC`, `COHORT_TOKEN_BUDGET`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CohortThresholds {
    /// `COHORT_SIZE` — max tasks admitted into one cohort before admission closes (default
    /// `3 × MAX_PARALLEL`).
    pub size: u32,
    /// `COHORT_MAX_AGE` — minutes to keep admission open from the cohort's start (default 90).
    pub max_age_minutes: u64,
    /// `COHORT_BUDGET_SEC` — total wall-clock budget for the cohort in seconds; `None` or `0`
    /// disables the budget circuit-breaker (the config default `0` = no limit).
    pub budget_sec: Option<u64>,
    /// `COHORT_TOKEN_BUDGET` — actual tokens allowed for one cohort; `None` or `0` disables the
    /// token circuit-breaker. Estimated usage is deliberately excluded before reaching this
    /// resolver, so a heuristic never becomes an apparently exact spending gate.
    pub token_budget: Option<u64>,
}

/// The already-read cohort counters the gate weighs against [`CohortThresholds`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CohortCounters {
    /// `Admitted всего` — how many tasks the cohort has admitted so far (across all waves).
    pub admitted_total: u32,
    /// Minutes elapsed since `Начало когорты`.
    pub age_minutes: u64,
    /// Seconds elapsed since the cohort started (for the `COHORT_BUDGET_SEC` circuit-breaker).
    pub elapsed_sec: u64,
    /// Deduplicated `usage.recorded` total for this batch with `estimated=false` only.
    pub actual_tokens: u64,
}

/// The gate decision: keep admitting, or latch admission closed with a canonical reason.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AdmissionGate {
    /// Keep the cohort's admission open — no size/age/budget circuit-breaker has tripped.
    Continue,
    /// Latch `Приём: закрыт · причина=<reason>`.
    Close(CloseReason),
}

/// Whether the next model call may start under the optional actual-token ceiling. The caller
/// reads/deduplicates the append-only event stream before each dispatch; this pure result makes
/// the boundary testable without granting the resolver I/O or mutation authority.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TokenBudgetGate {
    /// No configured limit, or observed actual usage remains below it.
    Allow,
    /// The configured ceiling has been reached. Do not start another model invocation.
    Exhausted { actual_tokens: u64, budget: u64 },
}

/// Resolve the `COHORT_TOKEN_BUDGET` pre-dispatch gate. `None` and `0` retain the historical
/// unlimited behaviour; equality is exhausted so the configured ceiling is never exceeded by a
/// *new* model call after durable usage observation.
pub fn token_budget_gate(actual_tokens: u64, token_budget: Option<u64>) -> TokenBudgetGate {
    match token_budget.filter(|&budget| budget > 0) {
        Some(budget) if actual_tokens >= budget => TokenBudgetGate::Exhausted {
            actual_tokens,
            budget,
        },
        _ => TokenBudgetGate::Allow,
    }
}

/// Resolve the cohort budget / circuit-breaker gate. Pure: a deterministic function of already-read
/// `counters` and parsed `thresholds`.
///
/// Priority follows the processor's textual order (size before the time limits): the cohort being
/// full (`COHORT_SIZE`) is reported first; otherwise either the admission window (`COHORT_MAX_AGE`)
/// or the wall-clock budget (`COHORT_BUDGET_SEC`) elapsing closes admission with the time-based
/// `COHORT_MAX_AGE` reason. The actual-token gate follows those established limits and closes
/// with its own `COHORT_TOKEN_BUDGET` reason. `None`/`0` disable either optional budget.
pub fn admission_gate(counters: CohortCounters, thresholds: CohortThresholds) -> AdmissionGate {
    // Size circuit-breaker: the cohort is full.
    if counters.admitted_total >= thresholds.size {
        return AdmissionGate::Close(CloseReason::CohortSize);
    }
    // Age circuit-breaker: the admission window has elapsed.
    if counters.age_minutes >= thresholds.max_age_minutes {
        return AdmissionGate::Close(CloseReason::CohortMaxAge);
    }
    // Wall-clock budget circuit-breaker (only when COHORT_BUDGET_SEC > 0): the cohort has spent its
    // whole time budget -> stop admitting, reported with the existing time-based reason.
    if let Some(budget) = thresholds.budget_sec {
        if budget > 0 && counters.elapsed_sec >= budget {
            return AdmissionGate::Close(CloseReason::CohortMaxAge);
        }
    }
    if let TokenBudgetGate::Exhausted { .. } =
        token_budget_gate(counters.actual_tokens, thresholds.token_budget)
    {
        return AdmissionGate::Close(CloseReason::CohortTokenBudget);
    }
    AdmissionGate::Continue
}

#[cfg(test)]
mod tests {
    use super::*;

    fn thresholds(
        size: u32,
        max_age_minutes: u64,
        budget_sec: Option<u64>,
        token_budget: Option<u64>,
    ) -> CohortThresholds {
        CohortThresholds {
            size,
            max_age_minutes,
            budget_sec,
            token_budget,
        }
    }

    fn counters(
        admitted_total: u32,
        age_minutes: u64,
        elapsed_sec: u64,
        actual_tokens: u64,
    ) -> CohortCounters {
        CohortCounters {
            admitted_total,
            age_minutes,
            elapsed_sec,
            actual_tokens,
        }
    }

    #[test]
    fn continues_while_under_every_threshold() {
        let t = thresholds(15, 90, Some(3600), Some(4_000));
        assert_eq!(
            admission_gate(counters(4, 30, 1800, 1_999), t),
            AdmissionGate::Continue
        );
        // Budget disabled (None / 0) never trips even at a huge elapsed.
        assert_eq!(
            admission_gate(
                counters(4, 30, 999_999, 999_999),
                thresholds(15, 90, None, None)
            ),
            AdmissionGate::Continue
        );
        assert_eq!(
            admission_gate(
                counters(4, 30, 999_999, 999_999),
                thresholds(15, 90, Some(0), Some(0))
            ),
            AdmissionGate::Continue
        );
    }

    #[test]
    fn closes_on_cohort_size_at_capacity() {
        let t = thresholds(15, 90, None, None);
        assert_eq!(
            admission_gate(counters(15, 10, 600, 0), t),
            AdmissionGate::Close(CloseReason::CohortSize)
        );
        assert_eq!(
            admission_gate(counters(16, 10, 600, 0), t),
            AdmissionGate::Close(CloseReason::CohortSize)
        );
    }

    #[test]
    fn closes_on_cohort_max_age_when_window_elapsed() {
        let t = thresholds(15, 90, None, None);
        assert_eq!(
            admission_gate(counters(4, 90, 5400, 0), t),
            AdmissionGate::Close(CloseReason::CohortMaxAge)
        );
        assert_eq!(
            admission_gate(counters(4, 120, 7200, 0), t),
            AdmissionGate::Close(CloseReason::CohortMaxAge)
        );
    }

    #[test]
    fn closes_on_wall_clock_budget_exhaustion_with_time_reason() {
        // COHORT_BUDGET_SEC circuit-breaker: budget spent, still under size and age -> close with
        // the time-based COHORT_MAX_AGE reason (no separate budget literal in the §13.2 vocabulary).
        let t = thresholds(15, 90, Some(3600), None);
        assert_eq!(
            admission_gate(counters(4, 30, 3600, 0), t),
            AdmissionGate::Close(CloseReason::CohortMaxAge)
        );
        assert_eq!(
            admission_gate(counters(4, 30, 4000, 0), t),
            AdmissionGate::Close(CloseReason::CohortMaxAge)
        );
    }

    #[test]
    fn size_takes_precedence_over_time_limits_when_both_trip() {
        // Both full AND past the age window / budget: report COHORT_SIZE (processor's textual order).
        let t = thresholds(15, 90, Some(3600), Some(2_000));
        assert_eq!(
            admission_gate(counters(15, 120, 4000, 2_000), t),
            AdmissionGate::Close(CloseReason::CohortSize)
        );
    }

    #[test]
    fn token_budget_is_a_pre_dispatch_gate_and_closes_admission() {
        assert_eq!(
            token_budget_gate(4_999, Some(5_000)),
            TokenBudgetGate::Allow
        );
        assert_eq!(
            token_budget_gate(5_000, Some(5_000)),
            TokenBudgetGate::Exhausted {
                actual_tokens: 5_000,
                budget: 5_000
            }
        );
        assert_eq!(token_budget_gate(9_999, None), TokenBudgetGate::Allow);
        assert_eq!(token_budget_gate(9_999, Some(0)), TokenBudgetGate::Allow);
        assert_eq!(
            admission_gate(
                counters(4, 30, 1800, 5_000),
                thresholds(15, 90, None, Some(5_000))
            ),
            AdmissionGate::Close(CloseReason::CohortTokenBudget)
        );
    }
}
