<#
    Fixed, operator-selected focus profile. Model/review defaults from the
    queue processor do not apply. ProcessKit discovery and shared leases do apply.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'processkit-runtime.ps1')

try {
    $python = $null
    $pythonPrefix = @()
    foreach ($name in @('python3', 'python', 'py')) {
        $candidate = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $candidate) { continue }
        $prefix = if ($name -eq 'py') { @('-3') } else { @() }
        $probe = Invoke-ProcessKitCaptured -FilePath $candidate.Source -ArgumentList ($prefix + @(
            '-c', 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'))
        if ($probe.ExitCode -eq 0) {
            $python = [string]$candidate.Source
            $pythonPrefix = $prefix
            break
        }
    }
    if (-not $python) { throw 'Python 3.10 or newer is required for cc-focus.' }
    $runtime = Join-Path $PSScriptRoot 'cc_focus.py'
    if (-not (Test-Path -LiteralPath $runtime -PathType Leaf)) { throw "Missing cycle runtime: $runtime" }
    $env:ORCHESTRA_CYCLE_PWSH = Get-PowerShellHostExecutable
    $env:PYTHONDONTWRITEBYTECODE = '1'
    $env:PYTHONUTF8 = '1'
    $env:PYTHONIOENCODING = 'utf-8'
    $target = @($python) + $pythonPrefix + @($runtime) + @($args)
    if (($args.Count -gt 0 -and [string]$args[0] -in @('status', 'stop', 'messages')) -or $args -contains '--help' -or $args -contains '-h') {
        exit (Invoke-ProcessKitInherited -FilePath $python -ArgumentList ($pythonPrefix + @($runtime) + @($args)))
    }
    $backend = Resolve-OrchestraProcessKitBackend
    if ($backend.Kind -ne 'cli' -or -not $backend.SupportsInheritedStdio) {
        throw 'cc-focus requires processkit-cli with inherited stdio; no uncontained fallback is started.'
    }
    $env:ORCHESTRA_FOCUS_PROCESSKIT_CLI = [string]$backend.Path
    exit (Invoke-OrchestraRootProcess -Work (Join-Path (Get-Location).Path '.work') `
        -Label 'focus' -Interactive -TargetArgv $target)
} catch {
    [Console]::Error.WriteLine("cc-focus: $($_.Exception.Message)")
    exit 3
}
