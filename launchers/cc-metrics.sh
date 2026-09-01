#!/usr/bin/env bash
# Read-only operational aggregate, cohort-budget and time-window digest metrics.
set -u
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
ORCHESTRA_HOME="${ORCHESTRA_HOME:-$HOME/.orchestra}"
if [ -f "$SCRIPT_DIR/../tools/metrics.ps1" ]; then
  METRICS="$SCRIPT_DIR/../tools/metrics.ps1"
elif [ -f "$ORCHESTRA_HOME/scripts/metrics.ps1" ]; then
  METRICS="$ORCHESTRA_HOME/scripts/metrics.ps1"
elif [ -f "$SCRIPT_DIR/metrics.ps1" ]; then
  METRICS="$SCRIPT_DIR/metrics.ps1"
else
  echo "cc-metrics: metrics.ps1 not found (run cc-sync from the Orchestra checkout)" >&2
  exit 3
fi
if command -v pwsh >/dev/null 2>&1; then
  exec pwsh -NoProfile -NonInteractive -File "$METRICS" "$@"
fi
echo "cc-metrics: pwsh (PowerShell 7) is required" >&2
exit 3
