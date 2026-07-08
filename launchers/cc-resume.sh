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
exec claude --agent processor --permission-mode auto --continue "Continue processing .work/Tasks_Queue.md from where you left off, per your system prompt's Фаза 0 recovery logic."
