# Конфигурация Orchestra и переменные окружения

Пользовательские настройки Orchestra больше не читаются из системных переменных
окружения. Глобальные настройки находятся в ~/.orchestra/root-config.md, а
настройки конкретного проекта — в .work/config.md.

Порядок разрешения: .work/config.md -> ~/.orchestra/root-config.md -> default.

root-config.md содержит комментарии со всеми ключами, допустимыми значениями и
эффектом каждого ключа. Шаблон в репозитории — root-config.example.md. Все ключи
из repository config.md также разрешены в root config; root-only ключи
(ORCHESTRA_*, CODEX_HOME, CC_PROCESSKIT_*, ORCHESTRA_REGISTRY_PATH и launcher
timeouts) из project config игнорируются.

## Основные root keys

| Ключ | Значения / default | Эффект |
|---|---|---|
| ORCHESTRA_PROVIDER | claude или codex; claude | Выбор root processor. |
| ORCHESTRA_CLAUDE_PERMISSION_MODE | auto или bypassPermissions; auto | Permission mode Claude launchers. |
| ORCHESTRA_AUTO_APPROVE | on или off; off | Operator pre-consent durable approval gates. |
| ORCHESTRA_CODEX_MODEL | model id; unset | Модель Codex-native processor/roles. |
| ORCHESTRA_CODEX_REASONING | low, medium, high или xhigh; high | Native Codex reasoning effort. |
| ORCHESTRA_CODEX_SANDBOX | workspace-write или danger-full-access; danger-full-access | Native Codex sandbox. |
| ORCHESTRA_CODEX_MAX_THREADS | integer 2..32; 6 | Native Codex concurrency. |
| CODEX_HOME | path; ~/.codex | Codex roles and sessions location. |
| CC_PROCESSKIT_CLI | unset, off или executable path | ProcessKit CLI selection. |
| CC_PROCESSKIT_PYTHON | unset или executable path | Legacy ProcessKit fallback. |
| ORCHESTRA_REGISTRY_PATH | path; ~/.orchestra/projects.json | Project registry location. |
| BASH_DEFAULT_TIMEOUT_MS / BASH_MAX_TIMEOUT_MS | positive integer; 1900000 | Long-running launcher timeouts. |

## What remains environment-only

Следующие переменные являются process protocol, test или external-tool сигналами,
а не пользовательской конфигурацией и намеренно не читаются из root-config.md:

- ORCHESTRA_PROCESSKIT_ROOT_RUN_ID, CC_CODEX_EXEC_GRANT, ORCHESTRA_CODEX_ROLE_TOPIC,
  ORCHESTRA_BROKER_*, RUNTIME_LAYOUT;
- *_FAULT, *_DEBUG и test synchronization signals;
- MSBUILDDISABLENODEREUSE, DOTNET_CLI_USE_MSBUILD_SERVER;
- стандартные переменные внешних инструментов, которые читает сам инструмент.

Launchers may use ORCHESTRA_HOME only as a portable installation/test path override;
it does not select any configuration value. The normal root is always ~/.orchestra.
