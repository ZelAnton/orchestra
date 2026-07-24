#!/usr/bin/env bash
# Seed .work/config.md and .work/constraints.md from the repo templates if they do not
# exist yet, and seed the Claude Code allow-rules for autonomous Codex (the runtime
# wrapper the adapters actually run, in both its layout forms -
# `pwsh -File tools/codex-runtime.ps1` from a repo checkout or
# `pwsh -File ~/.claude/scripts/codex-runtime.ps1` from a cc-sync mirror - plus the
# historical `codex exec` anchor) into .claude/settings.local.json. An existing target
# file is NEVER overwritten wholesale (same guarantee for all three). Finally, register
# the canonical project root in the user-global Orchestra registry and create
# .inbox/messages plus .inbox/releases for cross-project communication and release audit.
#   - config.md: only the copyable block between the "# >>> config.md seed start" /
#     "# <<< config.md seed end" markers inside config.example.md's fenced code block
#     (headings/prose/tables are never copied).
#   - constraints.md: the WHOLE constraints.example.md (the entire document IS the policy
#     content - there is no seed block to slice, unlike config.md).
#   - .claude/settings.local.json: ensures the canonical Codex allow-list
#     (permissions.allow) is present. If the file does not exist it is created with the
#     list. If it exists but is missing a canonical rule, that rule is MERGED into the
#     existing permissions.allow array via jq (task T-078): only the missing rule is added,
#     every other key/allow entry/deny-list/hook is preserved, and the result is written
#     atomically (temp file + mv). An already-present rule (idempotency substring pre-check)
#     leaves the file untouched. T-058 had removed the prior jq auto-merge fearing it would
#     silently widen an operator-owned file; T-078 restores it narrowly (add-only,
#     operator-run) - running this launcher IS the operator granting the permission, the
#     same consent that already justifies creating the file from scratch. Degenerate cases
#     (jq unavailable, invalid JSON, unexpected shape, file not writable) fall back to
#     printing the exact rule to add by hand - never a silent no-op. This is the ONLY
#     sanctioned point where the rule is written; the orchestrator and its subagents never
#     write it.

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

# --- .claude/settings.local.json (create if absent; else merge the missing rule in) ---
# Canonical Codex allow-list (single source of truth - keep byte-identical to
# launchers/cc-config.cmd's $rules and to the hint text printed by
# launchers/cc-doctor.cmd/.sh; documented in config.example.md under "Codex-агенты" /
# "Разрешение на запуск codex"). THREE rules (task F-05, extended by T-114):
#   - Bash(pwsh -File tools/codex-runtime.ps1 *) - the command Bash ACTUALLY runs when the
#     adapters run from a repo checkout. Since task T-075 both adapters drive codex through
#     the runtime wrapper `pwsh -File tools/codex-runtime.ps1 <run|guard-commit|...>`; the
#     child `codex exec` is spawned by the runtime via .NET ProcessStartInfo and never
#     crosses the Bash permission gate, so this is the rule that must be present for the
#     classifier to let the adapters run. One prefix covers every runtime subcommand and
#     every CODEX_CMD (a non-default CODEX_CMD is only a `--codex-cmd` argument to the
#     wrapper, not a separate Bash command).
#   - Bash(pwsh -File ~/.claude/scripts/codex-runtime.ps1 *) - the command's OTHER literal
#     form (task T-114): a target project that only has the cc-sync mirror (no tools/
#     checkout of its own) has no relative tools/codex-runtime.ps1 to resolve, so the
#     adapters fall back to the mirrored copy at ~/.claude/scripts/codex-runtime.ps1
#     instead - kept as a literal, unexpanded tilde so the rule stays a fixed,
#     machine-independent string.
#   - Bash(codex exec *) - kept as the historical anchor (the form CC_CODEX_EXEC_GRANT
#     names and older setups may already carry); harmless, does not itself authorize the
#     real runtime command.
# If the file does not exist yet, create it with this list (no parser needed - a fixed
# template). If it already exists but is missing a canonical rule, MERGE that rule into
# the existing permissions.allow array with jq (task T-078 restored this narrowly -
# add-only - after T-058 removed the prior jq auto-merge): jq preserves every other key,
# existing allow entry, deny-list and hook, and the result is written atomically (temp
# file + mv) so a mid-write failure cannot corrupt the file. The idempotency pre-check is
# a plain grep -F substring search (same as before), per rule: an already-present rule is
# not re-added, so an older file that only has Bash(codex exec *) gets just the missing
# runtime rule merged in on a re-run. Degenerate cases - jq is not installed, the file is
# not valid JSON, permissions/allow is not the expected shape, or the file cannot be
# written - fall back to printing the exact rule(s) to add by hand (never a silent no-op).
# Only the operator (by running this launcher) ever writes these rules; the
# orchestrator/subagents never do.
CODEX_ALLOW_RULES=('Bash(pwsh -File tools/codex-runtime.ps1 *)' 'Bash(pwsh -File ~/.claude/scripts/codex-runtime.ps1 *)' 'Bash(codex exec *)')
SETTINGS=".claude/settings.local.json"
if [ -f "$SETTINGS" ]; then
  missing=()
  for r in "${CODEX_ALLOW_RULES[@]}"; do
    if ! grep -qF -- "$r" "$SETTINGS" 2>/dev/null; then
      missing+=("$r")
    fi
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    echo "OK   .claude/settings.local.json already grants autonomous codex - left unchanged."
  else
    # A canonical rule is missing -> merge it into permissions.allow. Any degenerate case
    # prints the same "add by hand" fallback (never a silent no-op).
    print_add_by_hand() {
      echo "$1"
      for m in "${missing[@]}"; do
        echo "  - $m"
      done
    }
    if ! command -v jq >/dev/null 2>&1; then
      print_add_by_hand ".claude/settings.local.json is missing the allow-rule(s) and jq is not installed - cannot merge automatically; add by hand to permissions.allow:"
    elif ! jq empty "$SETTINGS" >/dev/null 2>&1; then
      print_add_by_hand ".claude/settings.local.json exists but is not valid JSON - cannot merge automatically; add the allow-rule(s) by hand to permissions.allow:"
    else
      tmp="$SETTINGS.tmp"
      # Ensure .permissions and .permissions.allow exist (as an object / array), then add
      # only the rules genuinely absent from the allow array. Input is fed via stdin so the
      # rules can be passed as jq positional args (--args). A non-object permissions or
      # non-array allow makes jq error out -> shape fallback below.
      if jq '.permissions = (.permissions // {}) | .permissions.allow = (.permissions.allow // []) | reduce $ARGS.positional[] as $r (.; if (.permissions.allow | index($r)) then . else .permissions.allow += [$r] end)' --args "${missing[@]}" < "$SETTINGS" > "$tmp" 2>/dev/null; then
        if mv -f "$tmp" "$SETTINGS" 2>/dev/null; then
          echo "Merged allow-rule(s) into .claude/settings.local.json permissions.allow: ${missing[*]} (lets coder_codex/reviewer_codex run codex autonomously via the runtime wrapper)."
        else
          rm -f "$tmp" 2>/dev/null
          print_add_by_hand ".claude/settings.local.json could not be written (read-only or locked?) - cannot merge automatically; add the allow-rule(s) by hand to permissions.allow:"
        fi
      else
        rm -f "$tmp" 2>/dev/null
        print_add_by_hand ".claude/settings.local.json exists but its permissions/allow is not the expected shape - cannot merge automatically; add the allow-rule(s) by hand to permissions.allow:"
      fi
    fi
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
  echo "Created .claude/settings.local.json with allow-rule(s): ${CODEX_ALLOW_RULES[*]} (lets coder_codex/reviewer_codex run codex autonomously via the runtime wrapper)."
fi

# --- user-global project registry + local cross-project inbox ---
# Resolve the runtime from the source checkout first, then from the flat cc-sync mirror.
# Registration is a required cc-config outcome: a missing/broken runtime fails the
# launcher instead of leaving the project silently undiscoverable by other repositories.
PROJECT_REGISTRY="$SCRIPT_DIR/../tools/project-registry.ps1"
if [ ! -f "$PROJECT_REGISTRY" ]; then
  PROJECT_REGISTRY="$SCRIPT_DIR/project-registry.ps1"
fi
if [ ! -f "$PROJECT_REGISTRY" ]; then
  echo "Failed to register project (project-registry.ps1 not found next to the launcher or in the cc-sync mirror - run cc-sync)." >&2
  exit 2
fi
if ! command -v pwsh >/dev/null 2>&1; then
  echo "Failed to register project (pwsh is required by project-registry.ps1)." >&2
  exit 2
fi
pwsh -NoProfile -File "$PROJECT_REGISTRY" register --root "$PWD" --ensure-inbox
