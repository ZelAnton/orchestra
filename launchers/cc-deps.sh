#!/usr/bin/env bash
LAUNCHER_DIR="${0%/*}"; [ "$LAUNCHER_DIR" = "$0" ] && LAUNCHER_DIR='.'
. "$LAUNCHER_DIR/cc-common.sh"
# Reconcile the current repository's products/direct dependencies into the user registry.
CLAUDE_PERMISSION_MODE="$(orchestra_permission_mode)" || exit $?
case "$CLAUDE_PERMISSION_MODE" in
  auto|bypassPermissions) ;;
  *) printf 'Invalid ORCHESTRA_CLAUDE_PERMISSION_MODE "%s". Allowed: auto, bypassPermissions.\n' "$CLAUDE_PERMISSION_MODE" >&2; exit 2 ;;
esac
exec claude --agent dependency_curator --permission-mode "$CLAUDE_PERMISSION_MODE" "Per your system prompt, refresh this repository's dependency graph now. MODE=refresh. CALLER=manual. ROOT=current repository root. WORK=.work. BASE=current committed trunk tip."
