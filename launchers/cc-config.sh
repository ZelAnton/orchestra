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
#   - .claude/settings.local.json: created with the canonical Codex exec-grant allow-list
#     (permissions.allow) only when the file does not exist yet. An EXISTING file is never
#     modified or merged into - this launcher only reports which canonical rule(s) are
#     missing from it, so the operator can add them by hand (task T-058: auto-merging into
#     an existing, operator-owned permissions file risked silently widening it). This is
#     the ONLY sanctioned point where the rule is created from scratch - the orchestrator
#     and its subagents never write it; seeding it here means the operator running this
#     launcher is the one granting the permission.

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

# --- .claude/settings.local.json (create-only; never merge into an existing file) ---
# Canonical Codex exec-grant allow-list (single source of truth - task T-058; keep
# byte-identical to launchers/cc-config.cmd's $rules and to the hint text printed by
# launchers/cc-doctor.cmd/.sh; documented in config.example.md under "Codex-агенты" /
# "Разрешение на запуск codex"). Currently one rule.
# If the file does not exist yet, create it with this list (no parser needed - a fixed
# template). If it already exists, it is NEVER modified or merged into (task T-058
# changed this from the prior jq-based auto-merge) - instead, print which of the
# canonical rule(s) are missing from it (plain grep -F substring search, no JSON
# parser needed for a read-only check) so the operator can add them by hand. Only the
# operator (by running this launcher) ever writes this rule from scratch; the
# orchestrator/subagents never do.
CODEX_ALLOW_RULES=('Bash(codex exec *)')
if [ -f ".claude/settings.local.json" ]; then
  missing=()
  for r in "${CODEX_ALLOW_RULES[@]}"; do
    if ! grep -qF -- "$r" ".claude/settings.local.json" 2>/dev/null; then
      missing+=("$r")
    fi
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    echo "OK   .claude/settings.local.json already allows codex exec - left unchanged."
  else
    echo ".claude/settings.local.json already exists - left unchanged (never auto-merged). Missing allow-rule(s) - add by hand to permissions.allow:"
    for m in "${missing[@]}"; do
      echo "  - $m"
    done
  fi
else
  mkdir -p ".claude"
  {
    echo '{'
    echo '  "permissions": {'
    echo '    "allow": ['
    last=$((${#CODEX_ALLOW_RULES[@]} - 1))
    i=0
    for r in "${CODEX_ALLOW_RULES[@]}"; do
      if [ "$i" -lt "$last" ]; then
        printf '      "%s",\n' "$r"
      else
        printf '      "%s"\n' "$r"
      fi
      i=$((i + 1))
    done
    echo '    ]'
    echo '  }'
    echo '}'
  } > ".claude/settings.local.json"
  echo "Created .claude/settings.local.json with allow-rule(s): ${CODEX_ALLOW_RULES[*]} (lets coder_codex/reviewer_codex run codex exec autonomously)."
fi
