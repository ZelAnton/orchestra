#!/usr/bin/env bash
# Resume an interrupted processor session in the current folder (the most recent
# Claude Code session here, via --continue) instead of a cold start from scratch.
# processor can recover from scratch anyway (Фаза 0 of its system prompt), but
# --continue saves re-discovering context when the session is still alive.
#
# On resume, processor reuses ITS OWN lock (.work/orchestrator.lock of the same
# session) - so cc-resume normally just continues; no need to remove the lock. If a
# DIFFERENT, genuinely dead session left the lock and resume trips over it, run
# cc-processor.sh --force-lock only after confirming that processor is not running.
#
# WARNING: --continue picks up the MOST RECENT Claude Code session in this directory,
# whatever it is. Do not run other cc-* launchers or an interactive claude between
# the crash and cc-resume - otherwise --continue resumes their session, not processor.
# --allowedTools grants: pre-granted session permission for the codex adapters to run
# codex autonomously (same set as cc-processor.sh) - otherwise the auto-mode classifier
# rejects the call mid-run on resume. Two prefix grants are passed:
#   Bash(pwsh -File tools/codex-runtime.ps1:*) - the string the Bash tool ACTUALLY runs:
#     the adapters drive codex through the runtime wrapper
#     `pwsh -File tools/codex-runtime.ps1 <subcommand> ...`, so this one prefix covers every
#     runtime subcommand; `codex exec` is spawned by the runtime as a child process and does
#     not pass through the Bash permission gate (review finding R-01).
#   Bash(codex exec:*) - the canonical codex-autonomy anchor CC_CODEX_EXEC_GRANT names and
#     that the Phase 1.1 gate / cc-doctor / cc-config settings rule key off.
# They sit BEFORE --permission-mode (the variadic flag must not swallow the following
# tokens). --permission-mode auto and --continue unchanged.
# CC_CODEX_EXEC_GRANT="codex exec": the same single launcher->processor contract as in
# cc-processor.sh - an explicit signal of the already-issued session grant that the Phase
# 1.1 gate and cc-doctor read; its value stays the canonical "codex exec" prefix they
# compare against `<CODEX_CMD> exec` (not the pwsh wrapper). With it, no persistent
# allow-rule is required.
export CC_CODEX_EXEC_GRANT="codex exec"
exec claude --agent processor --allowedTools "Bash(codex exec:*)" "Bash(pwsh -File tools/codex-runtime.ps1:*)" --permission-mode auto --continue "Continue processing .work/Tasks_Queue.md from where you left off, per your system prompt's Фаза 0 recovery logic."
