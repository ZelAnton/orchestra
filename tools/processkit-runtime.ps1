<#
.SYNOPSIS
    ProcessKit backend resolver and root-session launcher for Orchestra.

.DESCRIPTION
    Prefers the standalone processkit-cli binary, validates its machine contract with
    `probe`, and runs an Orchestra provider session in a kernel-backed container with a
    durable JSONL lifecycle log. The legacy Python wrapper remains a compatibility
    transport fallback when no standalone CLI is available, but it does not issue
    the launcher attestation required for a processor lease.

    Configuration contract (`~/.orchestra/root-config.md`):
      CC_PROCESSKIT_CLI     unset = auto-discover processkit-cli in ~/.orchestra or PATH
                            off   = disable standalone CLI discovery
                            other = required executable path/name (fail closed)
      CC_PROCESSKIT_PYTHON  optional legacy Python executable with importable processkit

    This file is also a dot-sourceable library. tools/supervisor.ps1 and
    tools/doctor-runtime.ps1 use the same resolver as the launchers, so compatibility
    requirements cannot drift between preflight and execution.

.EXAMPLE
    pwsh -File tools/processkit-runtime.ps1 probe --json
    pwsh -File tools/processkit-runtime.ps1 assert-root --json
    pwsh -File tools/processkit-runtime.ps1 run-root --work .work --label processor -- claude --agent processor
#>

$script:ProcessKitUtf8 = New-Object System.Text.UTF8Encoding($false)
$script:ProcessKitRuntimeExitCode = 0
$script:ProcessKitRootRunIdEnvironment = 'ORCHESTRA_PROCESSKIT_ROOT_RUN_ID'
$script:ProcessKitRequiredSurfaces = @(
    'run', 'run:--run-id', 'run:--cwd', 'run:--jsonl', 'run:--create-no-window',
    'run:--env',
    'inspect', 'inspect:--run-id', 'inspect:--json',
    'cancel', 'cancel:--run-id', 'kill', 'kill:--run-id',
    'list', 'list:--json', 'prune', 'prune:--json'
)
if (-not (Get-Command Get-OrchestraConfigValue -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'common.ps1')
}

function Get-ProcessKitApplication {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    return @(Get-Command $Name.Trim() -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
}

function Get-OrchestraProcessKitConfigValue {
    param([Parameter(Mandatory)][string]$Name, [string]$Work = '')
    $configWork = if ([string]::IsNullOrWhiteSpace($Work)) { Join-Path (Get-Location).Path '.work' } else { $Work }
    return Get-OrchestraConfigValue -Work $configWork -Key $Name -Default ''
}

function Set-ProcessKitArgumentList {
    param([Parameter(Mandatory)]$StartInfo, [Parameter(Mandatory)][string[]]$ArgumentList)
    if ($StartInfo | Get-Member -Name 'ArgumentList' -MemberType Property -ErrorAction SilentlyContinue) {
        foreach ($arg in $ArgumentList) { $StartInfo.ArgumentList.Add($arg) }
    } else {
        $StartInfo.Arguments = ConvertTo-Win32CommandLine $ArgumentList
    }
}

function Test-ProcessKitShellAssociationRequired {
    param([Parameter(Mandatory)][string]$FilePath)

    $onWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Windows)
    return [bool]($onWindows -and [System.IO.Path]::GetExtension($FilePath) -in @('.cmd', '.bat'))
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
    $psi.UseShellExecute = Test-ProcessKitShellAssociationRequired -FilePath $launchPath
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
    param([string]$Work = '')
    $configuredPython = Get-OrchestraProcessKitConfigValue -Name 'CC_PROCESSKIT_PYTHON' -Work $Work
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
    param([string]$Work = '')
    $configuredCli = Get-OrchestraProcessKitConfigValue -Name 'CC_PROCESSKIT_CLI' -Work $Work
    $cliDisabled = $configuredCli.Trim().Equals('off', [System.StringComparison]::OrdinalIgnoreCase)
    $cliExplicit = -not [string]::IsNullOrWhiteSpace($configuredCli) -and -not $cliDisabled
    $cliName = if ($cliExplicit) { $configuredCli.Trim() } else { 'processkit-cli' }

    if (-not $cliDisabled) {
        $cli = $null
        if ($cliExplicit) {
            $cli = Get-ProcessKitApplication $cliName
        } else {
            # The shared binary is installed beside the common runtime, before PATH
            # discovery. This makes the already-installed .orchestra/processkit-cli.exe
            # deterministic and prevents an unrelated developer installation from taking
            # precedence over the Orchestra contract.
            foreach ($candidate in @(
                (Join-Path (Get-OrchestraHome) 'processkit-cli.exe'),
                (Join-Path (Get-OrchestraHome) 'processkit-cli'),
                'processkit-cli'
            )) {
                if ([System.IO.Path]::IsPathRooted($candidate) -and -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
                $cli = Get-ProcessKitApplication $candidate
                if ($null -ne $cli -and $cli.Source) { break }
            }
        }
        if ($null -ne $cli -and $cli.Source) {
            $contract = Test-ProcessKitCliContract -FilePath ([string]$cli.Source)
            return [pscustomobject]@{
                Kind = 'cli'
                Path = [string]$cli.Source
                Version = [string]$contract.version
                SchemaVersion = [int]$contract.schema_version
                Surfaces = @($contract.surface)
                SupportsInheritedStdio = @($contract.surface) -contains 'run:--inherit-stdio'
                Explicit = $cliExplicit
            }
        }
        if ($cliExplicit) { throw "CC_PROCESSKIT_CLI executable not found: $configuredCli" }
    }

    $pythonBackend = Resolve-OrchestraProcessKitPythonBackend -Work $Work
    if ($null -ne $pythonBackend) { return $pythonBackend }

    return [pscustomobject]@{ Kind = 'none'; Path = ''; Version = ''; SchemaVersion = 0; Surfaces = @(); SupportsInheritedStdio = $false; Explicit = $false }
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

function Get-OrchestraProcessKitRootAttestation {
    $runId = [string][Environment]::GetEnvironmentVariable(
        $script:ProcessKitRootRunIdEnvironment,
        [EnvironmentVariableTarget]::Process)
    $valid = (-not [string]::IsNullOrWhiteSpace($runId)) -and
        $runId -match '^orchestra-[A-Za-z0-9_.-]+-[0-9a-f]{32}$'
    return [pscustomobject]@{
        Valid = [bool]$valid
        RunId = if ($valid) { $runId } else { '' }
        Environment = $script:ProcessKitRootRunIdEnvironment
    }
}

function Invoke-OrchestraRootProcess {
    param(
        [Parameter(Mandatory)][string]$Work,
        [string]$Label = 'processor',
        [switch]$Interactive,
        [Parameter(Mandatory)][string[]]$TargetArgv
    )
    if ($TargetArgv.Count -eq 0 -or [string]::IsNullOrWhiteSpace($TargetArgv[0])) {
        throw 'run-root requires a target command after --'
    }
    $backend = Resolve-OrchestraProcessKitBackend
    $target = [string]$TargetArgv[0]
    $targetArgs = if ($TargetArgv.Count -gt 1) { @($TargetArgv[1..($TargetArgv.Count - 1)]) } else { @() }

    if ($backend.Kind -eq 'cli' -and (-not $Interactive -or [bool]$backend.SupportsInheritedStdio)) {
        $events = New-OrchestraProcessKitEventPath -Work $Work -Label $Label
        $runId = 'orchestra-' + (($Label -replace '[^A-Za-z0-9_.-]', '_').Trim('.-_')) + '-' + [guid]::NewGuid().ToString('N')
        $cliArgs = @('run', '--run-id', $runId, '--cwd', [System.IO.Path]::GetFullPath((Get-Location).Path),
            '--jsonl', $events, '--env', "$($script:ProcessKitRootRunIdEnvironment)=$runId")
        if ($Interactive) { $cliArgs += '--inherit-stdio' } else { $cliArgs += '--create-no-window' }
        $cliArgs += @('--', $target) + @($targetArgs)
        return Invoke-ProcessKitInherited -FilePath $backend.Path -ArgumentList $cliArgs
    }
    if ($Interactive -and $backend.Kind -eq 'cli') {
        [Console]::Error.WriteLine('processkit-runtime: processkit-cli lacks run:--inherit-stdio; starting a compatibility root that cannot acquire a processor lease (supervised leaf commands remain contained)')
    }
    if ($backend.Kind -eq 'python' -and -not $Interactive) {
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
    if ($command -eq 'assert-root') {
        $unknown = @($Argv | Select-Object -Skip 1 | Where-Object { $_ -ne '--json' })
        if ($unknown.Count -gt 0) { throw "unknown assert-root option '$($unknown[0])'" }
        $attestation = Get-OrchestraProcessKitRootAttestation
        if (-not $attestation.Valid) {
            throw 'processor root is not launcher-attested by ProcessKit; start it with cc-processor or cc-resume'
        }
        if ($Argv -contains '--json') {
            [ordered]@{
                contained = $true
                backend = 'processkit-cli'
                run_id = $attestation.RunId
            } | ConvertTo-Json -Compress
        } else {
            Write-Output "contained backend=processkit-cli run_id=$($attestation.RunId)"
        }
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
    $interactive = $false
    for ($i = 1; $i -lt $separator; $i++) {
        switch ([string]$Argv[$i]) {
            '--work' { $i++; if ($i -lt $separator) { $work = [string]$Argv[$i] } }
            '--label' { $i++; if ($i -lt $separator) { $label = [string]$Argv[$i] } }
            '--interactive' { $interactive = $true }
            default { throw "unknown run-root option '$($Argv[$i])'" }
        }
    }
    if ([string]::IsNullOrWhiteSpace($work)) { throw 'run-root requires --work <directory>' }
    $script:ProcessKitRuntimeExitCode = Invoke-OrchestraRootProcess -Work $work -Label $label -Interactive:$interactive -TargetArgv @($Argv[($separator + 1)..($Argv.Count - 1)])
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
