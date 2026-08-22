#!/usr/bin/env bash
LAUNCHER_DIR="${0%/*}"; [ "$LAUNCHER_DIR" = "$0" ] && LAUNCHER_DIR='.'
. "$LAUNCHER_DIR/cc-common.sh"
# Run the intelligent cross-project inbox curator on demand. Processor invokes the same
# role automatically at safe cohort boundaries; this launcher is the manual trigger.
CLAUDE_PERMISSION_MODE="$(orchestra_permission_mode)" || exit $?
case "$CLAUDE_PERMISSION_MODE" in
  auto|bypassPermissions) ;;
  *) printf 'Invalid ORCHESTRA_CLAUDE_PERMISSION_MODE "%s". Allowed: auto, bypassPermissions.\n' "$CLAUDE_PERMISSION_MODE" >&2; exit 2 ;;
esac
exec claude --agent inbox_curator --permission-mode "$CLAUDE_PERMISSION_MODE" "Per your system prompt, process this repository's cross-project inbox now. MODE=all. queue_write_mode=auto. ROOT=current repository root."
