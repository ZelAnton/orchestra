@echo off
chcp 65001 >nul
setlocal
rem Возобновляет прерванную сессию processor в текущей папке (последнюю сессию
rem Claude Code здесь — через --continue), вместо холодного старта с нуля.
rem processor и так умеет восстанавливаться с нуля (Фаза 0 его системного промпта),
rem но --continue экономит на повторном обнаружении контекста, если сессия жива.
rem
rem На resume processor переиспользует СВОЙ лок (.work\orchestrator.lock той же
rem сессии) — поэтому cc-resume штатно продолжает работу, снимать лок не нужно. Если
rem же лок оставила ДРУГАЯ, действительно мёртвая сессия и resume упирается в него —
rem запусти cc-processor --force-lock, только убедившись, что тот processor не работает.
rem
rem ВНИМАНИЕ: --continue подхватывает САМУЮ ПОСЛЕДНЮЮ сессию Claude Code в этом каталоге,
rem какой бы она ни была. Не запускай между падением и cc-resume другие cc-* лаунчеры
rem или интерактивный claude — иначе --continue возобновит их сессию, а не processor.
rem --allowedTools (грант): предвыданный сессионный грант на автономный запуск codex
rem адаптерами (тот же набор, что в cc-processor.cmd) — иначе classifier auto-режима
rem отклонит вызов посреди возобновлённого прогона. Передаём два префиксных гранта:
rem   Bash(pwsh -File tools/codex-runtime.ps1:*) — строка, которую РЕАЛЬНО исполняет
rem     Bash-инструмент: адаптеры гонят codex через runtime-обёртку
rem     `pwsh -File tools/codex-runtime.ps1 <подкоманда> ...`, поэтому один этот префикс
rem     покрывает все подкоманды runtime; сам `codex exec` runtime порождает дочерним
rem     процессом и через permission-гейт Bash он не проходит (находка ревью R-01).
rem   Bash(codex exec:*) — канонический якорь codex-автономии, который называет
rem     CC_CODEX_EXEC_GRANT и от которого отталкиваются гейт Фазы 1.1 / cc-doctor / cc-config.
rem Стоят перед флагом permission-mode (вариативный флаг не должен поглотить следующие
rem токены). Режим auto и --continue сохранены.
rem CC_CODEX_EXEC_GRANT="codex exec": тот же единый контракт launcher->processor, что и в
rem cc-processor.cmd — явный признак уже выданного сессионного гранта, который читают гейт
rem Фазы 1.1 processor.md и cc-doctor; значение остаётся каноническим префиксом `codex exec`,
rem который они сверяют с `<CODEX_CMD> exec` (не с pwsh-обёрткой). При нём постоянное
rem allow-правило не требуется.
rem Внутри setlocal (см. выше) — видна дочернему claude, не утекает в вызывающую оболочку.
set "CC_CODEX_EXEC_GRANT=codex exec"
claude --agent processor --allowedTools "Bash(codex exec:*)" "Bash(pwsh -File tools/codex-runtime.ps1:*)" --permission-mode auto --continue "Continue processing .work/Tasks_Queue.md from where you left off, per your system prompt's Фаза 0 recovery logic."
