@echo off
rem Запуск code_auditor в текущей папке (Claude Code, auto-режим).
rem Аудирует исходный код и заводит найденные проблемы задачами в очередь.
call "%~dp0cc-common.cmd" run code_auditor auto "Per your system prompt, audit the repository source code and enqueue each issue you find as a separate task in .work/Tasks_Queue.md. Start now."
