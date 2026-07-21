<#
  Regression coverage for the installed cc-sync.cmd PATH layout.

  The mirrored launcher has no sibling ../tools runtime.  When it is invoked from
  the Orchestra checkout it must resolve tools/sync-runtime.ps1 from cwd instead
  of reporting a successful no-op and leaving the user mirror stale.
#>

$ErrorActionPreference = 'Stop'
$failures = [System.Collections.Generic.List[string]]::new()
$root = Join-Path ([System.IO.Path]::GetTempPath()) ('orchestra-sync-launcher-' + [guid]::NewGuid().ToString('N'))
$checkout = Join-Path $root 'checkout'
$mirrorScripts = Join-Path $root 'mirror\scripts'
$bin = Join-Path $root 'bin'
$capture = Join-Path $root 'pwsh-args.txt'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { $script:failures.Add($Message) }
}

try {
    New-Item -ItemType Directory -Force -Path (Join-Path $checkout 'agents'), (Join-Path $checkout 'tools'), $mirrorScripts, $bin | Out-Null
    Set-Content -LiteralPath (Join-Path $checkout 'agents\processor.md') -Value 'fixture' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $checkout 'generate-codex-agents.ps1') -Value '# fixture' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $checkout 'tools\sync-runtime.ps1') -Value '# fixture' -Encoding ascii
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\..\launchers\cc-sync.cmd') -Destination (Join-Path $mirrorScripts 'cc-sync.cmd')

    $fakePwsh = @"
@echo off
>"$capture" echo %*
exit /b 0
"@
    Set-Content -LiteralPath (Join-Path $bin 'pwsh.cmd') -Value $fakePwsh -Encoding ascii

    $oldPath = $env:PATH
    $oldLocation = Get-Location
    try {
        $env:PATH = "$bin;$oldPath"
        Set-Location -LiteralPath $checkout
        & (Join-Path $mirrorScripts 'cc-sync.cmd') -Quiet
        $rc = $LASTEXITCODE
    } finally {
        Set-Location -LiteralPath $oldLocation
        $env:PATH = $oldPath
    }

    Assert-True ($rc -eq 0) "PATH mirror launcher exited $rc"
    Assert-True (Test-Path -LiteralPath $capture -PathType Leaf) 'PATH mirror launcher did not invoke pwsh from an Orchestra checkout cwd'
    if (Test-Path -LiteralPath $capture -PathType Leaf) {
        $argsText = Get-Content -LiteralPath $capture -Raw
        $expectedRuntime = Join-Path $checkout 'tools\sync-runtime.ps1'
        Assert-True ($argsText.Contains($expectedRuntime)) "PATH mirror launcher did not select cwd runtime '$expectedRuntime': $argsText"
        Assert-True ($argsText.Contains('-Quiet')) "PATH mirror launcher did not forward arguments: $argsText"
    }

    # A target project may contain a stale/gitignored tools/sync-runtime.ps1.  One
    # filename is not enough identity: the installed launcher must not execute it.
    $target = Join-Path $root 'target'
    New-Item -ItemType Directory -Force -Path (Join-Path $target 'tools') | Out-Null
    Set-Content -LiteralPath (Join-Path $target 'tools\sync-runtime.ps1') -Value '# stale target-local fixture' -Encoding ascii
    Remove-Item -LiteralPath $capture -Force -ErrorAction SilentlyContinue
    try {
        $env:PATH = "$bin;$oldPath"
        Set-Location -LiteralPath $target
        $noOpOutput = & (Join-Path $mirrorScripts 'cc-sync.cmd') 2>&1
        $noOpRc = $LASTEXITCODE
    } finally {
        Set-Location -LiteralPath $oldLocation
        $env:PATH = $oldPath
    }
    Assert-True ($noOpRc -eq 0) "PATH mirror launcher outside Orchestra exited $noOpRc"
    Assert-True (-not (Test-Path -LiteralPath $capture)) 'PATH mirror launcher executed a target-local runtime without full Orchestra identity'
    Assert-True (($noOpOutput -join "`n") -match 'no Orchestra checkout found') 'PATH mirror launcher did not report its no-op outside Orchestra'
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

if ($failures.Count -gt 0) {
    Write-Host "test-sync-launcher: $($failures.Count) failure(s):"
    foreach ($failure in $failures) { Write-Host "  FAIL - $failure" }
    exit 1
}

Write-Host 'OK - installed cc-sync.cmd resolves the Orchestra checkout runtime from cwd.'
