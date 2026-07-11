<#
  Cross-platform doctor engine for launchers/cc-doctor.cmd and launchers/cc-doctor.sh
  (task T-090). Both launchers are thin wrappers that resolve pwsh (PowerShell 7,
  which runs identically on Windows and POSIX) and delegate here, so the read-only
  Codex/configuration/orchestration preflight lives in ONE place with ONE behaviour
  instead of a Windows .cmd program and a separate, hand-kept-in-sync POSIX shell
  program (the two divergent copies this task exists to remove). This mirrors how
  cc-sync was unified onto tools/sync-runtime.ps1 in the same task.

  Read-only: it never creates, edits or deletes any file (not even a stuck
  orchestrator.lock or an orphaned worktree - it only reports on them) and always
  exits 0. It is a diagnostic, so OK/WARN/FAIL/N/A are TEXT verdicts, never exit
  codes. Run from a target project's root.

  What it reports, in order:
    1. Codex preflight        - codex binary presence/version, ~/.codex/auth.json,
                                and the auto-mode allow-rule for the runtime wrapper
                                `pwsh -File tools/codex-runtime.ps1` (session grant OR
                                permissions.allow), gated on whether Codex routing is on.
    2. Effective CODEX_*      - the resolved CODEX_* values (.work/config.md, with the
                                documented config-then-env fallback for CODEX_CODER/
                                CODEX_REVIEWER).
    3. Codex key validation   - fail-closed classification of the six value-constrained
                                Codex keys against their allowed sets ($codexAllowed).
    4. KB status              - the resolved KB mode (.work/config.md, with the same
                                documented config-then-env fallback, default `on`) and
                                per-shard entry counts.
    5. Windows sandbox        - Windows-only: the [windows] sandbox profile + approval
                                policy from ~/.codex/config.toml vs this process's
                                elevation. N/A on POSIX (the concept does not exist there).
    6. Task queue & config    - Tasks_Queue.md header format + T-NNN uniqueness, and
                                .work/config.md unknown/mistyped keys ($known) + SMOKE_CMD.
    7. Lock & worktrees       - stuck orchestrator.lock heuristic + orphaned worktrees.
    8. Main branch & mirror   - main-branch determinability (jj-then-git) and, from an
                                actual checkout, ~/.claude/agents mirror freshness.

  Intentionally ASCII-only source: this file is invoked via pwsh first and Windows
  PowerShell 5.1 only as a fallback, and an ASCII source is read the same by both
  regardless of the BOM/codepage hazard that bites non-ASCII .ps1s under 5.1. The two
  Cyrillic strings the output needs (the "KB" section header and the "status" word in
  Tasks_Queue.md headers) are therefore built from numeric Unicode code points at
  runtime rather than typed as source literals - the same technique the old inline
  cc-doctor.cmd used.

  Single-source contracts (machine-guarded, so they cannot silently drift):
    - $codexAllowed  - the six value-constrained Codex key sets. Guarded by
                       tools/check-codex-config-guard.ps1 against config.example.md's
                       validation table and agents/processor.md.
    - $known         - the recognized .work/config.md keys. Guarded by
                       tools/check-consistency.ps1 (Class 4) against config.example.md's
                       defaults table.
  Both are kept hardcoded here (not read from config.example.md at runtime) because
  cc-doctor must keep working when this runtime is mirrored standalone into
  ~/.claude/scripts by cc-sync, where a reliable checkout of tools/ + config.example.md
  is not guaranteed to be present.
#>

[CmdletBinding()]
param(
    # The target project root whose .work/ is audited. Defaults to the current
    # directory (where the launcher was invoked). Overridable so the fixture tests can
    # drive a synthetic project tree without touching a real one.
    [string]$ProjectRoot,

    # The Orchestra repository root above launchers/ (used only by the agent-mirror
    # freshness check). Defaults to the parent of tools/ (where this script lives),
    # which is correct both in a checkout (repo root) and in the ~/.claude/scripts
    # mirror (~/.claude, whose agents/ is the mirror itself).
    [string]$RepoRoot,

    # The user home whose ~/.claude and ~/.codex are inspected. Defaults to the real
    # home; overridable so tests never read the machine's real Codex/Claude settings.
    [string]$HomeDir
)

# Read-only diagnostic: degrade quietly, never throw. Individual probes still guard
# their own external calls (git/jj/codex) with 2>$null / -ErrorAction SilentlyContinue.
$ErrorActionPreference = 'SilentlyContinue'

# --- OS detection correct on both Windows PowerShell 5.1 and pwsh 7 ----------------
# $IsWindows does not exist under 5.1; the RuntimeInformation probe works everywhere.
$script:OnWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows)

if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).Path }
if (-not $RepoRoot)    { $RepoRoot = Split-Path -Parent $PSScriptRoot }
if (-not $HomeDir) {
    if ($script:OnWindows) { $HomeDir = $env:USERPROFILE }
    if (-not $HomeDir)     { $HomeDir = $env:HOME }
    if (-not $HomeDir)     { $HomeDir = $HOME }
}

# ASCII-safe construction of the two Cyrillic strings the output needs.
function ConvertFrom-CodePoints { param([int[]]$Codes) return (-join ($Codes | ForEach-Object { [char]$_ })) }
$script:StatusWord = ConvertFrom-CodePoints @(0x0441, 0x0442, 0x0430, 0x0442, 0x0443, 0x0441)             # "status" in Cyrillic
$script:KbTitle    = ConvertFrom-CodePoints @(0x0411, 0x0430, 0x0437, 0x0430, 0x0020, 0x0437, 0x043D, 0x0430, 0x043D, 0x0438, 0x0439)  # "Knowledge base" in Cyrillic
$script:EmDash     = [char]0x2014

$script:WorkDir    = Join-Path $ProjectRoot '.work'
$script:ConfigFile = Join-Path $script:WorkDir 'config.md'

# =============================================================================
# Config parsing helpers (semantics identical to the old cc-doctor GetCfg/EffCodex)
# =============================================================================

$script:ConfigLines = $null
function Get-ConfigLines {
    if ($null -eq $script:ConfigLines) {
        if (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf) {
            $script:ConfigLines = @(Get-Content -LiteralPath $script:ConfigFile -Encoding UTF8)
        } else {
            $script:ConfigLines = @()
        }
    }
    return $script:ConfigLines
}

function Get-Cfg {
    # Value of "KEY: value" from .work/config.md: leading/trailing whitespace trimmed,
    # value read up to (not including) an inline '#'. First match wins. Empty if unset.
    param([string]$Key)
    $rx = '^\s*' + [regex]::Escape($Key) + '\s*:\s*([^#]*?)\s*(?:#.*)?$'
    foreach ($line in (Get-ConfigLines)) {
        $m = [regex]::Match($line, $rx)
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return ''
}

function Get-EnvTrimmed {
    param([string]$Key)
    $v = [Environment]::GetEnvironmentVariable($Key)
    if ($v) { return $v.Trim() }
    return ''
}

function Get-EffCodex {
    # Effective CODEX_CODER/CODEX_REVIEWER: config.md wins, else the same-named env var.
    param([string]$Key)
    $v = Get-Cfg $Key
    if (-not $v) { $v = Get-EnvTrimmed $Key }
    return $v
}

# =============================================================================
# 1. Codex preflight
# =============================================================================

$codexCmd = Get-Cfg 'CODEX_CMD'
if (-not $codexCmd) { $codexCmd = 'codex' }

Write-Host '== Codex preflight =='
$bin = Get-Command $codexCmd -ErrorAction SilentlyContinue
if ($bin) {
    Write-Host ('codex binary : ' + $bin.Source)
    Write-Host ('codex version: ' + (& $codexCmd --version 2>$null))
} else {
    Write-Host ('codex binary : NOT FOUND (' + $codexCmd + ') -> coder_codex will escalate to Claude')
}
$authFile = Join-Path (Join-Path $HomeDir '.codex') 'auth.json'
if (Test-Path -LiteralPath $authFile -PathType Leaf) {
    Write-Host 'auth         : ~/.codex/auth.json present'
} else {
    Write-Host 'auth         : NOT found -> run: codex login'
}

# Since T-075 the adapters run the runtime wrapper `pwsh -File tools/codex-runtime.ps1`
# (which spawns the real `codex exec` as a child, past the Bash gate). So the allow-rule
# that must actually be present is the one covering that wrapper (runtimeRule); it covers
# every CODEX_CMD (a non-default CODEX_CMD is just a --codex-cmd argument to the wrapper).
# cmdPrefix ("<CODEX_CMD> exec") is kept only for the launcher session-grant comparison.
$cmdPrefix   = $codexCmd + ' exec'
$runtimeRule = 'pwsh -File tools/codex-runtime.ps1'

# Routing is on if ANY of CODEX_CODER / CODEX_REVIEWER (config-or-env) or CODEX_CIFIX
# (config only) is something other than off - the union of the three Codex routes.
$ccEff = Get-EffCodex 'CODEX_CODER'
$crEff = Get-EffCodex 'CODEX_REVIEWER'
$cfEff = Get-Cfg 'CODEX_CIFIX'
$codexRoutingOn = (($ccEff -and $ccEff -ne 'off') -or ($crEff -and $crEff -ne 'off') -or ($cfEff -and $cfEff -ne 'off'))

# Session grant: cc-processor/cc-resume pre-grant the runtime allow-rule and export
# CC_CODEX_EXEC_GRANT="codex exec" as the launcher-session marker; a session whose
# granted anchor covers the codex sub-command prefix needs no persistent settings rule.
$grant = [Environment]::GetEnvironmentVariable('CC_CODEX_EXEC_GRANT')
$sessionGrant = ($grant -and $cmdPrefix.StartsWith($grant))

# Static settings check (only meaningful without a covering session grant): inspect ONLY
# the permissions.allow array of each settings file for an entry containing the actual
# runtime-wrapper command prefix. Matches in permissions.deny / hooks / comments must NOT
# count (task T-071).
$permRule = $false
$settingsFiles = @(
    (Join-Path $ProjectRoot '.claude/settings.local.json'),
    (Join-Path $ProjectRoot '.claude/settings.json'),
    (Join-Path (Join-Path $HomeDir '.claude') 'settings.json')
)
foreach ($sf in $settingsFiles) {
    if (-not (Test-Path -LiteralPath $sf -PathType Leaf)) { continue }
    try { $j = Get-Content -LiteralPath $sf -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $j = $null }
    if ($j -and $j.permissions -and $j.permissions.allow) {
        foreach ($e in $j.permissions.allow) {
            if (($e -is [string]) -and $e.Contains($runtimeRule)) { $permRule = $true }
        }
    }
}

if (-not $codexRoutingOn) {
    Write-Host 'OK   exec permission: not found, but not required right now - CODEX_CODER, CODEX_REVIEWER and CODEX_CIFIX are all off'
} elseif ($sessionGrant) {
    Write-Host ('OK   exec permission: session grant present (CC_CODEX_EXEC_GRANT covers the ' + $cmdPrefix + ' command prefix) - no persistent settings allow-rule required for this session')
} elseif ($permRule) {
    Write-Host ('OK   exec permission: allow-rule for the codex runtime (' + $runtimeRule + ') present in Claude Code settings (permissions.allow)')
} else {
    Write-Host 'WARN exec permission: NOT found -> CODEX_CODER/CODEX_REVIEWER/CODEX_CIFIX routing is on, so the auto-mode classifier blocks the autonomous codex runtime without it; run cc-config (seeds .claude/settings.local.json with the canonical allow-rules Bash(pwsh -File tools/codex-runtime.ps1 *) and Bash(codex exec *) if absent, else lists what is missing) or add the allow-rule by hand (permissions.allow: Bash(pwsh -File tools/codex-runtime.ps1 *)) to .claude/settings.local.json or .claude/settings.json, else coder_codex/reviewer_codex escalate to Claude'
}

# =============================================================================
# 2. Effective CODEX_*
# =============================================================================

Write-Host ''
Write-Host '== Effective CODEX_* (.work/config.md; CODEX_CODER/CODEX_REVIEWER fall back to env; blank = default) =='
foreach ($k in 'CODEX_CODER', 'CODEX_REVIEWER', 'CODEX_CIFIX', 'CODEX_MODEL', 'CODEX_REASONING', 'CODEX_SANDBOX', 'CODEX_NETWORK', 'CODEX_CMD') {
    $val = Get-Cfg $k
    $src = ''
    if (-not $val -and ($k -eq 'CODEX_CODER' -or $k -eq 'CODEX_REVIEWER')) {
        $ev = Get-EnvTrimmed $k
        if ($ev) { $val = $ev; $src = ' (env)' }
    }
    if (-not $val) { $val = '(default)' }
    Write-Host ('  ' + $k.PadRight(16) + ' = ' + $val + $src)
}

# =============================================================================
# 3. Codex key value validation
# =============================================================================
#
# Fail-closed classification of the six value-constrained Codex keys against their
# allowed sets. $codexAllowed is the launcher-local copy of the single source of truth
# (config.example.md's "Codex key values" validation table); check-codex-config-guard.ps1
# machine-guarantees it, this copy and processor.md's branching do not drift apart. An
# empty/unset key is NOT an error (documented default); only a non-empty out-of-set value
# is flagged.
$codexAllowed = [ordered]@{
    'CODEX_CODER'     = @('off', 'fast', 'fast+std')
    'CODEX_REVIEWER'  = @('off', 'fast', 'fast+std', 'deep')
    'CODEX_CIFIX'     = @('off', 'on')
    'CODEX_REASONING' = @('auto', 'low', 'medium', 'high')
    'CODEX_SANDBOX'   = @('read-only', 'workspace-write')
    'CODEX_NETWORK'   = @('on', 'off')
}
Write-Host ''
Write-Host '== Codex key value validation =='
$codexInvalid = $false
foreach ($k in $codexAllowed.Keys) {
    $v = Get-Cfg $k
    if (-not $v -and ($k -eq 'CODEX_CODER' -or $k -eq 'CODEX_REVIEWER')) {
        $v = Get-EnvTrimmed $k
    }
    if (-not $v) { continue }
    if ($codexAllowed[$k] -notcontains $v) {
        $codexInvalid = $true
        Write-Host ('FAIL ' + $k + ': invalid value ' + [char]39 + $v + [char]39 + ' -> allowed: ' + ($codexAllowed[$k] -join ' | '))
    }
}
if (-not $codexInvalid) {
    Write-Host 'OK   Codex key values: all set values are within their allowed sets'
} else {
    Write-Host '  -> fix .work/config.md (or the env var) so the cohort is not blocked at Phase 1.1; no silent default is substituted for an invalid value'
}

# =============================================================================
# 4. KB status
# =============================================================================

Write-Host ''
Write-Host ('== ' + $script:KbTitle + ' (KB; .work/knowledge) ==')
$kb = Get-Cfg 'KB'
$kbSrc = ''
if (-not $kb) {
    $ev = Get-EnvTrimmed 'KB'
    if ($ev) { $kb = $ev; $kbSrc = ' (env)' }
}
if (-not $kb) { $kb = 'on (default)' } else { $kb = $kb + $kbSrc }
Write-Host ('  KB = ' + $kb)
$kbDir = Join-Path $script:WorkDir 'knowledge'
if (Test-Path -LiteralPath $kbDir) {
    foreach ($s in 'architecture', 'conventions', 'pitfalls') {
        $c = (Get-ChildItem -Path (Join-Path $kbDir $s) -Filter *.md -ErrorAction SilentlyContinue | Measure-Object).Count
        Write-Host ('  ' + $s.PadRight(13) + ' = ' + $c + ' entries')
    }
} else {
    Write-Host '  .work/knowledge absent (KB empty or off)'
}

# =============================================================================
# 5. Windows sandbox profile & approval policy (Windows-only)
# =============================================================================

Write-Host ''
Write-Host '== Windows sandbox profile & approval policy =='
if (-not $script:OnWindows) {
    Write-Host 'N/A  windows sandbox profile: not applicable on this OS (Windows-only Codex config; this check runs only on Windows)'
} else {
    $q  = [char]34
    $q2 = [char]39
    $wp = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isElevated = $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $cfgToml = Join-Path (Join-Path $HomeDir '.codex') 'config.toml'
    $sandboxVal = $null
    $approvalVal = $null
    if (Test-Path -LiteralPath $cfgToml) {
        $section = ''
        foreach ($ln in Get-Content -LiteralPath $cfgToml) {
            $t = $ln.Trim()
            if ($t -match '^\[(.+)\]$') { $section = $Matches[1].Trim(); continue }
            if (-not $t -or $t.StartsWith('#')) { continue }
            if ($section -eq 'windows' -and (-not $sandboxVal) -and $t -match '^sandbox\s*=\s*(.+?)\s*(#.*)?$') { $sandboxVal = $Matches[1].Trim($q).Trim($q2) }
            if ($section -eq '' -and (-not $approvalVal) -and $t -match '^approval_policy\s*=\s*(.+?)\s*(#.*)?$') { $approvalVal = $Matches[1].Trim($q).Trim($q2) }
        }
    }
    if (-not $sandboxVal) {
        Write-Host 'WARN windows sandbox profile: [windows] sandbox not set, or config.toml missing/unreadable at ~/.codex/config.toml -> cannot verify Windows sandbox isolation; set sandbox = unelevated there to confirm restricted-token isolation applies (elevated additionally requires this launcher process itself to be elevated - not how Orchestra normally runs)'
    } elseif ($sandboxVal -eq 'unelevated') {
        Write-Host 'OK   windows sandbox profile: unelevated - matches this (unelevated) launcher process; confirmed to isolate, writes outside the workspace are rejected'
    } elseif ($sandboxVal -eq 'elevated') {
        if ($isElevated) {
            Write-Host 'WARN windows sandbox profile: elevated, and this process is currently elevated - the elevated spawn may succeed here, but Orchestra launchers normally run unelevated and this cannot be fully confirmed by this check; prefer sandbox = unelevated, confirmed to isolate regardless of elevation'
        } else {
            Write-Host 'FAIL windows sandbox profile: elevated, but this launcher process is NOT elevated -> the elevated sandbox spawn fails (CreateProcessAsUserW: Access is denied, Windows error 5). Raw codex exec (or codex run outside Orchestra) under a default approval_policy would then silently rerun the command WITHOUT any sandbox: full network and filesystem access, no isolation (confirmed, not a one-off). Orchestra itself does NOT run unsandboxed here: its coder_codex/reviewer_codex adapters pin -c approval_policy=never on every call, so codex returns the sandbox-init failure instead of running the command, the adapter raises CODEX_FAILED - ENV_LIMIT/sandbox-init before making any edits (coder_codex leaves the worktree unchanged, reviewer_codex leaves review.md untouched), and the processor falls back to the equivalent Claude executor. So the pipeline stays safe, but codex sandbox isolation is not in effect and every such call detours to Claude. Restore real isolation in ~/.codex/config.toml (pick one): set sandbox = unelevated (confirmed to isolate, so codex runs sandboxed instead of escalating to Claude); or set approval_policy = never (matches what the adapters already pin per call, and also closes the silent-unsandboxed fallback for raw codex exec outside Orchestra). Do not try to fix this by running the launcher elevated.'
        }
    } else {
        Write-Host ('WARN windows sandbox profile: unrecognized [windows] sandbox value (' + $sandboxVal + ') in ~/.codex/config.toml -> cannot verify isolation; expected unelevated or elevated')
    }
    if (-not $approvalVal) {
        Write-Host 'WARN approval_policy: not set in ~/.codex/config.toml -> a sandbox denial may silently escalate into an unsandboxed run in non-interactive codex exec (confirmed for the on-request default). This governs raw codex exec run outside Orchestra: the coder_codex/reviewer_codex adapters already pin -c approval_policy=never per call, so Orchestra codex runs stay fail-closed regardless of this value. Set approval_policy = never here to return a model error instead (and to cover raw codex exec too)'
    } elseif ($approvalVal -eq 'never') {
        Write-Host 'OK   approval_policy: never - a sandbox denial returns a model error instead of escalating to an unsandboxed run'
    } else {
        Write-Host ('WARN approval_policy: ' + $approvalVal + ' - may silently escalate a sandbox denial into an unsandboxed run in non-interactive codex exec (confirmed for on-request). This governs raw codex exec outside Orchestra; the coder_codex/reviewer_codex adapters pin -c approval_policy=never per call so Orchestra codex runs stay fail-closed. Set approval_policy = never here to close this for raw codex exec too')
    }
}

# =============================================================================
# 6. Preflight readiness audit: task queue & configuration
# =============================================================================

Write-Host ''
Write-Host '== Preflight readiness audit: task queue & configuration =='
$headerRegex = '^### \[(T-\d+)\] .+ ' + $script:EmDash + ' ' + $script:StatusWord + ': .+$'
$qf = Join-Path $script:WorkDir 'Tasks_Queue.md'
if (Test-Path -LiteralPath $qf) {
    $lines = @(Get-Content -LiteralPath $qf -Encoding UTF8)
    $seen = @{}
    $bad = New-Object System.Collections.ArrayList
    $lineNo = 0
    foreach ($line in $lines) {
        $lineNo++
        if ($line -match '^#{1,6}\s') {
            if ($line -match $headerRegex) {
                $id = $Matches[1]
                if ($seen.ContainsKey($id)) {
                    [void]$bad.Add(('line {0}: duplicate task id {1} (first seen at line {2})' -f $lineNo, $id, $seen[$id]))
                } else {
                    $seen[$id] = $lineNo
                }
            } elseif ($line -match 'T-\d+') {
                [void]$bad.Add(('line {0}: malformed task header (expected format: ''### [T-NNN] Title - status: ...''): {1}' -f $lineNo, $line))
            }
        }
    }
    if ($bad.Count -eq 0) {
        Write-Host ('OK   Tasks_Queue.md: {0} task header(s), format valid, IDs unique' -f $seen.Count)
    } else {
        Write-Host 'FAIL Tasks_Queue.md format violation(s):'
        foreach ($b in $bad) { Write-Host ('  - ' + $b) }
    }
} else {
    Write-Host 'OK   .work/Tasks_Queue.md not found (nothing to validate)'
}

$known = @('MAX_PARALLEL', 'COHORT_SIZE', 'COHORT_MAX_AGE', 'REVIEW_MIN_PASSES', 'REVIEW_LOOP_MAX', 'INTEGRATION_LOOP_MAX', 'CI_FIX_MAX', 'QUARANTINE_MAX_ATTEMPTS', 'CALL_DEADLINE_SEC', 'CALL_MAX_ATTEMPTS', 'CALL_OUTPUT_MAX_BYTES', 'COHORT_BUDGET_SEC', 'SMOKE_CMD', 'PUSH', 'CI_WATCH', 'PUBLISH_CI_DEADLINE_SEC', 'PUBLISH_CI_BACKOFF_SEC', 'APPROVAL_DEADLINE_SEC', 'REVIEWER_TIERING', 'MAIN_BRANCH', 'EVENTS_OUTBOX', 'KB', 'KB_TTL', 'KB_CAP', 'CODEX_CODER', 'CODEX_REVIEWER', 'CODEX_CIFIX', 'CODEX_MODEL', 'CODEX_REASONING', 'CODEX_SANDBOX', 'CODEX_NETWORK', 'CODEX_CMD')
if (Test-Path -LiteralPath $script:ConfigFile) {
    $hasSmoke = $false
    $unknown = New-Object System.Collections.ArrayList
    foreach ($line in (Get-ConfigLines)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        if ($t -match '^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$') {
            $k = $Matches[1]; $v = $Matches[2]
            if ($v) { $v = ($v -replace '#.*$', '').Trim() }
            if ($known -notcontains $k) { [void]$unknown.Add($k) }
            if ($k -eq 'SMOKE_CMD' -and $v) { $hasSmoke = $true }
        }
    }
    if ($unknown.Count -eq 0) {
        Write-Host 'OK   .work/config.md: no unknown/mistyped keys'
    } else {
        Write-Host ('FAIL .work/config.md: unknown/possibly mistyped key(s): ' + ($unknown -join ', '))
    }
    if ($hasSmoke) {
        Write-Host 'OK   SMOKE_CMD is configured'
    } else {
        Write-Host 'WARN SMOKE_CMD is not set - coder/merger self-checks will skip build/test verification'
    }
} else {
    Write-Host 'WARN .work/config.md not found - defaults apply; SMOKE_CMD is not configured (self-checks skip build/test verification)'
}

# =============================================================================
# 7. Preflight readiness audit: orchestrator lock & worktrees
# =============================================================================

Write-Host ''
Write-Host '== Preflight readiness audit: orchestrator lock & worktrees =='
$lockDir = Join-Path $script:WorkDir 'orchestrator.lock'
if (Test-Path -LiteralPath $lockDir) {
    $infoFile = Join-Path $lockDir 'info'
    $started = $null; $hostVal = $null
    if (Test-Path -LiteralPath $infoFile) {
        foreach ($l in Get-Content -LiteralPath $infoFile -Encoding UTF8) {
            if ($l -match '^started=(.+)$') { $started = $Matches[1] }
            if ($l -match '^host=(.+)$') { $hostVal = $Matches[1] }
        }
    }
    if ($started) {
        $ts = [DateTime]::MinValue
        $ok = [DateTime]::TryParse($started, [System.Globalization.CultureInfo]::InvariantCulture, ([System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal), [ref]$ts)
        if ($ok) {
            $ageHours = [math]::Round(((Get-Date).ToUniversalTime() - $ts).TotalHours, 1)
            $ageHoursStr = $ageHours.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)
            if ($ageHours -gt 6) {
                Write-Host ('WARN orchestrator.lock: age {0}h (started {1}, host {2}) - possibly stale (heuristic only); verify no processor is actually running before removing .work/orchestrator.lock manually' -f $ageHoursStr, $started, $hostVal)
            } else {
                Write-Host ('OK   orchestrator.lock present, age {0}h (started {1}, host {2}) - looks like an active run' -f $ageHoursStr, $started, $hostVal)
            }
        } else {
            Write-Host ('WARN orchestrator.lock/info present but the started timestamp is unparsable ({0}) - cannot judge age' -f $started)
        }
    } else {
        Write-Host 'WARN orchestrator.lock present without info/started timestamp - cannot judge age; verify manually'
    }
} else {
    Write-Host 'OK   no orchestrator.lock (no active/stuck processor run)'
}

$wtRoot = Join-Path $script:WorkDir 'worktrees'
if (Test-Path -LiteralPath $wtRoot) {
    $orphans = New-Object System.Collections.ArrayList
    Get-ChildItem -LiteralPath $wtRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $name = $_.Name
        if ($name -eq '_integration') {
            if (-not (Test-Path -LiteralPath (Join-Path $script:WorkDir 'batch.md'))) {
                [void]$orphans.Add($name + ' (no .work/batch.md - no active batch)')
            }
        } else {
            if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $script:WorkDir 'tasks') (Join-Path $name 'task.md')))) {
                [void]$orphans.Add($name + ' (no .work/tasks/' + $name + '/task.md descriptor)')
            }
        }
    }
    if ($orphans.Count -eq 0) {
        Write-Host 'OK   no orphaned worktrees under .work/worktrees'
    } else {
        Write-Host 'FAIL orphaned worktree(s) (no matching active task/batch - not auto-removed):'
        foreach ($o in $orphans) { Write-Host ('  - ' + $o) }
    }
} else {
    Write-Host 'OK   .work/worktrees not present (nothing to check)'
}

# =============================================================================
# 8. Preflight readiness audit: main branch & agent mirror
# =============================================================================

Write-Host ''
Write-Host '== Preflight readiness audit: main branch & agent mirror =='
Push-Location -LiteralPath $ProjectRoot -ErrorAction SilentlyContinue
try {
    $mainBranchCfg = Get-Cfg 'MAIN_BRANCH'
    $jjRootOut = & jj root 2>$null
    if ($LASTEXITCODE -eq 0 -and $jjRootOut) {
        $branch = if ($mainBranchCfg) { $mainBranchCfg } else { 'main' }
        $bm = & jj bookmark list 2>$null
        $found = $bm | Select-String -Pattern ('^' + [regex]::Escape($branch) + ':')
        if (-not $found -and -not $mainBranchCfg) {
            $branch = 'master'
            $found = $bm | Select-String -Pattern '^master:'
        }
        if ($found) {
            Write-Host ('OK   main branch determinable: jj bookmark {0}' -f $branch)
        } else {
            Write-Host ('FAIL cannot determine main branch: no jj bookmark {0} found; set MAIN_BRANCH in .work/config.md if the trunk has a different name' -f $branch)
        }
    } else {
        $gitRootOut = & git rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -eq 0 -and $gitRootOut) {
            $branch = $mainBranchCfg
            if (-not $branch) {
                $oh = & git symbolic-ref --short refs/remotes/origin/HEAD 2>$null
                if ($LASTEXITCODE -eq 0 -and $oh) { $branch = ($oh -replace '^origin/', '') }
            }
            if (-not $branch) { $branch = 'main' }
            & git rev-parse --verify $branch *> $null
            if ($LASTEXITCODE -ne 0) { $branch = 'master'; & git rev-parse --verify $branch *> $null }
            if ($LASTEXITCODE -eq 0) {
                Write-Host ('OK   main branch determinable: git branch {0}' -f $branch)
            } else {
                Write-Host 'FAIL cannot determine main branch: neither main nor master resolves and no origin/HEAD/MAIN_BRANCH; set MAIN_BRANCH in .work/config.md'
            }
        } else {
            Write-Host 'WARN not a git or jj repository here - main-branch check skipped (run cc-doctor from the target project root)'
        }
    }
} finally {
    Pop-Location -ErrorAction SilentlyContinue
}

# Agent-mirror freshness - only meaningful when this runs from an actual Orchestra repo
# checkout (agent definitions live under $RepoRoot/agents). Same agents/ source and
# reduced exclusion set (only the two generator templates) as cc-sync.
$agentsDir = Join-Path $RepoRoot 'agents'
if ($RepoRoot -and (Test-Path -LiteralPath $agentsDir)) {
    $mirrorDir = Join-Path $HomeDir '.claude/agents'
    $excludeNames = @('coder.template.md', 'reviewer.template.md')
    $srcFiles = Get-ChildItem -LiteralPath $agentsDir -File -Filter '*.md' -ErrorAction SilentlyContinue | Where-Object { $excludeNames -notcontains $_.Name }
    if (-not $srcFiles -or $srcFiles.Count -eq 0) {
        Write-Host 'OK   agent-mirror freshness check skipped (no agent .md files under agents/ - not the Orchestra repo checkout)'
    } else {
        $stale = New-Object System.Collections.ArrayList
        $missing = New-Object System.Collections.ArrayList
        foreach ($f in $srcFiles) {
            $dst = Join-Path $mirrorDir $f.Name
            if (-not (Test-Path -LiteralPath $dst)) { [void]$missing.Add($f.Name); continue }
            $srcBytes = [System.IO.File]::ReadAllBytes($f.FullName)
            $dstBytes = [System.IO.File]::ReadAllBytes($dst)
            if (-not [System.Linq.Enumerable]::SequenceEqual([byte[]]$srcBytes, [byte[]]$dstBytes)) { [void]$stale.Add($f.Name) }
        }
        if ($missing.Count -eq 0 -and $stale.Count -eq 0) {
            Write-Host ('OK   ~/.claude/agents mirror up to date with {0} agent file(s) in this checkout' -f $srcFiles.Count)
        } else {
            Write-Host 'FAIL ~/.claude/agents mirror stale relative to this checkout:'
            foreach ($m2 in $missing) { Write-Host ('  - ' + $m2 + ': missing in mirror') }
            foreach ($s in $stale) { Write-Host ('  - ' + $s + ': content differs from checkout') }
            Write-Host '  run cc-sync to refresh the mirror'
        }
    }
} else {
    Write-Host 'OK   agent-mirror freshness check skipped (not running from the Orchestra repo checkout)'
}

exit 0
