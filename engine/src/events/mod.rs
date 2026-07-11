//! Typed, read-only access to the `.work/events.jsonl` durable event outbox
//! (contract `docs/queue_contract.md` §19).
//!
//! `.work/events.jsonl` is the machine-readable journal of orchestrator facts (cohort / task /
//! codex-attempt transitions) that complements the human-readable Markdown artifacts. This
//! module gives the future engine and TUI a shared, typed way to *consume* that journal:
//!
//! * [`model`] — the typed envelope ([`Event`], [`Actor`], [`EventType`]).
//! * [`parse`] — decode + validate one line (strict envelope, lenient-forward reading, §19.4).
//! * [`reader`] — a cursor / tail reader ([`TailReader`]) that yields only new, unique,
//!   fully-committed events and never hands out a torn tail (§19.5 / §19.7).
//!
//! **Read-only by construction.** Nothing here mutates the file, takes a lock, or emits an
//! event; it is not wired into `agents/processor.md`, `tools/*.ps1`, or any launcher. The
//! append / single-writer / repair half of the contract (§19.5, §19.6) stays with the
//! reference writer `tools/outbox.ps1` and is out of this module's scope.

pub mod model;
pub mod parse;
pub mod reader;

pub use model::{Actor, ActorKind, Event, EventType, SCHEMA_VERSION};
pub use parse::{parse_line, ParseError};
pub use reader::{Cursor, PollStats, TailReader};
