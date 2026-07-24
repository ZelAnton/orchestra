# Verifies that cc-inbox.cmd launches the dedicated critical inbox curator in auto mode
# with the fixed all-modes prompt.

. (Join-Path $PSScriptRoot 'common.ps1')

Invoke-Test -Name 'cc-inbox.cmd' -Body {
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-inbox.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'
        $result = Invoke-Launcher -Paths $paths -Name 'cc-inbox.cmd' -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '0'
        }
        Assert-Equal 0 $result.ExitCode 'exit code'
        $expected = @(
            '--agent', 'inbox_curator',
            '--permission-mode', (Get-ExpectedPermissionMode 'cc-inbox.cmd'),
            "Per your system prompt, process this repository's cross-project inbox now. MODE=all. queue_write_mode=auto. ROOT=current repository root."
        )
        Assert-ArrayEqual $expected (Get-CapturedArgs $captureFile) 'claude argv'
    }
    finally { Remove-Sandbox $paths }
}
