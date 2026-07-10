@echo off
chcp 65001 >nul
rem Запуск оркестратора processor в текущей папке (Claude Code, auto-режим).
rem Обрабатывает очередь .work/Tasks_Queue.md параллельными батчами до конца.
rem
rem Необязательные флаги (в любом порядке, перед остальными аргументами):
rem   --force-lock       операторский force-takeover аренды: удалить каталог аренды
rem                      .work\orchestrator.lock (вместе с lease.json) перед стартом —
rem                      только если точно знаешь, что предыдущий processor уже не
rem                      работает. Безопасный авто-takeover (при доказанном stale)
rem                      этого не требует; --force-lock — явное подтверждение оператора.
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
rem --allowedTools "Bash(codex exec:*)": предвыданный сессионный грант на запуск codex
rem адаптерами (coder_codex/reviewer_codex). Запуск launcher'а пользователем и есть
rem выдача согласия; без него classifier auto-режима отклоняет `codex exec … ` посреди
rem прогона как «запуск автономного агента» (см. agents\coder_codex.md). Грант — по
rem литеральному префиксу строки команды, поэтому адаптеры зовут codex командой,
rem начинающейся ровно с `codex exec`. Флаг стоит перед флагом permission-mode:
rem --allowedTools вариативен и без следующего флага-ограничителя поглотил бы промпт.
rem Режим auto сохранён без изменений.
rem
rem CC_CODEX_EXEC_GRANT="codex exec": явный, проверяемый признак того, что сессионный
rem грант на автономный `codex exec` уже выдан выше через --allowedTools. Это единый
rem контракт launcher->processor (тот же признак читают Фаза 1.1 processor.md и
rem cc-doctor): значение — гранованный префикс команды. Получив его, permission-гейт
rem Фазы 1.1 не требует дублирующего постоянного allow-правила в settings-файлах и не
rem запускает статический поиск заново. Внутри setlocal — переменная видна дочернему
rem процессу claude и не утекает в окружение вызывающей оболочки.
set "CC_CODEX_EXEC_GRANT=codex exec"
claude --agent processor %MODEL_ARG%%EXTRA_ARGS% --allowedTools "Bash(codex exec:*)" --permission-mode auto "Start now, following your system prompt: take the orchestrator lock, then process .work/Tasks_Queue.md end to end — capture batches of parallel-safe tasks, plan them, implement in parallel worktrees, review, merge via the merger, and publish (ff-merge + push + CI), looping until no not-started tasks remain. Report progress as you go."
