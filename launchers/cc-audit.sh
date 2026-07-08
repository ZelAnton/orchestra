#!/usr/bin/env bash
# Run code_auditor in the current folder (Claude Code, acceptEdits mode).
# Audits the repository source code and enqueues each issue it finds as a task.
exec claude --agent code_auditor --permission-mode acceptEdits "Per your system prompt, audit the repository source code and enqueue each issue you find as a separate task in .work/Tasks_Queue.md. Start now."
