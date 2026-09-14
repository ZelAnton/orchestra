# Interactive focus terminal

## Scope

Add a persistent terminal composer to the existing serial workflow. Keep the
fixed profiles, shared lease, protected work, publication/CI barrier and external
control commands. Do not install or exercise providers in consuming projects.

## Implementation

1. Add a standard-library terminal with bounded scrollback, editing, status,
   slash commands, explicit approval prompts and a non-TTY fallback.
2. Persist messages addressed to one iteration, invocation and role. Distinguish
   queued, sending, accepted, rejected and discarded delivery. Uncertain delivery
   must stop phase advancement and require an explicit operator decision.
3. Use Codex `turn/steer` with the expected turn ID. Use Claude bidirectional
   stream-json input with replay acknowledgements. Keep only one provider active.
4. Retain a paused terminal after releasing runtime ownership. Support resume,
   stopped-stage corrections and explicit retry/discard of undelivered messages.
5. Carry accepted stage instructions into subsequent review context and invalidate
   prior review credit on intervention. Do not steer publication or CI.
6. Update mirrored assets, operator documentation and hermetic regression tests.

## Validation

Exercise normal delivery, terminal-result races, interleaved protocol responses,
missing acknowledgements, restart, stale targeting, approval ownership, terminal
restoration and redirected output. Use disposable repositories and protocol
fixtures, never paid model calls. Review and fix until two consecutive review
passes find no implementation errors; record evidence separately.

## Completion

Implemented the terminal, durable message delivery, provider integration, stopped
controls, mirrored assets, documentation and regression coverage. The final two
review passes are clean; evidence and platform limits are recorded in
`FOCUS_TERMINAL_REVIEW.md`. Installation remains an explicit operator action after
stopping any older runtime; no consuming project was modified.
