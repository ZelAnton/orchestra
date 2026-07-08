# Verifies launchers/cc-github.cmd invokes claude with the expected static
# argument list (agent, permission mode - no predefined prompt, waits for the
# task in chat) and propagates its exit code.

. (Join-Path $PSScriptRoot 'common.ps1')

Invoke-Test -Name 'cc-github.cmd' -Body {
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-github.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-github.cmd' -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '1'
        }

        Assert-Equal 1 $result.ExitCode 'exit code must be forwarded from claude'

        $expectedMode = Get-ExpectedPermissionMode 'cc-github.cmd'
        $expected = @(
            '--agent', 'github_sync',
            '--permission-mode', $expectedMode
        )
        Assert-ArrayEqual $expected (Get-CapturedArgs $captureFile) 'claude argv'
    }
    finally {
        Remove-Sandbox $paths
    }
}
