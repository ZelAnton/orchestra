# Review existing implementation

Use `cc-focus review` to inspect completed plan items or an explicit scope.
This mode uses the normal review pairs, arbitration, repair gates, publication, and CI.
It does not run an initial implementation phase.
Reviewers inspect the current implementation of the selected requirements, including necessary dependencies.
They do not limit inspection to the new repair diff.

## Start conditions

Start from a clean, published `main` checkout. For a parallel member, remote main must contain local main. The run start then syncs it.
In a project with multiple repositories, each member must meet this condition.
Finish active development through publication and CI first.
Use `/finish-stage` in its terminal, then wait for the stage-completed pause.
The review command preserves the paused development state.

Commits pushed to main after a development boundary do not prevent the review.
Changed project context outside the member repositories still prevents it, unless development completed a stage.

Only one development or review runtime can own the project.
An unfinished review campaign prevents a new campaign or development run.
Resume that campaign with its recorded ID.
The runtime never accepts incomplete review work as a development checkpoint.

## Select items with arguments

```sh
cc-focus review --plan plan/s2-adaptation.md --stages S2-15a
cc-focus review --plan plan/s2-adaptation.md --stages 'S2-15a..S2-15e2,S2-17'
cc-focus review --plan plan/s2-adaptation.md --section S2-15
cc-focus review --plan plan/s2-adaptation.md --completed --preview
```

A range includes both endpoints and follows document order, not alphabetic order.
A single parent ID selects its completed descendants.
For a range, a parent at the right endpoint extends the range through its last descendant.
Overlapping ranges select an item once.
Unknown IDs, reversed ranges, and duplicate item definitions cause an error.
An explicit unfinished leaf item also causes an error.
Ranges and sections exclude unfinished descendants and show their status in the selection output.

The parser accepts Markdown ID headings and ID checklists.
The plan can contain up to 32 MiB, including historical journals.
For example, use `### S2-15a. Title` or `- [x] P1. Title`.
A status table can use ID in its first column and a `Status` or `Статус` column.
A section can instead contain a `Status:` or `Статус:` line near its start.
Explicit completion words include `Completed`, `Published`, `Done`, `Завершена`, and `Опубликована`.
Unknown status remains unavailable for selection.
Split parent items select completed leaf items.
For another plan format, supply an explicit scope file.

By default, each selected item is a separate target.
Each target completes all review, repair, publication, and CI gates before the next target starts.
Use `--integration` to inspect selected items together as one target.
Use `--scope` to add boundary conditions or exclusions.

```sh
cc-focus review --plan plan/s2-adaptation.md --stages 'S2-15a..S2-15e2' \
  --integration --scope 'Check resource ownership across storage and delivery.'
cc-focus review --scope-file /tmp/integration-review.md
```

An explicit scope can identify components, requirements, scenarios, and exclusions without a plan.
The scope file must contain UTF-8 text and must not exceed 64 KiB.
It is input to the review, not a source of another implementation task.

Give several scope files to review them in one campaign. Each file is a separate target, in the order of the arguments.
Each target completes all review, repair, publication, and CI gates before the next target starts.

```sh
cc-focus review --scope-file reviews/s1a-review.md reviews/s1b-review.md reviews/s1c-review.md
```

Several scope files cannot have plan items, `--integration`, `--scope`, or the menu. Give each file only one time.
The whole selection can have at most 4 MiB. A target title is the first line of its file, without a Markdown heading marker.

A shell pattern gives the files in name order. Thus `s1-10.md` comes before `s1-2.md`, so use names with the same length.
A repair of a later target can queue an earlier target again when they share covered files, as "Results and coverage" describes.

## Select items in a menu

Install the optional menu once for the current user:

```sh
cc-focus review --install-ui
cc-focus review --plan plan/s2-adaptation.md --pick
```

The installer uses pinned `prompt_toolkit` and `wcwidth` versions in `~/.orchestra/venvs/focus-ui`.
It does not change the system Python environment.
Argument-based selection requires no extra Python packages.
The menu opens before the runtime takes ownership or starts a model.
It uses keyboard input and does not capture the mouse.

| Key | Action |
| --- | --- |
| Up / Down | Move through items |
| Space | Toggle an item or all completed descendants |
| Left / Right | Collapse or expand a group |
| `/` | Move to search |
| `r`, then `r` | Select a range between two marked endpoints |
| `i` | Switch between separate targets and integration |
| Tab / Shift-Tab | Move between the list, search, and additional scope |
| Enter in the list / Ctrl-S | Accept the selection |
| Esc / Ctrl-C | Cancel without starting a run |

Marks survive search and collapsed groups.
The menu shows the current item's text, status, selected count, and processing mode.
The displayed selection includes IDs, titles, scope, and excluded items.
The saved selection also contains the exact requirement text.
Use `--preview` to stop after this display.

## Save, resume, and control

```sh
cc-focus review --plan plan/s2-adaptation.md --pick --preview \
  --save-selection .work/cycle/selections/recheck.json
cc-focus review --selection-file .work/cycle/selections/recheck.json
cc-focus review --list
cc-focus review --resume RUN_ID
cc-focus review --resume RUN_ID --retry
cc-focus status --review-run RUN_ID
cc-focus correct --review-run RUN_ID --message 'Also check restart after delivery.'
```

Save selection JSON directly in `.work/cycle/selections/` or outside the project.
Existing files are never overwritten.
A saved selection binds to the plan hash and exact completed requirement text.
The combined saved selection must not exceed 4 MiB.
If the plan changed before a new run, select again.
A resumed run retains its original scope and accepted corrections.

Each campaign stores state, sessions, messages, and evidence in `.work/cycle/review-runs/RUN_ID/`.
The project runtime lock and active process control remain shared with development.
`status`, `stop`, `messages`, and `finish-stage` address the last active run by default.
Use `--review-run RUN_ID` to address a specific campaign.
In its terminal, `/resume`, `/pause`, `/stop`, `/correct`, and `/finish-stage` retain their existing behavior.
Here, `/finish-stage` pauses after the current review target and CI.
A correction restarts the review pairs for that target, without entering coding.
Coding-report recovery and publication-reconciliation imports are not supported in this mode.

A campaign uses the project brief of development: the pointer and the copies in `.work/cycle/`.
Each target captures the pointer at its start, and its result records that hash.
A changed pointer does not reopen completed targets. To review them again under another brief, start a new campaign.
The campaign coordinator gets no brief.

To change the brief of the current unfinished target, stop the campaign.
Then run `cc-focus brief apply --review-run RUN_ID`. Then run `cc-focus review --resume RUN_ID`.
If a saved blocker remains after the apply, run `cc-focus review --resume RUN_ID --retry` instead.
To see the record of a campaign, run `cc-focus brief show --review-run RUN_ID`.

During a review stage pause, you can push other commits to main.
On resume, the runtime makes the checks of a development stage pause.
It then queues a completed target again when later changes reach its recorded paths or their directories.
A path that only a sync, a catch-up, or an integration of a parallel member changed does not queue a target again.

## Results and coverage

Each independent outer reviewer records coverage for every selected requirement.
Coverage names inspected files, checks, and limitations.
The runtime validates requirement IDs and snapshot paths, and it rejects a path that a coverage entry lists more than one time.
This validation does not prove that the model found every defect.
Required verification that has not run remains a finding.
The existing repair gates control tests and builds.

For the test scope rules, the selected review scope counts as the current changes.
The Pair B full run and the final gate follow the same rules as in development.
If a target has no repairs, the runtime skips the final gate.

Publication commits and pushes only the new reviewed repairs in affected repositories.
If a target needs no repairs, the runtime verifies the existing remote revision and evaluates its CI gate.
It does not create an empty commit or push unchanged repositories.
The existing CI policy still decides whether configured checks are required.

Later repairs invalidate earlier targets when they change recorded coverage paths or files in their covered directories.
The runtime also watches paths repaired during each completed target.
The runtime returns those targets to the queue with fresh sessions and review results.
This check uses recorded coverage, not a complete semantic dependency graph.
Use integration mode when cross-component behavior is the primary concern.

The campaign stops when all selected targets have current results.
`report.md` gives the readable result. `result.json` links the sealed target records.
Both files are inside the campaign directory.
They preserve review, repair, publication, and CI evidence separately from the source plan's historical completion status.

For each target, `report.md` lists the findings that the outer review pairs decided, in every round.
A fixed or verified finding shows the executor result, unless a later round deferred it or marked it a duplicate.
Another finding shows its last decision and the reason. Each line also gives up to three locations.
The list omits inner repair gate findings, unless an outer pair decides them again.

If a merge resolver of a parallel member resolved a conflict, `report.md` also lists the resolved paths of the target and their rules.
Nobody reviewed these files. A resolved file differs from remote main, so it can queue earlier targets again, as other repairs do.

The last section lists the deferred findings, also those of an earlier review of a target that was reviewed again.
An earlier deferral is left out when the current review has a finding with the same title and location paths.
A pair can defer only a finding that is not significant. Plan these findings separately if they still apply.

After a completed campaign, run normal `cc-focus` to continue development.
The runtime accepts the new checkpoint only if the saved development boundary and completed review evidence still match.
It verifies the checkout and remote revisions again.
An unexplained change prevents this transfer and preserves both states.

Commits pushed after the last review publication are not an unexplained change.
For them, the runtime makes the checks of a development stage pause.
The runtime accepts changed project context outside the member repositories only after a completed development stage.
