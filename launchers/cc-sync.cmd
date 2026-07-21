@echo off
rem Thin Windows launcher for cc-sync (task T-090). All of the real work -
rem regenerating Claude/Codex role variants, validating agent .md invariants,
rem mirroring agents/launchers/config-templates into %USERPROFILE%\.claude, and
rem installing namespaced custom agents into %CODEX_HOME%\agents (normally
rem %USERPROFILE%\.codex\agents) transactionally - lives in tools\sync-runtime.ps1, the single
rem cross-platform engine shared verbatim with the POSIX launcher cc-sync.sh. This
rem file only resolves a PowerShell host and forwards the runtime's exit code.
rem
rem Keeping the logic in one pwsh script (instead of a big inline cmd program and a
rem separate hand-mirrored POSIX shell program) is what makes Windows and POSIX give
rem identical behaviour and exit codes, and removes the cmd.exe UTF-8/codepage
rem fragility the old inline version had to work around.
setlocal
set "CC_SYNC_RT=%~dp0..\tools\sync-runtime.ps1"

rem An installed cc-sync is normally resolved from %USERPROFILE%\.claude\scripts.
rem When the operator runs that PATH command while cwd is the Orchestra checkout,
rem recover the checkout runtime from cwd.  Without this fallback `cc-sync` looked
rem successful but was a no-op, leaving agents and policy runtimes stale.
if not exist "%CC_SYNC_RT%" (
  if exist "%CD%\agents\processor.md" if exist "%CD%\generate-codex-agents.ps1" if exist "%CD%\tools\sync-runtime.ps1" set "CC_SYNC_RT=%CD%\tools\sync-runtime.ps1"
)

rem Outside an Orchestra checkout a mirror invocation still has no source to sync.
if not exist "%CC_SYNC_RT%" (
  echo Skipping sync - no Orchestra checkout found beside the launcher or in the current directory; cd to the Orchestra checkout and run cc-sync again.
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
