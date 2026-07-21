<#
.SYNOPSIS
    Hermetic fixtures for tools/check-queue-contract-path-guard.ps1 (T-269).

.DESCRIPTION
    Exercises the real validator through its RepositoryRoot test seam. Fixtures prove that
    an agent citing the roadmap contract is accepted only when it carries both exact ROOT
    paths and the complete anti-disk-walk block. No repository files are modified.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$Guard = Join-Path $PSScriptRoot '..\tools\check-queue-contract-path-guard.ps1'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Failures = [System.Collections.Generic.List[string]]::new()
$TempDirs = [System.Collections.Generic.List[string]]::new()

function Write-Utf8 {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        [void][System.IO.Directory]::CreateDirectory($parent)
    }
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function New-Fixture {
    param(
        [switch]$BareRoadmap,
        [switch]$MissingAntiDiskWalk
    )
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('orchestra-path-guard-' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory((Join-Path $root 'agents'))
    [void][System.IO.Directory]::CreateDirectory((Join-Path $root 'docs'))
    $TempDirs.Add($root)

    $shared = if ($MissingAntiDiskWalk) { 'find / find C:/' } else { 'find / find C:/ find / -maxdepth' }
    $roadmapPaths = if ($BareRoadmap) {
        'docs/roadmap_contract.md .work/roadmap.md'
    } else {
        '$ROOT/docs/roadmap_contract.md $ROOT/.work/roadmap.md'
    }
    $queuePaths = '$ROOT/docs/queue_contract.md $HOME/.claude/specs/Tasks_Queue_Format.md'

    # One role cites both families so the validator's per-family fail-closed scope check
    # remains active in every fixture.
    Write-Utf8 (Join-Path $root 'agents/role.md') "$queuePaths $roadmapPaths $shared"
    Write-Utf8 (Join-Path $root 'knowledge.md') "$queuePaths `$ROOT/docs/roadmap_contract.md `$ROOT/.work/roadmap.md find / find C:/ find / -maxdepth"
    Write-Utf8 (Join-Path $root 'docs/queue_contract.md') "$queuePaths find / find C:/ find / -maxdepth"
    Write-Utf8 (Join-Path $root 'docs/roadmap_contract.md') '$ROOT/docs/roadmap_contract.md $ROOT/.work/roadmap.md find / find C:/ find / -maxdepth'
    return $root
}

function Invoke-Fixture {
    param([Parameter(Mandatory)][string]$Root)
    $output = @(& pwsh -NoProfile -File $Guard -RepositoryRoot $Root 2>&1 | ForEach-Object { $_.ToString() })
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { $Failures.Add("FAIL - ${Message}: expected [$Expected], got [$Actual]") }
}

function Assert-Contains {
    param([string]$Text, [string]$Needle, [string]$Message)
    if (-not $Text.Contains($Needle)) { $Failures.Add("FAIL - $Message (missing [$Needle] in [$Text])") }
}

try {
    $positive = Invoke-Fixture -Root (New-Fixture)
    Assert-Equal 0 $positive.ExitCode 'complete roadmap resolution and anti-disk-walk guard is accepted'

    $bare = Invoke-Fixture -Root (New-Fixture -BareRoadmap)
    Assert-Equal 1 $bare.ExitCode 'bare roadmap references are rejected'
    Assert-Contains $bare.Output 'resolve-roadmap-contract-path' 'bare roadmap contract path reports the resolution finding'
    Assert-Contains $bare.Output 'resolve-roadmap-artifact-path' 'bare roadmap artifact path reports the resolution finding'

    $unsafe = Invoke-Fixture -Root (New-Fixture -MissingAntiDiskWalk)
    Assert-Equal 1 $unsafe.ExitCode 'roadmap reference without the full anti-disk-walk block is rejected'
    Assert-Contains $unsafe.Output 'ban-find-maxdepth' 'missing maxdepth ban reports the anti-disk-walk finding'
}
finally {
    foreach ($dir in $TempDirs) {
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

if ($Failures.Count -gt 0) {
    Write-Host "FAILED - $($Failures.Count) assertion(s):"
    $Failures | ForEach-Object { Write-Host "  $_" }
    exit 1
}

Write-Host 'OK - queue/roadmap contract path guard accepts complete fixtures and rejects bare or unsafe roadmap references.'
exit 0
