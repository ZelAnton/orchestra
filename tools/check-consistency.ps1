<#
.SYNOPSIS
    Checks cross-agent textual contract consistency across Orchestra's role .md files.

.DESCRIPTION
    Agent role files reference each other only through plain text: config keys,
    processor phase numbers, and runtime-artifact filenames. Nothing enforces that
    these references stay in sync with their sources of truth, so drift is currently
    only caught by manual review. This script machine-checks three classes of such
    cross-file contracts:

      1. Config keys      — every UPPER_SNAKE_CASE config key referenced in an agent
                             file exists in the defaults table of config.example.md,
                             and every key in that table is referenced by at least one
                             agent file.
      2. Processor phases  — every "Фаза N" / "Фаза N.M" label referenced in an agent
                             file (other than as that file's own section heading)
                             actually appears somewhere in processor.md.
      3. Runtime artifacts — every `.work/`-style runtime-artifact filename (e.g.
                             review_integration.md, merge_report.md, cohort_state.md)
                             referenced in an agent file appears in the runtime-artifact
                             table of knowledge.md.

    "Agent files" = the *.md files under the agents/ directory that start with a YAML
    frontmatter block (`---` as the very first line) — i.e. the actual role definitions
    (processor.md, coder*.md, reviewer*.md, ...). Documentation lives in the repo root
    (AGENTS.md, knowledge.md, config.example.md, README.md, plans/*.md), not in agents/,
    and is not scanned; two of those root files (config.example.md, knowledge.md) instead
    serve as the source of truth that agent files are checked against.

    On any discrepancy, prints one line per finding in the form
    "<file> — <check> — <detail>" and exits with a non-zero code. With nothing to
    report, prints a short summary and exits 0.

.NOTES
    Manual, ad-hoc tool for now (see task T-017) — CI/cc-sync integration is out of
    scope here (tracked separately, e.g. T-019).

.EXAMPLE
    pwsh -File tools/check-consistency.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
# Agent role definitions live under agents/; config.example.md and knowledge.md (the
# reference sources of truth) stay in the repo root.
$AgentsDir = Join-Path $RepoRoot 'agents'
$ConfigFile = Join-Path $RepoRoot 'config.example.md'
$KnowledgeFile = Join-Path $RepoRoot 'knowledge.md'
$ProcessorFile = Join-Path $AgentsDir 'processor.md'

foreach ($required in @($ConfigFile, $KnowledgeFile, $ProcessorFile)) {
    if (-not (Test-Path -LiteralPath $required)) {
        Write-Error "Required reference file not found: $required"
        exit 2
    }
}

# --- Findings collector -----------------------------------------------------

$findings = [System.Collections.Generic.List[string]]::new()

function Add-Finding {
    param(
        [Parameter(Mandatory)][string]$FileRef,
        [Parameter(Mandatory)][string]$Check,
        [Parameter(Mandatory)][string]$Detail
    )
    $findings.Add("$FileRef - $Check - $Detail")
}

function Strip-InlineCode {
    # Remove `...` spans so command/regex examples inside inline code aren't parsed as
    # prose references (e.g. an `rg -n "Фаза N"` example quoted in documentation).
    param([string]$Line)
    return [regex]::Replace($Line, '`[^`]*`', '')
}

# --- Discover agent files (frontmatter-bearing .md files at repo root) -----

$agentFiles = Get-ChildItem -Path $AgentsDir -Filter '*.md' -File | Where-Object {
    (Get-Content -LiteralPath $_.FullName -TotalCount 1 -Encoding utf8) -ceq '---'
} | Sort-Object Name

if (-not $agentFiles -or $agentFiles.Count -eq 0) {
    Write-Error "No agent .md files (YAML-frontmatter role files) found under $AgentsDir"
    exit 2
}

Write-Host "Discovered $($agentFiles.Count) agent files under $AgentsDir"

# =============================================================================
# Class 1 — config keys vs config.example.md defaults table
# =============================================================================

$configLines = Get-Content -LiteralPath $ConfigFile -Encoding utf8

$defaultKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$inTable = $false
foreach ($line in $configLines) {
    if ($line -match '^##\s+Значения по умолчанию') { $inTable = $true; continue }
    if ($inTable -and $line -match '^##\s') { break }
    if ($inTable -and $line -match '^\|\s*`([A-Z][A-Z0-9_]*)`\s*\|') {
        [void]$defaultKeys.Add($Matches[1])
    }
}

if ($defaultKeys.Count -eq 0) {
    Write-Error "Could not parse the defaults table ('## Значения по умолчанию') in $ConfigFile - format may have changed"
    exit 2
}

# Tokens that match the UPPER_SNAKE_CASE shape but are NOT config keys: derived/local
# shell variables, adapter escalation sentinels, failure-classification label terms (e.g.
# ENV_LIMIT, used in sentinel messages like "CODEX_FAILED — ENV_LIMIT/<class>: <detail>"
# and as a section-heading reference, not a .work/config.md key), the codex->broker
# network-request protocol token (NEED_NET, emitted by codex as "NEED_NET: <command>" for
# the coder_codex dependency broker, not a .work/config.md key), the launcher->processor
# session-grant signal (CC_CODEX_EXEC_GRANT, exported by cc-processor/cc-resume and read by
# the Phase 1.1 gate / cc-doctor as an environment variable, not a .work/config.md key -
# task T-071), plan/doc filenames referenced in caps, git-config-via-environment variable
# names and a Windows schannel error code quoted verbatim inside the codex adapter's
# network-override snippet, and the naming-convention term itself. Reviewed by hand against
# current repo content; extend this list if a genuinely new non-key token starts matching.
$nonKeyTokens = [System.Collections.Generic.HashSet[string]]::new([string[]]@(
        'CC_CODEX_EXEC_GRANT', 'CODEX_FAILED', 'CODEX_UNAVAILABLE', 'CODEX_REVIEW_MODE', 'DEFAULT_BRANCH',
        'DIFF_TOO_LARGE', 'EMPTY_DIFF', 'ENV_LIMIT', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0',
        'LOOP_ORCHESTRA_ROADMAP', 'NEED_NET', 'NET_GIT', 'NET_NET', 'OBSERVABILITY_PLATFORM_PLAN',
        'OTHER_FAILURE', 'SEC_E_NO_CREDENTIALS', 'SKIP_GIT', 'SMOKE_FAILED', 'JJ_DRIFT',
        'UPPER_SNAKE_CASE'
    ), [StringComparer]::Ordinal)

$keyPattern = '\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b'
$usedKeyLocations = [ordered]@{}   # key -> List[string] of "file:line"

# A few table keys are a single ALL-CAPS word without an underscore (e.g. `PUSH`, `KB`)
# — the general UPPER_SNAKE_CASE pattern above can't safely catch bare single words
# without flooding on unrelated acronyms (CI, VCS, SHA, ...), so for those specific
# known keys look for literal word-boundary matches instead.
$singleWordKeys = $defaultKeys | Where-Object { $_ -notmatch '_' }

foreach ($file in $agentFiles) {
    $lines = Get-Content -LiteralPath $file.FullName -Encoding utf8
    for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($m in [regex]::Matches($lines[$i], $keyPattern)) {
            $tok = $m.Value
            if ($nonKeyTokens.Contains($tok)) { continue }
            if (-not $usedKeyLocations.Contains($tok)) { $usedKeyLocations[$tok] = [System.Collections.Generic.List[string]]::new() }
            $usedKeyLocations[$tok].Add("$($file.Name):$($i + 1)")
        }
        foreach ($key in $singleWordKeys) {
            if ([regex]::IsMatch($lines[$i], "\b$key\b")) {
                if (-not $usedKeyLocations.Contains($key)) { $usedKeyLocations[$key] = [System.Collections.Generic.List[string]]::new() }
                $usedKeyLocations[$key].Add("$($file.Name):$($i + 1)")
            }
        }
    }
}

foreach ($tok in $usedKeyLocations.Keys) {
    if (-not $defaultKeys.Contains($tok)) {
        $locs = $usedKeyLocations[$tok]
        $sample = ($locs | Select-Object -First 3) -join ', '
        if ($locs.Count -gt 3) { $sample += ", ... (+$($locs.Count - 3) more)" }
        Add-Finding -FileRef $sample -Check 'config-key' `
            -Detail "'$tok' used in agent files but missing from the defaults table in config.example.md"
    }
}

foreach ($key in $defaultKeys) {
    if (-not $usedKeyLocations.Contains($key)) {
        Add-Finding -FileRef (Split-Path -Leaf $ConfigFile) -Check 'config-key' `
            -Detail "'$key' is in the defaults table but not referenced by any agent file"
    }
}

# =============================================================================
# Class 2 — processor phase references vs processor.md
# =============================================================================

$phasePattern = 'Фаза\s*(\d+(?:\.\d+)?)'

# All phase labels processor.md itself uses (section headings and inline sub-phase
# references, e.g. "Фаза 4.3", "Фаза 5.4") — processor.md is authoritative, so whatever
# label it uses anywhere in its own body counts as "existing".
$processorLines = Get-Content -LiteralPath $ProcessorFile -Encoding utf8
$knownProcessorPhases = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($line in $processorLines) {
    foreach ($m in [regex]::Matches((Strip-InlineCode $line), $phasePattern)) {
        [void]$knownProcessorPhases.Add($m.Groups[1].Value)
    }
}

if ($knownProcessorPhases.Count -eq 0) {
    Write-Error "Could not find any 'Фаза N' label in $ProcessorFile - format may have changed"
    exit 2
}

foreach ($file in $agentFiles) {
    if ($file.FullName -eq (Resolve-Path $ProcessorFile).Path) { continue } # authoritative source, not a reference to itself

    $lines = Get-Content -LiteralPath $file.FullName -Encoding utf8

    # This file's own section headings named "Фаза N" (if any) define its own phase
    # scheme (e.g. reviewer.md/full_reviewer.md/github_sync.md each number their own
    # workflow phases 0..N) — inline mentions of those numbers are self-references, not
    # references to processor.md, and must not be checked against it.
    $ownPhases = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($line in $lines) {
        if ($line -match "^#+\s*$phasePattern") {
            [void]$ownPhases.Add($Matches[1])
        }
    }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $clean = Strip-InlineCode $lines[$i]
        foreach ($m in [regex]::Matches($clean, $phasePattern)) {
            $num = $m.Groups[1].Value
            if ($ownPhases.Contains($num)) { continue }
            if (-not $knownProcessorPhases.Contains($num)) {
                Add-Finding -FileRef "$($file.Name):$($i + 1)" -Check 'processor-phase' `
                    -Detail "references 'Фаза $num', which does not exist in processor.md"
            }
        }
    }
}

# =============================================================================
# Class 3 — runtime-artifact filenames vs knowledge.md's runtime-artifact table
# =============================================================================

$knowledgeLines = Get-Content -LiteralPath $KnowledgeFile -Encoding utf8

$canonicalArtifacts = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$inArtifactTable = $false
foreach ($line in $knowledgeLines) {
    if ($line -match '^##\s+Runtime-артефакты') { $inArtifactTable = $true; continue }
    if ($inArtifactTable -and $line -match '^##\s') { break }
    if ($inArtifactTable -and $line -match '^\|\s*`([^`]+)`\s*\|') {
        $path = $Matches[1].TrimEnd('/')
        $basename = ($path -split '/')[-1]
        if ($basename -match '\.(md|lock)$') {
            [void]$canonicalArtifacts.Add($basename)
        }
    }
}

if ($canonicalArtifacts.Count -eq 0) {
    Write-Error "Could not parse the runtime-artifact table ('## Runtime-артефакты...') in $KnowledgeFile - format may have changed"
    exit 2
}

# Repo-internal doc/source filenames (recursively, minus VCS/.work churn dirs) — a
# matched filename that is actually a file in this repo is a self-referential doc
# mention (e.g. "processor.md", "AGENTS.md", "plans/LOOP_ORCHESTRA_ROADMAP.md"), not a
# `.work/` runtime artifact, and must not be checked against the runtime-artifact table.
$excludeDirs = @('\.git\\', '\.jj\\', '\.work\\', 'node_modules\\')
$repoFileNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
Get-ChildItem -Path $RepoRoot -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($RepoRoot.Length)
    if ($excludeDirs | Where-Object { $rel -match $_ }) { return }
    [void]$repoFileNames.Add($_.Name)
}

# Known non-table filenames that are intentionally NOT individual rows in knowledge.md's
# runtime-artifact table: KB shard files summarized under the single `.work/knowledge/`
# row (INDEX.md, learnings.md), per-invocation Codex scratch output (not durable
# coordination state), an external spec file outside `.work/` entirely, literal example
# filenames quoted from third-party tool error messages (e.g. git's index.lock in an
# ENV_LIMIT vcs-write error signature), and third-party dependency-manager lock files named
# in the coder_codex network broker's allowlist (Cargo.lock, uv.lock — regenerated by the
# broker) rather than Orchestra's own runtime state.
$knownNonArtifact = [System.Collections.Generic.HashSet[string]]::new([string[]]@(
        'INDEX.md', 'learnings.md', 'codex_out.md', 'codex_review_out.md', 'Tasks_Queue_Format.md',
        'index.lock', 'Cargo.lock', 'uv.lock'
    ), [StringComparer]::Ordinal)

$filenamePattern = '(?<![.\w])[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)*\.(?:md|lock)\b'
$artifactLocations = [ordered]@{}   # basename -> List[string] of "file:line"

foreach ($file in $agentFiles) {
    if ($file.FullName -eq (Resolve-Path $KnowledgeFile -ErrorAction SilentlyContinue).Path) { continue }
    $lines = Get-Content -LiteralPath $file.FullName -Encoding utf8
    for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($m in [regex]::Matches($lines[$i], $filenamePattern)) {
            $name = $m.Value
            if ($repoFileNames.Contains($name)) { continue }
            if ($knownNonArtifact.Contains($name)) { continue }
            if (-not $artifactLocations.Contains($name)) { $artifactLocations[$name] = [System.Collections.Generic.List[string]]::new() }
            $artifactLocations[$name].Add("$($file.Name):$($i + 1)")
        }
    }
}

foreach ($name in $artifactLocations.Keys) {
    if (-not $canonicalArtifacts.Contains($name)) {
        $locs = $artifactLocations[$name]
        $sample = ($locs | Select-Object -First 3) -join ', '
        if ($locs.Count -gt 3) { $sample += ", ... (+$($locs.Count - 3) more)" }
        Add-Finding -FileRef $sample -Check 'runtime-artifact' `
            -Detail "'$name' referenced in agent files but missing from the runtime-artifact table in knowledge.md"
    }
}

# =============================================================================
# Class 4 — cc-doctor allowlist vs config.example.md defaults table
# =============================================================================
#
# tools/doctor-runtime.ps1 (the unified cc-doctor engine; since task T-090 the
# former cc-doctor.cmd/.sh are thin wrappers that delegate to it) hardcodes an
# allowlist of recognized .work/config.md keys (used to flag unknown/mistyped
# keys). That list is meant to track the defaults table in config.example.md
# exactly (task T-043) — this check catches drift between the two without
# requiring cc-doctor to parse config.example.md at runtime (its engine must keep
# working when mirrored standalone into ~/.claude/scripts, see the comments in
# tools/doctor-runtime.ps1).

$DoctorRuntimeFile = Join-Path $RepoRoot 'tools/doctor-runtime.ps1'

if (-not (Test-Path -LiteralPath $DoctorRuntimeFile)) {
    Write-Error "Required reference file not found: $DoctorRuntimeFile"
    exit 2
}

$rtContent = Get-Content -LiteralPath $DoctorRuntimeFile -Raw -Encoding utf8
$rtMatch = [regex]::Match($rtContent, '\$known\s*=\s*@\(([^)]*)\)')
if (-not $rtMatch.Success) {
    Write-Error "Could not find the `$known=@(...)` allowlist in $DoctorRuntimeFile - format may have changed"
    exit 2
}
$doctorKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($m in [regex]::Matches($rtMatch.Groups[1].Value, "'([A-Za-z0-9_]+)'")) {
    [void]$doctorKeys.Add($m.Groups[1].Value)
}

$srcName = 'tools/doctor-runtime.ps1'
foreach ($key in $doctorKeys) {
    if (-not $defaultKeys.Contains($key)) {
        Add-Finding -FileRef $srcName -Check 'cc-doctor-allowlist' `
            -Detail "'$key' is in the allowlist but missing from the defaults table in config.example.md"
    }
}
foreach ($key in $defaultKeys) {
    if (-not $doctorKeys.Contains($key)) {
        Add-Finding -FileRef $srcName -Check 'cc-doctor-allowlist' `
            -Detail "'$key' is in the defaults table in config.example.md but missing from the allowlist"
    }
}

# =============================================================================
# Class 5 — versioned schema source (tools/policy-schema.ps1) vs config.example.md
# =============================================================================
#
# tools/policy-schema.ps1 is the single, versioned schema source that describes every
# config key and the policy sections (task T-084); tools/policy.ps1 (the executable policy
# boundary) and cc-config/cc-doctor's validators derive from it. To keep documentation and
# the validators synchronized with that one source, this check machine-guarantees that the
# schema's config-key NAMES equal config.example.md's defaults table (bidirectional), and
# that the six value-constrained Codex keys carry the same allowed value SETS as the
# "Допустимые значения Codex-ключей" validation table. Because that defaults table is in
# turn checked equal to the cc-doctor allowlist (Class 4), a schema change not mirrored
# into config.example.md - and thence cc-doctor - fails here. cc-doctor's engine
# (tools/doctor-runtime.ps1) keeps its own hardcoded copy (it must run when mirrored
# standalone into ~/.claude/scripts) yet cannot drift from this schema.

$SchemaFile = Join-Path $PSScriptRoot 'policy-schema.ps1'
if (-not (Test-Path -LiteralPath $SchemaFile)) {
    Write-Error "Required reference file not found: $SchemaFile"
    exit 2
}
try { . $SchemaFile } catch { Write-Error "Could not load the schema source $SchemaFile : $($_.Exception.Message)"; exit 2 }
$schema = $null
try { $schema = Get-OrchestraSchema } catch { Write-Error "Get-OrchestraSchema failed in $SchemaFile : $($_.Exception.Message)"; exit 2 }
if (-not $schema -or -not $schema.config -or $schema.config.Count -eq 0) {
    Write-Error "Schema $SchemaFile has no config keys - format may have changed"
    exit 2
}

$schemaKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($k in $schema.config) { [void]$schemaKeys.Add([string]$k.name) }

foreach ($k in $schemaKeys) {
    if (-not $defaultKeys.Contains($k)) {
        Add-Finding -FileRef 'tools/policy-schema.ps1' -Check 'schema-config' `
            -Detail "'$k' is a schema config key but missing from the defaults table in config.example.md"
    }
}
foreach ($k in $defaultKeys) {
    if (-not $schemaKeys.Contains($k)) {
        Add-Finding -FileRef 'tools/policy-schema.ps1' -Check 'schema-config' `
            -Detail "'$k' is in the config.example.md defaults table but missing from the schema (tools/policy-schema.ps1)"
    }
}

# Codex validation-table enum sets vs the schema's enums (order-insensitive). Enum options
# inside the allowed-values cell are separated by an escaped pipe (' \| '), so split each
# row on UNESCAPED pipes to isolate the columns, then take the backtick tokens.
$valEnum = [ordered]@{}
$inVal = $false
foreach ($line in $configLines) {
    if ($line -match '^###\s+Допустимые значения Codex') { $inVal = $true; continue }
    if ($inVal -and $line -match '^#{1,3}\s') { break }
    if ($inVal -and $line -match '^\|\s*`CODEX_') {
        $cells = [regex]::Split($line, '(?<!\\)\|') | ForEach-Object { $_.Trim() }
        if ($cells.Count -ge 4) {
            $keyM = [regex]::Match($cells[1], '`(CODEX_[A-Z]+)`')
            if ($keyM.Success) {
                $vals = @([regex]::Matches($cells[2], '`([^`]+)`') | ForEach-Object { $_.Groups[1].Value })
                $valEnum[$keyM.Groups[1].Value] = ($vals | Sort-Object)
            }
        }
    }
}
if ($valEnum.Count -eq 0) {
    Write-Error "Could not parse the Codex validation table ('### Допустимые значения Codex...') in $ConfigFile - format may have changed"
    exit 2
}
foreach ($ck in $valEnum.Keys) {
    $desc = $schema.config | Where-Object { $_.name -eq $ck } | Select-Object -First 1
    if (-not $desc) {
        Add-Finding -FileRef 'tools/policy-schema.ps1' -Check 'schema-codex-enum' -Detail "validation-table key '$ck' has no schema descriptor"
        continue
    }
    $schemaVals = @($desc.enum | Sort-Object)
    if (($valEnum[$ck] -join ',') -ne ($schemaVals -join ',')) {
        Add-Finding -FileRef 'tools/policy-schema.ps1' -Check 'schema-codex-enum' `
            -Detail "'$ck' allowed set differs: schema [$($schemaVals -join ' | ')] vs config.example.md validation table [$($valEnum[$ck] -join ' | ')]"
    }
}

# =============================================================================
# Report
# =============================================================================

if ($findings.Count -eq 0) {
    Write-Host "OK - no cross-agent contract inconsistencies found (config keys, processor phases, runtime artifacts, policy schema)."
    exit 0
}

Write-Host "Found $($findings.Count) cross-agent contract inconsistency(ies):`n"
foreach ($f in $findings) {
    Write-Host $f
}
exit 1
