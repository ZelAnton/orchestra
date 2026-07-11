//! orchestra-engine-spike — T-097 Stage 1 de-risking spike.
//!
//! Purpose (intent doc §8.1, risk R1): prove, OUTSIDE Claude Code, that a compiled engine
//! can spawn and supervise ONE `claude` leaf-agent call and ONE `codex exec` call with a
//! deadline / maxTurns, capture their structured output, and handle permission/consent
//! correctly — the single true unknown before any headless engine is worth building.
//!
//! This crate is dependency-free on purpose (see Cargo.toml). Every module is a small,
//! unit-tested primitive:
//!
//! * [`supervise`] — spawn + deadline + tree-kill + reason classification, contract-
//!   compatible with `tools/supervisor.ps1`.
//! * [`claude`] — headless `claude -p --output-format stream-json` argv + transcript
//!   parse + explicit per-call permission posture (the T-057 lesson).
//! * [`codex`] — fail-closed `codex exec` argv mirroring `tools/codex-runtime.ps1`.
//! * [`contract`] — deterministic parse of leaf-agent structured markers (§8.2).
//! * [`jsonline`] — minimal top-level JSON field scanner for stream-json lines.
//!
//! Beyond the original spike, the crate now also carries [`events`] — typed, read-only access
//! to the `.work/events.jsonl` durable event outbox (contract `docs/queue_contract.md` §19).
//! This is the first module to grow the crate from spike toward engine and the first to pull
//! in `serde_json` (see Cargo.toml / README "Spike outcome"). It only *reads* the journal; it
//! is not wired into the running orchestrator.

pub mod claude;
pub mod codex;
pub mod contract;
pub mod events;
pub mod jsonline;
pub mod supervise;
