#!/usr/bin/env bash
# Run enhancement_scout in the current folder through Claude or the interactive Codex TUI.

PROVIDER="${ORCHESTRA_PROVIDER:-claude}"
case "${1:-}" in
  claude|codex) PROVIDER="$1"; shift ;;
  --provider)
    if [ "$#" -lt 2 ]; then
      printf '%s\n' 'Flag --provider requires a value.' >&2
      exit 2
    fi
    PROVIDER="$2"
    shift 2
    ;;
esac
case "$PROVIDER" in
  claude)
    exec claude --agent enhancement_scout --permission-mode auto "Per your system prompt, analyze the project and enqueue development/improvement proposals as separate tasks in .work/Tasks_Queue.md. Start now."
    ;;
  codex)
    SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
    PROJECT_ROOT="$(pwd -P)"
    CODEX_ROLE_RUNTIME="$SCRIPT_DIR/../tools/codex-role-runtime.ps1"
    if [ ! -f "$CODEX_ROLE_RUNTIME" ]; then CODEX_ROLE_RUNTIME="$SCRIPT_DIR/codex-role-runtime.ps1"; fi
    if [ ! -f "$CODEX_ROLE_RUNTIME" ]; then
      printf '%s\n' 'Codex role runtime not found. Run cc-sync from the Orchestra checkout.' >&2
      exit 12
    fi
    exec pwsh -NoProfile -File "$CODEX_ROLE_RUNTIME" -Role enhancement_scout -Root "$PROJECT_ROOT" -RequestedProvider codex
    ;;
  *) printf 'Invalid provider "%s". Allowed: claude, codex.\n' "$PROVIDER" >&2; exit 2 ;;
esac
