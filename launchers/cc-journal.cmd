@echo off
chcp 65001 >nul
rem Show the tail of the run journal (.work\journal.md) - last ~40 lines -
rem without launching Claude Code. If there is no journal yet, says so.
powershell -NoProfile -Command "if (Test-Path '.work\journal.md') { Get-Content -Tail 40 '.work\journal.md' } else { Write-Host '(no journal yet - no batch has completed)' }"
