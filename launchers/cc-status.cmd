@echo off
chcp 65001 >nul
rem Показывает текущий обзор оркестра (.work\status.md) и хвост журнала прогонов
rem (.work\journal.md) в текущей папке — без запуска Claude Code. Не дампит файлы
rem целиком: только последние ~40 строк каждого (обзор обычно короче).
echo === .work\status.md (последние 40 строк) ===
powershell -NoProfile -Command "if (Test-Path '.work\status.md') { Get-Content -LiteralPath '.work\status.md' -Encoding UTF8 -Tail 40 } else { Write-Host '(нет активного обзора — processor ещё не запускался или очередь пуста)' }"
echo.
echo === .work\journal.md (последние 40 строк) ===
powershell -NoProfile -Command "if (Test-Path '.work\journal.md') { Get-Content -LiteralPath '.work\journal.md' -Encoding UTF8 -Tail 40 } else { Write-Host '(журнал пуст — ни один батч ещё не завершился)' }"
