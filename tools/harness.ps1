<#
.SYNOPSIS
    Hermetic end-to-end resilience harness for Orchestra's cohort lifecycle, over
    disposable git AND jj fixtures, with fault injection after every critical
    transition (task T-093).

.DESCRIPTION
    Orchestra's control loop (agents/processor.md) is an LLM prompt, but every one of
    its *critical state transitions* is mediated by an executable transactional tool:

      * the queue         -> tools/queue-tx.ps1   (capture / return / escalate / archive)
      * the control plane -> tools/state-tx.ps1   (owner lease + status-transition guard)
      * the event outbox  -> tools/outbox.ps1     (append-only .work/events.jsonl)
      * the code trees     -> git worktrees / jj workspaces (branch, integrate, publish)

    This harness drives those REAL tools and a REAL (but disposable, offline, never-pushed)
    git or jj repository through the full cohort lifecycle - lease/slot capture, cohort
    open, task capture (with dependencies), branch, review transitions, integration (clean
    or conflicting), a required-check gate, policy-violation halt, quarantine/requeue,
    publication (ff-merge into the trunk) and archival - and then, at each critical
    transition, injects a fault (a crash exactly before or after the tool's atomic commit,
    via the tool's own QUEUE_TX_FAULT / STATE_TX_FAULT / OUTBOX_FAULT hooks) and verifies
    that a crash-recovery replay converges to the SAME final worktree tree, the SAME
    .work/tasks archive + Tasks_Done.md, and the SAME deduplicated events.jsonl outbox as an
    uninterrupted run - or halts at a safe, diagnosable point (never a silent task loss or a
    Tasks_Queue.md / descriptor / outbox desync).

    It is a companion of the transaction tools it drives and does NOT reimplement or replace
    any guarantee they already provide (Phase-0 crash recovery, the outbox dedup / torn-tail
    repair, the quarantine counter): it exercises them end-to-end, composed.

    Everything is fully hermetic: the fixture is a fresh repo under the OS temp dir,
    isolated `user.name`/`user.email` are set locally, there is NO network and NO real
    remote/push (publication is a local ff-merge into the fixture's own trunk bookmark/
    branch). Nothing here touches the repository the harness itself lives in.

    The "final-state fingerprint" is deliberately timestamp- and event-id-independent (it
    hashes the deduplicated set of event *identities* - type + entity + transition - not the
    occurred_at / event_id), so a clean run and a faulted-then-recovered run of the same
    scenario produce the SAME fingerprint whenever they reach the same logical end state.

.NOTES
    Runs under PowerShell 7 (pwsh) and Windows PowerShell 5.1. Every VCS fixture is
    disposable; a jj scenario self-reports `skipped` (never fails) when the jj binary is
    absent, mirroring how the rest of the suite self-skips optional-binary cases.

    Exit codes:
      0   scenario ran and its assertions (if any internal ones) held
      2   usage / argument error
      3   a VCS backend needed by the scenario is not installed (git absent, or jj absent
          for a jj scenario) - the caller decides whether that is a skip or a failure
      4   a scenario reached an UNSAFE state (a divergence / silent loss the harness caught)

.EXAMPLE
    pwsh -File tools/harness.ps1 scenario --vcs git --name clean --json
    pwsh -File tools/harness.ps1 scenario --vcs jj  --name clean --fault capture:before-rename --json
    pwsh -File tools/harness.ps1 list-scenarios
    pwsh -File tools/harness.ps1 list-faults
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# --------------------------------------------------------------------------
# Argument parsing:  <command> [--key value | --flag] ...
# --------------------------------------------------------------------------
$Command = if ($args.Count -ge 1) { [string]$args[0] } else { '' }
$BoolFlags = @('json', 'keep')
$opts = @{}
for ($i = 1; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    if ($a -like '--*') {
        $key = $a.Substring(2)
        if ($BoolFlags -contains $key) { $opts[$key] = $true; continue }
        $i++
        if ($i -lt $args.Count) { $opts[$key] = [string]$args[$i] } else { $opts[$key] = '' }
    }
}
function Fail { param([int]$Code, [string]$Message) throw ('HRNERR|' + $Code + '|' + $Message) }
function Opt { param([string]$Name, $Default = $null) if ($opts.ContainsKey($Name)) { return $opts[$Name] } else { return $Default } }
function Require-Opt {
    param([string]$Name)
    if (-not $opts.ContainsKey($Name) -or [string]::IsNullOrEmpty([string]$opts[$Name])) { Fail 2 "missing required option --$Name" }
    return [string]$opts[$Name]
}

# --------------------------------------------------------------------------
# Tool locations + a PowerShell host to spawn them with.
# --------------------------------------------------------------------------
$script:ToolsDir = $PSScriptRoot
$script:QueueTx = Join-Path $script:ToolsDir 'queue-tx.ps1'
$script:StateTx = Join-Path $script:ToolsDir 'state-tx.ps1'
$script:Outbox = Join-Path $script:ToolsDir 'outbox.ps1'
$script:Policy = Join-Path $script:ToolsDir 'policy.ps1'
$script:OnWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows)
$script:PsHost = ([System.Diagnostics.Process]::GetCurrentProcess()).MainModule.FileName
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)

# Runs one of the transaction tools as a child process; returns @{ ExitCode; Out; Err }.
# $EnvVars lets a caller set a *_FAULT env var for exactly one invocation (crash injection).
function Invoke-Tool {
    param([string]$Tool, [string[]]$ToolArgs, [hashtable]$EnvVars = @{})
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:PsHost
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8
    $psi.StandardErrorEncoding = $script:Utf8
    foreach ($a in (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Tool) + $ToolArgs)) {
        $psi.ArgumentList.Add($a)
    }
    foreach ($k in $EnvVars.Keys) { $psi.Environment[$k] = [string]$EnvVars[$k] }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outT = $proc.StandardOutput.ReadToEndAsync()
    $errT = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Out = $outT.Result; Err = $errT.Result }
}

# Runs an external binary (git / jj); returns @{ ExitCode; Out; Err }. Never uses a shell.
# $WorkDir sets the child's working directory: jj resolves both the repo AND its file
# paths relative to cwd, so every jj call must run WITH cwd = the fixture repo (otherwise
# `jj file list` emits cwd-relative names that leak the random temp path into the
# fingerprint, and `jj file show <p>` cannot resolve <p>). It also guarantees a jj call
# only ever touches the fixture, never an ambient jj workspace of the host repo.
function Invoke-Bin {
    param([string]$File, [string[]]$BinArgs, [string]$WorkDir = '')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8
    $psi.StandardErrorEncoding = $script:Utf8
    if ($WorkDir) { $psi.WorkingDirectory = $WorkDir }
    foreach ($a in $BinArgs) { $psi.ArgumentList.Add([string]$a) }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outT = $proc.StandardOutput.ReadToEndAsync()
    $errT = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Out = $outT.Result; Err = $errT.Result }
}
# jj always runs with cwd = the fixture repo (see Invoke-Bin's $WorkDir note).
function Invoke-Jj { param($Fx, [string[]]$JjArgs) return (Invoke-Bin 'jj' $JjArgs -WorkDir $Fx.Repo) }
function Has-Bin { param([string]$Name) return [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# --------------------------------------------------------------------------
# Small IO helpers.
# --------------------------------------------------------------------------
function Read-Text { param([string]$Path) if (Test-Path -LiteralPath $Path) { return [System.IO.File]::ReadAllText($Path, $script:Utf8) } else { return '' } }
function Write-Text { param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8)
}
function Sha256Hex { param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $h = $sha.ComputeHash($script:Utf8.GetBytes($Text)) } finally { $sha.Dispose() }
    return -join ($h | ForEach-Object { $_.ToString('x2') })
}

# ==========================================================================
# VCS abstraction. The lifecycle uses only these operations; each dispatches
# on $Fx.Vcs ('git' | 'jj'). All are offline; publication is a local ff-merge
# into the fixture's own trunk (main), never a push.
# ==========================================================================
$script:TrunkFile = 'app.txt'

function Vcs-Init {
    param($Fx)
    $repo = $Fx.Repo
    if ($Fx.Vcs -eq 'git') {
        $r = Invoke-Bin 'git' @('init', '-q', '-b', 'main', $repo); if ($r.ExitCode -ne 0) { Fail 3 "git init failed: $($r.Err)" }
        Invoke-Bin 'git' @('-C', $repo, 'config', 'user.email', 't@example.invalid') | Out-Null
        Invoke-Bin 'git' @('-C', $repo, 'config', 'user.name', 'Harness') | Out-Null
        Invoke-Bin 'git' @('-C', $repo, 'config', 'commit.gpgsign', 'false') | Out-Null
        Write-Text (Join-Path $repo $script:TrunkFile) "l1`nl2`nl3`nl4`nl5`n"
        Invoke-Bin 'git' @('-C', $repo, 'add', '-A') | Out-Null
        $c = Invoke-Bin 'git' @('-C', $repo, 'commit', '-q', '-m', 'base'); if ($c.ExitCode -ne 0) { Fail 3 "git base commit failed: $($c.Err)" }
        $Fx.Base = (Invoke-Bin 'git' @('-C', $repo, 'rev-parse', 'HEAD')).Out.Trim()
    } else {
        # cwd = repo for every jj call (Invoke-Jj); the repo dir already exists (empty).
        $r = Invoke-Jj $Fx @('git', 'init'); if ($r.ExitCode -ne 0) { Fail 3 "jj git init failed: $($r.Err)" }
        Invoke-Jj $Fx @('config', 'set', '--repo', 'user.name', 'Harness') | Out-Null
        Invoke-Jj $Fx @('config', 'set', '--repo', 'user.email', 't@example.invalid') | Out-Null
        Write-Text (Join-Path $repo $script:TrunkFile) "l1`nl2`nl3`nl4`nl5`n"
        Invoke-Jj $Fx @('describe', '-m', 'base') | Out-Null
        Invoke-Jj $Fx @('bookmark', 'create', 'main', '-r', '@') | Out-Null
        Invoke-Jj $Fx @('new', 'main', '-m', 'wc') | Out-Null   # move off the base commit
        $Fx.Base = 'main'
    }
}

# Create a task branch/bookmark off BASE and commit a one-line edit to $script:TrunkFile.
# $Line selects which line (1..5) the task rewrites; two tasks editing the SAME line
# collide at integration (conflict scenario); different lines integrate cleanly.
function Vcs-TaskCommit {
    param($Fx, [string]$TaskId, [int]$Line, [string]$Token)
    $repo = $Fx.Repo
    $branch = "task/$TaskId"
    if ($Fx.Vcs -eq 'git') {
        $wt = Join-Path $Fx.Worktrees $TaskId
        if (-not (Test-Path -LiteralPath $wt)) {
            $r = Invoke-Bin 'git' @('-C', $repo, 'worktree', 'add', '-q', '-b', $branch, $wt, $Fx.Base)
            if ($r.ExitCode -ne 0) { Fail 4 "git worktree add for $TaskId failed: $($r.Err)" }
        }
        $f = Join-Path $wt $script:TrunkFile
        $lines = @(Get-Content -LiteralPath $f)
        $lines[$Line - 1] = "l$Line-$Token"
        Write-Text $f (($lines -join "`n") + "`n")
        Invoke-Bin 'git' @('-C', $wt, 'add', '-A') | Out-Null
        Invoke-Bin 'git' @('-C', $wt, 'commit', '-q', '-m', "$TaskId work") | Out-Null
    } else {
        Invoke-Jj $Fx @('new', 'main', '-m', "$TaskId work") | Out-Null
        $f = Join-Path $repo $script:TrunkFile
        $lines = @(Get-Content -LiteralPath $f)
        $lines[$Line - 1] = "l$Line-$Token"
        Write-Text $f (($lines -join "`n") + "`n")
        # snapshot the edit into the working-copy commit, then name it.
        Invoke-Jj $Fx @('bookmark', 'create', $branch, '-r', '@') | Out-Null
        Invoke-Jj $Fx @('new', 'main', '-m', 'wc') | Out-Null   # detach @ from the task commit
    }
}

# Integrate the given task branches into an integration branch/bookmark. Returns
# @{ Clean = $bool; Integrated = @(taskIds that merged clean) }. On a conflict the
# FIRST task is kept and each conflicting later task is reported as not integrated.
function Vcs-Integrate {
    param($Fx, [string[]]$TaskIds, [string]$BatchId)
    $repo = $Fx.Repo
    $integ = "integration/$BatchId"
    $kept = New-Object System.Collections.Generic.List[string]
    $rejected = New-Object System.Collections.Generic.List[string]
    if ($Fx.Vcs -eq 'git') {
        # Per-batch integration worktree branched off the CURRENT main tip (not the fixed
        # original base): a rolling cohort integrates several waves in sequence, and wave N+1
        # must build on wave N's already-published trunk so the ff-publish below stays a real
        # fast-forward. Recreate it fresh each call so a re-run/replay is deterministic.
        $wt = Join-Path $Fx.Worktrees ("_integration-" + $BatchId)
        if (Test-Path -LiteralPath $wt) { Invoke-Bin 'git' @('-C', $repo, 'worktree', 'remove', '--force', $wt) | Out-Null }
        Invoke-Bin 'git' @('-C', $repo, 'branch', '-D', $integ) | Out-Null   # drop a stale same-batch branch (ok if absent)
        $add = Invoke-Bin 'git' @('-C', $repo, 'worktree', 'add', '-q', '-b', $integ, $wt, 'main')
        if ($add.ExitCode -ne 0) { Fail 4 "git integration worktree add for $BatchId failed: $($add.Err)" }
        foreach ($t in $TaskIds) {
            $m = Invoke-Bin 'git' @('-C', $wt, 'merge', '--no-ff', '-m', "integrate $t", "task/$t")
            if ($m.ExitCode -ne 0) {
                Invoke-Bin 'git' @('-C', $wt, 'merge', '--abort') | Out-Null
                $rejected.Add($t)
            } else { $kept.Add($t) }
        }
    } else {
        # Build the integration commit as a merge of BASE + each kept task, one at a time,
        # so a conflicting task can be excluded deterministically.
        $parents = @('main')
        foreach ($t in $TaskIds) {
            $trial = $parents + @("task/$t")
            $newArgs = @('new') + $trial + @('-m', "integrate-trial $t")
            Invoke-Jj $Fx $newArgs | Out-Null
            $isConf = (Invoke-Jj $Fx @('log', '--no-graph', '-r', '@', '-T', 'if(conflict,"Y","N")')).Out.Trim()
            if ($isConf -eq 'Y') {
                $rejected.Add($t)
                Invoke-Jj $Fx @('abandon', '-r', '@') | Out-Null   # drop the trial merge
            } else {
                $kept.Add($t)
                $parents = $trial
            }
        }
        # Build the FINAL integration commit deterministically as a FRESH clean merge of
        # main + the KEPT tasks only - never name it from @. After abandoning a conflicting
        # LAST trial, @ is a new working-copy commit that still carries that trial's
        # conflicting parents, so `bookmark create -r @` would publish a CONFLICTED commit
        # whose materialized tree is non-deterministic (the jj conflict scenario's trunk
        # fingerprint flip-flopped between otherwise-identical runs). A fresh merge of only
        # the kept branches is content-identical to the last clean trial and stable.
        $finalParents = @('main') + @($kept | ForEach-Object { "task/$_" })
        Invoke-Jj $Fx (@('new') + $finalParents + @('-m', "integration $BatchId")) | Out-Null
        Invoke-Jj $Fx @('bookmark', 'create', $integ, '-r', '@') | Out-Null
        Invoke-Jj $Fx @('new', $integ, '-m', 'wc') | Out-Null
    }
    return [pscustomobject]@{ Clean = ($rejected.Count -eq 0); Integrated = @($kept); Rejected = @($rejected) }
}

# ff-merge the integration branch into the trunk (main). Local only; never a push.
function Vcs-Publish {
    param($Fx, [string]$BatchId)
    $repo = $Fx.Repo
    $integ = "integration/$BatchId"
    if ($Fx.Vcs -eq 'git') {
        $r = Invoke-Bin 'git' @('-C', $repo, 'merge', '--ff-only', $integ)   # HEAD is main in the primary worktree
        if ($r.ExitCode -ne 0) { Fail 4 "git ff publish failed: $($r.Err)" }
    } else {
        Invoke-Jj $Fx @('bookmark', 'set', 'main', '-r', $integ) | Out-Null
    }
}

# Deterministic content fingerprint of the trunk tip (path=sha256 for each tracked file).
function Vcs-TreeFingerprint {
    param($Fx)
    $repo = $Fx.Repo
    if ($Fx.Vcs -eq 'git') {
        $ls = Invoke-Bin 'git' @('-C', $repo, 'ls-tree', '-r', '--name-only', 'main')
        $names = @($ls.Out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object)
        $parts = foreach ($n in $names) {
            $blob = (Invoke-Bin 'git' @('-C', $repo, 'show', "main:$n")).Out
            "$n=" + (Sha256Hex $blob)
        }
        return (Sha256Hex ($parts -join "`n"))
    } else {
        $ls = Invoke-Jj $Fx @('file', 'list', '-r', 'main')
        $names = @($ls.Out -split "`n" | ForEach-Object { ($_ -replace '\\', '/').Trim() } | Where-Object { $_ } | Sort-Object)
        $parts = foreach ($n in $names) {
            $blob = (Invoke-Jj $Fx @('file', 'show', '-r', 'main', $n)).Out
            "$n=" + (Sha256Hex $blob)
        }
        return (Sha256Hex ($parts -join "`n"))
    }
}

# ==========================================================================
# Fixture: a disposable repo + an isolated .work sandbox with a minimal config.
# ==========================================================================
function New-Fixture {
    param([string]$Vcs, [string]$Path)
    if (-not $Path) { $Path = Join-Path ([System.IO.Path]::GetTempPath()) ('orc-harness-' + [guid]::NewGuid().ToString('N')) }
    $repo = Join-Path $Path 'repo'
    $work = Join-Path $repo '.work'
    $null = New-Item -ItemType Directory -Force -Path $repo
    $fx = [pscustomobject]@{
        Vcs        = $Vcs
        Root       = $Path
        Repo       = $repo
        Work       = $work
        Worktrees  = Join-Path $work 'worktrees'
        IntegWt    = Join-Path $work 'worktrees/_integration'
        Base       = ''
        Owner      = ''
        BatchId    = 'B-20260101T000000Z'
    }
    Vcs-Init $fx
    $null = New-Item -ItemType Directory -Force -Path $fx.Work
    $null = New-Item -ItemType Directory -Force -Path $fx.Worktrees
    return $fx
}

# ==========================================================================
# Final-state fingerprint (timestamp / event-id independent). Combines:
#   tree   - trunk content, queue - normalized task headers+status,
#   archive- Tasks_Done archived ids + remaining descriptors+status,
#   outbox - deduplicated set of event IDENTITIES (type|batch|task|from>to).
# ==========================================================================
function Get-QueueDigest {
    param($Fx)
    $q = Read-Text (Join-Path $Fx.Work 'Tasks_Queue.md')
    $rows = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($q -split "`n")) {
        $m = [regex]::Match($line, '^###\s+\[(T-\d+)\].*?—\s*статус:\s*([^\r·]+?)(?:\s*·|$)')
        if ($m.Success) {
            $attempt = ''
            $am = [regex]::Match($line, 'попытка=(\d+)')
            if ($am.Success) { $attempt = "/попытка=$($am.Groups[1].Value)" }
            $rows.Add(($m.Groups[1].Value + '=' + $m.Groups[2].Value.Trim() + $attempt))
        }
    }
    return (($rows | Sort-Object) -join ';')
}
function Get-ArchiveDigest {
    param($Fx)
    $done = Read-Text (Join-Path $Fx.Work 'Tasks_Done.md')
    $doneIds = @([regex]::Matches($done, '\[(T-\d+)\]') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $tasksDir = Join-Path $Fx.Work 'tasks'
    $descr = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $tasksDir) {
        foreach ($d in (Get-ChildItem -LiteralPath $tasksDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $tm = Join-Path $d.FullName 'task.md'
            $st = ''
            if (Test-Path -LiteralPath $tm) {
                $sm = [regex]::Match((Read-Text $tm), '(?m)^Статус:\s*(.+?)\s*$')
                if ($sm.Success) { $st = $sm.Groups[1].Value }
            }
            $descr.Add("$($d.Name)=$st")
        }
    }
    return 'done:' + ($doneIds -join ',') + '|descr:' + (($descr) -join ',')
}
# Safe JSON property probes (avoid StrictMode's member-enumeration-over-empty-collection
# throw that .PSObject.Properties.Name triggers on an empty object such as payload {}).
function JHas { param($Obj, [string]$Name) return ($null -ne $Obj -and $null -ne $Obj.PSObject.Properties[$Name]) }
function JGet { param($Obj, [string]$Name) if (JHas $Obj $Name) { return $Obj.$Name } else { return $null } }

function Get-OutboxDigest {
    param($Fx)
    $ev = Join-Path $Fx.Work 'events.jsonl'
    if (-not (Test-Path -LiteralPath $ev)) { return '' }
    $ids = @{}
    $identities = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Read-Text $ev) -split "`n") {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $o = $null
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if (-not (JHas $o 'event_id')) { continue }
        $eid = [string]$o.event_id
        if ($ids.ContainsKey($eid)) { continue }
        $ids[$eid] = $true
        $batch = [string](JGet $o 'batch_id')
        $task = [string](JGet $o 'task_id')
        $trans = ''
        $pl = JGet $o 'payload'
        if ($pl) {
            $from = [string](JGet $pl 'from')
            $to = [string](JGet $pl 'to')
            if ($from -or $to) { $trans = "$from>$to" }
        }
        $identities.Add(("{0}|{1}|{2}|{3}" -f [string]$o.type, $batch, $task, $trans))
    }
    return (($identities | Sort-Object) -join ';')
}
function Get-Fingerprint {
    param($Fx)
    $tree = Vcs-TreeFingerprint $Fx
    $queue = Get-QueueDigest $Fx
    $archive = Get-ArchiveDigest $Fx
    $outbox = Get-OutboxDigest $Fx
    return [pscustomobject]@{
        Tree     = $tree
        Queue    = $queue
        Archive  = $archive
        Outbox   = $outbox
        Combined = Sha256Hex ("tree=$tree`nqueue=$queue`narchive=$archive`noutbox=$outbox")
    }
}

# ==========================================================================
# Fault injection. A fault is "<target>:<stage>". Each target is a single
# critical transition mediated by exactly one transactional tool, so injecting
# the tool's own crash hook models a crash exactly at that transition.
#   pre-commit  stage (before-rename / before-write): the atomic commit did NOT
#               land -> crash-recovery must replay the transition.
#   post-commit stage (after-rename): the atomic commit DID land, then the process
#               died -> recovery must DETECT it and continue without re-applying.
# ==========================================================================
$script:FaultTargets = @{
    'lease'     = @{ EnvVar = 'STATE_TX_FAULT';  Stages = @('before-rename', 'after-rename') }
    'capture'   = @{ EnvVar = 'QUEUE_TX_FAULT';  Stages = @('before-rename', 'after-rename') }
    'archive'   = @{ EnvVar = 'QUEUE_TX_FAULT';  Stages = @('before-rename', 'after-rename') }
    'to-review' = @{ EnvVar = 'OUTBOX_FAULT';    Stages = @('before-write') }
    'integrate' = @{ EnvVar = 'OUTBOX_FAULT';    Stages = @('before-write') }
    'publish'   = @{ EnvVar = 'OUTBOX_FAULT';    Stages = @('before-write') }
}
function Parse-Fault {
    param([string]$Spec)
    if (-not $Spec) { return $null }
    $parts = $Spec -split ':', 2
    if ($parts.Count -ne 2) { Fail 2 "bad --fault '$Spec' (expected <target>:<stage>)" }
    $target = $parts[0]; $stage = $parts[1]
    if (-not $script:FaultTargets.ContainsKey($target)) { Fail 2 "unknown fault target '$target' (valid: $(($script:FaultTargets.Keys | Sort-Object) -join ', '))" }
    $entry = $script:FaultTargets[$target]
    if ($entry.Stages -notcontains $stage) { Fail 2 "fault target '$target' does not support stage '$stage' (valid: $($entry.Stages -join ', '))" }
    return [pscustomobject]@{ Target = $target; Stage = $stage; EnvVar = $entry.EnvVar; Post = ($stage -eq 'after-rename') }
}

# Runs a transactional tool call. When the active fault targets THIS step, first runs it
# with the crash hook (must fail), then reconciles per pre/post-commit semantics before
# replaying/continuing. $CommittedProbe reports whether the atomic commit is on disk.
function Guarded-ToolCall {
    param($Fx, [string]$StepName, [string]$Tool, [string[]]$ToolArgs, [scriptblock]$CommittedProbe = $null)
    $f = $Fx.Fault
    if ($f -and $f.Target -eq $StepName) {
        $r1 = Invoke-Tool $Tool $ToolArgs @{ $f.EnvVar = $f.Stage }
        $Fx.FaultFired = $true
        if ($r1.ExitCode -eq 0) { Fail 4 "injected fault '$($f.Stage)' at step '$StepName' did not interrupt the tool (exit 0)" }
        $committed = $false
        if ($CommittedProbe) { $committed = [bool](& $CommittedProbe) }
        if ($f.Post) {
            if (-not $committed) { Fail 4 "post-commit fault at '$StepName': commit not on disk after crash (possible silent loss)" }
            return [pscustomobject]@{ ExitCode = 0; Out = 'recovered-post-commit'; Err = ''; Skipped = $true }
        }
        if ($committed) { Fail 4 "pre-commit fault at '$StepName': mutation landed despite a pre-commit crash (atomicity broken)" }
        # fall through to a clean replay of the transition
    }
    $r = Invoke-Tool $Tool $ToolArgs
    if ($r.ExitCode -ne 0) { Fail 4 "step '$StepName' failed: exit $($r.ExitCode) $([string]$r.Err)$([string]$r.Out)" }
    return $r
}

# --------------------------------------------------------------------------
# Descriptor / coordination-file helpers (harness-internal, all idempotent).
# --------------------------------------------------------------------------
function Set-Descriptor {
    param($Fx, [string]$TaskId, [string]$Status)
    $dir = Join-Path $Fx.Work "tasks/$TaskId"
    Write-Text (Join-Path $dir 'task.md') "# $TaskId`nСтатус: $Status`nВетка: task/$TaskId`n"
}
function Remove-Descriptor {
    param($Fx, [string]$TaskId)
    $dir = Join-Path $Fx.Work "tasks/$TaskId"
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}
function Lease-Owner {
    param($Fx)
    $p = Join-Path $Fx.Work 'orchestrator.lock/lease.json'
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    try { return [string]((Read-Text $p | ConvertFrom-Json).owner_id) } catch { return '' }
}
function Queue-Status {
    param($Fx, [string]$TaskId)
    $q = Read-Text (Join-Path $Fx.Work 'Tasks_Queue.md')
    $m = [regex]::Match($q, "###\s+\[$([regex]::Escape($TaskId))\].*?—\s*статус:\s*([^\r`n]+)")
    if ($m.Success) { return $m.Groups[1].Value } else { return '' }
}

# --------------------------------------------------------------------------
# Critical-transition steps.
# --------------------------------------------------------------------------
function Step-Lease {
    param($Fx)
    $lease = Join-Path $Fx.Work 'orchestrator.lock/lease.json'
    Guarded-ToolCall $Fx 'lease' $script:StateTx `
        @('acquire', '--work', $Fx.Work, '--root', $Fx.Repo, '--role', 'processor', '--ttl', '900') `
        { Test-Path -LiteralPath $lease } | Out-Null
    $Fx.Owner = Lease-Owner $Fx
    if (-not $Fx.Owner) { Fail 4 'lease acquired but owner id unreadable from lease.json' }
}
function Emit-Event {
    param($Fx, [string]$StepName, [string[]]$EventArgs)
    $base = @('append', '--work', $Fx.Work, '--owner', $Fx.Owner) + $EventArgs
    if ($StepName) {
        Guarded-ToolCall $Fx $StepName $script:Outbox $base $null | Out-Null
    } else {
        $r = Invoke-Tool $script:Outbox $base
        if ($r.ExitCode -ne 0) { Fail 4 "outbox append failed: $([string]$r.Err)$([string]$r.Out)" }
    }
}
function Step-CohortOpen {
    param($Fx, [string[]]$TaskIds)
    Write-Text (Join-Path $Fx.Work 'batch.md') "# Батч $($Fx.BatchId)`nБаза: $($Fx.Base)`nЗадачи: $($TaskIds -join ', ')`n"
    Write-Text (Join-Path $Fx.Work 'cohort_state.md') "# Когорта`nПриём: закрыт`nВолна: 1`n"
    Emit-Event $Fx $null @('--type', 'cohort.opened', '--batch-id', $Fx.BatchId, '--payload', '{"wave":1}')
}
function Step-Capture {
    param($Fx, [string]$TaskId)
    Guarded-ToolCall $Fx 'capture' $script:QueueTx `
        @('capture', '--work', $Fx.Work, '--id', $TaskId, '--batch', $Fx.BatchId) `
        { (Queue-Status $Fx $TaskId) -match 'в работе' } | Out-Null
    Set-Descriptor $Fx $TaskId 'в работе'
    Emit-Event $Fx $null @('--type', 'task.captured', '--batch-id', $Fx.BatchId, '--task-id', $TaskId, '--attempt', '1', '--payload', '{"level":"coder"}')
}
function Step-ToReview {
    param($Fx, [string]$TaskId)
    # Validate the transition through the real state-machine guard (read-only).
    $ct = Invoke-Tool $script:StateTx @('check-transition', '--kind', 'task', '--from', 'working', '--to', 'in-review')
    if ($ct.ExitCode -ne 0) { Fail 4 "state-tx rejected working->in-review: $($ct.Err)" }
    Emit-Event $Fx 'to-review' @('--type', 'task.status_changed', '--task-id', $TaskId, '--from', 'в работе', '--to', 'на ревью', '--attempt', '1', '--round', '1', '--payload', '{"from":"в работе","to":"на ревью"}')
    Set-Descriptor $Fx $TaskId 'на ревью'
}
function Step-ToReady {
    param($Fx, [string]$TaskId)
    Emit-Event $Fx $null @('--type', 'task.status_changed', '--task-id', $TaskId, '--from', 'на ревью', '--to', 'готова к слиянию', '--attempt', '1', '--round', '1', '--payload', '{"from":"на ревью","to":"готова к слиянию"}')
    Set-Descriptor $Fx $TaskId 'готова к слиянию'
}
function Step-PublishTask {
    param($Fx, [string]$TaskId)
    Emit-Event $Fx 'publish' @('--type', 'task.status_changed', '--task-id', $TaskId, '--from', 'готова к слиянию', '--to', 'опубликована', '--attempt', '1', '--round', '1', '--payload', '{"from":"готова к слиянию","to":"опубликована"}')
    Set-Descriptor $Fx $TaskId 'опубликована'
}
function Step-Archive {
    param($Fx, [string]$TaskId)
    Emit-Event $Fx $null @('--type', 'task.status_changed', '--task-id', $TaskId, '--from', 'опубликована', '--to', 'выполнена', '--attempt', '1', '--round', '1', '--payload', '{"from":"опубликована","to":"выполнена"}')
    Guarded-ToolCall $Fx 'archive' $script:QueueTx `
        @('archive', '--work', $Fx.Work, '--id', $TaskId) `
        { -not (Queue-Status $Fx $TaskId) } | Out-Null
    Remove-Descriptor $Fx $TaskId
    $done = Join-Path $Fx.Work 'Tasks_Done.md'
    $cur = Read-Text $done
    if ($cur -notmatch [regex]::Escape("[$TaskId]")) { Write-Text $done ($cur + "### [$TaskId] done`n") }
}

# Full happy-path lifecycle of one task from capture through archive (given its branch
# already exists). Publication is a per-task transition; the VCS ff-merge is done once
# per integration by the caller.
function Lifecycle-Task {
    param($Fx, [string]$TaskId)
    Step-Capture $Fx $TaskId
    Step-ToReview $Fx $TaskId
    Step-ToReady $Fx $TaskId
}

# --------------------------------------------------------------------------
# Seeds the queue with the scenario's task proposals.
# --------------------------------------------------------------------------
function Seed-Task {
    param($Fx, [string]$TaskId, [string]$Title, [string]$Predecessors = '')
    $a = @('propose', '--work', $Fx.Work, '--id', $TaskId, '--title', $Title)
    if ($Predecessors) { $a += @('--predecessors', $Predecessors) }
    $r = Invoke-Tool $script:QueueTx $a
    if ($r.ExitCode -ne 0) { Fail 4 "seed propose $TaskId failed: $([string]$r.Err)$([string]$r.Out)" }
}

# ==========================================================================
# Scenarios. Each returns @{ Outcome; Notes }. All share the same instrumented
# transition steps, so any of them can be run with any --fault target it exercises.
# ==========================================================================
$script:Scenarios = @('clean', 'deps', 'conflict', 'quarantine', 'policy', 'checks', 'publish', 'resume',
    'ci-delayed', 'ci-rerun', 'ci-outage', 'approve', 'reject', 'approval-timeout', 'approval-stale')

function Scenario-Clean {
    param($Fx)
    $t1 = 'T-101'; $t2 = 'T-102'
    Seed-Task $Fx $t1 'clean one'
    Seed-Task $Fx $t2 'clean two'
    Step-Lease $Fx
    Step-CohortOpen $Fx @($t1, $t2)
    Vcs-TaskCommit $Fx $t1 2 'A'
    Vcs-TaskCommit $Fx $t2 4 'B'
    Lifecycle-Task $Fx $t1
    Lifecycle-Task $Fx $t2
    $integ = Vcs-Integrate $Fx @($t1, $t2) $Fx.BatchId
    if (-not $integ.Clean) { Fail 4 'clean scenario unexpectedly conflicted' }
    Emit-Event $Fx 'integrate' @('--type', 'cohort.join_started', '--batch-id', $Fx.BatchId, '--payload', '{}')
    Vcs-Publish $Fx $Fx.BatchId
    Step-PublishTask $Fx $t1
    Step-PublishTask $Fx $t2
    Emit-Event $Fx $null @('--type', 'cohort.published', '--batch-id', $Fx.BatchId, '--payload', '{"pushed":false}')
    Step-Archive $Fx $t1
    Step-Archive $Fx $t2
    Emit-Event $Fx $null @('--type', 'cohort.closed', '--batch-id', $Fx.BatchId, '--payload', '{"merged":2,"quarantined":0,"escalated":0}')
    return [pscustomobject]@{ Outcome = 'published'; Notes = '2 tasks integrated clean, published, archived' }
}

function Scenario-Publish { param($Fx) return (Scenario-Clean $Fx) }
function Scenario-Resume  { param($Fx) return (Scenario-Clean $Fx) }

function Scenario-Checks {
    param($Fx)
    # Like clean, but a required-check gate (a real child command that exits 0) must pass
    # before publication - modelling the SMOKE_CMD / required-checks gate.
    $t1 = 'T-101'
    Seed-Task $Fx $t1 'checks one'
    Step-Lease $Fx
    Step-CohortOpen $Fx @($t1)
    Vcs-TaskCommit $Fx $t1 3 'C'
    Lifecycle-Task $Fx $t1
    $integ = Vcs-Integrate $Fx @($t1) $Fx.BatchId
    if (-not $integ.Clean) { Fail 4 'checks scenario unexpectedly conflicted' }
    Emit-Event $Fx 'integrate' @('--type', 'cohort.join_started', '--batch-id', $Fx.BatchId, '--payload', '{}')
    # required check: a hermetic no-op command that must succeed.
    $chk = Invoke-Bin $script:PsHost @('-NoProfile', '-Command', 'exit 0')
    if ($chk.ExitCode -ne 0) { Fail 4 'required check failed' }
    Vcs-Publish $Fx $Fx.BatchId
    Step-PublishTask $Fx $t1
    Emit-Event $Fx $null @('--type', 'cohort.published', '--batch-id', $Fx.BatchId, '--payload', '{"pushed":false}')
    Step-Archive $Fx $t1
    Emit-Event $Fx $null @('--type', 'cohort.closed', '--batch-id', $Fx.BatchId, '--payload', '{"merged":1,"quarantined":0,"escalated":0}')
    return [pscustomobject]@{ Outcome = 'published'; Notes = 'required-check gate passed, 1 task published' }
}

function Scenario-Deps {
    param($Fx)
    # T-102 declares T-101 as a mandatory predecessor: it must not be capturable until
    # T-101 is archived. Exercises the queue readiness gate across two sequential waves.
    $t1 = 'T-101'; $t2 = 'T-102'
    Seed-Task $Fx $t1 'dep base'
    Seed-Task $Fx $t2 'dep dependent' $t1
    Step-Lease $Fx
    Step-CohortOpen $Fx @($t1)
    # gate: dependent is not ready before the predecessor is archived.
    $rdy = Invoke-Tool $script:QueueTx @('ready', '--work', $Fx.Work, '--id', $t2)
    if ($rdy.ExitCode -ne 6) { Fail 4 "deps: dependent should be not-ready before predecessor archived (got exit $($rdy.ExitCode): $($rdy.Out)$($rdy.Err))" }
    # wave 1: fully process T-101.
    Vcs-TaskCommit $Fx $t1 2 'A'
    Lifecycle-Task $Fx $t1
    $integ1 = Vcs-Integrate $Fx @($t1) $Fx.BatchId
    if (-not $integ1.Clean) { Fail 4 'deps wave1 conflicted' }
    Emit-Event $Fx 'integrate' @('--type', 'cohort.join_started', '--batch-id', $Fx.BatchId, '--payload', '{"wave":1}')
    Vcs-Publish $Fx $Fx.BatchId
    Step-PublishTask $Fx $t1
    Emit-Event $Fx $null @('--type', 'cohort.published', '--batch-id', $Fx.BatchId, '--payload', '{"pushed":false}')
    Step-Archive $Fx $t1
    # gate: now the dependent is ready.
    $rdy2 = Invoke-Tool $script:QueueTx @('ready', '--work', $Fx.Work, '--id', $t2)
    if ($rdy2.ExitCode -ne 0) { Fail 4 "deps: dependent should be ready after predecessor archived (got exit $($rdy2.ExitCode): $($rdy2.Out)$($rdy2.Err))" }
    # wave 2: process T-102 (own integration branch).
    $b2 = 'B-20260101T000001Z'
    Vcs-TaskCommit $Fx $t2 4 'B'
    Step-Capture $Fx $t2
    Step-ToReview $Fx $t2
    Step-ToReady $Fx $t2
    $integ2 = Vcs-Integrate $Fx @($t2) $b2
    if (-not $integ2.Clean) { Fail 4 'deps wave2 conflicted' }
    Emit-Event $Fx $null @('--type', 'cohort.join_started', '--batch-id', $b2, '--payload', '{"wave":2}')
    Vcs-Publish $Fx $b2
    Step-PublishTask $Fx $t2
    Step-Archive $Fx $t2
    Emit-Event $Fx $null @('--type', 'cohort.closed', '--batch-id', $Fx.BatchId, '--payload', '{"merged":2,"quarantined":0,"escalated":0}')
    return [pscustomobject]@{ Outcome = 'published'; Notes = 'dependency gate honoured across two waves' }
}

function Scenario-Conflict {
    param($Fx)
    # Two tasks rewrite the SAME line -> integration conflicts on the second; the first
    # publishes, the second is quarantined (requeued with an incremented попытка counter,
    # merge_report.md rewritten in the single quarantine format) and its descriptor cleaned.
    $t1 = 'T-101'; $t2 = 'T-102'
    Seed-Task $Fx $t1 'conf one'
    Seed-Task $Fx $t2 'conf two'
    Step-Lease $Fx
    Step-CohortOpen $Fx @($t1, $t2)
    Vcs-TaskCommit $Fx $t1 2 'A'
    Vcs-TaskCommit $Fx $t2 2 'B'    # same line -> conflict
    Lifecycle-Task $Fx $t1
    Lifecycle-Task $Fx $t2
    $integ = Vcs-Integrate $Fx @($t1, $t2) $Fx.BatchId
    if ($integ.Clean) { Fail 4 'conflict scenario unexpectedly integrated clean' }
    if (@($integ.Rejected).Count -ne 1 -or $integ.Rejected[0] -ne $t2) { Fail 4 "conflict: expected only $t2 rejected, got [$($integ.Rejected -join ',')]" }
    Emit-Event $Fx 'integrate' @('--type', 'cohort.join_started', '--batch-id', $Fx.BatchId, '--payload', '{}')
    # quarantine the conflicting task via the real queue transaction (bounded requeue).
    $ret = Invoke-Tool $script:QueueTx @('return', '--work', $Fx.Work, '--id', $t2, '--reason', 'конфликт слияния', '--max-attempts', '3')
    if ($ret.ExitCode -ne 0) { Fail 4 "quarantine return failed: $($ret.Err)" }
    Write-Text (Join-Path $Fx.Work 'merge_report.md') "# merge_report`n- [$t2] quarantined=конфликт слияния`n"
    Remove-Descriptor $Fx $t2
    # publish the survivor.
    Vcs-Publish $Fx $Fx.BatchId
    Step-PublishTask $Fx $t1
    Emit-Event $Fx $null @('--type', 'cohort.published', '--batch-id', $Fx.BatchId, '--payload', '{"pushed":false}')
    Step-Archive $Fx $t1
    Emit-Event $Fx $null @('--type', 'cohort.closed', '--batch-id', $Fx.BatchId, '--payload', '{"merged":1,"quarantined":1,"escalated":0}')
    return [pscustomobject]@{ Outcome = 'partial'; Notes = "$t1 published, $t2 quarantined+requeued" }
}

function Scenario-Quarantine {
    param($Fx)
    # A single task fails a required integration check and is requeued via the quarantine
    # counter until it exhausts QUARANTINE_MAX_ATTEMPTS, at which point queue-tx escalates
    # it terminally (never an infinite recapture). Demonstrates the bounded requeue path.
    $t1 = 'T-101'
    Seed-Task $Fx $t1 'flaky one'
    Step-Lease $Fx
    Step-CohortOpen $Fx @($t1)
    Vcs-TaskCommit $Fx $t1 3 'Q'
    Lifecycle-Task $Fx $t1
    Emit-Event $Fx 'integrate' @('--type', 'cohort.join_started', '--batch-id', $Fx.BatchId, '--payload', '{}')
    # required check fails on every attempt -> requeue until the cap, then escalate.
    $max = 3
    $escalated = $false
    for ($n = 1; $n -le $max + 1; $n++) {
        $ret = Invoke-Tool $script:QueueTx @('return', '--work', $Fx.Work, '--id', $t1, '--reason', 'сломала проверку', '--max-attempts', "$max")
        if ($ret.ExitCode -ne 0) { Fail 4 "quarantine return #$n failed: $($ret.Err)" }
        Remove-Descriptor $Fx $t1
        if ((Queue-Status $Fx $t1) -match 'эскалирована') { $escalated = $true; break }
    }
    if (-not $escalated) { Fail 4 'quarantine: task never escalated after exhausting attempts (possible infinite requeue)' }
    Emit-Event $Fx $null @('--type', 'cohort.closed', '--batch-id', $Fx.BatchId, '--payload', '{"merged":0,"quarantined":0,"escalated":1}')
    return [pscustomobject]@{ Outcome = 'escalated'; Notes = 'bounded requeue then terminal escalation' }
}

function Scenario-Policy {
    param($Fx)
    # A task's change touches a denylisted path. The real policy guard (tools/policy.ps1
    # check-paths) must DENY it, and the task is escalated (a safe, diagnosable halt) - it
    # never reaches integration/publication.
    $t1 = 'T-101'
    Seed-Task $Fx $t1 'policy one'
    # a constraints.md whose ACTIVE denylist forbids **/secrets/** (the parser reads only
    # bullets under the "**Активные ограничения**" marker; see policy-schema.ps1).
    Write-Text (Join-Path $Fx.Work 'constraints.md') "## Запрещённые пути (denylist)`n`n**Активные ограничения**:`n`n- ``**/secrets/**```n"
    Step-Lease $Fx
    Step-CohortOpen $Fx @($t1)
    Vcs-TaskCommit $Fx $t1 3 'P'
    Step-Capture $Fx $t1
    Step-ToReview $Fx $t1
    # the guard rejects a denylisted changed path.
    $guard = Invoke-Tool $script:Policy @('check-paths', '--work', $Fx.Work, '--path', 'app/secrets/token.txt')
    if ($guard.ExitCode -eq 0) { Fail 4 'policy: denylisted path was NOT rejected by the guard' }
    $esc = Invoke-Tool $script:QueueTx @('escalate', '--work', $Fx.Work, '--id', $t1, '--reason', 'запрещённый путь (denylist)')
    if ($esc.ExitCode -ne 0) { Fail 4 "policy escalate failed: $($esc.Err)" }
    Set-Descriptor $Fx $t1 'эскалирована'
    Emit-Event $Fx $null @('--type', 'cohort.closed', '--batch-id', $Fx.BatchId, '--payload', '{"merged":0,"quarantined":0,"escalated":1}')
    return [pscustomobject]@{ Outcome = 'escalated'; Notes = 'policy denylist hit -> safe escalation halt' }
}

# --------------------------------------------------------------------------
# Publish-gate (T-095) helpers: drive the REAL tools/policy.ps1 check-gate /
# approval-* verbs deterministically (fixed sha, elapsed, deadline, now) so a
# faulted-then-recovered run reaches the same logical end state as a clean run.
# --------------------------------------------------------------------------
$script:CiChecksName = 'ci_runs.jsonl'
function Set-CiConstraints {
    param($Fx, [string[]]$Checks)
    $body = "## Обязательные CI-проверки публикации`n`n**Активные ограничения**:`n`n"
    foreach ($c in $Checks) { $body += "- ``$c```n" }
    Write-Text (Join-Path $Fx.Work 'constraints.md') $body
}
function Write-CiRuns {
    param($Fx, [object[]]$Runs)
    $lines = foreach ($r in $Runs) { ($r | ConvertTo-Json -Compress) }
    Write-Text (Join-Path $Fx.Work $script:CiChecksName) (($lines -join "`n") + "`n")
}
function Assert-Gate {
    param($Fx, [string]$Sha, [int]$Elapsed, [int]$ExpectExit, [string]$ExpectVerdict)
    $checks = Join-Path $Fx.Work $script:CiChecksName
    $r = Invoke-Tool $script:Policy @('check-gate', '--work', $Fx.Work, '--sha', $Sha, '--checks-from', $checks, '--elapsed-sec', "$Elapsed", '--deadline-sec', '600', '--backoff-sec', '30', '--json')
    if ($r.ExitCode -ne $ExpectExit) { Fail 4 "check-gate expected exit $ExpectExit at elapsed=$Elapsed, got $($r.ExitCode): $([string]$r.Out)$([string]$r.Err)" }
    $v = ''
    try { $v = ([string]$r.Out).Trim() | ConvertFrom-Json | ForEach-Object { $_.verdict } } catch { }
    if ($v -ne $ExpectVerdict) { Fail 4 "check-gate expected verdict '$ExpectVerdict', got '$v'" }
}
# Runs an approval verb; returns the parsed JSON object (for --json calls) or $null.
function Approval {
    param($Fx, [string[]]$ApArgs, [int]$ExpectExit)
    # policy.ps1 expects <command> first; inject --work right after it.
    $full = @($ApArgs[0], '--work', $Fx.Work)
    if ($ApArgs.Count -gt 1) { $full += $ApArgs[1..($ApArgs.Count - 1)] }
    $r = Invoke-Tool $script:Policy $full
    if ($r.ExitCode -ne $ExpectExit) { Fail 4 "approval $($ApArgs[0]) expected exit $ExpectExit, got $($r.ExitCode): $([string]$r.Out)$([string]$r.Err)" }
    $o = $null
    try { $o = ([string]$r.Out).Trim() | ConvertFrom-Json } catch { }
    return $o
}
# Escalate a task through the real queue transaction and mark its descriptor (mirrors the
# policy scenario's safe-halt bookkeeping) - the terminal state for a denied publish gate.
function Halt-Escalate {
    param($Fx, [string]$TaskId, [string]$Reason)
    $esc = Invoke-Tool $script:QueueTx @('escalate', '--work', $Fx.Work, '--id', $TaskId, '--reason', $Reason)
    if ($esc.ExitCode -ne 0) { Fail 4 "escalate $TaskId failed: $($esc.Err)" }
    Set-Descriptor $Fx $TaskId 'эскалирована'
}

function Scenario-CiDelayed {
    param($Fx)
    # Like checks, but the required CI SET has TWO checks and the watcher must WAIT through a
    # pending poll before the WHOLE set is green - it never finishes on the first green run.
    $t1 = 'T-101'
    Seed-Task $Fx $t1 'ci-delayed one'
    Set-CiConstraints $Fx @('validate', 'crash-matrix')
    Step-Lease $Fx
    Step-CohortOpen $Fx @($t1)
    Vcs-TaskCommit $Fx $t1 3 'C'
    Lifecycle-Task $Fx $t1
    $integ = Vcs-Integrate $Fx @($t1) $Fx.BatchId
    if (-not $integ.Clean) { Fail 4 'ci-delayed unexpectedly conflicted' }
    Emit-Event $Fx 'integrate' @('--type', 'cohort.join_started', '--batch-id', $Fx.BatchId, '--payload', '{}')
    $sha = 'sha-' + $Fx.BatchId
    # poll 1: crash-matrix still in progress -> wait (do not publish on the first green run)
    Write-CiRuns $Fx @(
        @{ name = 'validate'; head_sha = $sha; status = 'completed'; conclusion = 'success' },
        @{ name = 'crash-matrix'; head_sha = $sha; status = 'in_progress'; conclusion = '' })
    Assert-Gate $Fx $sha 10 10 'wait'
    # poll 2: whole set green -> ready
    Write-CiRuns $Fx @(
        @{ name = 'validate'; head_sha = $sha; status = 'completed'; conclusion = 'success' },
        @{ name = 'crash-matrix'; head_sha = $sha; status = 'completed'; conclusion = 'success' })
    Assert-Gate $Fx $sha 40 0 'ready'
    Vcs-Publish $Fx $Fx.BatchId
    Step-PublishTask $Fx $t1
    Emit-Event $Fx $null @('--type', 'cohort.published', '--batch-id', $Fx.BatchId, '--payload', '{"pushed":false,"ci":"confirmed"}')
    Step-Archive $Fx $t1
    Emit-Event $Fx $null @('--type', 'cohort.closed', '--batch-id', $Fx.BatchId, '--payload', '{"merged":1,"quarantined":0,"escalated":0}')
    return [pscustomobject]@{ Outcome = 'published'; Notes = 'delayed multi-check CI gate waited the whole set, then published' }
}

function Scenario-CiRerun {
    param($Fx)
    # A required check is RED first, then re-run GREEN (higher run_id wins). The gate must bind
    # to the SHA and honour the rerun conclusion, not the first (failed) run.
    $t1 = 'T-101'
    Seed-Task $Fx $t1 'ci-rerun one'
    Set-CiConstraints $Fx @('validate')
    Step-Lease $Fx
    Step-CohortOpen $Fx @($t1)
    Vcs-TaskCommit $Fx $t1 3 'R'
    Lifecycle-Task $Fx $t1
    $integ = Vcs-Integrate $Fx @($t1) $Fx.BatchId
    if (-not $integ.Clean) { Fail 4 'ci-rerun unexpectedly conflicted' }
    Emit-Event $Fx 'integrate' @('--type', 'cohort.join_started', '--batch-id', $Fx.BatchId, '--payload', '{}')
    $sha = 'sha-' + $Fx.BatchId
    # first run failed
    Write-CiRuns $Fx @(@{ name = 'validate'; head_sha = $sha; status = 'completed'; conclusion = 'failure'; run_id = 1 })
    Assert-Gate $Fx $sha 10 9 'failed'
    # rerun green (latest run wins) -> ready
    Write-CiRuns $Fx @(
        @{ name = 'validate'; head_sha = $sha; status = 'completed'; conclusion = 'failure'; run_id = 1 },
        @{ name = 'validate'; head_sha = $sha; status = 'completed'; conclusion = 'success'; run_id = 2 })
    Assert-Gate $Fx $sha 60 0 'ready'
    Vcs-Publish $Fx $Fx.BatchId
    Step-PublishTask $Fx $t1
    Emit-Event $Fx $null @('--type', 'cohort.published', '--batch-id', $Fx.BatchId, '--payload', '{"pushed":false,"ci":"confirmed"}')
    Step-Archive $Fx $t1
    Emit-Event $Fx $null @('--type', 'cohort.closed', '--batch-id', $Fx.BatchId, '--payload', '{"merged":1,"quarantined":0,"escalated":0}')
    return [pscustomobject]@{ Outcome = 'published'; Notes = 'red check re-run to green (latest run wins), then published' }
}

function Scenario-CiOutage {
    param($Fx)
    # CI never reports for the pushed SHA within the deadline (outage). The gate is fail-closed:
    # the batch is ff-merged (publication already happened) but the task is NOT archived - it
    # stays 'опубликована', its recovery artifacts are kept, and the degradation is recorded
    # both as a journal note and as the cohort.published `ci` field.
    $t1 = 'T-101'
    Seed-Task $Fx $t1 'ci-outage one'
    Set-CiConstraints $Fx @('validate', 'crash-matrix')
    Step-Lease $Fx
    Step-CohortOpen $Fx @($t1)
    Vcs-TaskCommit $Fx $t1 3 'O'
    Lifecycle-Task $Fx $t1
    $integ = Vcs-Integrate $Fx @($t1) $Fx.BatchId
    if (-not $integ.Clean) { Fail 4 'ci-outage unexpectedly conflicted' }
    Emit-Event $Fx 'integrate' @('--type', 'cohort.join_started', '--batch-id', $Fx.BatchId, '--payload', '{}')
    $sha = 'sha-' + $Fx.BatchId
    Write-CiRuns $Fx @()   # no runs ever appear
    Assert-Gate $Fx $sha 10 10 'wait'        # within deadline -> keep waiting
    Assert-Gate $Fx $sha 601 9 'timeout'     # past the 600s deadline -> fail-closed
    Vcs-Publish $Fx $Fx.BatchId
    Step-PublishTask $Fx $t1
    # degradation reflected in BOTH the journal and the outbox (ci field), NOT silently.
    Write-Text (Join-Path $Fx.Work 'journal.md') "# journal`n- [$($Fx.BatchId)] CI не подтверждён за дедлайн - задачи не заархивированы (ручная проверка)`n"
    Emit-Event $Fx $null @('--type', 'cohort.published', '--batch-id', $Fx.BatchId, '--payload', '{"pushed":false,"ci":"unconfirmed-degraded"}')
    # deliberately DO NOT archive: the task remains 'опубликована' (not 'выполнена').
    return [pscustomobject]@{ Outcome = 'ci-unconfirmed'; Notes = 'CI outage past deadline: fail-closed, published-but-not-archived, degradation recorded' }
}

function Scenario-Approve {
    param($Fx)
    # A publish that needs human sign-off (policy-bypass category): a one-time approval request
    # is issued, the operator APPROVES, approval-status confirms it fresh, publication proceeds.
    $t1 = 'T-101'
    Seed-Task $Fx $t1 'approve one'
    Step-Lease $Fx
    Step-CohortOpen $Fx @($t1)
    Vcs-TaskCommit $Fx $t1 3 'A'
    Lifecycle-Task $Fx $t1
    $fp = 'fp-' + $t1; $ph = 'ph-1'
    $req = Approval $Fx @('approval-request', '--task', $t1, '--reason', 'policy-bypass', '--fingerprint', $fp, '--policy-hash', $ph, '--deadline-sec', '3600', '--now', '2026-01-01T00:00:00Z', '--json') 0
    if (-not $req -or -not $req.id) { Fail 4 'approve: no approval id issued' }
    $id = [string]$req.id
    # resume idempotency: the same request reuses the same id (no duplicate)
    $req2 = Approval $Fx @('approval-request', '--task', $t1, '--reason', 'policy-bypass', '--fingerprint', $fp, '--policy-hash', $ph, '--now', '2026-01-01T00:01:00Z', '--json') 0
    if ([string]$req2.id -ne $id) { Fail 4 'approve: request not idempotent on resume' }
    Approval $Fx @('approval-approve', '--id', $id, '--by', 'operator', '--now', '2026-01-01T00:10:00Z') 0 | Out-Null
    Approval $Fx @('approval-status', '--id', $id, '--fingerprint', $fp, '--policy-hash', $ph, '--now', '2026-01-01T00:20:00Z', '--json') 0 | Out-Null
    $integ = Vcs-Integrate $Fx @($t1) $Fx.BatchId
    if (-not $integ.Clean) { Fail 4 'approve unexpectedly conflicted' }
    Emit-Event $Fx 'integrate' @('--type', 'cohort.join_started', '--batch-id', $Fx.BatchId, '--payload', '{}')
    Vcs-Publish $Fx $Fx.BatchId
    Step-PublishTask $Fx $t1
    Emit-Event $Fx $null @('--type', 'cohort.published', '--batch-id', $Fx.BatchId, '--payload', '{"pushed":false,"ci":"disabled"}')
    Step-Archive $Fx $t1
    Emit-Event $Fx $null @('--type', 'cohort.closed', '--batch-id', $Fx.BatchId, '--payload', '{"merged":1,"quarantined":0,"escalated":0}')
    return [pscustomobject]@{ Outcome = 'published'; Notes = 'one-time approval granted -> published' }
}

function Scenario-Reject {
    param($Fx)
    # The operator REJECTS the approval: the dependent task is not published; it is escalated
    # (a safe, diagnosable halt), like a policy denial.
    $t1 = 'T-101'
    Seed-Task $Fx $t1 'reject one'
    Step-Lease $Fx
    Step-CohortOpen $Fx @($t1)
    Vcs-TaskCommit $Fx $t1 3 'J'
    Step-Capture $Fx $t1
    Step-ToReview $Fx $t1
    $req = Approval $Fx @('approval-request', '--task', $t1, '--reason', 'policy-bypass', '--fingerprint', 'fp-r', '--policy-hash', 'ph-r', '--deadline-sec', '3600', '--now', '2026-01-01T00:00:00Z', '--json') 0
    $id = [string]$req.id
    Approval $Fx @('approval-reject', '--id', $id, '--by', 'operator', '--now', '2026-01-01T00:05:00Z') 11 | Out-Null
    Approval $Fx @('approval-status', '--id', $id, '--fingerprint', 'fp-r', '--policy-hash', 'ph-r', '--now', '2026-01-01T00:06:00Z', '--json') 11 | Out-Null
    Halt-Escalate $Fx $t1 'approval отклонён оператором'
    Emit-Event $Fx $null @('--type', 'cohort.closed', '--batch-id', $Fx.BatchId, '--payload', '{"merged":0,"quarantined":0,"escalated":1}')
    return [pscustomobject]@{ Outcome = 'escalated'; Notes = 'approval rejected -> task escalated (not published)' }
}

function Scenario-ApprovalTimeout {
    param($Fx)
    # No operator decision arrives by the deadline: fail-closed rejection (never a default
    # approval); the task is escalated, not published.
    $t1 = 'T-101'
    Seed-Task $Fx $t1 'approval-timeout one'
    Step-Lease $Fx
    Step-CohortOpen $Fx @($t1)
    Vcs-TaskCommit $Fx $t1 3 'T'
    Step-Capture $Fx $t1
    Step-ToReview $Fx $t1
    $req = Approval $Fx @('approval-request', '--task', $t1, '--reason', 'human-review', '--fingerprint', 'fp-t', '--policy-hash', 'ph-t', '--deadline-sec', '60', '--now', '2026-01-01T00:00:00Z', '--json') 0
    $id = [string]$req.id
    Approval $Fx @('approval-status', '--id', $id, '--fingerprint', 'fp-t', '--policy-hash', 'ph-t', '--now', '2026-01-01T01:00:00Z', '--json') 11 | Out-Null
    Halt-Escalate $Fx $t1 'approval не получен к дедлайну (fail-closed)'
    Emit-Event $Fx $null @('--type', 'cohort.closed', '--batch-id', $Fx.BatchId, '--payload', '{"merged":0,"quarantined":0,"escalated":1}')
    return [pscustomobject]@{ Outcome = 'escalated'; Notes = 'approval deadline passed with no answer -> fail-closed escalation' }
}

function Scenario-ApprovalStale {
    param($Fx)
    # The operator approved, but the affected code then changed (fingerprint differs): the
    # decision expires (stale) and must NOT be reused - the task is not published.
    $t1 = 'T-101'
    Seed-Task $Fx $t1 'approval-stale one'
    Step-Lease $Fx
    Step-CohortOpen $Fx @($t1)
    Vcs-TaskCommit $Fx $t1 3 'S'
    Step-Capture $Fx $t1
    Step-ToReview $Fx $t1
    $req = Approval $Fx @('approval-request', '--task', $t1, '--reason', 'force-lock', '--fingerprint', 'fp-old', '--policy-hash', 'ph-s', '--deadline-sec', '3600', '--now', '2026-01-01T00:00:00Z', '--json') 0
    $id = [string]$req.id
    Approval $Fx @('approval-approve', '--id', $id, '--by', 'operator', '--now', '2026-01-01T00:10:00Z') 0 | Out-Null
    # code changed after approval -> current fingerprint differs -> stale (fail-closed)
    Approval $Fx @('approval-status', '--id', $id, '--fingerprint', 'fp-new', '--policy-hash', 'ph-s', '--now', '2026-01-01T00:20:00Z', '--json') 11 | Out-Null
    Halt-Escalate $Fx $t1 'approval устарел (код изменился после одобрения)'
    Emit-Event $Fx $null @('--type', 'cohort.closed', '--batch-id', $Fx.BatchId, '--payload', '{"merged":0,"quarantined":0,"escalated":1}')
    return [pscustomobject]@{ Outcome = 'escalated'; Notes = 'approval went stale after a code change -> not reused, escalated' }
}

function Invoke-Scenario {
    param($Fx, [string]$Name)
    switch ($Name) {
        'clean'            { return (Scenario-Clean $Fx) }
        'publish'          { return (Scenario-Publish $Fx) }
        'resume'           { return (Scenario-Resume $Fx) }
        'checks'           { return (Scenario-Checks $Fx) }
        'deps'             { return (Scenario-Deps $Fx) }
        'conflict'         { return (Scenario-Conflict $Fx) }
        'quarantine'       { return (Scenario-Quarantine $Fx) }
        'policy'           { return (Scenario-Policy $Fx) }
        'ci-delayed'       { return (Scenario-CiDelayed $Fx) }
        'ci-rerun'         { return (Scenario-CiRerun $Fx) }
        'ci-outage'        { return (Scenario-CiOutage $Fx) }
        'approve'          { return (Scenario-Approve $Fx) }
        'reject'           { return (Scenario-Reject $Fx) }
        'approval-timeout' { return (Scenario-ApprovalTimeout $Fx) }
        'approval-stale'   { return (Scenario-ApprovalStale $Fx) }
        default            { Fail 2 "unknown scenario '$Name' (valid: $($script:Scenarios -join ', '))" }
    }
}

# ==========================================================================
# Commands.
# ==========================================================================
function Cmd-Scenario {
    $vcs = [string](Opt 'vcs' 'git')
    if ($vcs -ne 'git' -and $vcs -ne 'jj') { Fail 2 "--vcs must be 'git' or 'jj'" }
    $name = [string](Opt 'name' 'clean')
    if ($script:Scenarios -notcontains $name) { Fail 2 "unknown scenario '$name' (valid: $($script:Scenarios -join ', '))" }
    if ($vcs -eq 'git' -and -not (Has-Bin 'git')) { Fail 3 'git is not installed' }
    if ($vcs -eq 'jj' -and -not (Has-Bin 'jj')) { Fail 3 'jj is not installed' }

    $fault = Parse-Fault ([string](Opt 'fault' ''))
    $fx = New-Fixture $vcs ([string](Opt 'path' ''))
    Add-Member -InputObject $fx -NotePropertyName 'Fault' -NotePropertyValue $fault -Force
    Add-Member -InputObject $fx -NotePropertyName 'FaultFired' -NotePropertyValue $false -Force
    $keep = [bool](Opt 'keep' $false)
    try {
        $res = Invoke-Scenario $fx $name
        if ($fault -and -not $fx.FaultFired) { Fail 2 "fault target '$($fault.Target)' was never reached by scenario '$name'" }
        $fp = Get-Fingerprint $fx
        $out = [ordered]@{
            scenario     = $name
            vcs          = $vcs
            outcome      = $res.Outcome
            notes        = $res.Notes
            fault        = if ($fault) { "$($fault.Target):$($fault.Stage)" } else { '' }
            fault_fired  = [bool]$fx.FaultFired
            fingerprint  = $fp.Combined
            tree         = $fp.Tree
            queue        = $fp.Queue
            archive      = $fp.Archive
            outbox       = $fp.Outbox
            fixture      = $fx.Root
        }
        if ([bool](Opt 'json' $false)) { Write-Output ($out | ConvertTo-Json -Depth 6 -Compress) }
        else { Write-Output "scenario=$name vcs=$vcs outcome=$($res.Outcome) fault=$($out.fault) fired=$($out.fault_fired) fingerprint=$($fp.Combined)" }
    } finally {
        if (-not $keep) { Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Cmd-ListScenarios { foreach ($s in $script:Scenarios) { Write-Output $s } }
function Cmd-ListFaults {
    foreach ($k in ($script:FaultTargets.Keys | Sort-Object)) {
        Write-Output ("{0}: {1}" -f $k, ($script:FaultTargets[$k].Stages -join ', '))
    }
}
function Cmd-NewFixture {
    $vcs = [string](Opt 'vcs' 'git')
    if ($vcs -ne 'git' -and $vcs -ne 'jj') { Fail 2 "--vcs must be 'git' or 'jj'" }
    if ($vcs -eq 'git' -and -not (Has-Bin 'git')) { Fail 3 'git is not installed' }
    if ($vcs -eq 'jj' -and -not (Has-Bin 'jj')) { Fail 3 'jj is not installed' }
    $fx = New-Fixture $vcs (Require-Opt 'path')
    Write-Output "fixture=$($fx.Root) repo=$($fx.Repo) work=$($fx.Work) base=$($fx.Base)"
}

# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------
try {
    switch ($Command) {
        'scenario'       { Cmd-Scenario }
        'new-fixture'    { Cmd-NewFixture }
        'list-scenarios' { Cmd-ListScenarios }
        'list-faults'    { Cmd-ListFaults }
        'version'        { Write-Output 'orchestra-harness 1' }
        default {
            Fail 2 "unknown command '$Command'. Valid: scenario, new-fixture, list-scenarios, list-faults, version"
        }
    }
} catch {
    $m = [string]$_.Exception.Message
    if ($m -like 'HRNERR|*') {
        $parts = $m -split '\|', 3
        [Console]::Error.WriteLine("harness: $($parts[2])")
        exit ([int]$parts[1])
    }
    [Console]::Error.WriteLine("harness: $m")
    if ($env:HARNESS_DEBUG) { [Console]::Error.WriteLine($_.ScriptStackTrace) }
    exit 1
}
