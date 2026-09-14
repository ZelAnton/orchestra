# Rejected coding report recovery

## Confirmed failure

A completed implementation can report zero review fixes and still be substantial.
Applying reviewer-only count consistency to coding rejected that result. A healer
returned a valid report about its own work, but was correctly forbidden to edit
runtime state. The runtime returned to coding, while coordination treated pending
reviews as an incompatible phase. Retrying did not provide a phase-recovery action.

## Implementation

- [x] Distinguish new implementation from reviewer/healer fix classification.
- [x] Make report finalization an explicit coding-recovery route for coordination.
- [x] Provide an operator-only saved-result recovery command under the existing
  locks and lease. Validate stage evidence, preserve a recovery archive, keep native
  sessions, grant no review credit and exit before starting any model.
- [x] Document exact recovery steps and retain existing consuming-project state.
- [x] Validate and review until three consecutive passes find no substantive errors.

## Consecutive final review passes

Initial validation added explicit rejection of symlinked external invocation and
archive directories. This was fixed before counting the final clean passes.

- [x] Role-specific report validation and phase recovery: no errors. Coding may
  report new implementation without review-fix counts; reviewer/healer consistency
  checks remain strict. The original coding description reaches Astra, and
  coordinator recovery cannot select another stage to replace report finalization.
- [x] Evidence, ownership, crash boundaries and mandatory review preservation:
  no errors. Recovery checks the source role/iteration, exact files/HEAD/index,
  protected work, local paths and phase. Backup precedes the atomic state change;
  native sessions and original results are retained, and all five clean review
  passes remain required. The real wrapper/root/lease fixture exited paused,
  released ownership and invoked no provider. All 86 focused tests passed.
- [x] CLI/install compatibility, regression coverage and operator instructions:
  no errors. The command requires explicit recovery arguments, uses the existing
  contained launcher and shared runtime installation, and does not silently start
  processing. Documentation distinguishes the original coding result from the
  healer report and gives an explicit resume step. A comment clarification did
  not alter implementation or reset the clean-pass count.

## Final validation

- Focus suite: 86/86 tests passed in each of the final two complete focused runs.
- Full launcher regression: 12/12 eligible test files terminal green, serial mode,
  12 launches, maximum parallelism 1, survivors 0, 551560 ms. It included the 82
  tests present when the suite started; the four later additions were covered by
  the final 86-test runs.
- POSIX launcher regression, consistency, Python syntax, unique test names,
  PowerShell wrapper parsing/analyzer and whitespace checks: passed.
- Generated package drift and Windows launcher byte checks: passed. Native
  Windows-only suites were skipped on Linux, not reported as executed.
- Native ProcessKit recovery integration used disposable repositories and
  fail-closed provider stubs. No paid model turn or production recovery ran.
- No installation, commit or push was performed.

The consuming project is diagnostic input only. Its source, runtime state, lease
and history are not modified by this implementation or its tests.

The saved legacy coding report was also checked read-only with the new validator:
its completed status, coding intent, before/after HEAD, exact current snapshot,
protected files/index and stopped code phase satisfy the recovery preconditions.
The transition itself was exercised only in disposable repositories.
