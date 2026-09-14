# Multi-repository focus cycle and Orbit Git migration review

Date: 2026-09-13. Scope: one project cycle across independent Git repositories,
per-repository publication/recovery/CI, ownership, installation, and the explicitly
requested conversion of Orbit from colocated Jujutsu to Git.

The implementing Codex performed this self-review. No independent reviewer or
delegated agent was used. Three consecutive clean passes cover the same snapshot
of 15 Orchestra files and 7 Orbit files. The review record was added afterward.
Snapshot: `.work/focus-multirepo-review-snapshot.json`.

## Final behavior

- A project outside Git discovers direct Git children or reads explicit relative
  members from `focus-project.json`. Every member remains a primary `main` checkout.
  Membership, path containment and nonoverlap are checked; single-repository state
  and existing role conversations remain compatible.
- One coding phase and both review loops cover the combined iteration. File paths
  carry member prefixes; HEAD and index are recorded separately. Loose project
  files are sealed read-only context, with no implicit publication owner.
- Project and member locks/leases exclude overlapping runtimes. POSIX provider
  processes inherit all lock descriptors. Persistent member ownership records
  guard parent crashes and stop/status addressing. PAUSE is respected at both levels.
- Only changed repositories become publication targets. Each target pins its
  remote/push URL and passes policy before any publisher call. Completed pushes
  are reconciled before replay; partial progress survives interruption. Further
  reviewed changes reopen a target or add another already-owned member. A started
  publication cannot silently drop a target.
- Every changed repository completes CI at its own published SHA. Artifacts are
  separate, explicit retry renews member deadlines, and the next iteration clears
  publication metadata in the same saved transition. The aggregate display hash
  is never used as a Git SHA for remote queries or CI.

## Orbit migration

| Repository | Preserved HEAD | Git branch/upstream | Verified existing files |
| --- | --- | --- | ---: |
| Core | `6697ee8b2dbd660c90577efb095b15a1479c381b` | `main` / `origin/main` | 262 |
| Root | `61cd545f2b4f0b17029916c53f391f59bd8efc38` | `main` / `origin/main` | 97 |
| Specification | `63bd77906ccf3262038f809fbbe2fd573ec03b33` | `main` / `origin/main` | 200 |

All three existing main refs already matched HEAD and the live remote main refs.
HEAD was attached symbolically without checking out files; upstream tracking was
configured. `.jj`, `refs/jj/*` and their local metadata directories were removed.
Existing commits, index bytes and working files were preserved. Only the requested
active instructions changed, and `focus-project.json` was added at the project root.
No project commit, push, reset or clean was performed.

Before conversion, Git metadata, Jujutsu metadata and verified complete Git bundles
were saved outside Orbit under `.work/orbit-git-migration/`. `before.json` and
`after.json` record preservation evidence. Historical immutable toolchain inputs,
including bundled AGENTS bytes, were preserved; the active migrator guide explicitly
identifies their VCS instructions as historical data. Product roadmap references
to a future alternative VCS backend are not development instructions.

## Closed findings before the clean sequence

The implementation review corrected member CI deadline renewal, stale confirmation
after additional reviewed fixes, expansion after partial publication, atomic cleanup
of publication metadata at the next iteration, member PAUSE handling, member CI
artifact path containment, and safe member stop/status addressing. Regression
scenarios cover these boundaries. The clean sequence began after these corrections.

## Clean pass 1 — full scope, publication and data preservation

Reviewed all changed runtime paths, prompts, discovery, snapshots, member policy,
commit/push reconciliation, CI and next-iteration persistence. Rechecked the Orbit
migration against preserved HEAD/index/file hashes and active instructions.
No findings or changes. Consecutive clean passes: 1.

## Clean pass 2 — full scope, ownership and failure recovery

Rechecked the full diff, initial admission, parent/member locks and leases,
provider cleanup, parked sessions, stop/status, protected files/index, corrections,
partial pushes, retries and publication scope changes. Checked compatibility with
single-repository workflows and unchanged fixed models/permissions/review gates.
No findings or changes. Consecutive clean passes: 2.

## Clean pass 3 — full scope, integration and installation

Rechecked the full snapshot, test outcomes, documentation, generated-role stability,
mirror asset lists and installation as the operator account. Installed runtime bytes
match reviewed sources. The installed project reader, running as anton, admits all
three Orbit repositories and seals 562 current files. User Claude settings, root
configuration and Codex configuration hashes are unchanged after sync.
No findings or changes. Consecutive clean passes: 3.

## Validation

- `pwsh -NoProfile -File tests/launchers/run-all.ps1`: 12/12 suites passed,
  446842 ms, survivors=0. Linux skips 18 Windows-only launcher suites.
- The full run includes 139 workflow tests (4 skips), 55 terminal/input tests,
  17 status tests and 27 multi-repository tests (1 optional ProcessKit-location skip).
- The real ProcessKit launcher/parent-and-member lease test also passed separately
  with the installed operator CLI location. It starts no provider and confirms
  release of all four leases/locks after a safe pause.
- Publication fixtures use independent local bare Git remotes. Full combined review,
  selective publication, interrupted publisher continuation, additional reviewed fixes,
  untouched repositories, protected staging and per-member CI evidence were exercised.
  Live GitHub publication was not performed.
- Python syntax, UTF-8 without BOM, changed-line whitespace, `git diff --check`,
  generated-role stability and the reviewed snapshot hashes were verified.
- `cc-sync` succeeded as anton. Shared runtime and provider mirrors were updated;
  user settings remained unchanged. Existing parked terminals need a new cc-focus
  process to load the update.

Logs: `.work/focus-multirepo-suite.log`, `.work/focus-multirepo-suite-summary.json`,
`.work/focus-multirepo-project-final.log`, `.work/focus-multirepo-sync.log`.
