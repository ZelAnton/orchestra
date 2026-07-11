# orchestra-engine-spike — T-097 Stage 1 de-risking spike

This directory (`engine/`) is the top-level home of the future deterministic orchestrator
engine described in [`plans/DETERMINISTIC_ORCHESTRATOR_INTENT.md`](../plans/DETERMINISTIC_ORCHESTRATOR_INTENT.md).
It began as the Stage 1 de-risking spike for task **T-097**, and is now growing its first
engine-grade library modules — currently the **`events`** module (T-101): typed, read-only
access to the `.work/events.jsonl` durable event outbox (contract
[`docs/queue_contract.md`](../docs/queue_contract.md) §19). The headless engine itself is
still deliberately NOT built here: the intent doc's non-goals (§13) forbid a big-bang rewrite
of `agents/processor.md` before the spike's one real unknown is proven tractable and the
leaf-agent contracts are hardened (§8.2). The `events` module only *reads* the journal; it is
not wired into the running orchestrator.

## What the spike answers

The single true unknown (intent doc **risk R1**, §8.1): today `agents/processor.md` runs
*inside* Claude Code and spawns leaf agents (planner / coder / reviewer / merger …) with
the in-process **"Use the X subagent"** directive, which rides the session's
permission/classifier model. `tools/supervisor.ps1` — despite its name — is a generic
child-process bound (it spawns `--file <script.ps1>` or `--exe`); it does **not** spawn an
in-process Claude subagent. So an engine running *outside* Claude Code must reinvent the
wrapper that spawns and supervises `claude -p` / `codex exec` as child processes, with a
deadline, `maxTurns`, structured-output capture and correct permission handling.

This spike is a minimal, dependency-free Rust process that does exactly that, and proves
each piece under `cargo test`.

## Layout

| Module | Proves |
|---|---|
| `src/supervise.rs` | spawn a child, enforce a wall-clock deadline, drain stdout/stderr without deadlock, kill the child tree on timeout/cancel, and classify the stop into `ok/timeout/cancelled/crash/error` — with the **same reason→exit-code contract as `tools/supervisor.ps1`** (0/3/4/5/6), so a native port stays interchangeable. |
| `src/claude.rs` | build the headless `claude -p --output-format stream-json --verbose --max-turns N --model M --permission-mode …` argv, parse the stream-json transcript back to a structured result, and set the permission posture **explicitly per call** (see below). |
| `src/codex.rs` | build the fail-closed `codex exec … -c approval_policy=never --sandbox …` argv, mirroring the already-working `tools/codex-runtime.ps1`. |
| `src/contract.rs` | deterministically parse the leaf-agent structured markers (`R-NN`, `SUMMARY-R-<ts>`, `F-NN`, Codex sentinels, `Изменённые файлы:`) and compute the processor's phase-2.6 clean-pass gate as a pure function. |
| `src/jsonline.rs` | a minimal top-level JSON field scanner for one stream-json line (no dependency). |
| `src/events/` | typed, **read-only** consumer of the `.work/events.jsonl` durable event outbox (contract §19): `model` (the typed envelope — `Event` / `Actor` / `EventType`), `parse` (strict-envelope, lenient-forward line decode, §19.4), `reader` (a `TailReader` cursor that yields only new, unique, fully-committed events and never hands out a torn tail, §19.5/§19.7). This is the first module to use `serde_json`. |

## Run it

```sh
cd engine
cargo test            # hermetic, offline, token-free: unit tests + the e2e spike
cargo run -- selfcheck    # supervise a stand-in child (success / timeout / error cases)
cargo run -- argv claude  # print the argv the engine WOULD spawn for a claude call
cargo run -- argv codex   # print the fail-closed codex exec argv
cargo run -- events tail ../.work/events.jsonl            # decode the outbox to EOF and exit
cargo run -- events tail --follow ../.work/events.jsonl   # keep polling for new events (^C to stop)
```

`events tail` opens the file **read-only** — it never writes, truncates, or locks it — so it is
safe to point at the live `.work/events.jsonl` while the orchestrator runs. It prints each new,
unique, fully-committed event as one normalized JSON line and never emits a torn (half-written)
trailing record.

The first `cargo build`/`cargo test` performs a one-time online fetch of `serde_json`; after that
`engine/Cargo.lock` is committed and the crate builds and tests **offline** (the smoke gate stays
green with no network). The T-097 spike modules remain dependency-free; only `events` uses a crate.

A **real** model call is strictly opt-in and never runs in tests or `selfcheck`:

```sh
cargo run -- claude --live "Use the coder subagent to implement task T-1. Worktree=… WORK=…"
cargo run -- codex  --live "review this diff"
```

## Spike outcome (the Stage 1 verdict)

**Tractable — "clean", not "painful".** The three things R1 warned might be expensive are
all either already solved in this workspace or straightforward:

1. **Spawn + supervise.** The child-process spawn, deadline, output drain and tree-kill are
   small and already mirror what `tools/supervisor.ps1` does. The Rust line moreover
   already ships **`processkit`** (kill-on-drop Windows Job Object / Linux cgroup v2 /
   POSIX process group, timeouts, cancellation, restart/backoff, a mockable runner) —
   exactly the production substrate for this — so the engine does not have to reinvent the
   no-orphan guarantee. `vcs-toolkit` / `agent-workspace` cover the VCS-lifecycle and
   worktree side.
2. **Structured output.** `claude --output-format stream-json` is a real, documented
   headless mode; the transcript is newline-delimited JSON whose final `type":"result"`
   event carries `subtype` / `is_error` / `num_turns` / `result` — machine-parseable
   without any free-text guessing (proven in `claude.rs` / `jsonline.rs`).
3. **Permission / consent (the T-057 lesson).** The auto-mode classifier is an *in-process*
   Claude Code concern. A `claude -p` **subprocess carries its own permission configuration
   explicitly on its own argv** (`--permission-mode`, `--allowedTools`), so there is no
   parent→subagent consent hand-off to lose — which is precisely the failure mode of
   incident T-057 ("consent is not inherited through a subagent"). In the subprocess model
   consent stays "in the context of the call itself" by construction. This is a point *in
   favour* of the engine, not against it.

**Therefore:** the spike does not surface a blocker. It does **not** license a big-bang.
The correct next move per the intent doc's phased migration (§9) and the non-goals (§13) is
to proceed to Stage 2 (leaf-agent contract hardening) and Stage 3 (versioned manifest +
drift-CI) as **separate, individually reviewable queue tasks**, then build the headless
engine on top of the primitives sketched here — with `agents/processor.md` retained as the
differential oracle (`tools/harness.ps1` fingerprint) until equivalence is proven.

## Not in this spike (deliberately, by intent-doc non-goals)

- The headless engine itself (phase 0–6 state machine). — Stage 4.
- Rewriting `agents/processor.md` or any `tools/*.ps1`. — never big-bang; §13.
- The TUI. — last, after the engine drives a cohort itself.
- Wiring a `cargo` job into `.github/workflows/ci.yml`. — belongs with the engine stage,
  not the spike, to keep this change's blast radius minimal.
