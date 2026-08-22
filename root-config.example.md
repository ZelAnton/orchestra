# Orchestra global configuration template.
#
# This file is copied to ~/.orchestra/root-config.md. It is the only global
# configuration source: OS environment variables are not read as settings.
#
# Precedence:
#   project .work/config.md -> ~/.orchestra/root-config.md -> documented default.
# The root-only keys below are never accepted from a project config.md.
# Leave a key commented to use its default. Values are trimmed and comments are ignored.
#
# Root-only provider/runtime keys
#
# ORCHESTRA_PROVIDER: claude
#   Values: claude | codex. Selects the root processor implementation.
# ORCHESTRA_CLAUDE_PERMISSION_MODE: auto
#   Values: auto | bypassPermissions. Selects Claude's permission mode; bypassPermissions
#   is an explicit operator choice and applies to spawned Claude subagents.
# ORCHESTRA_AUTO_APPROVE: off
#   Values: on | off. Enables the durable approval gate's operator pre-consent.
# ORCHESTRA_CODEX_MODEL: unset
#   Any Codex model name, or unset. Sets the native Codex root/role model.
# ORCHESTRA_CODEX_REASONING: high
#   Values: low | medium | high | xhigh. Sets native Codex reasoning effort.
# ORCHESTRA_CODEX_SANDBOX: danger-full-access
#   Values: workspace-write | danger-full-access. Sets native Codex sandbox.
# ORCHESTRA_CODEX_MAX_THREADS: 6
#   Integer from 2 through 32. Limits native Codex root-agent concurrency.
# CODEX_HOME: ~/.codex
#   Path to the Codex home containing generated agents and sessions.
# CC_PROCESSKIT_CLI: unset
#   unset = auto-discover ~/.orchestra/processkit-cli(.exe)/PATH; off = disable CLI;
#   any other value = required processkit-cli executable path/name.
# CC_PROCESSKIT_PYTHON: unset
#   Optional Python executable with importable processkit; used only as legacy fallback.
# ORCHESTRA_REGISTRY_PATH: ~/.orchestra/projects.json
#   Path to the user-global project registry.
# BASH_DEFAULT_TIMEOUT_MS: 1900000
#   Default foreground Bash timeout exported by long-running launchers.
# BASH_MAX_TIMEOUT_MS: 1900000
#   Maximum foreground Bash timeout exported by long-running launchers.
#
# Project keys (the same keys are valid in a repository's .work/config.md).
# A project value overrides the root value for these keys.
#
# MAX_PARALLEL: 5
#   Integer >= 1. Maximum concurrent task workers.
# COHORT_SIZE: 3xMAX_PARALLEL
#   Positive integer or 3xMAX_PARALLEL. Maximum tasks selected for one cohort.
# COHORT_MAX_AGE: 90
#   Integer >= 1. Maximum admission age in minutes before the cohort closes.
# REVIEW_MIN_PASSES: 2
#   Integer >= 1. Minimum review passes before integration.
# REVIEW_LOOP_MAX: 8
#   Integer >= 1. Maximum review/repair iterations.
# INTEGRATION_LOOP_MAX: 8
#   Integer >= 1. Maximum integration repair iterations.
# CI_FIX_MAX: 5
#   Integer >= 1. Maximum post-CI repair iterations.
# STAGNATION_LIMIT: 2
#   Integer >= 2. Consecutive no-progress passes before escalation.
# QUARANTINE_MAX_ATTEMPTS: 3
#   Integer >= 1. Attempts allowed for quarantined work.
# CALL_DEADLINE_SEC: 1800
#   Integer >= 1. Per-agent call deadline in seconds.
# CALL_MAX_ATTEMPTS: 2
#   Integer >= 1. Maximum retries for an agent call.
# CALL_OUTPUT_MAX_BYTES: 1048576
#   Integer >= 1. Maximum captured agent output.
# COHORT_BUDGET_SEC: 0
#   Integer >= 0. Cohort wall-clock budget; 0 means unlimited.
# COHORT_TOKEN_BUDGET: 0
#   Integer >= 0. Cohort token budget; 0 means unlimited.
# COHORT_TOKEN_BUDGET_STRICT: false
#   Values: true | false. Rejects unmetered usage when true.
# SMOKE_CMD: unset
#   Shell command used as the project smoke verification command.
# VERIFICATION_MODE: disabled
#   Values: auto | required | disabled. Controls publication verification.
# VERIFICATION_COMMANDS: unset
#   JSON array of non-empty commands used for verification.
# PUSH: true
#   Values: true | false. Allows the processor to publish when policy also permits.
# CI_WATCH: true
#   Values: true | false. Waits for terminal remote CI after publication.
# PUBLISH_CI_DEADLINE_SEC: 1800
#   Integer >= 1. Publication CI watch deadline in seconds.
# PUBLISH_CI_BACKOFF_SEC: 30
#   Integer >= 1. Delay between publication CI polls.
# PUBLISH_LINEAR_HISTORY: false
#   Values: true | false. Requires linear publication history.
# APPROVAL_DEADLINE_SEC: 86400
#   Integer >= 1. Approval request lifetime in seconds.
# NOTIFY_CMD: unset
#   Optional notification command for durable event notifications.
# REVIEWER_TIERING: true
#   Values: true | false. Enables standard/deep reviewer tier selection.
# MAIN_BRANCH: autodetect
#   Branch name, or autodetect. Selects the repository integration branch.
# EVENTS_OUTBOX: on
#   Values: on | off. Enables durable event outbox telemetry.
# KB: on
#   Values: on | off. Enables knowledge-base context enrichment.
# KB_TTL: 8
#   Integer >= 1. Knowledge entries' freshness window.
# KB_CAP: 12
#   Integer >= 1. Maximum knowledge entries included in a prompt.
# CLAUDE_CODER_FAST_MODEL: sonnet
#   Values: haiku | sonnet | opus | fable. Fast Claude coder model.
# CLAUDE_CODER_MODEL: sonnet
#   Values: haiku | sonnet | opus | fable. Standard Claude coder model.
# CLAUDE_CODER_DEEP_MODEL: opus
#   Values: haiku | sonnet | opus | fable. Deep Claude coder model.
# CLAUDE_REVIEWER_STD_MODEL: sonnet
#   Values: haiku | sonnet | opus | fable. Standard Claude reviewer model.
# CLAUDE_REVIEWER_MODEL: opus
#   Values: haiku | sonnet | opus | fable. Deep Claude reviewer model.
# CODEX_CODER: off
#   Values: off | fast | fast+std | all. Enables Codex coder tiers.
# CODEX_REVIEWER: off
#   Values: off | fast | fast+std | deep | all. Enables Codex reviewer tiers.
# CODEX_CIFIX: off
#   Values: off | on. Enables Codex CI-fix role.
# CODEX_MODEL: unset
#   Optional legacy Codex model override for adapter roles.
# CODEX_CODER_MODEL: unset
#   Optional model for the standard Codex coder.
# CODEX_CODER_DEEP_MODEL: gpt-5.6-sol
#   Model for the deep Codex coder.
# CODEX_REVIEWER_MODEL: unset
#   Optional model for the standard Codex reviewer.
# CODEX_REVIEWER_DEEP_MODEL: gpt-5.6-sol
#   Model for the deep Codex reviewer.
# CODEX_REASONING: auto
#   Values: auto | low | medium | high | xhigh. Adapter reasoning effort.
# CODEX_SANDBOX: workspace-write
#   Values: read-only | workspace-write. Adapter sandbox mode.
# CODEX_NETWORK: on
#   Values: on | off. Adapter network access.
# CODEX_CMD: codex
#   Codex executable or launcher path for adapter calls.
