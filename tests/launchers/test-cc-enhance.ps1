# Verifies launchers/cc-enhance.cmd invokes claude with the expected static
# argument list (agent, permission mode, prompt) and propagates its exit code.

. (Join-Path $PSScriptRoot 'common.ps1')

Invoke-Test -Name 'cc-enhance.cmd' -Body {
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-enhance.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-enhance.cmd' -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '0'
        }

        Assert-Equal 0 $result.ExitCode 'exit code must be forwarded from claude'

        $expectedMode = Get-ExpectedPermissionMode 'cc-enhance.cmd'
        $expected = @(
            '--agent', 'enhancement_scout',
            '--permission-mode', $expectedMode,
            'Per your system prompt, analyze the project and enqueue development/improvement proposals as separate tasks in .work/Tasks_Queue.md. Start now.'
        )
        Assert-ArrayEqual $expected (Get-CapturedArgs $captureFile) 'claude argv'
    }
    finally {
        Remove-Sandbox $paths
    }

    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-enhance.cmd'
        Install-FakeCodex -Paths $paths
        $captureFile = Join-Path $paths.Root 'codex-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-enhance.cmd' -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '6'
            ORCHESTRA_PROVIDER = 'codex'
        }
        Assert-Equal 6 $result.ExitCode 'ORCHESTRA_PROVIDER=codex exit code must be forwarded'
        $captured = @(Get-CapturedArgs $captureFile)
        Assert-True (-not ($captured -contains 'exec')) 'system codex default opens TUI instead of codex exec'
        Assert-True (-not ($captured -contains '--json')) 'system codex default does not expose JSONL'
        Assert-True ([string]$captured[-1] -match 'agents[\\/]enhancement_scout\.md') 'codex bootstrap points to canonical enhancement_scout prompt'
    }
    finally {
        Remove-Sandbox $paths
    }

    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-enhance.cmd'
        Install-FakeClaude -Paths $paths
        Remove-Item -LiteralPath (Join-Path $paths.Orchestra 'scripts/config-runtime.ps1') -Force
        $captureFile = Join-Path $paths.Root 'claude-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-enhance.cmd' -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '0'
        }
        Assert-Equal 12 $result.ExitCode 'provider resolver must propagate a config runtime failure'
        Assert-True (@(Get-CapturedArgs $captureFile).Count -eq 0) 'provider resolver failure must not start Claude'
    }
    finally {
        Remove-Sandbox $paths
    }
}
