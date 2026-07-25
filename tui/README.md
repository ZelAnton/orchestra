# `orchestra-tui`

`orchestra-tui` is the live terminal view for an already configured Orchestra
project. It gives an operator a compact view of the current run and the decisions
that need attention. It does not start `processor`, run a launcher, or replace the
normal `cc-processor` / `cc-resume` workflow.

Run it from the Orchestra checkout after the target project's `.work` directory
exists. The workspace toolchain is pinned in the repository root.

```powershell
cargo build --locked -p orchestra-tui
cargo run --locked -p orchestra-tui -- --work C:\src\my-project\.work
```

For a debug build that is already present, the binary can also be started directly:

```powershell
.\target\debug\orchestra-tui.exe --work C:\src\my-project\.work
```

## Starting a session

The working directory is optional. With no arguments, the TUI observes `.work`
relative to the current directory. A positional path and `--work` are equivalent.

```text
orchestra-tui [OPTIONS] [WORK_DIR]

-w, --work <PATH>    Path to the project's .work directory
    --tick-ms <N>    Refresh and input-poll cadence in milliseconds (default: 250)
    --all-projects   Open the read-only registered-projects hub
```

`--tick-ms` must be greater than zero. `--all-projects` cannot be combined with a
working-directory argument. It reads the operator registry at
`~/.orchestra/projects.json` (or the operator-provided `ORCHESTRA_REGISTRY_PATH`),
then opens the selected project's normal screens with `Enter`; `b` returns to the
hub. The hub itself does not accept command keys.

The usual single-project entry point is therefore:

```powershell
cargo run --locked -p orchestra-tui -- --work .work
```

## Screens and navigation

The TUI refreshes its observations on a short cadence. It reads `.work/status.md`
and tails `.work/events.jsonl`; it can therefore show a running orchestrator without
holding its lease.

- **Overview** is the initial screen. It projects the current cohort, tasks, recent
  activity, and the latest status overlay.
- **Decision Inbox** groups pending approvals, escalated tasks, quarantined tasks,
  and blocked work. A pause banner remains visible even when no cards are present.

Press `Tab` to switch between the two screens and `r` to reload `status.md` and the
inbox immediately. In the Decision Inbox, use `Left`/`Right` (or `h`/`l`) to choose a
panel; `Up`/`Down` (or `k`/`j`) select pending approvals or scroll the selected
non-approval panel. `PageUp` and `PageDown` move by a larger step. Press `q` or
`Ctrl+C` to quit; `Esc` first closes an open lease-status popup and otherwise quits.
An open confirmation or rejection-reason modal consumes input; `Esc` cancels it.

## Operator actions

Observing is read-only by default. The following named keys are the TUI's entire
command surface; only the rows marked as write actions mutate project state:

| Key | Action | Boundary and result |
| --- | --- | --- |
| `p` | Pause | Writes `.work/PAUSE`, the same kill switch used by `cc-pause`, with a timestamp and TUI reason. The processor stops at its next phase or round boundary. |
| `u` | Resume | Removes `.work/PAUSE`, like `cc-unpause`. An already absent file is harmless. |
| `s` | Lease status | Read-only query of `orchestrator.lock` through `tools/state-tx.ps1 status --json`; it reports the owner and liveness. |
| `x` | Force-release lease | Opens a confirmation modal. Only `y`, `Y`, or `Enter` executes `tools/state-tx.ps1 release --force`; any other key cancels. Use it only after confirming that the processor is definitely dead. |
| `a` | Approve | On the Decision Inbox only, opens a confirmation for the selected pending approval. |
| `d` | Reject | On the Decision Inbox only, asks for a non-empty reason, then opens a confirmation for the selected pending approval. |

Approval actions are performed through `tools/policy.ps1`; the Rust process never
writes approval JSON itself. Force-lock and approval actions use the existing
supervised transactional paths, so their diagnostics match the launcher workflow;
approval actions also retain the established policy checks. A confirmation is
deliberately required for every force-lock or approval decision. If another operator
consumed or expired an approval first, the TUI reloads the inbox rather than applying
a stale decision.

Outside the `PAUSE` control file, those transactions are the entire write surface.
The TUI never edits the queue, task descriptors, source code, or approval artifacts,
and never invokes `processor`. Use `cc-status` and `cc-journal` for lightweight
noninteractive inspection, and use the normal processor/resume launchers to begin or
continue work.

For the complete operator response procedure, see
[`docs/operations.md`](../docs/operations.md).
