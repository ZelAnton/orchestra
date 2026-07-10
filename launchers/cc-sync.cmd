@echo off
rem Thin Windows launcher for cc-sync (task T-090). All of the real work -
rem regenerating the template-driven coder/reviewer variants, validating agent .md
rem invariants, and mirroring agents/launchers/config-templates into
rem %USERPROFILE%\.claude TRANSACTIONALLY (staged publish, journal-backed rollback,
rem manifest-scoped pruning) - lives in tools\sync-runtime.ps1, the single
rem cross-platform engine shared verbatim with the POSIX launcher cc-sync.sh. This
rem file only resolves a PowerShell host and forwards the runtime's exit code.
rem
rem Keeping the logic in one pwsh script (instead of a big inline cmd program and a
rem separate hand-mirrored POSIX shell program) is what makes Windows and POSIX give
rem identical behaviour and exit codes, and removes the cmd.exe UTF-8/codepage
rem fragility the old inline version had to work around.
setlocal
set "CC_SYNC_RT=%~dp0..\tools\sync-runtime.ps1"

rem Checkout vs mirror: tools\sync-runtime.ps1 only exists in an actual repo checkout.
rem Run from the launchers-only %USERPROFILE%\.claude\scripts mirror there is nothing
rem to sync FROM, so report a deliberate no-op instead of pretending work happened.
if not exist "%CC_SYNC_RT%" (
  echo Skipping sync - not running from a repository checkout ^(mirror detected^); run cc-sync from the repo checkout instead.
  exit /b 0
)

rem Prefer pwsh (PowerShell 7, the cross-platform runtime); fall back to Windows
rem PowerShell 5.1 only if pwsh is not installed.
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%CC_SYNC_RT%" %*
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%CC_SYNC_RT%" %*
)
exit /b %ERRORLEVEL%
