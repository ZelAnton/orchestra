<#
  Runs every tests/launchers/test-*.ps1 in this directory, each as its own
  child PowerShell process (full isolation of PATH/env/cwd changes between
  tests - see common.ps1 for why), and reports a pass/fail summary.

  Cross-platform (task T-090): most test-*.ps1 here drive the Windows-only .cmd
  launchers (via cmd.exe) and can only run on Windows. The engine/fixture tests that
  drive the cross-platform pwsh runtimes (test-sync-runtime.ps1, test-doctor-runtime.ps1,
  test-generate-coders.ps1) are marked with a `# ci:posix` comment and run on every OS.
  So:
    - on Windows: run ALL test-*.ps1, spawned with Windows PowerShell (powershell.exe),
      which is what the .cmd-launcher tests were validated against;
    - on Linux/macOS: run ONLY the `# ci:posix`-marked tests, spawned with pwsh
      (PowerShell 7). The CI matrix runs this file on both windows-latest and
      ubuntu-latest, so the marked runtime tests actually execute on Linux there - that
      is the real cross-platform equivalence checkpoint for the unified sync/doctor
      engines.

  Exit code: 0 if every executed test passed, otherwise the number of failing
  tests (non-zero), per T-018's requirement that the entry point return a non-zero
  code on any failure. (A missing/empty test set is itself a failure.)

  Usage (from the repository root):
    pwsh -File tests\launchers\run-all.ps1          # any OS
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\launchers\run-all.ps1   # Windows
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# OS probe that is correct on both Windows PowerShell 5.1 (no $IsWindows automatic var)
# and pwsh 7.
$onWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows)

# Host used to spawn each child test. On Windows keep Windows PowerShell (powershell.exe)
# - the .cmd-launcher tests exercise a cmd.exe/5.1 codepage bug and were validated under
# it. On POSIX there is no powershell.exe, so use pwsh (PowerShell 7).
if ($onWindows) {
    $hostExe = 'powershell.exe'
} else {
    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwshCmd) {
        Write-Host 'FAIL - pwsh (PowerShell 7) not found on PATH; it is required to run the cross-platform launcher tests on this OS.'
        exit 1
    }
    $hostExe = $pwshCmd.Source
}

$allFiles = Get-ChildItem -Path $PSScriptRoot -Filter 'test-*.ps1' | Sort-Object Name

if ($allFiles.Count -eq 0) {
    Write-Host 'No test-*.ps1 files found.'
    exit 1
}

# On POSIX, restrict to the cross-platform (`# ci:posix`-marked) tests; the rest drive
# the Windows-only .cmd launchers and cannot run here.
if ($onWindows) {
    $testFiles = $allFiles
} else {
    $testFiles = @($allFiles | Where-Object {
        $head = Get-Content -LiteralPath $_.FullName -TotalCount 40 -ErrorAction SilentlyContinue
        ($head -join "`n") -match '(?m)^#\s*ci:posix\b'
    })
    $skipped = @($allFiles | Where-Object { $testFiles -notcontains $_ })
    if ($skipped.Count -gt 0) {
        Write-Host ("Skipping {0} Windows-only launcher test(s) on this OS: {1}" -f $skipped.Count, (($skipped | ForEach-Object { $_.Name }) -join ', '))
    }
    if ($testFiles.Count -eq 0) {
        Write-Host 'No cross-platform (# ci:posix) test-*.ps1 files found to run on this OS.'
        exit 1
    }
}

$failed = @()
foreach ($f in $testFiles) {
    $proc = Start-Process -FilePath $hostExe `
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
