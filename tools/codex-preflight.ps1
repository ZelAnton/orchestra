<#
.SYNOPSIS
    Cheap, no-model preflight probe of the Codex Windows restricted-token /
    workspace-write "split writable root" sandbox spawn (task T-117).

.DESCRIPTION
    Some Windows hosts intermittently cannot bring up the codex restricted-token
    sandbox for `--sandbox workspace-write` and emit `CreateProcessAsUserW failed: 5`
    ("Windows sandbox cannot enforce split writable root; refusing to run
    unsandboxed") - the fail-closed `sandbox-init` ENV_LIMIT class (T-067/T-069).
    When that happens, every real `coder_codex`/`reviewer_codex` call on the host
    burns a full model round-trip only to escalate. This probe lets the processor
    learn, ONCE per session and for ~1 second, whether that host limit is LIVE right
    now - WITHOUT a model round-trip, network, or tokens - so it can route the rest
    of the session straight to the Claude executor instead of wasting Codex calls.

    How it probes: it runs `codex sandbox -c sandbox_mode=workspace-write -- <no-op>`.
    `codex sandbox` executes a command inside the SAME Windows restricted-token
    sandbox that `codex exec` uses, so it exercises the exact restricted-token
    creation + writable-root split enforcement that fails with error 5 - but with a
    trivial no-op command (`cmd /c exit 0`) and no model call. The captured
    stdout/stderr/RC are classified with the SAME failure table as
    tools/codex-runtime.ps1 (this script dot-sources it, so the `sandbox-init`
    signature `CreateProcessAsUserW failed: 5` stays single-sourced and guarded).

    IMPORTANT - this is a ROUTING optimization, never a safety gate. It NEVER runs
    anything outside the sandbox: the no-op is executed *inside* codex's sandbox, and
    if codex refuses (cannot enforce the split) the probe simply reports it. It never
    touches VCS. The adapters' fail-closed escalation (T-069) remains the sole
    authority for real calls; this probe only removes doomed calls before they start.

    With no `--workspace`, this measures the host/process-wide class once per
    session. With `--workspace <task-worktree>`, it measures the exact nested
    worktree shape before a worktree-scoped coder dispatch; this second probe is
    intentionally separate because a throwaway top-level probe cannot reproduce
    the native Windows split-root failure.

    Decision (also encoded in the exit code, so a caller may branch on either):
      * class == 'sandbox-init-worktree' -> decision 'downgrade-worktree', exit 3.
        Route worktree-scoped coder calls to Claude for the rest of the session;
        reviewer/read-only and main-tree CI-fix routing remain independent.
      * class == 'sandbox-init'  -> decision 'downgrade', exit 3. The host limit is
        live this session; the caller should route Codex work to Claude for the rest
        of the session and say so in the overview/journal.
      * anything else (none / ordinary / codex not found / probe error) -> decision
        'unchanged', exit 0. Behaviour is identical to not having a preflight at all
        (this is the case on every host where the signature does not reproduce - the
        common case, e.g. codex-cli 0.144.1).

    Only `sandbox-init` and the exact `sandbox-init-worktree` signature drive a
    downgrade. network / tls-schannel / vcs-write / profile-denied are scope- or
    config-dependent (a no-op touches no network, git metadata or profile), so they
    are handled by the existing scope-keyed T-065 KB path, not by this probe.

.EXAMPLE
    pwsh -File tools/codex-preflight.ps1
    pwsh -File tools/codex-preflight.ps1 --codex-cmd codex --timeout-sec 30
    pwsh -File tools/codex-preflight.ps1 --workspace D:\repo\.work\worktrees\T-123
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

# --- Reuse the tested runtime helpers (Resolve-CodexTarget, Invoke-Captured,
# Get-FailureClass, Get-Sentinel) so the ENV_LIMIT signature table has ONE home.
# The dot-source guard in codex-runtime.ps1 keeps its CLI dispatch from firing here.
. (Join-Path $PSScriptRoot 'codex-runtime.ps1')

# --- Minimal, self-contained arg parse (--key value | --flag) ------------------
$pf = @{}
$pfBool = @('json')
for ($i = 0; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    if ($a -like '--*') {
        $k = $a.Substring(2)
        if ($pfBool -contains $k) { $pf[$k] = $true; continue }
        $i++
        if ($i -lt $args.Count) { $pf[$k] = [string]$args[$i] } else { $pf[$k] = '' }
    }
}
function PfOpt { param([string]$Name, $Default = $null) if ($pf.ContainsKey($Name)) { return $pf[$Name] } else { return $Default } }

$CodexCmd = [string](PfOpt 'codex-cmd' 'codex')
$TimeoutSec = [int]([string](PfOpt 'timeout-sec' '30'))
$Workspace = [string](PfOpt 'workspace' '')
$workspaceSupplied = -not [string]::IsNullOrWhiteSpace($Workspace)

function Emit-Result {
    param($Object, [int]$ExitCode)
    Write-Output ($Object | ConvertTo-Json -Depth 8)
    exit $ExitCode
}

# --- Resolve codex. Absent -> inconclusive, DO NOT change routing (the existing
# CODEX_UNAVAILABLE fallback already handles a missing binary). ------------------
$target = Resolve-CodexTarget -CodexCmd $CodexCmd
if ($null -eq $target) {
    Emit-Result ([pscustomobject]@{
            probe        = 'codex-sandbox-workspace-write'
            ran          = $false
            codexResolved = $false
            class        = 'unavailable'
            envLimit     = $false
            hostLimit    = $false
            decision     = 'unchanged'
            sentinel     = $null
            detail       = "codex command not found: $CodexCmd (preflight inconclusive; routing unchanged)"
        }) 0
}

# --- A throwaway writable workspace so the probe never depends on, or dirties, a
# real worktree. The no-op writes nothing; the dir only gives workspace-write a
# writable root to enforce the split against. -----------------------------------
$onWindows = if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) { [bool]$IsWindows } else { $true }
$createdWs = $false
if (-not $Workspace) {
    $Workspace = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-preflight-" + [System.Guid]::NewGuid().ToString('N').Substring(0, 12))
    New-Item -ItemType Directory -Force -Path $Workspace | Out-Null
    $createdWs = $true
} elseif (-not (Test-Path -LiteralPath $Workspace -PathType Container)) {
    Emit-Result ([pscustomobject]@{
            probe         = 'codex-sandbox-workspace-write'
            scope         = 'worktree'
            workspace     = $Workspace
            ran           = $false
            codexResolved = $true
            class         = 'sandbox-init-worktree'
            envLimit      = $true
            hostLimit     = $false
            decision      = 'downgrade-worktree'
            sentinel      = (Get-Sentinel -Kind 'failed' -Class 'sandbox-init-worktree' -Detail 'task worktree missing')
            detail        = "task worktree does not exist for exact sandbox probe: $Workspace"
        }) 3
}
$Workspace = [System.IO.Path]::GetFullPath($Workspace)

# The no-op command codex runs INSIDE its sandbox: trivial, writes nothing.
$noop = if ($onWindows) { @('cmd', '/c', 'exit', '0') } else { @('sh', '-c', 'exit 0') }

# codex sandbox <flags> -- <no-op>. Forcing sandbox_mode=workspace-write makes codex
# set up (and, on a broken host, fail to set up) the split writable root.
$sandboxArgs = @('sandbox', '-c', 'sandbox_mode=workspace-write')
if ($onWindows) {
    # Mirror the runtime's native-Windows single-root collapse (T-279) so this probe measures
    # the SAME sandbox shape the real `codex exec --sandbox workspace-write` call will use:
    # exclude codex's own extra /tmp and $TMPDIR writable roots, leaving `[workdir]` as the
    # single enforceable root (tools/codex-runtime.ps1 Build-CodexArgv does the same). Without
    # this the probe would test the pre-fix split-root shape and could return
    # `downgrade-worktree` even though the real single-root call would now start cleanly - a
    # false negative that would needlessly route the whole worktree lane to Claude.
    $sandboxArgs += @('-c', 'sandbox_workspace_write.exclude_slash_tmp=true',
        '-c', 'sandbox_workspace_write.exclude_tmpdir_env_var=true')
}
$sandboxArgs += @('--') + $noop
$spawnArgs = @($target.Prefix) + $sandboxArgs

# Run with the addressed directory as the child process working directory so Codex
# and the Windows sandbox agree on one primary root. Invoke-Captured pins this
# mechanically; changing only the parent PowerShell's managed CurrentDirectory was
# insufficiently explicit and was the same shape that diverged in codex exec.
$res = $null
try {
    $res = Invoke-Captured -FilePath $target.File -Arguments $spawnArgs -StdinText '' -TimeoutSec $TimeoutSec -WorkingDirectory $Workspace
}
finally {
    if ($createdWs -and (Test-Path -LiteralPath $Workspace)) {
        Remove-Item -LiteralPath $Workspace -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- Classify with the shared table. A no-op probe can only realistically surface
# 'sandbox-init' (the spawn itself) or a clean run. ------------------------------
$combined = "$($res.StdOut)`n$($res.StdErr)"
$fc = Get-FailureClass -Text $combined -RC $res.ExitCode

$worktreeLimit = ($fc.class -eq 'sandbox-init-worktree')
if ($worktreeLimit) {
    $sentinel = Get-Sentinel -Kind 'failed' -Class 'sandbox-init-worktree' -Detail 'live task-worktree preflight'
    Emit-Result ([pscustomobject]@{
            probe         = 'codex-sandbox-workspace-write'
            scope         = if ($workspaceSupplied) { 'worktree' } else { 'host-probe' }
            workspace     = $Workspace
            ran           = $true
            codexResolved = $true
            exitCode      = $res.ExitCode
            timedOut      = $res.TimedOut
            class         = 'sandbox-init-worktree'
            envLimit      = $true
            hostLimit     = $false
            decision      = 'downgrade-worktree'
            sentinel      = $sentinel
            detail        = 'native Windows sandbox rejected the split writable-root shape for this task worktree; route worktree-scoped Codex coder calls to Claude'
        }) 3
}

$hostLimit = ($fc.class -eq 'sandbox-init')
if ($hostLimit) {
    $firstSig = if ($fc.signature) { $fc.signature } else { 'CreateProcessAsUserW failed: 5' }
    $sentinel = Get-Sentinel -Kind 'failed' -Class 'sandbox-init' -Detail 'live host preflight'
    Emit-Result ([pscustomobject]@{
            probe        = 'codex-sandbox-workspace-write'
            scope        = 'host'
            workspace    = $Workspace
            ran          = $true
            codexResolved = $true
            exitCode     = $res.ExitCode
            timedOut     = $res.TimedOut
            class        = 'sandbox-init'
            envLimit     = $true
            hostLimit    = $true
            decision     = 'downgrade'
            sentinel     = $sentinel
            detail       = "codex workspace-write sandbox refused to initialize on this host now ($firstSig); routing Codex work to Claude for the rest of the session"
        }) 3
}

# Clean run (or any non-sandbox-init outcome) -> routing unchanged.
Emit-Result ([pscustomobject]@{
        probe        = 'codex-sandbox-workspace-write'
        scope        = if ($workspaceSupplied) { 'worktree' } else { 'host' }
        workspace    = $Workspace
        ran          = $true
        codexResolved = $true
        exitCode     = $res.ExitCode
        timedOut     = $res.TimedOut
        class        = $fc.class
        envLimit     = [bool]$fc.envLimit
        hostLimit    = $false
        decision     = 'unchanged'
        sentinel     = $null
        detail       = 'codex workspace-write sandbox initialized normally; Codex routing unchanged'
    }) 0
