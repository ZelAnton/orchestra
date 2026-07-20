# Verifies launchers/cc-processor.cmd argument parsing: --force-lock removal,
# --model with/without a value, EXTRA_ARGS passthrough (and ordering relative
# to --permission-mode), and exit-code propagation.

. (Join-Path $PSScriptRoot 'common.ps1')

Invoke-Test -Name 'cc-processor.cmd' -Body {
    $expectedMode = Get-ExpectedPermissionMode 'cc-processor.cmd'

    # --- Scenario 1: no arguments at all -------------------------------
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-processor.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-processor.cmd' -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '0'
        }
        Assert-Equal 0 $result.ExitCode '[no args] exit code'

        $expected = @(
            '--agent', 'processor',
            '--allowedTools', 'Bash(codex exec:*)', 'Bash(pwsh -File tools/codex-runtime.ps1:*)',
            '--permission-mode', $expectedMode,
            'Start now, following your system prompt: take the orchestrator lock, then process .work/Tasks_Queue.md end to end — capture batches of parallel-safe tasks, plan them, implement in parallel worktrees, review, merge via the merger, and publish (ff-merge + push + CI), looping until no not-started tasks remain. Report progress as you go.'
        )
        Assert-ArrayEqual $expected (Get-CapturedArgs $captureFile) '[no args] claude argv'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 2: --model with a value -------------------------------
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-processor.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-processor.cmd' -LauncherArgs @('--model', 'opus-9000') -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '0'
        }
        Assert-Equal 0 $result.ExitCode '[--model value] exit code'

        $args = Get-CapturedArgs $captureFile
        Assert-True ($args.Count -ge 9) '[--model value] enough tokens captured'
        Assert-ArrayEqual @('--agent', 'processor', '--model', 'opus-9000', '--allowedTools', 'Bash(codex exec:*)', 'Bash(pwsh -File tools/codex-runtime.ps1:*)', '--permission-mode', $expectedMode) $args[0..8] '[--model value] --model must precede --permission-mode with its value forwarded'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 3: trailing --model with no value is ignored, not eaten ---
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-processor.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-processor.cmd' -LauncherArgs @('--model') -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '0'
        }
        Assert-Equal 0 $result.ExitCode '[--model no value] exit code'

        $expected = @(
            '--agent', 'processor',
            '--allowedTools', 'Bash(codex exec:*)', 'Bash(pwsh -File tools/codex-runtime.ps1:*)',
            '--permission-mode', $expectedMode,
            'Start now, following your system prompt: take the orchestrator lock, then process .work/Tasks_Queue.md end to end — capture batches of parallel-safe tasks, plan them, implement in parallel worktrees, review, merge via the merger, and publish (ff-merge + push + CI), looping until no not-started tasks remain. Report progress as you go.'
        )
        Assert-ArrayEqual $expected (Get-CapturedArgs $captureFile) '[--model no value] --model must be dropped entirely, not consume the prompt'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 4: EXTRA_ARGS passthrough, positioned before --permission-mode ---
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-processor.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-processor.cmd' -LauncherArgs @('--model', 'foo', '--verbose', '--extra-flag') -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '0'
        }
        Assert-Equal 0 $result.ExitCode '[extra args] exit code'

        $expected = @(
            '--agent', 'processor',
            '--model', 'foo',
            '--verbose', '--extra-flag',
            '--allowedTools', 'Bash(codex exec:*)', 'Bash(pwsh -File tools/codex-runtime.ps1:*)',
            '--permission-mode', $expectedMode,
            'Start now, following your system prompt: take the orchestrator lock, then process .work/Tasks_Queue.md end to end — capture batches of parallel-safe tasks, plan them, implement in parallel worktrees, review, merge via the merger, and publish (ff-merge + push + CI), looping until no not-started tasks remain. Report progress as you go.'
        )
        Assert-ArrayEqual $expected (Get-CapturedArgs $captureFile) '[extra args] claude argv must interleave --model and EXTRA_ARGS before --permission-mode'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 5: --force-lock removes an existing lock directory --------
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-processor.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'
        $lockDir = Join-Path $paths.Project '.work\orchestrator.lock'
        New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
        Set-Content -LiteralPath (Join-Path $lockDir 'holder.txt') -Value 'stale' -Encoding utf8

        $result = Invoke-Launcher -Paths $paths -Name 'cc-processor.cmd' -LauncherArgs @('--force-lock') -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '0'
        }
        Assert-Equal 0 $result.ExitCode '[--force-lock] exit code'
        Assert-NoFileExists $lockDir '[--force-lock] lock directory must be removed before launching claude'

        $expected = @(
            '--agent', 'processor',
            '--allowedTools', 'Bash(codex exec:*)', 'Bash(pwsh -File tools/codex-runtime.ps1:*)',
            '--permission-mode', $expectedMode,
            'Start now, following your system prompt: take the orchestrator lock, then process .work/Tasks_Queue.md end to end — capture batches of parallel-safe tasks, plan them, implement in parallel worktrees, review, merge via the merger, and publish (ff-merge + push + CI), looping until no not-started tasks remain. Report progress as you go.'
        )
        Assert-ArrayEqual $expected (Get-CapturedArgs $captureFile) '[--force-lock] --force-lock itself must not leak into claude argv'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 6: --force-lock with no existing lock does not error ------
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-processor.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-processor.cmd' -LauncherArgs @('--force-lock') -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '0'
        }
        Assert-Equal 0 $result.ExitCode '[--force-lock, no lock present] exit code'
        Assert-True ((Get-CapturedArgs $captureFile).Count -gt 0) '[--force-lock, no lock present] claude must still be invoked'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 7 (task T-071): the launcher exports CC_CODEX_EXEC_GRANT
    # into claude's environment - the explicit, verifiable session-grant signal
    # the processor's Phase 1.1 gate reads instead of requiring a persistent
    # settings allow-rule. Its value is the canonical granted codex command prefix
    # ("codex exec"), which the Phase 1.1 gate / cc-doctor compare against the
    # adapters' "<CODEX_CMD> exec" prefix; the actually-executed Bash string is the
    # runtime wrapper, granted separately via "Bash(pwsh -File tools/codex-runtime.ps1:*)".
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-processor.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'
        $envFile = Join-Path $paths.Root 'claude-env.txt'

        # Deliberately clear CC_CODEX_EXEC_GRANT in the ambient env first so the
        # captured value can only come from the launcher itself, not from whatever
        # the machine running the tests happens to have set.
        $result = Invoke-Launcher -Paths $paths -Name 'cc-processor.cmd' -EnvVars @{
            FAKE_ARGS_FILE      = $captureFile
            FAKE_ENV_FILE       = $envFile
            FAKE_EXIT_CODE      = '0'
            CC_CODEX_EXEC_GRANT = ''
            BASH_DEFAULT_TIMEOUT_MS = ''
            BASH_MAX_TIMEOUT_MS = ''
        }
        Assert-Equal 0 $result.ExitCode '[session grant] exit code'

        $expectedGrant = Get-ExpectedGrant 'cc-processor.cmd'
        Assert-Equal 'codex exec' $expectedGrant '[session grant] launcher source must set CC_CODEX_EXEC_GRANT=codex exec'
        Assert-Equal $expectedGrant (Get-CapturedGrant $envFile) '[session grant] claude must inherit CC_CODEX_EXEC_GRANT with the launcher-set value'
        Assert-Equal '1' (Get-CapturedEnvValue $envFile 'MSBUILDDISABLENODEREUSE') '[process containment] claude must inherit disabled MSBuild node reuse'
        Assert-Equal '0' (Get-CapturedEnvValue $envFile 'DOTNET_CLI_USE_MSBUILD_SERVER') '[process containment] claude must inherit disabled MSBuild server use'
        Assert-Equal '1900000' (Get-CapturedEnvValue $envFile 'BASH_DEFAULT_TIMEOUT_MS') '[foreground codex] launcher raises Claude Bash default timeout'
        Assert-Equal '1900000' (Get-CapturedEnvValue $envFile 'BASH_MAX_TIMEOUT_MS') '[foreground codex] launcher raises Claude Bash maximum timeout'

        # The session-grant env signal is in ADDITION to the --allowedTools grants,
        # not a replacement: both allow-rules must still be present on the claude
        # command line. The pwsh runtime-wrapper grant is the one that actually
        # unblocks the adapters' Bash call (review finding R-01); the codex exec grant
        # is retained as the canonical anchor CC_CODEX_EXEC_GRANT names.
        $capturedArgs = Get-CapturedArgs $captureFile
        Assert-True ($capturedArgs -contains 'Bash(codex exec:*)') '[session grant] --allowedTools "Bash(codex exec:*)" must still be forwarded'
        Assert-True ($capturedArgs -contains 'Bash(pwsh -File tools/codex-runtime.ps1:*)') '[session grant] --allowedTools "Bash(pwsh -File tools/codex-runtime.ps1:*)" (the actually-executed runtime wrapper) must be forwarded'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 8: explicitly configured containment is fail-closed --------
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-processor.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'
        $result = Invoke-Launcher -Paths $paths -Name 'cc-processor.cmd' -EnvVars @{
            FAKE_ARGS_FILE       = $captureFile
            FAKE_EXIT_CODE       = '0'
            CC_PROCESSKIT_PYTHON = (Join-Path $paths.Root 'missing-python.exe')
        }
        Assert-Equal 10 $result.ExitCode '[containment backend missing] launcher must fail closed'
        Assert-NoFileExists $captureFile '[containment backend missing] claude must not start uncontained'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 9: explicit Codex provider bypasses Claude and delegates to
    # the full native processor runtime with translated model/extra arguments.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-processor.cmd'
        Install-FakeClaude -Paths $paths
        $claudeCapture = Join-Path $paths.Root 'claude-args.txt'
        $runtimeCapture = Join-Path $paths.Root 'codex-runtime-args.txt'
        @'
$args | Set-Content -LiteralPath $env:FAKE_CODEX_PROCESSOR_ARGS -Encoding utf8
exit 0
'@ | Set-Content -LiteralPath (Join-Path $paths.Scripts 'codex-processor-runtime.ps1') -Encoding utf8

        $result = Invoke-Launcher -Paths $paths -Name 'cc-processor.cmd' -LauncherArgs @('codex', '--model', 'gpt-test', '--extra-codex-flag') -EnvVars @{
            FAKE_ARGS_FILE = $claudeCapture
            FAKE_CODEX_PROCESSOR_ARGS = $runtimeCapture
            FAKE_EXIT_CODE = '0'
            ORCHESTRA_PROVIDER = ''
            CD = (Join-Path $paths.Root 'shadowed-cd-must-not-be-used')
        }
        Assert-Equal 0 $result.ExitCode ("[codex provider] exit code; output=" + $result.Output.Trim())
        Assert-NoFileExists $claudeCapture '[codex provider] Claude must never be invoked'
        $captured = @(Get-Content -LiteralPath $runtimeCapture -Encoding utf8)
        Assert-True ($captured[0] -eq 'start') '[codex provider] runtime action is start'
        Assert-True ($captured -contains '-Root') '[codex provider] target root is explicit'
        Assert-True ($captured -contains $paths.Project) '[codex provider] target root value forwarded'
        Assert-True ($captured -contains '-Model' -and $captured -contains 'gpt-test') '[codex provider] --model translated to runtime -Model'
        Assert-True ($captured -contains '--extra-codex-flag') '[codex provider] remaining Codex args forwarded'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 10: system provider selects Codex without a positional token.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-processor.cmd'
        $runtimeCapture = Join-Path $paths.Root 'codex-runtime-args.txt'
        @'
$args | Set-Content -LiteralPath $env:FAKE_CODEX_PROCESSOR_ARGS -Encoding utf8
exit 0
'@ | Set-Content -LiteralPath (Join-Path $paths.Scripts 'codex-processor-runtime.ps1') -Encoding utf8
        $result = Invoke-Launcher -Paths $paths -Name 'cc-processor.cmd' -EnvVars @{
            FAKE_CODEX_PROCESSOR_ARGS = $runtimeCapture
            ORCHESTRA_PROVIDER = 'codex'
        }
        Assert-Equal 0 $result.ExitCode '[system codex provider] exit code'
        Assert-True ((Get-Content -LiteralPath $runtimeCapture -First 1) -eq 'start') '[system codex provider] ORCHESTRA_PROVIDER=codex selects native runtime'
    }
    finally {
        Remove-Sandbox $paths
    }
}
