#!/usr/bin/env bash
# Shared configuration helpers for POSIX launchers. Configuration is resolved by the
# PowerShell runtime so the checkout and installed mirror use identical parsing rules.

CC_COMMON_SOURCE="${BASH_SOURCE[0]}"
CC_COMMON_DIR="${CC_COMMON_SOURCE%/*}"
if [ "$CC_COMMON_DIR" = "$CC_COMMON_SOURCE" ]; then CC_COMMON_DIR='.'; fi
CC_COMMON_DIR="$(CDPATH='' cd -- "$CC_COMMON_DIR" && pwd -P)"
export ORCHESTRA_HOME="${ORCHESTRA_HOME:-$HOME/.orchestra}"
if [ -f "$CC_COMMON_DIR/../tools/config-runtime.ps1" ]; then
  CC_CONFIG_RUNTIME="$CC_COMMON_DIR/../tools/config-runtime.ps1"
else
  CC_CONFIG_RUNTIME="$ORCHESTRA_HOME/scripts/config-runtime.ps1"
fi

orchestra_config_get() {
  local key="$1"
  local work="${2:-$PWD/.work}"
  if [ ! -f "$CC_CONFIG_RUNTIME" ]; then
    printf 'Orchestra config runtime is missing: %s\n' "$CC_CONFIG_RUNTIME" >&2
    return 12
  fi
  local powershell_command
  powershell_command="$(command -v pwsh 2>/dev/null || command -v pwsh.exe 2>/dev/null || true)"
  if [ -z "$powershell_command" ]; then
    printf 'PowerShell (pwsh) is missing; cannot read Orchestra config\n' >&2
    return 12
  fi
  "$powershell_command" -NoProfile -File "$CC_CONFIG_RUNTIME" get --work "$work" --key "$key"
}

orchestra_provider() {
  local value
  value="$(orchestra_config_get ORCHESTRA_PROVIDER)" || return $?
  printf '%s\n' "${value:-claude}"
}

orchestra_permission_mode() {
  local value
  value="$(orchestra_config_get ORCHESTRA_CLAUDE_PERMISSION_MODE)" || return $?
  printf '%s\n' "${value:-auto}"
}

orchestra_timeout_value() {
  local key="$1"
  local value
  value="$(orchestra_config_get "$key")" || return $?
  printf '%s\n' "${value:-1900000}"
}
