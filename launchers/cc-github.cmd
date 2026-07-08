@echo off
chcp 65001 >nul
rem Запуск github_sync в текущей папке (Claude Code, acceptEdits-режим). Требует gh CLI с авторизацией.
rem Заводит задачи из открытых issues/PR и закрывает готовые (PR — всегда close, не merge).
claude --agent github_sync --permission-mode acceptEdits "Per your system prompt, sync GitHub with the task queue: enqueue tasks from open issues/PRs and close the ones that are done. Start now."
