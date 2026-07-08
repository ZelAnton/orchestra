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
}
