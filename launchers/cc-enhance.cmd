@echo off
chcp 65001 >nul
rem Запуск enhancement_scout в текущей папке (Claude Code, auto-режим).
rem Предлагает развитие проекта и заводит предложения задачами в очередь.
claude --agent enhancement_scout --permission-mode auto "Per your system prompt, analyze the project and enqueue development/improvement proposals as separate tasks in .work/Tasks_Queue.md. Start now."
