# Verifies launchers/cc-doctor.cmd: reports codex binary presence/absence,
# reflects CODEX_* keys from .work\config.md (including the CODEX_CMD
# override), and reports KB status. Read-only, never calls claude.
#
# Note: the sandboxed copy of cc-doctor.cmd carries one cosmetic string
# substitution (see common.ps1's $LauncherContentFixups) to work around a
# cmd.exe/PowerShell parsing corruption specific to this environment; it does
# not affect any of the behavior asserted below. See common.ps1 for details.

. (Join-Path $PSScriptRoot 'common.ps1')

Invoke-Test -Name 'cc-doctor.cmd' -Body {
    # --- Scenario 1: codex not on PATH, no .work\config.md -> defaults -----
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-doctor.cmd'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-doctor.cmd' -MinimalPath
        Assert-Equal 0 $result.ExitCode '[no codex, no config] exit code'
        Assert-Contains $result.Output 'NOT FOUND' '[no codex, no config] must report codex missing'
        Assert-Contains $result.Output 'coder_codex will escalate to Claude' '[no codex, no config] must explain the fallback'
        Assert-Contains $result.Output '== KB status' '[no codex, no config] KB status header must print'
        Assert-Contains $result.Output 'KB = off (default)' '[no codex, no config] KB must default to off'
        Assert-Contains $result.Output '.work\knowledge absent' '[no codex, no config] must report absent knowledge dir'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 2: fake codex present on PATH, config.md sets CODEX_* ----
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-doctor.cmd'
        Install-FakeCodex -Paths $paths -Version 'codex-cli 1.2.3-test'

        $workDir = Join-Path $paths.Project '.work'
        New-Item -ItemType Directory -Force -Path $workDir | Out-Null
        @(
            'CODEX_CODER: fast+std'
            'CODEX_REVIEWER: deep'
            'CODEX_MODEL: gpt-5-codex'
            'KB: on'
        ) -join "`n" | Set-Content -LiteralPath (Join-Path $workDir 'config.md') -Encoding utf8

        $kbDir = Join-Path $workDir 'knowledge'
        foreach ($sub in 'architecture', 'conventions', 'pitfalls') {
            New-Item -ItemType Directory -Force -Path (Join-Path $kbDir $sub) | Out-Null
        }
        Set-Content -LiteralPath (Join-Path $kbDir 'pitfalls\p-01.md') -Value '# pitfall' -Encoding utf8

        $result = Invoke-Launcher -Paths $paths -Name 'cc-doctor.cmd'
        Assert-Equal 0 $result.ExitCode '[codex present, config set] exit code'
        Assert-Contains $result.Output 'codex binary : ' '[codex present] must report the resolved binary'
        Assert-Contains $result.Output 'codex-cli 1.2.3-test' '[codex present] must report the fake version string'
        Assert-Contains $result.Output 'CODEX_CODER      = fast+std' '[config] CODEX_CODER must reflect config.md'
        Assert-Contains $result.Output 'CODEX_REVIEWER   = deep' '[config] CODEX_REVIEWER must reflect config.md'
        Assert-Contains $result.Output 'CODEX_MODEL      = gpt-5-codex' '[config] CODEX_MODEL must reflect config.md'
        Assert-Contains $result.Output 'KB = on' '[config] KB must reflect config.md'
        Assert-Contains $result.Output 'pitfalls      = 1 entries' '[config] pitfalls count must reflect the knowledge dir'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 3: CODEX_CODER falls back to the OS environment variable
    # when absent from config.md (documented exception for this one key).
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-doctor.cmd'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-doctor.cmd' -EnvVars @{
            CODEX_CODER = 'fast'
        }
        Assert-Equal 0 $result.ExitCode '[env fallback] exit code'
        Assert-Contains $result.Output 'CODEX_CODER      = fast (env)' '[env fallback] CODEX_CODER must be read from the environment and labeled as such'
    }
    finally {
        Remove-Sandbox $paths
    }
}
