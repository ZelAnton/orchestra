# Launcher tests

Scriptable, LLM-free tests for `launchers\cc-*.cmd`. Each test runs the real
launcher file in a throwaway temporary sandbox (own `.work\` and current
directory, own `PATH` with fake `claude`/`codex` stubs that record the exact
arguments they receive instead of doing anything) and asserts on those
arguments, exit codes, side effects (files written/removed) and, where
relevant, stdout text. Nothing here touches this repository's own `.work\`
or working tree.

## Running

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests\launchers\run-all.ps1
```

Runs every `test-*.ps1` in this directory (each as an isolated child
process) and exits non-zero if any of them fails. Run a single file the same
way, e.g. `... -File tests\launchers\test-cc-processor.ps1`, to iterate on
one launcher.

`run-all.ps1` is cross-platform (task T-090): on Windows it runs the whole suite,
spawning each test with Windows PowerShell (`powershell.exe`) - which is what the
`.cmd`-launcher tests were validated against; on macOS/Linux it runs only the
cross-platform engine tests marked with a `# ci:posix` comment
(`test-sync-runtime.ps1`, `test-doctor-runtime.ps1`, `test-generate-coders.ps1`),
spawning them with `pwsh`, and skips the Windows-only `.cmd`-launcher tests. The CI
matrix runs this file on both `windows-latest` and `ubuntu-latest`.

## Coverage

One test file per `launchers\cc-*.cmd`, except `cc-sync.cmd` and `cc-doctor.cmd`
(see below - both are thin wrappers covered via their engines). `common.ps1` holds
the shared harness (sandbox setup, fake `claude`/`codex`, launcher invocation,
assertions) - see the comments there for how it works and for two
environment-specific workarounds it applies only to sandboxed *copies* of the
launchers (never to the real files):

- CRLF normalization, needed because these launchers ship with LF-only line
  endings and `chcp 65001`, which triggers a real cmd.exe multi-byte
  read-ahead corruption bug under any non-interactive/redirected invocation
  (exactly what an automated test, or a CI runner, does) - normalizing to
  CRLF in the sandbox copy eliminates it.
- One narrowly-scoped cosmetic string substitution for `cc-status.cmd`, whose
  single-line embedded Cyrillic message hits a related corruption that (unlike the
  line-boundary case CRLF fixes) breaks the entire surrounding `powershell -Command`
  parse. Its exact wording does not affect the logic under test. (`cc-doctor.cmd`
  historically needed the same treatment; since T-090 it is a thin wrapper with no
  embedded non-ASCII and needs no fixup.)

Per T-018's constraint, the tests never hardcode the literal value of the
`--permission-mode` flag (it is expected to change independently in a
parallel task): `Get-ExpectedPermissionMode` extracts whatever value is
currently in a launcher's own source and asserts that the launcher actually
forwards it, rather than asserting a fixed string.

## `cc-sync.cmd` is intentionally not covered

`cc-sync.cmd` regenerates `coder.md`/`coder_fast.md`/`coder_deep.md` from
`coder.template.md` (`generate-coders.cmd`/`.ps1`, including a `git diff`
call) and then mirrors agent definitions and launcher scripts via `robocopy`
into `%USERPROFILE%\.claude\agents` and `%USERPROFILE%\.claude\scripts`.
Exercising it faithfully in a sandbox would mean either running it against
the real repository checkout and the real `%USERPROFILE%\.claude\*` mirror
(unacceptable side effects for a test run) or copying the entire relevant
slice of the repository (template, generator, generated variants, `.git`)
into a throwaway tree and separately redirecting `%USERPROFILE%` for the
robocopy step - at that point the "test" is mostly re-implementing
`cc-sync.cmd`'s own orchestration rather than exercising it as a black box,
for a launcher with no argument parsing to speak of (it takes none) and no
`claude`/`codex` invocation. Given the cost/value tradeoff, and that this
launcher is a thin, low-risk wrapper around already-standard tools (`git`,
`robocopy`, the existing `generate-coders` scripts) rather than the kind of
bespoke argument-parsing logic (`--force-lock`, `--model`, `EXTRA_ARGS`,
quote handling) this suite targets, it is excluded here.

Since task T-090, `cc-sync.cmd`/`cc-sync.sh` are thin wrappers over one
cross-platform engine, `tools/sync-runtime.ps1`. The valuable, mutation-bearing
part — the transactional mirror (staged publish, journal-backed rollback,
manifest-scoped pruning, directory-vs-file healing) — is covered directly and
side-effect-free by `test-sync-runtime.ps1`, which drives that runtime as a child
`pwsh` process against a synthetic repo tree and a throwaway destination root (never
the real `~/.claude`). Because the runtime is a single `pwsh` script, running that
test under `pwsh` on Windows and on Linux exercises byte-for-byte the same code, so
its pass/fail result is the cross-platform equivalence proof for sync.

## `cc-doctor.cmd`/`.sh` and generation are covered via their engines too

Also since T-090, `cc-doctor.cmd`/`cc-doctor.sh` are thin wrappers over one
cross-platform engine, `tools/doctor-runtime.ps1` (the old inline `.cmd` program and
its separate POSIX shell reimplementation are gone). Its behaviour — exec-permission
classification, effective `CODEX_*` and their fail-closed validation, KB status, the
Windows sandbox profile block (real classification on Windows, an `N/A` line on
POSIX), and the queue/config/lock/worktree/main-branch/mirror audit — is covered
directly and hermetically by `test-doctor-runtime.ps1`, which drives that runtime as
a child `pwsh` process against a synthetic project tree and a throwaway home (never
the machine's real `~/.claude` or `~/.codex`, and never the ambient `CODEX_*`).

`test-generate-coders.ps1` covers the template generator side-effect-free: it copies
`generate-coders.ps1` and the two `*.template.md` into a throwaway tree, runs it, and
asserts the five variants are well-formed (UTF-8 without BOM, LF-only, no leftover
`{{PLACEHOLDER}}`), deterministic (a second run is byte-identical), and reproduce the
committed `agents/*.md` byte-for-byte.

All three of these engine/generation tests are `# ci:posix`-marked, so - like
`test-sync-runtime.ps1` - running them under `pwsh` on Windows and on Linux exercises
byte-for-byte the same code, which is the cross-platform equivalence proof for doctor
and for generation.
