# Focus output and operator corrections

## Scope

- Render public messages, tool actions, command output and errors from the existing
  serial provider protocols. Keep reasoning and protocol envelopes out of the
  console, retain private protocol logs, and offer compact output explicitly.
- Add a model-free, stopped-only correction command accepting text or a UTF-8 file.
  Bind it to the current unpublished stage, preserve sessions and artifacts, replace
  obsolete invocation intent, and require coding followed by both review loops.
- Preserve stop containment, locks, protected work, publication reconciliation and
  exact-revision CI. Refuse corrections after publication starts or before a stage
  starts; do not silently redirect them to another stage.

## Implementation and verification

1. Add bounded, terminal-safe provider event rendering and transport integration.
2. Persist immutable corrections and recovery anchors before changing phase state;
   include them in resumed prompts and guard against stale result replay.
3. Cover both transports, output deduplication, malformed events, correction crash
   recovery, review invalidation and CLI ownership using hermetic fixtures.
4. Update installation inventory, operator documentation and the knowledge map.
5. Run focused and launcher regressions. Review and fix until three consecutive
   passes find no implementation defects; minor wording changes do not reset them.

No native interactive terminal, mid-turn steering, new SDK, external harness,
permission change, deployment, commit or push is part of this implementation.

## Outcome

Implemented and verified. The final three review passes were clean; see
`FOCUS_INTERVENTION_REVIEW.md` for findings, fixes, test results and platform limits.
