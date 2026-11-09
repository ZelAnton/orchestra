# Shared runner of the hermetic cc-focus Python modules. It is not a test file itself.
# Each test-cc-focus*.ps1 file runs a group of modules. On Windows, these modules take
# several times longer than on Linux, so one group must stay below the time limit of
# one test file in run-all.ps1. Every module of a group runs, and the group then fails
# with the full list, so one CI run shows all failures.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-FocusSuites {
    param([Parameter(Mandatory)] [object[]] $Suites)
    $repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $python = Get-Command python3, python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $python) { throw 'Python 3.10+ is required for cc-focus regression tests.' }
    $env:PYTHONDONTWRITEBYTECODE = '1'
    # Match focus-runtime.ps1 rather than the host's legacy Windows code page.
    $env:PYTHONUTF8 = '1'
    $env:PYTHONIOENCODING = 'utf-8'
    foreach ($suite in $Suites) {
        # A group of one module needs @(, @(...)): PowerShell flattens @(@(...)) into two strings.
        if ($suite -isnot [array] -or $suite.Count -ne 2) { throw 'Each focus suite is @(module path, label).' }
    }
    $failed = @()
    foreach ($suite in $Suites) {
        & $python.Source (Join-Path $repo $suite[0])
        if ($LASTEXITCODE -ne 0) { $failed += "$($suite[1]) failed: $LASTEXITCODE" }
    }
    if ($failed.Count -gt 0) { throw ($failed -join [Environment]::NewLine) }
}
