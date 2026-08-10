# ci:posix
<#
.SYNOPSIS
    Fixtures for the Class 9 smoke-budget handoff check of tools/check-consistency.ps1.

.DESCRIPTION
    Copies the repository into disposable roots, appends dispatch-instruction fixtures to
    the COPIED agents/processor.md and then runs the real validator end to end - the same
    entry point CI runs, with every class active. The positive fixture proves that a
    complete, line-wrapped handoff stays clean; the negative fixture proves that a newly
    added dispatch template omitting either budget - or both - is reported as a
    "<file>:<line> - smoke-budget-handoff - <detail>" finding with a non-zero exit code.
    Driving the production entry point (rather than a test-only mode) is deliberate: it
    also proves Class 9 is wired into the main flow. No repository file is modified.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$CheckerRelPath = 'tools/check-consistency.ps1'
$ProcessorRelPath = 'agents/processor.md'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Failures = [System.Collections.Generic.List[string]]::new()
$TempRoots = [System.Collections.Generic.List[string]]::new()

# Reuse the interpreter that runs this test instead of assuming `pwsh` is on PATH: a
# silent skip would hide the gate rather than prove it.
$PwshExe = (Get-Process -Id $PID).Path
if ([string]::IsNullOrWhiteSpace($PwshExe)) { $PwshExe = 'pwsh' }

# The validator reads agents/, tools/, launchers/ and the root contract docs, so the
# fixture is a copy of the whole checkout minus VCS and runtime state.
$SkipTopLevel = @('.git', '.jj', '.work', 'node_modules', 'target')

# A complete instruction that wraps across physical lines: the check must accept it, since
# every real processor dispatch template is wrapped this way.
$CompleteDispatch = @'
9.9. Fixture dispatch appended by tests/test-consistency.ps1: `Use the coder subagent
to implement task <T-ID>. Worktree=<abs>. WORK=<abs>. VCS=<jj|git>.
SMOKE_CMD=<if set>. CALL_DEADLINE_SEC=<from config>. CALL_OUTPUT_MAX_BYTES=<from config>.`
'@

# Three regressions in one fixture: a brand-new dispatch template with no budget at all,
# and one omitting each budget individually.
$IncompleteDispatches = @'
9.7. Fixture dispatch appended by tests/test-consistency.ps1 (no budget at all): `Use
the coder subagent to implement task <T-ID>. Worktree=<abs>. WORK=<abs>.
SMOKE_CMD=<if set>.`

9.8. Fixture dispatch appended by tests/test-consistency.ps1 (deadline omitted): `Use
the merger subagent. SMOKE_CMD=<if set>. CALL_OUTPUT_MAX_BYTES=<from config>.`

9.9. Fixture dispatch appended by tests/test-consistency.ps1 (output budget omitted):
`Use the coder_deep subagent. SMOKE_CMD=<if set>. CALL_DEADLINE_SEC=<from config>.`
'@

function New-RepoFixture {
    param([Parameter(Mandatory)][string]$AppendToProcessor)

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('orchestra-consistency-' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($root)
    $TempRoots.Add($root)
    foreach ($entry in @(Get-ChildItem -LiteralPath $RepoRoot -Force)) {
        if ($SkipTopLevel -contains $entry.Name) { continue }
        Copy-Item -LiteralPath $entry.FullName -Destination $root -Recurse -Force
    }

    # A blank line before the fixture keeps it a separate Markdown instruction paragraph.
    $processor = Join-Path $root $ProcessorRelPath
    $original = [System.IO.File]::ReadAllText($processor)
    [System.IO.File]::WriteAllText($processor, ($original + "`n`n" + $AppendToProcessor + "`n"), $Utf8NoBom)
    return $root
}

function Invoke-Checker {
    param([Parameter(Mandatory)][string]$Root)
    $lines = @(& $PwshExe -NoProfile -File (Join-Path $Root $CheckerRelPath) 2>&1 |
            ForEach-Object { $_.ToString().TrimEnd() })
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Lines    = $lines
        Output   = ($lines -join "`n")
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { $Failures.Add("FAIL - ${Message}: expected [$Expected], got [$Actual]") }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { $Failures.Add("FAIL - $Message") }
}

try {
    $positive = Invoke-Checker -Root (New-RepoFixture -AppendToProcessor $CompleteDispatch)
    Assert-Equal 0 $positive.ExitCode `
        "a complete line-wrapped dispatch keeps the whole validator clean; output=$($positive.Output)"
    Assert-True (-not $positive.Output.Contains('smoke-budget-handoff')) `
        'a complete dispatch produces no smoke-budget finding'

    $negative = Invoke-Checker -Root (New-RepoFixture -AppendToProcessor $IncompleteDispatches)
    $found = @($negative.Lines | Where-Object { $_ -match ' - smoke-budget-handoff - ' })
    Assert-Equal 1 $negative.ExitCode 'an incomplete dispatch fails the validator'
    Assert-Equal 3 $found.Count `
        "one finding per incomplete dispatch instruction; findings=$($found -join ' // ')"
    Assert-Equal 1 @($found | Where-Object { $_ -match 'missing CALL_DEADLINE_SEC=, CALL_OUTPUT_MAX_BYTES=$' }).Count `
        "omitting both budgets is reported once, naming both keys; findings=$($found -join ' // ')"
    Assert-Equal 1 @($found | Where-Object { $_ -match 'missing CALL_DEADLINE_SEC=$' }).Count `
        "omitting only the deadline budget is reported; findings=$($found -join ' // ')"
    Assert-Equal 1 @($found | Where-Object { $_ -match 'missing CALL_OUTPUT_MAX_BYTES=$' }).Count `
        "omitting only the output budget is reported; findings=$($found -join ' // ')"
    Assert-Equal 3 @($found | Where-Object { $_ -match '^agents/processor\.md:\d+ - ' }).Count `
        "findings keep the '<file>:<line> - <check> - <detail>' shape; findings=$($found -join ' // ')"
}
finally {
    foreach ($dir in $TempRoots) {
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($Failures.Count -gt 0) {
    Write-Host "FAILED - $($Failures.Count) assertion(s):"
    foreach ($failure in $Failures) { Write-Host "  $failure" }
    exit 1
}

Write-Host 'OK - consistency Class 9 accepts a complete wrapped dispatch and reports every dispatch missing either supervisor budget.'
exit 0
