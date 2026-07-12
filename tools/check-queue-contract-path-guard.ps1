<#
.SYNOPSIS
    Guards the "queue-contract path-resolution" contract across every agent prompt
    that references the queue contracts (task T-122).

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

    For each agents/*.md that mentions `queue_contract.md` or `Tasks_Queue_Format.md`, and
    for the two normative docs (knowledge.md, docs/queue_contract.md), it requires all of:

      - `$ROOT/docs/queue_contract.md`            (exact queue-contract path -> resolving)
      - `$HOME/.claude/specs/Tasks_Queue_Format.md` (exact spec path        -> resolving)
      - `find /`                                  (the base ban)
      - `find C:/`                                (the Windows drive-root ban)
      - `find / -maxdepth`                        (the extended ban: `-maxdepth N` from `/`
                                                   is explicitly insufficient - T-122 crux)

    Files that mention neither contract path (e.g. executor.md, full_reviewer.md) are out
    of scope and skipped. If NO agents file is in scope at all, the citation strings the
    guard keys on must have changed, so the guard can no longer be trusted -> exit 2.

    On any violation prints one line per finding as "<file> - <check> - <detail>" and exits
    1. A structural problem (a required file or the agents dir is missing, or nothing is in
    scope) exits 2 so it is never mistaken for "contract satisfied". Nothing to report -> a
    short summary and exit 0. Runs identically under pwsh on Windows and Linux.

.EXAMPLE
    pwsh -File tools/check-queue-contract-path-guard.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$AgentsDir = Join-Path $RepoRoot 'agents'
$KnowledgeFile = Join-Path $RepoRoot 'knowledge.md'
$QueueContractFile = Join-Path $RepoRoot 'docs/queue_contract.md'

function Fail-Structural {
    param([string]$Message)
    Write-Error $Message
    exit 2
}

if (-not (Test-Path -LiteralPath $AgentsDir -PathType Container)) {
    Fail-Structural "Required directory not found: $AgentsDir"
}
foreach ($doc in @($KnowledgeFile, $QueueContractFile)) {
    if (-not (Test-Path -LiteralPath $doc)) {
        Fail-Structural "Required normative doc not found: $doc"
    }
}

# A file is IN SCOPE if it cites either queue contract by name.
$MentionTokens = @('queue_contract.md', 'Tasks_Queue_Format.md')

# The canonical guard, as a set of distinctive whitespace-insensitive substrings. Every
# in-scope file must carry ALL of them: two exact paths (resolving) + the full `find /`
# ban including the `-maxdepth` extension that T-122 exists for. Kept token-based (not a
# full-sentence match) so prose may be reworded while the substance stays enforced.
$RequiredTokens = [ordered]@{
    'resolve-queue-path' = '$ROOT/docs/queue_contract.md'
    'resolve-spec-path'  = '$HOME/.claude/specs/Tasks_Queue_Format.md'
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
        [Parameter(Mandatory)][string]$NormalizedText
    )
    foreach ($check in $RequiredTokens.Keys) {
        if (-not $NormalizedText.Contains($RequiredTokens[$check])) {
            Add-Finding -FileRef $FileRef -Check $check `
                -Detail "missing the canonical guard token '$($RequiredTokens[$check])' (a file that cites docs/queue_contract.md / Tasks_Queue_Format.md must carry the resolution+ban guard, incl. the 'find / -maxdepth N' extension - T-122)"
        }
    }
}

# --- Agent prompts (incl. both *.template.md and the generated variants) -------------
$agentFiles = Get-ChildItem -LiteralPath $AgentsDir -Filter '*.md' -File | Sort-Object Name
if ($agentFiles.Count -eq 0) {
    Fail-Structural "No agents/*.md files found under $AgentsDir - the layout may have changed."
}

$inScope = 0
foreach ($file in $agentFiles) {
    $norm = Get-Normalized -Path $file.FullName
    $mentions = $false
    foreach ($m in $MentionTokens) { if ($norm.Contains($m)) { $mentions = $true; break } }
    if (-not $mentions) { continue }   # out of scope: cites neither contract
    $inScope++
    Test-GuardTokens -FileRef "agents/$($file.Name)" -NormalizedText $norm
}

if ($inScope -eq 0) {
    # Nothing cites the contracts -> the mention tokens this guard keys on must have
    # changed, so it can no longer verify anything. Never pass that quietly.
    Fail-Structural "No agents/*.md references '$($MentionTokens -join "' or '")' - the citation format may have changed and this guard can no longer be trusted."
}

# --- Normative docs: the canonical resolution+ban must not regress there either -----
Test-GuardTokens -FileRef 'knowledge.md' -NormalizedText (Get-Normalized -Path $KnowledgeFile)
Test-GuardTokens -FileRef 'docs/queue_contract.md' -NormalizedText (Get-Normalized -Path $QueueContractFile)

# --- Report -------------------------------------------------------------------------
if ($findings.Count -eq 0) {
    Write-Host "OK - queue-contract path guard holds: all $inScope agent prompt(s) citing docs/queue_contract.md / Tasks_Queue_Format.md carry the resolution+ban guard (incl. the 'find / -maxdepth N' extension), and both normative docs (knowledge.md, docs/queue_contract.md) agree."
    exit 0
}

Write-Host "Found $($findings.Count) queue-contract path guard violation(s):`n"
foreach ($f in $findings) {
    Write-Host $f
}
exit 1
