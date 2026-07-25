# Verifies cc-pause.cmd: it creates the PAUSE kill switch, retains the operator
# reason, and is safe to repeat without changing the pause semantic.

. (Join-Path $PSScriptRoot 'common.ps1')

Invoke-Test -Name 'cc-pause.cmd' -Body {
    # --- Scenario 1: a bare pause creates the control file without a reason. ---
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-pause.cmd'
        $result = Invoke-Launcher -Paths $paths -Name 'cc-pause.cmd'
        $pause = Join-Path $paths.Project '.work\PAUSE'
        Assert-Equal 0 $result.ExitCode '[bare pause] exit code'
        Assert-FileExists $pause '[bare pause] PAUSE is created'
        $text = Get-Content -LiteralPath $pause -Raw -Encoding utf8
        Assert-True ($text -match '^paused_at=\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z') '[bare pause] UTC timestamp is recorded'
        Assert-True ($text -notmatch '(?m)^reason=') '[bare pause] no synthetic reason is written'
    }
    finally { Remove-Sandbox $paths }

    # --- Scenario 2: reason text is visible to the operator and stays so after a repeat. ---
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-pause.cmd'
        $pause = Join-Path $paths.Project '.work\PAUSE'
        $reason = @('planned','operator','maintenance')
        $first = Invoke-Launcher -Paths $paths -Name 'cc-pause.cmd' -LauncherArgs $reason
        Assert-Equal 0 $first.ExitCode '[reason] first exit code'
        Assert-FileExists $pause '[reason] PAUSE is created'
        Assert-Contains (Get-Content -LiteralPath $pause -Raw -Encoding utf8) 'reason=planned operator maintenance' '[reason] reason is preserved'

        $second = Invoke-Launcher -Paths $paths -Name 'cc-pause.cmd' -LauncherArgs $reason
        Assert-Equal 0 $second.ExitCode '[repeat] exit code'
        Assert-FileExists $pause '[repeat] PAUSE remains present'
        Assert-Contains (Get-Content -LiteralPath $pause -Raw -Encoding utf8) 'reason=planned operator maintenance' '[repeat] reason remains visible'
    }
    finally { Remove-Sandbox $paths }
}
