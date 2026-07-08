#!/usr/bin/env bash
# Seed .work/config.md and .work/constraints.md from the repo templates if they do not
# exist yet. An existing target file is NEVER overwritten (same guarantee for both).
#   - config.md: only the copyable block between the "# >>> config.md seed start" /
#     "# <<< config.md seed end" markers inside config.example.md's fenced code block
#     (headings/prose/tables are never copied).
#   - constraints.md: the WHOLE constraints.example.md (the entire document IS the policy
#     content - there is no seed block to slice, unlike config.md).

# Directory of this script (works whether run from a repo checkout or the ~/.claude/scripts
# mirror).
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"

mkdir -p ".work"

# Look for a template next to launchers/ first (repo checkout layout: this file lives in
# launchers/, the *.example.md one level up at the repo root), then alongside this script
# (mirror layout in ~/.claude/scripts, where cc-sync.sh mirrors the templates flat next to
# the *.sh files). Prints the resolved path, or nothing if neither exists.
find_template() {
  if [ -f "$SCRIPT_DIR/../$1" ]; then
    printf '%s\n' "$SCRIPT_DIR/../$1"
  elif [ -f "$SCRIPT_DIR/$1" ]; then
    printf '%s\n' "$SCRIPT_DIR/$1"
  fi
}

# --- config.md (seed only the marked block) ---
if [ -f ".work/config.md" ]; then
  echo ".work/config.md already exists - leaving it unchanged."
else
  TEMPLATE="$(find_template config.example.md)"
  if [ -z "$TEMPLATE" ]; then
    echo "Failed to create .work/config.md (config.example.md missing next to launchers?)."
  else
    # Extract only the lines strictly between the seed markers (both markers excluded).
    seed="$(awk '
      /^# >>> config\.md seed start/ { f=1; next }
      /^# <<< config\.md seed end/   { f=0 }
      f
    ' "$TEMPLATE")"
    if [ -z "$seed" ]; then
      echo "Failed to create .work/config.md (seed markers not found in config.example.md?)."
    else
      printf '%s\n' "$seed" > ".work/config.md"
      echo "Created .work/config.md from config.example.md - edit it for this project."
    fi
  fi
fi

# --- constraints.md (copy the WHOLE file; plain cp preserves the BOM-less UTF-8 bytes) ---
if [ -f ".work/constraints.md" ]; then
  echo ".work/constraints.md already exists - leaving it unchanged."
else
  TEMPLATE="$(find_template constraints.example.md)"
  if [ -z "$TEMPLATE" ]; then
    echo "Failed to create .work/constraints.md (constraints.example.md missing next to launchers?)."
  elif cp -f "$TEMPLATE" ".work/constraints.md"; then
    echo "Created .work/constraints.md from constraints.example.md - edit it for this project."
  else
    echo "Failed to create .work/constraints.md."
  fi
fi
