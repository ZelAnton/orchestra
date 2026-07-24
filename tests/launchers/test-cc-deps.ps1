# Verifies that cc-deps.cmd launches the dedicated dependency curator in auto mode.

. (Join-Path $PSScriptRoot 'common.ps1')

Invoke-Test -Name 'cc-deps.cmd' -Body {
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-deps.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'
        $result = Invoke-Launcher -Paths $paths -Name 'cc-deps.cmd' -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '0'
        }
        Assert-Equal 0 $result.ExitCode 'exit code'
        $expected = @(
            '--agent', 'dependency_curator',
            '--permission-mode', (Get-ExpectedPermissionMode 'cc-deps.cmd'),
            "Per your system prompt, refresh this repository's dependency graph now. MODE=refresh. ROOT=current repository root. WORK=.work. BASE=current committed trunk tip."
        )
        Assert-ArrayEqual $expected (Get-CapturedArgs $captureFile) 'claude argv'
    }
    finally { Remove-Sandbox $paths }
}
