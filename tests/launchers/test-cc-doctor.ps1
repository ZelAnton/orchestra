# Verifies launchers/cc-doctor.cmd: reports codex binary presence/absence,
# reflects CODEX_* keys from .work\config.md (including the CODEX_CMD
# override), reports KB status, (task T-058) audits the Codex exec-grant
# allow-rule: WARN with a precise hint when CODEX_CODER/CODEX_REVIEWER
# routing is on and no grant is found; OK when a grant is found; OK (no WARN)
# when routing is off even without a grant, and (task T-070) classifies the
# Windows Codex sandbox profile (~\.codex\config.toml's [windows] sandbox) and
# approval_policy for the safe/dangerous/missing/corrupted-config cases. Read-
# only, never calls claude.
#
# Note: the sandboxed copy of cc-doctor.cmd carries one cosmetic string
# substitution (see common.ps1's $LauncherContentFixups) to work around a
# cmd.exe/PowerShell parsing corruption specific to this environment; it does
# not affect any of the behavior asserted below. See common.ps1 for details.

. (Join-Path $PSScriptRoot 'common.ps1')

# Mirrors cc-doctor.cmd's own elevation check exactly, so the "dangerous
# combination" scenario below (task T-070) asserts the correct branch
# regardless of whether the machine actually running this test suite happens
# to have an elevated launcher process (uncommon, but not guaranteed absent -
# e.g. some CI runners execute as an administrative account).
function Test-IsElevated {
    $wp = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

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

    # --- Scenario 4 (task T-070): safe Windows sandbox profile - [windows]
    # sandbox = "unelevated" is confirmed (T-068) to actually isolate, and
    # approval_policy = "never" is confirmed to return a model error instead
    # of escalating a sandbox denial into an unsandboxed run. USERPROFILE is
    # redirected to the sandbox root for this call only (restored by
    # Invoke-Launcher's finally block) so the check reads a fully controlled
    # ~\.codex\config.toml instead of whatever happens to exist on the real
    # machine running this suite.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-doctor.cmd'
        $codexDir = Join-Path $paths.Root '.codex'
        New-Item -ItemType Directory -Force -Path $codexDir | Out-Null
        @(
            'approval_policy = "never"'
            '[windows]'
            'sandbox = "unelevated"'
        ) -join "`n" | Set-Content -LiteralPath (Join-Path $codexDir 'config.toml') -Encoding utf8

        $result = Invoke-Launcher -Paths $paths -Name 'cc-doctor.cmd' -EnvVars @{ USERPROFILE = $paths.Root }
        Assert-Equal 0 $result.ExitCode '[windows sandbox: safe] exit code'
        Assert-Contains $result.Output 'OK   windows sandbox profile: unelevated' '[windows sandbox: safe] must report the unelevated profile as OK'
        Assert-Contains $result.Output 'OK   approval_policy: never' '[windows sandbox: safe] must report approval_policy = never as OK'
        Assert-True ($result.Output -notlike '*FAIL windows sandbox*') '[windows sandbox: safe] must not FAIL'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 5 (task T-070): dangerous combination - [windows] sandbox =
    # "elevated" together with this (normally unelevated) launcher process is
    # confirmed (T-067/T-068) to make Codex's elevated sandbox spawn fail
    # (CreateProcessAsUserW: Access is denied). Raw codex exec would then run
    # unsandboxed, but Orchestra's adapters pin -c approval_policy=never (T-069)
    # so within Orchestra it escalates ENV_LIMIT/sandbox-init and falls back to
    # Claude instead; the FAIL message must say so rather than claim the pipeline
    # runs unsandboxed. The expected severity depends on whether this test
    # process itself happens to be elevated (see Test-IsElevated above).
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-doctor.cmd'
        $codexDir = Join-Path $paths.Root '.codex'
        New-Item -ItemType Directory -Force -Path $codexDir | Out-Null
        @(
            '[windows]'
            'sandbox = "elevated"'
        ) -join "`n" | Set-Content -LiteralPath (Join-Path $codexDir 'config.toml') -Encoding utf8

        $result = Invoke-Launcher -Paths $paths -Name 'cc-doctor.cmd' -EnvVars @{ USERPROFILE = $paths.Root }
        Assert-Equal 0 $result.ExitCode '[windows sandbox: dangerous] exit code'
        if (Test-IsElevated) {
            Assert-Contains $result.Output 'WARN windows sandbox profile: elevated, and this process is currently elevated' '[windows sandbox: dangerous, elevated test process] must WARN, not silently pass'
        } else {
            Assert-Contains $result.Output 'FAIL windows sandbox profile: elevated, but this launcher process is NOT elevated' '[windows sandbox: dangerous] must FAIL and name the CreateProcessAsUserW failure mode'
            Assert-Contains $result.Output 'Orchestra itself does NOT run unsandboxed here' '[windows sandbox: dangerous] must state Orchestra escalates rather than running unsandboxed (post-T-069)'
            Assert-Contains $result.Output 'ENV_LIMIT/sandbox-init' '[windows sandbox: dangerous] must name the sandbox-init escalation the adapters raise'
            Assert-Contains $result.Output 'sandbox = unelevated' '[windows sandbox: dangerous] must offer a concrete config-only fix'
        }
        Assert-Contains $result.Output 'WARN approval_policy: not set' '[windows sandbox: dangerous] approval_policy is unset in this config and must WARN'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 6 (task T-070): absent config.toml - cannot verify the
    # Windows sandbox profile at all; must WARN, not silently say nothing and
    # not crash.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-doctor.cmd'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-doctor.cmd' -EnvVars @{ USERPROFILE = $paths.Root }
        Assert-Equal 0 $result.ExitCode '[windows sandbox: missing config] exit code'
        Assert-Contains $result.Output 'WARN windows sandbox profile:' '[windows sandbox: missing config] must print a WARN line for the sandbox profile'
        Assert-Contains $result.Output 'sandbox not set, or config.toml missing/unreadable' '[windows sandbox: missing config] must WARN that it cannot verify isolation'
        Assert-Contains $result.Output 'WARN approval_policy: not set' '[windows sandbox: missing config] approval_policy must also WARN as not set'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 7 (task T-070): present but corrupted/unparseable
    # config.toml (recognized section, garbled values) - must not crash and
    # must fall back to the "cannot verify" WARN for both the sandbox profile
    # and approval_policy, naming the unrecognized value.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-doctor.cmd'
        $codexDir = Join-Path $paths.Root '.codex'
        New-Item -ItemType Directory -Force -Path $codexDir | Out-Null
        @(
            'approval_policy = totally-bogus'
            '[windows]'
            'sandbox = totally-bogus'
        ) -join "`n" | Set-Content -LiteralPath (Join-Path $codexDir 'config.toml') -Encoding utf8

        $result = Invoke-Launcher -Paths $paths -Name 'cc-doctor.cmd' -EnvVars @{ USERPROFILE = $paths.Root }
        Assert-Equal 0 $result.ExitCode '[windows sandbox: corrupted config] exit code'
        Assert-Contains $result.Output 'WARN windows sandbox profile: unrecognized' '[windows sandbox: corrupted config] must WARN about an unrecognized sandbox value'
        Assert-Contains $result.Output 'sandbox value (totally-bogus)' '[windows sandbox: corrupted config] must show the unrecognized value'
        Assert-Contains $result.Output 'WARN approval_policy: totally-bogus' '[windows sandbox: corrupted config] approval_policy must WARN with the unrecognized value shown'
    }
    finally {
        Remove-Sandbox $paths
    }
}
