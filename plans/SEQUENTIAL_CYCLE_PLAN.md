# Sequential main-branch cycle

## Scope

Implement an opt-in `cc-focus` command independently of the queue processor. Work
serially in the repository's existing `main` checkout. Do not change the legacy
processor's models, configuration, worktree strategy, or permission defaults.
The project plan referenced in the handoff supplies the next stage; read its current
state instead of selecting work from the queue or conversation memory. A missing
or ambiguous plan blocks selection. After publication, advance only when configured
CI succeeds on that exact commit; absent CI does not add a waiting barrier.

| Responsibility | Provider/model | Effort |
| --- | --- | --- |
| Coordination, concise reports | Codex gpt-5.6-luna | xhigh |
| Next stage implementation | Claude claude-fable-5-1 | high |
| First review and fixes | Codex gpt-6-astra | high |
| Second review and fixes | Claude claude-fable-5-1 | xhigh |
| Commit and push | Codex gpt-5.6-luna | high |
| Blocker resolution before escalation | Codex gpt-6-astra | xhigh |

Codex uses `danger-full-access` and `on-request`; Claude uses
`bypassPermissions`. These are explicit properties of this operator-selected
mode, not changes to global settings. Native delegation is disabled. The runtime
starts only one provider process at a time, including coordination and recovery.

## Implementation sequence

- [x] Add the dedicated launchers, fixed prompts and provider transports. Use the
  Codex app-server protocol for persistent sessions and real approval callbacks.
- [x] Add durable, repository-bound state, an exclusive processor lease, handoff
  snapshots, internal session capture, clean-session reset, and crash recovery.
- [x] Implement the sequential state machine and independently recorded review
  passes. Require three clean Codex passes and two clean Claude passes. After the
  third Codex pass only implementation fixes reset its counter; minor edits do
  not count. Return to Codex after substantial Claude implementation fixes.
- [x] Add one recovery attempt per blocker before an operator-visible stop.
  Preserve unfinished work and reconcile publication against actual Git state.
- [x] Wait for configured CI on the exact published revision before starting
  another stage. Use deterministic polling, not model turns, while CI runs.
- [x] Integrate runtime installation and document operation and limitations.
- [x] Test with protocol fixtures and disposable repositories, then review and
  fix until three consecutive substantive review passes are clean.

## Persistence and boundaries

`--handoff FILE` imports an immutable UTF-8 context snapshot. Session identifiers
are internal implementation details: there is no identifier import option or
first-run identifier prompt. `--new-sessions` resets conversations only; it does
not discard working files, the current stage, reports or publication progress.

The runtime owns state transitions and review counters. The coordinator receives
short outcomes and artifact paths; the first reviewer receives the complete
implementation final message. A completed process alone is not a completed step:
the report and repository invariants must validate first. Incomplete review
passes never increment clean counters. Instructions, configuration and tests can
be implementation; classification must not depend on filename extensions.

Check `.work/PAUSE` only at safe boundaries. Treat publication and its CI wait as
one publication window. Do not start recovery concurrently with an active or
unaccounted-for process. Human approval requests are not approvals that a recovery
model may grant on the operator's behalf.

No usage dashboard, quota balancing algorithm, additional parallelism, session
identifier migration, or unrelated workflow enhancements are included.
