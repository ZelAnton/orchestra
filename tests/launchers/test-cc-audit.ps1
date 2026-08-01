# Verifies launchers/cc-audit.cmd invokes claude with the expected static
# argument list (agent, permission mode, prompt) and propagates its exit code.

. (Join-Path $PSScriptRoot 'common.ps1')

Invoke-Test -Name 'cc-audit.cmd' -Body {
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-audit.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-audit.cmd' -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '7'
        }

        Assert-Equal 7 $result.ExitCode 'exit code must be forwarded from claude'

        $expectedMode = Get-ExpectedPermissionMode 'cc-audit.cmd'
        $expected = @(
            '--agent', 'code_auditor',
            '--permission-mode', $expectedMode,
            'Per your system prompt, audit the repository source code and enqueue each issue you find as a separate task in .work/Tasks_Queue.md. Start now.'
        )
        Assert-ArrayEqual $expected (Get-CapturedArgs $captureFile) 'claude argv'
    }
    finally {
        Remove-Sandbox $paths
    }

    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-audit.cmd'
        Install-FakeCodex -Paths $paths
        $captureFile = Join-Path $paths.Root 'codex-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-audit.cmd' `
            -LauncherArgs @('codex') -EnvVars @{
                FAKE_ARGS_FILE = $captureFile
                FAKE_EXIT_CODE = '8'
                ORCHESTRA_PROVIDER = 'claude'
            }
        Assert-Equal 8 $result.ExitCode 'codex exit code must be forwarded'
        $captured = @(Get-CapturedArgs $captureFile)
        Assert-True (-not ($captured -contains 'exec')) 'codex path opens TUI instead of codex exec'
        Assert-True (-not ($captured -contains '--json')) 'codex path does not expose JSONL'
        Assert-True ([string]$captured[-1] -match 'agents[\\/]code_auditor\.md') 'codex bootstrap points to canonical code_auditor prompt'
    }
    finally {
        Remove-Sandbox $paths
    }
}
