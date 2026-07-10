# Verifies launchers/cc-resume.cmd invokes claude with --continue plus the
# expected static argument list, propagates its exit code, and (task T-071)
# exports the CC_CODEX_EXEC_GRANT session-grant signal into claude's environment.

. (Join-Path $PSScriptRoot 'common.ps1')

Invoke-Test -Name 'cc-resume.cmd' -Body {
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-resume.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'
        $envFile = Join-Path $paths.Root 'claude-env.txt'

        # Clear CC_CODEX_EXEC_GRANT in the ambient env so the captured value can
        # only come from the launcher itself (see test-cc-processor.ps1 scenario 7).
        $result = Invoke-Launcher -Paths $paths -Name 'cc-resume.cmd' -EnvVars @{
            FAKE_ARGS_FILE      = $captureFile
            FAKE_ENV_FILE       = $envFile
            FAKE_EXIT_CODE      = '2'
            CC_CODEX_EXEC_GRANT = ''
        }

        Assert-Equal 2 $result.ExitCode 'exit code must be forwarded from claude'

        $expectedMode = Get-ExpectedPermissionMode 'cc-resume.cmd'
        $expected = @(
            '--agent', 'processor',
            '--allowedTools', 'Bash(codex exec:*)',
            '--permission-mode', $expectedMode,
            '--continue',
            "Continue processing .work/Tasks_Queue.md from where you left off, per your system prompt's Фаза 0 recovery logic."
        )
        Assert-ArrayEqual $expected (Get-CapturedArgs $captureFile) 'claude argv'

        # task T-071: the same launcher->processor session-grant contract as
        # cc-processor.cmd - the resumed session must carry the signal too.
        $expectedGrant = Get-ExpectedGrant 'cc-resume.cmd'
        Assert-Equal 'codex exec' $expectedGrant 'launcher source must set CC_CODEX_EXEC_GRANT=codex exec'
        Assert-Equal $expectedGrant (Get-CapturedGrant $envFile) 'claude must inherit CC_CODEX_EXEC_GRANT with the launcher-set value'
    }
    finally {
        Remove-Sandbox $paths
    }
}
