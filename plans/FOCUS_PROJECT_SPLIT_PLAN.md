# cc-focus readiness for a project split: plan

Status: accepted. Each reviewer gave two consecutive clean passes on revision 3.3.
Revision 3.4 corrects the order of steps 3 and 4. Revision 3.5 adds the checks and the undo after the first run in steps 4, 6, and 11.
The implementation follows this plan.

## Goal

Prepare cc-focus for a project that moves its plans and documentation out of the code repository.
After the split, one stage can change the code, the plan, and the documentation in three repositories.
Another agent makes the split. This plan covers the cc-focus changes and the guide that the other agent follows.

The target layout of Interlink is:

```
/srv/dev/projects/Interlink/          project root, not a Git repository
    focus-project.json                {"version": 1, "repositories": ["Interlink", "Interlink-docs", "Interlink-plans"]}
    AGENTS.md -> Interlink-docs/project/AGENTS.md
    CLAUDE.md -> Interlink-docs/project/CLAUDE.md
    Interlink/                        code repository
    Interlink-docs/                   documentation repository
    Interlink-plans/                  plan repository
```

The outer path stays the same. The code repository moves one level down.

## Readiness: what works now

cc-focus has a project mode for a root outside Git with member repositories. The code shows these facts:

- One stage can change several members. The pairs review the combined diff (`focus_publication.py`, `focus_pair_view.py`).
- Publication commits and pushes each changed member separately. A member without changes gets no commit.
  A reviewed fix after a partial push can add another commit to a member.
- The CI gate runs for each member with the policy of that member (`MemberCycle.policy` uses the member `.work`).
  - Required checks come from the member `.work/constraints.md`.
  - A member has no CI only when it has no required checks and no `.github/workflows` files.
  - A workflow file makes the gate wait for its run on the published commit.
  - Without required checks, a known external CI file stops the gate with `unsupported-ci`.
- `accept_task` accepts a plan path in a member, relative to the project root (`focus_status.py`).
- `cc-focus review --plan` accepts a regular plan file inside the project root, at most 32 MiB (`focus_review_scope.source_file`).
  `create_run` also requires a clean, published main in every member.
- The project brief uses the project root store.
- A root symbolic link is sealed by its link text, not by the content of its target (`Project.loose_files`).
  - A change of the target content is a normal member change.
  - A changed link raises `project-context-changed`, and `cc-focus reconcile` refuses it (`reconcile-symlink`).
  - A frozen review view shows a link as a placeholder text. The view contains the target file under its own path.
- The project cycle uses the member store for the lock, the owner record, and `active.json` (the parked-provider guard).
  It also uses the member `.work/PAUSE`, the member processor lease, and the member `constraints.md`.
  It does not read the member `state.json`.
- Saved state is bound to its repository path. After the move, an old state in the code repository fails with `invalid-state`.
- In a development run, a member outside the publication is checked against its remote only when its main changed.
  Thus a local-only member that never changes works. A review campaign requires a published main in every member.

## Gaps

1. **Instruction files.** The roles see different instruction files:
   - Main roles and pair writers run in the project root. Codex reads only the root `AGENTS.md` there.
     Claude reads the root `CLAUDE.md`, and a nested `CLAUDE.md` only when it reads files in that directory.
   - Independent pair readers run in an empty view directory. Today, Codex readers find `Interlink/AGENTS.md` through the `.git` directory above the view.
     After the split, no `.git` directory is above the project root. Codex readers then load no instruction file.
   - Claude pair readers start without setting sources. They load no instruction file, before and after the split.
   Thus, after the split, no reader gets the project rules, and Codex roles in the root miss the member rules.
2. **Tests.** No test covers a plan in a member, member names with a shared prefix, root instruction links, or the new instruction list.
3. **Guide.** The operator and the splitting agent need exact steps, checks, and the changes in the Interlink repositories.

## Design

### M1. Project instructions in the context

- In project mode, the runtime lists the instruction files of the root and of each member:
  `AGENTS.md`, `CLAUDE.md`, and `.claude/CLAUDE.md` in the directory.
  - Each entry has `path`, relative to the project root, and `repository`: the member name, or null for the root.
  - For a link to a regular file in the same source, the entry also has `target`. Other links and other file types are left out.
  - Root entries come first, then the members in sorted order.
- The context field `project_instructions` has the list and the fixed rule `PROJECT_INSTRUCTIONS_RULE` in `tools/cycle_prompts.py`.
  The name differs from the diagnostic `instruction_files`, which lists the files that Claude can load.
  The checker scans the rule. A comment names the `_STYLE_TEXT` entry that a later change of the rule needs.
- Rule text:

  > The files field lists the instruction files of the project root and its member repositories.
  > The paths are relative to the project root. For a link, read the file that its target field names.
  > These files are part of the project instructions.
  >
  > Before you use, change, or review files in a repository, read its instruction files.
  > If a repository instruction file gives a command, run the command in the root of that repository.
  > If a repository instruction and a project-root instruction do not agree, obey the repository instruction for that repository.
  > In a pair inspection, read these files with focus_inspect.
  >
  > If an instruction file does not agree with another source, obey the other source.
  > These sources are your role contract, operator messages and corrections, and the review scope.

- Sources of the list:
  - For the main roles and the pair writers, the list comes from the current files.
  - For a pair reader, the list comes from the frozen view of that reader record.
    Names come from the view files, kinds from the view source kinds, and link targets from the placeholder text.
    A target is kept only when it is a regular file in the view. Link chains are resolved inside the view.
    Thus the list matches the view, and a rebuilt prompt of a saved job does not change.
- Delivery:
  - `ProjectCycle.context` adds the field for `code`, `coordinate`, `heal`, `publish`, and the pair writers.
    These contexts are built again for each invocation. Writer bindings do not hash the prompt, so no saved state changes.
  - The campaign coordinator keeps its own text without the field (`ReviewMode.context`).
  - A new pair in project mode stores the marker `project_instructions_version: 1`.
    `repair_reader`, `start_final_gate`, and the evidence reader in `focus_repair_evidence.py` copy the marker. An absent marker stays absent.
  - With the marker, the prompt of every reader gets the field, also for the complexity assessor and the evidence auditor.
  - A pair without the marker, made by an older runtime, gets no field. Its saved jobs keep their prompts, so `same_pair_prompt` needs no change.
  - An empty list adds no field.
  - An unknown marker version stops the run with `instruction-version`. `RUNTIME_VERSION_BLOCKERS` routes it to `runtime-version`, and no recovery agent starts.
- A single repository adds no field. Its prompts stay unchanged.

### M2. Readiness tests

The tests use the project fixtures with the members `Interlink`, `Interlink-docs`, and `Interlink-plans`. The names share a prefix.
The plan path in all tests is `Interlink-plans/plan/s2-adaptation.md`.

- Layout:
  - `assert_main` and the snapshot accept the layout and root links to `Interlink-docs/project/AGENTS.md`.
  - A change of the target content is a member change and raises no `project-context-changed`.
  - A retargeted root link raises `project-context-changed`, and reconcile refuses it.
- Plan in a member: `accept_task` stores the plan path, and `create_run` accepts it with `--plan`.
- A stage changes `Interlink` and `Interlink-plans`. Only these two members publish. `Interlink-docs` gets no commit.
- CI: a member with no required checks and no workflow passes the real policy gate.
- Instruction list:
  - The main context and the writer context in project mode have the field, with the root link target.
  - Readers of a new pair, inner readers, the complexity assessor, the evidence auditor, and the final-gate evidence auditor have the field.
  - `ViewInspector` can read every listed file and link target.
  - A link chain inside the view gives the final regular file as the target.
  - Directories, links outside the view, and missing files are left out. An empty list adds no field.
  - A saved reader job of a new pair still matches its prompt after an instruction file or a link changes on disk.
  - A single repository, an older pair without the marker, and the campaign coordinator get no field.
  - A campaign in project mode gives the field to `publish`, `heal`, and the writers.
- `tests/test_focus_instructions.py`: the checker scans the rule.

### M3. Migration guide

A new section in `docs/sequential-cycle.md`, "Move plans and documentation to member repositories", gives these steps.
The commands use absolute paths, except in step 5 and in the commands that run at the project root. Each step names its stopping point.

1. **Stop at a stage boundary.**
   - Use `/finish-stage`, wait for the pause, then use `/exit`.
   - Check `cc-focus status`: `running` is false, and `stage_completed` is set or `status` is `complete`.
     `active.provider_run` is null or absent, and `active.provider_runs` is empty or absent.
   - Check `cc-focus review --list`. Finish each unfinished campaign with `cc-focus review --resume ID`.
     Otherwise step 6 archives the campaign. Then a new campaign with the new plan path must cover its remaining targets.
   - Check that `git -C /srv/dev/projects/Interlink worktree list` shows only the main checkout. Finish or remove the queue worktrees.
     Keep a worktree only when you must, and repair it in step 4.
     If the repository is a colocated Jujutsu repository, also check `jj workspace list`.
   - Check that the code checkout is clean.
   Stopping point: safe, the old setup still works.
2. **Install the runtime.** Run `cc-sync` from Orchestra. Stopping point: safe.
3. **Split the repositories.**
   - Make regular clones with their own `.git` directory. Do not use linked worktrees or a separate Git directory.
   - In each new repository, commit a `.gitignore` with `.work/`, `.inbox/`, and `.claude/settings.local.json`.
   - Commit `Interlink-docs/project/AGENTS.md` and `Interlink-docs/project/CLAUDE.md` with the project-root instructions:
     the plan path, the members, and the directory of the commands.
   - In the plan repository, write references to code as paths from the project root, for example `Interlink/src/...`.
     Name the directory of each verification command. The last completed stage must show as complete.
   - Add these changes to the removal commit of the code repository:
     - Rewrite `AGENTS.md` and `CLAUDE.md`. They must not describe plans or documentation inside the repository.
     - Name the directory of each verification command.
     - Update the scripts and the CI jobs that read the moved files.
     - If the tool configuration of step 4 must not stay, save a copy outside the repositories. Then remove the originals in this commit.
   - Push each of the three repositories with `git push -u origin main`.
   - Check each repository with `git status -sb`: `## main...origin/main` with no ahead or behind mark, and one push URL.
   Stopping point: the push that removes the plans and the documentation from the code repository cannot be undone easily.
4. **Make the project root.** Check that `/srv/dev/projects/Interlink.code` and `/srv/dev/projects/Interlink.project` do not exist.
   ```sh
   mv /srv/dev/projects/Interlink /srv/dev/projects/Interlink.code
   mkdir /srv/dev/projects/Interlink
   mv /srv/dev/projects/Interlink.code /srv/dev/projects/Interlink/Interlink
   ```
   - Put `Interlink-docs` and `Interlink-plans` into `/srv/dev/projects/Interlink`.
   - Do not run `git worktree prune`. For each worktree that you kept in step 1, run `git worktree repair` with its new path.
   - Copy tool configuration that must stay active to the project root, for example `.claude/settings.json` or `.mcp.json`.
     - The roles now run in the project root, so these files in the code repository stop loading.
     - Adjust the relative paths in the copies.
     - If step 3 removed the originals, use the copy that you saved in step 3.
     - Do not delete the originals now. A removal must be part of the step 3 commit.
   - Root files are sealed project context. Do not keep files there that tools change, for example `.claude/settings.local.json`.
   Stopping point: local, reversible.
5. **Write the project files.** Run these commands in `/srv/dev/projects/Interlink`:
   ```sh
   cd /srv/dev/projects/Interlink
   printf '%s\n' '{"version": 1, "repositories": ["Interlink", "Interlink-docs", "Interlink-plans"], "parallel": ["Interlink-docs", "Interlink-plans"]}' > focus-project.json
   ln -s Interlink-docs/project/AGENTS.md AGENTS.md
   ln -s Interlink-docs/project/CLAUDE.md CLAUDE.md
   ```
   - Do not use `ln -f`. `focus-project.json` must be a regular file.
   - The key `parallel` lists the members with other writers. `plans/FOCUS_PARALLEL_MEMBERS_PLAN.md` describes its rules.
   - A link itself can change only before the first run or at a completed-stage pause. Its target changes like any member file.
   - Regular root files are the alternative. Reconcile can accept their changes, but they have no version control.
   Stopping point: local, reversible.
6. **Archive the old state.**
   ```sh
   mkdir -p /srv/dev/projects/Interlink/.work
   mv /srv/dev/projects/Interlink/Interlink/.work/cycle /srv/dev/projects/Interlink/.work/single-repository-archive
   rm -f /srv/dev/projects/Interlink/*/.work/PAUSE
   ```
   The project-root `.work/` is excluded from the project context. Stopping point: local, reversible.
   Before step 11, use these commands to undo steps 4 to 6. After step 11, first do the extra move in step 11.
   The undo restores only the layout, because the step 3 push stays.
   ```sh
   mv /srv/dev/projects/Interlink/.work/single-repository-archive /srv/dev/projects/Interlink/Interlink/.work/cycle
   mv /srv/dev/projects/Interlink /srv/dev/projects/Interlink.project
   mv /srv/dev/projects/Interlink.project/Interlink /srv/dev/projects/Interlink
   ```
7. **Configure the members.** `cc-config` is optional for cc-focus. A member needs `constraints.md` only for required checks or rules.
   - When CI jobs moved between repositories, update the required check names in each member `.work/constraints.md`.
   - Make sure that each workflow runs on every push to main.
   - In `Interlink-docs` and `Interlink-plans`, a main workflow must not cancel earlier runs.
   Stopping point: safe, no model.
8. **Check the repositories.** For each member `M`, use `git -C /srv/dev/projects/Interlink/M`:
   - `git status --porcelain` shows nothing.
   - After `git fetch`, `git rev-parse HEAD` equals `git rev-parse @{u}`.
   - `git remote get-url --all --push origin` shows one URL.
   - cc-focus compares main with the push URL through `git ls-remote`. If the remote has a separate push URL, compare with it.
   Stopping point: safe, no model.
9. **Check without a model.** At the project root, run
   `cc-focus review --plan Interlink-plans/plan/s2-adaptation.md --scope "migration preflight" --preview`.
   It checks the layout, the main branch of each member, and the plan path. It starts no model. Then run `cc-focus status`.
   Stopping point: safe, no model.
10. **Set the brief.** Run `cc-focus brief set FILE` at the project root. Keep the file outside the project.
    Stopping point: safe, no model. The brief is now in `/srv/dev/projects/Interlink/.work/cycle`.
11. **Start the first run.** Run `cc-focus --handoff FILE` at the project root. Keep the handoff outside the project. It names:
    - the plan path and the last completed stage
    - the unfinished work and the verification commands with their directories
    - the map from old paths to new paths

    Stopping point: the project store now exists in `/srv/dev/projects/Interlink/.work/cycle` and records the members.
    A later change of the members in `focus-project.json` stops the run with `project-layout-changed`.
    Change the members only with a new store.

    The run also made `/srv/dev/projects/Interlink/Interlink/.work/cycle` for the member lock and the owner record.
    To undo the migration after this step, first move that directory to `/srv/dev/projects/Interlink/.work/member-store-Interlink`.
    Then use the undo commands of step 6. The project store moves with `/srv/dev/projects/Interlink.project`.
12. **Verify the first stage.** After the publication, check with `cc-focus status` the publication and the CI result of each changed member.
    Stopping point: the completed first stage.

The guide also gives this advice to the operator:

- Always run cc-focus at the project root. A run inside a member is a separate single-repository cycle.
- The iteration counter starts again at 1. The old review campaigns stay in the archive.
- Publication across repositories is not atomic. The runtime finishes an interrupted publication.
- All members of one publication get the same commit subject.
- With a root link, an edit of the link target changes the root instructions. Check such edits in the reviews and the published commits.
- Keep each repository owned by the user that runs cc-focus, and check `gh` access to the new repositories.
- Other agents work in their own clones outside `/srv/dev/projects/Interlink`, on their own branches. Never in the checkouts of cc-focus.
- In the active plan, only cc-focus changes the status of stages. Keep an empty line around each status line.

## Documentation

- `docs/sequential-cycle.md`: the migration section, and the instruction list in the project-mode section.
  A sentence in "Paired review protocol and context" and in "Passing context without priming the final pair" states that the list is neutral current source.
- `knowledge.md`: the function, the field, and the marker.
- `docs/focus-instruction-style-audit.md`: an addendum that assesses all 53 rules for the new text.

## Implementation steps

1. `tools/focus_project.py`: the list from the current files.
2. `tools/focus_pair_view.py` or `tools/focus_pairs.py`: the list from a frozen view.
3. `tools/cycle_prompts.py`: `PROJECT_INSTRUCTIONS_RULE`. `tools/check_focus_instructions.py`: scan it.
4. `tools/focus_publication.py`: the field in `ProjectCycle.context`.
5. `tools/focus_pairs.py`, `tools/focus_pair_repair.py`, `tools/focus_repair_evidence.py`: the marker, its copies, and the reader field.
   `tools/cycle_workflow.py`: `RUNTIME_VERSION_BLOCKERS` and the reason `runtime-version`.
6. Tests in `tests/test_focus_project.py`, `tests/test_focus_instructions.py`, and the routing test in `tests/test_cycle.py`.
7. Documentation.

## Out of scope

- The split of the Interlink repositories, their history, and the changes in the Interlink repositories.
- An admission check for member upstreams. It would stop projects with a local-only member. The guide checks the upstreams in step 8.
- Instruction files for pair readers in single-repository mode.
- A plan-location setting for single-repository mode. Project mode covers the need.
- Changes to models, efforts, review targets, or CI requirements.
