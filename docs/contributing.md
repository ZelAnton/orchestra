# Orchestra Developer Guide

Use this guide when changing Orchestra itself. For operating an installed orchestra, use
the [Operator's Guide](operations.md). Start repository work with the ownership and control-flow
map in [`knowledge.md`](../knowledge.md) and the repository rules in
[`AGENTS.md`](../AGENTS.md).

## 1. Add a new role

1. Decide whether the role is standalone or belongs to one of the two generated families.
   Use [Project Structure & Module Organization](../AGENTS.md#project-structure--module-organization)
   and the [source-file map](../knowledge.md#карта-исходных-файлов) to identify its owner,
   caller, and runtime artifacts before adding a file.
2. Put YAML frontmatter at byte 0 and save the file as UTF-8 without BOM. Set non-empty
   `name`, `description`, `model`, and `permissionMode`; make `name` equal the lowercase
   snake_case filename, and set `permissionMode: auto`. The executable definition is
   [`tools/validate-agents.ps1`](../tools/validate-agents.ps1); the repository policy is
   [Coding Style & Naming Conventions](../AGENTS.md#coding-style--naming-conventions).
3. For a coder-family role, edit
   [`agents/coder.template.md`](../agents/coder.template.md). For a reviewer-family role,
   edit [`agents/reviewer.template.md`](../agents/reviewer.template.md). If a prompt-wide
   invariant applies to both families, add it to both templates. Never hand-edit
   `coder.md`, `coder_fast.md`, `coder_deep.md`, `reviewer.md`, or `reviewer_std.md`.
4. Add or change generated-role metadata in the `$variants` table in
   [`generate-coders.ps1`](../generate-coders.ps1). Its token replacement covers the
   **whole template body**, not only frontmatter: coder variants use `NAME`, `MODEL`,
   `EFFORT`, and `DESCRIPTION`; reviewer variants also parameterize `MAXTURNS`, `IDENTITY`,
   and `FASTPATH`. Keep a genuinely standalone role outside this generator.
5. Register the role where it is selected and invoked. Start with the canonical phases in
   [`agents/processor.md`](../agents/processor.md) and update the role ownership/control-flow
   sections in [`knowledge.md`](../knowledge.md#карта-исходных-файлов) if responsibilities,
   phases, artifacts, or invariants change.
6. Review the template exclusions in `ExcludedAgents` in
   [`tools/sync-runtime.ps1`](../tools/sync-runtime.ps1), `$excludeNames` in
   [`tools/validate-agents.ps1`](../tools/validate-agents.ps1), and the agent-mirror
   freshness block in [`tools/doctor-runtime.ps1`](../tools/doctor-runtime.ps1). A real role
   must remain included. If a new non-agent template needs exclusion, add the same narrow
   exception in all three places.
7. If the prompt mentions `docs/queue_contract.md` or `Tasks_Queue_Format.md`, include the
   canonical resolution-and-search-ban block in context, even when the mention is only a
   citation. Copy the maintained form from a template and run
   [`tools/check-queue-contract-path-guard.ps1`](../tools/check-queue-contract-path-guard.ps1).
8. Run `pwsh -File ./generate-coders.ps1`, then
   `pwsh -File ./tools/validate-agents.ps1` and
   `pwsh -File ./tools/check-consistency.ps1`. Inspect all regenerated variants, not only
   the new role metadata. The CI source of truth is the `validate` job in
   [`.github/workflows/ci.yml`](../.github/workflows/ci.yml).
9. Run [`tests/launchers/test-generate-coders.ps1`](../tests/launchers/test-generate-coders.ps1),
   [`tests/launchers/test-sync-runtime.ps1`](../tests/launchers/test-sync-runtime.ps1), and
   a disposable-project smoke test of the caller. Follow
   [Build, Test, and Development Commands](../AGENTS.md#build-test-and-development-commands).

## 2. Add a new configuration key

Treat the key as one contract propagated through this chain:

[`tools/policy-schema.ps1`](../tools/policy-schema.ps1) →
[`config.example.md`](../config.example.md) →
[`tools/doctor-runtime.ps1`](../tools/doctor-runtime.ps1) →
[`tools/check-consistency.ps1`](../tools/check-consistency.ps1).

1. Add one descriptor to `Get-SchemaConfigKeys` in
   [`tools/policy-schema.ps1`](../tools/policy-schema.ps1). Define its type, default,
   enum/range, environment precedence, and sensitivity there; this is the versioned schema
   source consumed by `tools/policy.ps1`.
2. Add the key and exact default to
   [Values by default](../config.example.md#значения-по-умолчанию). If `cc-config` should
   seed it, also add it inside the `config.md seed` markers at the top of
   [`config.example.md`](../config.example.md). Do not create a second default in prose.
3. Document behavior, ownership, precedence, and failure semantics under
   [What each key means](../config.example.md#что-означает-каждый-ключ). For a Codex key,
   also update [Codex agents](../config.example.md#codex-агенты-coder_codex-reviewer_codex)
   and, when values are bounded,
   [Allowed Codex key values](../config.example.md#допустимые-значения-codex-ключей-валидация-fail-closed).
4. Update every runtime consumer, starting with the relevant phase in
   [`agents/processor.md`](../agents/processor.md) and the owning role or runner. Preserve
   schema validation before the value can affect routing or mutation.
5. Add the key to the hardcoded `$known` table in
   [`tools/doctor-runtime.ps1`](../tools/doctor-runtime.ps1). Doctor must work from the
   standalone `cc-sync` mirror, so it cannot load `config.example.md` from a checkout. Add
   fail-closed value validation there when the key has an enum or range.
6. Extend the appropriate machine guard. `tools/check-consistency.ps1` Class 4 compares
   Doctor's allowlist with the documented defaults; Class 5 compares schema key names and
   Codex enums with the documentation. If the key joins the bounded Codex set, also update
   [`tools/check-codex-config-guard.ps1`](../tools/check-codex-config-guard.ps1) and the
   processor validation form it checks.
7. Add validation, default, invalid-value, precedence, and migration cases to
   [`tests/test-policy.ps1`](../tests/test-policy.ps1) and Doctor cases to
   [`tests/launchers/test-doctor-runtime.ps1`](../tests/launchers/test-doctor-runtime.ps1).
   Update launcher tests if `cc-config` seed output changes.
8. Run the policy and Doctor tests, both configuration guards, and the full
   [`tests/launchers/run-all.ps1`](../tests/launchers/run-all.ps1) entry point. Verify that
   the new standalone `tests/test-*.ps1` entry point is explicitly wired into
   [`.github/workflows/ci.yml`](../.github/workflows/ci.yml); CI does not auto-discover it.

## 3. Add a new `tools/` runner

1. Put the executable contract in `tools/<name>.ps1`, with deterministic exit codes and
   `Get-Help` text. Keep the shared implementation in PowerShell 7 when `.cmd` and `.sh`
   launchers need identical behavior; use the existing
   [`tools/doctor-runtime.ps1`](../tools/doctor-runtime.ps1) and
   [`tools/sync-runtime.ps1`](../tools/sync-runtime.ps1) split as the launcher/engine model.
2. Add thin `cc-<action>.cmd` and `cc-<action>.sh` wrappers only when the runner is a
   user-facing command. Preserve the launcher naming, `.cmd` CRLF policy, and validation
   commands in [Coding Style & Naming Conventions](../AGENTS.md#coding-style--naming-conventions)
   and [Build, Test, and Development Commands](../AGENTS.md#build-test-and-development-commands).
3. Rely on `Get-ManagedPairs` in
   [`tools/sync-runtime.ps1`](../tools/sync-runtime.ps1) to mirror every `tools/*.ps1` file
   to `<destination>/scripts`. Do not add a per-runner copy list. `sync-runtime.ps1` itself
   is the sole runner exclusion because a mirror has no checkout source to synchronize.
4. Make each agent caller implement the
   [checkout-versus-mirror resolution rule](../knowledge.md#резолвинг-раннеров-toolsps1-чекаут-vs-зеркало):
   resolve once per run. The existence of `tools/<name>.ps1` alone does not prove the checkout
   layout: require all three Orchestra source markers (`agents/processor.md`,
   `generate-codex-agents.ps1`, `tools/sync-runtime.ps1`). Only then use literal
   `tools/<name>.ps1`; otherwise invoke
   literal `~/.claude/scripts/<name>.ps1` directly in the command. Do not pass the tilde
   form through a variable or rebuild it from `$HOME`. Never execute a same-named runner from
   a target project's own, stale, or gitignored `tools/` directory.
5. Audit permissions against
   [Auto-mode permissions and pre-granted consent](../knowledge.md#разрешения-auto-режима-и-политика-согласие--заранее).
   Ordinary local runners need no central grant. A runner that launches an autonomous
   agent, publishes, performs destructive work, or executes a project-defined command
   needs the narrow user-granted rule and normal refusal/escalation path. Never let a role
   edit `.claude/settings*` or reshape a command to self-grant permission.
6. If the new runner needs a central grant, update the checkout and mirror forms together
   in `cc-config.cmd`, `cc-config.sh`, `config.example.md`, Doctor diagnostics, and a static
   guard. Keep the global allowlist minimal; prefer a repository-local grant for
   project-specific operations. Use
   [`tools/check-codex-runtime-path-guard.ps1`](../tools/check-codex-runtime-path-guard.ps1)
   as the paired-artifact example.
7. Add focused `tests/test-<name>.ps1` behavior tests. Extend
   [`tests/launchers/test-sync-runtime.ps1`](../tests/launchers/test-sync-runtime.ps1) to
   prove mirror installation/removal and add launcher tests under `tests/launchers/` when
   wrappers exist. Test checkout and mirror-only resolution on Windows and POSIX where the
   contract is cross-platform.
8. Wire every new test explicitly into the `validate` job in
   [`.github/workflows/ci.yml`](../.github/workflows/ci.yml), or into
   [`tests/launchers/run-all.ps1`](../tests/launchers/run-all.ps1) when it is a launcher
   test. New `tests/test-*.ps1` and `tools/*.ps1` files are not auto-discovered by CI.
9. Run `pwsh -File ./tests/launchers/test-sync-runtime.ps1`, the focused runner tests,
   `pwsh -File ./tools/check-consistency.ps1`, and a disposable checkout/mirror smoke test.
   Re-run `cc-sync` before testing the installed form, as described in
   [The operating toolchain](operations.md#8-the-operating-toolchain-cc-sync-cc-doctor-and-what-ci-actually-checks).

## 4. Change the queue contract

1. Treat [`docs/queue_contract.md`](queue_contract.md) as the normative source. Identify
   the exact affected sections before changing agents, tools, or examples.
2. Update the contract first. Keep queue entry form, identifiers, statuses, transaction
   semantics, state transitions, trust/redaction, and event semantics in their existing
   numbered sections instead of restating them in role prompts.
3. Update the executable owner for the affected section: usually
   [`tools/queue-tx.ps1`](../tools/queue-tx.ps1),
   [`tools/state-tx.ps1`](../tools/state-tx.ps1),
   [`tools/outbox.ps1`](../tools/outbox.ps1), or
   [`tools/redaction.ps1`](../tools/redaction.ps1). Update `agents/processor.md` when a
   phase or transition changes.
4. Update every role that consumes the changed rule, but link back to the numbered queue
   contract section instead of copying its mechanics. Use the
   [queue population map](../knowledge.md#наполнение-очереди-и-знания) to find the five
   producers and [`tools/check-consistency.ps1`](../tools/check-consistency.ps1) to catch
   phase and runtime-artifact drift.
5. Keep the canonical guard block around every queue-contract link in `agents/*.md` and
   both generator templates. Do not rely on a manual “read versus citation” distinction.
   Do not introduce a `docs/roadmap_contract.md` citation without the same bounded path
   resolution context.
6. Add or update focused tests such as
   [`tests/launchers/test-queue-tx.ps1`](../tests/launchers/test-queue-tx.ps1),
   [`tests/launchers/test-state-tx.ps1`](../tests/launchers/test-state-tx.ps1),
   [`tests/test-outbox.ps1`](../tests/test-outbox.ps1), or
   [`tests/test-redaction.ps1`](../tests/test-redaction.ps1). Explicitly wire any new
   standalone test into CI.
7. Run [`tools/check-queue-contract-path-guard.ps1`](../tools/check-queue-contract-path-guard.ps1),
   [`tools/check-consistency.ps1`](../tools/check-consistency.ps1), and the affected focused
   tests. Regenerate both template families if either template changed.
8. Run the mandatory resilience gate
   [`tests/test-harness.ps1`](../tests/test-harness.ps1) when lifecycle, queue, state,
   publication, recovery, or transaction behavior changes. Use
   [`tests/test-harness-crashmatrix.ps1`](../tests/test-harness-crashmatrix.ps1) for the
   exhaustive fault sweep.

## Contract guards and CI gates

These scripts protect machine-verifiable copies of repository contracts:

| Guard | Protected contract |
|---|---|
| [`generate-coders.ps1`](../generate-coders.ps1) plus the CI drift check | Generated coder and reviewer variants are byte-for-byte derived from their templates and variant metadata. |
| [`tools/validate-agents.ps1`](../tools/validate-agents.ps1) | Agent encoding, byte-zero frontmatter, required fields, filename/name agreement, snake_case, and `permissionMode: auto`. |
| [`tools/check-consistency.ps1`](../tools/check-consistency.ps1) | Agent config-key references, processor phase references, runtime artifacts in `knowledge.md`, Doctor's key allowlist, and policy-schema/documentation parity. |
| [`tools/check-codex-config-guard.ps1`](../tools/check-codex-config-guard.ps1) | Bounded Codex allowed values and defaults across `config.example.md`, `processor.md`, and Doctor. |
| [`tools/check-codex-runtime-path-guard.ps1`](../tools/check-codex-runtime-path-guard.ps1) | Checkout/mirror Codex runtime commands, paired allow-rules, literal-tilde handling, and matching adapter/documentation guidance. |
| [`tools/check-codex-sandbox-guard.ps1`](../tools/check-codex-sandbox-guard.ps1) | `approval_policy=never`, sandbox arguments, and fail-closed `ENV_LIMIT/sandbox-init` escalation in both Codex adapters and their documentation. |
| [`tools/check-queue-contract-path-guard.ps1`](../tools/check-queue-contract-path-guard.ps1) | Canonical queue/spec resolution and the disk-wide-search ban in every role/template that cites a queue contract, plus the normative docs. |
| [`tests/test-reviewer-codex-gate.ps1`](../tests/test-reviewer-codex-gate.ps1) | The `reviewer_codex` clean-pass and `SUMMARY-R` decision contract. |
| [`tests/test-engine-processor-parity.ps1`](../tests/test-engine-processor-parity.ps1) | Pre-cutover outcome parity between the processor-prose control loop and deterministic Rust engine for the reference cohort. |

The `validate` job in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) also makes
the following behavioral tests mandatory on Windows and Linux unless the test documents a
platform-specific skip:

- [`tests/test-codex-runtime.ps1`](../tests/test-codex-runtime.ps1) protects safe argv,
  process/timeout handling, sandbox refusal, no-commit cleanup, and adapter runtime results.
- [`tests/test-policy.ps1`](../tests/test-policy.ps1) protects schema-driven validation,
  migration, path/denylist guards, approval gates, and publish preconditions.
- [`tests/launchers/run-all.ps1`](../tests/launchers/run-all.ps1) protects launcher behavior
  and the sync, Doctor, generator, queue, and state runtimes; POSIX runs only tests marked
  `# ci:posix`.
- [`tests/test-metrics.ps1`](../tests/test-metrics.ps1) protects read-only aggregation,
  selection, tolerant event parsing, and the no-lock/no-write invariant.
- [`tests/test-supervisor.ps1`](../tests/test-supervisor.ps1) protects deadlines,
  cancellation, process-tree cleanup, output limits, retry classification, and budgets.
- [`tests/test-harness.ps1`](../tests/test-harness.ps1) is the mandatory CI-level lifecycle
  gate. It checks representative publication, quarantine, escalation, divergence, and
  crash-recovery equivalence scenarios over disposable repositories.
- [`tests/test-harness-crashmatrix.ps1`](../tests/test-harness-crashmatrix.ps1) expands the
  recovery equivalence sweep across all fault points in a separate, time-limited,
  non-blocking job on main pushes and manual dispatch.

[`tests/test-outbox.ps1`](../tests/test-outbox.ps1) and
[`tests/test-redaction.ps1`](../tests/test-redaction.ps1) are additional focused regression
tests present in the repository, but they are not direct standalone entries in the current
CI workflow. Run them when their contracts change, and wire new tests explicitly rather
than assuming filename discovery.

## Before committing

Use [Quick check of changes](../knowledge.md#быстрая-проверка-изменений) as the common
baseline; do not duplicate it here. Apply the scenario checklist above, then:

1. Inspect the complete diff for source/generated pairs, role ownership, permission
   boundaries, runtime-artifact names, and documentation links.
2. Run every guard named by the affected scenario and its focused behavior tests.
3. Run `pwsh -File ./tests/launchers/run-all.ps1` for role, configuration, runner, Doctor,
   sync, queue, or launcher changes.
4. Run `pwsh -File ./tests/test-harness.ps1` for control-plane or recovery changes.
5. Confirm each new script or standalone test has an explicit CI invocation.
6. Smoke-test installed behavior in a disposable target repository, never against
   unpublished work in a real consuming project.
