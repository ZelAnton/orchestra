# База знаний Orchestra

## Как пользоваться этим файлом

Это постоянная карта **данного репозитория**. Перед поиском по проекту сначала прочитайте
этот файл, затем открывайте только названные здесь источники истины. Обновляйте карту в той
же правке, если меняются роли, поток обработки, конфигурация, runtime-артефакты или команды.
Не путайте её с опциональной `.work/knowledge/`: та база создаётся в подключённом проекте,
накапливает опыт его прогонов и обслуживается агентом `knowledge_curator`.

## Назначение и установка

Orchestra — не приложение и не библиотека. Это комплект системных промптов Claude Code,
адаптеров Codex CLI и кросс-платформенных launchers для автономной обработки очереди задач.
Агентские описания лежат в каталоге `agents/` и устанавливаются в
`%USERPROFILE%\.claude\agents`; launchers устанавливаются в `%USERPROFILE%\.claude\scripts`.
После изменения ролей или launcher выполните `launchers\cc-sync.cmd` (или `cc-sync.sh`),
иначе Claude продолжит использовать старую копию.
Стратегические направления и порядок развития зафиксированы в
`LOOP_ORCHESTRA_ROADMAP.md`; это план, а не действующий runtime-контракт.
Архитектура неблокирующего human in the loop, web/Android control plane, событий и PoC
описана в `OBSERVABILITY_PLATFORM_PLAN.md`. Там же определены proposal-curation и разделение
исполняемых задач на `current` и `next_major`; это пока проектируемые, не действующие
runtime-контракты.

## Основной поток

```text
источник задачи -> Tasks_Queue.md -> planner -> task.md
    -> coder в отдельном worktree -> reviewer <-> coder
    -> merger в _integration -> full_reviewer <-> coder
    -> ff-merge main -> push/CI -> knowledge_curator -> журнал/очистка
```

Всем циклом владеет `processor.md`. Он берёт `orchestrator.lock`, восстанавливает
прерванное состояние, выбирает параллельно безопасный батч, создаёт Git worktree или Jujutsu
workspace, коммитит результаты листовых агентов, публикует их и чистит runtime-состояние.
Листовые coder/reviewer не должны самостоятельно управлять очередью, коммитами или push.

## Карта исходных файлов

Все перечисленные ниже агентские `.md` лежат в каталоге `agents/` (в тексте — краткими
именами файлов, например `agents/processor.md`); там же — шаблоны `coder.template.md` и
`reviewer.template.md`. Документация (`AGENTS.md`, `knowledge.md`, `config.example.md`,
`constraints.example.md`, `README.md`, `plans/`) и генератор `generate-coders.ps1`/`.cmd`
остаются в корне репозитория. Отдельно, в подкаталоге `docs/`, лежат: `docs/operations.md` —
руководство оператора (запуск и мониторинг сессии processor, чтение status/journal,
обработка эскалаций); `docs/queue_contract.md` — единый нормативный источник механического
контракта постановки задач в `.work/Tasks_Queue.md` (форма заголовка, нумерация `T-NNN`,
статусы, тело, дедуп по трём источникам, поведение под локом, запреты), на который ссылаются
все пять популяторов очереди вместо переизложения правил.

### Координация и интеграция

- `processor.md` — канонический state machine: фазы 0–6, resume, лимиты циклов,
  маршрутизация Claude/Codex, публикация и CI. При споре между кратким описанием и фазами
  ориентируйтесь на алгоритм фаз.
- `planner.md` — выбирает непересекающиеся conflict domains и создаёт
  `.work/tasks/<T-ID>/task.md`; код и очередь не меняет.
- `executor.md` — только механические переходы строк очереди: capture, requeue,
  escalation, delete.
- `merger.md` — последовательно сливает готовые ветки в `_integration`, разрешает или
  карантинит конфликты, пишет `merge_report.md`.

### Реализация и ревью

- `coder.template.md` — **единственный источник** общей логики Claude-coder.
  `generate-coders.ps1` создаёт `coder_fast.md`, `coder.md`, `coder_deep.md`; их нельзя
  редактировать по отдельности. Уровни: fast = Sonnet/medium, standard = Sonnet/high,
  deep = Opus/xhigh.
- `reviewer_std.md` — дешёвое per-task ревью fast-задач; `reviewer.md` — полное ревью
  standard/deep; оба ведут `R-NN` в task-local `review.md`.
- `full_reviewer.md` — ревью совокупного результата в `_integration`, ведёт `F-NN` в
  `review_integration.md`.
- `coder_codex.md` и `reviewer_codex.md` — тонкие адаптеры `codex exec` с обязательным
  fallback на Claude. Codex-coder поддерживает реализацию, `R-` и при
  `CODEX_CIFIX=on` точечный Режим 3, но не интеграционные `F-`. Codex-reviewer работает
  read-only.

### Наполнение очереди и знания

Пять популяторов ниже механику постановки в очередь не переизлагают, а ссылаются на общий
нормативный источник `docs/queue_contract.md` (форма заголовка, нумерация, статусы, тело,
дедуп по трём источникам, лок, запреты); каждый несёт лишь свой уникальный мандат.

- `queue_builder.md` — превращает пользовательский источник в недублирующиеся `T-NNN`.
- `thinker.md` — интерактивно исследует идею и после согласования создаёт задачи.
- `code_auditor.md` — ищет дефекты исходного кода; `enhancement_scout.md` — ищет
  улучшения проекта; оба только пополняют очередь.
- `github_sync.md` — синхронизирует issues/PR через `gh`; PR закрывает, но не мержит.
- `knowledge_curator.md` — единственный писатель runtime-базы `.work/knowledge/`.

### Конфигурация и запуск

- `config.example.md` — каноническое описание `.work/config.md`, всех defaults и
  Codex/KB-переключателей. `launchers\cc-config.cmd`/`.sh` создаёт локальные `.work/config.md`
  (блочный seed) и `.work/constraints.md` (полная копия), не перезаписывая существующие.
- `constraints.example.md` — шаблон человекочитаемой политики ограничений проекта
  (`.work/constraints.md`): denylist путей, ветки/remotes, push/merge policy, обязательные
  проверки, пороги размера, human-review категории. Сеется целиком через `cc-config`.
- `cc-processor` запускает цикл, `cc-resume` продолжает последнюю сессию,
  `cc-status`/`cc-journal` читают состояние, `cc-doctor` проверяет Codex, `cc-queue`,
  `cc-thinker`, `cc-audit`, `cc-enhance`, `cc-github` запускают соответствующие роли.

## Runtime-артефакты подключённого проекта

| Путь | Владелец / назначение |
|---|---|
| `.work/Tasks_Queue.md` | входная очередь; новые задачи имеют ID `T-NNN` |
| `.work/Tasks_Done.md` | архив завершённых задач |
| `.work/Github_Sync.md` | таблица соответствия GitHub issues/PR и задач очереди; ведёт `github_sync` |
| `.work/config.md` | локальные переопределения, ключи `UPPER_SNAKE_CASE` |
| `.work/constraints.md` | человекочитаемая политика ограничений проекта (denylist путей, ветки/remotes, push/merge policy, обязательные проверки, пороги, human-review категории); шаблон — `constraints.example.md`, сеет `cc-config`; читают processor/planner/coder/reviewer, нет файла — деградация без ошибок |
| `.work/orchestrator.lock` | защита от двух processor одновременно |
| `.work/PAUSE` | kill switch: при наличии processor штатно останавливается на границе фазы/раунда (освобождает lock, состояние подхватит Фаза 0); ставит/снимает `cc-pause`/`cc-unpause` |
| `.work/batch.md` | append-only манифест текущей когорты (строки волн приёма дописываются, не переписываются) |
| `.work/cohort_state.md` | состояние роллинг-приёма когорты (открыт/закрыт, волна, счётчики) |
| `.work/tasks/<T-ID>/task.md` | дескриптор и критерии от planner |
| `.work/tasks/<T-ID>/review.md` | per-task находки `R-NN` |
| `.work/tasks/<T-ID>/status.md` | статус листового агента |
| `.work/worktrees/<T-ID>` | изолированная рабочая копия задачи |
| `.work/worktrees/_integration` | join-барьер и совокупный результат батча |
| `.work/review_integration.md` | интеграционные находки `F-NN` |
| `.work/integration_state.md` | служебное состояние джойна (Ревью-SHA предыдущего интеграционного ревью, F-циклов); ведёт processor, создаётся в Фазе 5, удаляется в 6.4 |
| `.work/merge_report.md` | результаты merge и причины карантина |
| `.work/status.md` | текущий обзор processor |
| `.work/journal.md` | постоянный журнал завершённых прогонов |
| `.work/events.jsonl` | append-only машинный event-outbox; пишет только processor (одна JSON-строка на событие) при `EVENTS_OUTBOX:on`; машинный контракт для будущей платформы наблюдаемости; не привязан к одной когорте, переживает очистку Фазы 6, никогда не переписывается/не усекается; Markdown-артефакты остаются источником истины для человека |
| `.work/knowledge/` | runtime-KB целевого проекта при `KB:on` |

## Инварианты, которые нужно сохранять

- У очереди и runtime-KB по одному писателю на каждом этапе; не добавляйте параллельную
  запись без нового механизма синхронизации.
- Per-task изменения изолированы; пересечение conflict domains запрещает общий батч.
- Maker/checker должны быть независимы. Если Codex реализовал задачу, Claude её ревьюит.
- `R-NN` относятся к одной задаче, `F-NN` — к интеграции всего батча.
- В основном дереве точечный CI-фикс коммитится явным списком файлов, не `git add -A`.
- `--force-lock` допустим только после проверки, что прежний processor действительно умер.
- YAML frontmatter обязан начинаться с первого байта; агентские Markdown-файлы хранятся
  как UTF-8 без BOM.

## Быстрая проверка изменений

1. При изменении coder-логики запустите
   `powershell -NoProfile -ExecutionPolicy Bypass -File .\generate-coders.ps1`.
2. Просмотрите `git diff`, особенно границы владения файлами и VCS-разрешения ролей.
3. Для config/маршрутизации синхронно проверьте `processor.md`, `config.example.md`,
   соответствующий адаптер и `cc-doctor.cmd`.
4. Для новой роли проверьте frontmatter, launcher (если нужен) и правила исключений
   `cc-sync.cmd`.
5. Smoke-test выполняйте в одноразовом целевом репозитории, не на неопубликованной работе.

## Быстрый поиск

- Роль агента: `rg -n "^(name:|description:|# Роль)" -g "*.md" .`
- Фаза оркестратора: `rg -n "^## Фаза|Фаза 5\." agents/processor.md`
- Runtime-файл и его писатели: `rg -n "review_integration|merge_report|Tasks_Queue" -g "*.md" .`
- Конфигурационный ключ: `rg -n "CODEX_CIFIX|REVIEW_LOOP_MAX" agents/processor.md config.example.md`
