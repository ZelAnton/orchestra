# Verifies launchers/cc-config.cmd: seeds .work/config.md from the marked
# block of config.example.md when absent, never overwrites an existing
# .work/config.md, and fails gracefully when no template can be found. Also
# verifies the .claude/settings.local.json Codex allow-list (tasks T-058/T-078,
# F-05, extended by T-114): created with ALL THREE canonical allow-rules - the
# runtime wrapper in its checkout form Bash(pwsh -File tools/codex-runtime.ps1 *)
# and its mirror form Bash(pwsh -File ~/.claude/scripts/codex-runtime.ps1 *) the
# adapters actually run (one or the other, depending on layout), plus the
# historical Bash(codex exec *) anchor - when absent; when the file exists but
# lacks a canonical rule, the missing rule(s) are MERGED into permissions.allow
# add-only (other keys / existing allow entries preserved) and the merge is
# idempotent on a re-run; a file that already grants all three is left unchanged
# and reported OK; and degenerate cases (invalid JSON, a read-only/unwritable
# file) leave the file untouched and fall back to printing the rule(s) to add by
# hand. This launcher never calls claude/codex.

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
        Assert-Contains $settingsContent 'Bash(pwsh -File tools/codex-runtime.ps1 *)' '[settings: fresh] checkout-form runtime-wrapper allow-rule (the actual adapter command) must be present'
        Assert-Contains $settingsContent 'Bash(pwsh -File ~/.claude/scripts/codex-runtime.ps1 *)' '[settings: fresh] mirror-form runtime-wrapper allow-rule (T-114) must be present'
        Assert-Contains $settingsContent 'Bash(codex exec *)' '[settings: fresh] historical codex exec anchor rule must be present'
        Assert-Contains $result.Output 'Created .claude\settings.local.json' '[settings: fresh] success message printed'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 5: .claude/settings.local.json exists WITHOUT the allow-rule
    # (plus an unrelated allow entry and other keys) -> the canonical rule is
    # MERGED into permissions.allow add-only; every other key / existing entry is
    # preserved (task T-078 restored the auto-merge that T-058 had removed).
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-config.cmd'
        Install-ConfigExample -Paths $paths
        $claudeDir = Join-Path $paths.Project '.claude'
        New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
        $settingsPath = Join-Path $claudeDir 'settings.local.json'
        $original = '{"permissions":{"allow":["Bash(git status)"],"deny":["Bash(rm *)"]},"otherKey":true}'
        Set-Content -LiteralPath $settingsPath -Value $original -Encoding utf8 -NoNewline

        $result = Invoke-Launcher -Paths $paths -Name 'cc-config.cmd'
        Assert-Equal 0 $result.ExitCode '[settings: merge] exit code'
        Assert-Contains $result.Output 'Merged allow-rule(s) into .claude\settings.local.json' '[settings: merge] must report the rule was merged'

        $merged = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        Assert-True ([bool](@($merged.permissions.allow) -contains 'Bash(pwsh -File tools/codex-runtime.ps1 *)')) '[settings: merge] canonical checkout-form runtime-wrapper rule must be added to permissions.allow'
        Assert-True ([bool](@($merged.permissions.allow) -contains 'Bash(pwsh -File ~/.claude/scripts/codex-runtime.ps1 *)')) '[settings: merge] canonical mirror-form runtime-wrapper rule (T-114) must be added to permissions.allow'
        Assert-True ([bool](@($merged.permissions.allow) -contains 'Bash(codex exec *)')) '[settings: merge] canonical codex exec anchor rule must be added to permissions.allow'
        Assert-True ([bool](@($merged.permissions.allow) -contains 'Bash(git status)')) '[settings: merge] pre-existing allow entry must be preserved'
        Assert-True ([bool](@($merged.permissions.deny) -contains 'Bash(rm *)')) '[settings: merge] pre-existing deny entry must be preserved'
        Assert-Equal $true $merged.otherKey '[settings: merge] unrelated top-level key must be preserved'
        Assert-Equal 4 (@($merged.permissions.allow).Count) '[settings: merge] allow must have the pre-existing entry plus all three canonical rules (no duplication)'
        # A leftover temp file must never remain after a successful merge.
        Assert-NoFileExists ($settingsPath + '.tmp') '[settings: merge] no temp file must be left behind'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 6: .claude/settings.local.json already exists and already
    # grants codex exec -> left unchanged, reported OK, no "merge" wording.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-config.cmd'
        Install-ConfigExample -Paths $paths
        $claudeDir = Join-Path $paths.Project '.claude'
        New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
        $settingsPath = Join-Path $claudeDir 'settings.local.json'
        $original = '{"permissions":{"allow":["Bash(pwsh -File tools/codex-runtime.ps1 *)","Bash(pwsh -File ~/.claude/scripts/codex-runtime.ps1 *)","Bash(codex exec *)"]}}'
        Set-Content -LiteralPath $settingsPath -Value $original -Encoding utf8 -NoNewline

        $result = Invoke-Launcher -Paths $paths -Name 'cc-config.cmd'
        Assert-Equal 0 $result.ExitCode '[settings: existing, already granted] exit code'

        $settingsContent = Get-Content -LiteralPath $settingsPath -Raw
        Assert-Equal $original $settingsContent '[settings: existing, already granted] file must be left byte-for-byte unchanged'
        Assert-Contains $result.Output 'OK   .claude\settings.local.json already grants autonomous codex' '[settings: existing, already granted] must report OK unchanged'
        Assert-True ($result.Output -notlike '*Merged*') '[settings: existing, already granted] must not claim a merge happened'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 7: idempotency - running the launcher again after a merge is a
    # no-op that reports OK and leaves the file byte-for-byte identical.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-config.cmd'
        Install-ConfigExample -Paths $paths
        $claudeDir = Join-Path $paths.Project '.claude'
        New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
        $settingsPath = Join-Path $claudeDir 'settings.local.json'
        Set-Content -LiteralPath $settingsPath -Value '{"permissions":{"allow":["Bash(git status)"]}}' -Encoding utf8 -NoNewline

        $first = Invoke-Launcher -Paths $paths -Name 'cc-config.cmd'
        Assert-Equal 0 $first.ExitCode '[settings: idempotent] first run exit code'
        Assert-Contains $first.Output 'Merged allow-rule(s)' '[settings: idempotent] first run merges the rule'
        $afterFirst = Get-Content -LiteralPath $settingsPath -Raw

        $second = Invoke-Launcher -Paths $paths -Name 'cc-config.cmd'
        Assert-Equal 0 $second.ExitCode '[settings: idempotent] second run exit code'
        Assert-Contains $second.Output 'OK   .claude\settings.local.json already grants autonomous codex' '[settings: idempotent] second run is a no-op reported OK'
        $afterSecond = Get-Content -LiteralPath $settingsPath -Raw
        Assert-Equal $afterFirst $afterSecond '[settings: idempotent] second run must not change the file'
        $parsed = $afterSecond | ConvertFrom-Json
        Assert-Equal 4 (@($parsed.permissions.allow).Count) '[settings: idempotent] pre-existing entry plus all three canonical rules, not duplicated on re-run'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 8: existing file that is not valid JSON -> cannot merge; the
    # file is left untouched and the rule to add by hand is printed (no silent
    # no-op, no clobbering the operator's file).
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-config.cmd'
        Install-ConfigExample -Paths $paths
        $claudeDir = Join-Path $paths.Project '.claude'
        New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
        $settingsPath = Join-Path $claudeDir 'settings.local.json'
        $original = '{ this is not valid json '
        Set-Content -LiteralPath $settingsPath -Value $original -Encoding utf8 -NoNewline

        $result = Invoke-Launcher -Paths $paths -Name 'cc-config.cmd'
        Assert-Equal 0 $result.ExitCode '[settings: invalid json] exit code'
        $settingsContent = Get-Content -LiteralPath $settingsPath -Raw
        Assert-Equal $original $settingsContent '[settings: invalid json] file must be left byte-for-byte unchanged'
        Assert-Contains $result.Output 'not valid JSON' '[settings: invalid json] must report the file is not valid JSON'
        Assert-Contains $result.Output 'Bash(codex exec *)' '[settings: invalid json] must print the rule to add by hand'
        Assert-Contains $result.Output 'Bash(pwsh -File ~/.claude/scripts/codex-runtime.ps1 *)' '[settings: invalid json] must also print the mirror-form rule (T-114) to add by hand'
        Assert-True ($result.Output -notlike '*Merged*') '[settings: invalid json] must not claim a merge happened'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 9: existing valid file missing the rule but marked read-only ->
    # the merge cannot be written; the file is left untouched and the fallback
    # instruction is printed (write failure is not a silent no-op).
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-config.cmd'
        Install-ConfigExample -Paths $paths
        $claudeDir = Join-Path $paths.Project '.claude'
        New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
        $settingsPath = Join-Path $claudeDir 'settings.local.json'
        $original = '{"permissions":{"allow":["Bash(git status)"]}}'
        Set-Content -LiteralPath $settingsPath -Value $original -Encoding utf8 -NoNewline
        Set-ItemProperty -LiteralPath $settingsPath -Name IsReadOnly -Value $true

        $result = Invoke-Launcher -Paths $paths -Name 'cc-config.cmd'
        # Clear the read-only bit right away so cleanup (and the read below) work
        # regardless of whether any assertion throws.
        Set-ItemProperty -LiteralPath $settingsPath -Name IsReadOnly -Value $false

        Assert-Equal 0 $result.ExitCode '[settings: read-only] exit code'
        $settingsContent = Get-Content -LiteralPath $settingsPath -Raw
        Assert-Equal $original $settingsContent '[settings: read-only] file must be left byte-for-byte unchanged'
        Assert-Contains $result.Output 'could not be written' '[settings: read-only] must report the file could not be written'
        Assert-Contains $result.Output 'Bash(codex exec *)' '[settings: read-only] must print the rule to add by hand'
        Assert-Contains $result.Output 'Bash(pwsh -File ~/.claude/scripts/codex-runtime.ps1 *)' '[settings: read-only] must also print the mirror-form rule (T-114) to add by hand'
        Assert-NoFileExists ($settingsPath + '.tmp') '[settings: read-only] no temp file must be left behind'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 10: existing file is an empty JSON object {} -> permissions and
    # permissions.allow are created and the rule is merged in.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-config.cmd'
        Install-ConfigExample -Paths $paths
        $claudeDir = Join-Path $paths.Project '.claude'
        New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
        $settingsPath = Join-Path $claudeDir 'settings.local.json'
        Set-Content -LiteralPath $settingsPath -Value '{}' -Encoding utf8 -NoNewline

        $result = Invoke-Launcher -Paths $paths -Name 'cc-config.cmd'
        Assert-Equal 0 $result.ExitCode '[settings: empty object] exit code'
        Assert-Contains $result.Output 'Merged allow-rule(s)' '[settings: empty object] must report the rule was merged'
        $merged = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        Assert-True ([bool](@($merged.permissions.allow) -contains 'Bash(pwsh -File tools/codex-runtime.ps1 *)')) '[settings: empty object] checkout-form runtime-wrapper rule must be present under permissions.allow'
        Assert-True ([bool](@($merged.permissions.allow) -contains 'Bash(pwsh -File ~/.claude/scripts/codex-runtime.ps1 *)')) '[settings: empty object] mirror-form runtime-wrapper rule (T-114) must be present under permissions.allow'
        Assert-True ([bool](@($merged.permissions.allow) -contains 'Bash(codex exec *)')) '[settings: empty object] codex exec anchor rule must be present under permissions.allow'
        Assert-Equal 3 (@($merged.permissions.allow).Count) '[settings: empty object] allow must contain exactly the three canonical rules'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 11: existing file has a permissions object but no allow key
    # (only a deny list) -> allow is created, the rule merged in, deny preserved.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-config.cmd'
        Install-ConfigExample -Paths $paths
        $claudeDir = Join-Path $paths.Project '.claude'
        New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
        $settingsPath = Join-Path $claudeDir 'settings.local.json'
        Set-Content -LiteralPath $settingsPath -Value '{"permissions":{"deny":["Bash(rm *)"]}}' -Encoding utf8 -NoNewline

        $result = Invoke-Launcher -Paths $paths -Name 'cc-config.cmd'
        Assert-Equal 0 $result.ExitCode '[settings: no allow key] exit code'
        Assert-Contains $result.Output 'Merged allow-rule(s)' '[settings: no allow key] must report the rule was merged'
        $merged = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        Assert-True ([bool](@($merged.permissions.allow) -contains 'Bash(pwsh -File tools/codex-runtime.ps1 *)')) '[settings: no allow key] checkout-form runtime-wrapper rule must be added under a new permissions.allow'
        Assert-True ([bool](@($merged.permissions.allow) -contains 'Bash(pwsh -File ~/.claude/scripts/codex-runtime.ps1 *)')) '[settings: no allow key] mirror-form runtime-wrapper rule (T-114) must be added under a new permissions.allow'
        Assert-True ([bool](@($merged.permissions.allow) -contains 'Bash(codex exec *)')) '[settings: no allow key] codex exec anchor rule must be added under a new permissions.allow'
        Assert-True ([bool](@($merged.permissions.deny) -contains 'Bash(rm *)')) '[settings: no allow key] pre-existing deny list must be preserved'
    }
    finally {
        Remove-Sandbox $paths
    }
}
