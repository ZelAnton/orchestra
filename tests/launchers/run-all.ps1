<#
  Runs every tests/launchers/test-*.ps1 in this directory, each as its own
  child PowerShell process (full isolation of PATH/env/cwd changes between
  tests - see common.ps1 for why), and reports a pass/fail summary.

  Exit code: 0 if every test passed, otherwise the number of failing tests
  (non-zero), per T-018's requirement that the entry point return a non-zero
  code on any failure.

  Usage (from the repository root):
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\launchers\run-all.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testFiles = Get-ChildItem -Path $PSScriptRoot -Filter 'test-*.ps1' | Sort-Object Name

if ($testFiles.Count -eq 0) {
    Write-Host 'No test-*.ps1 files found.'
    exit 1
}

$failed = @()
foreach ($f in $testFiles) {
    $proc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $f.FullName) `
        -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput "$($f.FullName).out.tmp" `
        -RedirectStandardError "$($f.FullName).err.tmp"

    $stdout = Get-Content -LiteralPath "$($f.FullName).out.tmp" -Raw -ErrorAction SilentlyContinue
    $stderr = Get-Content -LiteralPath "$($f.FullName).err.tmp" -Raw -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "$($f.FullName).out.tmp", "$($f.FullName).err.tmp" -ErrorAction SilentlyContinue

    if ($stdout) { Write-Host $stdout.TrimEnd() }
    if ($stderr) { Write-Host $stderr.TrimEnd() }

    if ($proc.ExitCode -ne 0) {
        $failed += $f.Name
    }
}

Write-Host ''
Write-Host "== $($testFiles.Count - $failed.Count)/$($testFiles.Count) test files passed =="
if ($failed.Count -gt 0) {
    Write-Host ('Failed: ' + ($failed -join ', '))
    exit $failed.Count
}
exit 0
