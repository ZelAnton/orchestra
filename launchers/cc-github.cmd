@echo off
rem Запуск github_sync в текущей папке (Claude Code, auto-режим). Требует gh CLI с авторизацией.
rem Заводит задачи из открытых issues/PR и закрывает готовые (PR — всегда close, не merge).
call "%~dp0cc-common.cmd" run github_sync auto "Per your system prompt, sync GitHub with the task queue: enqueue tasks from open issues/PRs and close the ones that are done. Start now."
