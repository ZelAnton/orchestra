<#
.SYNOPSIS
    Runtime wrapper that drives the jcode CLI for Orchestra's optional jcode leaf
    adapters (agents/coder_jcode.md, agents/reviewer_jcode.md) - the jcode-side
    counterpart of tools/codex-runtime.ps1.

.DESCRIPTION
    The adapters are thin Claude roles: they build a prompt, call this runtime, verify
    the result and report in the ordinary leaf-agent contract. Every mechanical and
    every safety-critical step lives HERE, as executable code, rather than as prose in
    the role files - the same split codex-runtime.ps1 established.

    WHY THIS RUNTIME IS NOT A COPY OF codex-runtime.ps1
    ---------------------------------------------------
    `codex exec` is sandboxed: Orchestra passes --sandbox workspace-write, pins
    `-c approval_policy=never` so a sandbox-init failure errors instead of silently
    running unconfined, and narrows the writable root to the task worktree. The kernel
    (or the Windows restricted token) enforces the boundary.

    `jcode run` has NO sandbox and no approval gate at all: it edits files and runs
    shell commands unattended by default. Its isolation surface is exactly two flags:

      -C, --cwd <dir>     the process working directory
      --tools a,b,c       the tool allow-list exposed to the model

    That is weaker than a sandbox in one specific way that matters: `bash` inside the
    allow-list can reach ANY path, so -C alone does not contain a coder. This runtime
    therefore replaces the missing kernel boundary with two compensating guards:

      1. Structural read-only for the reviewer. The reviewer profile omits `bash` and
         every write tool, so reviewer runs are read-only by construction rather than
         by policy - verified: with --tools read,ls,agentgrep the model reports exactly
         `Read, agentgrep, ls` and cannot write. Because the reviewer then has no shell
         to run `git diff` with, `prepare-review` materialises the diff to a file for it
         (outside the worktree, so the worktree stays pristine).

      2. Post-hoc tree verification for the coder, which does need `bash`. `snapshot`
         fingerprints the worktree head, the main checkout and known sibling Orchestra
         worktrees before the run; `guard-tree` re-reads them after and fails if jcode
         created a revision or changed one of those protected trees. This is detection,
         not prevention, and it cannot observe arbitrary filesystem paths - say so
         plainly rather than implying sandbox-equivalent containment.

    A THIRD HAZARD, SPECIFIC TO jcode: --tools SILENTLY IGNORES UNKNOWN NAMES.
    Verified against jcode v0.76.0: `--tools bogus` neither errors nor warns - it
    yields an EMPTY toolset, and the run completes "successfully" having done nothing.
    A typo in an allow-list is therefore not a loud failure but a silent no-op that
    burns a full task cycle and looks like "the model refused". Role tool profiles are
    consequently pinned literals here and validated against $JcodeKnownTools before any
    argv is built.

.NOTES
    Runs under PowerShell 7 (pwsh). Reports failures by writing stderr and calling
    `exit` (the runtime model), not via the coded-error catch dispatcher.

    Invoke-Captured is dot-sourced from codex-runtime.ps1 rather than reimplemented:
    it is a hardened, non-codex-specific process launcher (UTF-8 capture on every
    stream, Win32-correct argv quoting, process-group reaping for the T-256 leak,
    bounded waits). tools/codex-preflight.ps1 already reuses it exactly this way, and
    codex-runtime.ps1's dot-source guard keeps its CLI dispatch from firing. Extracting
    it into a neutral library is worthwhile but is a codex-touching refactor and is
    deliberately not bundled with this feature.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Emit UTF-8 on stdout regardless of the host console code page, so the Cyrillic
# escalation sentinels (`ЭСКАЛАЦИЯ jcode: ...`) survive capture/redirection intact.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

# Invoke-Captured (+ common.ps1 / proc-tree.ps1, which it pulls in). See .NOTES.
. (Join-Path $PSScriptRoot 'codex-runtime.ps1')

# Test-PathAtOrUnder - the real-path containment check used by prepare-review to keep
# review artefacts out of the worktree. Both dot-sources land BEFORE the Fail/Opt
# definitions below, so this file's runtime-model Fail overrides common.ps1's
# throw-model copy rather than the other way round.
. (Join-Path $PSScriptRoot 'policy-schema.ps1')

# --------------------------------------------------------------------------
# Argument parsing:  <command> [--key value | --flag] ...
# Same shape as codex-runtime.ps1 / queue-tx.ps1. Parsed AFTER the dot-source so
# these definitions win over the ones codex-runtime.ps1 leaves in the shared scope.
# --------------------------------------------------------------------------
$Command = if ($args.Count -ge 1) { [string]$args[0] } else { '' }
$JcodeBoolFlags = @('json')
$opts = @{}
for ($i = 1; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    if ($a -like '--*') {
        $key = $a.Substring(2)
        if ($JcodeBoolFlags -contains $key) { $opts[$key] = $true; continue }
        $i++
        if ($i -lt $args.Count) { $opts[$key] = [string]$args[$i] } else { $opts[$key] = '' }
    }
}

function Fail {
    param([int]$Code, [string]$Message)
    [Console]::Error.WriteLine("jcode-runtime: $Message")
    exit $Code
}
function Opt {
    param([string]$Name, $Default = $null)
    if ($opts.ContainsKey($Name)) { return $opts[$Name] } else { return $Default }
}
function Require-Opt {
    param([string]$Name)
    if (-not $opts.ContainsKey($Name) -or [string]::IsNullOrEmpty([string]$opts[$Name])) {
        Fail 2 "missing required option --$Name"
    }
    return [string]$opts[$Name]
}

function Write-TextNoBomLocal {
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($false)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}
function Emit-JsonLocal {
    param($Object)
    Write-Output ($Object | ConvertTo-Json -Depth 12)
}

# --------------------------------------------------------------------------
# Pinned tool vocabulary (fail-closed).
#
# $JcodeKnownTools lists ONLY names verified to resolve against the running jcode
# build. It is deliberately not the full src/tool/*.rs inventory: an unverified name
# that jcode does not recognise is indistinguishable from a typo, and both silently
# shrink the toolset (see the .DESCRIPTION hazard note). To add one, run
#   jcode run --quiet --tools <name> "List the exact names of every tool you
#                                     currently have available, comma-separated."
# and add it only if jcode echoes it back.
#
# $JcodeRoleTools is the whole reason this runtime takes --role instead of a raw tool
# list: a reviewer can then never be handed `bash` by a prompt-level mistake, because
# the adapter never names tools at all.
# --------------------------------------------------------------------------
$JcodeKnownTools = @(
    'agentgrep', 'apply_patch', 'bash', 'edit', 'ls', 'multiedit', 'read', 'todo', 'write'
)

$JcodeRoleTools = [ordered]@{
    # Needs a shell: SMOKE_CMD self-check, build/test commands. Contained by
    # snapshot/guard-tree, not by a sandbox.
    coder    = @('read', 'write', 'edit', 'multiedit', 'apply_patch', 'ls', 'bash', 'agentgrep', 'todo')
    # No bash, no write tool of any kind -> structurally incapable of mutating the
    # tree. `prepare-review` feeds it the diff so it does not need a shell.
    reviewer = @('read', 'ls', 'agentgrep')
}

$AllowedRoles = @($JcodeRoleTools.Keys)
$AllowedVcsKinds = @('git', 'jj')

function Resolve-RoleTools {
    param([string]$Role)
    if ($Role -notin $AllowedRoles) {
        Fail 2 "invalid --role '$Role' (allowed: $($AllowedRoles -join ' | '))"
    }
    $tools = @($JcodeRoleTools[$Role])
    foreach ($t in $tools) {
        if ($t -notin $JcodeKnownTools) {
            # Reached only if this file is edited inconsistently; jcode itself would
            # accept the bad name and silently drop the tool.
            Fail 2 "role '$Role' names tool '$t', which is not in the verified tool list"
        }
    }
    return $tools
}

function Require-Vcs {
    $vcs = Require-Opt 'vcs'
    if ($vcs -notin $AllowedVcsKinds) { Fail 2 "invalid --vcs '$vcs' (allowed: git | jj)" }
    return $vcs
}

function Resolve-JcodeCmd {
    $cmd = [string](Opt 'jcode-cmd' 'jcode')
    if ([string]::IsNullOrWhiteSpace($cmd)) { $cmd = 'jcode' }
    $bin = Get-Command $cmd -ErrorAction SilentlyContinue
    if (-not $bin) { return $null }
    return $bin.Source
}

# --------------------------------------------------------------------------
# Failure classification. jcode has no sandbox, so the codex sandbox-init classes have
# no analogue; what remains is availability, auth and the silent-empty-toolset case.
# Every class maps to a clean escalation - the processor falls back to the equivalent
# Claude leaf agent, exactly as it does for codex.
# --------------------------------------------------------------------------
$JcodeFailureClasses = @(
    [pscustomobject]@{ Class = 'tool-missing'; Signatures = @('is not recognized as', 'command not found', 'No such file or directory') }
    [pscustomobject]@{ Class = 'auth';         Signatures = @('not logged in', 'no credentials', 'authentication failed', 'unauthorized', '401') }
    [pscustomobject]@{ Class = 'rate-limit';   Signatures = @('rate limit', '429', 'quota') }
    [pscustomobject]@{ Class = 'provider';     Signatures = @('provider unavailable', 'stream idle timeout', 'overloaded', '529', '503') }
)

function Get-JcodeFailureClass {
    param([string]$Text)
    $t = ([string]$Text).ToLowerInvariant()
    foreach ($fc in $JcodeFailureClasses) {
        foreach ($sig in $fc.Signatures) {
            if ($t.Contains($sig.ToLowerInvariant())) { return $fc.Class }
        }
    }
    return 'unknown'
}

# --------------------------------------------------------------------------
# VCS probes used by snapshot/guard-tree.
# --------------------------------------------------------------------------
function Get-TreeHead {
    param([string]$Dir, [string]$Vcs)
    if ($Vcs -eq 'jj') {
        $r = Invoke-Captured -FilePath 'jj' -Arguments @('-R', $Dir, 'log', '-r', '@', '-T', 'commit_id', '--no-graph') -TimeoutSec 60
    } else {
        $r = Invoke-Captured -FilePath 'git' -Arguments @('-C', $Dir, 'rev-parse', 'HEAD') -TimeoutSec 60
    }
    if ($r.ExitCode -ne 0) { return '' }
    return ([string]$r.StdOut).Trim()
}

function Get-TreeStatusDigest {
    param([string]$Dir, [string]$Vcs)
    if ($Vcs -eq 'jj') {
        # Hash patch CONTENT, not `jj st` path names. A second write to an already-dirty
        # file leaves status text unchanged and would otherwise evade the isolation guard.
        $r = Invoke-Captured -FilePath 'jj' -Arguments @('-R', $Dir, 'diff', '--git', '--no-pager') -TimeoutSec 120
        if ($r.ExitCode -ne 0) { return 'UNREADABLE' }
        $text = [string]$r.StdOut
    } else {
        # `git diff --binary HEAD` covers tracked content. Add hashes of every untracked,
        # non-ignored file; status/path-only fingerprints cannot distinguish rewrites of
        # an already-dirty file.
        $r = Invoke-Captured -FilePath 'git' -Arguments @('-C', $Dir, 'diff', '--binary', 'HEAD') -TimeoutSec 120
        if ($r.ExitCode -ne 0) { return 'UNREADABLE' }
        $u = Invoke-Captured -FilePath 'git' -Arguments @('-C', $Dir, 'ls-files', '--others', '--exclude-standard', '-z') -TimeoutSec 120
        if ($u.ExitCode -ne 0) { return 'UNREADABLE' }
        $parts = [System.Collections.Generic.List[string]]::new()
        $parts.Add([string]$r.StdOut)
        foreach ($rel in @(([string]$u.StdOut).Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries))) {
            $path = Join-Path $Dir $rel
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return 'UNREADABLE' }
            $fileSha = [System.Security.Cryptography.SHA256]::Create()
            try {
                $stream = [System.IO.File]::OpenRead($path)
                try { $hex = [System.BitConverter]::ToString($fileSha.ComputeHash($stream)).Replace('-', '') }
                finally { $stream.Dispose() }
            } catch { return 'UNREADABLE' }
            finally { $fileSha.Dispose() }
            $parts.Add("UNTRACKED $rel $hex")
        }
        $text = $parts -join "`n"
    }
    $text = $text.Replace("`r`n", "`n").Trim()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
        return [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
    } finally { $sha.Dispose() }
}

function Get-ControlPlaneDigest {
    param([string]$RepoRoot, [string]$Worktree)
    $controlRoot = Join-Path $RepoRoot '.work'
    if (-not (Test-Path -LiteralPath $controlRoot -PathType Container)) { return 'ABSENT' }

    # .work is intentionally ignored by consuming repositories, so Git's status/diff
    # fingerprint above cannot see queue, lease, task-descriptor, or approval writes in
    # the main checkout. Protect that control plane explicitly. Task worktrees are
    # excluded here because they are fingerprinted as sibling trees below. The current
    # jcode artifact directory is also expected to appear/change during a coder run
    # (snapshot output is written before jcode starts, prompt/output/result files after
    # it), so exclude only that one task-local directory; other task artifacts remain
    # protected.
    $worktreePath = [System.IO.Path]::GetFullPath($Worktree)
    $worktreePath = $worktreePath.TrimEnd([char[]]@([char]92, [char]47))
    $taskId = Split-Path -Leaf $worktreePath
    $taskArtifactRelative = ('tasks/{0}/jcode' -f $taskId)
    $rows = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($entry in @(Get-ChildItem -LiteralPath $controlRoot -Force -Recurse -ErrorAction Stop)) {
            $relative = [System.IO.Path]::GetRelativePath($controlRoot, $entry.FullName)
            $normalizedRelative = $relative.Replace([char]92, [char]47)
            $first = ($normalizedRelative -split '/')[0]
            if ($first -eq 'worktrees') { continue }
            if ($normalizedRelative -eq $taskArtifactRelative -or
                $normalizedRelative.StartsWith($taskArtifactRelative + '/', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($entry.PSIsContainer) {
                $rows.Add("D $normalizedRelative")
                continue
            }
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                $stream = [System.IO.File]::OpenRead($entry.FullName)
                try { $hex = [System.BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
                finally { $stream.Dispose() }
            } finally { $sha.Dispose() }
            $rows.Add("F $normalizedRelative $hex")
        }
    } catch {
        return 'UNREADABLE'
    }

    $rows.Sort()
    $text = $rows -join "`n"
    $digest = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
        return [System.BitConverter]::ToString($digest.ComputeHash($bytes)).Replace('-', '')
    } finally { $digest.Dispose() }
}

function Get-SiblingTreeSnapshots {
    param([string]$Worktree, [string]$RepoRoot, [string]$Vcs)
    $root = Join-Path (Join-Path $RepoRoot '.work') 'worktrees'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    $target = [System.IO.Path]::GetFullPath($Worktree).TrimEnd('\', '/')
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
        $path = [System.IO.Path]::GetFullPath($dir.FullName).TrimEnd('\', '/')
        $same = if ($IsWindows) { $path.Equals($target, [System.StringComparison]::OrdinalIgnoreCase) } else { $path.Equals($target, [System.StringComparison]::Ordinal) }
        if ($same) { continue }
        $rows.Add([ordered]@{
                path   = $path
                head   = (Get-TreeHead -Dir $path -Vcs $Vcs)
                digest = (Get-TreeStatusDigest -Dir $path -Vcs $Vcs)
            })
    }
    return $rows.ToArray()
}

function New-TreeSnapshot {
    param([string]$Worktree, [string]$RepoRoot, [string]$Vcs)
    return [ordered]@{
        vcs           = $Vcs
        worktree      = $Worktree
        worktreeHead  = (Get-TreeHead -Dir $Worktree -Vcs $Vcs)
        repoRoot      = $RepoRoot
        repoRootHead  = (Get-TreeHead -Dir $RepoRoot -Vcs $Vcs)
        repoRootDigest = (Get-TreeStatusDigest -Dir $RepoRoot -Vcs $Vcs)
        repoRootControlDigest = (Get-ControlPlaneDigest -RepoRoot $RepoRoot -Worktree $Worktree)
        siblingTrees  = @(Get-SiblingTreeSnapshots -Worktree $Worktree -RepoRoot $RepoRoot -Vcs $Vcs)
    }
}

# ==========================================================================
# Commands
# ==========================================================================

function Cmd-Preflight {
    $bin = Resolve-JcodeCmd
    $result = [ordered]@{ ok = $false; binary = ''; version = ''; auth = $false; reason = '' }
    if (-not $bin) {
        $result.reason = 'jcode binary not found'
        if (Opt 'json') { Emit-JsonLocal $result; return }
        Fail 3 'jcode binary not found -> the adapter must escalate to its Claude equivalent'
    }
    $result.binary = $bin
    # `jcode version` prints a multi-line build table; the first line is the human form.
    $v = Invoke-Captured -FilePath $bin -Arguments @('version') -TimeoutSec 60
    if ($v.ExitCode -eq 0) {
        $firstLine = (([string]$v.StdOut).Replace("`r`n", "`n").Split("`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1)
        $result.version = ([string]$firstLine).Trim()
    }

    # Ask jcode's own read-only auth-status command instead of guessing one credential
    # filename: supported providers use different stores and environment variables.
    # Absence is reported rather than enforced because local/no-key providers are valid.
    $authProbe = Invoke-Captured -FilePath $bin -Arguments @(
        '--quiet', '--no-update', '--no-selfdev', 'auth', 'status', '--json') -TimeoutSec 60
    if ($authProbe.ExitCode -eq 0) {
        try {
            $authJson = ([string]$authProbe.StdOut) | ConvertFrom-Json
            $result.auth = [bool]$authJson.any_available
        } catch { $result.auth = $false }
    }
    $result.ok = $true
    if (Opt 'json') { Emit-JsonLocal $result; return }
    Write-Output ('binary : ' + $result.binary)
    Write-Output ('version: ' + $result.version)
    Write-Output ('auth   : ' + $(if ($result.auth) { 'at least one provider available' } else { 'no available provider reported (a local/no-key provider may still work)' }))
}

function Build-JcodeArgv {
    param(
        [string]$Worktree, [string]$Role, [string]$Model, [string]$Provider, [string]$Prompt
    )
    $tools = Resolve-RoleTools $Role

    $argv = [System.Collections.Generic.List[string]]::new()
    # argv[0] is the command NAME, for reporting only - Cmd-Run strips it and launches the
    # resolved absolute path. Honour --jcode-cmd here so `build-argv` shows what will
    # actually run rather than a hardcoded default.
    $cmdName = [string](Opt 'jcode-cmd' 'jcode')
    if ([string]::IsNullOrWhiteSpace($cmdName)) { $cmdName = 'jcode' }
    [void]$argv.Add($cmdName)
    # These are global flags. Keep them before the subcommand in the canonical wrapper
    # shape documented by jcode. In particular, --no-selfdev prevents repository
    # auto-detection from changing runtime behavior, and --no-update prevents an
    # autonomous leaf call from mutating the installed executable or adding update noise.
    [void]$argv.Add('--quiet')
    [void]$argv.Add('--no-update')
    [void]$argv.Add('--no-selfdev')
    # -C pins the process working directory to the task worktree. For the reviewer this
    # is the whole containment story (no shell, no write tools); for the coder it is a
    # default, backed by guard-tree afterwards.
    [void]$argv.Add('-C'); [void]$argv.Add($Worktree)
    [void]$argv.Add('--tools'); [void]$argv.Add(($tools -join ','))
    if ($Model)    { [void]$argv.Add('-m'); [void]$argv.Add($Model) }
    if ($Provider) { [void]$argv.Add('-p'); [void]$argv.Add($Provider) }
    [void]$argv.Add('run')
    # End-of-options separator before the positional message. Prompts are built from task
    # descriptions and review findings, so one can legitimately begin with '--' - and jcode
    # (clap) then rejects the whole invocation with "unexpected argument" instead of running.
    # Verified against v0.76.0: without `--` such a prompt is a hard parse error; with it the
    # message is taken verbatim.
    [void]$argv.Add('--')
    [void]$argv.Add($Prompt)
    return $argv.ToArray()
}

function Cmd-BuildArgv {
    $worktree = Require-Opt 'worktree'
    $role = Require-Opt 'role'
    $promptFile = [string](Opt 'prompt-file' '')
    $prompt = if ($promptFile) { Read-TextOrEmpty $promptFile } else { [string](Opt 'prompt' '') }
    if ([string]::IsNullOrWhiteSpace($prompt)) { Fail 2 'empty prompt (--prompt-file or --prompt)' }
    $argv = Build-JcodeArgv -Worktree $worktree -Role $role `
        -Model ([string](Opt 'model' '')) -Provider ([string](Opt 'provider' '')) -Prompt $prompt
    Emit-JsonLocal $argv
}

function Cmd-Run {
    $worktree = Require-Opt 'worktree'
    $role = Require-Opt 'role'
    if (-not (Test-Path -LiteralPath $worktree -PathType Container)) {
        Fail 2 "--worktree '$worktree' is not an existing directory"
    }
    $promptFile = Require-Opt 'prompt-file'
    $prompt = Read-TextOrEmpty $promptFile
    if ([string]::IsNullOrWhiteSpace($prompt)) { Fail 2 "prompt file '$promptFile' is empty" }

    $bin = Resolve-JcodeCmd
    if (-not $bin) {
        Fail 3 'jcode binary not found -> the adapter must escalate to its Claude equivalent'
    }

    $timeout = 1800
    $rawTimeout = [string](Opt 'timeout-sec' '1800')
    if ($rawTimeout -notmatch '^\d+$') { Fail 2 "--timeout-sec must be a non-negative integer (got '$rawTimeout')" }
    $timeout = [int]$rawTimeout

    $argv = Build-JcodeArgv -Worktree $worktree -Role $role `
        -Model ([string](Opt 'model' '')) -Provider ([string](Opt 'provider' '')) -Prompt $prompt
    # argv[0] is the command name for reporting; the launcher takes the resolved path.
    $callArgs = @($argv[1..($argv.Length - 1)])

    $res = Invoke-Captured -FilePath $bin -Arguments $callArgs -TimeoutSec $timeout -WorkingDirectory $worktree

    $outFile = [string](Opt 'out-file' '')
    $errFile = [string](Opt 'stderr-file' '')
    if ($outFile) { Write-TextNoBomLocal $outFile ([string]$res.StdOut) }
    if ($errFile) { Write-TextNoBomLocal $errFile ([string]$res.StdErr) }

    $timedOut = [bool]$res.TimedOut
    $failClass = ''
    if ($res.ExitCode -ne 0 -or $timedOut) {
        $failClass = if ($timedOut) { 'timeout' } else { Get-JcodeFailureClass ([string]$res.StdErr + "`n" + [string]$res.StdOut) }
    }

    $result = [ordered]@{
        exitCode   = [int]$res.ExitCode
        timedOut   = $timedOut
        role       = $role
        tools      = (Resolve-RoleTools $role) -join ','
        failClass  = $failClass
        outFile    = $outFile
        stderrFile = $errFile
    }
    $resultFile = [string](Opt 'result-file' '')
    if ($resultFile) { Write-TextNoBomLocal $resultFile ($result | ConvertTo-Json -Depth 12) }
    Emit-JsonLocal $result
    if ($res.ExitCode -ne 0 -or $timedOut) { exit 3 }
}

function Cmd-Snapshot {
    $worktree = Require-Opt 'worktree'
    $repoRoot = Require-Opt 'repo-root'
    $vcs = Require-Vcs
    $snap = New-TreeSnapshot -Worktree $worktree -RepoRoot $repoRoot -Vcs $vcs
    # An unreadable pre-image must abort here, not be recorded as empty: guard-tree can
    # only compare fields it actually has, so an empty head or an UNREADABLE digest would
    # silently disable the very check that replaces jcode's missing sandbox. Fail-closed.
    if ([string]$snap.worktreeHead -eq '') {
        Fail 3 "could not read the worktree head of '$worktree' via $vcs - refusing to start an unverifiable run"
    }
    if ([string]$snap.repoRootDigest -eq 'UNREADABLE') {
        Fail 3 "could not read the working-copy status of '$repoRoot' via $vcs - refusing to start an unverifiable run"
    }
    foreach ($sibling in @($snap.siblingTrees)) {
        if ([string]$sibling.head -eq '' -or [string]$sibling.digest -eq 'UNREADABLE') {
            Fail 3 "could not read sibling worktree '$($sibling.path)' via $vcs - refusing to start an unverifiable run"
        }
    }
    $out = [string](Opt 'out' '')
    if ($out) { Write-TextNoBomLocal $out ($snap | ConvertTo-Json -Depth 12) }
    Emit-JsonLocal $snap
}

function Cmd-GuardTree {
    # The compensating control for jcode's missing sandbox. DETECTION, not prevention:
    # it reports that the boundary was crossed, after the fact. The processor treats a
    # violation as a hard stop for that task (quarantine the branch, escalate), never as
    # a warning to continue past.
    $worktree = Require-Opt 'worktree'
    $repoRoot = Require-Opt 'repo-root'
    $vcs = Require-Vcs
    $beforeFile = Require-Opt 'before'
    if (-not (Test-Path -LiteralPath $beforeFile -PathType Leaf)) {
        Fail 2 "--before snapshot '$beforeFile' not found"
    }
    $before = Get-Content -LiteralPath $beforeFile -Raw -Encoding utf8 | ConvertFrom-Json
    $after = New-TreeSnapshot -Worktree $worktree -RepoRoot $repoRoot -Vcs $vcs

    $violations = [System.Collections.Generic.List[string]]::new()

    # An unreadable post-image is a violation, never a pass. Losing the ability to read
    # the tree is indistinguishable from a run that damaged it, and this guard is the only
    # boundary coder_jcode has - so it must fail closed on missing evidence too.
    if ([string]$after.worktreeHead -eq '') {
        $violations.Add("could not read the worktree head of '$worktree' after the run - isolation is unverifiable")
    }
    if ([string]$after.repoRootDigest -eq 'UNREADABLE') {
        $violations.Add("could not read the working-copy status of '$repoRoot' after the run - isolation is unverifiable")
    }
    if ([string]$after.repoRootControlDigest -eq 'UNREADABLE') {
        $violations.Add("could not read the control plane of '$repoRoot' after the run - isolation is unverifiable")
    }

    # A leaf agent never creates revisions - the processor owns all VCS writes.
    if ([string]$before.worktreeHead -ne '' -and [string]$before.worktreeHead -ne [string]$after.worktreeHead) {
        $violations.Add("worktree head moved ($($before.worktreeHead) -> $($after.worktreeHead)): jcode created a revision, which leaf agents must never do")
    }
    # The protected Orchestra trees outside the target may not change: no sandbox
    # stopped a `bash` call from reaching the main tree or a sibling task's worktree.
    if ([string]$before.repoRootHead -ne '' -and [string]$before.repoRootHead -ne [string]$after.repoRootHead) {
        $violations.Add("repository root head moved ($($before.repoRootHead) -> $($after.repoRootHead)): the run escaped its worktree")
    }
    if ([string]$before.repoRootDigest -ne 'UNREADABLE' -and [string]$before.repoRootDigest -ne [string]$after.repoRootDigest) {
        $violations.Add('repository root working-copy status changed: the run modified files outside its worktree')
    }
    if ([string]$before.repoRootControlDigest -ne [string]$after.repoRootControlDigest) {
        $violations.Add('repository root control-plane status changed: the run modified ignored .work files outside its worktree')
    }

    # Sibling task/integration worktrees live below .work and are ignored by the main
    # checkout, so the repo-root digest cannot see them. Compare their full diff-content
    # fingerprints and heads separately, including added/removed sibling directories.
    $beforeSiblings = @($before.siblingTrees)
    $afterSiblings = @($after.siblingTrees)
    $key = { param([string]$p) if ($IsWindows) { $p.ToLowerInvariant() } else { $p } }
    $beforeMap = @{}
    $afterMap = @{}
    foreach ($row in $beforeSiblings) { $beforeMap[(& $key ([string]$row.path))] = $row }
    foreach ($row in $afterSiblings) { $afterMap[(& $key ([string]$row.path))] = $row }
    $allSiblingKeys = @(@($beforeMap.Keys) + @($afterMap.Keys) | Sort-Object -Unique)
    foreach ($k in $allSiblingKeys) {
        if (-not $beforeMap.ContainsKey($k) -or -not $afterMap.ContainsKey($k)) {
            $violations.Add("sibling worktree set changed at '$k': the run escaped its worktree")
            continue
        }
        $b = $beforeMap[$k]
        $a = $afterMap[$k]
        if ([string]$a.head -eq '' -or [string]$a.digest -eq 'UNREADABLE') {
            $violations.Add("sibling worktree '$($a.path)' became unreadable: isolation is unverifiable")
        } elseif ([string]$b.head -ne [string]$a.head -or [string]$b.digest -ne [string]$a.digest) {
            $violations.Add("sibling worktree '$($a.path)' changed: the run modified files outside its worktree")
        }
    }

    $result = [ordered]@{
        ok         = ($violations.Count -eq 0)
        violations = $violations.ToArray()
        before     = $before
        after      = $after
    }
    Emit-JsonLocal $result
    if ($violations.Count -gt 0) { exit 3 }
}

function Cmd-PrepareReview {
    # The reviewer profile has no shell, so it cannot run `git diff` itself. Materialise
    # the diff and the changed-file list for it, OUTSIDE the worktree (default: the
    # task's own .work/tasks/<T-ID>/jcode/ directory) so the branch under review keeps a
    # pristine working copy - a stray review artefact inside the worktree would show up
    # as an uncommitted change and confuse the processor's own diff checks.
    #
    # --base is what makes this correct for the normal case. Per-task review runs AFTER
    # the processor has committed the branch, so the interesting diff is branch-vs-base,
    # and without --base the default (working copy vs HEAD) would be empty - a reviewer
    # handed an empty patch would report "no findings" on unreviewed code. The caller
    # passes the comparison revision; the default is only right when reviewing an
    # uncommitted working copy.
    $worktree = Require-Opt 'worktree'
    $vcs = Require-Vcs
    $outDir = Require-Opt 'out-dir'
    $baseRev = [string](Opt 'base' '')

    if (Test-PathAtOrUnder -Child $outDir -Root $worktree) {
        Fail 2 "--out-dir '$outDir' is inside the worktree; review artefacts must live outside it"
    }
    if (-not (Test-Path -LiteralPath $outDir)) { $null = New-Item -ItemType Directory -Force -Path $outDir }

    if ($vcs -eq 'jj') {
        $diffArgs = @('-R', $worktree, 'diff', '--git')
        if ($baseRev) { $diffArgs = @('-R', $worktree, 'diff', '--git', '--from', $baseRev) }
        $d = Invoke-Captured -FilePath 'jj' -Arguments $diffArgs -TimeoutSec 300
        $nameArgs = @('-R', $worktree, 'diff', '--summary')
        if ($baseRev) { $nameArgs = @('-R', $worktree, 'diff', '--summary', '--from', $baseRev) }
        $n = Invoke-Captured -FilePath 'jj' -Arguments $nameArgs -TimeoutSec 300
    } else {
        $target = if ($baseRev) { $baseRev } else { 'HEAD' }
        $d = Invoke-Captured -FilePath 'git' -Arguments @('-C', $worktree, 'diff', $target) -TimeoutSec 300
        $n = Invoke-Captured -FilePath 'git' -Arguments @('-C', $worktree, 'diff', '--stat', $target) -TimeoutSec 300
    }
    if ($d.ExitCode -ne 0) { Fail 3 "could not produce the review diff: $([string]$d.StdErr)" }

    $diffPath = Join-Path $outDir 'diff.patch'
    $statPath = Join-Path $outDir 'diffstat.txt'
    Write-TextNoBomLocal $diffPath ([string]$d.StdOut)
    Write-TextNoBomLocal $statPath ([string]$n.StdOut)

    Emit-JsonLocal ([ordered]@{
            diffFile  = $diffPath
            statFile  = $statPath
            diffBytes = ([string]$d.StdOut).Length
            empty     = ([string]::IsNullOrWhiteSpace([string]$d.StdOut))
        })
}

function Cmd-Classify {
    $text = ''
    $file = [string](Opt 'file' '')
    if ($file) { $text = Read-TextOrEmpty $file } else { $text = [string](Opt 'text' '') }
    Emit-JsonLocal ([ordered]@{ class = (Get-JcodeFailureClass $text) })
}

# Dot-source guard, mirroring codex-runtime.ps1: a caller that dot-sources this file
# gets the functions without the CLI dispatch firing.
if ($MyInvocation.InvocationName -eq '.') { return }

switch ($Command) {
    'preflight'      { Cmd-Preflight }
    'build-argv'     { Cmd-BuildArgv }
    'run'            { Cmd-Run }
    'snapshot'       { Cmd-Snapshot }
    'guard-tree'     { Cmd-GuardTree }
    'prepare-review' { Cmd-PrepareReview }
    'classify'       { Cmd-Classify }
    default {
        Fail 2 "unknown command '$Command'. Valid: preflight, build-argv, run, snapshot, guard-tree, prepare-review, classify"
    }
}
