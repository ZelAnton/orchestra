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
        }

        Assert-Equal 2 $result.ExitCode '[addressed] exit code must be forwarded from claude'

        $captured = Get-CapturedArgs $captureFile
        $flags = @('--agent', 'processor', '--allowedTools', 'Bash(codex exec:*)', '--permission-mode', $expectedMode, '--continue')
        Assert-Equal ($flags.Count + 1) $captured.Count '[addressed] flags + one prompt arg'
        Assert-ArrayEqual $flags $captured[0..($flags.Count - 1)] '[addressed] flag list, ending in --continue'
        Assert-True ($captured[$flags.Count] -match '^Continue processing \.work/Tasks_Queue\.md from where you left off') '[addressed] resume prompt'

        # task T-071: the launcher exports the session-grant signal in either branch.
        $expectedGrant = Get-ExpectedGrant 'cc-resume.cmd'
        Assert-Equal 'codex exec' $expectedGrant '[addressed] launcher source sets CC_CODEX_EXEC_GRANT=codex exec'
        Assert-Equal $expectedGrant (Get-CapturedGrant $envFile) '[addressed] claude inherits CC_CODEX_EXEC_GRANT'
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
        $flags = @('--agent', 'processor', '--allowedTools', 'Bash(codex exec:*)', '--permission-mode', $expectedMode)
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
}
