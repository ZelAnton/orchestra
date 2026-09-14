# Focus command, live activity and stop control

## Implementation

- [x] Rename the installed command to `cc-focus`, retaining the existing runtime
  state and native session identities without an implicit fresh start.
- [x] Show actual provider activity, phase/pass/model, elapsed and silent time,
  report locations and review/CI transitions. Do not print reasoning contents,
  command arguments, credentials or raw protocol output by default.
- [x] Add repository-scoped `stop` with safe-boundary acknowledgement and waiting,
  plus `stop --now` with contained emergency termination and recoverable state.
  Preserve PAUSE semantics and the publication-plus-CI window. Never signal an
  unrelated PID or another run, and never start blocker recovery for operator stop.
- [x] Expose live versus stale state through `status`; document continuation,
  interrupted-run recovery, deployment and the old-command upgrade procedure.
- [x] Add fixture/disposable-repository tests, run regressions and review/fix until
  three consecutive passes have no substantive errors.

Existing `.work/cycle/` paths and invocation markers are compatibility contracts;
the public command rename does not require moving or rewriting consuming projects.
No production processing or stop commands are run in another project for testing.
