# Repository Guidelines

## Project Structure & Module Organization

This repository defines a Claude/Codex agent orchestra. Most root-level `*.md` files are agent definitions with YAML frontmatter and Russian instructions. `processor.md` orchestrates specialized planner, merger, reviewer, and coder roles. `coder.template.md` generates the three Claude coder variants. `config.example.md` documents `.work/config.md`; Windows entry points live in `launchers/`. Runtime state belongs in a consuming project's `.work/`, not here.

## Project Knowledge

Read `knowledge.md` before exploring or changing the repository. Use its map of ownership, control flow, runtime artifacts, and pitfalls to target source checks. Update it alongside changes to locations, responsibilities, phases, configuration, launchers, or invariants. It documents Orchestra itself; generated `.work/knowledge/` describes a consuming project.

## Build, Test, and Development Commands

- `powershell -NoProfile -ExecutionPolicy Bypass -File .\generate-coders.ps1` regenerates all Claude coder variants after editing the template.
- `git diff --exit-code -- coder.md coder_fast.md coder_deep.md` checks that regeneration produced no unexpected drift.
- `launchers\cc-doctor.cmd` performs the read-only Codex/configuration preflight when run from a target project root.
- `launchers\cc-processor.cmd` starts the end-to-end queue processor in a configured target project.

There is no compiled build or automated test suite. Validate changes by regenerating derived files, inspecting `git diff`, and smoke-testing the affected launcher or agent flow in a disposable target repository.

## Coding Style & Naming Conventions

Keep Markdown instructions direct, imperative, and consistent with the existing Russian terminology. Preserve YAML frontmatter as the first bytes of agent files; files must be UTF-8 without BOM. Use lowercase snake_case for agent names and files (`knowledge_curator.md`) and the `cc-<action>.cmd` pattern for launchers. Use four-space indentation in PowerShell blocks and uppercase snake case for configuration keys such as `REVIEW_LOOP_MAX`.

Do not edit generated coder variants independently. Change `coder.template.md` or the variant metadata in `generate-coders.ps1`, regenerate, and review all three outputs.

## Testing Guidelines

Test role boundaries: file ownership, VCS permissions, status transitions, retry limits, and fallbacks. For launchers, verify argument parsing and failures. Use a disposable repository for destructive flow tests.

## Commit & Pull Request Guidelines

History uses short, imperative subjects such as `Add orchestrator agent configs and CLI launchers`. Keep commits focused. Pull requests should name affected roles, changed invariants, compatibility impact, and validation. Link issues and include terminal output for launcher changes.
