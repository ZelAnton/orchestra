<#
.SYNOPSIS
    Guards the queue/roadmap contract path-resolution rules across every agent prompt
    that references either contract family (tasks T-122, T-269).

.DESCRIPTION
    Bare references to `docs/queue_contract.md` / `Tasks_Queue_Format.md` in an agent
    prompt are NOT an instruction to search the disk for the file. Task T-118 tried to
    enforce this by hand-classifying the 71 references in agents/*.md into "reads" (which
    got a cheap path-resolution hint + an explicit `find /` ban) and "pure citations"
    (left untouched, on the assumption that a cited path is never literally opened). That
    assumption did not hold: after T-118 shipped, a live agent of one of the UNPATCHED
    roles (the coder/reviewer families carry the bare `docs/queue_contract.md, §18`
    trust/redaction citation and are the most-invoked roles) still opened the file
    literally and, lacking a cheap way to get the absolute path, improvised

        find / -maxdepth 6 -iname "queue_contract.md" 2>/dev/null

    which on this Windows (Git Bash/MSYS) host still walks the whole system drive within
    6 levels (Program Files / Windows / Users, many sub-dirs at shallow depth) and can
    hang the role - a `-maxdepth N` from `/` is NOT a sufficient mitigation on its own.

    T-122 replaces the manual read-vs-citation split with a mechanical rule: EVERY
    `agents/*.md` (and both `*.template.md`, from which generate-coders.ps1 produces the
    coder*/reviewer* variants) that mentions either contract path must carry the canonical
    resolution+ban guard, so no future citation can silently regress into a `find /`. This
    script is that guard's enforcer, in the same static style as
    tools/check-codex-runtime-path-guard.ps1 (T-119): it is deliberately token-based (a
    small set of distinctive whitespace-insensitive substrings) rather than a full-sentence
    match, so surrounding prose may be reworded freely while the substance stays enforced.

    For each agents/*.md that mentions `queue_contract.md` or `Tasks_Queue_Format.md`, it
    requires both exact queue paths. For each agents/*.md that mentions
    `roadmap_contract.md` or `.work/roadmap.md`, it requires both exact roadmap paths. Every
    in-scope prompt must also carry the common anti-disk-walk block.

    Queue paths:

      - `$ROOT/docs/queue_contract.md`            (exact queue-contract path -> resolving)
      - `$HOME/.claude/specs/Tasks_Queue_Format.md` (exact spec path        -> resolving)

    Roadmap paths:

      - `$ROOT/docs/roadmap_contract.md`          (exact roadmap-contract path -> resolving)
      - `$ROOT/.work/roadmap.md`                  (exact project artifact path -> resolving)

    Common anti-disk-walk block:

      - `find /`                                  (the base ban)
      - `find C:/`                                (the Windows drive-root ban)
      - `find / -maxdepth`                        (the extended ban: `-maxdepth N` from `/`
                                                   is explicitly insufficient - T-122 crux)

    Files that mention neither contract family (e.g. executor.md, full_reviewer.md) are out
    of scope and skipped. If no agents file is in scope for one of the two contract families,
    the citation strings that family keys on must have changed -> exit 2.

    On any violation prints one line per finding as "<file> - <check> - <detail>" and exits
    1. A structural problem (a required file or the agents dir is missing, or nothing is in
    scope) exits 2 so it is never mistaken for "contract satisfied". Nothing to report -> a
    short summary and exit 0. Runs identically under pwsh on Windows and Linux.

.EXAMPLE
    pwsh -File tools/check-queue-contract-path-guard.ps1
#>

[CmdletBinding()]
param(
    # Test seam for hermetic fixture tests. Production callers omit it and validate the
    # checkout containing this script.
    [string]$RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    Split-Path -Parent $PSScriptRoot
} else {
    [System.IO.Path]::GetFullPath($RepositoryRoot)
}
$AgentsDir = Join-Path $RepoRoot 'agents'
$KnowledgeFile = Join-Path $RepoRoot 'knowledge.md'
$QueueContractFile = Join-Path $RepoRoot 'docs/queue_contract.md'
$RoadmapContractFile = Join-Path $RepoRoot 'docs/roadmap_contract.md'

function Fail-Structural {
    param([string]$Message)
    Write-Error $Message
    exit 2
}

if (-not (Test-Path -LiteralPath $AgentsDir -PathType Container)) {
    Fail-Structural "Required directory not found: $AgentsDir"
}
foreach ($doc in @($KnowledgeFile, $QueueContractFile, $RoadmapContractFile)) {
    if (-not (Test-Path -LiteralPath $doc)) {
        Fail-Structural "Required normative doc not found: $doc"
    }
}

# A file is in scope for a contract family if it cites either of that family's names.
$QueueMentionTokens = @('queue_contract.md', 'Tasks_Queue_Format.md')
$RoadmapMentionTokens = @('roadmap_contract.md', '.work/roadmap.md')

# The canonical guard, as a set of distinctive whitespace-insensitive substrings. Every
# in-scope file must carry ALL of them: two exact paths (resolving) + the full `find /`
# ban including the `-maxdepth` extension that T-122 exists for. Kept token-based (not a
# full-sentence match) so prose may be reworded while the substance stays enforced.
$QueueRequiredTokens = [ordered]@{
    'resolve-queue-path' = '$ROOT/docs/queue_contract.md'
    'resolve-spec-path'  = '$HOME/.claude/specs/Tasks_Queue_Format.md'
}
$RoadmapRequiredTokens = [ordered]@{
    'resolve-roadmap-contract-path' = '$ROOT/docs/roadmap_contract.md'
    'resolve-roadmap-artifact-path' = '$ROOT/.work/roadmap.md'
}
$SharedRequiredTokens = [ordered]@{
    'ban-find-root'      = 'find /'
    'ban-find-drive'     = 'find C:/'
    'ban-find-maxdepth'  = 'find / -maxdepth'
}

# Normalize runs of whitespace to a single space so line-wrapping differences between
# files never hide a token that is otherwise present verbatim.
function Get-Normalized {
    param([Parameter(Mandatory)][string]$Path)
    $raw = (Get-Content -LiteralPath $Path -Encoding utf8) -join "`n"
    return ($raw -replace '\s+', ' ')
}

$findings = [System.Collections.Generic.List[string]]::new()
function Add-Finding {
    param(
        [Parameter(Mandatory)][string]$FileRef,
        [Parameter(Mandatory)][string]$Check,
        [Parameter(Mandatory)][string]$Detail
    )
    $findings.Add("$FileRef - $Check - $Detail")
}

function Test-GuardTokens {
    param(
        [Parameter(Mandatory)][string]$FileRef,
        [Parameter(Mandatory)][string]$NormalizedText,
        [Parameter(Mandatory)][System.Collections.IDictionary]$RequiredTokens,
        [Parameter(Mandatory)][string]$ContractLabel
    )
    foreach ($check in $RequiredTokens.Keys) {
        if (-not $NormalizedText.Contains($RequiredTokens[$check])) {
            Add-Finding -FileRef $FileRef -Check $check `
                -Detail "missing the canonical guard token '$($RequiredTokens[$check])' (a file that cites the $ContractLabel contract must carry its exact resolution paths and the anti-disk-walk guard)"
        }
    }
}

function Test-MentionsAny {
    param(
        [Parameter(Mandatory)][string]$NormalizedText,
        [Parameter(Mandatory)][string[]]$Tokens
    )
    foreach ($token in $Tokens) {
        if ($NormalizedText.Contains($token)) { return $true }
    }
    return $false
}

# --- Agent prompts (incl. both *.template.md and the generated variants) -------------
$agentFiles = @(Get-ChildItem -LiteralPath $AgentsDir -Filter '*.md' -File | Sort-Object Name)
if ($agentFiles.Count -eq 0) {
    Fail-Structural "No agents/*.md files found under $AgentsDir - the layout may have changed."
}

$queueInScope = 0
$roadmapInScope = 0
foreach ($file in $agentFiles) {
    $norm = Get-Normalized -Path $file.FullName
    $mentionsQueue = Test-MentionsAny -NormalizedText $norm -Tokens $QueueMentionTokens
    $mentionsRoadmap = Test-MentionsAny -NormalizedText $norm -Tokens $RoadmapMentionTokens
    if (-not $mentionsQueue -and -not $mentionsRoadmap) { continue }

    $fileRef = "agents/$($file.Name)"
    if ($mentionsQueue) {
        $queueInScope++
        Test-GuardTokens -FileRef $fileRef -NormalizedText $norm `
            -RequiredTokens $QueueRequiredTokens -ContractLabel 'queue'
    }
    if ($mentionsRoadmap) {
        $roadmapInScope++
        Test-GuardTokens -FileRef $fileRef -NormalizedText $norm `
            -RequiredTokens $RoadmapRequiredTokens -ContractLabel 'roadmap'
    }
    Test-GuardTokens -FileRef $fileRef -NormalizedText $norm `
        -RequiredTokens $SharedRequiredTokens -ContractLabel 'queue/roadmap'
}

if ($queueInScope -eq 0) {
    Fail-Structural "No agents/*.md references '$($QueueMentionTokens -join "' or '")' - the queue citation format may have changed and this guard can no longer be trusted."
}
if ($roadmapInScope -eq 0) {
    Fail-Structural "No agents/*.md references '$($RoadmapMentionTokens -join "' or '")' - the roadmap citation format may have changed and this guard can no longer be trusted."
}

# --- Normative docs: exact paths and anti-disk-walk rules must not regress ----------
$knowledgeNorm = Get-Normalized -Path $KnowledgeFile
Test-GuardTokens -FileRef 'knowledge.md' -NormalizedText $knowledgeNorm `
    -RequiredTokens $QueueRequiredTokens -ContractLabel 'queue'
Test-GuardTokens -FileRef 'knowledge.md' -NormalizedText $knowledgeNorm `
    -RequiredTokens $RoadmapRequiredTokens -ContractLabel 'roadmap'
Test-GuardTokens -FileRef 'knowledge.md' -NormalizedText $knowledgeNorm `
    -RequiredTokens $SharedRequiredTokens -ContractLabel 'queue/roadmap'

$queueContractNorm = Get-Normalized -Path $QueueContractFile
Test-GuardTokens -FileRef 'docs/queue_contract.md' -NormalizedText $queueContractNorm `
    -RequiredTokens $QueueRequiredTokens -ContractLabel 'queue'
Test-GuardTokens -FileRef 'docs/queue_contract.md' -NormalizedText $queueContractNorm `
    -RequiredTokens $SharedRequiredTokens -ContractLabel 'queue'

$roadmapContractNorm = Get-Normalized -Path $RoadmapContractFile
Test-GuardTokens -FileRef 'docs/roadmap_contract.md' -NormalizedText $roadmapContractNorm `
    -RequiredTokens $RoadmapRequiredTokens -ContractLabel 'roadmap'
Test-GuardTokens -FileRef 'docs/roadmap_contract.md' -NormalizedText $roadmapContractNorm `
    -RequiredTokens $SharedRequiredTokens -ContractLabel 'roadmap'

# --- Report -------------------------------------------------------------------------
if ($findings.Count -eq 0) {
    Write-Host "OK - queue/roadmap path guard holds: $queueInScope queue-citing and $roadmapInScope roadmap-citing agent prompt(s) carry exact resolution paths plus the anti-disk-walk guard; knowledge.md and both normative contracts agree."
    exit 0
}

Write-Host "Found $($findings.Count) queue-contract path guard violation(s):`n"
foreach ($f in $findings) {
    Write-Host $f
}
exit 1
