<#
.SYNOPSIS
    Deterministic tests (T-084) for the executable policy boundary: tools/policy.ps1 and
    its schema source tools/policy-schema.ps1.

.DESCRIPTION
    tools/policy.ps1 makes .work/config.md + .work/constraints.md an executed boundary
    (schema-driven validation/migration + a destructive-operation runtime guard) rather
    than prose the roles are trusted to have honoured. Because it IS code, it is unit
    tested directly. Each scenario builds a throwaway sandbox under the temp dir, drives
    the real tool as a child pwsh process, and asserts on its output/exit code. Nothing
    here touches this repository's own .work/.

    Covered (per T-084's acceptance criteria):
      * schema: single source; its config key NAMES equal config.example.md's defaults
        table, and the six Codex enums equal the validation table (the same contract
        tools/check-consistency.ps1 Class 5 enforces as the smoke gate).
      * migration: preserves every value/comment (append-only) and refuses (does not
        silently default) an unknown / duplicated / invalid field.
      * invalid values: out-of-enum, out-of-range int, non-boolean, unknown key.
      * the destructive-op runtime guard: canonicalises the path, enforces root/object,
        rejects a '..' escape, a symlink/junction routed outside, a substituted worktree,
        a foreign directory, and an out-of-root main-tree/work-file target; validates the
        VCS worktree registration when git is present.
      * denylist reconciliation of the ACTUAL changed paths (post-return / pre-publish),
        including rename (both sides) and case-insensitive matching, with the example
        block NOT applied.
      * the conflict-integration case: a multi-task changed set with one denylisted file
        is flagged so the forbidden edit does not reach the integration result.
      * allowed-branch / allowed-remote / push policy as a precondition.

.EXAMPLE
    pwsh -File tests/test-policy.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$script:Tool = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\policy.ps1')).Path
$script:SchemaLib = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\policy-schema.ps1')).Path
$script:ConfigExample = (Resolve-Path (Join-Path $PSScriptRoot '..\config.example.md')).Path
$script:ConstraintsExample = (Resolve-Path (Join-Path $PSScriptRoot '..\constraints.example.md')).Path
$script:PsExe = ([System.Diagnostics.Process]::GetCurrentProcess()).MainModule.FileName
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:TempItems = [System.Collections.Generic.List[string]]::new()
$script:IsWin = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)

function New-TempDir {
    $p = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'policy-t-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    $script:TempItems.Add($p)
    return $p
}
function New-Sandbox {
    $root = New-TempDir
    New-Item -ItemType Directory -Force -Path (Join-Path $root '.work') | Out-Null
    return $root
}
function Write-Utf8 { param([string]$Path, [string]$Text) [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8) }

# Runs policy.ps1 as a child pwsh process; returns @{ ExitCode; Out; Err }.
function Invoke-Policy {
    param([string[]]$ToolArgs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:PsExe
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8
    $psi.StandardErrorEncoding = $script:Utf8
    foreach ($a in (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:Tool) + $ToolArgs)) {
        $psi.ArgumentList.Add($a)
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outT = $proc.StandardOutput.ReadToEndAsync()
    $errT = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Out = $outT.Result; Err = $errT.Result }
}

function Assert-True { param([bool]$Cond, [string]$Msg) if (-not $Cond) { $script:Failures.Add("FAIL - $Msg") } }
function Assert-Equal { param($Expected, $Actual, [string]$Msg) if ($Expected -ne $Actual) { $script:Failures.Add("FAIL - ${Msg}: expected [$Expected], got [$Actual]") } }
function Assert-Exit { param($R, [int]$Code, [string]$Msg) if ($R.ExitCode -ne $Code) { $script:Failures.Add("FAIL - ${Msg}: expected exit $Code, got $($R.ExitCode) (out=[$($R.Out.Trim())] err=[$($R.Err.Trim())])") } }
function Assert-OutMatch { param($R, [string]$Pattern, [string]$Msg) $t = "$($R.Out)`n$($R.Err)"; if ($t -notmatch $Pattern) { $script:Failures.Add("FAIL - ${Msg}: [$Pattern] not in output [$($t.Trim())]") } }

# =============================================================================
# 1. schema is a single source consistent with config.example.md
# =============================================================================
{
    . $script:SchemaLib
    $schema = Get-OrchestraSchema
    $schemaKeys = @($schema.config | ForEach-Object { $_.name }) | Sort-Object

    # config.example.md defaults table keys
    $cfgLines = Get-Content -LiteralPath $script:ConfigExample -Encoding utf8
    $tableKeys = [System.Collections.Generic.List[string]]::new()
    $inTable = $false
    foreach ($l in $cfgLines) {
        if ($l -match '^##\s+Значения по умолчанию') { $inTable = $true; continue }
        if ($inTable -and $l -match '^##\s') { break }
        if ($inTable -and $l -match '^\|\s*`([A-Z][A-Z0-9_]*)`\s*\|') { $tableKeys.Add($Matches[1]) }
    }
    $tableSorted = @($tableKeys) | Sort-Object
    Assert-Equal ($tableSorted -join ',') ($schemaKeys -join ',') 'schema config keys equal config.example.md defaults table'

    # Codex enum sets equal the validation table. Enum options within the allowed-values
    # cell are separated by an escaped pipe (` \| `), so split the row on UNESCAPED pipes to
    # isolate the columns first, then take the backtick tokens of the allowed-values column.
    $inVal = $false
    $valEnum = @{}
    foreach ($l in $cfgLines) {
        if ($l -match '^###\s+Допустимые значения Codex') { $inVal = $true; continue }
        if ($inVal -and $l -match '^#{1,3}\s') { break }
        if ($inVal -and $l -match '^\|\s*`CODEX_') {
            $cells = [regex]::Split($l, '(?<!\\)\|') | ForEach-Object { $_.Trim() }
            # cells: ['', key, allowed, default, '']
            if ($cells.Count -ge 4) {
                $keyM = [regex]::Match($cells[1], '`(CODEX_[A-Z]+)`')
                if ($keyM.Success) {
                    $vals = @([regex]::Matches($cells[2], '`([^`]+)`') | ForEach-Object { $_.Groups[1].Value }) | Sort-Object
                    $valEnum[$keyM.Groups[1].Value] = ($vals -join ',')
                }
            }
        }
    }
    foreach ($k in $valEnum.Keys) {
        $d = $schema.config | Where-Object { $_.name -eq $k } | Select-Object -First 1
        $schemaEnum = @($d.enum) | Sort-Object
        Assert-Equal $valEnum[$k] ($schemaEnum -join ',') "schema enum for $k equals validation table"
    }
    Assert-Equal 33 $schema.config.Count 'schema has 33 config keys'

    # T-095: the publish-gate tuning keys and the CI-required-checks policy section exist.
    foreach ($k in @('PUBLISH_CI_DEADLINE_SEC', 'PUBLISH_CI_BACKOFF_SEC', 'APPROVAL_DEADLINE_SEC')) {
        Assert-True ([bool]($schema.config | Where-Object { $_.name -eq $k })) "schema has publish-gate key $k"
    }
    Assert-True ([bool]($schema.policy | Where-Object { $_.id -eq 'publish-ci' })) 'schema has the publish-ci policy section'
}.Invoke()

# =============================================================================
# 2. validate-config: valid / invalid / unknown / duplicate / empty=default
# =============================================================================
{
    $sb = New-Sandbox
    $cfg = Join-Path $sb '.work\config.md'
    Write-Utf8 $cfg "# demo`nMAX_PARALLEL: 8`nPUSH: false`nCODEX_REASONING: high`nSMOKE_CMD:`n"
    $r = Invoke-Policy @('validate-config', '--file', $cfg)
    Assert-Exit $r 0 'validate-config accepts a valid file (empty SMOKE_CMD = unset)'

    Write-Utf8 $cfg "MAX_PARALLEL: 0`nCODEX_REASONING: turbo`nFOO_BAR: 1`nPUSH: maybe`nMAX_PARALLEL: 5`n"
    $r = Invoke-Policy @('validate-config', '--file', $cfg)
    Assert-Exit $r 3 'validate-config rejects invalid file'
    Assert-OutMatch $r 'below the minimum' 'validate-config: int range reported'
    Assert-OutMatch $r "not one of" 'validate-config: enum reported'
    Assert-OutMatch $r "unknown key 'FOO_BAR'" 'validate-config: unknown key reported'
    Assert-OutMatch $r 'not a boolean' 'validate-config: bool reported'
    Assert-OutMatch $r 'duplicate key' 'validate-config: duplicate reported'

    # T-100: xhigh is a confirmed reasoning-effort tier added to the CODEX_REASONING enum.
    Write-Utf8 $cfg "CODEX_REASONING: xhigh`n"
    $r = Invoke-Policy @('validate-config', '--file', $cfg)
    Assert-Exit $r 0 'validate-config accepts CODEX_REASONING: xhigh (enum extended in T-100)'
}.Invoke()

# =============================================================================
# 3. migrate: append-only (preserves values/comments, adds defaults), refuses bad
# =============================================================================
{
    $sb = New-Sandbox
    $cfg = Join-Path $sb '.work\config.md'
    $out = Join-Path $sb '.work\config.new.md'
    Write-Utf8 $cfg "# keep me`nMAX_PARALLEL: 8   # my tuning`n# KB: on`n"
    $r = Invoke-Policy @('migrate', '--file', $cfg, '--out', $out)
    Assert-Exit $r 0 'migrate accepts a valid file'
    $migrated = Get-Content -LiteralPath $out -Raw -Encoding utf8
    Assert-True ($migrated -match '# keep me') 'migrate: preserves standalone comment'
    Assert-True ($migrated -match 'MAX_PARALLEL: 8   # my tuning') 'migrate: preserves value + inline comment verbatim'
    Assert-True ($migrated -match '# KB: on') 'migrate: preserves user-commented key (not re-added)'
    Assert-True ($migrated -match '(?m)^# CODEX_CMD: codex') 'migrate: appends a missing default as a comment'
    Assert-True (([regex]::Matches($migrated, '(?m)^\s*#?\s*MAX_PARALLEL\s*:')).Count -eq 1) 'migrate: does not duplicate a present key'

    Write-Utf8 $cfg "MAX_PARALLEL: 8`nBOGUS_KEY: 1`n"
    $r = Invoke-Policy @('migrate', '--file', $cfg, '--out', $out)
    Assert-Exit $r 5 'migrate refuses an unknown key (no silent default)'
    Assert-OutMatch $r 'migration refused' 'migrate: refusal message'

    # an EMPTY (0-byte) config.md is a valid, migratable file (not "not found"): all
    # schema defaults are appended as comments.
    Write-Utf8 $cfg ''
    $r = Invoke-Policy @('migrate', '--file', $cfg, '--out', $out)
    Assert-Exit $r 0 'migrate: empty config.md migrates (adds all defaults)'
    $migrated = Get-Content -LiteralPath $out -Raw -Encoding utf8
    Assert-True ($migrated -match '(?m)^# MAX_PARALLEL: 5') 'migrate: empty file gets the MAX_PARALLEL default'
    $r = Invoke-Policy @('validate-config', '--file', $cfg)
    Assert-Exit $r 0 'validate-config: empty config.md is valid (all defaults)'
}.Invoke()

# =============================================================================
# 4. guard-path: valid, '..' escape, substitution, foreign dir, main-tree/work-file
# =============================================================================
{
    $sb = New-Sandbox
    $root = $sb
    $work = Join-Path $root '.work'
    New-Item -ItemType Directory -Force -Path (Join-Path $work 'worktrees') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $work 'tasks\T-045') | Out-Null

    $r = Invoke-Policy @('guard-path', '--root', $root, '--work', $work, '--object', 'worktree', '--task', 'T-045', '--path', (Join-Path $work 'worktrees\T-045'))
    Assert-Exit $r 0 'guard-path: valid worktree accepted'

    $r = Invoke-Policy @('guard-path', '--root', $root, '--work', $work, '--object', 'worktree', '--task', 'T-045', '--path', (Join-Path $work 'worktrees\..\..\..\evil'))
    Assert-Exit $r 6 "guard-path: '..' escape rejected"
    Assert-OutMatch $r "'\.\.' segment" 'guard-path: dotdot reason'

    $r = Invoke-Policy @('guard-path', '--root', $root, '--work', $work, '--object', 'worktree', '--task', 'T-045', '--path', (Join-Path $work 'worktrees\T-002'))
    Assert-Exit $r 6 'guard-path: substituted sibling worktree rejected'
    Assert-OutMatch $r 'substituted target' 'guard-path: substitution reason'

    # foreign directory entirely outside the project root
    $foreign = New-TempDir
    $r = Invoke-Policy @('guard-path', '--root', $root, '--work', $work, '--object', 'work-file', '--path', (Join-Path $foreign 'x.txt'))
    Assert-Exit $r 6 'guard-path: foreign directory (outside .work) rejected'

    # main-tree must not target .work
    $r = Invoke-Policy @('guard-path', '--root', $root, '--work', $work, '--object', 'main-tree', '--path', (Join-Path $work 'foo'))
    Assert-Exit $r 6 'guard-path: main-tree target under .work rejected'
    # main-tree in the working copy is fine
    $r = Invoke-Policy @('guard-path', '--root', $root, '--work', $work, '--object', 'main-tree', '--path', (Join-Path $root 'src\app.js'))
    Assert-Exit $r 0 'guard-path: main-tree target in working copy accepted'

    # task-dir with a mismatched id
    $r = Invoke-Policy @('guard-path', '--root', $root, '--work', $work, '--object', 'task-dir', '--task', 'T-045', '--path', (Join-Path $work 'tasks\T-099'))
    Assert-Exit $r 6 'guard-path: task-dir substitution rejected'
}.Invoke()

# =============================================================================
# 5. guard-path: symlink/junction routed outside the allowed root is rejected
# =============================================================================
{
    $sb = New-Sandbox
    $root = $sb
    $work = Join-Path $root '.work'
    New-Item -ItemType Directory -Force -Path (Join-Path $work 'worktrees') | Out-Null
    $outside = New-TempDir   # a real dir OUTSIDE the project

    # Replace .work/worktrees with a link (junction on Windows, symlink elsewhere) that
    # points outside the project. A worktree "created" under it would land outside root.
    $linkPath = Join-Path $work 'worktrees'
    $linkMade = $false
    try {
        Remove-Item -LiteralPath $linkPath -Force -Recurse -ErrorAction SilentlyContinue
        if ($script:IsWin) {
            New-Item -ItemType Junction -Path $linkPath -Target $outside -ErrorAction Stop | Out-Null
        } else {
            New-Item -ItemType SymbolicLink -Path $linkPath -Target $outside -ErrorAction Stop | Out-Null
        }
        $linkMade = $true
    } catch { }

    if ($linkMade) {
        $r = Invoke-Policy @('guard-path', '--root', $root, '--work', $work, '--object', 'worktree', '--task', 'T-045', '--path', (Join-Path $linkPath 'T-045'))
        Assert-Exit $r 6 'guard-path: worktree under a junction/symlink routed outside root is rejected'
        Assert-OutMatch $r '(escape|outside the addressed|not the addressed)' 'guard-path: link escape reason'
    } else {
        Write-Host 'SKIP - could not create a junction/symlink (privileges) - link-escape guard-path case skipped'
    }
}.Invoke()

# =============================================================================
# 6. guard-path VCS check: registered worktree passes, an unregistered dir fails
# =============================================================================
{
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $root = New-TempDir
        & git -C $root init -q 2>&1 | Out-Null
        & git -C $root -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>&1 | Out-Null
        $work = Join-Path $root '.work'
        New-Item -ItemType Directory -Force -Path (Join-Path $work 'worktrees') | Out-Null
        $wt = Join-Path $work 'worktrees\T-045'
        & git -C $root worktree add -q -b task/T-045 $wt 2>&1 | Out-Null

        $r = Invoke-Policy @('guard-path', '--root', $root, '--work', $work, '--object', 'worktree', '--task', 'T-045', '--path', $wt, '--expect-vcs', 'git')
        Assert-Exit $r 0 'guard-path(vcs): a registered git worktree passes'

        # An existing dir at the addressed path that is NOT a registered worktree.
        $root2 = New-TempDir
        & git -C $root2 init -q 2>&1 | Out-Null
        & git -C $root2 -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>&1 | Out-Null
        $work2 = Join-Path $root2 '.work'
        $wt2 = Join-Path $work2 'worktrees\T-045'
        New-Item -ItemType Directory -Force -Path $wt2 | Out-Null   # plain dir, not a worktree
        $r = Invoke-Policy @('guard-path', '--root', $root2, '--work', $work2, '--object', 'worktree', '--task', 'T-045', '--path', $wt2, '--expect-vcs', 'git')
        Assert-Exit $r 6 'guard-path(vcs): an unregistered dir masquerading as a worktree is rejected'
    } else {
        Write-Host 'SKIP - git not on PATH - guard-path VCS registration case skipped'
    }
}.Invoke()

# =============================================================================
# 7. check-paths: denylist hits (glob), example NOT applied, rename, case, clean
# =============================================================================
{
    $sb = New-Sandbox
    $constraints = Join-Path $sb '.work\constraints.md'
    Write-Utf8 $constraints @'
## Запрещённые пути (denylist)

**Активные ограничения** (по умолчанию пусто):

- `**/secrets/**`, `**/*.pem`
- `infra/**`

**Пример** (ориентир, не применяется):

- `deploy/**`

## Разрешённые ветки и remotes

**Активные ограничения**:

- Ветки публикации: `main`
- Remotes: `origin`

## Push/merge policy

**Активные ограничения**:

- Публикация (push): требует ручного подтверждения

## Обязательные проверки

**Активные ограничения** (по умолчанию пусто):

- (пусто)

## Пороги размера изменений

**Активные ограничения** (по умолчанию не заданы):

- (не задано)

## Категории обязательного human review

**Активные категории**:

- security
'@
    $changed = Join-Path $sb 'changed.txt'
    Write-Utf8 $changed "src/app.js`ninfra/deploy.tf`nsrc/secrets/key.txt`nlib/util.pem`ndeploy/x.yml`n"
    $r = Invoke-Policy @('check-paths', '--work', (Join-Path $sb '.work'), '--paths-from', $changed)
    Assert-Exit $r 7 'check-paths: denylist hits reported'
    Assert-OutMatch $r 'infra/deploy.tf' 'check-paths: infra hit'
    Assert-OutMatch $r 'secrets/key.txt' 'check-paths: secrets hit'
    Assert-OutMatch $r 'util.pem' 'check-paths: pem hit'
    Assert-True ($r.Out -notmatch 'deploy/x.yml') 'check-paths: example-block glob NOT applied (deploy allowed)'

    # rename form "old => new": both sides checked
    Write-Utf8 $changed "src/a.js => infra/b.tf`n"
    $r = Invoke-Policy @('check-paths', '--work', (Join-Path $sb '.work'), '--paths-from', $changed)
    Assert-Exit $r 7 'check-paths: rename target side hits denylist'

    # case-insensitive on Windows
    if ($script:IsWin) {
        $r = Invoke-Policy @('check-paths', '--work', (Join-Path $sb '.work'), '--path', 'INFRA/Deploy.TF')
        Assert-Exit $r 7 'check-paths: case-insensitive denylist match on Windows'
    }

    # clean set
    $r = Invoke-Policy @('check-paths', '--work', (Join-Path $sb '.work'), '--path', 'src/app.js', '--path', 'README.md')
    Assert-Exit $r 0 'check-paths: clean changed set passes'
}.Invoke()

# =============================================================================
# 8. conflict-integration: multi-task changed set, one denylisted file is flagged
# =============================================================================
{
    $sb = New-Sandbox
    $constraints = Join-Path $sb '.work\constraints.md'
    Write-Utf8 $constraints "## Запрещённые пути (denylist)`n`n**Активные ограничения**:`n`n- ``**/migrations/**```n"
    $changed = Join-Path $sb 'changed.txt'
    # files from several merged task branches; exactly one touches a denylisted path
    Write-Utf8 $changed "taskA/api.go`ntaskB/db/migrations/003_add.sql`ntaskC/ui.tsx`n"
    $r = Invoke-Policy @('check-paths', '--work', (Join-Path $sb '.work'), '--paths-from', $changed)
    Assert-Exit $r 7 'conflict-integration: the one denylisted file among many is flagged'
    Assert-OutMatch $r 'migrations/003_add.sql' 'conflict-integration: names the forbidden path'
    Assert-True ($r.Out -notmatch 'api.go') 'conflict-integration: does not flag the clean paths'
}.Invoke()

# =============================================================================
# 9. check-publish + degradation without a policy file
# =============================================================================
{
    $sb = New-Sandbox
    $constraints = Join-Path $sb '.work\constraints.md'
    Write-Utf8 $constraints @'
## Разрешённые ветки и remotes

**Активные ограничения**:

- Ветки публикации: `main`
- Remotes: `origin`

## Push/merge policy

**Активные ограничения**:

- Слияние в trunk: только ff-merge
'@
    $work = Join-Path $sb '.work'
    $r = Invoke-Policy @('check-publish', '--work', $work, '--branch', 'main', '--remote', 'origin')
    Assert-Exit $r 0 'check-publish: allowed branch+remote pass'
    $r = Invoke-Policy @('check-publish', '--work', $work, '--branch', 'develop', '--remote', 'origin')
    Assert-Exit $r 8 'check-publish: disallowed branch rejected'
    $r = Invoke-Policy @('check-publish', '--work', $work, '--branch', 'main', '--remote', 'upstream')
    Assert-Exit $r 8 'check-publish: disallowed remote rejected'
    foreach ($caseVariant in @('MAIN', 'Main')) {
        $r = Invoke-Policy @('check-publish', '--work', $work, '--branch', $caseVariant, '--remote', 'origin')
        Assert-Exit $r 8 "check-publish: branch comparison is ordinal and rejects '$caseVariant' on every platform"
    }
    foreach ($caseVariant in @('ORIGIN', 'Origin')) {
        $r = Invoke-Policy @('check-publish', '--work', $work, '--branch', 'main', '--remote', $caseVariant)
        Assert-Exit $r 8 "check-publish: remote comparison is ordinal and rejects '$caseVariant' on every platform"
    }

    # manual push confirmation blocks the push
    Write-Utf8 $constraints "## Push/merge policy`n`n**Активные ограничения**:`n`n- Публикация (push): требует ручного подтверждения`n"
    $r = Invoke-Policy @('check-publish', '--work', $work, '--branch', 'main', '--remote', 'origin')
    Assert-Exit $r 8 'check-publish: push manual-confirmation blocks'
    Assert-OutMatch $r 'do not push' 'check-publish: push-block guidance'

    # no policy file at all -> degrade to OK
    $bare = New-Sandbox
    $r = Invoke-Policy @('check-publish', '--work', (Join-Path $bare '.work'), '--branch', 'anything', '--remote', 'anywhere')
    Assert-Exit $r 0 'check-publish: no constraints.md -> unrestricted (degradation without errors)'
    $r = Invoke-Policy @('check-paths', '--work', (Join-Path $bare '.work'), '--path', 'secrets/x.pem')
    Assert-Exit $r 0 'check-paths: no constraints.md -> allowed (degradation without errors)'
    $r = Invoke-Policy @('validate-policy', '--work', (Join-Path $bare '.work'))
    Assert-Exit $r 0 'validate-policy: no file -> OK (not in force)'
}.Invoke()

# =============================================================================
# 9a. placeholder forms in the seeded constraints template
# =============================================================================
{
    . $script:SchemaLib

    # Both documented placeholder forms must be ignored by the shared parser.
    $placeholderLines = @(
        '## Разрешённые ветки и remotes',
        '',
        '**Активные ограничения**:',
        '',
        '- (пусто — ограничение не задано)',
        '- Ветки публикации: (по умолчанию — trunk)',
        '- Remotes: (не задано)',
        '- Явное значение: `origin`'
    )
    $active = Get-PolicyActiveBullets $placeholderLines 'Разрешённые ветки и remotes'
    Assert-Equal 1 $active.Count 'policy placeholders: bare and labelled forms are skipped by one parser rule'
    Assert-Equal 'Явное значение: `origin`' $active[0] 'policy placeholders: explicit value remains active'

    # Placeholder keywords use a Unicode-safe explicit terminator: whitespace, ')' or end.
    # ASCII explicit values remain active alongside Cyrillic placeholder text.
    $boundaryLines = @(
        '## Разрешённые ветки и remotes',
        '',
        '**Активные ограничения**:',
        '',
        '- (пусто)',
        '- Ветки публикации: (не задано)',
        '- Remote policy: (по умолчанию — origin)',
        '- Explicit value: upstream'
    )
    $active = Get-PolicyActiveBullets $boundaryLines 'Разрешённые ветки и remotes'
    Assert-Equal 1 $active.Count 'policy placeholders: explicit Unicode-safe terminators are skipped'
    Assert-Equal 'Explicit value: upstream' $active[0] 'policy placeholders: ASCII explicit value remains active'

    # cc-config seeds this exact template. Its default branch/remote, push and size text
    # must remain inactive, while a real explicit branch/remote policy still applies.
    $templateLines = [System.IO.File]::ReadAllLines($script:ConstraintsExample, $script:Utf8)
    Assert-Equal 0 (Get-PolicyActiveBullets $templateLines 'Разрешённые ветки и remotes').Count 'template placeholders: branch/remotes are inactive'
    $pushTemplate = Get-PolicyActiveBullets $templateLines 'Push/merge policy'
    Assert-Equal 1 $pushTemplate.Count 'template placeholders: only the explicit ff-merge invariant remains active'
    Assert-True (([string]$pushTemplate[0]) -notmatch 'Публикация \(push\)') 'template placeholders: push default is inactive'
    Assert-Equal 0 (Get-PolicyActiveBullets $templateLines 'Пороги размера изменений').Count 'template placeholders: size thresholds are inactive'

    $sb = New-Sandbox
    $work = Join-Path $sb '.work'
    $constraints = Join-Path $work 'constraints.md'
    [System.IO.File]::WriteAllText($constraints, [System.IO.File]::ReadAllText($script:ConstraintsExample, $script:Utf8), $script:Utf8)
    $r = Invoke-Policy @('check-publish', '--work', $work, '--branch', 'main', '--remote', 'origin')
    Assert-Exit $r 0 'check-publish: untouched constraints template does not restrict main/origin'
    $r = Invoke-Policy @('check-publish', '--work', $work, '--branch', 'feature/any-real-branch', '--remote', 'upstream')
    Assert-Exit $r 0 'check-publish: untouched constraints template does not restrict branch or remote'

    Write-Utf8 $constraints "## Разрешённые ветки и remotes`n`n**Активные ограничения**:`n`n- Ветки публикации: main`n- Remotes: origin`n"
    $r = Invoke-Policy @('check-publish', '--work', $work, '--branch', 'main', '--remote', 'origin')
    Assert-Exit $r 0 'check-publish: explicit bare branch+remote pass'
    $r = Invoke-Policy @('check-publish', '--work', $work, '--branch', 'develop', '--remote', 'origin')
    Assert-Exit $r 8 'check-publish: explicit bare branch restriction remains active'
}.Invoke()

# =============================================================================
# 9b. T-259 incident investigation: placeholder detector vs publish extraction
# =============================================================================
{
    . $script:SchemaLib

    # Investigation result: no live placeholder-detector gap was found. T-116 skips the
    # reported single-line label-prefixed form; the wrapped form cannot produce a target.
    $sb = New-Sandbox
    $work = Join-Path $sb '.work'
    $constraints = Join-Path $work 'constraints.md'

    # Scenario A: a wrapped placeholder leaves only label-only bullets visible to the shared
    # parser because continuation lines are not bullets. This still cannot restrict publishing:
    # Get-PublishTargets requires one or more characters after the colon, so both target lists
    # are empty and check-publish must ALLOW. No broader label-only parser rule is needed.
    $wrapped = @'
## Разрешённые ветки и remotes

**Активные ограничения**:

- Ветки публикации:
  (по умолчанию — trunk)
- Remotes:
  (не задано)
'@
    Write-Utf8 $constraints $wrapped
    $active = Get-PolicyActiveBullets ($wrapped -split "`r?`n") 'Разрешённые ветки и remotes'
    Assert-Equal 2 $active.Count 'T-259 scenario A: parser retains the two label-only bullets'
    Assert-Equal 'Ветки публикации:' $active[0] 'T-259 scenario A: branch label has no value'
    Assert-Equal 'Remotes:' $active[1] 'T-259 scenario A: remote label has no value'
    $r = Invoke-Policy @('check-publish', '--work', $work, '--branch', 'main', '--remote', 'origin')
    Assert-Exit $r 0 'T-259 scenario A: wrapped label-only placeholders cannot restrict main/origin'

    # Scenario B: this is the reported single-line incident shape. T-116's optional label
    # prefix skips it. The template spelling with a backtick token is included because, without
    # T-116, Get-PublishTargets would mistake MAIN_BRANCH for an allowed branch and DENY main.
    $singleLineCases = [ordered]@{
        'reported trunk spelling' = '- Ветки публикации: (по умолчанию — trunk)'
        'seeded backtick spelling' = '- Ветки публикации: (по умолчанию — trunk из `MAIN_BRANCH`/автоопределения)'
        'inner whitespace'         = '- Ветки публикации: ( по умолчанию — trunk)'
        'alternate label'          = '- Publish branches: (по умолчанию – trunk)'
        'remote empty'             = '- Remotes: (пусто)'
        'remote unset'             = '- Remotes: (не задано)'
        'bare placeholder'         = '- (по умолчанию — trunk)'
    }
    foreach ($case in $singleLineCases.GetEnumerator()) {
        $lines = @(
            '## Разрешённые ветки и remotes',
            '',
            '**Активные ограничения**:',
            '',
            $case.Value
        )
        Assert-Equal 0 (Get-PolicyActiveBullets $lines 'Разрешённые ветки и remotes').Count "T-259 scenario B/C: $($case.Key) is inactive"
    }

    Write-Utf8 $constraints @'
## Разрешённые ветки и remotes

**Активные ограничения**:

- Ветки публикации: (по умолчанию — trunk)
- Remotes: (не задано)
'@
    $r = Invoke-Policy @('check-publish', '--work', $work, '--branch', 'main', '--remote', 'origin')
    Assert-Exit $r 0 'T-259 scenario B: reported single-line placeholders permit main/origin'

    # Scenario D: branch/remote placeholders do not interact with the push placeholder or the
    # explicit ff-merge invariant. A real remote restriction remains active and still DENYs.
    Write-Utf8 $constraints @'
## Разрешённые ветки и remotes

**Активные ограничения**:

- Ветки публикации: (по умолчанию — trunk из `MAIN_BRANCH`/автоопределения)
- Remotes: (не задано)

## Push/merge policy

**Активные ограничения**:

- Публикация (push): (по умолчанию — по `PUSH` из `config.md`)
- Слияние в trunk: только ff-merge после интеграционного ревью
'@
    $r = Invoke-Policy @('check-publish', '--work', $work, '--branch', 'main', '--remote', 'origin')
    Assert-Exit $r 0 'T-259 scenario D: target and push placeholders do not combine into a false DENY'

    Write-Utf8 $constraints @'
## Разрешённые ветки и remotes

**Активные ограничения**:

- Ветки публикации: (по умолчанию — trunk)
- Remotes: `upstream`
'@
    $r = Invoke-Policy @('check-publish', '--work', $work, '--branch', 'main', '--remote', 'origin')
    Assert-Exit $r 8 'T-259 scenario D: explicit remote restriction remains enforced beside a placeholder'

    # Scenario E: reconstructed from the surviving .work/constraints.md whose timestamp predates
    # batch B-20260717T110755Z. Its active sections explicitly allowed main/origin; the default
    # push bullet was inactive and the ff-merge text did not request manual confirmation.
    Write-Utf8 $constraints @'
## Разрешённые ветки и remotes

**Активные ограничения** (по умолчанию — как определяет processor):

- Ветки публикации: `main`
- Remotes: `origin`

## Push/merge policy

**Активные ограничения** (по умолчанию — по `PUSH` из `config.md`):

- Публикация (push): (по умолчанию — по `PUSH` из `config.md`)
- Слияние в trunk: только ff-merge после интеграционного ревью (текущее поведение
  processor; не ослабляйте без причины)
'@
    $r = Invoke-Policy @('check-publish', '--work', $work, '--branch', 'main', '--remote', 'origin')
    Assert-Exit $r 0 'T-259 scenario E: reconstructed batch-era policy permits main/origin'
}.Invoke()
# =============================================================================
# 10. check-gate (T-095): the fail-closed, SHA-bound, whole-set publish CI gate
# =============================================================================
{
    $sb = New-Sandbox
    $work = Join-Path $sb '.work'
    $constraints = Join-Path $work 'constraints.md'
    Write-Utf8 $constraints @'
## Обязательные CI-проверки публикации

**Активные ограничения** (по умолчанию пусто):

- `validate`
- `crash-matrix`

**Пример** (ориентир, не применяется):

- `example-only`
'@
    $sha = '0123456789abcdef0123456789abcdef01234567'
    $checks = Join-Path $sb 'runs.jsonl'

    function CG { param([string[]]$Extra) return (Invoke-Policy (@('check-gate', '--work', $work, '--sha', $sha, '--json') + $Extra)) }
    function CGJson { param($R) return ($R.Out.Trim() | ConvertFrom-Json) }

    # all required green at THIS sha -> ready (exit 0)
    Write-Utf8 $checks "{`"name`":`"validate`",`"head_sha`":`"$sha`",`"status`":`"completed`",`"conclusion`":`"success`"}`n{`"name`":`"crash-matrix`",`"head_sha`":`"$sha`",`"status`":`"completed`",`"conclusion`":`"success`"}`n"
    $r = CG @('--checks-from', $checks, '--elapsed-sec', '10')
    Assert-Exit $r 0 'check-gate: all required green -> ready'
    Assert-Equal 'ready' (CGJson $r).verdict 'check-gate: verdict ready'

    # one required still in_progress WITHIN the deadline -> wait (exit 10)
    Write-Utf8 $checks "{`"name`":`"validate`",`"head_sha`":`"$sha`",`"status`":`"completed`",`"conclusion`":`"success`"}`n{`"name`":`"crash-matrix`",`"head_sha`":`"$sha`",`"status`":`"in_progress`",`"conclusion`":`"`"}`n"
    $r = CG @('--checks-from', $checks, '--elapsed-sec', '10', '--deadline-sec', '600', '--backoff-sec', '30')
    Assert-Exit $r 10 'check-gate: pending within deadline -> wait'
    $j = CGJson $r
    Assert-Equal 'wait' $j.verdict 'check-gate: verdict wait'
    Assert-Equal 30 $j.next_backoff_sec 'check-gate: wait reports the backoff'
    Assert-True ($j.pending -contains 'crash-matrix') 'check-gate: names the pending check'

    # deadline exceeded with an incomplete set (outage) -> timeout, fail-closed (exit 9)
    $r = CG @('--checks-from', $checks, '--elapsed-sec', '601', '--deadline-sec', '600')
    Assert-Exit $r 9 'check-gate: incomplete at deadline -> timeout fail-closed'
    Assert-Equal 'timeout' (CGJson $r).verdict 'check-gate: verdict timeout'

    # a required check red -> fail-closed (exit 9), never a silent pass
    Write-Utf8 $checks "{`"name`":`"validate`",`"head_sha`":`"$sha`",`"status`":`"completed`",`"conclusion`":`"failure`"}`n{`"name`":`"crash-matrix`",`"head_sha`":`"$sha`",`"status`":`"completed`",`"conclusion`":`"success`"}`n"
    $r = CG @('--checks-from', $checks, '--elapsed-sec', '10')
    Assert-Exit $r 9 'check-gate: red required check -> fail-closed'
    Assert-True ((CGJson $r).red -contains 'validate') 'check-gate: names the red check'

    # cancelled counts as red (fail-closed), not a pass
    Write-Utf8 $checks "{`"name`":`"validate`",`"head_sha`":`"$sha`",`"status`":`"completed`",`"conclusion`":`"cancelled`"}`n{`"name`":`"crash-matrix`",`"head_sha`":`"$sha`",`"status`":`"completed`",`"conclusion`":`"success`"}`n"
    $r = CG @('--checks-from', $checks, '--elapsed-sec', '10')
    Assert-Exit $r 9 'check-gate: cancelled required check -> fail-closed'

    # runs for ANOTHER sha never satisfy the gate (SHA binding: no "first run wins")
    Write-Utf8 $checks "{`"name`":`"validate`",`"head_sha`":`"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef`",`"status`":`"completed`",`"conclusion`":`"success`"}`n{`"name`":`"crash-matrix`",`"head_sha`":`"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef`",`"status`":`"completed`",`"conclusion`":`"success`"}`n"
    $r = CG @('--checks-from', $checks, '--elapsed-sec', '10', '--deadline-sec', '600')
    Assert-Exit $r 10 'check-gate: green runs for another sha do not satisfy the gate (still pending)'
    Assert-Equal 2 (CGJson $r).missing.Count 'check-gate: other-sha runs count as missing'

    # SHA identity is an ordinal comparison too: do not inherit filesystem case rules.
    $upperSha = $sha.ToUpperInvariant()
    Write-Utf8 $checks "{`"name`":`"validate`",`"head_sha`":`"$upperSha`",`"status`":`"completed`",`"conclusion`":`"success`"}`n{`"name`":`"crash-matrix`",`"head_sha`":`"$upperSha`",`"status`":`"completed`",`"conclusion`":`"success`"}`n"
    $r = CG @('--checks-from', $checks, '--elapsed-sec', '10', '--deadline-sec', '600')
    Assert-Exit $r 10 'check-gate: SHA comparison is ordinal on every platform'
    Assert-Equal 2 (CGJson $r).missing.Count 'check-gate: differently cased SHA records count as missing'

    # Real GitHub Actions run IDs exceed Int32.MaxValue and must still produce a verdict.
    Write-Utf8 $checks "{`"name`":`"validate`",`"head_sha`":`"$sha`",`"status`":`"completed`",`"conclusion`":`"success`",`"run_id`":29199450670}`n{`"name`":`"crash-matrix`",`"head_sha`":`"$sha`",`"status`":`"completed`",`"conclusion`":`"success`",`"run_id`":29199450669}`n"
    $r = CG @('--checks-from', $checks, '--elapsed-sec', '10')
    Assert-Exit $r 0 'check-gate: realistic 11-digit run IDs -> ready without overflow'
    Assert-Equal 'ready' (CGJson $r).verdict 'check-gate: large run ID verdict ready'

    # rerun: a required check failed then re-ran green; the higher large run_id wins even
    # when the input records are reversed, rather than falling back to input order.
    Write-Utf8 $checks "{`"name`":`"validate`",`"head_sha`":`"$sha`",`"status`":`"completed`",`"conclusion`":`"success`",`"run_id`":29199450671}`n{`"name`":`"validate`",`"head_sha`":`"$sha`",`"status`":`"completed`",`"conclusion`":`"failure`",`"run_id`":29199450670}`n{`"name`":`"crash-matrix`",`"head_sha`":`"$sha`",`"status`":`"completed`",`"conclusion`":`"success`",`"run_id`":29199450672}`n"
    $r = CG @('--checks-from', $checks, '--elapsed-sec', '10')
    Assert-Exit $r 0 'check-gate: rerun with large run IDs selects the latest -> ready'
    Assert-Equal 'ready' (CGJson $r).verdict 'check-gate: large run ID rerun verdict ready'

    # Without run_id, preserve the documented fallback to the last record in input order.
    Write-Utf8 $checks "{`"name`":`"validate`",`"head_sha`":`"$sha`",`"status`":`"completed`",`"conclusion`":`"failure`"}`n{`"name`":`"validate`",`"head_sha`":`"$sha`",`"status`":`"completed`",`"conclusion`":`"success`"}`n{`"name`":`"crash-matrix`",`"head_sha`":`"$sha`",`"status`":`"completed`",`"conclusion`":`"success`"}`n"
    $r = CG @('--checks-from', $checks, '--elapsed-sec', '10')
    Assert-Exit $r 0 'check-gate: absent run IDs fall back to the last record -> ready'

    # no required-checks section at all -> degrade to OK (CI_WATCH governs)
    $bare = New-Sandbox
    $r = Invoke-Policy @('check-gate', '--work', (Join-Path $bare '.work'), '--sha', $sha, '--json')
    Assert-Exit $r 0 'check-gate: no required checks -> degrade to OK'
    Assert-Equal 'no-required-checks' ($r.Out.Trim() | ConvertFrom-Json).verdict 'check-gate: degraded verdict'
}.Invoke()

# =============================================================================
# 11. approval-* (T-095): one-time human-approval gate lifecycle
# =============================================================================
{
    $sb = New-Sandbox
    $work = Join-Path $sb '.work'
    Write-Utf8 (Join-Path $work 'constraints.md') "## Запрещённые пути (denylist)`n`n**Активные ограничения**:`n`n- ``infra/**```n"
    # The affected code lives in a working copy ($sb is the --root); the fingerprint binds
    # each listed path to its CONTENT read from there (R-01), so an in-place edit expires it.
    New-Item -ItemType Directory -Force -Path (Join-Path $sb 'src') | Out-Null
    Write-Utf8 (Join-Path $sb 'src/app.js') "console.log('v1');`n"
    Write-Utf8 (Join-Path $sb 'src/lib.js') "export const x = 1;`n"
    $changed = Join-Path $sb 'changed.txt'
    Write-Utf8 $changed "src/app.js`nsrc/lib.js`n"

    function AP { param([string[]]$Extra) return (Invoke-Policy $Extra) }
    function APJson { param($R) return ($R.Out.Trim() | ConvertFrom-Json) }

    # a diff fingerprint from a path list requires --root (fail-closed: never silently fall
    # back to the pre-R-01 path-only fingerprint that ignored file content)
    $r = AP @('approval-request', '--work', $work, '--task', 'T-045', '--reason', 'policy-bypass', '--paths-from', $changed, '--deadline-sec', '3600', '--now', '2026-01-01T00:00:00Z', '--json')
    Assert-Exit $r 2 'approval-request: --paths-from without --root is refused (needs content root)'

    # request creates a persistent artifact with a one-time id, diff fingerprint + policy snapshot
    $r = AP @('approval-request', '--work', $work, '--task', 'T-045', '--reason', 'policy-bypass', '--root', $sb, '--paths-from', $changed, '--deadline-sec', '3600', '--now', '2026-01-01T00:00:00Z', '--json')
    Assert-Exit $r 0 'approval-request: creates a request'
    $req = APJson $r
    $id = $req.id
    Assert-True ($id -like 'apr-*') 'approval-request: yields a one-time id'
    Assert-True (-not [string]::IsNullOrEmpty($req.fingerprint)) 'approval-request: carries a diff fingerprint'
    Assert-True (-not [string]::IsNullOrEmpty($req.policy_hash)) 'approval-request: carries a policy snapshot hash'
    Assert-True (Test-Path -LiteralPath (Join-Path $work "approvals/$id.json")) 'approval-request: persists the artifact'

    # resume of the SAME request (same subject+reason+fingerprint+policy) reuses it, no duplicate
    $r2 = AP @('approval-request', '--work', $work, '--task', 'T-045', '--reason', 'policy-bypass', '--root', $sb, '--paths-from', $changed, '--now', '2026-01-01T00:05:00Z', '--json')
    Assert-Equal $id (APJson $r2).id 'approval-request: idempotent on resume (same id)'
    Assert-Equal 'existing' (APJson $r2).state 'approval-request: resume returns the existing request, not a new one'

    # before a decision: status is pending (exit 12), never a default approval
    $r = AP @('approval-status', '--work', $work, '--id', $id, '--root', $sb, '--paths-from', $changed, '--now', '2026-01-01T00:10:00Z', '--json')
    Assert-Exit $r 12 'approval-status: undecided within deadline -> pending'
    Assert-Equal 'pending' (APJson $r).verdict 'approval-status: verdict pending'

    # approve consumes the id
    $r = AP @('approval-approve', '--work', $work, '--id', $id, '--by', 'operator', '--now', '2026-01-01T00:20:00Z')
    Assert-Exit $r 0 'approval-approve: operator approves'
    # a SECOND decision on the same id is refused (one-time consume)
    $r = AP @('approval-reject', '--work', $work, '--id', $id, '--by', 'operator', '--now', '2026-01-01T00:21:00Z')
    Assert-Exit $r 11 'approval: a one-time id cannot be decided twice'

    # status: approved + fingerprint/policy unchanged -> approved (exit 0)
    $r = AP @('approval-status', '--work', $work, '--id', $id, '--root', $sb, '--paths-from', $changed, '--now', '2026-01-01T00:30:00Z', '--json')
    Assert-Exit $r 0 'approval-status: fresh approval -> approved'
    Assert-Equal 'approved' (APJson $r).verdict 'approval-status: verdict approved'

    # FAIL-CLOSED (T-235): querying an APPROVED id with no inputs to recompute the current
    # fingerprint (bare --id, no --paths-from/--path/--fingerprint) must NOT silently report
    # `approved` - freshness cannot be verified, so refuse (exit 2), never a fail-open pass.
    $r = AP @('approval-status', '--work', $work, '--id', $id, '--now', '2026-01-01T00:30:10Z', '--json')
    Assert-Exit $r 2 'approval-status: approved id without freshness inputs -> refused (fail-closed, not approved)'
    Assert-Equal 'unverifiable' (APJson $r).verdict 'approval-status: verdict unverifiable when freshness cannot be checked'
    # the refusal is exactly the missing fingerprint inputs: supplying --fingerprint alone (a
    # precomputed current fingerprint that matches the stored one) restores the approved verdict,
    # proving the guard gates on verifiability, not on rejecting bare --id per se.
    $r = AP @('approval-status', '--work', $work, '--id', $id, '--fingerprint', $req.fingerprint, '--now', '2026-01-01T00:30:20Z', '--json')
    Assert-Exit $r 0 'approval-status: approved id with an explicit matching --fingerprint -> approved'
    Assert-Equal 'approved' (APJson $r).verdict 'approval-status: explicit matching fingerprint verifies freshness'

    # eol re-materialization only (LF -> CRLF) must NOT expire the approval - content is
    # normalized before hashing, so a benign eol churn stays fresh (avoids false-stale).
    Write-Utf8 (Join-Path $sb 'src/app.js') "console.log('v1');`r`n"
    $r = AP @('approval-status', '--work', $work, '--id', $id, '--root', $sb, '--paths-from', $changed, '--now', '2026-01-01T00:30:30Z', '--json')
    Assert-Exit $r 0 'approval-status: eol-only change stays fresh (content normalized)'
    Write-Utf8 (Join-Path $sb 'src/app.js') "console.log('v1');`n"   # restore LF for the next checks

    # STALE (path set): adding an affected path (content of the listed files unchanged) expires it
    $changed2 = Join-Path $sb 'changed2.txt'
    Write-Utf8 $changed2 "src/app.js`nsrc/lib.js`nsrc/new.js`n"
    $r = AP @('approval-status', '--work', $work, '--id', $id, '--root', $sb, '--paths-from', $changed2, '--now', '2026-01-01T00:31:00Z', '--json')
    Assert-Exit $r 11 'approval-status: added affected path -> stale (fail-closed)'
    Assert-Equal 'expired-stale' (APJson $r).verdict 'approval-status: verdict expired-stale (path set)'

    # STALE (R-01: in-place content edit): the SAME path set but different bytes must expire the
    # approval - an approval granted under one code must never be reused for other content.
    Write-Utf8 (Join-Path $sb 'src/app.js') "console.log('v2 - not reviewed');`n"
    $r = AP @('approval-status', '--work', $work, '--id', $id, '--root', $sb, '--paths-from', $changed, '--now', '2026-01-01T00:32:00Z', '--json')
    Assert-Exit $r 11 'approval-status: in-place content edit (same paths) -> stale (R-01 replay closed)'
    Assert-Equal 'expired-stale' (APJson $r).verdict 'approval-status: verdict expired-stale (content edit)'

    # reject path: a separate subject rejected is terminal (exit 11)
    $r = AP @('approval-request', '--work', $work, '--task', 'T-046', '--reason', 'human-review', '--fingerprint', 'aa', '--policy-hash', 'bb', '--deadline-sec', '3600', '--now', '2026-01-01T00:00:00Z', '--json')
    $idR = (APJson $r).id
    $r = AP @('approval-reject', '--work', $work, '--id', $idR, '--by', 'operator', '--now', '2026-01-01T00:05:00Z')
    Assert-Exit $r 11 'approval-reject: rejection returns fail-closed'
    $r = AP @('approval-status', '--work', $work, '--id', $idR, '--fingerprint', 'aa', '--policy-hash', 'bb', '--now', '2026-01-01T00:06:00Z', '--json')
    Assert-Exit $r 11 'approval-status: rejected is terminal'
    Assert-Equal 'rejected' (APJson $r).verdict 'approval-status: verdict rejected'

    # TIMEOUT: no answer by the deadline is a fail-closed rejection, not a default approval
    $r = AP @('approval-request', '--work', $work, '--batch', 'B-20260101T000000Z', '--reason', 'force-lock', '--fingerprint', 'cc', '--policy-hash', 'dd', '--deadline-sec', '60', '--now', '2026-01-01T00:00:00Z', '--json')
    $idT = (APJson $r).id
    $r = AP @('approval-status', '--work', $work, '--id', $idT, '--fingerprint', 'cc', '--policy-hash', 'dd', '--now', '2026-01-01T01:00:00Z', '--json')
    Assert-Exit $r 11 'approval-status: no decision by deadline -> fail-closed'
    Assert-Equal 'expired-timeout' (APJson $r).verdict 'approval-status: verdict expired-timeout'
    # an operator cannot approve an already-expired request
    $r = AP @('approval-approve', '--work', $work, '--id', $idT, '--by', 'operator', '--now', '2026-01-01T01:01:00Z')
    Assert-Exit $r 11 'approval-approve: cannot approve a request past its deadline'

    # INDEPENDENCE: approving one subject does not decide an unrelated open request
    $r = AP @('approval-request', '--work', $work, '--task', 'T-099', '--reason', 'policy-bypass', '--fingerprint', 'ee', '--policy-hash', 'ff', '--deadline-sec', '3600', '--now', '2026-01-01T00:00:00Z', '--json')
    $idI = (APJson $r).id
    $r = AP @('approval-status', '--work', $work, '--id', $idI, '--fingerprint', 'ee', '--policy-hash', 'ff', '--now', '2026-01-01T00:10:00Z', '--json')
    Assert-Exit $r 12 'approval-status: an unrelated subject stays pending (independent, not blocked by another approval)'
}.Invoke()

# =============================================================================
# Report + cleanup
# =============================================================================
foreach ($item in $script:TempItems) {
    Remove-Item -LiteralPath $item -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures.Count -eq 0) {
    Write-Host 'OK - policy.ps1 / policy-schema.ps1 behave per contract for all fixture scenarios.'
    exit 0
}
Write-Host "Found $($script:Failures.Count) failing assertion(s):`n"
foreach ($f in $script:Failures) { Write-Host $f }
exit 1
