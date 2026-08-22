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
    $configHome = New-TempDir
    $configKeys = @('CC_PROCESSKIT_CLI', 'CC_PROCESSKIT_PYTHON', 'CODEX_HOME', 'ORCHESTRA_REGISTRY_PATH')
    $configLines = @()
    if (-not $Environment.ContainsKey('CC_PROCESSKIT_CLI')) { $configLines += 'CC_PROCESSKIT_CLI: off' }
    foreach ($name in $Environment.Keys) {
        if ($configKeys -contains $name -and -not [string]::IsNullOrWhiteSpace([string]$Environment[$name])) {
            $configLines += (('{0}: {1}' -f $name, $Environment[$name]))
        }
    }
    [System.IO.File]::WriteAllText((Join-Path $configHome 'root-config.md'), (($configLines -join "`n") + "`n"), $script:Utf8)
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
    $processEnv['ORCHESTRA_HOME'] = $configHome
    foreach ($name in $configKeys) { $processEnv[$name] = '' }
    foreach ($name in $Environment.Keys) {
        if ($configKeys -notcontains $name) { $processEnv[[string]$name] = [string]$Environment[$name] }
    }
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

# Windows PowerShell 5.1 has no automatic $IsWindows variable. Remove it when the
# current host defines it so this StrictMode path reproduces the same contract.
Remove-Variable -Name IsWindows -Scope Global -Force -ErrorAction SilentlyContinue
. $script:Runtime
$onWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows)
Assert-Equal $onWindows (Test-ProcessKitShellAssociationRequired 'worker.cmd') '.cmd uses the Windows shell association only on Windows'
Assert-Equal $onWindows (Test-ProcessKitShellAssociationRequired 'worker.bat') '.bat uses the Windows shell association only on Windows'
Assert-Equal $false (Test-ProcessKitShellAssociationRequired $script:Pwsh) 'native executable keeps direct argv behavior'
$strictInherited = Invoke-ProcessKitInherited -FilePath $script:Pwsh -ArgumentList @(
    '-NoProfile', '-NonInteractive', '-Command', 'exit 0')
Assert-Equal 0 $strictInherited 'StrictMode inherited launch succeeds without an IsWindows variable'

if ($onWindows) {
    $shellWork = New-TempDir
    $shellTarget = Join-Path $shellWork 'inherited.cmd'
    $shellMarker = Join-Path $shellWork 'shell-marker.txt'
    [System.IO.File]::WriteAllText($shellTarget, "@echo off`r`n>`"%~1`" echo shell`r`nexit /b 19`r`n", $script:Utf8)
    $shellExit = Invoke-ProcessKitInherited -FilePath $shellTarget -ArgumentList @($shellMarker)
    Assert-Equal 19 $shellExit '.cmd inherited launch preserves exit code through shell association'
    Assert-True (Test-Path -LiteralPath $shellMarker -PathType Leaf) '.cmd inherited launch preserves argv through shell association'
}

$probe = Invoke-Runtime @('probe', '--json')
Assert-Equal 0 $probe.ExitCode 'disabled backend probe succeeds'
$probeObject = $probe.Out | ConvertFrom-Json
Assert-Equal 'none' $probeObject.Kind 'disabled backend resolves to none'

$unattested = Invoke-Runtime @('assert-root', '--json')
Assert-Equal 10 $unattested.ExitCode 'direct root without a launcher attestation is refused'
Assert-True ($unattested.Err -match 'not launcher-attested by ProcessKit') 'direct-root refusal names the required containment path'
$testRunId = 'orchestra-runtime-test-00000000000000000000000000000001'
$attested = Invoke-Runtime @('assert-root', '--json') -Environment @{
    ORCHESTRA_PROCESSKIT_ROOT_RUN_ID = $testRunId
}
Assert-Equal 0 $attested.ExitCode 'well-formed launcher attestation is accepted'
$attestedObject = $attested.Out | ConvertFrom-Json
Assert-Equal $true ([bool]$attestedObject.contained) 'attestation response is structurally contained=true'
Assert-Equal $testRunId ([string]$attestedObject.run_id) 'attestation response preserves the exact root run id'

$missing = Invoke-Runtime @('probe', '--json') -Environment @{ CC_PROCESSKIT_CLI = (Join-Path (New-TempDir) 'missing-processkit-cli') }
Assert-Equal 10 $missing.ExitCode 'missing explicit CLI fails closed'
Assert-True ($missing.Err -match 'CC_PROCESSKIT_CLI executable not found') 'missing explicit CLI explains the failed contract'

$work = New-TempDir
$worker = Join-Path $work 'worker.ps1'
$marker = Join-Path $work 'marker.txt'
[System.IO.File]::WriteAllText($worker, @'
param([string]$Marker, [int]$Code)
[System.IO.File]::WriteAllText($Marker, [string]$env:ORCHESTRA_PROCESSKIT_ROOT_RUN_ID)
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
    $realContract = (& $realCli probe --json | ConvertFrom-Json)
    $supportsInheritedStdio = @($realContract.surface) -contains 'run:--inherit-stdio'
    $realWork = New-TempDir
    $realMarker = Join-Path $realWork 'marker.txt'
    $real = Invoke-Runtime @('run-root', '--work', $realWork, '--label', 'released-cli', '--',
        $script:Pwsh, '-NoProfile', '-NonInteractive', '-File', $worker, $realMarker, '7') `
        -Environment @{ CC_PROCESSKIT_CLI = $realCli }
    Assert-Equal 7 $real.ExitCode 'released CLI preserves child exit code'
    Assert-True (Test-Path -LiteralPath $realMarker -PathType Leaf) 'released CLI ran target inside the container'
    if (Test-Path -LiteralPath $realMarker -PathType Leaf) {
        Assert-True ((Get-Content -Raw -LiteralPath $realMarker) -match '^orchestra-released-cli-[0-9a-f]{32}$') 'released CLI injects a per-root launcher attestation'
    }
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
    Assert-Equal 7 $interactive.ExitCode 'interactive root preserves child exit code'
    Assert-True (Test-Path -LiteralPath $interactiveMarker -PathType Leaf) 'interactive root runs the target'
    $interactiveEvents = @(Get-ChildItem -LiteralPath $interactiveWork -Recurse -Filter '*.processkit.jsonl')
    if ($supportsInheritedStdio) {
        Assert-Equal 1 $interactiveEvents.Count 'inherited-stdio capability keeps interactive root contained'
        Assert-True ($interactive.Err -notmatch 'lacks run:--inherit-stdio') 'capable CLI does not emit a degradation warning'
    } else {
        Assert-True ($interactive.Err -match 'lacks run:--inherit-stdio') 'legacy interactive fallback explains why root containment is degraded'
        Assert-Equal 0 $interactiveEvents.Count 'legacy interactive fallback does not create a fake contained lifecycle'
    }
}

foreach ($dir in $script:TempDirs) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
if ($script:Failures.Count -gt 0) {
    Write-Host "FAILED - $($script:Failures.Count) assertion(s):"
    foreach ($failure in $script:Failures) { Write-Host "  $failure" }
    exit 1
}
Write-Host 'OK - processkit-runtime resolver, fail-closed config, compatibility path, and optional released CLI contract passed.'
exit 0
