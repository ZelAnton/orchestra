#!/usr/bin/env bash
# Run queue_builder in the current folder (Claude Code, auto mode).
# Enqueues tasks into .work/Tasks_Queue.md. The source can be passed as an argument:
#   cc-queue docs/roadmap.md      or     cc-queue "add rate limiting to the API"
#
# Unlike the Windows cc-queue.cmd, no quote/%% sanitization is needed here: the POSIX
# shell already passes each argument through verbatim, and "$*" joins them into a
# single string without breaking the prompt's quoting. Contents of the argument
# (including any "$VAR" text) are NOT re-expanded, so quotes and special characters in
# typical input are preserved. Quote the argument so the shell keeps it as one token.
if [ "$#" -eq 0 ]; then
  exec claude --agent queue_builder --permission-mode auto "Per your system prompt, ask me for the source (file/spec/backlog) or task description to enqueue into .work/Tasks_Queue.md - none was given on the command line."
else
  exec claude --agent queue_builder --permission-mode auto "Per your system prompt, add tasks to .work/Tasks_Queue.md. Task source or description: $*"
fi
