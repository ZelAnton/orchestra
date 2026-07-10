@echo off
rem Thin Windows launcher for cc-doctor (task T-090). All of the real work - the
rem read-only Codex/configuration/orchestration preflight (codex binary/auth, the
rem autonomous-runtime allow-rule, effective CODEX_* + value validation, KB status,
rem the Windows sandbox profile, and the task-queue / lock / worktree / main-branch /
rem agent-mirror readiness audit) - lives in tools\doctor-runtime.ps1, the single
rem cross-platform engine shared verbatim with the POSIX launcher cc-doctor.sh. This
rem file only resolves a PowerShell host and forwards the runtime's exit code.
rem
rem Keeping the logic in one pwsh script (instead of a big inline cmd program and a
rem separate hand-mirrored POSIX shell program) is what makes Windows and POSIX give
rem identical diagnostics, and removes the cmd.exe UTF-8/codepage fragility the old
rem inline version had to work around.
setlocal
rem Prefer the checkout layout (launchers\..\tools\doctor-runtime.ps1); fall back to the
rem mirror layout (the runtime mirrored next to this launcher in %USERPROFILE%\.claude\
rem scripts by cc-sync) so cc-doctor keeps working when run from the mirror.
set "CC_DOCTOR_RT=%~dp0..\tools\doctor-runtime.ps1"
if not exist "%CC_DOCTOR_RT%" set "CC_DOCTOR_RT=%~dp0doctor-runtime.ps1"
if not exist "%CC_DOCTOR_RT%" (
  echo cc-doctor: doctor-runtime.ps1 not found next to the launcher or under ..\tools; reinstall the mirror with cc-sync from a repo checkout. 1>&2
  exit /b 2
)

rem Prefer pwsh (PowerShell 7, the cross-platform runtime); fall back to Windows
rem PowerShell 5.1 only if pwsh is not installed. The runtime source is ASCII-only so
rem 5.1's BOM-less ANSI read does not corrupt it.
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%CC_DOCTOR_RT%" %*
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%CC_DOCTOR_RT%" %*
)
exit /b %ERRORLEVEL%
