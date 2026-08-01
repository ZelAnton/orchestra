# Verifies launchers/cc-thinker.cmd: the no-argument branch (bare launch, no
# predefined prompt - waits for the task in chat) and the opening-topic
# argument forwarding (including the same quote-substitution behavior as
# cc-queue.cmd).

. (Join-Path $PSScriptRoot 'common.ps1')

Invoke-Test -Name 'cc-thinker.cmd' -Body {
    $expectedMode = Get-ExpectedPermissionMode 'cc-thinker.cmd'

    # --- Scenario 1: no arguments -> bare launch, no predefined prompt ---
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
            '--permission-mode', $expectedMode
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

    # --- Scenario 6: an explicit codex provider token is consumed and starts the
    # normal interactive Codex CLI (not `codex exec --json`). The remaining argv is
    # preserved as the opening topic in the short role bootstrap.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-thinker.cmd'
        Install-FakeCodex -Paths $paths
        $captureFile = Join-Path $paths.Root 'codex-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-thinker.cmd' `
            -LauncherArgs @('codex', 'should', 'we', 'split', 'the', 'runtime?') -EnvVars @{
                FAKE_ARGS_FILE = $captureFile
                FAKE_EXIT_CODE = '9'
                ORCHESTRA_PROVIDER = 'claude'
            }
        Assert-Equal 9 $result.ExitCode '[codex provider] exit code'

        $captured = @(Get-CapturedArgs $captureFile)
        Assert-True (-not ($captured -contains 'exec')) '[codex provider] must open TUI, not codex exec'
        Assert-True (-not ($captured -contains '--json')) '[codex provider] must not select JSON output'
        Assert-True ($captured -contains '-C') '[codex provider] project root must be pinned'
        $bootstrap = [string]$captured[-1]
        Assert-True ($bootstrap -match 'agents[\\/]thinker\.md') '[codex provider] bootstrap points to canonical thinker prompt'
        Assert-True ($bootstrap -match 'should we split the runtime\?') '[codex provider] remaining arguments become the opening topic'
        Assert-True ($bootstrap -notmatch 'topic: codex\b') '[codex provider] provider token is not part of the topic'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 7: the long provider form is also consumed by the Codex runtime.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-thinker.cmd'
        Install-FakeCodex -Paths $paths
        $captureFile = Join-Path $paths.Root 'codex-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-thinker.cmd' `
            -LauncherArgs @('--provider', 'codex', 'review', 'the', 'queue') -EnvVars @{
                FAKE_ARGS_FILE = $captureFile
                FAKE_EXIT_CODE = '0'
            }
        Assert-Equal 0 $result.ExitCode '[long codex provider] exit code'
        $bootstrap = [string](Get-CapturedArgs $captureFile)[-1]
        Assert-True ($bootstrap -match 'review the queue') '[long codex provider] opening topic is preserved'
        Assert-True ($bootstrap -notmatch 'topic: (--provider|codex)\b') '[long codex provider] selector is not part of the topic'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 8: an explicit Claude override is stripped from the opening topic.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-thinker.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-thinker.cmd' `
            -LauncherArgs @('--provider', 'claude', 'review', 'the', 'queue') -EnvVars @{
                FAKE_ARGS_FILE = $captureFile
                FAKE_EXIT_CODE = '0'
                ORCHESTRA_PROVIDER = 'codex'
            }
        Assert-Equal 0 $result.ExitCode '[explicit claude provider] exit code'
        $expected = @(
            '--agent', 'thinker',
            '--permission-mode', $expectedMode,
            'Per your system prompt: act as the analytical thinking partner for this project. Opening topic: review the queue'
        )
        Assert-ArrayEqual $expected (Get-CapturedArgs $captureFile) '[explicit claude provider] selector is consumed'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 9: under the environment-selected provider, an opening topic may
    # legitimately begin with the word "codex"; it must not be consumed as a selector.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-thinker.cmd'
        Install-FakeCodex -Paths $paths
        $captureFile = Join-Path $paths.Root 'codex-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-thinker.cmd' `
            -LauncherArgs @('codex design tradeoffs') -EnvVars @{
                FAKE_ARGS_FILE = $captureFile
                FAKE_EXIT_CODE = '0'
                ORCHESTRA_PROVIDER = 'codex'
            }
        Assert-Equal 0 $result.ExitCode '[environment codex topic] exit code'
        $bootstrap = [string](Get-CapturedArgs $captureFile)[-1]
        Assert-True ($bootstrap -match 'codex design tradeoffs') '[environment codex topic] leading codex word remains topic data'
    }
    finally {
        Remove-Sandbox $paths
    }
}
