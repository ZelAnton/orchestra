# Verifies launchers/cc-proposal.cmd invokes claude with the expected static
# argument list (agent proposal_curator, permission mode, prompt) and propagates
# its exit code (task T-245).

. (Join-Path $PSScriptRoot 'common.ps1')

Invoke-Test -Name 'cc-proposal.cmd' -Body {
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-proposal.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-proposal.cmd' -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '0'
        }

        Assert-Equal 0 $result.ExitCode 'exit code must be forwarded from claude'

        $expectedMode = Get-ExpectedPermissionMode 'cc-proposal.cmd'
        $expected = @(
            '--agent', 'proposal_curator',
            '--permission-mode', $expectedMode,
            'Per your system prompt, curate the new P-NNN proposals in .work/Tasks_Queue.md and decide one outcome for each proposed proposal. Start now.'
        )
        Assert-ArrayEqual $expected (Get-CapturedArgs $captureFile) 'claude argv'
    }
    finally {
        Remove-Sandbox $paths
    }
}
