@echo off
rem Запуск enhancement_scout в текущей папке (Claude Code, acceptEdits-режим).
rem Предлагает развитие проекта и заводит предложения задачами в очередь.
call "%~dp0cc-common.cmd" run enhancement_scout acceptEdits "Per your system prompt, analyze the project and enqueue development/improvement proposals as separate tasks in .work/Tasks_Queue.md. Start now."
