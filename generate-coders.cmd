@echo off
rem Regenerate agents/coder.md, coder_fast.md, coder_deep.md from agents/coder.template.md
rem and agents/reviewer.md, reviewer_std.md from agents/reviewer.template.md (paths are inside the .ps1).
rem Run this from the same folder (repo root) after editing any template.
rem Prefers pwsh (PowerShell 7); falls back to powershell (5.1) if pwsh is not found.
rem The generator writes UTF-8 without BOM explicitly ([IO.File]::WriteAllText) in both cases.
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0generate-coders.ps1"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0generate-coders.ps1"
)
