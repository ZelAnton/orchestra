#!/usr/bin/env bash
# POSIX counterpart of cc-sync.cmd. Mirror this repository's agent definitions and
# launchers into the Claude Code environment so that `claude --agent <name>` and the
# cc-* launchers pick up the current versions.
#
# It mirrors (copy-over, never purge - other agents already in the mirror are kept):
#   - agent *.md from the agents/ folder      -> ~/.claude/agents
#   - launchers/*.sh (this folder)            -> ~/.claude/scripts
#   - config.example.md (repo root)           -> ~/.claude/scripts (so cc-config.sh
#                                                can find its template from the mirror)
#   - constraints.example.md (repo root)      -> ~/.claude/scripts (so cc-config.sh
#                                                can find its template from the mirror)
#
# Deliberate cross-platform choices (documented per task T-027):
#   * launchers/*.cmd are NOT mirrored on POSIX - they do not run there; only the *.sh
#     launchers are copied into ~/.claude/scripts.
#   * The Windows-only PowerShell pre-steps of cc-sync.cmd (generate-coders.cmd
#     regeneration of agents/coder.md, coder_fast.md, coder_deep.md from
#     agents/coder.template.md, and tools/validate-agents.ps1 invariant checks) are
#     skipped here. On POSIX this script mirrors the committed agents/coder*.md as-is. If
#     you edit agents/coder.template.md, regenerate the three variants on a machine with
#     PowerShell (generate-coders) - or commit the regenerated files - before syncing,
#     otherwise a stale on-disk copy is what gets mirrored.

set -u

# Directory of this script and the repo root above launchers/ (when run from a repo
# checkout). When run from the ~/.claude/scripts mirror instead, the parent has no
# agents/ folder / config.example.md, so those copy steps simply find nothing to copy.
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

# Agent definitions live under agents/ in the repo checkout (documentation stays in the
# repo root). From the launchers-only mirror this directory does not exist, and the
# copy loop below simply finds nothing.
AGENTS_SRC="$REPO_ROOT/agents"

AGENTS_DIR="$HOME/.claude/agents"
SCRIPTS_DIR="$HOME/.claude/scripts"

# Copy $1 onto $2, healing the "mirror entry is a directory, not a file" corruption that
# every copy step below is otherwise vulnerable to: with a plain `cp -f`, if the destination
# path is already a directory, POSIX cp does NOT refuse - it copies the source INSIDE that
# directory under its own basename (e.g. .../config.example.md/config.example.md), returns
# success, and the caller prints a false "Synced". This is the POSIX twin of the robocopy
# code-4 masking guarded in cc-sync.cmd (task T-056). An EMPTY such directory is a stale
# husk: rmdir removes it (rmdir only ever succeeds on an empty directory) and the copy
# proceeds as usual. A NON-EMPTY one may hold real data, so it is reported as an explicit,
# path-named failure and left untouched - never a false "Synced". Returns 0 on a real copy,
# non-zero otherwise. Unlike cc-sync.cmd, this guard covers the agent/launcher loops too:
# each of those is a per-file `cp -f` with exactly the same directory-shadowing exposure.
mirror_file() {
  if [ -d "$2" ]; then
    if ! rmdir "$2" 2>/dev/null; then
      echo "Sync failed: \"$2\" is a non-empty directory blocking this mirror - inspect and remove it by hand, then re-run cc-sync."
      return 1
    fi
  fi
  cp -f "$1" "$2"
}

# 1) Mirror agent *.md from agents/ into ~/.claude/agents. Documentation lives in the
#    repo root (AGENTS.md, knowledge.md, README.md, config.example.md, plans/), NOT in
#    agents/, so the old growing documentation-exclusion list is gone. Same reduced
#    exclusion set as cc-sync.cmd's robocopy /XF list - only the two generator templates,
#    which sit in agents/ next to the real agents but are not themselves loadable:
#      coder.template.md    - "name: {{NAME}}" frontmatter would register a broken agent
#      reviewer.template.md - same: placeholder "name: {{NAME}}" frontmatter, not an agent
mkdir -p "$AGENTS_DIR"
agent_count=0
sync_failed=0
for f in "$AGENTS_SRC"/*.md; do
  [ -f "$f" ] || continue
  n="$(basename "$f")"
  case "$n" in
    coder.template.md|reviewer.template.md) continue ;;
  esac
  if mirror_file "$f" "$AGENTS_DIR/$n"; then
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
  if mirror_file "$f" "$SCRIPTS_DIR/$n"; then
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

# 3) Also mirror config.example.md and constraints.example.md next to the launchers in
#    scripts/, so that cc-config.sh (run from the mirror, off PATH) can find its
#    templates via its own dir.
if [ -f "$REPO_ROOT/config.example.md" ]; then
  if mirror_file "$REPO_ROOT/config.example.md" "$SCRIPTS_DIR/config.example.md"; then
    echo "Synced config.example.md -> $SCRIPTS_DIR"
  else
    echo "Sync failed: could not copy config.example.md."
  fi
fi

if [ -f "$REPO_ROOT/constraints.example.md" ]; then
  if mirror_file "$REPO_ROOT/constraints.example.md" "$SCRIPTS_DIR/constraints.example.md"; then
    echo "Synced constraints.example.md -> $SCRIPTS_DIR"
  else
    echo "Sync failed: could not copy constraints.example.md."
  fi
fi
