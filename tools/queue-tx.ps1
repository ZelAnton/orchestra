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
    cycle / infeasible-because-escalated / current-depends-on-next_major) and
    resolves readiness (a task is ready to capture only once every predecessor
    is archived into `.work/Tasks_Done.md`), reporting the concrete blocking
    predecessor.

    A task may also declare a DELIVERY LANE with the body field
    `Delivery target: current | next_major` (docs/queue_contract.md §11.1). A
    missing field, or any value but an explicit `next_major`, is the
    backward-compatible `current` lane. `next_major` (intentional breaking work)
    is visible/deduplicated/refined but parked out of the ordinary execution
    capacity: `ready` (the default current-lane view planner captures from) never
    lists it, `ready --next-major` shows the parked backlog separately, and a
    current-lane task may not declare a next_major-lane predecessor
    (validate-deps / propose reject that edge).

    The same unified backlog also carries a SEPARATE proposal lane: raw ideas as
    `### [P-NNN] ... — kind: proposal — status: <proposed|converted|rejected|
    duplicate|needs_human|deferred>` records. Proposals are NEVER executable —
    they form their own P-NNN id sequence, are excluded from candidate/readiness/
    validate/T-dedup, can never be a predecessor, and are only ever turned into
    tasks by the `proposal_curator` role (`classify-proposal`). The core T-task
    machine round-trips them verbatim so their original text (provenance) is never
    altered by an unrelated task mutation. See docs/queue_contract.md §20.

    See docs/queue_contract.md (§9-§12, §20) for the normative protocol this tool
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
      5  invalid dependency, or inbox processing / I/O error
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
    pwsh -File tools/queue-tx.ps1 propose --work /abs/.work --kind proposal --title "Idea Y" --body-file idea.txt --source user
    pwsh -File tools/queue-tx.ps1 list-proposals --work /abs/.work --status proposed
    pwsh -File tools/queue-tx.ps1 classify-proposal --work /abs/.work --id P-001 --outcome converted --tasks "T-201,T-202"
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared infrastructure primitives (arg-parse, Fail/Opt/Require-Opt + catch dispatcher,
# crash-safe Read-TextOrEmpty/Write-TextAtomic, Maybe-Fault, Acquire-Lock/Release-Lock;
# T-240). Dot-sourced like tools/policy-schema.ps1. Fail throws a coded terminating error
# instead of calling `exit`, so any `finally { Release-Lock }` still runs before the process
# leaves; the top-level dispatcher (Resolve-CatchExit) decodes the code and exits.
. (Join-Path $PSScriptRoot 'common.ps1')
$script:ErrPrefix = 'QTXERR'          # coded-error tag decoded by the catch dispatcher
$script:FaultEnv  = 'QUEUE_TX_FAULT'  # crash-injection hook read by Maybe-Fault
$script:LockName  = 'queue'           # label in the Acquire-Lock failure message

# --------------------------------------------------------------------------
# Argument parsing:  <command> [--key value | --flag] ...
# --------------------------------------------------------------------------
$parsed = Parse-CliArgs $args -BoolFlags @('force', 'json', 'next-major')
$Command = $parsed.Command
$opts = $parsed.Opts

function Format-Id { param([int]$N) return ('T-{0:D3}' -f $N) }
function Format-PId { param([int]$N) return ('P-{0:D3}' -f $N) }

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
        Rejected = Join-Path (Join-Path $work 'queue_inbox') 'rejected'
    }
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
# Delivery lane body field (docs/queue_contract.md §11.1). Only an explicit `next_major` (any
# case) parks a task; a missing field or any other value is the backward-compatible `current`.
$DeliveryRegex = '^Delivery target\s*:\s*(.+)$'

# Proposal-lane records (kind: proposal, id P-NNN) live in the SAME unified backlog
# file but form a separate lane: they are NEVER executable tasks. Their header carries
# the explicit `kind: proposal` marker (so no reader can mistake a proposal for a task
# by position) and an English `status:` label drawn from the closed set below. The `[P-`
# id prefix and the distinct `kind: proposal — status:` shape keep proposals structurally
# invisible to every T-task operation (readiness, validate-deps, capture, T-dedup, id
# allocation) while `Split-Queue`/`Build-QueueText` round-trip them verbatim so their
# original text (provenance) survives any unrelated T-task mutation. See
# docs/queue_contract.md §20.
$ProposalHeaderRegex = '^###\s+\[P-0*(\d+)\]\s*(.*?)\s*—\s*kind:\s*proposal\s*—\s*status:\s*(.*?)\s*$'
$AnyHeaderRegex      = '^###\s+\[[TP]-0*\d+\]'
$ProposalStatuses    = @('proposed', 'converted', 'rejected', 'duplicate', 'needs_human', 'deferred')
$ProposalOutcomes    = @('converted', 'rejected', 'duplicate', 'needs_human', 'deferred')

# The delivery lane declared by a body's `Delivery target:` line (docs/queue_contract.md §11.1).
# First matching line wins; only an explicit `next_major` parks the task, everything else
# (missing field, `current`, or any other value) is the backward-compatible `current` lane.
function Get-DeliveryTarget {
    param([string[]]$Lines)
    foreach ($bl in $Lines) {
        $dm = [regex]::Match($bl, $DeliveryRegex)
        if ($dm.Success) {
            if ($dm.Groups[1].Value.Trim().ToLowerInvariant() -eq 'next_major') { return 'next_major' }
            return 'current'
        }
    }
    return 'current'
}

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
        Kind           = 'task'
        Id             = $id
        IdStr          = (Format-Id $id)
        Title          = $title
        Status         = $status
        Header         = $header
        Body           = @($body)
        Predecessors   = @($preds.ToArray())
        DeliveryTarget = (Get-DeliveryTarget $body)
        Malformed      = (-not $m.Success)
    }
}

function Parse-Proposal {
    param([string[]]$BlockLines)
    $header = $BlockLines[0]
    $m = [regex]::Match($header, $ProposalHeaderRegex)
    $id = -1; $title = ''; $status = ''
    if ($m.Success) {
        $id = [int]$m.Groups[1].Value
        $title = $m.Groups[2].Value
        $status = $m.Groups[3].Value
    }
    $body = @()
    if ($BlockLines.Count -gt 1) { $body = @($BlockLines[1..($BlockLines.Count - 1)]) }
    return [pscustomobject]@{
        Kind      = 'proposal'
        Id        = $id
        IdStr     = (Format-PId $id)
        Title     = $title
        Status    = $status
        Header    = $header
        Body      = @($body)
        Malformed = (-not $m.Success)
    }
}

# Dispatches a header block to the task or proposal parser by its id prefix, so a
# unified backlog can carry both lanes and each record knows its own Kind.
function Parse-Record {
    param([string[]]$BlockLines)
    if ($BlockLines[0] -match '^###\s+\[P-0*\d+\]') { return (Parse-Proposal $BlockLines) }
    return (Parse-Task $BlockLines)
}

function Split-Queue {
    param([string]$Text)
    $normalized = ($Text -replace "`r`n", "`n") -replace "`r", "`n"
    $lines = $normalized -split "`n"
    $headerIdx = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $AnyHeaderRegex) { [void]$headerIdx.Add($i) }
    }
    if ($headerIdx.Count -eq 0) {
        return [pscustomobject]@{ Preamble = ($normalized.TrimEnd("`n")); Records = @(); Tasks = @(); Proposals = @() }
    }
    $preamble = ''
    if ($headerIdx[0] -gt 0) { $preamble = (@($lines[0..($headerIdx[0] - 1)]) -join "`n").TrimEnd("`n") }
    $records = New-Object System.Collections.ArrayList
    for ($h = 0; $h -lt $headerIdx.Count; $h++) {
        $start = $headerIdx[$h]
        $end = if ($h -lt $headerIdx.Count - 1) { $headerIdx[$h + 1] - 1 } else { $lines.Count - 1 }
        $blockLines = @($lines[$start..$end])
        while ($blockLines.Count -gt 1 -and [string]::IsNullOrWhiteSpace($blockLines[$blockLines.Count - 1])) {
            $blockLines = @($blockLines[0..($blockLines.Count - 2)])
        }
        [void]$records.Add((Parse-Record $blockLines))
    }
    $all = @($records.ToArray())
    # `Tasks` (the executable lane) and `Proposals` (the curation lane) are Kind-filtered
    # views of the same ordered `Records` union; every T-task operation consumes only
    # `Tasks`, so proposals never become candidates/predecessors, while `Records` preserves
    # exact file order for a byte-faithful round-trip through Build-QueueText.
    return [pscustomobject]@{
        Preamble  = $preamble
        Records   = $all
        Tasks     = @($all | Where-Object { $_.Kind -eq 'task' })
        Proposals = @($all | Where-Object { $_.Kind -eq 'proposal' })
    }
}

function Build-QueueText {
    param([string]$Preamble, $Records)
    $segments = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Preamble)) { [void]$segments.Add($Preamble.TrimEnd("`n")) }
    foreach ($t in $Records) {
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

function Set-ProposalStatus {
    param($Proposal, [string]$NewStatus)
    $Proposal.Status = $NewStatus
    $Proposal.Header = "### [$($Proposal.IdStr)] $($Proposal.Title) — kind: proposal — status: $NewStatus"
}

function Read-QueueState {
    param($Paths)
    $q = Split-Queue (Read-TextOrEmpty $Paths.Queue)
    $pre = $q.Preamble
    if ([string]::IsNullOrWhiteSpace($pre)) { $pre = '# Очередь задач' }
    # Canonical, order-preserving union of both lanes. The T-task commands read/mutate the
    # tasks sub-view (Get-StateTasks) while proposals ride along untouched in Records so the
    # commit round-trips them unchanged.
    return [pscustomobject]@{ Preamble = $pre; Records = @($q.Records) }
}
function Get-StateTasks     { param($State) return @($State.Records | Where-Object { $_.Kind -eq 'task' }) }
function Get-StateProposals { param($State) return @($State.Records | Where-Object { $_.Kind -eq 'proposal' }) }

function Commit-QueueState {
    param($Paths, $State, [int]$GenDelta = 1)
    Write-TextAtomic $Paths.Queue (Build-QueueText $State.Preamble $State.Records)
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
# Highest known P-NNN across the unified backlog + archive. Proposals form their OWN id
# sequence, independent of T-NNN: a P-id is never derived from or collides with a T-id.
function Get-MaxKnownPId {
    param($Paths, $QueueProposals)
    $max = 0
    foreach ($p in $QueueProposals) { if ($p.Id -gt $max) { $max = $p.Id } }
    foreach ($m in [regex]::Matches((Read-TextOrEmpty $Paths.Done), 'P-0*(\d+)')) {
        $v = [int]$m.Groups[1].Value; if ($v -gt $max) { $max = $v }
    }
    return $max
}
function Get-KnownProposalTitles {
    param($QueueProposals)
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($p in $QueueProposals) { [void]$set.Add((Normalize-Title $p.Title)) }
    return ,$set
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
    # Delivery lane per in-queue task (§11.1), for the current -> next_major edge check below.
    $delivery = @{}
    foreach ($t in $QueueTasks) { $delivery[$t.Id] = $t.DeliveryTarget }

    $adj = @{}
    foreach ($t in $QueueTasks) { $adj[$t.Id] = New-Object System.Collections.Generic.List[int] }

    foreach ($t in $QueueTasks) {
        foreach ($p in $t.Predecessors) {
            if ($p -eq $t.Id) { [void]$findings.Add("$($t.IdStr): self-reference in predecessors"); continue }
            $known = $queueIds.Contains($p) -or $doneIds.Contains($p) -or $activeIds.Contains($p)
            if (-not $known) { [void]$findings.Add("$($t.IdStr): missing predecessor $(Format-Id $p) (not in queue, archive, or active)"); continue }
            if ($escalated.ContainsKey($p)) { [void]$findings.Add("$($t.IdStr): infeasible predecessor $(Format-Id $p) (escalated, will never complete)") }
            # A current-lane task must not depend on a next_major-lane predecessor: the next_major
            # task is never admitted to the ordinary cohort, so the edge would block the current
            # task forever (§11.1). The reverse edge (next_major -> current) is allowed.
            if ($t.DeliveryTarget -ne 'next_major' -and $queueIds.Contains($p) -and $delivery[$p] -eq 'next_major') {
                [void]$findings.Add("$($t.IdStr): current task depends on next_major predecessor $(Format-Id $p) (a current-lane task cannot depend on a next_major-lane task)")
            }
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
        [void]$result.Add([pscustomobject]@{ Task = $t; Ready = ($reasons.Count -eq 0); Reasons = @($reasons.ToArray()); Delivery = $t.DeliveryTarget })
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

# Builds a fresh proposal record (kind: proposal, status: proposed). The optional
# provenance fields Suggested target / Source are appended after the body in the same
# order the observability plan (§3.1) shows, so a submitter's authorship survives verbatim.
function New-ProposalBlock {
    param([int]$Id, [string]$Title, [string]$Body, [string]$Source, [string]$SuggestedTarget)
    $bodyLines = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrEmpty($Body)) {
        foreach ($bl in (($Body -replace "`r`n", "`n") -split "`n")) { [void]$bodyLines.Add($bl) }
    }
    if ((-not [string]::IsNullOrEmpty($Source)) -or (-not [string]::IsNullOrEmpty($SuggestedTarget))) {
        while ($bodyLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($bodyLines[$bodyLines.Count - 1])) {
            $bodyLines.RemoveAt($bodyLines.Count - 1)
        }
    }
    if (-not [string]::IsNullOrEmpty($SuggestedTarget)) { [void]$bodyLines.Add("Suggested target: $SuggestedTarget") }
    if (-not [string]::IsNullOrEmpty($Source)) { [void]$bodyLines.Add("Source: $Source") }
    return (Parse-Proposal (@("### [$(Format-PId $Id)] $Title — kind: proposal — status: proposed") + @($bodyLines.ToArray())))
}

# Sets/replaces a single `Key: Value` evaluation field in a proposal body without touching
# the original prose (provenance). Re-classification replaces the existing field in place
# instead of duplicating it, so the operation is idempotent.
function Set-ProposalField {
    param($Proposal, [string]$Key, [string]$Value)
    $out = New-Object System.Collections.Generic.List[string]
    $replaced = $false
    foreach ($bl in $Proposal.Body) {
        if ($bl -match ('^' + [regex]::Escape($Key) + '\s*:')) {
            if (-not $replaced) { [void]$out.Add("${Key}: $Value"); $replaced = $true }
        } else {
            [void]$out.Add($bl)
        }
    }
    if (-not $replaced) {
        while ($out.Count -gt 0 -and [string]::IsNullOrWhiteSpace($out[$out.Count - 1])) { $out.RemoveAt($out.Count - 1) }
        [void]$out.Add("${Key}: $Value")
    }
    $Proposal.Body = @($out.ToArray())
}

# Mutates $State.Records in place (appends one task). Throws typed errors:
#   'DUP:<title>' -> duplicate ; 'DEP:<detail>' -> invalid dependency.
function Add-Proposal {
    param(
        $Paths, $State, [string]$Title, [string]$Body, [int[]]$Predecessors,
        [int]$ExplicitId, [bool]$Force, [System.Collections.Generic.HashSet[string]]$KnownTitles, [ref]$MaxIdRef
    )
    $normTitle = Normalize-Title $Title
    if (-not $Force -and $KnownTitles.Contains($normTitle)) { throw "DUP:$Title" }

    $stateTasks = Get-StateTasks $State
    if ($ExplicitId -gt 0) {
        foreach ($t in $stateTasks) { if ($t.Id -eq $ExplicitId) { throw "DEP:explicit id $(Format-Id $ExplicitId) already in queue" } }
        $id = $ExplicitId
    } else {
        $MaxIdRef.Value = $MaxIdRef.Value + 1
        $id = $MaxIdRef.Value
    }

    $queueIds = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($t in $stateTasks) { [void]$queueIds.Add($t.Id) }
    $doneIds = Get-DoneIds $Paths
    $activeIds = Get-ActiveIds $Paths.TasksDir
    # The new task's own delivery lane rides in its body text (§11.1); a current-lane task may not
    # declare a next_major-lane predecessor (rejected here the same way as missing/infeasible).
    $newDelivery = Get-DeliveryTarget (($Body -replace "`r`n", "`n") -split "`n")
    foreach ($p in $Predecessors) {
        if ($p -eq $id) { throw "DEP:self-reference $(Format-Id $p)" }
        $known = $queueIds.Contains($p) -or $doneIds.Contains($p) -or $activeIds.Contains($p)
        if (-not $known) { throw "DEP:missing predecessor $(Format-Id $p)" }
        $predTask = $stateTasks | Where-Object { $_.Id -eq $p } | Select-Object -First 1
        if ($predTask -and (Is-Escalated $predTask.Status)) { throw "DEP:infeasible predecessor $(Format-Id $p) (escalated)" }
        if ($newDelivery -ne 'next_major' -and $predTask -and $predTask.DeliveryTarget -eq 'next_major') {
            throw "DEP:current task cannot depend on next_major predecessor $(Format-Id $p) (a current-lane task cannot depend on a next_major-lane task)"
        }
    }

    $newTask = New-TaskBlock -Id $id -Title $Title -Body $Body -Predecessors $Predecessors
    $State.Records = @($State.Records) + @($newTask)

    $cycleFindings = Validate-Graph $Paths (Get-StateTasks $State) | Where-Object { $_ -like 'cycle*' }
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
    # Explicit guard: the T-task lifecycle commands (capture/return/escalate/archive/ready)
    # never operate on a proposal. A P-NNN id is refused with a pointed message instead of a
    # generic parse error, so a proposal can never be captured/executed via a T-command.
    if ($raw -match 'P-0*\d+') {
        Fail 2 "invalid --id: $raw is a proposal (kind: proposal); proposals are not executable tasks (use classify-proposal / list-proposals)"
    }
    $m = [regex]::Match($raw, 'T-0*(\d+)')
    if (-not $m.Success) { Fail 2 "invalid --id: $raw" }
    return [int]$m.Groups[1].Value
}
function Parse-ProposalIdArg {
    $raw = Require-Opt 'id'
    $m = [regex]::Match($raw, 'P-0*(\d+)')
    if (-not $m.Success) { Fail 2 "invalid --id: $raw (expected a proposal id P-NNN)" }
    return [int]$m.Groups[1].Value
}
function Get-KindArg {
    $k = ([string](Opt 'kind' 'task')).Trim().ToLowerInvariant()
    if ($k -ne 'task' -and $k -ne 'proposal') { Fail 2 "invalid --kind '$k' (expected 'task' or 'proposal')" }
    return $k
}
function Assert-ExpectedGeneration {
    param($Paths)
    if ($opts.ContainsKey('expected-generation')) {
        $exp = [int]$opts['expected-generation']
        $cur = Get-Generation $Paths.State
        if ($exp -ne $cur) { Fail 3 "generation mismatch: expected $exp, current $cur (queue changed since you read it; re-read and retry)" }
    }
}
function Get-TaskOrFail {
    param($State, [int]$Id)
    $t = (Get-StateTasks $State) | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $t) { Fail 9 "task $(Format-Id $Id) not found in queue" }
    return $t
}
function Get-ProposalOrFail {
    param($State, [int]$Id)
    $p = (Get-StateProposals $State) | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $p) { Fail 9 "proposal $(Format-PId $Id) not found in queue" }
    return $p
}

# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------
function Cmd-AllocateId {
    $paths = Resolve-Paths
    $kind = Get-KindArg
    $q = Split-Queue (Read-TextOrEmpty $paths.Queue)
    if ($kind -eq 'proposal') {
        Write-Output (Format-PId ((Get-MaxKnownPId $paths $q.Proposals) + 1))
        return
    }
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
    $kind = Get-KindArg
    if ($kind -eq 'proposal') { Invoke-ProposeProposal $paths; return }

    $title = Require-Opt 'title'
    $body = Get-BodyArg
    $preds = Get-PredecessorsArg
    $explicitId = 0
    if ($opts.ContainsKey('id')) { $m = [regex]::Match([string]$opts['id'], 'T-0*(\d+)'); if ($m.Success) { $explicitId = [int]$m.Groups[1].Value } }
    $force = [bool](Opt 'force' $false)

    Acquire-Lock $paths.Lock
    try {
        Assert-ExpectedGeneration $paths
        $state = Read-QueueState $paths
        $stateTasks = Get-StateTasks $state
        $known = Get-KnownTitles $paths $stateTasks
        $maxId = [ref](Get-MaxKnownId $paths $stateTasks)
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

# Adds a new proposal-lane record (kind: proposal, status: proposed) to the unified
# backlog. Proposals form their own id/dedup namespace and never validate/carry
# predecessors — they are not executable. See docs/queue_contract.md §20.
function Invoke-ProposeProposal {
    param($paths)
    $title = Require-Opt 'title'
    $body = Get-BodyArg
    $source = [string](Opt 'source' '')
    $target = [string](Opt 'suggested-target' '')
    $force = [bool](Opt 'force' $false)
    $explicitId = 0
    if ($opts.ContainsKey('id')) {
        $m = [regex]::Match([string]$opts['id'], 'P-0*(\d+)')
        if (-not $m.Success) { Fail 2 "invalid --id for --kind proposal: expected P-NNN, got $([string]$opts['id'])" }
        $explicitId = [int]$m.Groups[1].Value
    }

    Acquire-Lock $paths.Lock
    try {
        Assert-ExpectedGeneration $paths
        $state = Read-QueueState $paths
        $proposals = Get-StateProposals $state
        $known = Get-KnownProposalTitles $proposals
        $normTitle = Normalize-Title $title
        if (-not $force -and $known.Contains($normTitle)) {
            Fail 4 "duplicate: a proposal titled '$title' already exists in the backlog"
        }
        if ($explicitId -gt 0) {
            foreach ($p in $proposals) { if ($p.Id -eq $explicitId) { Fail 5 "invalid: explicit proposal id $(Format-PId $explicitId) already in the backlog" } }
            $id = $explicitId
        } else {
            $id = (Get-MaxKnownPId $paths $proposals) + 1
        }
        $newP = New-ProposalBlock -Id $id -Title $title -Body $body -Source $source -SuggestedTarget $target
        $state.Records = @($state.Records) + @($newP)
        $g = Commit-QueueState $paths $state
        Write-Output "id=$($newP.IdStr) generation=$g"
    } finally { Release-Lock $paths.Lock }
}

# Curator outcome for a single proposal: flips its status to one of the closed outcome set
# and appends provenance/evaluation fields WITHOUT rewriting the original proposal prose.
# `converted` requires --tasks naming the created T-ids, each of which must already exist
# (queue/active/archive) so the provenance link is never dangling. The proposal record is
# never deleted — it stays in the backlog as the immutable source (provenance).
function Cmd-ClassifyProposal {
    $paths = Resolve-Paths
    $id = Parse-ProposalIdArg
    $outcome = ([string](Require-Opt 'outcome')).Trim().ToLowerInvariant()
    if ($ProposalOutcomes -notcontains $outcome) {
        Fail 2 "invalid --outcome '$outcome' (expected one of: $($ProposalOutcomes -join ', '))"
    }
    $reason = [string](Opt 'reason' '')
    $tasksRaw = [string](Opt 'tasks' '')

    Acquire-Lock $paths.Lock
    try {
        Assert-ExpectedGeneration $paths
        $state = Read-QueueState $paths
        $p = Get-ProposalOrFail $state $id
        if ($outcome -eq 'converted') {
            $taskIds = New-Object System.Collections.Generic.List[int]
            foreach ($tm in [regex]::Matches($tasksRaw, 'T-0*(\d+)')) { [void]$taskIds.Add([int]$tm.Groups[1].Value) }
            if ($taskIds.Count -eq 0) { Fail 2 "outcome 'converted' requires --tasks `"T-a,T-b`" naming the created task id(s)" }
            $queueTaskIds = New-Object 'System.Collections.Generic.HashSet[int]'
            foreach ($t in (Get-StateTasks $state)) { [void]$queueTaskIds.Add($t.Id) }
            $doneIds = Get-DoneIds $paths
            $activeIds = Get-ActiveIds $paths.TasksDir
            foreach ($tid in $taskIds) {
                $known = $queueTaskIds.Contains($tid) -or $doneIds.Contains($tid) -or $activeIds.Contains($tid)
                if (-not $known) { Fail 5 "converted --tasks references $(Format-Id $tid), which does not exist (create the task first, then classify)" }
            }
            Set-ProposalStatus $p 'converted'
            Set-ProposalField $p 'Converted' (($taskIds | ForEach-Object { Format-Id $_ }) -join ', ')
            if ($reason) { Set-ProposalField $p 'Rationale' $reason }
        } else {
            Set-ProposalStatus $p $outcome
            if ($reason) { Set-ProposalField $p 'Причина' $reason }
        }
        $g = Commit-QueueState $paths $state
        Write-Output "classified $($p.IdStr) status=$outcome generation=$g"
    } finally { Release-Lock $paths.Lock }
}

# Lists proposal-lane records (id, status, title), optionally filtered by --status. Read-only
# helper the curator (and the demonstration) use to find proposals awaiting curation.
function Cmd-ListProposals {
    $paths = Resolve-Paths
    $q = Split-Queue (Read-TextOrEmpty $paths.Queue)
    $filter = $null
    if ($opts.ContainsKey('status')) { $filter = ([string]$opts['status']).Trim().ToLowerInvariant() }
    $rows = New-Object System.Collections.Generic.List[string]
    foreach ($p in $q.Proposals) {
        if ($filter -and ($p.Status.Trim().ToLowerInvariant() -ne $filter)) { continue }
        [void]$rows.Add("$($p.IdStr) $($p.Status) $($p.Title)")
    }
    if ($rows.Count -eq 0) { Write-Output 'proposals: (none)'; return }
    foreach ($r in $rows) { Write-Output $r }
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
        $t = (Get-StateTasks $state) | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if (-not $t) { Write-Output "not-present $(Format-Id $id)"; return }  # idempotent
        # Remove only the matching TASK record; proposal-lane records (even a coincident
        # P-NNN with the same number) ride along untouched.
        $state.Records = @($state.Records | Where-Object { -not ($_.Kind -eq 'task' -and $_.Id -eq $id) })
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
    # Delivery-lane selection (§11.1): the DEFAULT output is the ordinary `current` lane that
    # planner/processor capture from; `--next-major` shows the parked next_major backlog SEPARATELY,
    # never mixed into the default `ready` set.
    $nextMajor = [bool](Opt 'next-major' $false)
    if ($opts.ContainsKey('id')) {
        $id = Parse-IdArg
        $one = $res | Where-Object { $_.Task.Id -eq $id } | Select-Object -First 1
        if (-not $one) { Fail 9 "task $(Format-Id $id) is not a 'не начата' queue task" }
        # A next_major task is parked out of the ordinary current-lane capture gate: never ready
        # here, so the processor/engine capture gate refuses it (exit 6), same as an unmet prereq.
        if ($one.Delivery -eq 'next_major') {
            Write-Output "not-ready $($one.Task.IdStr): next_major delivery lane (parked; not admitted to the current cohort — see queue_contract §11.1)"
            exit 6
        }
        if ($one.Ready) { Write-Output "ready $($one.Task.IdStr)"; return }
        Write-Output "not-ready $($one.Task.IdStr): $(@($one.Reasons) -join '; ')"
        exit 6
    }
    $lane = if ($nextMajor) { 'next_major' } else { 'current' }
    $laneRes = @($res | Where-Object { $_.Delivery -eq $lane })
    $readyIds = @($laneRes | Where-Object { $_.Ready } | ForEach-Object { $_.Task.IdStr })
    if ($readyIds.Count -gt 0) { Write-Output ("ready: " + ($readyIds -join ' ')) } else { Write-Output 'ready: (none)' }
    foreach ($r in ($laneRes | Where-Object { -not $_.Ready })) {
        Write-Output "not-ready: $($r.Task.IdStr) - $(@($r.Reasons) -join '; ')"
    }
}

function Cmd-InboxAdd {
    $paths = Resolve-Paths
    $kind = Get-KindArg
    $title = Require-Opt 'title'
    $body = Get-BodyArg
    if (-not (Test-Path -LiteralPath $paths.Inbox)) { $null = New-Item -ItemType Directory -Force -Path $paths.Inbox }
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $name = "$stamp-$PID-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
    if ($kind -eq 'proposal') {
        # A proposal-lane inbox record: no predecessors (proposals never carry them); carries
        # the optional provenance fields instead. Drained into a `[P-NNN] ... kind: proposal`.
        $record = @{
            kind             = 'proposal'
            title            = $title
            body             = $body
            source           = [string](Opt 'source' '')
            suggested_target = [string](Opt 'suggested-target' '')
            created          = ([DateTime]::UtcNow.ToString('o'))
        }
    } else {
        $preds = Get-PredecessorsArg
        $record = @{
            kind         = 'task'
            title        = $title
            predecessors = @($preds | ForEach-Object { Format-Id $_ })
            body         = $body
            created      = ([DateTime]::UtcNow.ToString('o'))
        }
    }
    Write-TextAtomic (Join-Path $paths.Inbox $name) ($record | ConvertTo-Json -Depth 5)
    Write-Output "inbox=$name"
}

function Initialize-InboxRejectedDirectory {
    param($Paths)
    if (Test-Path -LiteralPath $Paths.Inbox) {
        if (-not (Test-Path -LiteralPath $Paths.Inbox -PathType Container)) {
            throw "inbox path is not a directory: $($Paths.Inbox)"
        }
    } else {
        $null = New-Item -ItemType Directory -Path $Paths.Inbox
    }
    if (Test-Path -LiteralPath $Paths.Rejected) {
        if (-not (Test-Path -LiteralPath $Paths.Rejected -PathType Container)) {
            throw "rejected path is not a directory: $($Paths.Rejected)"
        }
    } else {
        $null = New-Item -ItemType Directory -Path $Paths.Rejected
    }
}

function Move-InboxRecordToRejected {
    param($Paths, [System.IO.FileInfo]$Entry, [string]$Reason)
    $rejectedAt = [DateTime]::UtcNow
    $stamp = $rejectedAt.ToString('yyyyMMddTHHmmss')
    $originalBase = [System.IO.Path]::GetFileNameWithoutExtension($Entry.Name)
    $rejectedBase = "$stamp-$originalBase"
    $recordName = "$rejectedBase.json"
    $metadataName = "$rejectedBase.metadata.txt"
    $recordPath = Join-Path $Paths.Rejected $recordName
    $metadataPath = Join-Path $Paths.Rejected $metadataName
    if ((Test-Path -LiteralPath $recordPath) -or (Test-Path -LiteralPath $metadataPath)) {
        throw "rejected audit target already exists for '$($Entry.Name)'"
    }
    $metadata = @(
        "Rejection reason: $Reason"
        "Timestamp of rejection: $($rejectedAt.ToString('o'))"
        ''
    ) -join [Environment]::NewLine
    Write-TextAtomic $metadataPath $metadata
    Move-Item -LiteralPath $Entry.FullName -Destination $recordPath
    return [pscustomobject]@{ RecordName = $recordName; MetadataName = $metadataName }
}

function Cmd-InboxDrain {
    $paths = Resolve-Paths
    try {
        Initialize-InboxRejectedDirectory $paths
    } catch {
        Fail 5 "cannot initialize inbox: $($_.Exception.Message)"
    }

    Acquire-Lock $paths.Lock
    try {
        try {
            $entries = @(Get-ChildItem -LiteralPath $paths.Inbox -Filter '*.json' -File -ErrorAction Stop | Sort-Object Name)
        } catch {
            Fail 5 "cannot read inbox: $($_.Exception.Message)"
        }
        if ($entries.Count -eq 0) { Write-Output 'inbox empty'; return }
        try {
            $state = Read-QueueState $paths
            $stateTasks0 = Get-StateTasks $state
            $known = Get-KnownTitles $paths $stateTasks0
            $maxId = [ref](Get-MaxKnownId $paths $stateTasks0)
            $knownP = Get-KnownProposalTitles (Get-StateProposals $state)
            $maxPId = [ref](Get-MaxKnownPId $paths (Get-StateProposals $state))
        } catch {
            Fail 5 "cannot read queue state for inbox drain: $($_.Exception.Message)"
        }
        $added = New-Object System.Collections.Generic.List[string]
        $skipped = New-Object System.Collections.Generic.List[string]
        $rejected = New-Object System.Collections.Generic.List[string]
        $consume = New-Object System.Collections.Generic.List[string]
        $processingErrors = New-Object System.Collections.Generic.List[string]
        foreach ($e in $entries) {
            try {
                $rec = (Read-TextOrEmpty $e.FullName) | ConvertFrom-Json -ErrorAction Stop
                if ($null -eq $rec) { throw 'JSON content is empty' }
            }
            catch {
                $reason = [string]$_.Exception.Message
                try {
                    $moved = Move-InboxRecordToRejected $paths $e $reason
                    [void]$rejected.Add("$($e.Name) -> $($moved.RecordName): $reason")
                } catch {
                    [void]$processingErrors.Add("$($e.Name): could not quarantine unreadable JSON: $($_.Exception.Message)")
                }
                continue
            }
            $recKind = 'task'
            if (($rec.PSObject.Properties.Name -contains 'kind') -and $rec.kind) { $recKind = ([string]$rec.kind).Trim().ToLowerInvariant() }
            $recBody = ''
            if ($rec.PSObject.Properties.Name -contains 'body') { $recBody = [string]$rec.body }

            if ($recKind -eq 'proposal') {
                # Proposal-lane record: title-dedup only, no dependency graph, cannot fail with
                # DEP/cycle, so no rollback path is needed beyond the pre-append dup check.
                $normTitle = Normalize-Title ([string]$rec.title)
                if ($knownP.Contains($normTitle)) { [void]$skipped.Add("$($e.Name): duplicate proposal"); [void]$consume.Add($e.FullName); continue }
                $recSource = ''; $recTarget = ''
                if ($rec.PSObject.Properties.Name -contains 'source') { $recSource = [string]$rec.source }
                if ($rec.PSObject.Properties.Name -contains 'suggested_target') { $recTarget = [string]$rec.suggested_target }
                $maxPId.Value = $maxPId.Value + 1
                $np = New-ProposalBlock -Id $maxPId.Value -Title ([string]$rec.title) -Body $recBody -Source $recSource -SuggestedTarget $recTarget
                $state.Records = @($state.Records) + @($np)
                [void]$knownP.Add($normTitle)
                [void]$added.Add($np.IdStr); [void]$consume.Add($e.FullName)
                continue
            }

            $recordCountBefore = @($state.Records).Count
            $maxIdBefore = [int]$maxId.Value
            try {
                $recPreds = @()
                if (($rec.PSObject.Properties.Name -contains 'predecessors') -and $rec.predecessors) {
                    $recPreds = @($rec.predecessors | ForEach-Object { [int]([regex]::Match([string]$_, '\d+').Value) })
                }
                $nt = Add-Proposal $paths $state ([string]$rec.title) $recBody $recPreds 0 $false $known $maxId
                [void]$added.Add($nt.IdStr); [void]$consume.Add($e.FullName)
            } catch {
                $msg = [string]$_.Exception.Message
                $maxId.Value = $maxIdBefore
                if ($recordCountBefore -eq 0) { $state.Records = @() }
                else { $state.Records = @($state.Records | Select-Object -First $recordCountBefore) }
                if ($msg -like 'DUP:*') { [void]$skipped.Add("$($e.Name): duplicate"); [void]$consume.Add($e.FullName) }
                elseif ($msg -like 'DEP:*') {
                    try {
                        $moved = Move-InboxRecordToRejected $paths $e $msg
                        [void]$rejected.Add("$($e.Name) -> $($moved.RecordName): $msg")
                    } catch {
                        [void]$processingErrors.Add("$($e.Name): could not quarantine rejected record: $($_.Exception.Message)")
                    }
                }
                else { [void]$processingErrors.Add("$($e.Name): $msg") }
            }
        }
        if ($added.Count -gt 0) {
            try { [void](Commit-QueueState $paths $state $added.Count) }
            catch { Fail 5 "inbox queue commit failed: $($_.Exception.Message)" }
        }
        foreach ($f in $consume) {
            try { Remove-Item -LiteralPath $f -Force -ErrorAction Stop }
            catch { [void]$processingErrors.Add("$([System.IO.Path]::GetFileName($f)): could not consume record: $($_.Exception.Message)") }
        }
        Write-Output ("added: " + (@($added.ToArray()) -join ' '))
        if ($skipped.Count -gt 0) { Write-Output ("skipped-dup: " + (@($skipped.ToArray()) -join '; ')) }
        foreach ($r in $rejected) { Write-Output "rejected: $r" }
        if ($processingErrors.Count -gt 0) {
            Fail 5 ("inbox processing errors: " + (@($processingErrors.ToArray()) -join '; '))
        }
    } finally { Release-Lock $paths.Lock }
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
        'inbox-add'          { Cmd-InboxAdd }
        'inbox-drain'        { Cmd-InboxDrain }
        'classify-proposal'  { Cmd-ClassifyProposal }
        'list-proposals'     { Cmd-ListProposals }
        default {
            Fail 2 "unknown command '$Command'. Valid: allocate-id, propose, capture, return, escalate, archive, validate-deps, ready, generation, bump-generation, inbox-add, inbox-drain, classify-proposal, list-proposals"
        }
    }
} catch {
    exit (Resolve-CatchExit $_ 'QTXERR' 'queue-tx' 'QUEUE_TX_DEBUG')
}
