# Verifies launchers/cc-resume.cmd: the addressed resume decision (task T-079) plus
# the static flag list, exit-code propagation, and the CC_CODEX_EXEC_GRANT
# session-grant signal (task T-071).
#
# Addressed resume: --continue is used only when an addressed processor lease exists
# for this project (.work/orchestrator.lock/lease.json with role=processor). Without
# such a lease (or with a different role's lease) the launcher does an explicit cold
# recovery (Phase 0 from scratch, no --continue) instead of resuming an arbitrary last
# session.
#
# The two prompts contain a Cyrillic word ("Phase 0" in Russian) whose exact bytes are
# fragile across cmd.exe codepage handling and the 5.1 no-BOM source read; this file is
# therefore kept pure ASCII and matches each prompt by its (unique) ASCII prefix rather
# than by full-string equality.

. (Join-Path $PSScriptRoot 'common.ps1')

function Write-Lease {
    param([Parameter(Mandatory)] $Paths, [Parameter(Mandatory)] [string] $Role)
    $dir = Join-Path $Paths.Project '.work\orchestrator.lock'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $json = @"
{
  "schema": "orchestra/lease@1",
  "role": "$Role",
  "owner_id": "0123456789abcdef",
  "root": "C:\\proj\\demo",
  "host": "testhost",
  "heartbeat": "2026-07-10T00:00:00.000Z",
  "ttl_seconds": 900,
  "generation": 1
}
"@
    Set-Content -LiteralPath (Join-Path $dir 'lease.json') -Value $json -Encoding utf8
}

Invoke-Test -Name 'cc-resume.cmd' -Body {
    $expectedMode = Get-ExpectedPermissionMode 'cc-resume.cmd'

    # --- Scenario 1: addressed processor lease present -> --continue + grant ---
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-resume.cmd'
        Install-FakeClaude -Paths $paths
        Write-Lease -Paths $paths -Role 'processor'
        $captureFile = Join-Path $paths.Root 'claude-args.txt'
        $envFile = Join-Path $paths.Root 'claude-env.txt'

        # Clear CC_CODEX_EXEC_GRANT in the ambient env so the captured value can only
        # come from the launcher itself (see test-cc-processor.ps1 scenario 7).
        $result = Invoke-Launcher -Paths $paths -Name 'cc-resume.cmd' -EnvVars @{
            FAKE_ARGS_FILE      = $captureFile
            FAKE_ENV_FILE       = $envFile
            FAKE_EXIT_CODE      = '2'
            CC_CODEX_EXEC_GRANT = ''
            BASH_DEFAULT_TIMEOUT_MS = ''
            BASH_MAX_TIMEOUT_MS = ''
        }

        Assert-Equal 2 $result.ExitCode '[addressed] exit code must be forwarded from claude'

        $captured = Get-CapturedArgs $captureFile
        $flags = @('--agent', 'processor', '--allowedTools', 'Bash(codex exec:*)', 'Bash(pwsh -File tools/codex-runtime.ps1:*)', '--permission-mode', $expectedMode, '--continue')
        Assert-Equal ($flags.Count + 1) $captured.Count '[addressed] flags + one prompt arg'
        Assert-ArrayEqual $flags $captured[0..($flags.Count - 1)] '[addressed] flag list, ending in --continue'
        Assert-True ($captured[$flags.Count] -match '^Continue processing \.work/Tasks_Queue\.md from where you left off') '[addressed] resume prompt'

        # task T-071: the launcher exports the session-grant signal in either branch.
        $expectedGrant = Get-ExpectedGrant 'cc-resume.cmd'
        Assert-Equal 'codex exec' $expectedGrant '[addressed] launcher source sets CC_CODEX_EXEC_GRANT=codex exec'
        Assert-Equal $expectedGrant (Get-CapturedGrant $envFile) '[addressed] claude inherits CC_CODEX_EXEC_GRANT'
        Assert-Equal '1' (Get-CapturedEnvValue $envFile 'MSBUILDDISABLENODEREUSE') '[addressed] claude inherits disabled MSBuild node reuse'
        Assert-Equal '0' (Get-CapturedEnvValue $envFile 'DOTNET_CLI_USE_MSBUILD_SERVER') '[addressed] claude inherits disabled MSBuild server use'
        Assert-Equal '1900000' (Get-CapturedEnvValue $envFile 'BASH_DEFAULT_TIMEOUT_MS') '[addressed] claude inherits foreground Bash default timeout'
        Assert-Equal '1900000' (Get-CapturedEnvValue $envFile 'BASH_MAX_TIMEOUT_MS') '[addressed] claude inherits foreground Bash maximum timeout'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 2: no lease at all -> explicit cold recovery (no --continue) ---
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-resume.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-resume.cmd' -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '0'
        }
        Assert-Equal 0 $result.ExitCode '[cold] exit code forwarded'

        $captured = Get-CapturedArgs $captureFile
        $flags = @('--agent', 'processor', '--allowedTools', 'Bash(codex exec:*)', 'Bash(pwsh -File tools/codex-runtime.ps1:*)', '--permission-mode', $expectedMode)
        Assert-Equal ($flags.Count + 1) $captured.Count '[cold] flags + one prompt arg, no --continue'
        Assert-ArrayEqual $flags $captured[0..($flags.Count - 1)] '[cold] flag list has no --continue'
        Assert-True (-not ($captured -contains '--continue')) '[cold] --continue absent'
        Assert-True ($captured[$flags.Count] -match '^Cold start: no addressed processor session to continue') '[cold] cold-recovery prompt'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 3: a different role's lease is NOT an addressed processor lease --
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-resume.cmd'
        Install-FakeClaude -Paths $paths
        Write-Lease -Paths $paths -Role 'merger'
        $captureFile = Join-Path $paths.Root 'claude-args.txt'

        $result = Invoke-Launcher -Paths $paths -Name 'cc-resume.cmd' -EnvVars @{
            FAKE_ARGS_FILE = $captureFile
            FAKE_EXIT_CODE = '0'
        }
        Assert-Equal 0 $result.ExitCode '[non-processor] exit code forwarded'

        $captured = Get-CapturedArgs $captureFile
        Assert-True (-not ($captured -contains '--continue')) '[non-processor] a non-processor lease must not trigger --continue'
        Assert-True ($captured[-1] -match '^Cold start: no addressed processor session to continue') '[non-processor] falls back to cold recovery'
    }
    finally {
        Remove-Sandbox $paths
    }

    # --- Scenario 4: explicitly configured containment is fail-closed --------
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-resume.cmd'
        Install-FakeClaude -Paths $paths
        $captureFile = Join-Path $paths.Root 'claude-args.txt'
        $result = Invoke-Launcher -Paths $paths -Name 'cc-resume.cmd' -EnvVars @{
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

    # --- Scenario 5: Codex provider uses its exact-session runtime and never Claude.
    $paths = New-Sandbox
    try {
        Install-Launcher -Paths $paths -Names 'cc-resume.cmd'
        Install-FakeClaude -Paths $paths
        $claudeCapture = Join-Path $paths.Root 'claude-args.txt'
        $runtimeCapture = Join-Path $paths.Root 'codex-runtime-args.txt'
        $rootMarkerName = '.codex-project-root-marker'
        Set-Content -LiteralPath (Join-Path $paths.Project $rootMarkerName) -Value 'expected-root' -Encoding ascii
        @'
$args | Set-Content -LiteralPath $env:FAKE_CODEX_PROCESSOR_ARGS -Encoding utf8
exit 0
'@ | Set-Content -LiteralPath (Join-Path $paths.Scripts 'codex-processor-runtime.ps1') -Encoding utf8
        $result = Invoke-Launcher -Paths $paths -Name 'cc-resume.cmd' -LauncherArgs @('codex', '-Model', 'gpt-test') -EnvVars @{
            FAKE_ARGS_FILE = $claudeCapture
            FAKE_CODEX_PROCESSOR_ARGS = $runtimeCapture
            FAKE_EXIT_CODE = '0'
            ORCHESTRA_PROVIDER = ''
            CD = (Join-Path $paths.Root 'shadowed-cd-must-not-be-used')
        }
        Assert-Equal 0 $result.ExitCode '[codex resume] exit code'
        Assert-NoFileExists $claudeCapture '[codex resume] Claude must never be invoked'
        $captured = @(Get-Content -LiteralPath $runtimeCapture -Encoding utf8)
        Assert-True ($captured[0] -eq 'resume') '[codex resume] runtime action is resume'
        $rootIndex = [Array]::IndexOf($captured, '-Root')
        Assert-True ($rootIndex -ge 0 -and ($rootIndex + 1) -lt $captured.Count) '[codex resume] project root argument is explicit'
        $capturedRoot = $captured[$rootIndex + 1]
        Assert-True (Test-Path -LiteralPath (Join-Path $capturedRoot $rootMarkerName) -PathType Leaf) '[codex resume] project root addresses the project directory'
        Assert-True (-not ($captured -contains 'codex')) '[codex resume] consumed provider token is not forwarded after SHIFT'
        Assert-True ($captured -contains '-Model' -and $captured -contains 'gpt-test') '[codex resume] remaining runtime arguments are preserved'
    }
    finally {
        Remove-Sandbox $paths
    }
}
