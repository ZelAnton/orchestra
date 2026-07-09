# Verifies launchers/cc-doctor.cmd: reports codex binary presence/absence,
# reflects CODEX_* keys from .work\config.md (including the CODEX_CMD
# override), reports KB status, and (task T-058) audits the Codex exec-grant
# allow-rule: WARN with a precise hint when CODEX_CODER/CODEX_REVIEWER
# routing is on and no grant is found; OK when a grant is found; OK (no WARN)
# when routing is off even without a grant. Read-only, never calls claude.
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

        # Explicitly clear CODEX_CODER/CODEX_REVIEWER: this scenario asserts the
        # "routing off" path, which must not be flaky depending on whatever the
        # ambient shell environment happens to have set for real Codex usage.
        $result = Invoke-Launcher -Paths $paths -Name 'cc-doctor.cmd' -MinimalPath -EnvVars @{ CODEX_CODER = ''; CODEX_REVIEWER = '' }
        Assert-Equal 0 $result.ExitCode '[no codex, no config] exit code'
        Assert-Contains $result.Output 'NOT FOUND' '[no codex, no config] must report codex missing'
        Assert-Contains $result.Output 'coder_codex will escalate to Claude' '[no codex, no config] must explain the fallback'
        Assert-Contains $result.Output '== KB status' '[no codex, no config] KB status header must print'
        Assert-Contains $result.Output 'KB = off (default)' '[no codex, no config] KB must default to off'
        Assert-Contains $result.Output '.work\knowledge absent' '[no codex, no config] must report absent knowledge dir'
        Assert-Contains $result.Output 'OK   exec permission: not found, but not required' '[no codex, no config] no grant + routing off must be OK, not WARN'
        Assert-True ($result.Output -notlike '*WARN exec permission*') '[no codex, no config] must not WARN when CODEX_CODER/CODEX_REVIEWER are both off'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 1b: Codex routing is on (CODEX_CODER) but no exec-grant
    # exists anywhere -> WARN with a precise hint (task T-058).
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-doctor.cmd'
        $workDir = Join-Path $paths.Project '.work'
        New-Item -ItemType Directory -Force -Path $workDir | Out-Null
        Set-Content -LiteralPath (Join-Path $workDir 'config.md') -Value 'CODEX_CODER: fast' -Encoding utf8

        $result = Invoke-Launcher -Paths $paths -Name 'cc-doctor.cmd'
        Assert-Equal 0 $result.ExitCode '[routing on, no grant] exit code'
        Assert-Contains $result.Output 'WARN exec permission: NOT found' '[routing on, no grant] must WARN'
        Assert-Contains $result.Output 'Bash(codex exec *)' '[routing on, no grant] WARN must name the missing rule'
        Assert-Contains $result.Output 'cc-config' '[routing on, no grant] WARN must point at cc-config'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 1c: Codex routing is on and the exec-grant is present in
    # .claude/settings.local.json -> OK, no WARN (task T-058).
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-doctor.cmd'
        $workDir = Join-Path $paths.Project '.work'
        New-Item -ItemType Directory -Force -Path $workDir | Out-Null
        Set-Content -LiteralPath (Join-Path $workDir 'config.md') -Value 'CODEX_REVIEWER: fast+std' -Encoding utf8
        $claudeDir = Join-Path $paths.Project '.claude'
        New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
        Set-Content -LiteralPath (Join-Path $claudeDir 'settings.local.json') -Value '{"permissions":{"allow":["Bash(codex exec *)"]}}' -Encoding utf8

        $result = Invoke-Launcher -Paths $paths -Name 'cc-doctor.cmd'
        Assert-Equal 0 $result.ExitCode '[routing on, grant present] exit code'
        Assert-Contains $result.Output 'OK   exec permission: allow-rule for codex exec present' '[routing on, grant present] must report OK'
        Assert-True ($result.Output -notlike '*WARN exec permission*') '[routing on, grant present] must not WARN once a grant exists'
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
