@echo off
setlocal
chcp 65001 >nul
rem Read-only operational metrics from .work\events.jsonl + journal.md fallback.
set "METRICS=%~dp0..\tools\metrics.ps1"
if not exist "%METRICS%" set "METRICS=%~dp0metrics.ps1"
if not exist "%METRICS%" (
    >&2 echo cc-metrics: metrics.ps1 not found ^(run cc-sync from the Orchestra checkout^)
    exit /b 3
)
where pwsh >nul 2>nul
if errorlevel 1 (
    >&2 echo cc-metrics: pwsh ^(PowerShell 7^) is required
    exit /b 3
)
pwsh -NoProfile -NonInteractive -File "%METRICS%" %*
exit /b %ERRORLEVEL%
