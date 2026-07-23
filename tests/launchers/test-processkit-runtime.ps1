<#
  Cross-platform contract tests for tools/processkit-runtime.ps1. Baseline scenarios
  disable host auto-discovery so a developer-installed processkit-cli cannot make CI
  behavior machine-dependent. Set ORCHESTRA_PROCESSKIT_TEST_CLI to a released standalone
  binary to additionally exercise its real probe/run/JSONL contract.
#>

# ci:posix - cross-platform; run-all.ps1 runs this under pwsh on Linux in CI too.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Runtime = (Resolve-Path (Join-Path $PSScriptRoot '..\..\tools\processkit-runtime.ps1')).Path
$script:Common = (Resolve-Path (Join-Path $PSScriptRoot '..\..\tools\common.ps1')).Path
. $script:Common
$script:Pwsh = [string](@(Get-Command pwsh -CommandType Application -ErrorAction Stop) | Select-Object -First 1).Source
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:TempDirs = [System.Collections.Generic.List[string]]::new()

function New-TempDir {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('orc-pkrt-test-' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($path)
    $script:TempDirs.Add($path)
    return $path
}

function Invoke-Runtime {
    param([string[]]$Arguments, [hashtable]$Environment = @{})
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:Pwsh
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($psi | Get-Member -Name 'StandardOutputEncoding' -MemberType Property -ErrorAction SilentlyContinue) { $psi.StandardOutputEncoding = $script:Utf8 }
    if ($psi | Get-Member -Name 'StandardErrorEncoding' -MemberType Property -ErrorAction SilentlyContinue) { $psi.StandardErrorEncoding = $script:Utf8 }
    if ($psi | Get-Member -Name 'Environment' -MemberType Property -ErrorAction SilentlyContinue) {
        $processEnv = $psi.Environment
    } else {
        $processEnv = $psi.EnvironmentVariables
    }
    $processEnv['CC_PROCESSKIT_CLI'] = 'off'
    $processEnv['CC_PROCESSKIT_PYTHON'] = ''
    foreach ($name in $Environment.Keys) { $processEnv[[string]$name] = [string]$Environment[$name] }
    $childArgs = @('-NoProfile', '-NonInteractive', '-File', $script:Runtime) + $Arguments
    if ($psi | Get-Member -Name 'ArgumentList' -MemberType Property -ErrorAction SilentlyContinue) {
        foreach ($arg in $childArgs) { $psi.ArgumentList.Add($arg) }
    } else {
        $psi.Arguments = ConvertTo-Win32CommandLine $childArgs
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $stderr = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    $result = [pscustomobject]@{ ExitCode = $proc.ExitCode; Out = $stdout.Result; Err = $stderr.Result }
    $proc.Dispose()
    return $result
}

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { $script:Failures.Add("FAIL - $Message") } }
function Assert-Equal { param($Expected, $Actual, [string]$Message) if ($Expected -ne $Actual) { $script:Failures.Add("FAIL - ${Message}: expected [$Expected], got [$Actual]") } }

$probe = Invoke-Runtime @('probe', '--json')
Assert-Equal 0 $probe.ExitCode 'disabled backend probe succeeds'
$probeObject = $probe.Out | ConvertFrom-Json
Assert-Equal 'none' $probeObject.Kind 'disabled backend resolves to none'

$missing = Invoke-Runtime @('probe', '--json') -Environment @{ CC_PROCESSKIT_CLI = (Join-Path (New-TempDir) 'missing-processkit-cli') }
Assert-Equal 10 $missing.ExitCode 'missing explicit CLI fails closed'
Assert-True ($missing.Err -match 'CC_PROCESSKIT_CLI executable not found') 'missing explicit CLI explains the failed contract'

$work = New-TempDir
$worker = Join-Path $work 'worker.ps1'
$marker = Join-Path $work 'marker.txt'
[System.IO.File]::WriteAllText($worker, @'
param([string]$Marker, [int]$Code)
[System.IO.File]::WriteAllText($Marker, 'ran')
Write-Output 'runtime-output'
exit $Code
'@, $script:Utf8)
$run = Invoke-Runtime @('run-root', '--work', $work, '--label', 'test', '--', $script:Pwsh,
    '-NoProfile', '-NonInteractive', '-File', $worker, $marker, '7')
Assert-Equal 7 $run.ExitCode 'uncontained compatibility path forwards child exit code'
Assert-True (Test-Path -LiteralPath $marker -PathType Leaf) 'uncontained compatibility path runs the exact target'
Assert-True ($run.Out -match 'runtime-output') 'uncontained compatibility path preserves live stdout'
Assert-Equal 0 (@(Get-ChildItem -LiteralPath $work -Recurse -Filter '*.processkit.jsonl' -ErrorAction SilentlyContinue).Count) 'disabled backend creates no fake ProcessKit lifecycle'

$realCli = [string][Environment]::GetEnvironmentVariable('ORCHESTRA_PROCESSKIT_TEST_CLI')
if (-not [string]::IsNullOrWhiteSpace($realCli)) {
    $realWork = New-TempDir
    $realMarker = Join-Path $realWork 'marker.txt'
    $real = Invoke-Runtime @('run-root', '--work', $realWork, '--label', 'released-cli', '--',
        $script:Pwsh, '-NoProfile', '-NonInteractive', '-File', $worker, $realMarker, '7') `
        -Environment @{ CC_PROCESSKIT_CLI = $realCli }
    Assert-Equal 7 $real.ExitCode 'released CLI preserves child exit code'
    Assert-True (Test-Path -LiteralPath $realMarker -PathType Leaf) 'released CLI ran target inside the container'
    $events = @(Get-ChildItem -LiteralPath $realWork -Recurse -Filter '*.processkit.jsonl')
    Assert-Equal 1 $events.Count 'released CLI writes one root lifecycle artifact'
    if ($events.Count -eq 1) {
        $terminal = (Get-Content -LiteralPath $events[0].FullName -Encoding utf8 | Select-Object -Last 1) | ConvertFrom-Json
        Assert-Equal 'runner_exit' $terminal.event 'released CLI lifecycle ends with runner_exit'
        Assert-Equal 'child_exit' $terminal.source 'released CLI distinguishes the child result'
        Assert-Equal 7 ([int]$terminal.child_code) 'released CLI lifecycle preserves child code'
    }

    $interactiveWork = New-TempDir
    $interactiveMarker = Join-Path $interactiveWork 'marker.txt'
    $interactive = Invoke-Runtime @('run-root', '--interactive', '--work', $interactiveWork,
        '--label', 'interactive-root', '--', $script:Pwsh, '-NoProfile', '-NonInteractive',
        '-File', $worker, $interactiveMarker, '7') -Environment @{ CC_PROCESSKIT_CLI = $realCli }
    Assert-Equal 7 $interactive.ExitCode 'CLI without inherited-stdio surface preserves direct interactive fallback child code'
    Assert-True (Test-Path -LiteralPath $interactiveMarker -PathType Leaf) 'interactive fallback runs the target directly'
    Assert-True ($interactive.Err -match 'lacks run:--inherit-stdio') 'interactive fallback explains why root containment is degraded'
    Assert-Equal 0 (@(Get-ChildItem -LiteralPath $interactiveWork -Recurse -Filter '*.processkit.jsonl').Count) 'interactive fallback does not create a fake contained lifecycle'
}

foreach ($dir in $script:TempDirs) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
if ($script:Failures.Count -gt 0) {
    Write-Host "FAILED - $($script:Failures.Count) assertion(s):"
    foreach ($failure in $script:Failures) { Write-Host "  $failure" }
    exit 1
}
Write-Host 'OK - processkit-runtime resolver, fail-closed config, compatibility path, and optional released CLI contract passed.'
exit 0
