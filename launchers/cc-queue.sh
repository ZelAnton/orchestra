#!/usr/bin/env bash
LAUNCHER_DIR="${0%/*}"; [ "$LAUNCHER_DIR" = "$0" ] && LAUNCHER_DIR='.'
. "$LAUNCHER_DIR/cc-common.sh"
# Run queue_builder in the current folder (Claude Code).
# Enqueues tasks into .work/Tasks_Queue.md. The source can be passed as an argument:
#   cc-queue docs/roadmap.md      or     cc-queue "add rate limiting to the API"
#
# Unlike the Windows cc-queue.cmd, no quote/%% sanitization is needed here: the POSIX
# shell already passes each argument through verbatim, and "$*" joins them into a
# single string without breaking the prompt's quoting. Contents of the argument
# (including any "$VAR" text) are NOT re-expanded, so quotes and special characters in
# typical input are preserved. Quote the argument so the shell keeps it as one token.
CLAUDE_PERMISSION_MODE="$(orchestra_permission_mode)" || exit $?
case "$CLAUDE_PERMISSION_MODE" in
  auto|bypassPermissions) ;;
  *) printf 'Invalid ORCHESTRA_CLAUDE_PERMISSION_MODE "%s". Allowed: auto, bypassPermissions.\n' "$CLAUDE_PERMISSION_MODE" >&2; exit 2 ;;
esac
if [ "$#" -eq 0 ]; then
  # No predefined prompt: the agent launches and waits for the task in chat.
  exec claude --agent queue_builder --permission-mode "$CLAUDE_PERMISSION_MODE"
else
  exec claude --agent queue_builder --permission-mode "$CLAUDE_PERMISSION_MODE" "Per your system prompt, add tasks to .work/Tasks_Queue.md. Task source or description: $*"
fi
