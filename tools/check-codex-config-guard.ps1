<#
.SYNOPSIS
    Guards the single-source fail-closed validation contract for the six
    value-constrained Codex config keys (task T-072): their allowed value sets
    and defaults must stay identical across config.example.md, agents/processor.md,
    launchers/cc-doctor.cmd and launchers/cc-doctor.sh.

.DESCRIPTION
    CODEX_CODER, CODEX_REVIEWER, CODEX_CIFIX, CODEX_REASONING, CODEX_SANDBOX and
    CODEX_NETWORK each accept only a fixed set of values; an out-of-set value is a
    configuration error that must stop the cohort at Phase 1.1 rather than be
    silently replaced by a default. The single source of truth for those sets and
    defaults is the "Допустимые значения Codex-ключей" table in config.example.md.

    Because cc-doctor must keep working when mirrored standalone into
    ~/.claude/scripts (where tools/ and config.example.md are absent), it cannot
    read config.example.md at runtime - it, like processor.md's Phase 1.1 branching,
    carries its own copy of the allowed sets. This is the same architecture as the
    config-key allowlist already guarded by tools/check-consistency.ps1 (Class 4,
    task T-043). This script machine-guarantees that the four copies do not drift:

      1. config.example.md validation table  - the source of truth (allowed sets
                                                + per-key defaults).
      2. config.example.md defaults table     - each validated key's default there
                                                must match the validation table.
      3. agents/processor.md                  - the `KEY ∈ {...}` branching form
                                                must list the same allowed sets.
      4. launchers/cc-doctor.cmd              - the $codexAllowed hashtable.
      5. launchers/cc-doctor.sh               - the codex_allowed() case block.

    Sets are compared order-insensitively; defaults must match exactly and must be
    a member of their own allowed set. On any discrepancy, prints one line per
    finding as "<source> - <check> - <detail>" and exits 1. A structural problem
    (a required file / table / block is missing or unparseable, i.e. the format
    changed) exits 2 so it is never mistaken for "contract satisfied". Nothing to
    report -> a short summary and exit 0. Same ad-hoc-runnable style as
    tools/check-consistency.ps1 and tools/check-codex-sandbox-guard.ps1.

.EXAMPLE
    pwsh -File tools/check-codex-config-guard.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ConfigFile = Join-Path $RepoRoot 'config.example.md'
$ProcessorFile = Join-Path $RepoRoot 'agents/processor.md'
$CcDoctorCmdFile = Join-Path $RepoRoot 'launchers/cc-doctor.cmd'
$CcDoctorShFile = Join-Path $RepoRoot 'launchers/cc-doctor.sh'

foreach ($required in @($ConfigFile, $ProcessorFile, $CcDoctorCmdFile, $CcDoctorShFile)) {
    if (-not (Test-Path -LiteralPath $required)) {
        Write-Error "Required reference file not found: $required"
        exit 2
    }
}

# The six value-constrained keys this contract covers. CODEX_MODEL / CODEX_CMD are
# free-form strings (model / binary name) and are intentionally NOT validated.
$ValidatedKeys = @(
    'CODEX_CODER', 'CODEX_REVIEWER', 'CODEX_CIFIX',
    'CODEX_REASONING', 'CODEX_SANDBOX', 'CODEX_NETWORK'
)

$findings = [System.Collections.Generic.List[string]]::new()
function Add-Finding {
    param(
        [Parameter(Mandatory)][string]$FileRef,
        [Parameter(Mandatory)][string]$Check,
        [Parameter(Mandatory)][string]$Detail
    )
    $findings.Add("$FileRef - $Check - $Detail")
}

# Fail hard on a structural (format-changed) problem: the check can no longer be
# trusted to mean "contract satisfied", so exit 2 rather than silently pass.
function Fail-Structural {
    param([string]$Message)
    Write-Error $Message
    exit 2
}

function Sort-Set {
    param([string[]]$Values)
    return (@($Values) | Sort-Object -CaseSensitive)
}

# Compares one key's allowed set from a downstream copy against the source of
# truth, recording a finding on any difference. Order-insensitive.
function Compare-KeySet {
    param(
        [Parameter(Mandatory)][string]$SourceRef,
        [Parameter(Mandatory)][hashtable]$Truth,
        [Parameter(Mandatory)][hashtable]$Actual
    )
    foreach ($key in $ValidatedKeys) {
        if (-not $Actual.ContainsKey($key)) {
            Add-Finding -FileRef $SourceRef -Check 'allowed-set' -Detail "missing key '$key' (not found in this source)"
            continue
        }
        $want = (Sort-Set $Truth[$key]) -join ' | '
        $got = (Sort-Set $Actual[$key]) -join ' | '
        if ($want -cne $got) {
            Add-Finding -FileRef $SourceRef -Check 'allowed-set' `
                -Detail "'$key' allowed set is [$got] but config.example.md's validation table says [$want]"
        }
    }
    foreach ($key in $Actual.Keys) {
        if ($ValidatedKeys -notcontains $key) {
            Add-Finding -FileRef $SourceRef -Check 'allowed-set' `
                -Detail "unexpected key '$key' present in this source but not in the validated-key set"
        }
    }
}

$configLines = Get-Content -LiteralPath $ConfigFile -Encoding utf8

# --- Source of truth: config.example.md validation table --------------------
# Rows look like: | `CODEX_CODER` | `off` \| `fast` \| `fast+std` | `off` |
# The value cell's own pipes are markdown-escaped (\|); split cells on an
# UNescaped pipe so the value cell stays intact.
$specAllowed = @{}
$specDefault = @{}
$inValidationTable = $false
$seenHeader = $false
foreach ($line in $configLines) {
    if (-not $inValidationTable) {
        if ($line -match '^\s*\|.*Допустимые значения.*\|') { $inValidationTable = $true; $seenHeader = $true }
        continue
    }
    if ($line -notmatch '^\s*\|') { break }   # table ended
    if ($line -match '^\s*\|\s*-+') { continue }   # separator row
    $cells = [regex]::Split($line.Trim(), '(?<!\\)\|') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    if ($cells.Count -lt 3) { continue }
    if ($cells[0] -notmatch '^`(CODEX_[A-Z]+)`$') { continue }
    $key = $Matches[1]
    $allowed = @()
    foreach ($m in [regex]::Matches($cells[1], '`([^`]+)`')) { $allowed += $m.Groups[1].Value }
    if ($cells[2] -match '^`([^`]+)`$') { $specDefault[$key] = $Matches[1] }
    if ($allowed.Count -gt 0) { $specAllowed[$key] = $allowed }
}

if (-not $seenHeader) {
    Fail-Structural "Could not find the Codex validation table ('| ... Допустимые значения ... |') in $ConfigFile - format may have changed"
}
foreach ($key in $ValidatedKeys) {
    if (-not $specAllowed.ContainsKey($key)) {
        Fail-Structural "Codex validation table in $ConfigFile does not list '$key' - format may have changed"
    }
    if (-not $specDefault.ContainsKey($key)) {
        Fail-Structural "Codex validation table in $ConfigFile has no default for '$key' - format may have changed"
    }
    # Sanity: the documented default must itself be a member of the allowed set.
    if ($specAllowed[$key] -cnotcontains $specDefault[$key]) {
        Add-Finding -FileRef 'config.example.md' -Check 'default-membership' `
            -Detail "'$key' default '$($specDefault[$key])' is not one of its own allowed values [$((Sort-Set $specAllowed[$key]) -join ' | ')]"
    }
}

# --- config.example.md general defaults table (## Значения по умолчанию) ------
# Cross-check that each validated key's default there matches the validation
# table (so the two tables in the same file cannot silently disagree).
$generalDefault = @{}
$inDefaults = $false
foreach ($line in $configLines) {
    if ($line -match '^##\s+Значения по умолчанию') { $inDefaults = $true; continue }
    if ($inDefaults -and $line -match '^##\s') { break }
    if ($inDefaults -and $line -match '^\s*\|\s*`(CODEX_[A-Z]+)`\s*\|\s*(.+?)\s*\|\s*$') {
        $k = $Matches[1]
        # Leading bare token of the default cell (e.g. "off (или env...)" -> "off",
        # "workspace-write" -> "workspace-write"). Values use +/- (fast+std,
        # workspace-write, read-only).
        if ($Matches[2] -match '^`?([A-Za-z0-9][A-Za-z0-9+\-]*)') { $generalDefault[$k] = $Matches[1] }
    }
}
foreach ($key in $ValidatedKeys) {
    if (-not $generalDefault.ContainsKey($key)) {
        Add-Finding -FileRef 'config.example.md' -Check 'defaults-table' `
            -Detail "'$key' has no row in the '## Значения по умолчанию' table"
        continue
    }
    if ($generalDefault[$key] -cne $specDefault[$key]) {
        Add-Finding -FileRef 'config.example.md' -Check 'defaults-table' `
            -Detail "'$key' default is '$($generalDefault[$key])' in the defaults table but '$($specDefault[$key])' in the validation table"
    }
}

# --- agents/processor.md branching: `KEY` ∈ {v1, v2, ...} --------------------
# ∈ is the set-membership sign; matched by code point to keep this script's
# own source ASCII-safe regardless of how it is read.
$processorText = (Get-Content -LiteralPath $ProcessorFile -Encoding utf8) -join "`n"
$procAllowed = @{}
foreach ($m in [regex]::Matches($processorText, '`(CODEX_[A-Z]+)`\s*∈\s*\{([^}]*)\}')) {
    $key = $m.Groups[1].Value
    $vals = $m.Groups[2].Value -split ',' | ForEach-Object { $_.Trim().Trim('`') } | Where-Object { $_ -ne '' }
    if ($vals.Count -gt 0) { $procAllowed[$key] = @($vals) }
}
$missingProc = @($ValidatedKeys | Where-Object { -not $procAllowed.ContainsKey($_) })
if ($missingProc.Count -eq $ValidatedKeys.Count) {
    Fail-Structural "Could not find any 'KEY ∈ {...}' Codex allowed-set form in $ProcessorFile - format may have changed"
}
Compare-KeySet -SourceRef 'agents/processor.md' -Truth $specAllowed -Actual $procAllowed

# --- launchers/cc-doctor.cmd: $codexAllowed=[ordered]@{ 'KEY'=@('a','b'); ... } -
$cmdText = Get-Content -LiteralPath $CcDoctorCmdFile -Raw -Encoding utf8
if ($cmdText -notmatch '\$codexAllowed\s*=\s*\[ordered\]@\{') {
    Fail-Structural "Could not find the `$codexAllowed hashtable in $CcDoctorCmdFile - format may have changed"
}
$cmdAllowed = @{}
foreach ($m in [regex]::Matches($cmdText, "'(CODEX_[A-Z]+)'\s*=\s*@\(([^)]*)\)")) {
    $key = $m.Groups[1].Value
    $vals = @()
    foreach ($vm in [regex]::Matches($m.Groups[2].Value, "'([^']+)'")) { $vals += $vm.Groups[1].Value }
    if ($vals.Count -gt 0) { $cmdAllowed[$key] = $vals }
}
Compare-KeySet -SourceRef 'launchers/cc-doctor.cmd' -Truth $specAllowed -Actual $cmdAllowed

# --- launchers/cc-doctor.sh: codex_allowed() case: KEY) echo "a b c" ;; -------
$shText = Get-Content -LiteralPath $CcDoctorShFile -Raw -Encoding utf8
if ($shText -notmatch 'codex_allowed\s*\(\)\s*\{') {
    Fail-Structural "Could not find the codex_allowed() function in $CcDoctorShFile - format may have changed"
}
$shAllowed = @{}
foreach ($m in [regex]::Matches($shText, '(CODEX_[A-Z]+)\)\s*echo\s+"([^"]*)"')) {
    $key = $m.Groups[1].Value
    $vals = $m.Groups[2].Value -split '\s+' | Where-Object { $_ -ne '' }
    if ($vals.Count -gt 0) { $shAllowed[$key] = @($vals) }
}
Compare-KeySet -SourceRef 'launchers/cc-doctor.sh' -Truth $specAllowed -Actual $shAllowed

# --- Report -----------------------------------------------------------------
if ($findings.Count -eq 0) {
    Write-Host "OK - Codex config value contract holds: allowed sets + defaults agree across config.example.md, agents/processor.md, launchers/cc-doctor.cmd and launchers/cc-doctor.sh for $($ValidatedKeys.Count) keys."
    exit 0
}

Write-Host "Found $($findings.Count) Codex config value contract inconsistency(ies):`n"
foreach ($f in $findings) {
    Write-Host $f
}
exit 1
