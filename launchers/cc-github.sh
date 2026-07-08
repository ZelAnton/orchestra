#!/usr/bin/env bash
# Run github_sync in the current folder (Claude Code, auto mode). Requires an
# authenticated gh CLI. Enqueues tasks from open issues/PRs and closes the ones that
# are done (PRs are always closed, never merged).
# No predefined prompt: the agent launches and waits for the task in chat.
exec claude --agent github_sync --permission-mode auto
