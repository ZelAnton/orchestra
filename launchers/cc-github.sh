#!/usr/bin/env bash
LAUNCHER_DIR="${0%/*}"; [ "$LAUNCHER_DIR" = "$0" ] && LAUNCHER_DIR='.'
. "$LAUNCHER_DIR/cc-common.sh"
# Run github_sync in the current folder (Claude Code). Requires an
# authenticated gh CLI. Enqueues tasks from open issues/PRs and closes the ones that
# are done (PRs are always closed, never merged).
# No predefined prompt: the agent launches and waits for the task in chat.
CLAUDE_PERMISSION_MODE="$(orchestra_permission_mode)" || exit $?
case "$CLAUDE_PERMISSION_MODE" in
  auto|bypassPermissions) ;;
  *) printf 'Invalid ORCHESTRA_CLAUDE_PERMISSION_MODE "%s". Allowed: auto, bypassPermissions.\n' "$CLAUDE_PERMISSION_MODE" >&2; exit 2 ;;
esac
exec claude --agent github_sync --permission-mode "$CLAUDE_PERMISSION_MODE"
