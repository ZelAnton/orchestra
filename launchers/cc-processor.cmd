@echo off
chcp 65001 >nul
rem Запуск оркестратора processor в текущей папке (Claude Code, acceptEdits-режим).
rem Обрабатывает очередь .work/Tasks_Queue.md параллельными батчами до конца.
rem
rem Необязательные флаги (в любом порядке, перед остальными аргументами):
rem   --force-lock       удалить .work\orchestrator.lock перед стартом — только если
rem                      точно знаешь, что предыдущий processor уже не работает.
rem   --model <имя>      переопределить модель агента (если поддерживается вашей
rem                      версией claude — проверьте `claude --help`, комбинация
rem                      --agent + --model не документирована на 100%).
rem
rem EXTRA_ARGS — это флаги для самого claude (короткие токены вида --flag/значение),
rem а НЕ свободный текст описания задачи, как в cc-queue.cmd/cc-thinker.cmd, поэтому
rem здесь нет отдельной защиты от кавычек/%% — обычные имена флагов и их значения их
rem не содержат. Если всё же передать значение флага с "%%ИМЯ%%", совпадающим с
rem реальной переменной окружения, cmd подставит её значение при связывании %%1 с
rem батником (то же неустранимое изнутри .cmd-файла ограничение, что и в
rem cc-queue.cmd/cc-thinker.cmd) — с кавычками внутри значения флага аналогично не
rem боремся: не передавайте в EXTRA_ARGS произвольный текст с кавычками.

setlocal
set MODEL_ARG=
set EXTRA_ARGS=

:parse
if "%~1"=="" goto :run
if /I "%~1"=="--force-lock" (
  if exist ".work\orchestrator.lock" (
    echo Удаляю .work\orchestrator.lock — используй только если уверен, что предыдущий processor не работает.
    rd /s /q ".work\orchestrator.lock"
  )
  shift
  goto :parse
)
if /I "%~1"=="--model" (
  rem Хвостовой --model без значения: не съедаем следующий флаг как модель — игнорируем.
  if "%~2"=="" (
    echo Флаг --model без значения — игнорирую.
    shift
    goto :parse
  )
  set MODEL_ARG=--model %~2
  shift
  shift
  goto :parse
)
rem Прочие аргументы пробрасываются в claude как есть (после %MODEL_ARG%, перед промптом).
set EXTRA_ARGS=%EXTRA_ARGS% %1
shift
goto :parse

:run
claude --agent processor %MODEL_ARG%%EXTRA_ARGS% --permission-mode acceptEdits "Start now, following your system prompt: take the orchestrator lock, then process .work/Tasks_Queue.md end to end — capture batches of parallel-safe tasks, plan them, implement in parallel worktrees, review, merge via the merger, and publish (ff-merge + push + CI), looping until no not-started tasks remain. Report progress as you go."
