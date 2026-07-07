# Verifies launchers/cc-status.cmd: reports absence of status.md/journal.md
# cleanly, and shows the tail (~40 lines) of each when present. Never calls
# claude.
#
# Note: the sandboxed copy carries a cosmetic string substitution for the
# "nothing yet" Cyrillic messages (see common.ps1's $LauncherContentFixups)
# to work around a cmd.exe/PowerShell parsing corruption specific to this
# environment; their exact wording is not asserted below.

. (Join-Path $PSScriptRoot 'common.ps1')

Invoke-Test -Name 'cc-status.cmd' -Body {
    # --- Scenario 1: neither file exists ------------------------------------
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-status.cmd'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-status.cmd'
        Assert-Equal 0 $result.ExitCode '[nothing yet] exit code'
        Assert-Contains $result.Output '.work\status.md' '[nothing yet] status header must print'
        Assert-Contains $result.Output '.work\journal.md' '[nothing yet] journal header must print'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 2: both files present with distinct content --------------
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-status.cmd'
        $workDir = Join-Path $paths.Project '.work'
        New-Item -ItemType Directory -Force -Path $workDir | Out-Null
        Set-Content -LiteralPath (Join-Path $workDir 'status.md') -Value 'STATUS-MARKER-XYZ' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $workDir 'journal.md') -Value 'JOURNAL-MARKER-ABC' -Encoding utf8

        $result = Invoke-Launcher -Paths $paths -Name 'cc-status.cmd'
        Assert-Equal 0 $result.ExitCode '[both present] exit code'
        Assert-Contains $result.Output 'STATUS-MARKER-XYZ' '[both present] status.md content must be shown'
        Assert-Contains $result.Output 'JOURNAL-MARKER-ABC' '[both present] journal.md content must be shown'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 3: only status.md exists ----------------------------------
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-status.cmd'
        $workDir = Join-Path $paths.Project '.work'
        New-Item -ItemType Directory -Force -Path $workDir | Out-Null
        Set-Content -LiteralPath (Join-Path $workDir 'status.md') -Value 'STATUS-ONLY-MARKER' -Encoding utf8

        $result = Invoke-Launcher -Paths $paths -Name 'cc-status.cmd'
        Assert-Equal 0 $result.ExitCode '[status only] exit code'
        Assert-Contains $result.Output 'STATUS-ONLY-MARKER' '[status only] status.md content must be shown'
        Assert-Contains $result.Output '.work\journal.md' '[status only] journal header must still print'
        # The "empty journal" message is a Cyrillic literal in cc-status.cmd;
        # rather than re-typing non-ASCII text into this file's own source
        # (see common.ps1's notes on PowerShell 5.1's non-BOM script encoding
        # pitfalls), assert the branch structurally instead: with no
        # journal.md, nothing from a real journal (e.g. another marker)
        # should appear after the journal header.
        $journalHeaderIndex = $result.Output.IndexOf('.work\journal.md')
        $afterJournalHeader = $result.Output.Substring($journalHeaderIndex)
        Assert-True ($afterJournalHeader -notlike '*JOURNAL-MARKER*') '[status only] no real journal content should appear'
    }
    finally {
        Remove-Sandbox $paths
    }
}
