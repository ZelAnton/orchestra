# Focus activity and stop-control review

## Scope

Public command rename, compatibility with existing sessions/state, event-based
activity output, status freshness, graceful/emergency stop, exact-run containment,
runtime installation, documentation and regression isolation.

## Implementation validation

- Preserve `.work/cycle/` and old invocation markers to avoid breaking resume.
- Operator stop is separate from blocker recovery and from `.work/PAUSE`.
- Native CLI validation requires a lifecycle log and integral duration units;
  emergency tests exercise the installed ProcessKit with fixture processes only.
- Interrupted provider cleanup skips the normal persistence grace; normal results
  retain their orderly-shutdown grace.
- Invalidated publication intents are retained as artifacts but cleared as pending
  work before returning to review.
- A real weak process-group backend exposed escaped provider groups. Providers now
  have independently addressed containers; emergency control freezes the root then
  stops its durable provider target, including recovery after the root has crashed.
  Unconfirmed provider cleanup forbids starting another model.
- Read-only Windows status probing must not write the existing lock file. A lease
  release failure is recorded as an interruption, never a clean-stop acknowledgement.
- Status distinguishes a held runtime lock from fresh activity; old progress is
  marked stale even when a hung process still owns the lock.

## Final consecutive review passes

- [x] Session compatibility, state transitions and stop boundaries: no errors.
  Reviewed pending-intent/result recovery, old conversation markers, review-counter
  resets, publication reconciliation and safe-stop/error ordering. The final
  focused suite passed all 72 tests, including lease-release and stale-progress
  regressions added after the full launcher suite started.
- [x] Process ownership, emergency confirmation and output accuracy/privacy: no
  errors. Reviewed exact-run addressing, lock lifetime, root-before-leaf hard stop,
  cleanup failure handling, actual event labels and silent-provider heartbeats.
  Native ProcessKit fixture tests confirmed hard stop, orphan-leaf recovery and
  clean provider protocol transport; no real model invocation was used.
- [x] Installation, cross-platform entry points and regression/documentation
  scope: no errors. Reviewed shared runtime inventory, managed old-name pruning,
  argument routing, preserved state paths, executable modes and upgrade ordering.
  Only a capitalization correction in the knowledge map remained; it is not an
  implementation error and does not reset the clean-pass count.

## Verification evidence

- `python3 -B tests/test_cycle.py`: 72 tests passed, including native ProcessKit
  containment fixtures using the installed CLI and fake provider processes.
- `pwsh -NoProfile -File tests/launchers/run-all.ps1 -Mode Serial`: 12/12 eligible
  test files terminal green, 12 launches, maximum parallelism 1, survivors 0.
  This run included 70 focus tests; the two subsequent regression additions were
  covered by the final 72-test focused run. Windows-only suites were skipped on
  this Linux host, not counted as passed.
- `bash tests/launchers/test-posix-launchers.sh`: passed.
- Public POSIX launcher help, read-only status and Bash syntax: passed.
- PowerShell parsing and focus runtime analyzer errors: zero.
- Windows launcher byte/CRLF checks and generated package drift checks: passed.
- Repository consistency and whitespace checks: passed.

No native Windows execution, paid provider turn, production processing, deployment,
commit or push was performed. Existing unrelated working-tree changes were retained.
