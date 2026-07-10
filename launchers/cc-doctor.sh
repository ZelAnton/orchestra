#!/usr/bin/env bash
# Thin POSIX launcher for cc-doctor (task T-090). The real work - the read-only
# Codex/configuration/orchestration preflight (codex binary/auth, the autonomous-runtime
# allow-rule, effective CODEX_* + value validation, KB status, the Windows sandbox
# profile check - N/A on POSIX, and the task-queue / lock / worktree / main-branch /
# agent-mirror readiness audit) - lives in tools/doctor-runtime.ps1, the single
# cross-platform engine shared verbatim with the Windows launcher cc-doctor.cmd. This
# wrapper only locates PowerShell 7 and forwards the runtime's exit code, so Windows and
# POSIX behave identically.
#
# Cross-platform note (task T-090): unlike the pre-T-090 pure-shell cc-doctor.sh, this
# path now REQUIRES pwsh (PowerShell 7), because the doctor logic is the same pwsh engine
# both platforms run. This removes the previous drift risk where the POSIX variant
# reimplemented the checks in shell/awk and could diverge from the Windows diagnostics.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
# Prefer the checkout layout (launchers/../tools/doctor-runtime.ps1); fall back to the
# mirror layout (the runtime mirrored next to this launcher in ~/.claude/scripts by
# cc-sync) so cc-doctor keeps working when run from the mirror.
RT="$SCRIPT_DIR/../tools/doctor-runtime.ps1"
[ -f "$RT" ] || RT="$SCRIPT_DIR/doctor-runtime.ps1"
if [ ! -f "$RT" ]; then
  echo "cc-doctor: doctor-runtime.ps1 not found next to the launcher or under ../tools; reinstall the mirror with cc-sync from a repo checkout." >&2
  exit 2
fi

if command -v pwsh >/dev/null 2>&1; then
  exec pwsh -NoProfile -File "$RT" "$@"
fi

echo "cc-doctor: PowerShell 7 (pwsh) is required for the cross-platform doctor runtime but was not found on PATH. Install it from https://aka.ms/powershell and re-run cc-doctor." >&2
exit 3
