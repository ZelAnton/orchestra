@echo off
chcp 65001 >nul
rem Seed .work\config.md from config.example.md if no config exists yet.
rem An existing .work\config.md is NEVER overwritten.
if exist ".work\config.md" (
  echo .work\config.md already exists - leaving it unchanged.
  goto :eof
)
if not exist ".work" mkdir ".work"
copy /Y "%~dp0..\config.example.md" ".work\config.md" >nul
if errorlevel 1 (
  echo Failed to create .work\config.md ^(config.example.md missing next to launchers?^).
) else (
  echo Created .work\config.md from config.example.md - edit it for this project.
)
