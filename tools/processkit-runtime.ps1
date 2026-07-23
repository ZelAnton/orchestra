<#
.SYNOPSIS
    ProcessKit backend resolver and root-session launcher for Orchestra.

.DESCRIPTION
    Prefers the standalone processkit-cli binary, validates its machine contract with
    `probe`, and runs an Orchestra provider session in a kernel-backed container with a
    durable JSONL lifecycle log. The legacy Python wrapper remains a compatibility
    fallback when no standalone CLI is available.

    Environment contract:
      CC_PROCESSKIT_CLI     unset = auto-discover processkit-cli on PATH
                            off   = disable standalone CLI discovery
                            other = required executable path/name (fail closed)
      CC_PROCESSKIT_PYTHON  optional legacy Python executable with importable processkit

    This file is also a dot-sourceable library. tools/supervisor.ps1 and
    tools/doctor-runtime.ps1 use the same resolver as the launchers, so compatibility
    requirements cannot drift between preflight and execution.

.EXAMPLE
    pwsh -File tools/processkit-runtime.ps1 probe --json
    pwsh -File tools/processkit-runtime.ps1 run-root --work .work --label processor -- claude --agent processor
#>

$script:ProcessKitUtf8 = New-Object System.Text.UTF8Encoding($false)
$script:ProcessKitRuntimeExitCode = 0
$script:ProcessKitRequiredSurfaces = @(
    'run', 'run:--run-id', 'run:--cwd', 'run:--jsonl', 'run:--create-no-window',
    'inspect', 'inspect:--run-id', 'inspect:--json',
    'cancel', 'cancel:--run-id', 'kill', 'kill:--run-id',
    'list', 'list:--json', 'prune', 'prune:--json'
)
if (-not (Get-Command ConvertTo-Win32CommandLine -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'common.ps1')
}

function Get-ProcessKitApplication {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    return @(Get-Command $Name.Trim() -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
}

function Set-ProcessKitArgumentList {
    param([Parameter(Mandatory)]$StartInfo, [Parameter(Mandatory)][string[]]$ArgumentList)
    if ($StartInfo | Get-Member -Name 'ArgumentList' -MemberType Property -ErrorAction SilentlyContinue) {
        foreach ($arg in $ArgumentList) { $StartInfo.ArgumentList.Add($arg) }
    } else {
        $StartInfo.Arguments = ConvertTo-Win32CommandLine $ArgumentList
    }
}

function Invoke-ProcessKitCaptured {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [int]$TimeoutMs = 10000
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($psi | Get-Member -Name 'StandardOutputEncoding' -MemberType Property -ErrorAction SilentlyContinue) { $psi.StandardOutputEncoding = $script:ProcessKitUtf8 }
    if ($psi | Get-Member -Name 'StandardErrorEncoding' -MemberType Property -ErrorAction SilentlyContinue) { $psi.StandardErrorEncoding = $script:ProcessKitUtf8 }
    Set-ProcessKitArgumentList -StartInfo $psi -ArgumentList $ArgumentList
    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutMs)) {
            try { $proc.Kill($true) } catch { try { $proc.Kill() } catch { } }
            try { $proc.WaitForExit(2000) } catch { }
            throw "process timed out after ${TimeoutMs}ms: $FilePath"
        }
        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            Stdout = [string]$stdout.GetAwaiter().GetResult()
            Stderr = [string]$stderr.GetAwaiter().GetResult()
        }
    } finally {
        if ($null -ne $proc) { try { $proc.Dispose() } catch { } }
    }
}

function Invoke-ProcessKitInherited {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )
    $resolved = Get-ProcessKitApplication $FilePath
    $launchPath = if ($null -ne $resolved -and $resolved.Source) { [string]$resolved.Source } else { $FilePath }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $launchPath
    # A .cmd/.bat target needs the Windows shell association; native executables and
    # POSIX scripts use direct argv with no shell reinterpretation.
    $psi.UseShellExecute = [bool]($IsWindows -and [System.IO.Path]::GetExtension($launchPath) -in @('.cmd', '.bat'))
    $psi.CreateNoWindow = $false
    Set-ProcessKitArgumentList -StartInfo $psi -ArgumentList $ArgumentList
    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.WaitForExit()
        return $proc.ExitCode
    } finally {
        if ($null -ne $proc) { try { $proc.Dispose() } catch { } }
    }
}

function Test-ProcessKitCliContract {
    param([Parameter(Mandatory)][string]$FilePath)
    $probeArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($arg in @('probe', '--json', '--require-schema-version', '1', '--require-exit-code-band', '100-119')) {
        $probeArgs.Add($arg)
    }
    foreach ($surface in $script:ProcessKitRequiredSurfaces) {
        $probeArgs.Add('--require-surface')
        $probeArgs.Add($surface)
    }
    $probe = Invoke-ProcessKitCaptured -FilePath $FilePath -ArgumentList $probeArgs.ToArray()
    if ($probe.ExitCode -ne 0) {
        $detail = $probe.Stderr.Trim()
        if (-not $detail) { $detail = $probe.Stdout.Trim() }
        if (-not $detail) { $detail = "probe exited $($probe.ExitCode)" }
        throw "processkit-cli compatibility probe failed: $detail"
    }
    try { $contract = $probe.Stdout | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "processkit-cli probe returned invalid JSON: $($_.Exception.Message)" }
    if (-not [bool]$contract.compatible -or [int]$contract.schema_version -ne 1) {
        throw 'processkit-cli probe reported an incompatible contract'
    }
    return $contract
}

function Test-ProcessKitPython {
    param([Parameter(Mandatory)][string]$FilePath)
    $probe = Invoke-ProcessKitCaptured -FilePath $FilePath -ArgumentList @('-c', 'import processkit')
    if ($probe.ExitCode -ne 0) { throw "CC_PROCESSKIT_PYTHON cannot import processkit: $FilePath" }
}

function Resolve-OrchestraProcessKitPythonBackend {
    $configuredPython = [string][Environment]::GetEnvironmentVariable('CC_PROCESSKIT_PYTHON')
    if ([string]::IsNullOrWhiteSpace($configuredPython)) { return $null }
    $python = Get-ProcessKitApplication $configuredPython.Trim()
    if ($null -eq $python -or -not $python.Source) {
        throw "CC_PROCESSKIT_PYTHON executable not found: $configuredPython"
    }
    Test-ProcessKitPython -FilePath ([string]$python.Source)
    return [pscustomobject]@{
        Kind = 'python'
        Path = [string]$python.Source
        Version = ''
        SchemaVersion = 0
        Explicit = $true
    }
}

function Resolve-OrchestraProcessKitBackend {
    $configuredCli = [string][Environment]::GetEnvironmentVariable('CC_PROCESSKIT_CLI')
    $cliDisabled = $configuredCli.Trim().Equals('off', [System.StringComparison]::OrdinalIgnoreCase)
    $cliExplicit = -not [string]::IsNullOrWhiteSpace($configuredCli) -and -not $cliDisabled
    $cliName = if ($cliExplicit) { $configuredCli.Trim() } else { 'processkit-cli' }

    if (-not $cliDisabled) {
        $cli = Get-ProcessKitApplication $cliName
        if ($null -ne $cli -and $cli.Source) {
            $contract = Test-ProcessKitCliContract -FilePath ([string]$cli.Source)
            return [pscustomobject]@{
                Kind = 'cli'
                Path = [string]$cli.Source
                Version = [string]$contract.version
                SchemaVersion = [int]$contract.schema_version
                Explicit = $cliExplicit
            }
        }
        if ($cliExplicit) { throw "CC_PROCESSKIT_CLI executable not found: $configuredCli" }
    }

    $pythonBackend = Resolve-OrchestraProcessKitPythonBackend
    if ($null -ne $pythonBackend) { return $pythonBackend }

    return [pscustomobject]@{ Kind = 'none'; Path = ''; Version = ''; SchemaVersion = 0; Explicit = $false }
}

function New-OrchestraProcessKitEventPath {
    param([Parameter(Mandatory)][string]$Work, [string]$Label = 'processor')
    $safeLabel = $Label -replace '[^A-Za-z0-9_.-]', '_'
    $directory = Join-Path ([System.IO.Path]::GetFullPath($Work)) 'processes/_processor'
    [void][System.IO.Directory]::CreateDirectory($directory)
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $nonce = [guid]::NewGuid().ToString('N').Substring(0, 12)
    return Join-Path $directory "$safeLabel-$stamp-$nonce.processkit.jsonl"
}

function Invoke-OrchestraRootProcess {
    param(
        [Parameter(Mandatory)][string]$Work,
        [string]$Label = 'processor',
        [Parameter(Mandatory)][string[]]$TargetArgv
    )
    if ($TargetArgv.Count -eq 0 -or [string]::IsNullOrWhiteSpace($TargetArgv[0])) {
        throw 'run-root requires a target command after --'
    }
    $backend = Resolve-OrchestraProcessKitBackend
    $target = [string]$TargetArgv[0]
    $targetArgs = if ($TargetArgv.Count -gt 1) { @($TargetArgv[1..($TargetArgv.Count - 1)]) } else { @() }

    if ($backend.Kind -eq 'cli') {
        $events = New-OrchestraProcessKitEventPath -Work $Work -Label $Label
        $runId = 'orchestra-' + (($Label -replace '[^A-Za-z0-9_.-]', '_').Trim('.-_')) + '-' + [guid]::NewGuid().ToString('N')
        $cliArgs = @('run', '--run-id', $runId, '--cwd', [System.IO.Path]::GetFullPath((Get-Location).Path),
            '--jsonl', $events, '--create-no-window', '--', $target) + @($targetArgs)
        return Invoke-ProcessKitInherited -FilePath $backend.Path -ArgumentList $cliArgs
    }
    if ($backend.Kind -eq 'python') {
        return Invoke-ProcessKitInherited -FilePath $backend.Path -ArgumentList (@('-m', 'processkit', 'run', '--', $target) + @($targetArgs))
    }

    return Invoke-ProcessKitInherited -FilePath $target -ArgumentList $targetArgs
}

function Invoke-ProcessKitRuntimeCli {
    param([string[]]$Argv)
    $command = if ($Argv.Count -gt 0) { [string]$Argv[0] } else { '' }
    if ($command -eq 'probe') {
        $asJson = $Argv -contains '--json'
        $backend = Resolve-OrchestraProcessKitBackend
        if ($asJson) { $backend | ConvertTo-Json -Compress } else { "$($backend.Kind): $($backend.Path)" }
        $script:ProcessKitRuntimeExitCode = 0
        return
    }
    if ($command -ne 'run-root') { throw "unknown command '$command'" }

    $separator = [Array]::IndexOf([object[]]$Argv, '--')
    if ($separator -lt 0 -or $separator -ge ($Argv.Count - 1)) {
        throw 'run-root requires -- followed by the target command'
    }
    $work = ''
    $label = 'processor'
    for ($i = 1; $i -lt $separator; $i++) {
        switch ([string]$Argv[$i]) {
            '--work' { $i++; if ($i -lt $separator) { $work = [string]$Argv[$i] } }
            '--label' { $i++; if ($i -lt $separator) { $label = [string]$Argv[$i] } }
            default { throw "unknown run-root option '$($Argv[$i])'" }
        }
    }
    if ([string]::IsNullOrWhiteSpace($work)) { throw 'run-root requires --work <directory>' }
    $script:ProcessKitRuntimeExitCode = Invoke-OrchestraRootProcess -Work $work -Label $label -TargetArgv @($Argv[($separator + 1)..($Argv.Count - 1)])
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-ProcessKitRuntimeCli -Argv $args
        exit $script:ProcessKitRuntimeExitCode
    }
    catch {
        [Console]::Error.WriteLine('processkit-runtime: ' + $_.Exception.Message)
        exit 10
    }
}
