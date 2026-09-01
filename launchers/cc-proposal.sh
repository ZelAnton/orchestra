#!/usr/bin/env bash
LAUNCHER_DIR="${0%/*}"; [ "$LAUNCHER_DIR" = "$0" ] && LAUNCHER_DIR='.'
. "$LAUNCHER_DIR/cc-common.sh"
# Run proposal_curator in the current folder (Claude Code).
# Batch-curates the new P-NNN proposals (kind: proposal) in the backlog: decides one
# outcome for each proposed proposal and creates tasks from the converted ones.
CLAUDE_PERMISSION_MODE="$(orchestra_permission_mode)" || exit $?
case "$CLAUDE_PERMISSION_MODE" in
  auto|bypassPermissions) ;;
  *) printf 'Invalid ORCHESTRA_CLAUDE_PERMISSION_MODE "%s". Allowed: auto, bypassPermissions.\n' "$CLAUDE_PERMISSION_MODE" >&2; exit 2 ;;
esac
exec claude --agent proposal_curator --permission-mode "$CLAUDE_PERMISSION_MODE" "Per your system prompt, curate the new P-NNN proposals in .work/Tasks_Queue.md and decide one outcome for each proposed proposal. Start now."
