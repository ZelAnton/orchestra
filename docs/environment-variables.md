# Переменные окружения Orchestra

Этот справочник перечисляет операторские переменные окружения, которые Orchestra
учитывает при запуске и работе. Настройки конкретного проекта, для которых не указан
env-фолбэк, по-прежнему задаются в `.work/config.md`.

## Основное управление

| Переменная | Значения / default | Назначение |
|---|---|---|
| `ORCHESTRA_PROVIDER` | `claude` / `codex`; default `claude` | Выбирает provider для поддерживающих его launchers во всех проектах. Аргумент `codex\|claude` у `cc-processor`, `cc-resume`, `cc-thinker`, `cc-audit` или `cc-enhance` имеет приоритет. |
| `ORCHESTRA_AUTO_APPROVE` | `on` / `off`; default `off` | Автоматически подтверждает внутренние gates `human-review`, `force-lock` и `policy-bypass`. Это не разрешения Claude/Codex. Любое другое значение вызывает fail-closed. |
| `CODEX_CODER` | `off`, `fast`, `fast+std`, `all`; default `off` | В Claude-root режиме направляет реализацию соответствующих уровней в Codex; `all` включает `coder_deep`. |
| `CODEX_REVIEWER` | `off`, `fast`, `fast+std`, `deep`, `all`; default `off` | В Claude-root режиме направляет ревью соответствующих уровней в Codex; `deep` добавляет augment, `all` полностью заменяет ревью всех уровней. |
| `KB` | `on` / `off`; default `on` | Включает или отключает чтение и обновление `.work/knowledge/`. |

Для `CODEX_CODER`, `CODEX_REVIEWER` и `KB` действует следующий приоритет:

```text
.work/config.md -> environment -> default
```

Значение из `.work/config.md` всегда переопределяет одноимённую переменную окружения.
При `all` deep-исполнитель и deep-ревьюер всегда используют `gpt-5.6-sol`/`xhigh`,
игнорируя общие `CODEX_MODEL`/`CODEX_REASONING`; ревью запускается отдельным новым
checker-тредом Codex.
В Codex-root режиме `CODEX_CODER` и `CODEX_REVIEWER` игнорируются, поскольку все роли
там уже исполняются как Codex-native custom agents. Полный контракт env-фолбэка описан
в [`config.example.md`](../config.example.md).

## Настройки Codex-native сессий

Эти переменные применяются, когда provider выбран как `codex`. Модель, reasoning,
sandbox и `CODEX_CMD` общие для processor и прямых ролей; max threads нужен только
multi-agent processor:

| Переменная | Значения / default | Назначение |
|---|---|---|
| `ORCHESTRA_CODEX_MODEL` | model id; default — модель Codex CLI | Выбирает модель корневого processor и его custom agents. |
| `ORCHESTRA_CODEX_REASONING` | `low`, `medium`, `high`, `xhigh`; default `high` | Задаёт reasoning effort. |
| `ORCHESTRA_CODEX_SANDBOX` | `workspace-write`, `danger-full-access`; default `danger-full-access` | Задаёт sandbox всей Codex-native сессии; subagents наследуют выбранное значение. |
| `ORCHESTRA_CODEX_MAX_THREADS` | целое `2..32`; default `6` | Ограничивает число agent threads. Это не то же самое, что `MAX_PARALLEL` задач когорты. |
| `CODEX_CMD` | имя или путь; default `codex` | Низкоуровневое переопределение executable для Codex-native runtime. В гибридном Claude-root режиме одноимённый ключ задаётся через `.work/config.md`. |
| `CODEX_HOME` | путь; default `~/.codex` | Определяет, куда `cc-sync` устанавливает `orchestra_*.toml` и где runtime ищет роли. Это стандартная переменная Codex, которую Orchestra учитывает. |

Оба runtime независимо от окружения фиксируют `approval_policy=never`; processor runtime
дополнительно фиксирует `features.multi_agent=true` и `agents.max_depth=1`. Реализация
находится в [`tools/codex-processor-runtime.ps1`](../tools/codex-processor-runtime.ps1) и
[`tools/codex-role-runtime.ps1`](../tools/codex-role-runtime.ps1).

## Изоляция процессов

| Переменная | Значения / default | Назначение |
|---|---|---|
| `CC_PROCESSKIT_CLI` | не задано, `off` или executable/path | Не задано — искать `processkit-cli` в `PATH`; `off` — отключить standalone CLI; иное значение — обязательный конкретный backend, ошибка которого обрабатывается fail-closed. |
| `CC_PROCESSKIT_PYTHON` | путь к Python; default не задан | Устаревший fallback. Python должен поддерживать `import processkit`; используется, если standalone CLI не выбран. |

Общий resolver документирован в
[`tools/processkit-runtime.ps1`](../tools/processkit-runtime.ps1). На Windows он сначала
учитывает значение текущего процесса, затем перечитывает User/Machine scope для явно
заданных `CC_PROCESSKIT_CLI` и `CC_PROCESSKIT_PYTHON`.

`ORCHESTRA_PROCESSKIT_ROOT_RUN_ID` — внутренняя per-run аттестация, которую runtime
передаёт только процессам внутри `processkit-cli run`. Это не пользовательская настройка:
агенты и операторы не должны задавать её вручную. Без неё `state-tx` отказывает роли
`processor` в acquire/resume/heartbeat с кодом 20.

## Таймауты Claude Bash

| Переменная | Рекомендуемое значение | Назначение |
|---|---:|---|
| `BASH_DEFAULT_TIMEOUT_MS` | `1900000` | Стандартное ожидание foreground-вызова Codex runtime. |
| `BASH_MAX_TIMEOUT_MS` | `1900000` | Максимальное ожидание такого вызова. |

`cc-processor` и `cc-resume` устанавливают эти значения для дочерней сессии, только
если они ещё не заданы. Переменные управляют ожиданием, а не разрешениями. Подробнее —
в [`docs/operations.md`](operations.md).

## Путь пользовательского registry

| Переменная | Значение / default | Назначение |
|---|---|---|
| `ORCHESTRA_REGISTRY_PATH` | путь к JSON-файлу; default `~/.orchestra/projects.json` | Подменяет пользовательский registry проектов. Предназначена для оператора и тестов, например для полностью отдельного набора проектов и inbox. Агенты не должны устанавливать её сами. |

Разрешение пути реализовано в
[`tools/project-registry-lib.ps1`](../tools/project-registry-lib.ps1).

## Примеры для Windows

Установить значения постоянно для текущего пользователя:

```powershell
[Environment]::SetEnvironmentVariable('ORCHESTRA_PROVIDER', 'codex', 'User')
[Environment]::SetEnvironmentVariable('ORCHESTRA_CODEX_REASONING', 'high', 'User')
[Environment]::SetEnvironmentVariable('ORCHESTRA_CODEX_MAX_THREADS', '6', 'User')
[Environment]::SetEnvironmentVariable('ORCHESTRA_AUTO_APPROVE', 'on', 'User')
[Environment]::SetEnvironmentVariable('CODEX_CODER', 'all', 'User')
[Environment]::SetEnvironmentVariable('CODEX_REVIEWER', 'all', 'User')
```

После изменения откройте новый терминал и проверьте эффективную конфигурацию:

```powershell
cc-doctor
```

Удалить пользовательскую переменную:

```powershell
[Environment]::SetEnvironmentVariable('ORCHESTRA_PROVIDER', $null, 'User')
```

Установить значение только для текущей PowerShell-сессии:

```powershell
$env:ORCHESTRA_PROVIDER = 'codex'
```

## Что не является пользовательской env-настройкой

Остальные ключи `.work/config.md`, включая `MAX_PARALLEL`, `COHORT_SIZE`,
`COHORT_TOKEN_BUDGET`, `CODEX_CIFIX`, `CODEX_MODEL`, `CODEX_REASONING`,
`CODEX_SANDBOX`, `CODEX_NETWORK`, `PUSH` и `CI_WATCH`, не имеют env-фолбэка.

`CC_CODEX_EXEC_GRANT`, `ORCHESTRA_PROCESSKIT_ROOT_RUN_ID`, `ORCHESTRA_CODEX_ROLE_TOPIC`,
`ORCHESTRA_BROKER_*`, `RUNTIME_LAYOUT`,
`MSBUILDDISABLENODEREUSE` и `DOTNET_CLI_USE_MSBUILD_SERVER` выставляются runtime или
launchers внутренне. Переменные `*_FAULT` и внутренние `*_DEBUG` предназначены для
тестирования и диагностики, а не для управления Orchestra.
