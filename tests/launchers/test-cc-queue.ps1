# Verifies launchers/cc-queue.cmd: the no-argument branch (asks for a
# source), single-word and multi-word argument forwarding, and the
# double-quote -> single-quote substitution used to keep an embedded quote
# from breaking out of the prompt's own quoting.

. (Join-Path $PSScriptRoot 'common.ps1')

Invoke-Test -Name 'cc-queue.cmd' -Body {
    $expectedMode = Get-ExpectedPermissionMode 'cc-queue.cmd'

    # --- Scenario 1: no arguments -> asks for a source ------------------
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-queue.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-queue.cmd' -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '0'
        }
        Assert-Equal 0 $result.ExitCode '[no args] exit code'

        $expected = @(
            '--agent', 'queue_builder',
            '--permission-mode', $expectedMode,
            'Per your system prompt, ask me for the source (file/spec/backlog) or task description to enqueue into .work/Tasks_Queue.md — none was given on the command line.'
        )
        Assert-ArrayEqual $expected (Get-CapturedArgs $captureFile) '[no args] claude argv'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 2: single argument (file path) -------------------------
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-queue.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-queue.cmd' -LauncherArgs @('docs\roadmap.md') -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '0'
        }
        Assert-Equal 0 $result.ExitCode '[file arg] exit code'

        $expected = @(
            '--agent', 'queue_builder',
            '--permission-mode', $expectedMode,
            'Per your system prompt, add tasks to .work/Tasks_Queue.md. Task source or description: docs\roadmap.md'
        )
        Assert-ArrayEqual $expected (Get-CapturedArgs $captureFile) '[file arg] claude argv'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 3a: multi-word description passed as several separate
    # unquoted tokens (like `cc-queue add rate limiting to the API` typed at
    # a real prompt without surrounding quotes) reconstructs cleanly, with no
    # quote substitution triggered (no `"` ever appears in ARGS).
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-queue.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-queue.cmd' -LauncherArgs @('add', 'rate', 'limiting', 'to', 'the', 'API') -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '0'
        }
        Assert-Equal 0 $result.ExitCode '[multi-word unquoted arg] exit code'

        $expected = @(
            '--agent', 'queue_builder',
            '--permission-mode', $expectedMode,
            'Per your system prompt, add tasks to .work/Tasks_Queue.md. Task source or description: add rate limiting to the API'
        )
        Assert-ArrayEqual $expected (Get-CapturedArgs $captureFile) '[multi-word unquoted arg] claude argv'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 3b: same multi-word description, but passed as a single
    # caller-quoted argument (like `cc-queue "add rate limiting to the API"`,
    # the exact form documented in the launcher's own header comment). ARGS
    # then contains the argv-boundary quotes as literal characters, and the
    # script's own `"='` substitution turns those into visible single quotes
    # around the whole phrase too - this is real, current behavior, not
    # something this test suite invents.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-queue.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-queue.cmd' -LauncherArgs @('add rate limiting to the API') -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '0'
        }
        Assert-Equal 0 $result.ExitCode '[multi-word quoted arg] exit code'

        $expected = @(
            '--agent', 'queue_builder',
            '--permission-mode', $expectedMode,
            "Per your system prompt, add tasks to .work/Tasks_Queue.md. Task source or description: 'add rate limiting to the API'"
        )
        Assert-ArrayEqual $expected (Get-CapturedArgs $captureFile) '[multi-word quoted arg] claude argv'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 4: embedded double quotes are turned into single quotes,
    # including the outer caller-supplied quoting that kept this multi-word
    # argument together as one token (see scenario 3b) - every literal `"`
    # character that reaches ARGS is substituted, with no distinction between
    # an argv-boundary quote and one that was part of the task text.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-queue.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-queue.cmd' -LauncherArgs @('rename the "foo" module') -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '0'
        }
        Assert-Equal 0 $result.ExitCode '[embedded quote] exit code'

        $expected = @(
            '--agent', 'queue_builder',
            '--permission-mode', $expectedMode,
            "Per your system prompt, add tasks to .work/Tasks_Queue.md. Task source or description: 'rename the 'foo' module'"
        )
        Assert-ArrayEqual $expected (Get-CapturedArgs $captureFile) '[embedded quote] double quotes must become single quotes'
    }
    finally {
        Remove-Sandbox $paths
    }
}
