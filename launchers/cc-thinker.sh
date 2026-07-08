#!/usr/bin/env bash
# Launch the "thinker" analytical partner in the current folder (Claude Code,
# auto mode). No fixed task: describe problems/ideas/goals in the chat and
# think together; thinker analyzes the project with you and turns agreed work into
# tasks in .work/Tasks_Queue.md. Optional: pass an opening topic as an argument.
#
# Unlike the Windows cc-thinker.cmd, no quote/%% sanitization is needed here: the
# POSIX shell already passes each argument through verbatim, and "$*" joins them into
# a single string without breaking the prompt's quoting. Contents of the argument
# (including any "$VAR" text) are NOT re-expanded, so quotes and special characters in
# typical input are preserved. Quote the argument so the shell keeps it as one token.
if [ "$#" -eq 0 ]; then
  # No predefined prompt: the agent launches and waits for the task in chat.
  exec claude --agent thinker --permission-mode auto
else
  exec claude --agent thinker --permission-mode auto "Per your system prompt: act as the analytical thinking partner for this project. Opening topic: $*"
fi
