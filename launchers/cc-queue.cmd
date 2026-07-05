@echo off
chcp 65001 >nul
rem Запуск queue_builder в текущей папке (Claude Code, auto-режим).
rem Ставит задачи в .work/Tasks_Queue.md. Источник можно передать аргументом:
rem   cc-queue docs\roadmap.md      или     cc-queue "add rate limiting to the API"
if "%~1"=="" (
  claude --agent queue_builder --permission-mode auto "Per your system prompt, ask me for the source (file/spec/backlog) or task description to enqueue into .work/Tasks_Queue.md — none was given on the command line."
) else (
  claude --agent queue_builder --permission-mode auto "Per your system prompt, add tasks to .work/Tasks_Queue.md. Task source or description: %*"
)
