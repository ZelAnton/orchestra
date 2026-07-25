# Verifies cc-metrics.cmd: it finds the mirror metrics runner, preserves argv and
# propagates its exit status, while its missing-runner and missing-pwsh paths fail cleanly.

. (Join-Path $PSScriptRoot 'common.ps1')

function Install-FakeMetrics {
    param([Parameter(Mandatory)] $Paths)
    $script = @'
if ($env:FAKE_METRICS_ARGS) {
    $args | Set-Content -LiteralPath $env:FAKE_METRICS_ARGS -Encoding utf8
}
if ($env:FAKE_METRICS_EXIT) { exit [int]$env:FAKE_METRICS_EXIT }
exit 0
'@
    Set-Content -LiteralPath (Join-Path $Paths.Scripts 'metrics.ps1') -Value $script -Encoding utf8
}

Invoke-Test -Name 'cc-metrics.cmd' -Body {
    # --- Scenario 1: no checkout or mirror runner is an actionable failure. ---
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-metrics.cmd'
        $result = Invoke-Launcher -Paths $paths -Name 'cc-metrics.cmd'
        Assert-Equal 3 $result.ExitCode '[missing runner] exit code'
        Assert-Contains $result.Output 'metrics.ps1 not found' '[missing runner] diagnostic'
    }
    finally { Remove-Sandbox $paths }

    # --- Scenario 2: every digest argument reaches the flat-mirror runner unchanged. ---
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-metrics.cmd'
        Install-FakeMetrics -Paths $paths
        $capture = Join-Path $paths.Root 'metrics-args.txt'
        $metricArgs = @('digest','--work','.work','--since','2026-07-24T00:00:00Z','--until','2026-07-25T00:00:00Z','--json')
        $result = Invoke-Launcher -Paths $paths -Name 'cc-metrics.cmd' -LauncherArgs $metricArgs -EnvVars @{
            FAKE_METRICS_ARGS = $capture
            FAKE_METRICS_EXIT = '23'
        }
        Assert-Equal 23 $result.ExitCode '[forwarding] runner exit code is propagated'
        Assert-ArrayEqual $metricArgs (Get-CapturedArgs $capture) '[forwarding] metrics argv'
    }
    finally { Remove-Sandbox $paths }

    # --- Scenario 3: a runner without pwsh is rejected before it can run. ---
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-metrics.cmd'
        Install-FakeMetrics -Paths $paths
        $result = Invoke-Launcher -Paths $paths -Name 'cc-metrics.cmd' -MinimalPath
        Assert-Equal 3 $result.ExitCode '[missing pwsh] exit code'
        Assert-Contains $result.Output 'pwsh (PowerShell 7) is required' '[missing pwsh] diagnostic'
    }
    finally { Remove-Sandbox $paths }
}
