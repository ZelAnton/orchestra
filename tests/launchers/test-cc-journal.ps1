# Verifies launchers/cc-journal.cmd: reports the absence of a journal
# cleanly, and shows only the tail (~40 lines) of an existing one. Never
# calls claude.

. (Join-Path $PSScriptRoot 'common.ps1')

Invoke-Test -Name 'cc-journal.cmd' -Body {
    # --- Scenario 1: no journal yet ----------------------------------------
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-journal.cmd'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-journal.cmd'
        Assert-Equal 0 $result.ExitCode '[no journal] exit code'
        Assert-Contains $result.Output 'no journal yet' '[no journal] must report absence'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 2: small journal -> every line shown ----------------------
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-journal.cmd'
        $workDir = Join-Path $paths.Project '.work'
        New-Item -ItemType Directory -Force -Path $workDir | Out-Null
        1..5 | ForEach-Object { "journal line $_" } | Set-Content -LiteralPath (Join-Path $workDir 'journal.md') -Encoding utf8

        $result = Invoke-Launcher -Paths $paths -Name 'cc-journal.cmd'
        Assert-Equal 0 $result.ExitCode '[small journal] exit code'
        1..5 | ForEach-Object {
            Assert-Contains $result.Output "journal line $_" "[small journal] line $_ must be present"
        }
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 3: large journal -> only the last ~40 lines are shown -----
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-journal.cmd'
        $workDir = Join-Path $paths.Project '.work'
        New-Item -ItemType Directory -Force -Path $workDir | Out-Null
        1..60 | ForEach-Object { "journal line $_" } | Set-Content -LiteralPath (Join-Path $workDir 'journal.md') -Encoding utf8

        $result = Invoke-Launcher -Paths $paths -Name 'cc-journal.cmd'
        Assert-Equal 0 $result.ExitCode '[large journal] exit code'
        # Get-Content -Tail 40 over 60 lines keeps lines 21..60.
        Assert-Contains $result.Output 'journal line 60' '[large journal] last line must be present'
        Assert-Contains $result.Output 'journal line 21' '[large journal] first line of the tail window must be present'
        Assert-True ($result.Output -notlike '*journal line 20*') '[large journal] line just before the tail window must have been trimmed'
    }
    finally {
        Remove-Sandbox $paths
    }
}
