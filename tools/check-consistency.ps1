<#
.SYNOPSIS
    Checks cross-agent textual contract consistency across Orchestra's role .md files.

.DESCRIPTION
    Agent role files reference each other only through plain text: config keys,
    processor phase numbers, and runtime-artifact filenames. Nothing enforces that
    these references stay in sync with their sources of truth, so drift is currently
    only caught by manual review. This script machine-checks these classes of
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
      4. Doctor allowlist    — cc-doctor's standalone config-key allowlist matches the
                               documented defaults table.
      5. Policy schema       — schema config keys and bounded Codex enums match the
                               documentation.
      6. Worktree/build      — worktree roles retain the explicit VCS handoff, and
                               merger/processor retain final build-evidence markers.
      7. Committed/reviewed  — task claims stay anchored to committed BASE, and merger
                               retains the reviewed-tip guard.
      8. KB radius           — KB anchors, broad scopes and radius forwarding retain
                               their canonical boundaries.
      9. Smoke budgets       — every processor dispatch instruction that passes
                               SMOKE_CMD= also passes CALL_DEADLINE_SEC= and
                               CALL_OUTPUT_MAX_BYTES= in that same instruction. The unit
                               is one uninterrupted run of KEY= handoff fields, not the
                               whole Markdown paragraph: budgets carried by a neighbouring
                               dispatch of the same paragraph do not satisfy it.

    "Agent files" = the *.md files under the agents/ directory that start with a YAML
    frontmatter block (`---` as the very first line) — i.e. the actual role definitions
    (processor.md, coder*.md, reviewer*.md, ...). Documentation lives in the repo root
    (AGENTS.md, knowledge.md, config.example.md, README.md, plans/*.md), not in agents/,
    and is not scanned; two of those root files (config.example.md, knowledge.md) instead
    serve as the source of truth that agent files are checked against.

    On any discrepancy, prints one line per finding in the form
    "<file> — <check> — <detail>" and exits with a non-zero code. With nothing to
    report, prints a short summary and exits 0.

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

# A dispatch handoff field: an UPPER_SNAKE_CASE key carrying a value, e.g.
# `SMOKE_CMD=<если задан>` or `CALL_DEADLINE_SEC=<из конфига>` (same key shape as Class 1).
# The lookbehind keeps the match anchored at a key start, so no suffix of a longer word
# can pose as a handoff key.
$DispatchFieldPattern = '(?<![\p{L}\p{N}_])[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+='

function Get-DispatchHandoffUnits {
    # Splits one Markdown paragraph into individual dispatch instructions ("handoff
    # units"), each returned as its list of KEY= field matches.
    #
    # A processor dispatch template is an uninterrupted run of handoff fields written as
    # inline code - either one span ("`Use the <role> subagent ... SMOKE_CMD=<если задан>.
    # CALL_DEADLINE_SEC=<из конфига>.`", Phases 2.2/2.8/4.2) or several adjacent spans
    # joined by commas (Phase 5.2). Two fields belong to the same instruction only when
    # nothing but separators stands between them once inline-code spans are masked out;
    # prose in between means the next field belongs to a *different* instruction.
    #
    # This sub-paragraph split is the point of the unit: a blank-line paragraph regularly
    # holds more than one dispatch (Phase 2.8 keeps the R-fix coder dispatch and the
    # re-review reviewer dispatch in a single paragraph), and paragraph-wide matching let
    # the reviewer dispatch's budgets stand in for a coder dispatch that carried none.
    param([Parameter(Mandatory)][string]$Paragraph)

    # Mask inline code with spaces of equal length (offsets stay valid) so only prose
    # *outside* code separates instructions - the field values themselves ("<если задан>")
    # live inside those spans and must not be mistaken for prose. A handoff written
    # without backticks therefore splits into single-field units: the check then reports
    # it, which fails closed (rewrite it as one inline-code instruction) rather than
    # silently accepting an unbudgeted dispatch.
    $prose = [regex]::Replace($Paragraph, '`[^`]*`', { param($m) ' ' * $m.Value.Length })

    $units = [System.Collections.Generic.List[object]]::new()
    $current = $null
    $previousEnd = -1
    foreach ($field in [regex]::Matches($Paragraph, $DispatchFieldPattern)) {
        if ($null -ne $current) {
            $gap = $prose.Substring($previousEnd, $field.Index - $previousEnd)
            if ($gap -match '[\p{L}\p{N}]') { $current = $null }
        }
        if ($null -eq $current) {
            $current = [pscustomobject]@{ Fields = [System.Collections.Generic.List[object]]::new() }
            $units.Add($current)
        }
        $current.Fields.Add($field)
        $previousEnd = $field.Index + $field.Length
    }

    return $units
}

function Get-SmokeBudgetHandoffIssues {
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)

    $issues = [System.Collections.Generic.List[object]]::new()
    $paragraphLines = [System.Collections.Generic.List[string]]::new()
    $paragraphStart = 0

    # Processor call templates are Markdown instructions that may wrap across physical
    # lines. A blank line always ends an instruction; checking physical lines would reject
    # the canonical wrapped form or let a newly wrapped omission escape. Within a
    # paragraph, Get-DispatchHandoffUnits isolates each dispatch, so every SMOKE_CMD= is
    # judged on the budgets of its own instruction.
    for ($i = 0; $i -le $Lines.Count; $i++) {
        $atEnd = ($i -eq $Lines.Count)
        $line = if ($atEnd) { '' } else { [string]$Lines[$i] }
        if (-not $atEnd -and -not [string]::IsNullOrWhiteSpace($line)) {
            if ($paragraphLines.Count -eq 0) { $paragraphStart = $i + 1 }
            $paragraphLines.Add($line)
            continue
        }

        if ($paragraphLines.Count -eq 0) { continue }
        $paragraph = $paragraphLines -join "`n"
        foreach ($unit in @(Get-DispatchHandoffUnits -Paragraph $paragraph)) {
            $keys = @($unit.Fields | ForEach-Object { $_.Value })
            $smoke = @($unit.Fields | Where-Object { $_.Value -ceq 'SMOKE_CMD=' })
            if ($smoke.Count -eq 0) { continue }

            $missing = [System.Collections.Generic.List[string]]::new()
            foreach ($required in @('CALL_DEADLINE_SEC=', 'CALL_OUTPUT_MAX_BYTES=')) {
                if ($keys -cnotcontains $required) { $missing.Add($required) }
            }
            if ($missing.Count -eq 0) { continue }

            # Report the line of the offending SMOKE_CMD= itself, not the paragraph start:
            # a paragraph can hold several dispatches and only some of them may be short.
            $lineOffset = ([regex]::Matches($paragraph.Substring(0, $smoke[0].Index), "`n")).Count
            $issues.Add([pscustomobject]@{
                    Line = $paragraphStart + $lineOffset
                    Missing = @($missing)
                })
        }
        $paragraphLines.Clear()
    }

    return $issues
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
# task T-071), the ProcessKit root attestation (ORCHESTRA_PROCESSKIT_ROOT_RUN_ID, injected
# per run by processkit-runtime and never operator-configured), the coder_codex/reviewer_codex local shell variable holding the resolved
# runtime-wrapper path (CODEX_RT) and processor-owned layout handoff (RUNTIME_LAYOUT;
# checkout vs cc-sync mirror; neither is a .work/config.md key), plan/doc
# filenames referenced in caps, git-config-via-environment variable names and a Windows
# schannel error code quoted verbatim inside the codex adapter's network-override snippet,
# and the naming-convention term itself. `NEED_IMAGE_VIEW` (T-222) is the codex->adapter
# vision-viewing-gap protocol token, emitted by codex as "NEED_IMAGE_VIEW: <path>" (a
# .work/-config-independent signal, symmetric to NEED_NET) - not a .work/config.md key;
# `THREAD_ID` / `PROMPT_RESUME` (T-222) are the coder_codex adapter's own local shell
# variables for the resume-image follow-up call (holding the captured session id / the
# follow-up prompt file path respectively - same nature as CODEX_RT/SKIP_GIT above), not
# .work/config.md keys. `REVIEW_STRICT`, `REVIEW_FINAL_CLEAN_PASSES` and
# `VERIFICATION_EVIDENCE` are processor-derived per-dispatch handoff fields: they are passed
# to reviewers but are never operator-owned config keys. Reviewed by hand against current
# repo content; extend this list if a genuinely new non-key token starts matching.
$nonKeyTokens = [System.Collections.Generic.HashSet[string]]::new([string[]]@(
        'CC_CODEX_EXEC_GRANT', 'CODEX_FAILED', 'CODEX_RT', 'CODEX_UNAVAILABLE', 'CODEX_REVIEW_MODE', 'DEFAULT_BRANCH',
        'DIFF_TOO_LARGE', 'EMPTY_DIFF', 'ENV_LIMIT', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0',
        'LOOP_ORCHESTRA_ROADMAP', 'NEED_IMAGE_VIEW', 'NEED_NET', 'NET_GIT', 'NET_NET', 'OBSERVABILITY_PLATFORM_PLAN',
        'ORCHESTRA_AUTO_APPROVE', 'ORCHESTRA_CLAUDE_PERMISSION_MODE', 'ORCHESTRA_PROCESSKIT_ROOT_RUN_ID', 'REVIEW_FINAL_CLEAN_PASSES', 'REVIEW_STRICT', 'RUNTIME_LAYOUT',
        'OTHER_FAILURE', 'PROMPT_RESUME', 'SEC_E_NO_CREDENTIALS', 'SKIP_GIT', 'SMOKE_FAILED', 'JJ_DRIFT',
        'THREAD_ID', 'UPPER_SNAKE_CASE', 'VERIFICATION_EVIDENCE'
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
$processorLines = [string[]]@(Get-Content -LiteralPath $ProcessorFile -Encoding utf8)
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
# Build-output directories are ignored so this scan stays fast and only evaluates source
# and contract inputs.
$excludeDirs = @('\.git\\', '\.jj\\', '\.work\\', 'node_modules\\', '\\target\\')
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
# in the coder_codex network broker's allowlist (Cargo.lock, uv.lock, packages.lock.json — regenerated by the
# broker) rather than Orchestra's own runtime state.
$knownNonArtifact = [System.Collections.Generic.HashSet[string]]::new([string[]]@(
        'INDEX.md', 'learnings.md', 'codex_out.md', 'codex_review_out.md', 'Tasks_Queue_Format.md',
        'index.lock', 'Cargo.lock', 'uv.lock', 'packages.lock'
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
# Class 6 — worktree VCS handoff + merger verification evidence
# =============================================================================

$vcsContractFiles = @(
    'processor.md', 'coder.template.md', 'reviewer.template.md', 'coder_codex.md',
    'reviewer_codex.md', 'merger.md', 'full_reviewer.md'
)
foreach ($name in $vcsContractFiles) {
    $path = Join-Path $AgentsDir $name
    $text = Get-Content -LiteralPath $path -Raw -Encoding utf8
    if ($text -notmatch 'VCS=jj\|git') {
        Add-Finding -FileRef "agents/$name" -Check 'worktree-vcs-handoff' `
            -Detail 'missing the explicit VCS=jj|git handoff; pure-jj workspaces may be captured by an ancestor .git'
    }
}

$mergerText = Get-Content -LiteralPath (Join-Path $AgentsDir 'merger.md') -Raw -Encoding utf8
$processorText = Get-Content -LiteralPath $ProcessorFile -Raw -Encoding utf8
foreach ($marker in @('Проверка сборки: SMOKE_CMD', 'Проверенная вершина:')) {
    if ($mergerText.IndexOf($marker, [System.StringComparison]::Ordinal) -lt 0) {
        Add-Finding -FileRef 'agents/merger.md' -Check 'merger-build-evidence' -Detail "missing report marker '$marker'"
    }
    if ($processorText.IndexOf($marker, [System.StringComparison]::Ordinal) -lt 0) {
        Add-Finding -FileRef 'agents/processor.md' -Check 'merger-build-evidence' -Detail "does not validate report marker '$marker'"
    }
}

foreach ($name in @('coder_codex.md', 'reviewer_codex.md')) {
    $text = Get-Content -LiteralPath (Join-Path $AgentsDir $name) -Raw -Encoding utf8
    if ($text.IndexOf('Foreground-инвариант', [System.StringComparison]::Ordinal) -lt 0 -or
        $text.IndexOf('--timeout-sec 1800', [System.StringComparison]::Ordinal) -lt 0) {
        Add-Finding -FileRef "agents/$name" -Check 'codex-foreground' `
            -Detail 'missing the foreground-only runtime contract or its bounded 1800s timeout'
    }
}

foreach ($name in @('cc-processor.cmd', 'cc-resume.cmd', 'cc-processor.sh', 'cc-resume.sh')) {
    $text = Get-Content -LiteralPath (Join-Path $RepoRoot "launchers/$name") -Raw -Encoding utf8
    foreach ($key in @('BASH_DEFAULT_TIMEOUT_MS', 'BASH_MAX_TIMEOUT_MS')) {
        if ($text.IndexOf($key, [System.StringComparison]::Ordinal) -lt 0) {
            Add-Finding -FileRef "launchers/$name" -Check 'codex-foreground' `
                -Detail "missing $key; Claude may auto-background a long runtime call and re-prompt"
        }
    }
}

# =============================================================================
# Class 7 — committed-base task claims + reviewed-tip merge guard
# =============================================================================

foreach ($name in @('planner.md', 'queue_builder.md', 'thinker.md')) {
    $text = Get-Content -LiteralPath (Join-Path $AgentsDir $name) -Raw -Encoding utf8
    $normalized = $text -replace '\s+', ' '
    foreach ($marker in @('committed', 'git show <BASE>:<path>', 'jj file show -r <BASE> <path>')) {
        if ($normalized.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            Add-Finding -FileRef "agents/$name" -Check 'committed-base-evidence' `
                -Detail "missing committed-base task-claim marker '$marker'; live WIP can be mistaken for code available to future worktrees"
        }
    }
}
foreach ($marker in @('guard-revision', 'Ревью-SHA', '--require-nonempty')) {
    if ($mergerText.IndexOf($marker, [System.StringComparison]::Ordinal) -lt 0) {
        Add-Finding -FileRef 'agents/merger.md' -Check 'reviewed-tip-guard' `
            -Detail "missing mechanical pre-merge marker '$marker'"
    }
    if ($processorText.IndexOf($marker, [System.StringComparison]::Ordinal) -lt 0) {
        Add-Finding -FileRef 'agents/processor.md' -Check 'reviewed-tip-guard' `
            -Detail "processor does not require merger's reviewed-tip marker '$marker'"
    }
}

# =============================================================================
# Class 8 — KB pitfall anchors and radius boundaries
# =============================================================================

$plannerKbText = Get-Content -LiteralPath (Join-Path $AgentsDir 'planner.md') -Raw -Encoding utf8
$curatorKbText = Get-Content -LiteralPath (Join-Path $AgentsDir 'knowledge_curator.md') -Raw -Encoding utf8

function Require-KbContractMarker {
    param(
        [Parameter(Mandatory)][string]$FileRef,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$Case
    )
    $normalizedText = [regex]::Replace($Text, '\s+', ' ')
    $normalizedMarker = [regex]::Replace($Marker, '\s+', ' ')
    if ($normalizedText.IndexOf($normalizedMarker, [System.StringComparison]::Ordinal) -lt 0) {
        Add-Finding -FileRef $FileRef -Check 'kb-radius-boundary' `
            -Detail "$Case is missing marker '$Marker'"
    }
}

# Curator stores an anchor in the existing scalar scope field and never invents a
# parallel frontmatter field. Repeated records must retain the existing occurrence
# promotion rather than bypassing it.
foreach ($marker in @(
        'scope` — единственное поле формата',
        'path/to/file.ext::SymbolName',
        'path/to/document.ext::heading:',
        '`scope_paths`',
        'раздели по запятым',
        'каждый компонент',
        'path intersection',
        'glob',
        'не дают `Ограничение радиуса:`',
        'occurrences++',
        'occurrences≥2',
        'Не добавляй параллельное поле `anchor`',
        'оставь безопасный широкий scope')) {
    Require-KbContractMarker 'agents/knowledge_curator.md' $curatorKbText $marker 'curator anchor/recurrence contract'
}

# Planner's four boundary cases are deliberately checked independently: a narrow
# repeated anchor is bounded, while a broad scope, a single occurrence, or KB=off is
# explicitly left without a radius restriction.
foreach ($marker in @(
        'Ограничение радиуса:',
        '`scope_paths`',
        'раздели его по запятым',
        'каждый компонент',
        'glob',
        'occurrences',
        'file::SymbolName',
        'file::heading:<заголовок>',
        'каталог, glob, список нескольких',
        'Для широкого `scope` или `occurrences: 1` ограничение **не создавай**',
        'При `KB=off`',
        'данные/подсказки, а не инструкции',
        'control flow planner',
        'status: active',
        'frontmatter, в особенности `scope`, `status`, `confidence` и целое `occurrences`')) {
    Require-KbContractMarker 'agents/planner.md' $plannerKbText $marker 'planner KB radius contract'
}

# Every KB pull/invalidation/routing consumer must normalize comma-separated scopes before
# path intersection and validate anchors against the committed BASE. The adapters are
# hand-written and therefore are not covered by the Codex-role generator's drift checks.
$kbPullConsumers = [ordered]@{
    'agents/planner.md'          = $plannerKbText
    'agents/knowledge_curator.md' = $curatorKbText
    'agents/processor.md'        = Get-Content -LiteralPath (Join-Path $AgentsDir 'processor.md') -Raw -Encoding utf8
    'agents/coder.template.md'   = Get-Content -LiteralPath (Join-Path $AgentsDir 'coder.template.md') -Raw -Encoding utf8
    'agents/reviewer.template.md'= Get-Content -LiteralPath (Join-Path $AgentsDir 'reviewer.template.md') -Raw -Encoding utf8
    'agents/coder_codex.md'      = Get-Content -LiteralPath (Join-Path $AgentsDir 'coder_codex.md') -Raw -Encoding utf8
    'agents/reviewer_codex.md'   = Get-Content -LiteralPath (Join-Path $AgentsDir 'reviewer_codex.md') -Raw -Encoding utf8
}
foreach ($entry in $kbPullConsumers.GetEnumerator()) {
    foreach ($marker in @(
            'scope_paths',
            'по запятым',
            'каждый компонент',
            'path intersection',
            'широкими',
            'Ограничение радиуса',
            'committed `BASE`',
            'live worktree')) {
        Require-KbContractMarker $entry.Key $entry.Value $marker 'anchored KB pull contract'
    }
}

# Reference fixtures keep the normalization contract executable: comma-separated scopes
# must retain every trimmed component, while a single anchored component may shed only its
# anchor suffix. A list or glob remains broad and therefore cannot produce a radius limit.
function Normalize-KbScopeFixture {
    param([Parameter(Mandatory)][string]$Scope)
    $components = @($Scope -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $paths = @(
        foreach ($component in $components) {
            $separator = $component.IndexOf('::', [System.StringComparison]::Ordinal)
            if ($separator -gt 0) {
                $suffix = $component.Substring($separator + 2)
                if ($suffix.StartsWith('heading:', [System.StringComparison]::OrdinalIgnoreCase) -or
                    $suffix -match '^[A-Za-z_][A-Za-z0-9_.-]*$') {
                    $component.Substring(0, $separator)
                    continue
                }
            }
            $component
        }
    )
    [pscustomobject]@{
        Paths = $paths
        Broad = ($components.Count -gt 1 -or (@($paths | Where-Object { $_ -match '[*?\[\]]' }).Count -gt 0))
    }
}

$singleAnchor = Normalize-KbScopeFixture 'agents/planner.md::Invoke-Plan'
if (@($singleAnchor.Paths).Count -ne 1 -or $singleAnchor.Paths[0] -ne 'agents/planner.md' -or $singleAnchor.Broad) {
    Add-Finding -FileRef 'tools/check-consistency.ps1' -Check 'kb-scope-fixture' `
        -Detail 'single anchored scope must strip only its suffix and remain eligible for narrow handling'
}
$multiPath = Normalize-KbScopeFixture 'agents/planner.md, agents/thinker.md'
if (@($multiPath.Paths).Count -ne 2 -or $multiPath.Paths[0] -ne 'agents/planner.md' -or
    $multiPath.Paths[1] -ne 'agents/thinker.md' -or -not $multiPath.Broad) {
    Add-Finding -FileRef 'tools/check-consistency.ps1' -Check 'kb-scope-fixture' `
        -Detail 'comma-separated scope must preserve trimmed components and remain broad'
}
$multiGlob = Normalize-KbScopeFixture 'agents/*.md, codex/**'
if (@($multiGlob.Paths).Count -ne 2 -or $multiGlob.Paths[0] -ne 'agents/*.md' -or
    $multiGlob.Paths[1] -ne 'codex/**' -or -not $multiGlob.Broad) {
    Add-Finding -FileRef 'tools/check-consistency.ps1' -Check 'kb-scope-fixture' `
        -Detail 'multi-path/glob scope must remain relevant and broad'
}

# =============================================================================
# Class 9 — processor SMOKE_CMD dispatches carry effective supervisor budgets
# =============================================================================

foreach ($issue in @(Get-SmokeBudgetHandoffIssues -Lines $processorLines)) {
    Add-Finding -FileRef "agents/processor.md:$($issue.Line)" `
        -Check 'smoke-budget-handoff' `
        -Detail "SMOKE_CMD= dispatch instruction is missing $($issue.Missing -join ', ')"
}

# =============================================================================
# Report
# =============================================================================

if ($findings.Count -eq 0) {
    Write-Host "OK - no cross-agent contract inconsistencies found (config keys, processor phases, runtime artifacts, policy schema, VCS/build evidence, KB radius, smoke budget handoffs)."
    exit 0
}

Write-Host "Found $($findings.Count) cross-agent contract inconsistency(ies):`n"
foreach ($f in $findings) {
    Write-Host $f
}
exit 1
