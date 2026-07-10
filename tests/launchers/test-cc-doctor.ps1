# Verifies launchers/cc-doctor.cmd: reports codex binary presence/absence,
# reflects CODEX_* keys from .work\config.md (including the CODEX_CMD
# override), reports KB status, (task T-058, F-05) audits the Codex runtime
# allow-rule: WARN with a precise hint (naming Bash(pwsh -File tools/codex-runtime.ps1 *))
# when CODEX_CODER/CODEX_REVIEWER routing is on and no grant is found; OK when the
# runtime-wrapper allow-rule is found; OK (no WARN) when routing is off even without a
# grant, and (task T-070) classifies the Windows Codex sandbox profile
# (~\.codex\config.toml's [windows] sandbox) and approval_policy for the
# safe/dangerous/missing/corrupted-config cases. (task T-071, F-05) additionally covers
# the reconciled permission classification: session-only (CC_CODEX_EXEC_GRANT covers the
# command, no settings rule), deny-only (a runtime-wrapper match only in permissions.deny
# must not count), CI-fix-only (CODEX_CIFIX=on alone keeps the gate active), and custom
# CODEX_CMD with only the codex exec anchor (still WARN - the anchor does not authorize the
# runtime command) vs. with the runtime-wrapper rule (OK - it covers any CODEX_CMD).
# (task T-072) also covers the Codex value validation: an all-valid config
# reports the all-valid OK line and prints the now-included effective
# CODEX_NETWORK, and an invalid value for each of the six value-constrained keys
# (incl. danger-full-access for CODEX_SANDBOX) is classified as a FAIL naming the
# key/value/allowed set rather than silently defaulted. Read-only, never calls
# claude.
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

        # Clear the ambient session-grant signal so this asserts the static-settings
        # path (routing on, no grant anywhere -> WARN), not a session-grant OK.
        # USERPROFILE is redirected to the sandbox so the machine's real
        # ~/.claude/settings.json cannot inject a stray allow-rule into the search.
        $result = Invoke-Launcher -Paths $paths -Name 'cc-doctor.cmd' -EnvVars @{ CC_CODEX_EXEC_GRANT = ''; USERPROFILE = $paths.Root }
        Assert-Equal 0 $result.ExitCode '[routing on, no grant] exit code'
        Assert-Contains $result.Output 'WARN exec permission: NOT found' '[routing on, no grant] must WARN'
        Assert-Contains $result.Output 'Bash(pwsh -File tools/codex-runtime.ps1 *)' '[routing on, no grant] WARN must name the missing runtime-wrapper rule'
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
        Set-Content -LiteralPath (Join-Path $claudeDir 'settings.local.json') -Value '{"permissions":{"allow":["Bash(pwsh -File tools/codex-runtime.ps1 *)"]}}' -Encoding utf8

        # Clear the ambient session-grant signal so this asserts the static-settings
        # allow-rule path specifically, not a session-grant OK. USERPROFILE is
        # redirected so only the project settings.local.json created here is read.
        $result = Invoke-Launcher -Paths $paths -Name 'cc-doctor.cmd' -EnvVars @{ CC_CODEX_EXEC_GRANT = ''; USERPROFILE = $paths.Root }
        Assert-Equal 0 $result.ExitCode '[routing on, grant present] exit code'
        Assert-Contains $result.Output 'OK   exec permission: allow-rule for the codex runtime' '[routing on, grant present] must report OK'
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

    # --- Scenario 8 (task T-071): session-only - Codex routing is on and the
    # session carries the launcher grant signal (CC_CODEX_EXEC_GRANT covers the
    # command), with NO persistent settings allow-rule anywhere -> OK via session
    # grant, no WARN. This is the exact case the pre-T-071 gate would falsely block.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-doctor.cmd'
        $workDir = Join-Path $paths.Project '.work'
        New-Item -ItemType Directory -Force -Path $workDir | Out-Null
        Set-Content -LiteralPath (Join-Path $workDir 'config.md') -Value 'CODEX_CODER: fast' -Encoding utf8

        $result = Invoke-Launcher -Paths $paths -Name 'cc-doctor.cmd' -EnvVars @{ CC_CODEX_EXEC_GRANT = 'codex exec'; USERPROFILE = $paths.Root }
        Assert-Equal 0 $result.ExitCode '[session-only] exit code'
        Assert-Contains $result.Output 'OK   exec permission: session grant present' '[session-only] must report OK via the session grant, not require a settings rule'
        Assert-True ($result.Output -notlike '*WARN exec permission*') '[session-only] must not WARN when the session grant covers the command'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 9 (task T-071): deny-only - the runtime-wrapper rule appears ONLY in
    # permissions.deny (plus an unrelated allow entry), with routing on and no
    # session grant. The strict permissions.allow-only parse must NOT treat the
    # deny match as a grant -> stays a WARN, never a false OK.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-doctor.cmd'
        $workDir = Join-Path $paths.Project '.work'
        New-Item -ItemType Directory -Force -Path $workDir | Out-Null
        Set-Content -LiteralPath (Join-Path $workDir 'config.md') -Value 'CODEX_CODER: fast' -Encoding utf8
        $claudeDir = Join-Path $paths.Project '.claude'
        New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
        Set-Content -LiteralPath (Join-Path $claudeDir 'settings.local.json') -Value '{"permissions":{"deny":["Bash(pwsh -File tools/codex-runtime.ps1 *)"],"allow":["Read(*)"]}}' -Encoding utf8

        $result = Invoke-Launcher -Paths $paths -Name 'cc-doctor.cmd' -EnvVars @{ CC_CODEX_EXEC_GRANT = ''; USERPROFILE = $paths.Root }
        Assert-Equal 0 $result.ExitCode '[deny-only] exit code'
        Assert-Contains $result.Output 'WARN exec permission: NOT found' '[deny-only] a runtime-wrapper match in permissions.deny must NOT be accepted as a grant'
        Assert-True ($result.Output -notlike '*OK   exec permission: allow-rule*') '[deny-only] must not falsely report an allow-rule OK from a deny match'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 10 (task T-071): CI-fix-only - only CODEX_CIFIX is on;
    # CODEX_CODER and CODEX_REVIEWER are off. The gate necessity is the union of
    # all three routes, so it must still be active (WARN when no grant), not
    # skipped as "all off". CODEX_CODER/CODEX_REVIEWER are cleared in the env so
    # the ambient machine's real Codex settings cannot make this flaky.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-doctor.cmd'
        $workDir = Join-Path $paths.Project '.work'
        New-Item -ItemType Directory -Force -Path $workDir | Out-Null
        Set-Content -LiteralPath (Join-Path $workDir 'config.md') -Value 'CODEX_CIFIX: on' -Encoding utf8

        $result = Invoke-Launcher -Paths $paths -Name 'cc-doctor.cmd' -EnvVars @{
            CODEX_CODER         = ''
            CODEX_REVIEWER      = ''
            CC_CODEX_EXEC_GRANT = ''
            USERPROFILE         = $paths.Root
        }
        Assert-Equal 0 $result.ExitCode '[CI-fix-only] exit code'
        Assert-Contains $result.Output 'WARN exec permission: NOT found' '[CI-fix-only] CODEX_CIFIX=on alone must keep the gate active (WARN when no grant)'
        Assert-True ($result.Output -notlike '*not found, but not required*') '[CI-fix-only] must NOT treat routing as off when only CODEX_CIFIX is on'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 11 (F-05): custom command, only the historical codex exec anchor -
    # CODEX_CMD is non-canonical and the ONLY settings rule is Bash(codex exec *), which
    # does NOT cover the actual adapter command (the runtime wrapper the adapters really
    # run - the codex child process the runtime spawns never crosses the Bash gate). The
    # gate must NOT emit a false OK off the anchor; it must WARN naming the runtime rule.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-doctor.cmd'
        $workDir = Join-Path $paths.Project '.work'
        New-Item -ItemType Directory -Force -Path $workDir | Out-Null
        @('CODEX_CODER: fast', 'CODEX_CMD: my-codex') -join "`n" | Set-Content -LiteralPath (Join-Path $workDir 'config.md') -Encoding utf8
        $claudeDir = Join-Path $paths.Project '.claude'
        New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
        Set-Content -LiteralPath (Join-Path $claudeDir 'settings.local.json') -Value '{"permissions":{"allow":["Bash(codex exec *)"]}}' -Encoding utf8

        $result = Invoke-Launcher -Paths $paths -Name 'cc-doctor.cmd' -EnvVars @{ CC_CODEX_EXEC_GRANT = ''; USERPROFILE = $paths.Root }
        Assert-Equal 0 $result.ExitCode '[custom cmd, anchor only] exit code'
        Assert-Contains $result.Output 'WARN exec permission: NOT found' '[custom cmd, anchor only] the codex exec anchor alone must NOT authorize the runtime command'
        Assert-Contains $result.Output 'Bash(pwsh -File tools/codex-runtime.ps1 *)' '[custom cmd, anchor only] WARN must name the missing runtime-wrapper rule'
        Assert-True ($result.Output -notlike '*OK   exec permission: allow-rule*') '[custom cmd, anchor only] codex exec anchor must NOT yield a false OK'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 12 (F-05): custom command WITH the runtime-wrapper rule - since the
    # adapters run `pwsh -File tools/codex-runtime.ps1` regardless of CODEX_CMD (it is
    # only a --codex-cmd argument, not a separate Bash command), the single runtime-wrapper
    # allow-rule covers the custom command too, so the gate correctly reports OK - no
    # per-CODEX_CMD rule is needed.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-doctor.cmd'
        $workDir = Join-Path $paths.Project '.work'
        New-Item -ItemType Directory -Force -Path $workDir | Out-Null
        @('CODEX_CODER: fast', 'CODEX_CMD: my-codex') -join "`n" | Set-Content -LiteralPath (Join-Path $workDir 'config.md') -Encoding utf8
        $claudeDir = Join-Path $paths.Project '.claude'
        New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
        Set-Content -LiteralPath (Join-Path $claudeDir 'settings.local.json') -Value '{"permissions":{"allow":["Bash(pwsh -File tools/codex-runtime.ps1 *)"]}}' -Encoding utf8

        $result = Invoke-Launcher -Paths $paths -Name 'cc-doctor.cmd' -EnvVars @{ CC_CODEX_EXEC_GRANT = ''; USERPROFILE = $paths.Root }
        Assert-Equal 0 $result.ExitCode '[custom cmd, runtime rule] exit code'
        Assert-Contains $result.Output 'OK   exec permission: allow-rule for the codex runtime' '[custom cmd, runtime rule] the runtime rule covers any CODEX_CMD -> OK'
        Assert-True ($result.Output -notlike '*WARN exec permission*') '[custom cmd, runtime rule] must not WARN when the runtime rule exists'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 13 (task T-072): all six value-constrained Codex keys set to
    # VALID values -> the new "Codex key value validation" section reports the
    # all-valid OK line (no FAIL), and the effective-CODEX_* summary now prints
    # CODEX_NETWORK (previously absent). CODEX_NETWORK is set to its non-default
    # (off) to prove the summary reflects config.md rather than a hardcoded value.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-doctor.cmd'
        $workDir = Join-Path $paths.Project '.work'
        New-Item -ItemType Directory -Force -Path $workDir | Out-Null
        @(
            'CODEX_CODER: fast+std'
            'CODEX_REVIEWER: deep'
            'CODEX_CIFIX: on'
            'CODEX_REASONING: high'
            'CODEX_SANDBOX: read-only'
            'CODEX_NETWORK: off'
        ) -join "`n" | Set-Content -LiteralPath (Join-Path $workDir 'config.md') -Encoding utf8

        $result = Invoke-Launcher -Paths $paths -Name 'cc-doctor.cmd' -EnvVars @{ CC_CODEX_EXEC_GRANT = ''; USERPROFILE = $paths.Root }
        Assert-Equal 0 $result.ExitCode '[all valid] exit code'
        Assert-Contains $result.Output 'OK   Codex key values: all set values are within their allowed sets' '[all valid] must report the all-valid OK line'
        Assert-True ($result.Output -notlike '*FAIL CODEX_*invalid value*') '[all valid] must not emit any invalid-value FAIL'
        Assert-True ([regex]::IsMatch($result.Output, 'CODEX_NETWORK\s+=\s+off')) '[all valid] effective summary must now print CODEX_NETWORK from config.md'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 14 (task T-072): an INVALID value for each of the six
    # value-constrained keys (a typo / wrong variant, incl. danger-full-access
    # for CODEX_SANDBOX - the security-critical case) must be classified as a
    # FAIL naming the key, the actual bad value and the allowed set - never
    # silently replaced by a default (the all-valid OK line must be absent).
    # CODEX_CODER/CODEX_REVIEWER env is cleared so the ambient machine's real
    # Codex settings cannot make the config-only cases flaky.
    $badValues = [ordered]@{
        'CODEX_CODER'     = @{ Bad = 'fastest';            Allowed = 'off | fast | fast+std' }
        'CODEX_REVIEWER'  = @{ Bad = 'deeep';              Allowed = 'off | fast | fast+std | deep' }
        'CODEX_CIFIX'     = @{ Bad = 'yes';                Allowed = 'off | on' }
        'CODEX_REASONING' = @{ Bad = 'huge';               Allowed = 'auto | low | medium | high' }
        'CODEX_SANDBOX'   = @{ Bad = 'danger-full-access'; Allowed = 'read-only | workspace-write' }
        'CODEX_NETWORK'   = @{ Bad = 'enabled';            Allowed = 'on | off' }
    }
    foreach ($key in $badValues.Keys) {
        $paths = New-Sandbox
        try {
            Install-Launcher -Paths $paths -Names 'cc-doctor.cmd'
            $workDir = Join-Path $paths.Project '.work'
            New-Item -ItemType Directory -Force -Path $workDir | Out-Null
            $bad = $badValues[$key].Bad
            Set-Content -LiteralPath (Join-Path $workDir 'config.md') -Value ("{0}: {1}" -f $key, $bad) -Encoding utf8

            $result = Invoke-Launcher -Paths $paths -Name 'cc-doctor.cmd' -EnvVars @{
                CODEX_CODER         = ''
                CODEX_REVIEWER      = ''
                CC_CODEX_EXEC_GRANT = ''
                USERPROFILE         = $paths.Root
            }
            Assert-Equal 0 $result.ExitCode "[invalid $key] exit code"
            Assert-Contains $result.Output ("FAIL {0}: invalid value '{1}'" -f $key, $bad) "[invalid $key] must FAIL naming the key and the actual bad value"
            Assert-Contains $result.Output ("allowed: {0}" -f $badValues[$key].Allowed) "[invalid $key] must list the allowed set"
            Assert-True ($result.Output -notlike '*OK   Codex key values: all set values are within their allowed sets*') "[invalid $key] must not report the all-valid OK line (no silent default substitution)"
        }
        finally {
            Remove-Sandbox $paths
        }
    }
}
