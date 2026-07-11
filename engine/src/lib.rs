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
//!
//! [`state`] extends that read-only direction to the **control plane** (contract §13): it parses
//! the queue / task-descriptor / cohort / integration / batch Markdown artifacts into one typed
//! [`state::Snapshot`], mapping the Cyrillic status literals onto their canonical ASCII names.
//! Like [`events`], it only *reads* `.work/` — no mutation, no lock — and is not wired into the
//! running orchestrator; it is the model layer future resolvers and the TUI build on.
//!
//! [`resolvers`] is that first layer of resolvers: the processor's per-task decision trees
//! (`agents/processor.md` phases 2.x — reviewer tiering, Codex maker/checker routing, the clean
//! gate, review-cycle limits) compiled into deterministic pure functions over typed inputs (and
//! reusing [`contract::ReviewParse::is_clean_pass`]). Like the layers below it, it performs no
//! I/O and no mutation and is not wired into the running orchestrator.
//!
//! [`lease`] is the first module that *mutates* control-plane state — but never directly: it is
//! the engine's owner-lease interlock (contract §14–§17, task T-107), taking / renewing / releasing
//! / inspecting the `.work/orchestrator.lock` lease **strictly** through `tools/state-tx.ps1`
//! (owner-checked, liveness-checked) under the engine's own role (`engine`, distinct from
//! `processor`). It re-implements no owner/TTL check and never force-removes a foreign lease, so the
//! engine and a live processor mutually exclude each other on the one shared lock. It is exercised
//! only by the `engine lease` subcommand and is **not** wired into any launcher or live `.work/`.

pub mod claude;
pub mod codex;
pub mod contract;
pub mod events;
pub mod jsonline;
pub mod lease;
pub mod resolvers;
pub mod state;
pub mod supervise;
