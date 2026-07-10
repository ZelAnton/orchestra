<#
  Cross-platform sync engine for launchers/cc-sync.cmd and launchers/cc-sync.sh
  (task T-090). Both launchers are thin wrappers that resolve pwsh (PowerShell 7,
  which runs identically on Windows and POSIX) and delegate here, so the mirroring,
  regeneration and validation logic lives in ONE place with ONE behaviour instead
  of a Windows .cmd program and a separate, hand-kept-in-sync POSIX shell program.

  What it does, from a repository checkout:
    1. Regenerates the template-driven coder/reviewer variants (generate-coders.ps1),
       unless -SkipRegen. A regeneration failure aborts before any mirroring.
    2. Validates agent .md invariants (validate-agents.ps1), unless -SkipValidate.
       A violation is reported but is non-fatal (matches the pre-T-090 behaviour).
    3. Mirrors its OWN managed files into the Claude environment
       ($DestinationRoot, default ~/.claude) TRANSACTIONALLY:
         - agents/*.md  (minus the two generator templates) -> <dest>/agents
         - launchers    (*.cmd on Windows, *.sh on POSIX)    -> <dest>/scripts
         - config.example.md, constraints.example.md         -> <dest>/scripts
       Publication goes through a staging area and a persisted journal, so an
       error mid-publish (or a hard crash, recovered on the next run) is rolled
       back to the exact prior state - never a partially applied mirror.
    4. Keeps a manifest of the files it manages (<dest>/.orchestra-sync-manifest.json).
       On a later sync, an entry that this tool previously wrote but no longer
       sources (a renamed/deleted agent or launcher) is removed - but ONLY files
       recorded in that manifest. Anything the tool never wrote is never touched.

  Exit codes (forwarded verbatim by both launchers so Windows and POSIX agree):
    0  success, or nothing to do (run from a mirror rather than a checkout)
    1  a mirror/publish failure (rolled back), or a regeneration failure
    2  a usage/environment error (bad -RepoRoot, etc.)

  Intentionally ASCII-only output and source: this file is invoked via pwsh first
  and Windows PowerShell 5.1 only as a fallback, and an ASCII source is read the
  same by both regardless of the BOM/codepage hazard that bites non-ASCII .ps1s.
#>

[CmdletBinding()]
param(
    # Repository checkout root. Defaults to the parent of tools/ (where this script
    # lives). Overridable so the fixture tests can drive a synthetic tree.
    [string]$RepoRoot,

    # Target Claude environment root. Defaults to ~/.claude. Overridable so tests
    # never touch the real mirror.
    [string]$DestinationRoot,

    # Glob for the launchers to mirror. Defaults to *.cmd on Windows / *.sh on POSIX;
    # tests pass an explicit value to exercise the transaction OS-independently.
    [string]$LauncherGlob,

    [switch]$SkipRegen,
    [switch]$SkipValidate,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

# --- OS detection that is correct on both Windows PowerShell 5.1 and pwsh 7 -------
# $IsWindows does not exist under 5.1, and referencing it there is unsafe; the
# RuntimeInformation probe works on every supported host.
$script:OnWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows)

function Write-SyncInfo { param([string]$Message) if (-not $Quiet) { Write-Host $Message } }
function Write-SyncWarn { param([string]$Message) Write-Host $Message }

function Stop-Sync {
    param([int]$Code, [string]$Message)
    [Console]::Error.WriteLine("cc-sync: $Message")
    exit $Code
}

# =============================================================================
# Path / manifest helpers
# =============================================================================

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-RelativeDest {
    # Manifest entries are stored relative to $DestinationRoot with forward slashes,
    # so the same manifest is portable between a Windows and a POSIX mirror.
    param([string]$FullPath, [string]$Root)
    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $full = [System.IO.Path]::GetFullPath($FullPath)
    $rel = $full.Substring($rootFull.Length).TrimStart('\', '/')
    return ($rel -replace '\\', '/')
}

function Resolve-DestFromRelative {
    param([string]$Relative, [string]$Root)
    $native = $Relative -replace '/', [System.IO.Path]::DirectorySeparatorChar
    return (Join-Path $Root $native)
}

function Read-Manifest {
    param([string]$ManifestPath, [string]$Root)
    # Returns the set of absolute destination paths previously managed by this tool.
    # A missing or unparsable manifest yields an EMPTY set: on a first run (or after
    # a corrupted manifest) nothing is ever purged - deletions only ever target
    # files this tool provably wrote before.
    $result = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { return $result }
    try {
        $raw = [System.IO.File]::ReadAllText($ManifestPath)
        $obj = $raw | ConvertFrom-Json
        if ($obj -and $obj.managed) {
            foreach ($rel in $obj.managed) {
                [void]$result.Add([System.IO.Path]::GetFullPath((Resolve-DestFromRelative $rel $Root)))
            }
        }
    } catch {
        Write-SyncWarn "cc-sync: warning - could not read the existing sync manifest ($ManifestPath); treating it as empty (no stale entries will be purged this run)."
    }
    return $result
}

function Write-Manifest {
    param([string]$ManifestPath, [string]$Root, [string[]]$AbsoluteDests)
    $rel = @($AbsoluteDests | ForEach-Object { Get-RelativeDest -FullPath $_ -Root $Root } | Sort-Object -Unique)
    $obj = [ordered]@{
        version         = 1
        tool            = 'tools/sync-runtime.ps1'
        generatedAtUtc  = [DateTime]::UtcNow.ToString('o')
        managed         = $rel
    }
    $json = $obj | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($ManifestPath, $json, $script:Utf8NoBom)
}

# =============================================================================
# Transaction: staged, journaled publish with rollback + crash recovery
# =============================================================================
#
# Every destructive step (overwrite / create / delete) appends one line to a
# journal BEFORE it happens, recording how to undo it. If any step throws, the
# in-memory op list is replayed in reverse to restore the exact prior state, and
# the new manifest is NOT written. A journal left behind by a hard crash is
# replayed the same way on the next run (Invoke-JournalRecovery), so an
# interruption mid-publish never leaves a half-applied mirror.

function New-TxContext {
    param([string]$Root)
    $txDir = Join-Path $Root '.orchestra-sync-tx'
    return [ordered]@{
        Dir      = $txDir
        Stage    = Join-Path $txDir 'stage'
        Backup   = Join-Path $txDir 'backup'
        Journal  = Join-Path $txDir 'journal.jsonl'
        Applied  = [System.Collections.Generic.List[object]]::new()
        Counter  = 0
    }
}

function Write-JournalEntry {
    param($Tx, [hashtable]$Entry)
    $line = ($Entry | ConvertTo-Json -Compress -Depth 4)
    Add-Content -LiteralPath $Tx.Journal -Value $line -Encoding utf8
    $Tx.Applied.Add($Entry)
}

function Invoke-Undo {
    # Reverses a single recorded op. 'restore' copies the backup back over dest;
    # 'remove' deletes a file this run had created.
    param([hashtable]$Entry)
    $dest = [string]$Entry.dest
    switch ([string]$Entry.undo) {
        'restore' {
            $backup = [string]$Entry.backup
            if ($backup -and (Test-Path -LiteralPath $backup -PathType Leaf)) {
                $parent = Split-Path -Parent $dest
                if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
                Copy-Item -LiteralPath $backup -Destination $dest -Force
            }
        }
        'remove' {
            if (Test-Path -LiteralPath $dest -PathType Leaf) { Remove-Item -LiteralPath $dest -Force }
        }
    }
}

function Invoke-Rollback {
    param($Tx)
    for ($i = $Tx.Applied.Count - 1; $i -ge 0; $i--) {
        try { Invoke-Undo -Entry $Tx.Applied[$i] } catch { }
    }
}

function Invoke-JournalRecovery {
    # Called on startup: if a journal survives from a crashed prior run, replay its
    # undos (newest first) so we start from a clean, consistent mirror.
    param([string]$Root)
    $txDir = Join-Path $Root '.orchestra-sync-tx'
    $journal = Join-Path $txDir 'journal.jsonl'
    if (-not (Test-Path -LiteralPath $journal -PathType Leaf)) {
        if (Test-Path -LiteralPath $txDir) { Remove-Item -LiteralPath $txDir -Recurse -Force -ErrorAction SilentlyContinue }
        return
    }
    Write-SyncWarn "cc-sync: recovering from an interrupted previous sync (rolling back its partial changes)."
    $lines = @(Get-Content -LiteralPath $journal -ErrorAction SilentlyContinue)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $l = $lines[$i]
        if (-not $l) { continue }
        try { Invoke-Undo -Entry ([hashtable](@{} + ($l | ConvertFrom-Json | ForEach-Object { @{ dest = $_.dest; undo = $_.undo; backup = $_.backup } }))) } catch { }
    }
    Remove-Item -LiteralPath $txDir -Recurse -Force -ErrorAction SilentlyContinue
}

function Publish-One {
    # Stages $Source, then publishes it to $Dest under the transaction. Heals an
    # empty-directory husk at $Dest (the directory-vs-file corruption class from
    # T-056); refuses a NON-empty directory there (may hold real data) by throwing,
    # which triggers a full rollback.
    param($Tx, [string]$Source, [string]$Dest)

    $Tx.Counter++
    $stagePath = Join-Path $Tx.Stage ("s{0}" -f $Tx.Counter)
    Copy-Item -LiteralPath $Source -Destination $stagePath -Force

    $destDir = Split-Path -Parent $Dest
    if ($destDir -and -not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }

    if (Test-Path -LiteralPath $Dest -PathType Container) {
        $hasChild = $null -ne (Get-ChildItem -LiteralPath $Dest -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($hasChild) {
            throw "destination '$Dest' is a non-empty directory blocking the file mirror; remove it by hand, then re-run cc-sync."
        }
        Remove-Item -LiteralPath $Dest -Force
    }

    if (Test-Path -LiteralPath $Dest -PathType Leaf) {
        $backup = Join-Path $Tx.Backup ("b{0}" -f $Tx.Counter)
        Copy-Item -LiteralPath $Dest -Destination $backup -Force
        Write-JournalEntry -Tx $Tx -Entry @{ dest = $Dest; undo = 'restore'; backup = $backup }
        Copy-Item -LiteralPath $stagePath -Destination $Dest -Force
    } else {
        Write-JournalEntry -Tx $Tx -Entry @{ dest = $Dest; undo = 'remove'; backup = $null }
        Copy-Item -LiteralPath $stagePath -Destination $Dest -Force
    }

    if (-not $script:OnWindows -and $Dest.EndsWith('.sh')) {
        try { & chmod '+x' $Dest 2>$null } catch { }
    }
}

function Remove-Stale {
    param($Tx, [string]$Dest)
    if (Test-Path -LiteralPath $Dest -PathType Leaf) {
        $Tx.Counter++
        $backup = Join-Path $Tx.Backup ("d{0}" -f $Tx.Counter)
        Copy-Item -LiteralPath $Dest -Destination $backup -Force
        Write-JournalEntry -Tx $Tx -Entry @{ dest = $Dest; undo = 'restore'; backup = $backup }
        Remove-Item -LiteralPath $Dest -Force
    }
}

# =============================================================================
# Managed-file discovery
# =============================================================================

$script:ExcludedAgents = @('coder.template.md', 'reviewer.template.md')

function Get-ManagedPairs {
    # Returns @{ Source; Dest; Kind } for every file this tool mirrors.
    param([string]$Repo, [string]$Dest, [string]$Glob)
    $pairs = [System.Collections.Generic.List[object]]::new()

    $agentsSrc = Join-Path $Repo 'agents'
    $agentsDst = Join-Path $Dest 'agents'
    if (Test-Path -LiteralPath $agentsSrc) {
        foreach ($f in (Get-ChildItem -LiteralPath $agentsSrc -File -Filter '*.md' -ErrorAction SilentlyContinue | Sort-Object Name)) {
            if ($script:ExcludedAgents -contains $f.Name) { continue }
            $pairs.Add([ordered]@{ Source = $f.FullName; Dest = (Join-Path $agentsDst $f.Name); Kind = 'agent' })
        }
    }

    $scriptsDst = Join-Path $Dest 'scripts'
    $launchersSrc = Join-Path $Repo 'launchers'
    if (Test-Path -LiteralPath $launchersSrc) {
        foreach ($f in (Get-ChildItem -LiteralPath $launchersSrc -File -Filter $Glob -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $pairs.Add([ordered]@{ Source = $f.FullName; Dest = (Join-Path $scriptsDst $f.Name); Kind = 'launcher' })
        }
    }

    foreach ($tpl in @('config.example.md', 'constraints.example.md')) {
        $src = Join-Path $Repo $tpl
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            $pairs.Add([ordered]@{ Source = $src; Dest = (Join-Path $scriptsDst $tpl); Kind = 'template' })
        }
    }

    return $pairs
}

# =============================================================================
# Regeneration + validation (delegated to the existing single-source scripts)
# =============================================================================

function Invoke-Regen {
    param([string]$Repo)
    $gen = Join-Path $Repo 'generate-coders.ps1'
    if (-not (Test-Path -LiteralPath $gen -PathType Leaf)) { return }
    Write-SyncInfo "Regenerating template-driven agent variants (generate-coders.ps1)..."
    $global:LASTEXITCODE = 0
    try {
        & $gen | ForEach-Object { Write-SyncInfo $_ }
    } catch {
        Stop-Sync 1 "generate-coders.ps1 failed ($($_.Exception.Message)). Aborting before mirroring so a stale/partial variant is never mirrored."
    }
    if ($LASTEXITCODE -ne 0) {
        Stop-Sync 1 "generate-coders.ps1 exited with code $LASTEXITCODE. Aborting before mirroring."
    }
    # Informational drift check (non-fatal, mirrors the pre-T-090 T-011 behaviour):
    # the on-disk variants are already correct after the call above; we only note
    # that they differed from what is committed so they get committed.
    if (Test-Path -LiteralPath (Join-Path $Repo '.git')) {
        try {
            & git -C $Repo diff --exit-code -- agents/coder.md agents/coder_fast.md agents/coder_deep.md agents/reviewer.md agents/reviewer_std.md *> $null
            if ($LASTEXITCODE -ne 0) {
                Write-SyncWarn "cc-sync: warning - generated agent variants differed from their committed copies and were regenerated; commit agents/coder*.md / reviewer*.md."
            }
        } catch { }
    }
}

function Invoke-Validate {
    param([string]$Repo)
    $val = Join-Path $Repo 'tools/validate-agents.ps1'
    if (-not (Test-Path -LiteralPath $val -PathType Leaf)) { return }
    $global:LASTEXITCODE = 0
    try {
        & $val | ForEach-Object { Write-SyncInfo $_ }
    } catch {
        Write-SyncWarn "cc-sync: warning - validate-agents.ps1 could not run ($($_.Exception.Message)); skipping the invariant check."
        return
    }
    if ($LASTEXITCODE -ne 0) {
        Write-SyncWarn "cc-sync: warning - agent .md files violate invariants (see the list above). Fix before relying on the mirror."
    }
}

# =============================================================================
# Main
# =============================================================================

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
try { $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path } catch { Stop-Sync 2 "repository root '$RepoRoot' does not exist." }

# Checkout vs mirror: the generator and templates only exist in an actual checkout.
# Run from the launchers-only ~/.claude/scripts mirror there is nothing to sync FROM,
# so this is a deliberate, reported no-op (never a false "Synced").
$isCheckout = (Test-Path -LiteralPath (Join-Path $RepoRoot 'generate-coders.ps1')) -or (Test-Path -LiteralPath (Join-Path $RepoRoot 'agents/coder.template.md'))
if (-not $isCheckout) {
    Write-SyncInfo "Skipping sync - not running from a repository checkout (mirror detected); run cc-sync from the repo checkout instead."
    exit 0
}

if (-not $DestinationRoot) { $DestinationRoot = Join-Path $HOME '.claude' }
if (-not $LauncherGlob) { $LauncherGlob = if ($script:OnWindows) { '*.cmd' } else { '*.sh' } }

if (-not $SkipRegen)    { Invoke-Regen    -Repo $RepoRoot }
if (-not $SkipValidate) { Invoke-Validate -Repo $RepoRoot }

New-Item -ItemType Directory -Force -Path $DestinationRoot | Out-Null

# Recover any partial state left by a crashed previous run, THEN start fresh.
Invoke-JournalRecovery -Root $DestinationRoot

$manifestPath = Join-Path $DestinationRoot '.orchestra-sync-manifest.json'
$previous = Read-Manifest -ManifestPath $manifestPath -Root $DestinationRoot

$pairs = Get-ManagedPairs -Repo $RepoRoot -Dest $DestinationRoot -Glob $LauncherGlob
$newManaged = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($p in $pairs) { [void]$newManaged.Add([System.IO.Path]::GetFullPath($p.Dest)) }

$tx = New-TxContext -Root $DestinationRoot
New-Item -ItemType Directory -Force -Path $tx.Stage | Out-Null
New-Item -ItemType Directory -Force -Path $tx.Backup | Out-Null

$counts = @{ agent = 0; launcher = 0; template = 0 }
$removed = 0
try {
    foreach ($p in $pairs) {
        Publish-One -Tx $tx -Source $p.Source -Dest $p.Dest
        $counts[$p.Kind]++
    }
    # Stale-entry pruning: only destinations THIS TOOL recorded in the previous
    # manifest that are no longer sourced. Foreign files (never in the manifest)
    # are untouched.
    foreach ($old in $previous) {
        if (-not $newManaged.Contains($old)) {
            Remove-Stale -Tx $tx -Dest $old
            $removed++
        }
    }
    Write-Manifest -ManifestPath $manifestPath -Root $DestinationRoot -AbsoluteDests @($newManaged)
} catch {
    Invoke-Rollback -Tx $tx
    Remove-Item -LiteralPath $tx.Dir -Recurse -Force -ErrorAction SilentlyContinue
    Stop-Sync 1 "mirror failed and was rolled back to its previous state - $($_.Exception.Message)"
}

# Success: drop the transaction workspace (journal + staging + backups).
Remove-Item -LiteralPath $tx.Dir -Recurse -Force -ErrorAction SilentlyContinue

$agentsDst = Join-Path $DestinationRoot 'agents'
$scriptsDst = Join-Path $DestinationRoot 'scripts'
Write-SyncInfo ("Synced {0} agent definition(s) -> {1}" -f $counts['agent'], $agentsDst)
Write-SyncInfo ("Synced {0} launcher script(s) -> {1}" -f $counts['launcher'], $scriptsDst)
Write-SyncInfo ("Synced {0} config template(s) -> {1}" -f $counts['template'], $scriptsDst)
if ($removed -gt 0) {
    Write-SyncInfo ("Removed {0} stale previously-managed mirror entry(ies)." -f $removed)
}
exit 0
