@echo off
chcp 65001 >nul
rem Запуск code_auditor в текущей папке (Claude Code, auto-режим).
rem Аудирует исходный код и заводит найденные проблемы задачами в очередь.
claude --agent code_auditor --permission-mode auto "Per your system prompt, audit the repository source code and enqueue each issue you find as a separate task in .work/Tasks_Queue.md. Start now."
