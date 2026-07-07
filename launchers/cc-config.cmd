@echo off
chcp 65001 >nul
rem Seed .work\config.md from config.example.md if no config exists yet.
rem An existing .work\config.md is NEVER overwritten.
if exist ".work\config.md" (
  echo .work\config.md already exists - leaving it unchanged.
  goto :eof
)
if not exist ".work" mkdir ".work"
rem Look for the template next to launchers\ first (repo checkout layout: this file
rem lives in launchers\, config.example.md one level up at the repo root), then fall
rem back to alongside this script (mirror layout in %USERPROFILE%\.claude\scripts,
rem where cc-sync.cmd also mirrors config.example.md flat next to the *.cmd files).
set "CC_CONFIG_TEMPLATE=%~dp0..\config.example.md"
if not exist "%CC_CONFIG_TEMPLATE%" set "CC_CONFIG_TEMPLATE=%~dp0config.example.md"
copy /Y "%CC_CONFIG_TEMPLATE%" ".work\config.md" >nul
if errorlevel 1 (
  echo Failed to create .work\config.md ^(config.example.md missing next to launchers?^).
) else (
  echo Created .work\config.md from config.example.md - edit it for this project.
)
