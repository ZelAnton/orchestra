# Verifies launchers/cc-config.cmd: seeds .work/config.md from the marked
# block of config.example.md when absent, never overwrites an existing
# .work/config.md, and fails gracefully when no template can be found. Also
# verifies the .claude/settings.local.json Codex exec-grant allow-list
# (task T-058): created (with the canonical allow-rule) only when absent;
# an existing file is never modified, and missing canonical rule(s) are
# printed instead; a file that already grants codex exec is left unchanged
# and reported OK. This launcher never calls claude/codex.

. (Join-Path $PSScriptRoot 'common.ps1')

Invoke-Test -Name 'cc-config.cmd' -Body {
    # --- Scenario 1: fresh project, template present (flat mirror layout,
    # i.e. config.example.md sits right next to cc-config.cmd - the fallback
    # path cc-config.cmd uses when running from the ~/.claude/scripts mirror).
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-config.cmd'
        Install-ConfigExample -Paths $paths

        $result = Invoke-Launcher -Paths $paths -Name 'cc-config.cmd'
        Assert-Equal 0 $result.ExitCode '[fresh] exit code'

        $configPath = Join-Path $paths.Project '.work\config.md'
        Assert-FileExists $configPath '[fresh] .work/config.md must be created'
        $content = Get-Content -LiteralPath $configPath -Raw

        Assert-Contains $content 'MAX_PARALLEL: 5' '[fresh] first seed line must be present'
        Assert-Contains $content 'CODEX_SANDBOX: workspace-write' '[fresh] last seed line must be present'
        Assert-True ($content -notlike '*config.md seed start*') '[fresh] start marker must not be copied'
        Assert-True ($content -notlike '*config.md seed end*') '[fresh] end marker must not be copied'
        Assert-Contains $result.Output 'Created .work\config.md' '[fresh] success message printed'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 2: .work/config.md already exists -> must not be touched ---
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-config.cmd'
        Install-ConfigExample -Paths $paths
        $workDir = Join-Path $paths.Project '.work'
        New-Item -ItemType Directory -Force -Path $workDir | Out-Null
        $configPath = Join-Path $workDir 'config.md'
        Set-Content -LiteralPath $configPath -Value 'MY_CUSTOM_KEY: yes' -Encoding utf8

        $result = Invoke-Launcher -Paths $paths -Name 'cc-config.cmd'
        Assert-Equal 0 $result.ExitCode '[existing] exit code'

        $content = Get-Content -LiteralPath $configPath -Raw
        Assert-Contains $content 'MY_CUSTOM_KEY: yes' '[existing] file content must be left untouched'
        Assert-True ($content -notlike '*MAX_PARALLEL*') '[existing] template must not be applied over an existing file'
        Assert-Contains $result.Output 'already exists' '[existing] launcher must report the file already exists'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 3: no template reachable anywhere -> fails gracefully,
    # no .work/config.md is created.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-config.cmd'
        # deliberately do not Install-ConfigExample

        $result = Invoke-Launcher -Paths $paths -Name 'cc-config.cmd'
        Assert-Equal 0 $result.ExitCode '[missing template] launcher itself still exits cleanly'

        $configPath = Join-Path $paths.Project '.work\config.md'
        Assert-NoFileExists $configPath '[missing template] .work/config.md must not be created'
        Assert-Contains $result.Output 'Failed to create .work\config.md' '[missing template] failure message printed'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 4: no .claude/settings.local.json yet -> created with the
    # canonical Codex exec-grant allow-rule.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-config.cmd'
        Install-ConfigExample -Paths $paths

        $result = Invoke-Launcher -Paths $paths -Name 'cc-config.cmd'
        Assert-Equal 0 $result.ExitCode '[settings: fresh] exit code'

        $settingsPath = Join-Path $paths.Project '.claude\settings.local.json'
        Assert-FileExists $settingsPath '[settings: fresh] .claude/settings.local.json must be created'
        $settingsContent = Get-Content -LiteralPath $settingsPath -Raw
        Assert-Contains $settingsContent 'Bash(codex exec *)' '[settings: fresh] canonical allow-rule must be present'
        Assert-Contains $result.Output 'Created .claude\settings.local.json' '[settings: fresh] success message printed'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 5: .claude/settings.local.json already exists without the
    # allow-rule -> left completely unchanged; missing rule(s) reported instead.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-config.cmd'
        Install-ConfigExample -Paths $paths
        $claudeDir = Join-Path $paths.Project '.claude'
        New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
        $settingsPath = Join-Path $claudeDir 'settings.local.json'
        $original = '{"permissions":{"allow":["Bash(git status)"]}}'
        Set-Content -LiteralPath $settingsPath -Value $original -Encoding utf8 -NoNewline

        $result = Invoke-Launcher -Paths $paths -Name 'cc-config.cmd'
        Assert-Equal 0 $result.ExitCode '[settings: existing, missing rule] exit code'

        $settingsContent = Get-Content -LiteralPath $settingsPath -Raw
        Assert-Equal $original $settingsContent '[settings: existing, missing rule] file must be left byte-for-byte unchanged'
        Assert-Contains $result.Output 'already exists - left unchanged' '[settings: existing, missing rule] must report the file was not touched'
        Assert-Contains $result.Output 'Bash(codex exec *)' '[settings: existing, missing rule] must list the missing canonical rule'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 6: .claude/settings.local.json already exists and already
    # grants codex exec -> left unchanged, reported OK, no "missing" wording.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-config.cmd'
        Install-ConfigExample -Paths $paths
        $claudeDir = Join-Path $paths.Project '.claude'
        New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
        $settingsPath = Join-Path $claudeDir 'settings.local.json'
        $original = '{"permissions":{"allow":["Bash(codex exec *)"]}}'
        Set-Content -LiteralPath $settingsPath -Value $original -Encoding utf8 -NoNewline

        $result = Invoke-Launcher -Paths $paths -Name 'cc-config.cmd'
        Assert-Equal 0 $result.ExitCode '[settings: existing, already granted] exit code'

        $settingsContent = Get-Content -LiteralPath $settingsPath -Raw
        Assert-Equal $original $settingsContent '[settings: existing, already granted] file must be left byte-for-byte unchanged'
        Assert-Contains $result.Output 'OK   .claude\settings.local.json already allows codex exec' '[settings: existing, already granted] must report OK unchanged'
    }
    finally {
        Remove-Sandbox $paths
    }
}
