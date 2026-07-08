#!/usr/bin/env bash
# POSIX counterpart of cc-doctor.cmd. Read-only preflight/readiness audit for the
# optional Codex executor and the target project's orchestration state. Makes NO
# changes to any file (not even a stuck orchestrator.lock or an orphaned worktree - it
# only reports on them). Implemented with plain POSIX shell + grep/sed/awk, no
# PowerShell. Run from the project root.

# Directory of this script and the repo root above launchers/ (used by the
# agent-mirror freshness check further down; agent definitions live under
# $REPO_ROOT/agents, and when run from the ~/.claude/scripts mirror the parent has no
# agents/ folder, so that check is skipped).
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

CFG=".work/config.md"

# get_cfg KEY - print the value of "KEY: value" from .work/config.md, matching
# cc-doctor.cmd's GetCfg exactly: leading/trailing whitespace trimmed, and the value
# is read up to (but not including) an inline '#' comment, if present, mirroring the
# '^\s*KEY\s*:\s*([^#]*?)\s*(?:#.*)?$' regex there. If nothing remains after
# stripping the comment (or there was no value to begin with), the printed value is
# empty, i.e. treated as unset - not an error. First match wins.
get_cfg() {
  [ -f "$CFG" ] || return 0
  awk -v k="$1" '
    match($0, "^[[:space:]]*" k "[[:space:]]*:[[:space:]]*") {
      rest = substr($0, RLENGTH + 1)
      hIdx = index(rest, "#")
      if (hIdx > 0) rest = substr(rest, 1, hIdx - 1)
      sub(/[[:space:]]+$/, "", rest)
      print rest
      exit
    }
  ' "$CFG"
}

# == Block 1: Codex preflight =================================================
codex="$(get_cfg CODEX_CMD)"
[ -n "$codex" ] || codex="codex"
echo "== Codex preflight =="
bin="$(command -v "$codex" 2>/dev/null)"
if [ -n "$bin" ]; then
  echo "codex binary : $bin"
  echo "codex version: $("$codex" --version 2>/dev/null)"
else
  echo "codex binary : NOT FOUND ($codex) -> coder_codex will escalate to Claude"
fi
if [ -f "$HOME/.codex/auth.json" ]; then
  echo "auth         : ~/.codex/auth.json present"
else
  echo "auth         : NOT found -> run: codex login"
fi
echo
echo "== Effective CODEX_* (.work/config.md; CODEX_CODER/CODEX_REVIEWER fall back to env; blank = default) =="
for k in CODEX_CODER CODEX_REVIEWER CODEX_CIFIX CODEX_MODEL CODEX_REASONING CODEX_SANDBOX CODEX_CMD; do
  val="$(get_cfg "$k")"
  src=""
  if [ -z "$val" ] && { [ "$k" = "CODEX_CODER" ] || [ "$k" = "CODEX_REVIEWER" ]; }; then
    ev="$(eval "printf '%s' \"\${$k:-}\"")"
    if [ -n "$ev" ]; then
      # trim surrounding whitespace of the env value
      ev="$(printf '%s' "$ev" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      val="$ev"; src=" (env)"
    fi
  fi
  [ -n "$val" ] || val="(default)"
  printf '  %-16s = %s%s\n' "$k" "$val" "$src"
done
echo
echo "== База знаний (KB; .work/knowledge) =="
kb="$(get_cfg KB)"
[ -n "$kb" ] || kb="off (default)"
echo "  KB = $kb"
if [ -d ".work/knowledge" ]; then
  for s in architecture conventions pitfalls; do
    c="$(find ".work/knowledge/$s" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]')"
    printf '  %-13s = %s entries\n' "$s" "$c"
  done
else
  echo "  .work/knowledge absent (KB empty or off)"
fi

# == Block 2: task queue & configuration =====================================
echo
echo "== Preflight readiness audit: task queue & configuration =="
qf=".work/Tasks_Queue.md"
if [ -f "$qf" ]; then
  awk '
    /^#{1,6}[[:space:]]/ {
      if ($0 ~ /^### \[T-[0-9]+\] .+ — статус: .+$/) {
        match($0, /T-[0-9]+/); id = substr($0, RSTART, RLENGTH)
        if (id in seen) { nb++; bad[nb] = "line " NR ": duplicate task id " id " (first seen at line " seen[id] ")" }
        else { seen[id] = NR; cnt++ }
      } else if ($0 ~ /T-[0-9]+/) {
        nb++; bad[nb] = "line " NR ": malformed task header (expected format: \"### [T-NNN] Title — статус: ...\"): " $0
      }
    }
    END {
      if (nb == 0) print "OK   Tasks_Queue.md: " cnt " task header(s), format valid, IDs unique"
      else { print "FAIL Tasks_Queue.md format violation(s):"; for (i = 1; i <= nb; i++) print "  - " bad[i] }
    }
  ' "$qf"
else
  echo "OK   .work/Tasks_Queue.md not found (nothing to validate)"
fi
if [ -f "$CFG" ]; then
  awk -v known=" MAX_PARALLEL COHORT_SIZE COHORT_MAX_AGE REVIEW_MIN_PASSES REVIEW_LOOP_MAX INTEGRATION_LOOP_MAX CI_FIX_MAX QUARANTINE_MAX_ATTEMPTS SMOKE_CMD PUSH CI_WATCH REVIEWER_TIERING MAIN_BRANCH EVENTS_OUTBOX KB KB_TTL KB_CAP CODEX_CODER CODEX_REVIEWER CODEX_CIFIX CODEX_MODEL CODEX_REASONING CODEX_SANDBOX CODEX_CMD " '
    {
      t = $0
      gsub(/^[[:space:]]+/, "", t); gsub(/[[:space:]]+$/, "", t)
      if (t == "" || substr(t, 1, 1) == "#") next
      if (match(t, /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:/)) {
        colon = index(t, ":")
        k = substr(t, 1, colon - 1); gsub(/[[:space:]]+$/, "", k)
        v = substr(t, colon + 1); sub(/#.*$/, "", v)
        gsub(/^[[:space:]]+/, "", v); gsub(/[[:space:]]+$/, "", v)
        if (index(known, " " k " ") == 0) { unknown = unknown (unknown == "" ? "" : ", ") k }
        if (k == "SMOKE_CMD" && v != "") hasSmoke = 1
      }
    }
    END {
      if (unknown == "") print "OK   .work/config.md: no unknown/mistyped keys"
      else print "FAIL .work/config.md: unknown/possibly mistyped key(s): " unknown
      if (hasSmoke) print "OK   SMOKE_CMD is configured"
      else print "WARN SMOKE_CMD is not set - coder/merger self-checks will skip build/test verification"
    }
  ' "$CFG"
else
  echo "WARN .work/config.md not found - defaults apply; SMOKE_CMD is not configured (self-checks skip build/test verification)"
fi

# == Block 3: orchestrator lock & worktrees ==================================
echo
echo "== Preflight readiness audit: orchestrator lock & worktrees =="
lockDir=".work/orchestrator.lock"
if [ -d "$lockDir" ]; then
  started=""; hostVal=""
  if [ -f "$lockDir/info" ]; then
    started="$(sed -n 's/^started=//p' "$lockDir/info" | head -n1)"
    hostVal="$(sed -n 's/^host=//p' "$lockDir/info" | head -n1)"
  fi
  if [ -n "$started" ]; then
    if startEpoch="$(date -u -d "$started" +%s 2>/dev/null)"; then
      nowEpoch="$(date -u +%s)"
      ageHours="$(awk -v a="$nowEpoch" -v b="$startEpoch" 'BEGIN { printf "%.1f", (a - b) / 3600 }')"
      if awk -v h="$ageHours" 'BEGIN { exit (h > 6) ? 0 : 1 }'; then
        echo "WARN orchestrator.lock: age ${ageHours}h (started $started, host $hostVal) - possibly stale (heuristic only); verify no processor is actually running before removing .work/orchestrator.lock manually"
      else
        echo "OK   orchestrator.lock present, age ${ageHours}h (started $started, host $hostVal) - looks like an active run"
      fi
    else
      echo "WARN orchestrator.lock/info present but the started timestamp is unparsable ($started) - cannot judge age"
    fi
  else
    echo "WARN orchestrator.lock present without info/started timestamp - cannot judge age; verify manually"
  fi
else
  echo "OK   no orchestrator.lock (no active/stuck processor run)"
fi
wtRoot=".work/worktrees"
if [ -d "$wtRoot" ]; then
  orphans=""
  for d in "$wtRoot"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    if [ "$name" = "_integration" ]; then
      [ -f ".work/batch.md" ] || orphans="$orphans|$name (no .work/batch.md - no active batch)"
    else
      [ -f ".work/tasks/$name/task.md" ] || orphans="$orphans|$name (no .work/tasks/$name/task.md descriptor)"
    fi
  done
  if [ -z "$orphans" ]; then
    echo "OK   no orphaned worktrees under .work/worktrees"
  else
    echo "FAIL orphaned worktree(s) (no matching active task/batch - not auto-removed):"
    printf '%s\n' "$orphans" | tr '|' '\n' | while IFS= read -r o; do
      [ -n "$o" ] && echo "  - $o"
    done
  fi
else
  echo "OK   .work/worktrees not present (nothing to check)"
fi

# == Block 4: main branch & agent mirror =====================================
echo
echo "== Preflight readiness audit: main branch & agent mirror =="
mainCfg="$(get_cfg MAIN_BRANCH)"
bookmark_has() { printf '%s\n' "$1" | awk -F: -v b="$2" '$1 == b { f = 1 } END { exit f ? 0 : 1 }'; }
if jj root >/dev/null 2>&1; then
  if [ -n "$mainCfg" ]; then branch="$mainCfg"; else branch="main"; fi
  bm="$(jj bookmark list 2>/dev/null)"
  if bookmark_has "$bm" "$branch"; then found=1; else found=0; fi
  if [ "$found" -eq 0 ] && [ -z "$mainCfg" ]; then
    branch="master"
    if bookmark_has "$bm" "master"; then found=1; fi
  fi
  if [ "$found" -eq 1 ]; then
    echo "OK   main branch determinable: jj bookmark $branch"
  else
    echo "FAIL cannot determine main branch: no jj bookmark $branch found; set MAIN_BRANCH in .work/config.md if the trunk has a different name"
  fi
elif git rev-parse --show-toplevel >/dev/null 2>&1; then
  branch="$mainCfg"
  if [ -z "$branch" ]; then
    oh="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
    [ -n "$oh" ] && branch="${oh#origin/}"
  fi
  [ -z "$branch" ] && branch="main"
  if git rev-parse --verify "$branch" >/dev/null 2>&1; then
    echo "OK   main branch determinable: git branch $branch"
  else
    branch="master"
    if git rev-parse --verify "$branch" >/dev/null 2>&1; then
      echo "OK   main branch determinable: git branch $branch"
    else
      echo "FAIL cannot determine main branch: neither main nor master resolves and no origin/HEAD/MAIN_BRANCH; set MAIN_BRANCH in .work/config.md"
    fi
  fi
else
  echo "WARN not a git or jj repository here - main-branch check skipped (run cc-doctor.sh from the target project root)"
fi
# Agent-mirror freshness - only meaningful when this script runs from the actual
# Orchestra repo checkout (agent definitions live under $REPO_ROOT/agents), NOT from the
# launchers-only ~/.claude/scripts mirror. Same agents/ source and reduced exclusion set
# (only the two generator templates) as cc-sync.sh.
mirrorDir="$HOME/.claude/agents"
agentsSrc="$REPO_ROOT/agents"
srcCount=0; missing=""; stale=""
for f in "$agentsSrc"/*.md; do
  [ -f "$f" ] || continue
  n="$(basename "$f")"
  case "$n" in
    coder.template.md|reviewer.template.md) continue ;;
  esac
  srcCount=$((srcCount + 1))
  dst="$mirrorDir/$n"
  if [ ! -f "$dst" ]; then
    missing="$missing|$n"
  elif ! cmp -s "$f" "$dst"; then
    stale="$stale|$n"
  fi
done
if [ "$srcCount" -eq 0 ]; then
  echo "OK   agent-mirror freshness check skipped (no agents/ folder next to launchers/ - not the Orchestra repo checkout)"
elif [ -z "$missing" ] && [ -z "$stale" ]; then
  echo "OK   ~/.claude/agents mirror up to date with $srcCount agent file(s) in this checkout"
else
  echo "FAIL ~/.claude/agents mirror stale relative to this checkout:"
  printf '%s\n' "$missing" | tr '|' '\n' | while IFS= read -r m; do
    [ -n "$m" ] && echo "  - $m: missing in mirror"
  done
  printf '%s\n' "$stale" | tr '|' '\n' | while IFS= read -r s; do
    [ -n "$s" ] && echo "  - $s: content differs from checkout"
  done
  echo "  run launchers/cc-sync.sh to refresh the mirror"
fi
