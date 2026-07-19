#!/usr/bin/env bash
# Run the processor orchestrator in the current folder (Claude Code, auto mode).
# Processes the .work/Tasks_Queue.md queue in parallel batches end to end.
#
# Optional flags (any order, before the remaining arguments):
#   --force-lock     operator force-takeover of the lease: remove the lease directory
#                    .work/orchestrator.lock (with its lease.json) before starting -
#                    only if you are sure the previous processor is no longer running.
#                    A safe auto-takeover (on a provably stale lease) needs no flag;
#                    --force-lock is the explicit operator confirmation.
#   --model <name>   override the agent model (if supported by your claude version -
#                    check `claude --help`; the --agent + --model combination is not
#                    100% documented).
#
# The remaining arguments are flags for claude itself (short tokens like --flag/value),
# NOT free-form task-description text like in cc-queue.sh/cc-thinker.sh - so plain flag
# names and their values pass through as-is; do not put arbitrary quoted prose here.

MODEL_ARG=()
EXTRA_ARGS=()

# Agent builds are isolated runs: do not leave reusable .NET build workers behind.
export MSBUILDDISABLENODEREUSE=1
export DOTNET_CLI_USE_MSBUILD_SERVER=0
# Codex xhigh reviews can exceed Claude Code's short Bash default. Auto-backgrounding
# appends `&`, which no longer matches the pre-granted foreground runtime call. Preserve
# explicit user/system overrides; otherwise allow the bounded 30-minute runtime call plus
# shutdown overhead to finish in the foreground.
export BASH_DEFAULT_TIMEOUT_MS="${BASH_DEFAULT_TIMEOUT_MS:-1900000}"
export BASH_MAX_TIMEOUT_MS="${BASH_MAX_TIMEOUT_MS:-1900000}"

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

# --allowedTools grants: pre-granted session permission for the codex adapters
# (coder_codex/reviewer_codex) to run codex autonomously. Running this launcher IS the
# user's consent; without a covering grant the auto-mode classifier rejects the call
# mid-run as "launching an autonomous agent" (see agents/coder_codex.md). Two prefix
# grants are passed (allow-rules match by the literal Bash command-string prefix):
#   Bash(pwsh -File tools/codex-runtime.ps1:*) - the string the Bash tool ACTUALLY runs.
#     The adapters no longer invoke `codex exec` as a bare Bash command; they drive codex
#     through the runtime wrapper `pwsh -File tools/codex-runtime.ps1 <run|guard-commit|
#     cleanup|classify|check-diff|validate-reviewer|broker-validate|map-sentinel> ...`, so
#     this single prefix covers every runtime subcommand. `codex exec` itself is spawned by
#     the runtime as a child process (.NET ProcessStartInfo) and never passes through the
#     Bash permission gate - hence granting only `Bash(codex exec:*)` would leave every
#     adapter call blocked (fixed here, review finding R-01).
#   Bash(codex exec:*) - retained as the canonical codex-autonomy anchor that
#     CC_CODEX_EXEC_GRANT names and that the Phase 1.1 gate / cc-doctor / cc-config settings
#     rule still key off; harmless when codex is not invoked as a bare Bash command directly.
# The grants sit BEFORE --permission-mode: --allowedTools is variadic and, with no
# following flag to stop it, would swallow the positional prompt. --permission-mode auto is
# kept unchanged.
#
# CC_CODEX_EXEC_GRANT="codex exec": an explicit, verifiable signal that this session
# pre-granted autonomous codex above via --allowedTools. This is the single
# launcher->processor contract (Phase 1.1 of processor.md and cc-doctor read the same
# variable): its value is the canonical granted codex command prefix, which those readers
# compare against the adapters' `<CODEX_CMD> exec` command prefix - so it stays "codex exec"
# (do NOT retarget it to the pwsh wrapper, or that prefix check would stop matching and the
# Phase 1.1 gate would refuse to open the cohort). With it present, the Phase 1.1 gate needs
# no duplicate persistent allow-rule in the settings files and does not re-run the static
# search.
export CC_CODEX_EXEC_GRANT="codex exec"
if [ -n "${CC_PROCESSKIT_PYTHON:-}" ]; then
  if ! "$CC_PROCESSKIT_PYTHON" -c 'import processkit' >/dev/null 2>&1; then
    echo "CC_PROCESSKIT_PYTHON is set but processkit cannot be imported: $CC_PROCESSKIT_PYTHON" >&2
    exit 10
  fi
  exec "$CC_PROCESSKIT_PYTHON" -m processkit run -- claude --agent processor "${MODEL_ARG[@]}" "${EXTRA_ARGS[@]}" --allowedTools "Bash(codex exec:*)" "Bash(pwsh -File tools/codex-runtime.ps1:*)" --permission-mode auto "Start now, following your system prompt: take the orchestrator lock, then process .work/Tasks_Queue.md end to end — capture batches of parallel-safe tasks, plan them, implement in parallel worktrees, review, merge via the merger, and publish (ff-merge + push + CI), looping until no not-started tasks remain. Report progress as you go."
fi
exec claude --agent processor "${MODEL_ARG[@]}" "${EXTRA_ARGS[@]}" --allowedTools "Bash(codex exec:*)" "Bash(pwsh -File tools/codex-runtime.ps1:*)" --permission-mode auto "Start now, following your system prompt: take the orchestrator lock, then process .work/Tasks_Queue.md end to end — capture batches of parallel-safe tasks, plan them, implement in parallel worktrees, review, merge via the merger, and publish (ff-merge + push + CI), looping until no not-started tasks remain. Report progress as you go."
