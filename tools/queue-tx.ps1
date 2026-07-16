<#
.SYNOPSIS
    Transactional interface for the task queue `.work/Tasks_Queue.md`.

.DESCRIPTION
    Orchestra's task queue is a human-readable Markdown file
    (`.work/Tasks_Queue.md`) read and written by several independent roles
    (queue_builder, code_auditor, enhancement_scout, github_sync, thinker, plus
    planner/processor). Previously every writer performed its own
    read-modify-write with hand-rolled ID allocation and dedup, so two writers
    running at once could lose each other's update, reuse a T-NNN, or corrupt a
    header. This tool is the single transactional interface all Bash-capable
    roles use to mutate the queue: it serializes every mutation behind a lock,
    recomputes IDs/dedup against the current on-disk state under that lock
    (so a duplicate ID or lost append cannot result from normal operation),
    writes crash-safely (temp file + atomic rename), and maintains a monotonic
    generation counter (`.work/queue_state.json`) usable as an optimistic
    compare-and-swap guard.

    It also owns the machine-readable dependency graph. A task declares
    mandatory predecessors with an explicit body field
    `Предпосылки: T-045, T-046` (the `### [T-NNN] ... — статус: ...` header
    format is never touched, so writers/readers that only parse the header stay
    compatible). The tool validates that graph (missing / self-reference /
    cycle / infeasible-because-escalated) and resolves readiness (a task is
    ready to capture only once every predecessor is archived into
    `.work/Tasks_Done.md`), reporting the concrete blocking predecessor.

    See docs/queue_contract.md (§9-§12) for the normative protocol this tool
    implements and that the queue writers are required to use.

.NOTES
    Runs under both PowerShell 7 (pwsh) and Windows PowerShell 5.1. The file is
    stored UTF-8 with BOM so the Cyrillic status literals it must emit/parse
    (не начата / в работе / эскалирована / карантин / попытка / батч / ветка)
    survive 5.1's no-BOM ANSI fallback. The queue and state files are read/
    written as UTF-8 without BOM, matching the `.work/*.md` convention.

    Exit codes:
      0  success
      2  usage / argument error
      3  generation mismatch (caller's --expected-generation is stale)
      4  duplicate (dedup rejected the proposal)
      5  invalid dependency (missing / self-ref / cycle / infeasible)
      6  not ready (from `ready --id`, used as a capture gate)
      7  could not acquire the queue lock (timeout)
      8  illegal status transition
      9  task id not found in the queue

.EXAMPLE
    pwsh -File tools/queue-tx.ps1 allocate-id --work /abs/.work
    pwsh -File tools/queue-tx.ps1 propose --work /abs/.work --title "Fix X" --body-file body.txt --predecessors "T-045"
    pwsh -File tools/queue-tx.ps1 capture --work /abs/.work --id T-045 --batch B-20260101T000000Z
    pwsh -File tools/queue-tx.ps1 ready --work /abs/.work
    pwsh -File tools/queue-tx.ps1 validate-deps --work /abs/.work
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# Argument parsing:  <command> [--key value | --flag] ...
# --------------------------------------------------------------------------
$Command = if ($args.Count -ge 1) { [string]$args[0] } else { '' }
$BoolFlags = @('force', 'json')
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

# Fail throws a coded terminating error instead of calling `exit`, so that any
# `finally { Release-Lock }` still runs before the process leaves. The top-level
# dispatcher decodes the code and exits.
function Fail {
    param([int]$Code, [string]$Message)
    throw ('QTXERR|' + $Code + '|' + $Message)
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
function Format-Id { param([int]$N) return ('T-{0:D3}' -f $N) }

# --------------------------------------------------------------------------
# Paths (resolved once --work is known)
# --------------------------------------------------------------------------
function Resolve-Paths {
    $work = Require-Opt 'work'
    if (-not (Test-Path -LiteralPath $work)) { $null = New-Item -ItemType Directory -Force -Path $work }
    return [pscustomobject]@{
        Work     = $work
        Queue    = Join-Path $work 'Tasks_Queue.md'
        Done     = Join-Path $work 'Tasks_Done.md'
        TasksDir = Join-Path $work 'tasks'
        State    = Join-Path $work 'queue_state.json'
        Lock     = Join-Path $work 'queue-tx.lock'
        Inbox    = Join-Path $work 'queue_inbox'
    }
}

# --------------------------------------------------------------------------
# Crash-safe IO
# --------------------------------------------------------------------------
function Read-TextOrEmpty {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return [System.IO.File]::ReadAllText($Path) }
    return ''
}
function Maybe-Fault {
    param([string]$Stage)
    if ($env:QUEUE_TX_FAULT -and $env:QUEUE_TX_FAULT -eq $Stage) {
        throw "injected fault at stage '$Stage'"
    }
}
function Write-TextAtomic {
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($false)  # no BOM for .work/*.md/.json
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    # Fixed temp name (not PID-suffixed): queue/state writes are serialized by the
    # queue lock and inbox targets are already unique, so a crashed transaction's
    # leftover temp is simply overwritten by the retry instead of accumulating.
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $Content, $enc)
    Maybe-Fault 'before-rename'
    Move-Item -LiteralPath $tmp -Destination $Path -Force
    Maybe-Fault 'after-rename'
}

# --------------------------------------------------------------------------
# Lock: an exclusive lock FILE created with FileMode.CreateNew, which is the
# atomic "create, failing if it already exists" primitive. (PowerShell's
# `New-Item -ItemType Directory` is NOT atomic — it is a check-then-create over
# Directory.CreateDirectory, which is idempotent, so concurrent callers can all
# "succeed" and enter the critical section together. CreateNew fails the losers
# with an IOException, giving true mutual exclusion.) A crashed holder leaves the
# file behind; a lock older than $StaleMs is treated as abandoned and broken.
# --------------------------------------------------------------------------
function Acquire-Lock {
    param([string]$LockPath, [int]$TimeoutMs = 30000, [int]$StaleMs = 60000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ($true) {
        try {
            $fs = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try { $b = [System.Text.Encoding]::ASCII.GetBytes("$PID"); $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
            return
        } catch {
            if (Test-Path -LiteralPath $LockPath) {
                try {
                    $age = ([DateTime]::UtcNow - (Get-Item -LiteralPath $LockPath).CreationTimeUtc).TotalMilliseconds
                    if ($age -gt $StaleMs) { Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue; continue }
                } catch { }
            }
            if ([DateTime]::UtcNow -gt $deadline) { Fail 7 "could not acquire queue lock at $LockPath (held by another writer)" }
            Start-Sleep -Milliseconds 50
        }
    }
}
function Release-Lock {
    param([string]$LockPath)
    Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------------
# Generation counter
# --------------------------------------------------------------------------
function Get-Generation {
    param([string]$StatePath)
    if (-not (Test-Path -LiteralPath $StatePath)) { return 0 }
    try {
        $obj = (Read-TextOrEmpty $StatePath) | ConvertFrom-Json
        if ($obj -and ($obj.PSObject.Properties.Name -contains 'generation')) { return [int]$obj.generation }
    } catch { }
    return 0
}
function Set-Generation {
    param([string]$StatePath, [int]$Value)
    Write-TextAtomic $StatePath (@{ generation = $Value } | ConvertTo-Json -Compress)
}

# --------------------------------------------------------------------------
# Queue model
# --------------------------------------------------------------------------
$HeaderRegex = '^###\s+\[T-0*(\d+)\]\s*(.*?)\s*—\s*статус:\s*(.*?)\s*$'
$PredRegex   = '^(?:Предпосылки|Predecessors)\s*:\s*(.+)$'

function Parse-Task {
    param([string[]]$BlockLines)
    $header = $BlockLines[0]
    $m = [regex]::Match($header, $HeaderRegex)
    $id = -1; $title = ''; $status = ''
    if ($m.Success) {
        $id = [int]$m.Groups[1].Value
        $title = $m.Groups[2].Value
        $status = $m.Groups[3].Value
    }
    $body = @()
    if ($BlockLines.Count -gt 1) { $body = @($BlockLines[1..($BlockLines.Count - 1)]) }
    $preds = New-Object System.Collections.Generic.List[int]
    foreach ($bl in $body) {
        $pm = [regex]::Match($bl, $PredRegex)
        if ($pm.Success) {
            foreach ($t in [regex]::Matches($pm.Groups[1].Value, 'T-0*(\d+)')) {
                [void]$preds.Add([int]$t.Groups[1].Value)
            }
        }
    }
    return [pscustomobject]@{
        Id           = $id
        IdStr        = (Format-Id $id)
        Title        = $title
        Status       = $status
        Header       = $header
        Body         = @($body)
        Predecessors = @($preds.ToArray())
        Malformed    = (-not $m.Success)
    }
}

function Split-Queue {
    param([string]$Text)
    $normalized = ($Text -replace "`r`n", "`n") -replace "`r", "`n"
    $lines = $normalized -split "`n"
    $headerIdx = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^###\s+\[T-0*\d+\]') { [void]$headerIdx.Add($i) }
    }
    if ($headerIdx.Count -eq 0) {
        return [pscustomobject]@{ Preamble = ($normalized.TrimEnd("`n")); Tasks = @() }
    }
    $preamble = ''
    if ($headerIdx[0] -gt 0) { $preamble = (@($lines[0..($headerIdx[0] - 1)]) -join "`n").TrimEnd("`n") }
    $tasks = New-Object System.Collections.ArrayList
    for ($h = 0; $h -lt $headerIdx.Count; $h++) {
        $start = $headerIdx[$h]
        $end = if ($h -lt $headerIdx.Count - 1) { $headerIdx[$h + 1] - 1 } else { $lines.Count - 1 }
        $blockLines = @($lines[$start..$end])
        while ($blockLines.Count -gt 1 -and [string]::IsNullOrWhiteSpace($blockLines[$blockLines.Count - 1])) {
            $blockLines = @($blockLines[0..($blockLines.Count - 2)])
        }
        [void]$tasks.Add((Parse-Task $blockLines))
    }
    return [pscustomobject]@{ Preamble = $preamble; Tasks = @($tasks.ToArray()) }
}

function Build-QueueText {
    param([string]$Preamble, $Tasks)
    $segments = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Preamble)) { [void]$segments.Add($Preamble.TrimEnd("`n")) }
    foreach ($t in $Tasks) {
        $block = $t.Header
        if ($t.Body.Count -gt 0) { $block += "`n" + (@($t.Body) -join "`n") }
        [void]$segments.Add($block.TrimEnd("`n"))
    }
    if ($segments.Count -eq 0) { return "# Очередь задач`n" }
    return (($segments -join "`n`n").TrimEnd("`n")) + "`n"
}

function Set-TaskStatus {
    param($Task, [string]$NewStatus)
    $Task.Status = $NewStatus
    $Task.Header = "### [$($Task.IdStr)] $($Task.Title) — статус: $NewStatus"
}

function Read-QueueState {
    param($Paths)
    $q = Split-Queue (Read-TextOrEmpty $Paths.Queue)
    $pre = $q.Preamble
    if ([string]::IsNullOrWhiteSpace($pre)) { $pre = '# Очередь задач' }
    return [pscustomobject]@{ Preamble = $pre; Tasks = @($q.Tasks) }
}
function Commit-QueueState {
    param($Paths, $State, [int]$GenDelta = 1)
    Write-TextAtomic $Paths.Queue (Build-QueueText $State.Preamble $State.Tasks)
    $g = (Get-Generation $Paths.State) + $GenDelta
    Set-Generation $Paths.State $g
    return $g
}

# --------------------------------------------------------------------------
# ID / dedup helpers
# --------------------------------------------------------------------------
function Get-IdsFromText {
    param([string]$Text)
    $ids = New-Object System.Collections.Generic.HashSet[int]
    foreach ($m in [regex]::Matches($Text, 'T-0*(\d+)')) { [void]$ids.Add([int]$m.Groups[1].Value) }
    return ,$ids
}
function Get-ArchiveHeaderIds {
    param([string]$Text)
    $ids = New-Object System.Collections.Generic.HashSet[int]
    foreach ($line in ($Text -split "`r?`n")) {
        $m = [regex]::Match($line, '^\s*###\s*\[\s*T-0*(\d+)\s*\]')
        if ($m.Success) { [void]$ids.Add([int]$m.Groups[1].Value) }
    }
    return ,$ids
}
function Get-ActiveIds {
    param([string]$TasksDir)
    $ids = New-Object System.Collections.Generic.HashSet[int]
    if (Test-Path -LiteralPath $TasksDir) {
        foreach ($d in Get-ChildItem -LiteralPath $TasksDir -Directory -ErrorAction SilentlyContinue) {
            $m = [regex]::Match($d.Name, '^T-0*(\d+)$')
            if ($m.Success) { [void]$ids.Add([int]$m.Groups[1].Value) }
        }
    }
    return ,$ids
}
function Get-MaxKnownId {
    param($Paths, $QueueTasks)
    $max = 0
    foreach ($t in $QueueTasks) { if ($t.Id -gt $max) { $max = $t.Id } }
    foreach ($id in (Get-IdsFromText (Read-TextOrEmpty $Paths.Done))) { if ($id -gt $max) { $max = $id } }
    if (Test-Path -LiteralPath $Paths.TasksDir) {
        foreach ($d in Get-ChildItem -LiteralPath $Paths.TasksDir -Directory -ErrorAction SilentlyContinue) {
            $tf = Join-Path $d.FullName 'task.md'
            foreach ($id in (Get-IdsFromText (Read-TextOrEmpty $tf))) { if ($id -gt $max) { $max = $id } }
            $mm = [regex]::Match($d.Name, '^T-0*(\d+)$')
            if ($mm.Success -and [int]$mm.Groups[1].Value -gt $max) { $max = [int]$mm.Groups[1].Value }
        }
    }
    return $max
}
function Normalize-Title {
    param([string]$Title)
    return ([regex]::Replace($Title.Trim(), '\s+', ' ')).ToLowerInvariant()
}
function Get-KnownTitles {
    param($Paths, $QueueTasks)
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($t in $QueueTasks) { [void]$set.Add((Normalize-Title $t.Title)) }
    $doneText = Read-TextOrEmpty $Paths.Done
    foreach ($m in [regex]::Matches($doneText, '(?m)###\s+\[T-0*\d+\]\s*(.*?)\s*—\s*статус:')) {
        [void]$set.Add((Normalize-Title $m.Groups[1].Value))
    }
    foreach ($m in [regex]::Matches($doneText, '(?m)^Исходная задача:\s*\[T-0*\d+\]\s*(.+)$')) {
        [void]$set.Add((Normalize-Title $m.Groups[1].Value))
    }
    if (Test-Path -LiteralPath $Paths.TasksDir) {
        foreach ($d in Get-ChildItem -LiteralPath $Paths.TasksDir -Directory -ErrorAction SilentlyContinue) {
            $tf = Read-TextOrEmpty (Join-Path $d.FullName 'task.md')
            foreach ($m in [regex]::Matches($tf, '(?m)^Исходная задача:\s*\[T-0*\d+\]\s*(.+)$')) {
                [void]$set.Add((Normalize-Title $m.Groups[1].Value))
            }
        }
    }
    return ,$set
}

# --------------------------------------------------------------------------
# Status classification
# --------------------------------------------------------------------------
function Is-NotStarted { param([string]$Status) return (Get-BaseWord $Status) -eq 'не начата' }
function Is-Escalated  { param([string]$Status) return (Get-BaseWord $Status) -eq 'эскалирована' }
function Is-Captured   { param([string]$Status) return (Get-BaseWord $Status) -eq 'в работе' }
function Get-Attempt {
    param([string]$Status)
    $m = [regex]::Match($Status, 'попытка=(\d+)')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return 1
}
function Get-BaseWord {
    param([string]$Status)
    $parts = $Status -split ' · ', 2
    return $parts[0].Trim()
}

# --------------------------------------------------------------------------
# Dependency graph: cycle detection (top-level recursive DFS, script scope)
# --------------------------------------------------------------------------
$script:CycleAdj = $null
$script:CycleColor = $null
$script:CyclePath = $null
$script:CycleResult = $null

function Visit-CycleNode {
    param([int]$Node)
    $script:CycleColor[$Node] = 1  # gray
    [void]$script:CyclePath.Add($Node)
    foreach ($nb in $script:CycleAdj[$Node]) {
        if (-not $script:CycleColor.ContainsKey($nb)) { continue }
        if ($script:CycleColor[$nb] -eq 1) {
            $idx = $script:CyclePath.IndexOf($nb)
            $script:CycleResult = @($script:CyclePath[$idx..($script:CyclePath.Count - 1)])
            return $true
        } elseif ($script:CycleColor[$nb] -eq 0) {
            $sub = Visit-CycleNode -Node $nb
            if ($sub) { return $true }
        }
    }
    $script:CycleColor[$Node] = 2  # black
    [void]$script:CyclePath.RemoveAt($script:CyclePath.Count - 1)
    return $false
}
function Find-Cycle {
    param([hashtable]$Adj)
    $script:CycleAdj = $Adj
    $script:CycleColor = @{}
    foreach ($n in $Adj.Keys) { $script:CycleColor[$n] = 0 }
    $script:CycleResult = $null
    foreach ($n in @($Adj.Keys)) {
        if ($script:CycleColor[$n] -eq 0) {
            $script:CyclePath = New-Object System.Collections.Generic.List[int]
            $hit = Visit-CycleNode -Node $n
            if ($hit) { return @($script:CycleResult) }
        }
    }
    return $null
}

function Get-DoneIds { param($Paths) return ,(Get-ArchiveHeaderIds (Read-TextOrEmpty $Paths.Done)) }

function Validate-Graph {
    param($Paths, $QueueTasks)
    $findings = New-Object System.Collections.Generic.List[string]
    $queueIds = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($t in $QueueTasks) { [void]$queueIds.Add($t.Id) }
    $doneIds = Get-DoneIds $Paths
    $activeIds = Get-ActiveIds $Paths.TasksDir
    $escalated = @{}
    foreach ($t in $QueueTasks) { if (Is-Escalated $t.Status) { $escalated[$t.Id] = $true } }

    $adj = @{}
    foreach ($t in $QueueTasks) { $adj[$t.Id] = New-Object System.Collections.Generic.List[int] }

    foreach ($t in $QueueTasks) {
        foreach ($p in $t.Predecessors) {
            if ($p -eq $t.Id) { [void]$findings.Add("$($t.IdStr): self-reference in predecessors"); continue }
            $known = $queueIds.Contains($p) -or $doneIds.Contains($p) -or $activeIds.Contains($p)
            if (-not $known) { [void]$findings.Add("$($t.IdStr): missing predecessor $(Format-Id $p) (not in queue, archive, or active)"); continue }
            if ($escalated.ContainsKey($p)) { [void]$findings.Add("$($t.IdStr): infeasible predecessor $(Format-Id $p) (escalated, will never complete)") }
            if ($queueIds.Contains($p)) { [void]$adj[$t.Id].Add($p) }
        }
    }
    $cycle = Find-Cycle $adj
    if ($cycle) {
        $names = ($cycle | ForEach-Object { Format-Id $_ }) -join ' -> '
        [void]$findings.Add("cycle in dependency graph: $names")
    }
    return @($findings.ToArray())
}

function Resolve-Readiness {
    param($Paths, $QueueTasks)
    $doneIds = Get-DoneIds $Paths
    $activeIds = Get-ActiveIds $Paths.TasksDir
    $byId = @{}
    foreach ($t in $QueueTasks) { $byId[$t.Id] = $t }
    $result = New-Object System.Collections.ArrayList
    foreach ($t in $QueueTasks) {
        if (-not (Is-NotStarted $t.Status)) { continue }
        $reasons = New-Object System.Collections.Generic.List[string]
        foreach ($p in $t.Predecessors) {
            if ($p -eq $t.Id) { [void]$reasons.Add("self-reference $(Format-Id $p)"); continue }
            if ($doneIds.Contains($p)) { continue }
            if ($byId.ContainsKey($p)) {
                if (Is-Escalated $byId[$p].Status) { [void]$reasons.Add("blocked: predecessor $(Format-Id $p) escalated") }
                else { [void]$reasons.Add("waiting on $(Format-Id $p)") }
            } elseif ($activeIds.Contains($p)) {
                [void]$reasons.Add("waiting on $(Format-Id $p) (in flight)")
            } else {
                [void]$reasons.Add("missing predecessor $(Format-Id $p)")
            }
        }
        [void]$result.Add([pscustomobject]@{ Task = $t; Ready = ($reasons.Count -eq 0); Reasons = @($reasons.ToArray()) })
    }
    return @($result.ToArray())
}

# --------------------------------------------------------------------------
# Proposal core (shared by propose + inbox-drain)
# --------------------------------------------------------------------------
function New-TaskBlock {
    param([int]$Id, [string]$Title, [string]$Body, [int[]]$Predecessors)
    $bodyLines = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrEmpty($Body)) {
        foreach ($bl in (($Body -replace "`r`n", "`n") -split "`n")) { [void]$bodyLines.Add($bl) }
    }
    if ($Predecessors -and $Predecessors.Count -gt 0) {
        while ($bodyLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($bodyLines[$bodyLines.Count - 1])) {
            $bodyLines.RemoveAt($bodyLines.Count - 1)
        }
        $predStr = ($Predecessors | ForEach-Object { Format-Id $_ }) -join ', '
        [void]$bodyLines.Add("Предпосылки: $predStr")
    }
    return (Parse-Task (@("### [$(Format-Id $Id)] $Title — статус: не начата") + @($bodyLines.ToArray())))
}

# Mutates $State.Tasks in place (adds one task). Throws typed errors:
#   'DUP:<title>' -> duplicate ; 'DEP:<detail>' -> invalid dependency.
function Add-Proposal {
    param(
        $Paths, $State, [string]$Title, [string]$Body, [int[]]$Predecessors,
        [int]$ExplicitId, [bool]$Force, [System.Collections.Generic.HashSet[string]]$KnownTitles, [ref]$MaxIdRef
    )
    $normTitle = Normalize-Title $Title
    if (-not $Force -and $KnownTitles.Contains($normTitle)) { throw "DUP:$Title" }

    if ($ExplicitId -gt 0) {
        foreach ($t in $State.Tasks) { if ($t.Id -eq $ExplicitId) { throw "DEP:explicit id $(Format-Id $ExplicitId) already in queue" } }
        $id = $ExplicitId
    } else {
        $MaxIdRef.Value = $MaxIdRef.Value + 1
        $id = $MaxIdRef.Value
    }

    $queueIds = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($t in $State.Tasks) { [void]$queueIds.Add($t.Id) }
    $doneIds = Get-DoneIds $Paths
    $activeIds = Get-ActiveIds $Paths.TasksDir
    foreach ($p in $Predecessors) {
        if ($p -eq $id) { throw "DEP:self-reference $(Format-Id $p)" }
        $known = $queueIds.Contains($p) -or $doneIds.Contains($p) -or $activeIds.Contains($p)
        if (-not $known) { throw "DEP:missing predecessor $(Format-Id $p)" }
        $predTask = $State.Tasks | Where-Object { $_.Id -eq $p } | Select-Object -First 1
        if ($predTask -and (Is-Escalated $predTask.Status)) { throw "DEP:infeasible predecessor $(Format-Id $p) (escalated)" }
    }

    $newTask = New-TaskBlock -Id $id -Title $Title -Body $Body -Predecessors $Predecessors
    $State.Tasks = @($State.Tasks) + @($newTask)

    $cycleFindings = Validate-Graph $Paths $State.Tasks | Where-Object { $_ -like 'cycle*' }
    if ($cycleFindings) { throw "DEP:$($cycleFindings[0])" }

    [void]$KnownTitles.Add($normTitle)
    return $newTask
}

# --------------------------------------------------------------------------
# Argument extraction for body/predecessors/id
# --------------------------------------------------------------------------
function Get-BodyArg {
    if ($opts.ContainsKey('body-file')) {
        $bf = [string]$opts['body-file']
        if (-not (Test-Path -LiteralPath $bf)) { Fail 2 "--body-file not found: $bf" }
        return [System.IO.File]::ReadAllText($bf)
    }
    return [string](Opt 'body' '')
}
function Get-PredecessorsArg {
    $raw = [string](Opt 'predecessors' '')
    $ids = New-Object System.Collections.Generic.List[int]
    if ($raw) { foreach ($m in [regex]::Matches($raw, 'T-0*(\d+)')) { [void]$ids.Add([int]$m.Groups[1].Value) } }
    return @($ids.ToArray())
}
function Parse-IdArg {
    $raw = Require-Opt 'id'
    $m = [regex]::Match($raw, 'T-0*(\d+)')
    if (-not $m.Success) { Fail 2 "invalid --id: $raw" }
    return [int]$m.Groups[1].Value
}
function Get-TaskOrFail {
    param($State, [int]$Id)
    $t = $State.Tasks | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $t) { Fail 9 "task $(Format-Id $Id) not found in queue" }
    return $t
}

# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------
function Cmd-AllocateId {
    $paths = Resolve-Paths
    $q = Split-Queue (Read-TextOrEmpty $paths.Queue)
    Write-Output (Format-Id ((Get-MaxKnownId $paths $q.Tasks) + 1))
}

function Cmd-Generation {
    $paths = Resolve-Paths
    Write-Output (Get-Generation $paths.State)
}

function Cmd-BumpGeneration {
    $paths = Resolve-Paths
    Acquire-Lock $paths.Lock
    try {
        $g = (Get-Generation $paths.State) + 1
        Set-Generation $paths.State $g
        Write-Output "generation=$g"
    } finally { Release-Lock $paths.Lock }
}

function Cmd-Propose {
    $paths = Resolve-Paths
    $title = Require-Opt 'title'
    $body = Get-BodyArg
    $preds = Get-PredecessorsArg
    $explicitId = 0
    if ($opts.ContainsKey('id')) { $m = [regex]::Match([string]$opts['id'], 'T-0*(\d+)'); if ($m.Success) { $explicitId = [int]$m.Groups[1].Value } }
    $force = [bool](Opt 'force' $false)

    Acquire-Lock $paths.Lock
    try {
        if ($opts.ContainsKey('expected-generation')) {
            $exp = [int]$opts['expected-generation']
            $cur = Get-Generation $paths.State
            if ($exp -ne $cur) { Fail 3 "generation mismatch: expected $exp, current $cur (queue changed since you read it; re-read and retry)" }
        }
        $state = Read-QueueState $paths
        $known = Get-KnownTitles $paths $state.Tasks
        $maxId = [ref](Get-MaxKnownId $paths $state.Tasks)
        try {
            $newTask = Add-Proposal $paths $state $title $body $preds $explicitId $force $known $maxId
        } catch {
            $msg = [string]$_.Exception.Message
            if ($msg -like 'DUP:*') { Fail 4 "duplicate: a task titled '$($msg.Substring(4))' already exists (queue/archive/active)" }
            if ($msg -like 'DEP:*') { Fail 5 "invalid dependency: $($msg.Substring(4))" }
            throw
        }
        $g = Commit-QueueState $paths $state
        Write-Output "id=$($newTask.IdStr) generation=$g"
    } finally { Release-Lock $paths.Lock }
}

function Cmd-Capture {
    $paths = Resolve-Paths
    $id = Parse-IdArg
    $batch = Require-Opt 'batch'
    $worktree = [string](Opt 'worktree' ".work/worktrees/$(Format-Id $id)")
    $branch = [string](Opt 'branch' "task/$(Format-Id $id)")
    Acquire-Lock $paths.Lock
    try {
        $state = Read-QueueState $paths
        $t = Get-TaskOrFail $state $id
        if (Is-Captured $t.Status) { Write-Output "already-captured $($t.IdStr)"; return }
        if (-not (Is-NotStarted $t.Status)) { Fail 8 "cannot capture $($t.IdStr): status is '$($t.Status)'" }
        $attempt = [regex]::Match($t.Status, '· попытка=(\d+)')
        $new = "в работе · батч=$batch · worktree=$worktree · ветка=$branch"
        if ($attempt.Success) { $new += " · попытка=$($attempt.Groups[1].Value)" }
        Set-TaskStatus $t $new
        $g = Commit-QueueState $paths $state
        Write-Output "captured $($t.IdStr) generation=$g"
    } finally { Release-Lock $paths.Lock }
}

function Cmd-Return {
    $paths = Resolve-Paths
    $id = Parse-IdArg
    $reason = Require-Opt 'reason'
    $maxAttempts = [int](Opt 'max-attempts' 3)
    Acquire-Lock $paths.Lock
    try {
        $state = Read-QueueState $paths
        $t = Get-TaskOrFail $state $id
        if (Is-Escalated $t.Status) { Write-Output "already-escalated $($t.IdStr)"; return }  # idempotent
        $n = Get-Attempt $t.Status
        if ($n -lt $maxAttempts) {
            Set-TaskStatus $t "не начата · попытка=$($n + 1) · карантин=$reason"
            $g = Commit-QueueState $paths $state
            Write-Output "requeued $($t.IdStr) попытка=$($n + 1) generation=$g"
        } else {
            Set-TaskStatus $t "эскалирована · причина=карантин повторился $n раз: $reason"
            $g = Commit-QueueState $paths $state
            Write-Output "escalated $($t.IdStr) (attempts exhausted) generation=$g"
        }
    } finally { Release-Lock $paths.Lock }
}

function Cmd-Escalate {
    $paths = Resolve-Paths
    $id = Parse-IdArg
    $reason = Require-Opt 'reason'
    Acquire-Lock $paths.Lock
    try {
        $state = Read-QueueState $paths
        $t = Get-TaskOrFail $state $id
        Set-TaskStatus $t "эскалирована · причина=$reason"
        $g = Commit-QueueState $paths $state
        Write-Output "escalated $($t.IdStr) generation=$g"
    } finally { Release-Lock $paths.Lock }
}

function Cmd-Archive {
    $paths = Resolve-Paths
    $id = Parse-IdArg
    Acquire-Lock $paths.Lock
    try {
        $state = Read-QueueState $paths
        $t = $state.Tasks | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if (-not $t) { Write-Output "not-present $(Format-Id $id)"; return }  # idempotent
        $state.Tasks = @($state.Tasks | Where-Object { $_.Id -ne $id })
        $g = Commit-QueueState $paths $state
        Write-Output "archived $(Format-Id $id) generation=$g"
    } finally { Release-Lock $paths.Lock }
}

function Cmd-ValidateDeps {
    $paths = Resolve-Paths
    $q = Split-Queue (Read-TextOrEmpty $paths.Queue)
    $findings = @(Validate-Graph $paths $q.Tasks)
    if ($findings.Count -eq 0) { Write-Output 'OK - dependency graph valid'; return }
    foreach ($f in $findings) { Write-Output $f }
    exit 5
}

function Cmd-Ready {
    $paths = Resolve-Paths
    $q = Split-Queue (Read-TextOrEmpty $paths.Queue)
    $res = @(Resolve-Readiness $paths $q.Tasks)
    if ($opts.ContainsKey('id')) {
        $id = Parse-IdArg
        $one = $res | Where-Object { $_.Task.Id -eq $id } | Select-Object -First 1
        if (-not $one) { Fail 9 "task $(Format-Id $id) is not a 'не начата' queue task" }
        if ($one.Ready) { Write-Output "ready $($one.Task.IdStr)"; return }
        Write-Output "not-ready $($one.Task.IdStr): $(@($one.Reasons) -join '; ')"
        exit 6
    }
    $readyIds = @($res | Where-Object { $_.Ready } | ForEach-Object { $_.Task.IdStr })
    if ($readyIds.Count -gt 0) { Write-Output ("ready: " + ($readyIds -join ' ')) } else { Write-Output 'ready: (none)' }
    foreach ($r in ($res | Where-Object { -not $_.Ready })) {
        Write-Output "not-ready: $($r.Task.IdStr) - $(@($r.Reasons) -join '; ')"
    }
}

function Cmd-InboxAdd {
    $paths = Resolve-Paths
    $title = Require-Opt 'title'
    $body = Get-BodyArg
    $preds = Get-PredecessorsArg
    if (-not (Test-Path -LiteralPath $paths.Inbox)) { $null = New-Item -ItemType Directory -Force -Path $paths.Inbox }
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $name = "$stamp-$PID-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
    $record = @{
        title        = $title
        predecessors = @($preds | ForEach-Object { Format-Id $_ })
        body         = $body
        created      = ([DateTime]::UtcNow.ToString('o'))
    }
    Write-TextAtomic (Join-Path $paths.Inbox $name) ($record | ConvertTo-Json -Depth 5)
    Write-Output "inbox=$name"
}

function Cmd-InboxDrain {
    $paths = Resolve-Paths
    if (-not (Test-Path -LiteralPath $paths.Inbox)) { Write-Output 'inbox empty'; return }
    $entries = @(Get-ChildItem -LiteralPath $paths.Inbox -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($entries.Count -eq 0) { Write-Output 'inbox empty'; return }

    $hadRejected = $false
    Acquire-Lock $paths.Lock
    try {
        $state = Read-QueueState $paths
        $known = Get-KnownTitles $paths $state.Tasks
        $maxId = [ref](Get-MaxKnownId $paths $state.Tasks)
        $added = New-Object System.Collections.Generic.List[string]
        $skipped = New-Object System.Collections.Generic.List[string]
        $rejected = New-Object System.Collections.Generic.List[string]
        $consume = New-Object System.Collections.Generic.List[string]
        foreach ($e in $entries) {
            try { $rec = (Read-TextOrEmpty $e.FullName) | ConvertFrom-Json }
            catch { [void]$rejected.Add("$($e.Name): unreadable json"); continue }
            $recPreds = @()
            if (($rec.PSObject.Properties.Name -contains 'predecessors') -and $rec.predecessors) {
                $recPreds = @($rec.predecessors | ForEach-Object { [int]([regex]::Match([string]$_, '\d+').Value) })
            }
            $recBody = ''
            if ($rec.PSObject.Properties.Name -contains 'body') { $recBody = [string]$rec.body }
            try {
                $nt = Add-Proposal $paths $state ([string]$rec.title) $recBody $recPreds 0 $false $known $maxId
                [void]$added.Add($nt.IdStr); [void]$consume.Add($e.FullName)
            } catch {
                $msg = [string]$_.Exception.Message
                if ($msg -like 'DUP:*') { [void]$skipped.Add("$($e.Name): duplicate"); [void]$consume.Add($e.FullName) }
                elseif ($msg -like 'DEP:*') { [void]$rejected.Add("$($e.Name): $($msg.Substring(4))") }
                else { [void]$rejected.Add("$($e.Name): $msg") }
            }
        }
        if ($added.Count -gt 0) { [void](Commit-QueueState $paths $state $added.Count) }
        foreach ($f in $consume) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        Write-Output ("added: " + (@($added.ToArray()) -join ' '))
        if ($skipped.Count -gt 0) { Write-Output ("skipped-dup: " + (@($skipped.ToArray()) -join '; ')) }
        if ($rejected.Count -gt 0) { $hadRejected = $true; foreach ($r in $rejected) { Write-Output "rejected: $r" } }
    } finally { Release-Lock $paths.Lock }
    if ($hadRejected) { exit 5 }
}

# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------
try {
    switch ($Command) {
        'allocate-id'     { Cmd-AllocateId }
        'propose'         { Cmd-Propose }
        'capture'         { Cmd-Capture }
        'return'          { Cmd-Return }
        'escalate'        { Cmd-Escalate }
        'archive'         { Cmd-Archive }
        'validate-deps'   { Cmd-ValidateDeps }
        'ready'           { Cmd-Ready }
        'generation'      { Cmd-Generation }
        'bump-generation' { Cmd-BumpGeneration }
        'inbox-add'       { Cmd-InboxAdd }
        'inbox-drain'     { Cmd-InboxDrain }
        default {
            Fail 2 "unknown command '$Command'. Valid: allocate-id, propose, capture, return, escalate, archive, validate-deps, ready, generation, bump-generation, inbox-add, inbox-drain"
        }
    }
} catch {
    $m = [string]$_.Exception.Message
    if ($m -like 'QTXERR|*') {
        $parts = $m -split '\|', 3
        [Console]::Error.WriteLine("queue-tx: $($parts[2])")
        exit ([int]$parts[1])
    }
    [Console]::Error.WriteLine("queue-tx: $m")
    if ($env:QUEUE_TX_DEBUG) { [Console]::Error.WriteLine($_.ScriptStackTrace) }
    exit 1
}
