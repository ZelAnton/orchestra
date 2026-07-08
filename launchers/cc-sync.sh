#!/usr/bin/env bash
# POSIX counterpart of cc-sync.cmd. Mirror this repository's agent definitions and
# launchers into the Claude Code environment so that `claude --agent <name>` and the
# cc-* launchers pick up the current versions.
#
# It mirrors (copy-over, never purge - other agents already in the mirror are kept):
#   - top-level agent *.md from the repo root -> ~/.claude/agents
#   - launchers/*.sh (this folder)            -> ~/.claude/scripts
#   - config.example.md                       -> ~/.claude/scripts (so cc-config.sh
#                                                can find its template from the mirror)
#
# Deliberate cross-platform choices (documented per task T-027):
#   * launchers/*.cmd are NOT mirrored on POSIX - they do not run there; only the *.sh
#     launchers are copied into ~/.claude/scripts.
#   * The Windows-only PowerShell pre-steps of cc-sync.cmd (generate-coders.cmd
#     regeneration of coder.md/coder_fast.md/coder_deep.md from coder.template.md, and
#     tools/validate-agents.ps1 invariant checks) are skipped here. On POSIX this
#     script mirrors the committed coder*.md as-is. If you edit coder.template.md,
#     regenerate the three variants on a machine with PowerShell (generate-coders) - or
#     commit the regenerated files - before syncing, otherwise a stale on-disk copy is
#     what gets mirrored.

set -u

# Directory of this script and the repo root above launchers/ (when run from a repo
# checkout). When run from the ~/.claude/scripts mirror instead, the parent has no
# agent .md / config.example.md, so those copy steps simply find nothing to copy.
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

AGENTS_DIR="$HOME/.claude/agents"
SCRIPTS_DIR="$HOME/.claude/scripts"

# 1) Mirror top-level agent *.md into ~/.claude/agents. Same exclusion set as
#    cc-sync.cmd's robocopy /XF list:
#      coder.template.md   - "name: {{NAME}}" frontmatter would register a broken agent
#      config.example.md   - not an agent; mirrored separately below into scripts/
#      AGENTS.md/knowledge.md/README.md/*_PLAN.md/*_ROADMAP.md - repo docs, not agents
#      Orchestra_Review_*.md - dated review reports, not agents
mkdir -p "$AGENTS_DIR"
agent_count=0
sync_failed=0
for f in "$REPO_ROOT"/*.md; do
  [ -f "$f" ] || continue
  n="$(basename "$f")"
  case "$n" in
    coder.template.md|config.example.md|AGENTS.md|knowledge.md|README.md) continue ;;
    *_PLAN.md|*_ROADMAP.md|Orchestra_Review_*.md) continue ;;
  esac
  if cp -f "$f" "$AGENTS_DIR/$n"; then
    agent_count=$((agent_count + 1))
  else
    sync_failed=1
  fi
done
if [ "$sync_failed" -ne 0 ]; then
  echo "Sync failed: could not copy one or more agent definitions."
else
  echo "Synced $agent_count agent definition(s) -> $AGENTS_DIR"
fi

# 2) Mirror the launchers themselves (this folder's *.sh) into ~/.claude/scripts,
#    which is where they are invoked from on PATH. Keep them executable.
mkdir -p "$SCRIPTS_DIR"
launcher_count=0
sync_failed=0
for f in "$SCRIPT_DIR"/*.sh; do
  [ -f "$f" ] || continue
  n="$(basename "$f")"
  if cp -f "$f" "$SCRIPTS_DIR/$n"; then
    chmod +x "$SCRIPTS_DIR/$n" 2>/dev/null || true
    launcher_count=$((launcher_count + 1))
  else
    sync_failed=1
  fi
done
if [ "$sync_failed" -ne 0 ]; then
  echo "Sync failed: could not copy one or more launcher scripts."
else
  echo "Synced $launcher_count launcher script(s) -> $SCRIPTS_DIR"
fi

# 3) Also mirror config.example.md next to the launchers in scripts/, so that
#    cc-config.sh (run from the mirror, off PATH) can find its template via its own dir.
if [ -f "$REPO_ROOT/config.example.md" ]; then
  if cp -f "$REPO_ROOT/config.example.md" "$SCRIPTS_DIR/config.example.md"; then
    echo "Synced config.example.md -> $SCRIPTS_DIR"
  else
    echo "Sync failed: could not copy config.example.md."
  fi
fi
