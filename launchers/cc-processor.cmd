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
rem --allowedTools (грант): предвыданный сессионный грант на автономный запуск codex
rem адаптерами (coder_codex/reviewer_codex). Запуск launcher'а пользователем и есть
rem выдача согласия; без покрывающего гранта classifier auto-режима отклоняет вызов
rem посреди прогона как «запуск автономного агента» (см. agents\coder_codex.md). Передаём
rem два префиксных гранта (правило матчится по литеральному началу Bash-строки команды):
rem   Bash(pwsh -File tools/codex-runtime.ps1:*) — строка, которую РЕАЛЬНО исполняет
rem     Bash-инструмент. Адаптеры больше не зовут `codex exec` голой Bash-командой, а гонят
rem     codex через runtime-обёртку `pwsh -File tools/codex-runtime.ps1 <run|guard-commit|
rem     cleanup|classify|check-diff|validate-reviewer|broker-validate|map-sentinel> ...`,
rem     поэтому один этот префикс покрывает все подкоманды runtime. Сам `codex exec`
rem     runtime порождает дочерним процессом (.NET ProcessStartInfo) и через permission-гейт
rem     Bash он НЕ проходит — грант только на `Bash(codex exec:*)` оставил бы каждый вызов
rem     адаптера заблокированным (исправление находки ревью R-01).
rem   Bash(codex exec:*) — сохранён как канонический якорь codex-автономии, который называет
rem     CC_CODEX_EXEC_GRANT и от которого отталкиваются гейт Фазы 1.1 / cc-doctor / правило
rem     cc-config в settings; безвреден, когда codex не зовётся голой Bash-командой напрямую.
rem Гранты стоят перед флагом permission-mode: --allowedTools вариативен и без следующего
rem флага-ограничителя поглотил бы промпт. Режим auto сохранён без изменений.
rem
rem CC_CODEX_EXEC_GRANT="codex exec": явный, проверяемый признак того, что сессия выше
rem предвыдала автономный codex через --allowedTools. Это единый контракт
rem launcher->processor (тот же признак читают Фаза 1.1 processor.md и cc-doctor): значение
rem — канонический гранованный префикс codex-команды, который эти читатели сверяют с
rem префиксом команды адаптеров `<CODEX_CMD> exec`, поэтому оно остаётся `codex exec` (НЕ
rem переводи его на pwsh-обёртку — иначе эта префиксная сверка перестанет совпадать и гейт
rem Фазы 1.1 откажется открывать когорту). Получив его, гейт Фазы 1.1 не требует
rem дублирующего постоянного allow-правила в settings-файлах и не запускает статический
rem поиск заново. Внутри setlocal — переменная видна дочернему процессу claude и не утекает
rem в окружение вызывающей оболочки.
set "CC_CODEX_EXEC_GRANT=codex exec"
claude --agent processor %MODEL_ARG%%EXTRA_ARGS% --allowedTools "Bash(codex exec:*)" "Bash(pwsh -File tools/codex-runtime.ps1:*)" --permission-mode auto "Start now, following your system prompt: take the orchestrator lock, then process .work/Tasks_Queue.md end to end — capture batches of parallel-safe tasks, plan them, implement in parallel worktrees, review, merge via the merger, and publish (ff-merge + push + CI), looping until no not-started tasks remain. Report progress as you go."
