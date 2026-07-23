@echo off
chcp 65001 >nul
rem Запуск оркестратора processor в текущей папке.
rem Обрабатывает очередь .work/Tasks_Queue.md параллельными батчами до конца.
rem
rem Необязательные флаги (в любом порядке, перед остальными аргументами):
rem   claude|codex       явный provider (также: --provider <claude|codex>).
rem                      Если не задан, читается системная ORCHESTRA_PROVIDER;
rem                      default = claude.
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
set "LAUNCHER_DIR=%~dp0"
set "PROCESSKIT_RUNTIME=%~dp0..\tools\processkit-runtime.ps1"
if not exist "%PROCESSKIT_RUNTIME%" set "PROCESSKIT_RUNTIME=%~dp0processkit-runtime.ps1"
rem Do not use %%CD%% for the target root: a real environment variable named CD
rem shadows cmd.exe's dynamic current-directory value (GitHub Windows runners set one).
for %%I in (.) do set "PROJECT_ROOT=%%~fI"
set MODEL_ARG=
set MODEL_VALUE=
set EXTRA_ARGS=
set "PROVIDER=%ORCHESTRA_PROVIDER%"
if not defined PROVIDER set "PROVIDER=claude"
rem An agent run is an isolated build environment: persistent MSBuild nodes/servers only
rem leak resources into later tasks. Force the child session (and every subagent/tool it
rem spawns) to use short-lived build workers. These values stay inside setlocal.
set "MSBUILDDISABLENODEREUSE=1"
set "DOTNET_CLI_USE_MSBUILD_SERVER=0"
rem Codex xhigh reviews routinely outlive Claude Code's short Bash default. If Claude
rem auto-backgrounds the runtime command it appends `&`, which intentionally bypasses the
rem pre-granted foreground allow-rule and causes an approval prompt. Keep the wrapper in
rem foreground; explicit user/system values win over these session-scoped defaults.
if not defined BASH_DEFAULT_TIMEOUT_MS set "BASH_DEFAULT_TIMEOUT_MS=1900000"
if not defined BASH_MAX_TIMEOUT_MS set "BASH_MAX_TIMEOUT_MS=1900000"

:parse
if "%~1"=="" goto :run
if /I "%~1"=="claude" (
  set "PROVIDER=claude"
  shift
  goto :parse
)
if /I "%~1"=="codex" (
  set "PROVIDER=codex"
  shift
  goto :parse
)
if /I "%~1"=="--provider" (
  if "%~2"=="" (
    echo Флаг --provider без значения.
    exit /b 2
  )
  set "PROVIDER=%~2"
  shift
  shift
  goto :parse
)
if /I "%~1"=="--force-lock" (
  call :force_unlock
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
  set "MODEL_VALUE=%~2"
  set MODEL_ARG=--model %~2
  shift
  shift
  goto :parse
)
rem Прочие аргументы пробрасываются выбранному provider как есть.
set EXTRA_ARGS=%EXTRA_ARGS% %1
shift
goto :parse

:run
set "USE_PROCESSKIT_RUNTIME="
if exist "%PROCESSKIT_RUNTIME%" set "USE_PROCESSKIT_RUNTIME=1"
if not defined USE_PROCESSKIT_RUNTIME if defined CC_PROCESSKIT_PYTHON (
  echo ProcessKit runtime не найден. Запусти cc-sync из checkout Orchestra.
  exit /b 12
)
if not defined USE_PROCESSKIT_RUNTIME if defined CC_PROCESSKIT_CLI if /I not "%CC_PROCESSKIT_CLI%"=="off" (
  echo ProcessKit runtime не найден. Запусти cc-sync из checkout Orchestra.
  exit /b 12
)
if not defined USE_PROCESSKIT_RUNTIME where processkit-cli >nul 2>&1 && (
  echo ProcessKit runtime не найден. Запусти cc-sync из checkout Orchestra.
  exit /b 12
)
if /I "%PROVIDER%"=="codex" goto :run_codex
if /I not "%PROVIDER%"=="claude" (
  echo Недопустимый provider "%PROVIDER%". Разрешены: claude, codex.
  exit /b 2
)
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
rem Prefer the standalone processkit-cli (CC_PROCESSKIT_CLI or PATH) for the whole
rem provider session. processkit-runtime validates probe schema/surfaces, writes durable
rem JSONL under .work\processes\_processor, and falls back to CC_PROCESSKIT_PYTHON only
rem when no CLI is selected. Explicitly broken backends fail closed with exit 10.
if not defined USE_PROCESSKIT_RUNTIME goto :run_uncontained
pwsh -NoProfile -File "%PROCESSKIT_RUNTIME%" run-root --interactive --work "%PROJECT_ROOT%\.work" --label processor-start-claude -- claude --agent processor %MODEL_ARG%%EXTRA_ARGS% --allowedTools "Bash(codex exec:*)" "Bash(pwsh -File tools/codex-runtime.ps1:*)" --permission-mode auto "Start now, following your system prompt: take the orchestrator lock, then process .work/Tasks_Queue.md end to end — capture batches of parallel-safe tasks, plan them, implement in parallel worktrees, review, merge via the merger, and publish (ff-merge + push + CI), looping until no not-started tasks remain. Report progress as you go."
exit /b %ERRORLEVEL%
:run_uncontained
claude --agent processor %MODEL_ARG%%EXTRA_ARGS% --allowedTools "Bash(codex exec:*)" "Bash(pwsh -File tools/codex-runtime.ps1:*)" --permission-mode auto "Start now, following your system prompt: take the orchestrator lock, then process .work/Tasks_Queue.md end to end — capture batches of parallel-safe tasks, plan them, implement in parallel worktrees, review, merge via the merger, and publish (ff-merge + push + CI), looping until no not-started tasks remain. Report progress as you go."
exit /b %ERRORLEVEL%

:run_codex
set "CODEX_PROCESSOR_RUNTIME=%LAUNCHER_DIR%..\tools\codex-processor-runtime.ps1"
if exist "%CODEX_PROCESSOR_RUNTIME%" goto :codex_runtime_found
set "CODEX_PROCESSOR_RUNTIME=%LAUNCHER_DIR%codex-processor-runtime.ps1"
if exist "%CODEX_PROCESSOR_RUNTIME%" goto :codex_runtime_found
echo Codex processor runtime не найден. Запусти cc-sync из checkout Orchestra.
echo Проверены: "%LAUNCHER_DIR%..\tools\codex-processor-runtime.ps1" и "%LAUNCHER_DIR%codex-processor-runtime.ps1".
exit /b 12
:codex_runtime_found
if not defined USE_PROCESSKIT_RUNTIME goto :run_codex_uncontained
if defined MODEL_VALUE goto :run_codex_contained_model
pwsh -NoProfile -File "%PROCESSKIT_RUNTIME%" run-root --work "%PROJECT_ROOT%\.work" --label processor-start-codex -- pwsh -NoProfile -File "%CODEX_PROCESSOR_RUNTIME%" start -Root "%PROJECT_ROOT%" %EXTRA_ARGS%
exit /b %ERRORLEVEL%
:run_codex_contained_model
pwsh -NoProfile -File "%PROCESSKIT_RUNTIME%" run-root --work "%PROJECT_ROOT%\.work" --label processor-start-codex -- pwsh -NoProfile -File "%CODEX_PROCESSOR_RUNTIME%" start -Root "%PROJECT_ROOT%" -Model "%MODEL_VALUE%" %EXTRA_ARGS%
exit /b %ERRORLEVEL%
:run_codex_uncontained
if defined MODEL_VALUE goto :run_codex_uncontained_model
pwsh -NoProfile -File "%CODEX_PROCESSOR_RUNTIME%" start -Root "%PROJECT_ROOT%" %EXTRA_ARGS%
exit /b %ERRORLEVEL%
:run_codex_uncontained_model
pwsh -NoProfile -File "%CODEX_PROCESSOR_RUNTIME%" start -Root "%PROJECT_ROOT%" -Model "%MODEL_VALUE%" %EXTRA_ARGS%
exit /b %ERRORLEVEL%

rem --force-lock: route the operator force-takeover through the single transactional path
rem `state-tx.ps1 release --force` - the same owner/legacy/corrupt-lock diagnostics the TUI's
rem force-lock uses - resolving the runner by the checkout-vs-mirror rule (checkout tools\ first,
rem then the flat cc-sync mirror next to this launcher). Fall back to a raw `rd /s /q` only when
rem pwsh (PowerShell 7) is unavailable in PATH or the runner cannot be resolved.
:force_unlock
set "STATE_TX=%LAUNCHER_DIR%..\tools\state-tx.ps1"
if exist "%STATE_TX%" goto :force_unlock_run
set "STATE_TX=%LAUNCHER_DIR%state-tx.ps1"
if exist "%STATE_TX%" goto :force_unlock_run
goto :force_unlock_fallback
:force_unlock_run
where pwsh >nul 2>&1
if errorlevel 1 goto :force_unlock_fallback
echo Force-releasing .work\orchestrator.lock via state-tx release --force - use only if you are sure the previous processor is not running.
pwsh -NoProfile -File "%STATE_TX%" release --force --work ".work"
goto :eof
:force_unlock_fallback
if not exist ".work\orchestrator.lock" goto :eof
echo Removing .work\orchestrator.lock - pwsh unavailable, using raw fallback - use only if you are sure the previous processor is not running.
rd /s /q ".work\orchestrator.lock"
goto :eof
