# Verifies cc-unpause.cmd: it removes an existing PAUSE switch and treats repeated
# removal (including a missing .work directory) as a successful no-op.

. (Join-Path $PSScriptRoot 'common.ps1')

Invoke-Test -Name 'cc-unpause.cmd' -Body {
    # --- Scenario 1: no switch is an idempotent success. ---
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-unpause.cmd'
        $result = Invoke-Launcher -Paths $paths -Name 'cc-unpause.cmd'
        Assert-Equal 0 $result.ExitCode '[absent] exit code'
        Assert-Contains $result.Output '.work\PAUSE does not exist' '[absent] diagnostic'
    }
    finally { Remove-Sandbox $paths }

    # --- Scenario 2: remove a real pause marker, then repeat the request. ---
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-unpause.cmd'
        $work = Join-Path $paths.Project '.work'
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        $pause = Join-Path $work 'PAUSE'
        Set-Content -LiteralPath $pause -Value @('paused_at=2026-07-25T00:00:00Z','reason=operator-visible-marker') -Encoding utf8
        Assert-Contains (Get-Content -LiteralPath $pause -Raw -Encoding utf8) 'reason=operator-visible-marker' '[existing] reason exists before removal'

        $first = Invoke-Launcher -Paths $paths -Name 'cc-unpause.cmd'
        Assert-Equal 0 $first.ExitCode '[existing] exit code'
        Assert-NoFileExists $pause '[existing] PAUSE is removed'
        Assert-Contains $first.Output 'Removed .work\PAUSE' '[existing] removal is reported'

        $second = Invoke-Launcher -Paths $paths -Name 'cc-unpause.cmd'
        Assert-Equal 0 $second.ExitCode '[repeat] exit code'
        Assert-NoFileExists $pause '[repeat] PAUSE remains absent'
        Assert-Contains $second.Output '.work\PAUSE does not exist' '[repeat] no-op is reported'
    }
    finally { Remove-Sandbox $paths }
}
