#!/usr/bin/env bash
# Seed .work/config.md and .work/constraints.md from the repo templates if they do not
# exist yet, and seed a Claude Code allow-rule for autonomous `codex exec` into
# .claude/settings.local.json. An existing target file is NEVER overwritten wholesale
# (same guarantee for all three).
#   - config.md: only the copyable block between the "# >>> config.md seed start" /
#     "# <<< config.md seed end" markers inside config.example.md's fenced code block
#     (headings/prose/tables are never copied).
#   - constraints.md: the WHOLE constraints.example.md (the entire document IS the policy
#     content - there is no seed block to slice, unlike config.md).
#   - .claude/settings.local.json: merges (never replaces) an allow-rule
#     "Bash(codex exec *)" into permissions.allow so coder_codex/reviewer_codex are not
#     blocked by Claude Code's auto-mode permission classifier. Idempotent (no duplicate
#     on re-run). This is the ONLY sanctioned point where the rule is written - the
#     orchestrator and its subagents never write it; seeding it here means the operator
#     running this launcher is the one granting the permission.

# Directory of this script (works whether run from a repo checkout or the ~/.claude/scripts
# mirror).
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"

mkdir -p ".work"

# Look for a template next to launchers/ first (repo checkout layout: this file lives in
# launchers/, the *.example.md one level up at the repo root), then alongside this script
# (mirror layout in ~/.claude/scripts, where cc-sync.sh mirrors the templates flat next to
# the *.sh files). On success prints the resolved path and returns 0. On failure prints
# nothing and returns a code the caller maps to a distinct cause (task T-056): 1 = a
# directory of that name shadows the template (the ~/.claude/scripts mirror is corrupted),
# 2 = the template is genuinely absent. `[ -f ]` already skips a directory, but without
# this split cc-config.sh could only say a vague "missing?" - the same class of misleading
# diagnostic cc-config.cmd suffers from - instead of naming the corrupted-mirror cause.
find_template() {
  if [ -f "$SCRIPT_DIR/../$1" ]; then
    printf '%s\n' "$SCRIPT_DIR/../$1"
    return 0
  elif [ -f "$SCRIPT_DIR/$1" ]; then
    printf '%s\n' "$SCRIPT_DIR/$1"
    return 0
  elif [ -d "$SCRIPT_DIR/../$1" ] || [ -d "$SCRIPT_DIR/$1" ]; then
    return 1
  fi
  return 2
}

# --- config.md (seed only the marked block) ---
if [ -f ".work/config.md" ]; then
  echo ".work/config.md already exists - leaving it unchanged."
else
  TEMPLATE="$(find_template config.example.md)"; template_rc=$?
  if [ "$template_rc" -eq 1 ]; then
    echo "Failed to create .work/config.md (config.example.md exists but is a directory, not a file - the ~/.claude/scripts mirror is corrupted; run cc-sync to repair it)."
  elif [ "$template_rc" -ne 0 ]; then
    echo "Failed to create .work/config.md (config.example.md not found next to launchers or in the mirror - run cc-sync, or check your checkout)."
  else
    # Extract only the lines strictly between the seed markers (both markers excluded).
    seed="$(awk '
      /^# >>> config\.md seed start/ { f=1; next }
      /^# <<< config\.md seed end/   { f=0 }
      f
    ' "$TEMPLATE")"
    if [ -z "$seed" ]; then
      echo "Failed to create .work/config.md (config.example.md is a file but has no 'config.md seed start/end' block to copy)."
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
  TEMPLATE="$(find_template constraints.example.md)"; template_rc=$?
  if [ "$template_rc" -eq 1 ]; then
    echo "Failed to create .work/constraints.md (constraints.example.md exists but is a directory, not a file - the ~/.claude/scripts mirror is corrupted; run cc-sync to repair it)."
  elif [ "$template_rc" -ne 0 ]; then
    echo "Failed to create .work/constraints.md (constraints.example.md not found next to launchers or in the mirror - run cc-sync, or check your checkout)."
  elif cp -f "$TEMPLATE" ".work/constraints.md"; then
    echo "Created .work/constraints.md from constraints.example.md - edit it for this project."
  else
    echo "Failed to create .work/constraints.md (copy failed - is .work writable?)."
  fi
fi

# --- .claude/settings.local.json (merge in an allow-rule for autonomous `codex exec`) ---
# Idempotent: leaves the file unchanged if any allow entry already covers "codex exec".
# Merges (never wholesale-overwrites) an existing file. Uses jq when available (proper
# JSON handling); a missing file is created from a fixed template (no parser needed); if
# the file exists but jq is absent, the file is left untouched and the operator is told
# to add the rule by hand rather than risk corrupting JSON with text tools. Only the
# operator (by running this launcher) ever writes this rule; the orchestrator/subagents
# never do.
CODEX_RULE='Bash(codex exec *)'
if [ -f ".claude/settings.local.json" ]; then
  # Idempotency pre-check that needs no jq: "codex exec" only ever appears here as such
  # an allow-rule, so its presence means the file already grants it.
  if grep -q 'codex exec' ".claude/settings.local.json" 2>/dev/null; then
    echo "OK   .claude/settings.local.json already allows codex exec - unchanged."
  elif command -v jq >/dev/null 2>&1; then
    if jq --arg r "$CODEX_RULE" \
         '.permissions = (.permissions // {}) | .permissions.allow = ((.permissions.allow // []) + [$r])' \
         ".claude/settings.local.json" > ".claude/settings.local.json.tmp" 2>/dev/null \
       && mv -f ".claude/settings.local.json.tmp" ".claude/settings.local.json"; then
      echo "Added allow-rule Bash(codex exec *) to .claude/settings.local.json (lets coder_codex/reviewer_codex run codex exec autonomously)."
    else
      rm -f ".claude/settings.local.json.tmp" 2>/dev/null
      echo "SKIP could not update .claude/settings.local.json with jq - add this allow-rule by hand (permissions.allow): Bash(codex exec *)"
    fi
  else
    echo "SKIP jq not found and .claude/settings.local.json already exists - add this allow-rule by hand (permissions.allow): Bash(codex exec *)"
  fi
else
  mkdir -p ".claude"
  printf '%s\n' \
    '{' \
    '  "permissions": {' \
    '    "allow": [' \
    '      "Bash(codex exec *)"' \
    '    ]' \
    '  }' \
    '}' > ".claude/settings.local.json"
  echo "Created .claude/settings.local.json with allow-rule Bash(codex exec *) (lets coder_codex/reviewer_codex run codex exec autonomously)."
fi
