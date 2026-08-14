@echo off
rem Run enhancement_scout in the current folder through Claude or the interactive Codex TUI.
setlocal
set "LAUNCHER_DIR=%~dp0"
for %%I in (.) do set "PROJECT_ROOT=%%~fI"
set "PROVIDER=%ORCHESTRA_PROVIDER%"
if not defined PROVIDER set "PROVIDER=claude"
if /I "%~1"=="claude" (
  set "PROVIDER=claude"
)
if /I "%~1"=="codex" (
  set "PROVIDER=codex"
)
if /I "%~1"=="--provider" (
  if "%~2"=="" (
    echo Flag --provider requires a value.
    exit /b 2
  )
  set "PROVIDER=%~2"
)
if /I "%PROVIDER%"=="codex" goto :run_codex
if /I not "%PROVIDER%"=="claude" (
  echo Invalid provider "%PROVIDER%". Allowed: claude, codex.
  exit /b 2
)
call "%~dp0cc-common.cmd" run enhancement_scout "Per your system prompt, analyze the project and enqueue development/improvement proposals as separate tasks in .work/Tasks_Queue.md. Start now."
exit /b %ERRORLEVEL%

:run_codex
set "CODEX_ROLE_RUNTIME=%LAUNCHER_DIR%..\tools\codex-role-runtime.ps1"
if exist "%CODEX_ROLE_RUNTIME%" goto :codex_runtime_found
set "CODEX_ROLE_RUNTIME=%LAUNCHER_DIR%codex-role-runtime.ps1"
if exist "%CODEX_ROLE_RUNTIME%" goto :codex_runtime_found
echo Codex role runtime not found. Run cc-sync from the Orchestra checkout.
exit /b 12
:codex_runtime_found
pwsh -NoProfile -File "%CODEX_ROLE_RUNTIME%" -Role enhancement_scout -Root "%PROJECT_ROOT%" -RequestedProvider codex
exit /b %ERRORLEVEL%
