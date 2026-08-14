#!/usr/bin/env bash
# Launch the "thinker" analytical partner in the current folder through Claude
# (compatibility default) or the normal interactive Codex TUI.

PROVIDER="${ORCHESTRA_PROVIDER:-claude}"

case "${1:-}" in
  claude|codex)
    PROVIDER="$1"
    shift
    ;;
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
    CLAUDE_PERMISSION_MODE="${ORCHESTRA_CLAUDE_PERMISSION_MODE:-auto}"
    case "$CLAUDE_PERMISSION_MODE" in
      auto|bypassPermissions) ;;
      *) printf 'Invalid ORCHESTRA_CLAUDE_PERMISSION_MODE "%s". Allowed: auto, bypassPermissions.\n' "$CLAUDE_PERMISSION_MODE" >&2; exit 2 ;;
    esac
    if [ "$#" -eq 0 ]; then
      exec claude --agent thinker --permission-mode "$CLAUDE_PERMISSION_MODE"
    fi
    exec claude --agent thinker --permission-mode "$CLAUDE_PERMISSION_MODE" "Per your system prompt: act as the analytical thinking partner for this project. Opening topic: $*"
    ;;
  codex)
    SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
    PROJECT_ROOT="$(pwd -P)"
    CODEX_ROLE_RUNTIME="$SCRIPT_DIR/../tools/codex-role-runtime.ps1"
    if [ ! -f "$CODEX_ROLE_RUNTIME" ]; then
      CODEX_ROLE_RUNTIME="$SCRIPT_DIR/codex-role-runtime.ps1"
    fi
    if [ ! -f "$CODEX_ROLE_RUNTIME" ]; then
      printf '%s\n' 'Codex role runtime not found. Run cc-sync from the Orchestra checkout.' >&2
      exit 12
    fi
    export ORCHESTRA_CODEX_ROLE_TOPIC="$*"
    exec pwsh -NoProfile -File "$CODEX_ROLE_RUNTIME" -Role thinker -Root "$PROJECT_ROOT" -RequestedProvider codex
    ;;
  *)
    printf 'Invalid provider "%s". Allowed: claude, codex.\n' "$PROVIDER" >&2
    exit 2
    ;;
esac
