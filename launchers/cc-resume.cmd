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
rem --allowedTools "Bash(codex exec:*)": предвыданный сессионный грант на запуск codex
rem адаптерами (как в cc-processor.cmd) — иначе classifier auto-режима отклонит codex
rem посреди возобновлённого прогона. Стоит перед флагом permission-mode (вариативный флаг
rem не должен поглотить следующие токены). Режим auto и --continue сохранены.
rem CC_CODEX_EXEC_GRANT="codex exec": тот же единый контракт launcher->processor, что и в
rem cc-processor.cmd — явный признак уже выданного сессионного гранта, который читают гейт
rem Фазы 1.1 processor.md и cc-doctor; при нём постоянное allow-правило не требуется.
rem Внутри setlocal (см. выше) — видна дочернему claude, не утекает в вызывающую оболочку.
set "CC_CODEX_EXEC_GRANT=codex exec"
claude --agent processor --allowedTools "Bash(codex exec:*)" --permission-mode auto --continue "Continue processing .work/Tasks_Queue.md from where you left off, per your system prompt's Фаза 0 recovery logic."
