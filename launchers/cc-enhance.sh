#!/usr/bin/env bash
# Run enhancement_scout in the current folder (Claude Code, auto mode).
# Proposes project improvements and enqueues them as tasks in the queue.
exec claude --agent enhancement_scout --permission-mode auto "Per your system prompt, analyze the project and enqueue development/improvement proposals as separate tasks in .work/Tasks_Queue.md. Start now."
