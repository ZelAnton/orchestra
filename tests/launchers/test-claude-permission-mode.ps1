# Verifies the operator-owned Claude permission-mode override across every Windows
# launcher that starts Claude. The default path remains covered by each launcher's
# dedicated suite; this file covers the bypass opt-in and fail-closed validation.

. (Join-Path $PSScriptRoot 'common.ps1')

Invoke-Test -Name 'Claude permission mode override' -Body {
    $launchers = @(
        'cc-audit.cmd',
        'cc-deps.cmd',
        'cc-enhance.cmd',
        'cc-github.cmd',
        'cc-inbox.cmd',
        'cc-processor.cmd',
        'cc-proposal.cmd',
        'cc-queue.cmd',
        'cc-resume.cmd',
        'cc-thinker.cmd'
    )

    foreach ($launcher in $launchers) {
        $paths = New-Sandbox
        try {
            Install-Launcher -Paths $paths -Names $launcher
            Install-FakeClaude -Paths $paths
            $captureFile = Join-Path $paths.Root 'claude-args.txt'
            $result = Invoke-Launcher -Paths $paths -Name $launcher -EnvVars @{
                FAKE_ARGS_FILE = $captureFile
                FAKE_EXIT_CODE = '0'
                ORCHESTRA_CLAUDE_PERMISSION_MODE = 'bypassPermissions'
            }
            Assert-Equal 0 $result.ExitCode "[$launcher bypass] exit code"
            $args = @(Get-CapturedArgs $captureFile)
            $modeIndex = [Array]::IndexOf($args, '--permission-mode')
            Assert-True ($modeIndex -ge 0 -and ($modeIndex + 1) -lt $args.Count) "[$launcher bypass] permission flag exists"
            if ($modeIndex -ge 0 -and ($modeIndex + 1) -lt $args.Count) {
                Assert-Equal 'bypassPermissions' $args[$modeIndex + 1] "[$launcher bypass] effective mode"
            }
        }
        finally { Remove-Sandbox $paths }

        $paths = New-Sandbox
        try {
            Install-Launcher -Paths $paths -Names $launcher
            Install-FakeClaude -Paths $paths
            $captureFile = Join-Path $paths.Root 'claude-args.txt'
            $result = Invoke-Launcher -Paths $paths -Name $launcher -EnvVars @{
                FAKE_ARGS_FILE = $captureFile
                FAKE_EXIT_CODE = '0'
                ORCHESTRA_CLAUDE_PERMISSION_MODE = 'unsafe'
            }
            Assert-Equal 2 $result.ExitCode "[$launcher invalid] exit code"
            Assert-True (@(Get-CapturedArgs $captureFile).Count -eq 0) "[$launcher invalid] Claude must not start"
            Assert-True ($result.Output -like '*Invalid ORCHESTRA_CLAUDE_PERMISSION_MODE*') "[$launcher invalid] diagnostic"
        }
        finally { Remove-Sandbox $paths }
    }

    # The Windows resolver must treat an environment value as data until it has
    # matched an allowed literal. A quote/metacharacter payload previously executed
    # during percent expansion even though the launcher eventually returned exit 2.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-deps.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'
        $injectionMarker = Join-Path $paths.Root 'resolver-injected.txt'
        $payload = 'unsafe" & echo injected>"' + $injectionMarker + '" & rem "'
        $result = Invoke-Launcher -Paths $paths -Name 'cc-deps.cmd' -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '0'
            ORCHESTRA_CLAUDE_PERMISSION_MODE = $payload
        }
        Assert-Equal 2 $result.ExitCode '[metachar invalid] exit code'
        Assert-True (-not (Test-Path -LiteralPath $injectionMarker)) '[metachar invalid] environment value must never execute as cmd text'
        Assert-True (@(Get-CapturedArgs $captureFile).Count -eq 0) '[metachar invalid] Claude must not start'
    }
    finally { Remove-Sandbox $paths }

    # Simple shared-helper launchers historically needed no setlocal. The helper now
    # owns a local scope so its resolved internal variable cannot leak back to a caller.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-deps.cmd'
        Install-FakeClaude -Paths $paths
        $leakMarker = Join-Path $paths.Root 'permission-mode-leaked.txt'
        $probe = Join-Path $paths.Scripts 'probe-permission-scope.cmd'
        $probeText = @"
@echo off
call "%~dp0cc-deps.cmd"
if defined CLAUDE_PERMISSION_MODE echo leaked>"%LEAK_MARKER%"
exit /b %ERRORLEVEL%
"@
        [System.IO.File]::WriteAllText($probe, ($probeText -replace "`r?`n", "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        $result = Invoke-Launcher -Paths $paths -Name 'probe-permission-scope.cmd' -EnvVars @{
            FAKE_ARGS_FILE = (Join-Path $paths.Root 'claude-args.txt')
            FAKE_EXIT_CODE = '0'
            LEAK_MARKER = $leakMarker
            ORCHESTRA_CLAUDE_PERMISSION_MODE = 'bypassPermissions'
        }
        Assert-Equal 0 $result.ExitCode '[scope] wrapper exit code'
        Assert-True (-not (Test-Path -LiteralPath $leakMarker)) '[scope] internal resolved mode must not leak to the calling cmd scope'
    }
    finally { Remove-Sandbox $paths }

    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-common.cmd'
        Remove-Item -LiteralPath (Join-Path $paths.Orchestra 'scripts/config-runtime.ps1') -Force
        $result = Invoke-Launcher -Paths $paths -Name 'cc-common.cmd' `
            -LauncherArgs @('resolve_permission_mode')
        Assert-Equal 12 $result.ExitCode '[config runtime failure] permission resolver exit code'
    }
    finally { Remove-Sandbox $paths }
}
