#!/usr/bin/env bash
# Read-only operational metrics from .work/events.jsonl + journal.md fallback.
set -u
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -f "$SCRIPT_DIR/../tools/metrics.ps1" ]; then
  METRICS="$SCRIPT_DIR/../tools/metrics.ps1"
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
