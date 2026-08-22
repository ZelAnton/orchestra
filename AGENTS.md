# Repository Guidelines

## Project Structure & Module Organization

This repository defines a Claude/Codex agent orchestra. Agent definitions (YAML frontmatter, Russian instructions) live in `agents/`; `agents/processor.md` orchestrates specialized planner, merger, reviewer, and coder roles. `agents/coder.template.md` generates the three Claude coder variants (`coder.md`, `coder_fast.md`, `coder_deep.md`), and `agents/reviewer.template.md` generates the two Claude reviewer variants (`reviewer.md`, `reviewer_std.md`). `generate-codex-agents.ps1` converts those canonical roles into the generated Codex-native package under `codex/`: `codex/processor.md` and namespaced `codex/agents/orchestra_*.toml`. Windows/POSIX entry points live in `launchers/`; provider runtimes live in `tools/`. Runtime state belongs in a consuming project's `.work/`, not here.

## Project Knowledge

Read `knowledge.md` before exploring or changing the repository. Use its map of ownership, control flow, runtime artifacts, and pitfalls to target source checks. Update it alongside changes to locations, responsibilities, phases, configuration, launchers, or invariants. It documents Orchestra itself; generated `.work/knowledge/` describes a consuming project.

## Hard Workspace Boundary

When Orchestra is the target of the task, `D:\GitHub\Personal\orchestra` is the only writable repository. Other projects may be inspected read-only to reproduce an Orchestra-generated pitfall or collect evidence, but never edit, format, commit, push, rebase, archive queue tasks, change leases, or mutate `.work/` in those projects. Their source code and task queues are diagnostic inputs, not an implementation backlog. Fix the originating behavior in Orchestra; if the cause cannot be fixed here, report the external requirement without applying it. Do not continue or complete tasks found in another project's queue unless the user starts a separate request that explicitly changes the target repository.

## Build, Test, and Development Commands

- `powershell -NoProfile -ExecutionPolicy Bypass -File .\generate-coders.ps1` regenerates all Claude coder and reviewer variants under `agents/` after editing either template.
- `pwsh -NoProfile -File .\generate-codex-agents.ps1` regenerates the Codex-native processor/custom-agent package after any canonical role change.
- `git diff --exit-code -- agents/coder.md agents/coder_fast.md agents/coder_deep.md agents/reviewer.md agents/reviewer_std.md` checks that regeneration produced no unexpected drift.
- `launchers\cc-doctor.cmd` performs the read-only Codex/configuration preflight when run from a target project root.
- `launchers\cc-processor.cmd` starts the end-to-end queue processor in a configured target project.

There is no compiled build. Run `pwsh -NoProfile -File .\tests\launchers\run-all.ps1` for the launcher/runtime regression suite, regenerate derived files, inspect `git diff`, and smoke-test affected destructive flows only in a disposable target repository.

## Coding Style & Naming Conventions

Keep Markdown instructions direct, imperative, and consistent with the existing Russian terminology. Preserve YAML frontmatter as the first bytes of agent files; files must be UTF-8 without BOM. Use lowercase snake_case for agent names and files (`knowledge_curator.md`) and the `cc-<action>.cmd` pattern for launchers. Use four-space indentation in PowerShell blocks and uppercase snake case for configuration keys such as `REVIEW_LOOP_MAX`. `.cmd` launchers must use Windows (CRLF) line endings; this is enforced by `.gitattributes` (`*.cmd text eol=crlf`), so a plain checkout is always correct — do not hand-fix line endings per file or per contributor.

Do not edit generated coder/reviewer variants or `codex/processor.md`/`codex/agents/orchestra_*.toml` independently. Change the canonical `agents/*.md`, its template/variant metadata, or the provider overlay in `generate-codex-agents.ps1`; regenerate and review all outputs.

All committed agent frontmatter (`permissionMode:`) must use `auto`, not `acceptEdits` or `bypassPermissions`. Claude launchers must resolve `--permission-mode` only through the strict `ORCHESTRA_CLAUDE_PERMISSION_MODE: auto|bypassPermissions` operator key in `~/.orchestra/root-config.md`, defaulting to `auto` and failing closed on every other value. A parent launched in `bypassPermissions` passes that effective mode to spawned subagents, so generated or installed role frontmatter must not be rewritten. `auto` is a supported value — it was previously (wrongly, see history of T-007 in `.work/Tasks_Done.md`) replaced repo-wide with `acceptEdits` on the mistaken belief that `auto` was unsupported/undocumented; that regressed every agent from `⏵⏵ auto mode` to `⏵⏵ accept edits`. Do not repeat that change. Agents must never set `ORCHESTRA_CLAUDE_PERMISSION_MODE` or relaunch themselves to widen permissions; only the operator may select `bypassPermissions`, and only in an appropriately isolated environment.

Consent for a risky autonomous Bash operation (launching the autonomous codex runtime, in either of its two layout forms - `pwsh -File tools/codex-runtime.ps1` from a repo checkout or `pwsh -File ~/.claude/scripts/codex-runtime.ps1` from a cc-sync mirror; publishing via `git push`/`gh`; destructive worktree/branch removal or `rm -rf` under `.work/`; an arbitrary per-project `SMOKE_CMD`; any commit/merge that touches `.claude/settings*`) is **pre-granted by the user** — through the launchers' session `--allowedTools` and/or settings seeded by `cc-config` — never self-granted by an agent. No agent may widen its own permissions: do not edit `.claude/settings*` and do not rephrase a command to dodge the auto-mode classifier. A mid-run permission refusal is handled by the normal escalation of the role where it happened (the Codex adapter's `CODEX_UNAVAILABLE`/`CODEX_FAILED` fallback; a processor/merger "manual intervention required" stop), not by halting the whole run. In `auto`, consent is not inherited through a subagent — the classifier rejects a parent's relayed consent, so a settings-touching operation is finalized by the role whose own context shows the consent. This is distinct from the explicit operator-selected `bypassPermissions` session mode, which Claude applies to the parent and its spawned subagents. The central persistent allow-list stays minimal (only the three codex rules `Bash(pwsh -File tools/codex-runtime.ps1 *)`, `Bash(pwsh -File ~/.claude/scripts/codex-runtime.ps1 *)`, and `Bash(codex exec *)`); ad-hoc/per-repository needs use an explicit local grant. See `knowledge.md` ("Разрешения auto-режима и политика «согласие — заранее»") for the full operation-by-operation audit.

The internal `.work/approvals` policy gate is separate from Claude/Codex tool permission.
`ORCHESTRA_AUTO_APPROVE: on`, set by the operator in `~/.orchestra/root-config.md`,
pre-grants those gates across projects. Agents must still call `policy.ps1`; the runtime
persists the one-time request and consumes it as
`root-config:ORCHESTRA_AUTO_APPROVE` only while its diff fingerprint, policy snapshot, and
deadline are fresh. Agents must never set this key for themselves. Unset/`off` keeps manual
approval; any other value fails closed.

## Testing Guidelines

Test role boundaries: file ownership, VCS permissions, status transitions, retry limits, and fallbacks. For launchers, verify argument parsing and failures. Use a disposable repository for destructive flow tests.

## Commit & Pull Request Guidelines

History uses short, imperative subjects such as `Add orchestrator agent configs and CLI launchers`. Keep commits focused. Pull requests should name affected roles, changed invariants, compatibility impact, and validation. Link issues and include terminal output for launcher changes.

### Task identifiers

Do not include task numbers or task identifiers (for example, `T-123` or
`#123`) in either the commit subject or the commit body.
