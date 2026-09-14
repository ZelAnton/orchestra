@echo off
chcp 65001 >nul
setlocal
rem Explicit focus profile, independent of queue-provider/model defaults.
set "CYCLE_RUNTIME=%~dp0..\tools\focus-runtime.ps1"
if exist "%CYCLE_RUNTIME%" goto runtime_found
if not defined ORCHESTRA_HOME set "ORCHESTRA_HOME=%USERPROFILE%\.orchestra"
set "CYCLE_RUNTIME=%ORCHESTRA_HOME%\scripts\focus-runtime.ps1"
:runtime_found
if not exist "%CYCLE_RUNTIME%" (
    echo cc-focus: runtime is missing; run cc-sync first. 1>&2
    exit /b 3
)
where pwsh.exe >nul 2>nul
if errorlevel 1 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%CYCLE_RUNTIME%" %*
) else (
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%CYCLE_RUNTIME%" %*
)
exit /b %errorlevel%
