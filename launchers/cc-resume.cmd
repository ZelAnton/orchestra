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
rem Поэтому resume АДРЕСНЫЙ: --continue берётся лишь при наличии аренды processor'а этого
rem проекта (.work\orchestrator.lock\lease.json с role=processor — сама её позиция под
rem .work этого каталога адресует корень; роль сверяем здесь). Нет такой аренды —
rem запускаем ЯВНОЕ холодное восстановление (Фаза 0 с нуля, без --continue), а не
rem возобновляем произвольную последнюю сессию. Точную сверку корня/owner id делает
rem Фаза 0 processor'а через tools\state-tx.ps1 verify (docs\queue_contract.md, §16).
rem --allowedTools "Bash(codex exec:*)": предвыданный сессионный грант на запуск codex
rem адаптерами (как в cc-processor.cmd) — иначе classifier auto-режима отклонит codex
rem посреди возобновлённого прогона. Стоит перед флагом permission-mode (вариативный флаг
rem не должен поглотить следующие токены). Режим auto и --continue сохранены.
rem CC_CODEX_EXEC_GRANT="codex exec": тот же единый контракт launcher->processor, что и в
rem cc-processor.cmd — явный признак уже выданного сессионного гранта, который читают гейт
rem Фазы 1.1 processor.md и cc-doctor; при нём постоянное allow-правило не требуется.
rem Внутри setlocal (см. выше) — видна дочернему claude, не утекает в вызывающую оболочку.
set "CC_CODEX_EXEC_GRANT=codex exec"

rem Addressed check: an addressed processor lease exists only if the lease file is
rem present AND carries role=processor. The role line's spacing differs between
rem PowerShell 7 ("role": ) and 5.1 ("role":  ), so match "role" and "processor"
rem separately. goto/|| branching is used (not if(...)else(...)) so the ")" inside
rem "Bash(codex exec:*)" and the cold prompt cannot prematurely close a cmd block.
set "LEASE=.work\orchestrator.lock\lease.json"
if not exist "%LEASE%" goto :coldstart
findstr /C:"\"role\"" "%LEASE%" >nul 2>&1 || goto :coldstart
findstr /C:"\"processor\"" "%LEASE%" >nul 2>&1 || goto :coldstart
claude --agent processor --allowedTools "Bash(codex exec:*)" --permission-mode auto --continue "Continue processing .work/Tasks_Queue.md from where you left off, per your system prompt's Фаза 0 recovery logic."
goto :done
:coldstart
echo No addressed processor lease (.work\orchestrator.lock\lease.json role=processor) for this project - performing a cold recovery instead of resuming an arbitrary last session.
claude --agent processor --allowedTools "Bash(codex exec:*)" --permission-mode auto "Cold start: no addressed processor session to continue. Follow your system prompt's Фаза 0 recovery logic from scratch (reconcile any interrupted state without --continue), then process .work/Tasks_Queue.md end to end."
:done
