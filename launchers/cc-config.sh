#!/usr/bin/env bash
# Seed .work/config.md from the copyable block in config.example.md (the lines
# between the "# >>> config.md seed start" / "# <<< config.md seed end" markers
# inside its fenced code block) if no config exists yet - NOT the whole document
# (headings/prose/tables are never copied). An existing .work/config.md is NEVER
# overwritten.

if [ -f ".work/config.md" ]; then
  echo ".work/config.md already exists - leaving it unchanged."
  exit 0
fi

# Directory of this script (works whether run from a repo checkout or from the
# ~/.claude/scripts mirror).
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"

# Look for the template next to launchers/ first (repo checkout layout: this file
# lives in launchers/, config.example.md one level up at the repo root), then fall
# back to alongside this script (mirror layout in ~/.claude/scripts, where cc-sync.sh
# also mirrors config.example.md flat next to the *.sh files).
TEMPLATE="$SCRIPT_DIR/../config.example.md"
if [ ! -f "$TEMPLATE" ]; then
  TEMPLATE="$SCRIPT_DIR/config.example.md"
fi
if [ ! -f "$TEMPLATE" ]; then
  echo "Failed to create .work/config.md (config.example.md missing next to launchers?)."
  exit 1
fi

mkdir -p ".work"

# Extract only the lines strictly between the seed markers (both markers excluded).
seed="$(awk '
  /^# >>> config\.md seed start/ { f=1; next }
  /^# <<< config\.md seed end/   { f=0 }
  f
' "$TEMPLATE")"

if [ -z "$seed" ]; then
  echo "Failed to create .work/config.md (seed markers not found in config.example.md?)."
  exit 1
fi

printf '%s\n' "$seed" > ".work/config.md"
echo "Created .work/config.md from config.example.md - edit it for this project."
