# Verifies launchers/cc-thinker.cmd: the no-argument branch (generic greeting
# prompt) and the opening-topic argument forwarding (including the same
# quote-substitution behavior as cc-queue.cmd).

. (Join-Path $PSScriptRoot 'common.ps1')

Invoke-Test -Name 'cc-thinker.cmd' -Body {
    $expectedMode = Get-ExpectedPermissionMode 'cc-thinker.cmd'

    # --- Scenario 1: no arguments -----------------------------------------
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-thinker.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-thinker.cmd' -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '0'
        }
        Assert-Equal 0 $result.ExitCode '[no args] exit code'

        $expected = @(
            '--agent', 'thinker',
            '--permission-mode', $expectedMode,
            'Per your system prompt: act as the analytical thinking partner for this project. Greet me briefly, then ask what I want to explore or build. Analyze it with me and, once we agree on concrete work, enqueue it into .work/Tasks_Queue.md per your instructions.'
        )
        Assert-ArrayEqual $expected (Get-CapturedArgs $captureFile) '[no args] claude argv'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 2a: opening topic passed as several separate unquoted
    # tokens - reconstructs cleanly, no quote substitution triggered.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-thinker.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-thinker.cmd' -LauncherArgs @('should', 'we', 'add', 'a', 'caching', 'layer?') -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '0'
        }
        Assert-Equal 0 $result.ExitCode '[topic unquoted arg] exit code'

        $expected = @(
            '--agent', 'thinker',
            '--permission-mode', $expectedMode,
            "Per your system prompt: act as the analytical thinking partner for this project. Opening topic: should we add a caching layer?"
        )
        Assert-ArrayEqual $expected (Get-CapturedArgs $captureFile) '[topic unquoted arg] claude argv'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 2b: same topic, passed as a single caller-quoted argument
    # (like `cc-thinker "should we add a caching layer?"`). Same
    # argv-boundary-quotes-become-visible-single-quotes behavior as
    # cc-queue.cmd, since both scripts share the same escaping logic.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-thinker.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-thinker.cmd' -LauncherArgs @('should we add a caching layer?') -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '0'
        }
        Assert-Equal 0 $result.ExitCode '[topic quoted arg] exit code'

        $expected = @(
            '--agent', 'thinker',
            '--permission-mode', $expectedMode,
            "Per your system prompt: act as the analytical thinking partner for this project. Opening topic: 'should we add a caching layer?'"
        )
        Assert-ArrayEqual $expected (Get-CapturedArgs $captureFile) '[topic quoted arg] claude argv'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 3: embedded double quotes are turned into single quotes,
    # including the outer caller-supplied quoting (see cc-queue.cmd scenario
    # 3b/4 for the detailed explanation - both scripts share this logic).
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-thinker.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-thinker.cmd' -LauncherArgs @('what about the "queue" module?') -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '0'
        }
        Assert-Equal 0 $result.ExitCode '[embedded quote] exit code'

        $expected = @(
            '--agent', 'thinker',
            '--permission-mode', $expectedMode,
            "Per your system prompt: act as the analytical thinking partner for this project. Opening topic: 'what about the 'queue' module?'"
        )
        Assert-ArrayEqual $expected (Get-CapturedArgs $captureFile) '[embedded quote] double quotes must become single quotes'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 4: a literal "!" character in the argument must survive
    # untouched (regression coverage for the cc-common.cmd:sanitize helper
    # eating "!" via a second, unwanted delayed-expansion pass when the
    # sanitized value was relayed back through "endlocal & set VAR=%TMP%" -
    # see T-037 review finding R-01). Single word, no spaces, so PowerShell
    # passes it through as one unquoted argv token and no quote substitution
    # is triggered - isolates the "!" handling from the quote-substitution
    # behavior covered by the scenarios above.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-thinker.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-thinker.cmd' -LauncherArgs @('foo!bar!baz') -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '0'
        }
        Assert-Equal 0 $result.ExitCode '[bang arg] exit code'

        $expected = @(
            '--agent', 'thinker',
            '--permission-mode', $expectedMode,
            'Per your system prompt: act as the analytical thinking partner for this project. Opening topic: foo!bar!baz'
        )
        Assert-ArrayEqual $expected (Get-CapturedArgs $captureFile) '[bang arg] every "!" must be preserved literally'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 5: same "!" preservation, but for a multi-word argument
    # passed as a single caller-quoted token (like `cc-thinker "fix bug
    # ASAP!"`), which - per scenario 2b above - reaches ARGS wrapped in the
    # argv-boundary quotes and so also exercises the quote-substitution path
    # together with "!" in the same value.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-thinker.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-thinker.cmd' -LauncherArgs @('fix bug ASAP!') -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '0'
        }
        Assert-Equal 0 $result.ExitCode '[bang quoted arg] exit code'

        $expected = @(
            '--agent', 'thinker',
            '--permission-mode', $expectedMode,
            "Per your system prompt: act as the analytical thinking partner for this project. Opening topic: 'fix bug ASAP!'"
        )
        Assert-ArrayEqual $expected (Get-CapturedArgs $captureFile) '[bang quoted arg] trailing "!" must be preserved literally'
    }
    finally {
        Remove-Sandbox $paths
    }
}
