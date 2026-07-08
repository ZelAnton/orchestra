#!/usr/bin/env bash
# Run the processor orchestrator in the current folder (Claude Code, acceptEdits mode).
# Processes the .work/Tasks_Queue.md queue in parallel batches end to end.
#
# Optional flags (any order, before the remaining arguments):
#   --force-lock     remove .work/orchestrator.lock before starting - only if you are
#                    sure the previous processor is no longer running.
#   --model <name>   override the agent model (if supported by your claude version -
#                    check `claude --help`; the --agent + --model combination is not
#                    100% documented).
#
# The remaining arguments are flags for claude itself (short tokens like --flag/value),
# NOT free-form task-description text like in cc-queue.sh/cc-thinker.sh - so plain flag
# names and their values pass through as-is; do not put arbitrary quoted prose here.

MODEL_ARG=()
EXTRA_ARGS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --force-lock)
      if [ -d ".work/orchestrator.lock" ]; then
        echo "Removing .work/orchestrator.lock - use only if you are sure the previous processor is not running."
        rm -rf ".work/orchestrator.lock"
      fi
      shift
      ;;
    --model)
      # Trailing --model with no value: do not swallow the next flag as the model -
      # just ignore it (matches cc-processor.cmd).
      if [ "$#" -lt 2 ]; then
        echo "Flag --model without a value - ignoring."
        shift
      else
        MODEL_ARG=(--model "$2")
        shift 2
      fi
      ;;
    *)
      # Other arguments pass through to claude as-is (after --model, before the prompt).
      EXTRA_ARGS+=("$1")
      shift
      ;;
  esac
done

exec claude --agent processor "${MODEL_ARG[@]}" "${EXTRA_ARGS[@]}" --permission-mode acceptEdits "Start now, following your system prompt: take the orchestrator lock, then process .work/Tasks_Queue.md end to end — capture batches of parallel-safe tasks, plan them, implement in parallel worktrees, review, merge via the merger, and publish (ff-merge + push + CI), looping until no not-started tasks remain. Report progress as you go."
