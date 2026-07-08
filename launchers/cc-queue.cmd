@echo off
chcp 65001 >nul
rem Запуск queue_builder в текущей папке (Claude Code, acceptEdits-режим).
rem Ставит задачи в .work/Tasks_Queue.md. Источник можно передать аргументом:
rem   cc-queue docs\roadmap.md      или     cc-queue "add rate limiting to the API"
rem
rem Аргумент устойчив к кавычкам/%% так:
rem   1) %* захватывается в ARGS ДО setlocal EnableDelayedExpansion — иначе
rem      литеральные "!" в тексте аргумента были бы съедены отложенным
rem      раскрытием ещё на этапе захвата;
rem   2) в сам промпт claude аргумент подставляется через !ARGS! (отложенное
rem      раскрытие), а не напрямую через %* — второй раз %* в одной строке не
rem      используем;
rem   3) двойные кавычки внутри ARGS заменяются на одинарные — иначе кавычка в
rem      аргументе разорвала бы кавычки промпта, и claude получил бы несколько
rem      несвязных позиционных аргументов вместо одного текста задания.
rem Известное и не устранимое изнутри .cmd-файла ограничение cmd.exe: если
rem аргумент содержит "%ИМЯ%", совпадающее с реально существующей переменной
rem окружения (например "%PATH%"), cmd подставит её значение — это происходит
rem при связывании %* с батником, раньше первой строки кода скрипта.
setlocal
set "ARGS=%*"
setlocal EnableDelayedExpansion
set "ARGS=!ARGS:"='!"
if "%~1"=="" (
  claude --agent queue_builder --permission-mode acceptEdits "Per your system prompt, ask me for the source (file/spec/backlog) or task description to enqueue into .work/Tasks_Queue.md — none was given on the command line."
) else (
  claude --agent queue_builder --permission-mode acceptEdits "Per your system prompt, add tasks to .work/Tasks_Queue.md. Task source or description: !ARGS!"
)
