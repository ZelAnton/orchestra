#!/usr/bin/env bash
# Thin POSIX launcher for cc-sync (task T-090). The real work - regenerating the
# Claude/Codex role variants, validating agent .md invariants, mirroring
# agents/launchers/config-templates into ~/.claude, and installing namespaced custom
# agents into $CODEX_HOME/agents (normally ~/.codex/agents), each transactionally - lives in
# tools/sync-runtime.ps1, the single cross-platform engine shared verbatim with the
# Windows launcher cc-sync.cmd. This wrapper only locates PowerShell 7 and forwards
# the runtime's exit code, so Windows and POSIX behave identically.
#
# Cross-platform note (task T-090): unlike the pre-T-090 pure-shell cc-sync.sh, this
# path now REQUIRES pwsh (PowerShell 7), because the sync logic is the same pwsh
# engine both platforms run. This removes the previous drift risk where the POSIX
# variant skipped regeneration/validation and mirrored possibly-stale files.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
RT="$SCRIPT_DIR/../tools/sync-runtime.ps1"

# Checkout vs mirror: tools/sync-runtime.ps1 only exists in an actual repo checkout.
# Run from the launchers-only ~/.claude/scripts mirror there is nothing to sync FROM,
# so report a deliberate no-op instead of pretending work happened.
if [ ! -f "$RT" ]; then
  echo "Skipping sync - not running from a repository checkout (mirror detected); run cc-sync from the repo checkout instead."
  exit 0
fi

if command -v pwsh >/dev/null 2>&1; then
  exec pwsh -NoProfile -File "$RT" "$@"
fi

echo "cc-sync: PowerShell 7 (pwsh) is required for the cross-platform sync runtime but was not found on PATH. Install it from https://aka.ms/powershell and re-run cc-sync." >&2
exit 3
