<#
.SYNOPSIS
    The single, versioned schema source for Orchestra's configuration (.work/config.md)
    and its policy (.work/constraints.md), plus the shared primitives the schema-driven
    validators and the destructive-operation runtime guard are built on.

.DESCRIPTION
    Historically the config keys and their defaults were duplicated as prose across
    config.example.md, cc-doctor and processor.md, while the policy
    (.work/constraints.md) was free Markdown that roles only "read". Nothing described
    the two in one machine-readable place, so documentation and validators could drift and
    the policy was never an executable boundary. This file is that one place:

      * Get-OrchestraSchema returns a single versioned object describing every config key
        (type, default, enum/range, OS-environment precedence, sensitivity) and every
        policy section (its heading in constraints.example.md and how it is interpreted).
        tools/policy.ps1 (the CLI), tools/check-consistency.ps1 (Class 5, the smoke gate)
        and tests/test-policy.ps1 all consume THIS object, so the docs and validators are
        machine-checked against one source instead of hand-kept in sync.

      * The value/path/glob primitives (Test-ConfigValue, Get-RealFsPath, Test-PathAtOrUnder,
        Test-GlobMatch, ConvertFrom-ConfigText, Get-PolicyActiveBullets, ...) are the shared
        building blocks the schema-driven verbs (validate-config / validate-policy / migrate)
        and the runtime guard (guard-path / check-paths / check-publish) are assembled from.

    This is a LIBRARY: it defines functions/variables and performs no top-level action, so
    it can be dot-sourced safely (`. tools/policy-schema.ps1`). `tools/policy.ps1 schema`
    prints the schema as JSON for anyone who wants it as data.

.NOTES
    Single source of truth. The config key NAMES here are machine-checked to equal
    config.example.md's "Значения по умолчанию" table (and, for the six value-constrained
    Codex keys, their allowed value sets are checked to equal the "Допустимые значения
    Codex-ключей" table) by tools/check-consistency.ps1 Class 5. Because config.example.md's
    table is in turn checked to equal the cc-doctor allowlist (Class 4), a change here that
    is not mirrored into config.example.md - and thence cc-doctor - fails the smoke gate. So
    cc-doctor's engine (tools/doctor-runtime.ps1) keeps its own hardcoded copy (it must run
    when mirrored standalone into ~/.claude/scripts) yet cannot drift from this schema.

    Runs under PowerShell 7 (pwsh). Get-RealFsPath uses .NET 6+ ResolveLinkTarget for
    symlink/junction resolution; under Windows PowerShell 5.1 that call is unavailable and
    the resolver degrades to pure path normalization (the at/under-root and `..` checks still
    apply, but a junction routed through an ancestor is not followed). The orchestrator runs
    pwsh, and the tests run on the pwsh 7 CI runner, where the full resolution is exercised.
#>

Set-StrictMode -Version Latest

# ============================================================================
# The schema
# ============================================================================

$script:PolicySchemaVersion = 'orchestra/policy-schema@1'

# One config-key descriptor.
#   name        - the .work/config.md key (UPPER_SNAKE_CASE).
#   type        - 'int' | 'bool' | 'enum' | 'string'.
#   default     - human default string (matches config.example.md's defaults table prose).
#   enum        - allowed value set for 'enum' (else $null).
#   min         - inclusive lower bound for 'int' (else $null); ints have no explicit max.
#   envFallback - $true only for the two keys that also resolve from the OS environment.
#   sensitivity - 'low' | 'medium' | 'high' (how much a wrong value can widen blast radius).
function New-ConfigKey {
    param(
        [string]$Name, [string]$Type, [string]$Default,
        [string[]]$Enum = $null, $Min = $null,
        [bool]$EnvFallback = $false, [string]$Sensitivity = 'low'
    )
    return [ordered]@{
        name        = $Name
        type        = $Type
        default     = $Default
        enum        = $Enum
        min         = $Min
        envFallback = $EnvFallback
        sensitivity = $Sensitivity
    }
}

function Get-SchemaConfigKeys {
    return @(
        (New-ConfigKey 'MAX_PARALLEL'            'int'    '5'                                -Min 1  -Sensitivity 'medium')
        (New-ConfigKey 'COHORT_SIZE'             'int'    '3xMAX_PARALLEL'                   -Min 1)
        (New-ConfigKey 'COHORT_MAX_AGE'          'int'    '90'                               -Min 1)
        (New-ConfigKey 'REVIEW_MIN_PASSES'       'int'    '2'                                -Min 1)
        (New-ConfigKey 'REVIEW_LOOP_MAX'         'int'    '8'                                -Min 1)
        (New-ConfigKey 'INTEGRATION_LOOP_MAX'    'int'    '8'                                -Min 1)
        (New-ConfigKey 'CI_FIX_MAX'              'int'    '5'                                -Min 1)
        (New-ConfigKey 'QUARANTINE_MAX_ATTEMPTS' 'int'    '3'                                -Min 1)
        (New-ConfigKey 'CALL_DEADLINE_SEC'       'int'    '1800'                             -Min 1  -Sensitivity 'medium')
        (New-ConfigKey 'CALL_MAX_ATTEMPTS'       'int'    '2'                                -Min 1)
        (New-ConfigKey 'CALL_OUTPUT_MAX_BYTES'   'int'    '1048576'                          -Min 1)
        (New-ConfigKey 'COHORT_BUDGET_SEC'       'int'    '0'                                -Min 0  -Sensitivity 'medium')
        (New-ConfigKey 'SMOKE_CMD'               'string' 'unset'                            -Sensitivity 'medium')
        (New-ConfigKey 'PUSH'                    'bool'   'true'                             -Sensitivity 'high')
        (New-ConfigKey 'CI_WATCH'                'bool'   'true'                             -Sensitivity 'medium')
        (New-ConfigKey 'REVIEWER_TIERING'        'bool'   'true')
        (New-ConfigKey 'MAIN_BRANCH'             'string' 'autodetect'                       -Sensitivity 'high')
        (New-ConfigKey 'EVENTS_OUTBOX'           'enum'   'on'     -Enum @('on', 'off'))
        (New-ConfigKey 'KB'                      'enum'   'off'    -Enum @('on', 'off'))
        (New-ConfigKey 'KB_TTL'                  'int'    '8'                                -Min 1)
        (New-ConfigKey 'KB_CAP'                  'int'    '12'                               -Min 1)
        (New-ConfigKey 'CODEX_CODER'             'enum'   'off'    -Enum @('off', 'fast', 'fast+std')          -EnvFallback $true -Sensitivity 'medium')
        (New-ConfigKey 'CODEX_REVIEWER'          'enum'   'off'    -Enum @('off', 'fast', 'fast+std', 'deep')  -EnvFallback $true -Sensitivity 'medium')
        (New-ConfigKey 'CODEX_CIFIX'             'enum'   'off'    -Enum @('off', 'on')                        -Sensitivity 'medium')
        (New-ConfigKey 'CODEX_MODEL'             'string' 'unset')
        (New-ConfigKey 'CODEX_REASONING'         'enum'   'auto'   -Enum @('auto', 'low', 'medium', 'high'))
        (New-ConfigKey 'CODEX_SANDBOX'           'enum'   'workspace-write' -Enum @('read-only', 'workspace-write') -Sensitivity 'high')
        (New-ConfigKey 'CODEX_NETWORK'           'enum'   'on'     -Enum @('on', 'off')                        -Sensitivity 'high')
        (New-ConfigKey 'CODEX_CMD'               'string' 'codex')
    )
}

# One policy-section descriptor.
#   id          - stable ASCII id.
#   kind        - how the section is interpreted by the guard/gates.
#   heading     - the '## ...' heading it lives under in constraints.example.md.
#   defaultEmpty- $true if the safe default is "no active constraint".
function New-PolicySection {
    param([string]$Id, [string]$Kind, [string]$Heading, [bool]$DefaultEmpty)
    return [ordered]@{ id = $Id; kind = $Kind; heading = $Heading; defaultEmpty = $DefaultEmpty }
}

function Get-SchemaPolicySections {
    return @(
        (New-PolicySection 'denylist'         'path-glob-denylist' 'Запрещённые пути (denylist)'            $true)
        (New-PolicySection 'branches-remotes' 'publish-target'     'Разрешённые ветки и remotes'           $true)
        (New-PolicySection 'push-merge'       'push-merge-policy'  'Push/merge policy'                     $true)
        (New-PolicySection 'required-checks'  'required-commands'  'Обязательные проверки'                 $true)
        (New-PolicySection 'size-thresholds'  'size-thresholds'    'Пороги размера изменений'              $true)
        (New-PolicySection 'human-review'     'human-review'       'Категории обязательного human review'  $false)
    )
}

function Get-OrchestraSchema {
    return [ordered]@{
        version = $script:PolicySchemaVersion
        config  = @(Get-SchemaConfigKeys)
        policy  = @(Get-SchemaPolicySections)
    }
}

function Get-SchemaConfigKey {
    param([string]$Name)
    foreach ($k in (Get-SchemaConfigKeys)) { if ($k.name -eq $Name) { return $k } }
    return $null
}

# ============================================================================
# Config value validation (fail-closed: an out-of-spec value is an error, never a
# silent default). An EMPTY value means "unset -> take the documented default" and is
# always Ok - only a present, non-empty value is checked.
# ============================================================================
function Test-ConfigValue {
    param($Descriptor, [string]$Value)
    $v = ([string]$Value).Trim()
    if ($v -eq '') { return [pscustomobject]@{ Ok = $true; Reason = '' } }   # unset -> default
    switch ($Descriptor.type) {
        'int' {
            if ($v -notmatch '^-?\d+$') {
                return [pscustomobject]@{ Ok = $false; Reason = "'$v' is not an integer" }
            }
            $n = [int]$v
            if ($null -ne $Descriptor.min -and $n -lt [int]$Descriptor.min) {
                return [pscustomobject]@{ Ok = $false; Reason = "$n is below the minimum $($Descriptor.min)" }
            }
            return [pscustomobject]@{ Ok = $true; Reason = '' }
        }
        'bool' {
            if ($v -notin @('true', 'false')) {
                return [pscustomobject]@{ Ok = $false; Reason = "'$v' is not a boolean (true | false)" }
            }
            return [pscustomobject]@{ Ok = $true; Reason = '' }
        }
        'enum' {
            if ($v -notin $Descriptor.enum) {
                return [pscustomobject]@{ Ok = $false; Reason = "'$v' is not one of: $($Descriptor.enum -join ' | ')" }
            }
            return [pscustomobject]@{ Ok = $true; Reason = '' }
        }
        default { return [pscustomobject]@{ Ok = $true; Reason = '' } }   # free string
    }
}

# ============================================================================
# config.md parsing (preserves comments and layout for migration).
# Each entry: Kind ('key' | 'comment' | 'blank'); Key/Value/Comment (for 'key'); Raw; Line.
# Value semantics mirror cc-doctor's GetCfg exactly: value is the text after the first ':'
# up to (but excluding) an inline '#', trimmed.
# ============================================================================
function ConvertFrom-ConfigText {
    param([string[]]$Lines)
    $out = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $raw = $Lines[$i]
        $trim = $raw.Trim()
        if ($trim -eq '') {
            $out.Add([pscustomobject]@{ Kind = 'blank'; Key = ''; Value = ''; Comment = ''; Raw = $raw; Line = $i + 1 })
            continue
        }
        if ($trim.StartsWith('#')) {
            $out.Add([pscustomobject]@{ Kind = 'comment'; Key = ''; Value = ''; Comment = ''; Raw = $raw; Line = $i + 1 })
            continue
        }
        $m = [regex]::Match($raw, '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$')
        if ($m.Success) {
            $key = $m.Groups[1].Value
            $rest = $m.Groups[2].Value
            $comment = ''
            $hIdx = $rest.IndexOf('#')
            if ($hIdx -ge 0) { $comment = $rest.Substring($hIdx); $rest = $rest.Substring(0, $hIdx) }
            $out.Add([pscustomobject]@{ Kind = 'key'; Key = $key; Value = $rest.Trim(); Comment = $comment; Raw = $raw; Line = $i + 1 })
            continue
        }
        # A non-blank, non-comment line that is not KEY: value -> keep verbatim, flag as junk.
        $out.Add([pscustomobject]@{ Kind = 'junk'; Key = ''; Value = ''; Comment = ''; Raw = $raw; Line = $i + 1 })
    }
    return $out
}

# ============================================================================
# constraints.md parsing. Returns the ACTIVE bullet lines of a section (the list under
# "**Активные ..." up to the "**Пример" marker), excluding placeholder bullets like
# "(пусто ...)" / "(по умолчанию ...)". The example block is never returned.
# ============================================================================
function Get-PolicyActiveBullets {
    param([string[]]$Lines, [string]$HeadingText)
    $inSection = $false
    $inActive = $false
    $bullets = [System.Collections.Generic.List[string]]::new()
    foreach ($raw in $Lines) {
        if ($raw -match '^##\s+(.+?)\s*$') {
            $h = $Matches[1]
            if ($h -eq $HeadingText) { $inSection = $true; $inActive = $false; continue }
            elseif ($inSection) { break }   # next section heading ends ours
            else { continue }
        }
        if (-not $inSection) { continue }
        if ($raw -match '^\s*\*\*Активн') { $inActive = $true; continue }
        if ($raw -match '^\s*\*\*Пример') { $inActive = $false; continue }
        if ($inActive -and $raw -match '^\s*-\s+(.*\S)\s*$') {
            $item = $Matches[1]
            # skip pure placeholders
            if ($item -match '^\(\s*(пусто|не задан|по умолчанию)' ) { continue }
            $bullets.Add($item)
        }
    }
    return , $bullets.ToArray()
}

# ============================================================================
# Path canonicalization and containment (the core of the destructive-op guard).
# ============================================================================

# Fully resolve a path to its REAL on-disk location: normalize + collapse '..', then
# resolve symlinks/junctions component by component (following chains) for every existing
# component, so a reparse point anywhere on the path routes the result to its real target.
# A non-existing tail (e.g. a worktree about to be created) is normalized and appended to
# the resolved existing prefix.
function Get-RealFsPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if (-not $root) { $root = '' }
    $rest = $full.Substring($root.Length)
    $comps = $rest -split '[\\/]+' | Where-Object { $_ -ne '' }
    $cur = $root
    foreach ($c in $comps) {
        $cur = if ($cur -eq '') { $c } else { Join-Path $cur $c }
        if (Test-Path -LiteralPath $cur) {
            try {
                $it = Get-Item -LiteralPath $cur -Force -ErrorAction Stop
                $tgt = $null
                try { $tgt = $it.ResolveLinkTarget($true) } catch { $tgt = $null }   # .NET 6+ only
                if ($tgt) {
                    if ([System.IO.Path]::IsPathRooted($tgt.FullName)) { $cur = $tgt.FullName }
                    else { $cur = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $cur) $tgt.FullName)) }
                }
            } catch { }
        }
    }
    return ([System.IO.Path]::GetFullPath($cur)).TrimEnd('\', '/')
}

# Case-insensitive on Windows, case-sensitive elsewhere.
function Get-PathComparer {
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        return [System.StringComparison]::OrdinalIgnoreCase
    }
    return [System.StringComparison]::Ordinal
}

# Is $Child the same as, or nested under, $Root? Both are compared after real-path
# resolution + normalization, so a symlink/junction escape shows up as "not under root".
function Test-PathAtOrUnder {
    param([string]$Child, [string]$Root)
    $c = Get-RealFsPath $Child
    $r = Get-RealFsPath $Root
    if ($c -eq '' -or $r -eq '') { return $false }
    $cmp = Get-PathComparer
    if ([string]::Equals($c, $r, $cmp)) { return $true }
    $rWithSep = $r + [System.IO.Path]::DirectorySeparatorChar
    return $c.StartsWith($rWithSep, $cmp)
}

# Does the RAW (pre-normalization) path contain a parent-traversal '..' segment?
function Test-HasDotDotSegment {
    param([string]$Path)
    foreach ($seg in ($Path -split '[\\/]+')) { if ($seg -eq '..') { return $true } }
    return $false
}

# ============================================================================
# Glob matching for the denylist (supports **, *, ? on '/'-normalized paths).
# ============================================================================
function ConvertTo-NormalizedRelPath {
    param([string]$Path)
    $p = ([string]$Path).Trim().Replace('\', '/')
    while ($p.StartsWith('./')) { $p = $p.Substring(2) }
    return $p.TrimStart('/')
}

function Convert-GlobToRegex {
    param([string]$Glob)
    $g = ConvertTo-NormalizedRelPath $Glob
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('^')
    $i = 0
    while ($i -lt $g.Length) {
        $ch = $g[$i]
        if ($ch -eq '*') {
            if ($i + 1 -lt $g.Length -and $g[$i + 1] -eq '*') {
                # '**' : zero or more path segments.
                $i += 2
                if ($i -lt $g.Length -and $g[$i] -eq '/') {
                    [void]$sb.Append('(?:.*/)?'); $i++     # '**/' -> optional leading segments
                } else {
                    [void]$sb.Append('.*')                  # '**' (trailing or mid) -> anything
                }
            } else {
                [void]$sb.Append('[^/]*'); $i++             # '*' -> within one segment
            }
        } elseif ($ch -eq '?') {
            [void]$sb.Append('[^/]'); $i++
        } else {
            [void]$sb.Append([regex]::Escape([string]$ch)); $i++
        }
    }
    [void]$sb.Append('$')
    return $sb.ToString()
}

function Test-GlobMatch {
    param([string]$Path, [string]$Glob)
    $p = ConvertTo-NormalizedRelPath $Path
    $rx = Convert-GlobToRegex $Glob
    $opts = [System.Text.RegularExpressions.RegexOptions]::None
    if ((Get-PathComparer) -eq [System.StringComparison]::OrdinalIgnoreCase) {
        $opts = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    }
    return [regex]::IsMatch($p, $rx, $opts)
}

# ============================================================================
# Id validation
# ============================================================================
function Test-TaskId  { param([string]$Id) return ($Id -eq '_integration' -or $Id -match '^T-\d+$') }
function Test-BatchId { param([string]$Id) return ($Id -match '^B-\d{8}T\d{6}Z$') }
