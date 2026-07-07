# Verifies launchers/cc-config.cmd: seeds .work/config.md from the marked
# block of config.example.md when absent, never overwrites an existing
# .work/config.md, and fails gracefully when no template can be found. This
# launcher never calls claude/codex.

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
}
