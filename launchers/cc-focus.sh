#!/usr/bin/env bash
# Explicit focus profile; do not source queue-provider/model defaults.
set -euo pipefail
cycle_launcher_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [ -f "$cycle_launcher_dir/../tools/focus-runtime.ps1" ]; then
    cycle_runtime="$cycle_launcher_dir/../tools/focus-runtime.ps1"
else
    cycle_runtime="${ORCHESTRA_HOME:-$HOME/.orchestra}/scripts/focus-runtime.ps1"
fi
if [ ! -f "$cycle_runtime" ]; then
    printf 'cc-focus: runtime is missing; run cc-sync first.\n' >&2
    exit 3
fi
cycle_pwsh="$(command -v pwsh || command -v pwsh.exe || true)"
if [ -z "$cycle_pwsh" ]; then
    printf 'cc-focus: PowerShell 7 is required.\n' >&2
    exit 3
fi
exec "$cycle_pwsh" -NoProfile -File "$cycle_runtime" "$@"
