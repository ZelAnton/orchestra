@echo off
setlocal
chcp 65001 >nul
rem Запуск github_sync в текущей папке (Claude Code). Требует gh CLI с авторизацией.
rem Заводит задачи из открытых issues/PR и закрывает готовые (PR — всегда close, не merge).
rem Без предопределённого промпта: агент запускается и ждёт указания задачи в чате.
call "%~dp0cc-common.cmd" resolve_permission_mode
if errorlevel 1 exit /b %ERRORLEVEL%
claude --agent github_sync --permission-mode %CLAUDE_PERMISSION_MODE%
