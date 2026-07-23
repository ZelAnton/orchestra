@echo off
rem Запуск proposal_curator в текущей папке (Claude Code, auto-режим).
rem Пакетно курирует новые предложения P-NNN (kind: proposal) в бэклоге:
rem для каждого предложения выносит один исход и создаёт задачи из converted.
call "%~dp0cc-common.cmd" run proposal_curator auto "Per your system prompt, curate the new P-NNN proposals in .work/Tasks_Queue.md and decide one outcome for each proposed proposal. Start now."
