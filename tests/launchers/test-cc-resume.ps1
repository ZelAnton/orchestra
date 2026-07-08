# Verifies launchers/cc-resume.cmd invokes claude with --continue plus the
# expected static argument list, and propagates its exit code.

. (Join-Path $PSScriptRoot 'common.ps1')

Invoke-Test -Name 'cc-resume.cmd' -Body {
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-resume.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-resume.cmd' -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '2'
        }

        Assert-Equal 2 $result.ExitCode 'exit code must be forwarded from claude'

        $expectedMode = Get-ExpectedPermissionMode 'cc-resume.cmd'
        $expected = @(
            '--agent', 'processor',
            '--permission-mode', $expectedMode,
            '--continue',
            "Continue processing .work/Tasks_Queue.md from where you left off, per your system prompt's Фаза 0 recovery logic."
        )
        Assert-ArrayEqual $expected (Get-CapturedArgs $captureFile) 'claude argv'
    }
    finally {
        Remove-Sandbox $paths
    }
}
