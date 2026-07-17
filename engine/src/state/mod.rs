//! Typed, read-only snapshot of the orchestrator **control plane** (contract
//! `docs/queue_contract.md` §13).
//!
//! The queue (§1–§12) is the *backlog*; the run's live lifecycle — task / cohort-admission /
//! integration state, held in human-readable Markdown artifacts — is a separate *control plane*
//! (§13). This module parses those artifacts into one deterministic [`Snapshot`] the future
//! engine and TUI can share:
//!
//! * [`canonical`] — the canonical ASCII state names (§13.1–§13.3) and the Cyrillic-literal →
//!   canonical mapping, byte-for-byte with the contract tables and `tools/state-tx.ps1`.
//! * [`queue`] — `.work/Tasks_Queue.md` entries (id, title, task state, `Предпосылки:`,
//!   `Delivery target:` delivery lane §11.1).
//! * [`descriptor`] — `.work/tasks/<T-ID>/task.md` `Статус:` (§13.1).
//! * [`cohort`] — `.work/cohort_state.md` `Приём:` (§13.2); absent = no active cohort.
//! * [`integration`] — `.work/integration_state.md` (§13.3); absent = `none`.
//! * [`batch`] — `.work/batch.md` manifest (base, integration branch, admitted tasks).
//! * [`snapshot`] — the aggregate [`Snapshot`] + JSON / human presentation.
//!
//! **Read-only by construction.** Nothing here writes a file, takes the `.work/orchestrator.lock`
//! lease, or validates transitions (that is `tools/state-tx.ps1`, §17); it only *observes* the
//! current state, and it is not wired into `agents/processor.md`, `tools/*.ps1`, or any launcher.
//! Missing artifacts degrade to empty / `none` (an idle repository is a valid state), never an
//! error.

mod util;

pub mod batch;
pub mod canonical;
pub mod cohort;
pub mod descriptor;
pub mod integration;
pub mod queue;
pub mod snapshot;

pub use batch::{load_batch, parse_batch, BatchState, BatchTask};
pub use canonical::{CohortAdmission, IntegrationState, TaskState};
pub use cohort::{load_cohort, parse_cohort, CohortState};
pub use descriptor::{load_descriptors, parse_descriptor, parse_review_cycles, Descriptor};
pub use integration::{load_integration, parse_integration, IntegrationSnapshot};
pub use queue::{parse_queue, DeliveryTarget, QueueEntry};
pub use snapshot::Snapshot;
