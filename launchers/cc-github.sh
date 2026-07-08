#!/usr/bin/env bash
# Run github_sync in the current folder (Claude Code, acceptEdits mode). Requires an
# authenticated gh CLI. Enqueues tasks from open issues/PRs and closes the ones that
# are done (PRs are always closed, never merged).
exec claude --agent github_sync --permission-mode acceptEdits "Per your system prompt, sync GitHub with the task queue: enqueue tasks from open issues/PRs and close the ones that are done. Start now."
