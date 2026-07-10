<#
.SYNOPSIS
    Transactional control plane for Orchestra's runtime state: the orchestrator
    ownership lease, cohort/task state-transition validation, and a control-plane
    generation counter.

.DESCRIPTION
    This is the companion of tools/queue-tx.ps1. Where queue-tx.ps1 is the single
    transactional interface for the task *queue* (`.work/Tasks_Queue.md`), this tool
    is the single transactional interface for the *control plane* that governs a run:

      1. Owner lease (`.work/orchestrator.lock`). Historically the lock was a bare
         directory whose `info` file held only host + start time, with "is the holder
         alive?" unanswerable and takeover judged by eyeball. This tool turns it into a
         real lease record (`.work/orchestrator.lock/lease.json`) that carries an
         owner id, session id, project root, host, an optional local-liveness proof
         (pid + that process's creation time), an acquire timestamp, a heartbeat, a TTL
         and a monotonic generation. The lease is captured, renewed, and released
         atomically (temp file + rename); only the current owner may heartbeat or
         release it; a safe takeover is allowed only when the holder is provably not
         live (pid gone / pid reused / heartbeat past TTL) or an operator forces it;
         and an owner-checked release means a late crash-recovery straggler of an old
         run cannot tear down a *new* lease taken over after it.

      2. State-transition validation (`check-transition`). The task/cohort/integration
         lifecycles have a fixed set of legal transitions (documented normatively in
         docs/queue_contract.md). This verb validates a proposed transition against
         that table and rejects an illegal one with a precise diagnostic (which state
         machine, which from->to, what was allowed) so the caller halts the dangerous
         mutation instead of silently writing an inconsistent status. The state names
         are canonical ASCII tokens; the human-readable Markdown (its Cyrillic status
         literals) is a compatible presentation that maps onto these tokens.

      3. Control-plane generation (`generation` / `bump-generation`). A monotonic
         counter in `.work/control_state.json`, the state-plane analogue of queue-tx's
         `.work/queue_state.json`, usable as an optimistic compare-and-swap guard for
         cohort/task/integration state mutations.

    Every mutation serializes behind a short atomic lock (`.work/state-tx.lock`, a
    CreateNew lock file, separate from `.work/orchestrator.lock` and
    `.work/queue-tx.lock`), reads the current on-disk state under that lock, and writes
    crash-safely; a corrupt or contradictory lease halts the operation with a precise
    error rather than silently overwriting.

.NOTES
    Runs under both PowerShell 7 (pwsh) and Windows PowerShell 5.1. All emitted/parsed
    content is ASCII (canonical state tokens, JSON with English keys), so the file is
    plain UTF-8 (no BOM required) and is immune to 5.1's no-BOM ANSI fallback.

    Fault injection: set $env:STATE_TX_FAULT to a stage name to make that stage throw,
    exactly like queue-tx.ps1's $env:QUEUE_TX_FAULT. Stages: after-dir-create,
    before-lease-write, before-rename, after-rename.

    Exit codes:
      0   success
      2   usage / argument error
      3   generation mismatch (caller's --expected-generation is stale)
      7   could not acquire the state-tx lock (timeout)
      8   illegal state transition (check-transition)
      10  lease held (a live lease is owned by someone else)
      11  a stale lease is present (acquire refuses; use takeover or --force)
      12  no lease to renew (heartbeat on a missing lease)
      13  not the owner (owner id mismatch; also the late-cleanup-race guard on release)
      14  no lease present (status / verify)
      15  lease root mismatch (verify / addressed takeover guard)
      16  lease role mismatch (verify / addressed takeover guard)
      17  own lease but stale (verify: resume should re-adopt / cold-recover)
      18  corrupt / invalid lease record

.EXAMPLE
    pwsh -File tools/state-tx.ps1 acquire   --work /abs/.work --root /abs --role processor --pid 12345
    pwsh -File tools/state-tx.ps1 heartbeat --work /abs/.work --owner <id>
    pwsh -File tools/state-tx.ps1 verify    --work /abs/.work --require-root /abs --require-role processor
    pwsh -File tools/state-tx.ps1 takeover  --work /abs/.work --root /abs --role processor --require-root /abs
    pwsh -File tools/state-tx.ps1 release   --work /abs/.work --owner <id>
    pwsh -File tools/state-tx.ps1 status    --work /abs/.work --json
    pwsh -File tools/state-tx.ps1 check-transition --kind task --from working --to ready
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

function Fail {
    param([int]$Code, [string]$Message)
    throw ('STXERR|' + $Code + '|' + $Message)
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

# --------------------------------------------------------------------------
# Paths (resolved once --work is known)
# --------------------------------------------------------------------------
function Resolve-Paths {
    $work = Require-Opt 'work'
    if (-not (Test-Path -LiteralPath $work)) { $null = New-Item -ItemType Directory -Force -Path $work }
    return [pscustomobject]@{
        Work    = $work
        LockDir = Join-Path $work 'orchestrator.lock'
        Lease   = Join-Path $work 'orchestrator.lock/lease.json'
        TxLock  = Join-Path $work 'state-tx.lock'
        State   = Join-Path $work 'control_state.json'
    }
}

# --------------------------------------------------------------------------
# Crash-safe IO (mirrors queue-tx.ps1)
# --------------------------------------------------------------------------
function Read-TextOrEmpty {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return [System.IO.File]::ReadAllText($Path) }
    return ''
}
function Maybe-Fault {
    param([string]$Stage)
    if ($env:STATE_TX_FAULT -and $env:STATE_TX_FAULT -eq $Stage) {
        throw "injected fault at stage '$Stage'"
    }
}
function Write-TextAtomic {
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($false)  # no BOM for .work/*.json
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $Content, $enc)
    Maybe-Fault 'before-rename'
    Move-Item -LiteralPath $tmp -Destination $Path -Force
    Maybe-Fault 'after-rename'
}

# --------------------------------------------------------------------------
# Short serialization lock (identical primitive to queue-tx.ps1's queue lock)
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
            if ([DateTime]::UtcNow -gt $deadline) { Fail 7 "could not acquire state-tx lock at $LockPath (held by another writer)" }
            Start-Sleep -Milliseconds 50
        }
    }
}
function Release-Lock {
    param([string]$LockPath)
    Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------------
# Time helpers (UTC, round-trippable ISO 8601)
# --------------------------------------------------------------------------
function Format-Utc { param([datetime]$D) return $D.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
function Parse-Utc {
    # DateTimeOffset unambiguously honours a trailing 'Z' / explicit offset and, with
    # AssumeUniversal, treats an offset-less string as UTC too (never as local). Using
    # DateTime.Parse+ToUniversalTime here would misread a 'Z' string as local on hosts
    # whose offset != 0, throwing the heartbeat age off by the local UTC offset.
    param([string]$S)
    return [System.DateTimeOffset]::Parse($S, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
}
function Get-HostName { return [System.Net.Dns]::GetHostName() }

# --------------------------------------------------------------------------
# Local liveness proof: a recorded pid is authoritative *on its own host* only.
# We record the holder pid's creation time at acquire; a takeover candidate can
# then tell "process gone" and "pid reused by a different process" apart from a
# genuinely live holder, and does not wait out the TTL when the pid is provably
# gone. When no usable pid is recorded (or the check runs on a different host),
# liveness falls back to the heartbeat/TTL freshness signal.
# --------------------------------------------------------------------------
function Get-ProcStart {
    param([int]$ProcId)
    try {
        $p = Get-Process -Id $ProcId -ErrorAction SilentlyContinue
        if (-not $p) { return [pscustomobject]@{ Exists = $false; Start = $null } }
        $st = $null
        try { $st = $p.StartTime.ToUniversalTime() } catch { $st = $null }
        return [pscustomobject]@{ Exists = $true; Start = $st }
    } catch {
        return [pscustomobject]@{ Exists = $false; Start = $null }
    }
}
function Lease-HasProp { param($Lease, [string]$Name) return ($Lease.PSObject.Properties.Name -contains $Name) }
function Get-Liveness {
    param($Lease, [datetime]$Now)
    $hbAge = ($Now - (Parse-Utc $Lease.heartbeat)).TotalSeconds
    $ttl = [double]$Lease.ttl_seconds
    $curHost = Get-HostName
    $pidVal = 0
    if ((Lease-HasProp $Lease 'pid') -and $Lease.pid) { $pidVal = [int]$Lease.pid }
    $usePid = ($pidVal -gt 0) -and ($Lease.host -eq $curHost)
    if ($usePid) {
        $ps = Get-ProcStart $pidVal
        if (-not $ps.Exists) {
            return [pscustomobject]@{ Live = $false; Basis = 'pid'; HeartbeatAgeSec = [int]$hbAge; Reason = "pid $pidVal is not running (holder process is gone)" }
        }
        $recStart = $null
        if ((Lease-HasProp $Lease 'pid_started') -and $Lease.pid_started) { $recStart = Parse-Utc $Lease.pid_started }
        if ($null -ne $recStart -and $null -ne $ps.Start) {
            $delta = [math]::Abs(($ps.Start - $recStart).TotalSeconds)
            if ($delta -le 2) {
                return [pscustomobject]@{ Live = $true; Basis = 'pid'; HeartbeatAgeSec = [int]$hbAge; Reason = "pid $pidVal alive (start-time matches)" }
            }
            return [pscustomobject]@{ Live = $false; Basis = 'pid'; HeartbeatAgeSec = [int]$hbAge; Reason = "pid $pidVal reused by a different process (start-time mismatch)" }
        }
        return [pscustomobject]@{ Live = $true; Basis = 'pid-weak'; HeartbeatAgeSec = [int]$hbAge; Reason = "pid $pidVal present (no start-time proof; treated as alive)" }
    }
    if ($hbAge -lt $ttl) {
        return [pscustomobject]@{ Live = $true; Basis = 'heartbeat'; HeartbeatAgeSec = [int]$hbAge; Reason = "heartbeat $([int]$hbAge)s old < ttl $([int]$ttl)s" }
    }
    return [pscustomobject]@{ Live = $false; Basis = 'heartbeat'; HeartbeatAgeSec = [int]$hbAge; Reason = "heartbeat $([int]$hbAge)s old >= ttl $([int]$ttl)s (expired)" }
}

# --------------------------------------------------------------------------
# Lease read/write
# --------------------------------------------------------------------------
function Read-Lease {
    param($Paths)
    if (-not (Test-Path -LiteralPath $Paths.Lease)) { return [pscustomobject]@{ Present = $false; Valid = $false; Lease = $null; Error = $null } }
    $raw = Read-TextOrEmpty $Paths.Lease
    if ([string]::IsNullOrWhiteSpace($raw)) { return [pscustomobject]@{ Present = $true; Valid = $false; Lease = $null; Error = 'empty lease file' } }
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json } catch { return [pscustomobject]@{ Present = $true; Valid = $false; Lease = $null; Error = 'unparseable JSON' } }
    foreach ($f in @('role', 'owner_id', 'root', 'host', 'heartbeat', 'ttl_seconds', 'generation')) {
        if (-not (Lease-HasProp $obj $f)) { return [pscustomobject]@{ Present = $true; Valid = $false; Lease = $obj; Error = "missing field '$f'" } }
    }
    try { [void](Parse-Utc $obj.heartbeat) } catch { return [pscustomobject]@{ Present = $true; Valid = $false; Lease = $obj; Error = 'unparseable heartbeat timestamp' } }
    return [pscustomobject]@{ Present = $true; Valid = $true; Lease = $obj; Error = $null }
}
function Write-Lease {
    param($Paths, $Rec)
    if (-not (Test-Path -LiteralPath $Paths.LockDir)) { $null = New-Item -ItemType Directory -Force -Path $Paths.LockDir }
    Maybe-Fault 'after-dir-create'
    Maybe-Fault 'before-lease-write'
    Write-TextAtomic $Paths.Lease ($Rec | ConvertTo-Json -Depth 5)
}
function Resolve-PidFields {
    $pidVal = $null
    $pidStarted = $null
    $pidArg = [string](Opt 'pid' '')
    if ($pidArg -and $pidArg -match '^\d+$') {
        $pidVal = [int]$pidArg
        if ($pidVal -gt 0) {
            $ps = Get-ProcStart $pidVal
            if ($ps.Exists -and $null -ne $ps.Start) { $pidStarted = Format-Utc $ps.Start }
        } else { $pidVal = $null }
    }
    return [pscustomobject]@{ Pid = $pidVal; Started = $pidStarted }
}

# --------------------------------------------------------------------------
# Control-plane generation counter (state-plane analogue of queue_state.json)
# --------------------------------------------------------------------------
function Get-ControlGeneration {
    param([string]$StatePath)
    if (-not (Test-Path -LiteralPath $StatePath)) { return 0 }
    try {
        $obj = (Read-TextOrEmpty $StatePath) | ConvertFrom-Json
        if ($obj -and (Lease-HasProp $obj 'generation')) { return [int]$obj.generation }
    } catch { }
    return 0
}
function Set-ControlGeneration {
    param([string]$StatePath, [int]$Value)
    Write-TextAtomic $StatePath (@{ generation = $Value } | ConvertTo-Json -Compress)
}

# --------------------------------------------------------------------------
# State-transition tables (canonical ASCII; see docs/queue_contract.md).
# --------------------------------------------------------------------------
$script:Transitions = @{
    task        = @{
        'not-started' = @('working')
        'working'     = @('in-review', 'ready', 'escalated', 'conflict')
        'in-review'   = @('in-review', 'working', 'ready', 'escalated', 'conflict')
        'ready'       = @('merged', 'conflict', 'escalated')
        'merged'      = @('published', 'conflict')
        'published'   = @('done')
        'conflict'    = @('not-started', 'escalated')
        'done'        = @()
        'escalated'   = @()
    }
    cohort      = @{
        'open'   = @('closed')
        'closed' = @()
    }
    integration = @{
        'none'        = @('in-progress')
        'in-progress' = @('reviewed', 'failed')
        'reviewed'    = @('published', 'in-progress', 'failed')
        'published'   = @('cleaned')
        'failed'      = @('in-progress', 'cleaned')
        'cleaned'     = @()
    }
}

# --------------------------------------------------------------------------
# Commands: lease lifecycle
# --------------------------------------------------------------------------
function Invoke-Acquire {
    param([string]$Mode)   # 'acquire' | 'takeover'
    $paths = Resolve-Paths
    $root = Require-Opt 'root'
    $role = [string](Opt 'role' 'processor')
    $hostVal = [string](Opt 'host' (Get-HostName))
    $session = [string](Opt 'session' '')
    $ttl = [int](Opt 'ttl' 900)
    if ($ttl -le 0) { Fail 2 "--ttl must be a positive number of seconds" }
    $owner = [string](Opt 'owner' '')
    if (-not $owner) { $owner = [guid]::NewGuid().ToString('N') }
    $force = [bool](Opt 'force' $false)
    $pidInfo = Resolve-PidFields

    Acquire-Lock $paths.TxLock
    try {
        $now = [datetime]::UtcNow
        $existing = Read-Lease $paths
        $prevOwner = $null
        $baseGen = 0
        if ($existing.Present) {
            if (-not $existing.Valid) {
                if (-not $force) { Fail 18 "existing lease is corrupt ($($existing.Error)); refuse to $Mode without --force" }
                # --force: overwrite the corrupt record.
            } else {
                $L = $existing.Lease
                if ($opts.ContainsKey('require-root') -and $L.root -ne (Require-Opt 'require-root')) {
                    Fail 15 "lease belongs to a different project root '$($L.root)' (required '$([string](Opt 'require-root'))'); not adopting it"
                }
                if ($opts.ContainsKey('require-role') -and $L.role -ne [string](Opt 'require-role')) {
                    Fail 16 "lease belongs to a different role '$($L.role)' (required '$([string](Opt 'require-role'))'); not adopting it"
                }
                if ($opts.ContainsKey('require-owner') -and $L.owner_id -ne [string](Opt 'require-owner')) {
                    Fail 13 "lease owner '$($L.owner_id)' != required '$([string](Opt 'require-owner'))'"
                }
                $live = Get-Liveness $L $now
                if ($live.Live -and -not $force) {
                    Fail 10 "lease is held (live) by owner=$($L.owner_id) host=$($L.host) role=$($L.role) ($($live.Reason)); refuse to $Mode without --force"
                }
                if ($Mode -eq 'acquire' -and -not $force) {
                    Fail 11 "a stale lease is present (owner=$($L.owner_id), $($live.Reason)); use 'takeover' or --force to adopt it"
                }
                $prevOwner = $L.owner_id
                $baseGen = [int]$L.generation
            }
        }
        $gen = $baseGen + 1
        $nowIso = Format-Utc $now
        $rec = [ordered]@{
            schema          = 'orchestra/lease@1'
            role            = $role
            owner_id        = $owner
            session_id      = $session
            root            = $root
            host            = $hostVal
            pid             = $pidInfo.Pid
            pid_started     = $pidInfo.Started
            acquired        = $nowIso
            heartbeat       = $nowIso
            ttl_seconds     = $ttl
            generation      = $gen
            taken_over_from = $prevOwner
        }
        Write-Lease $paths $rec
        $suffix = ''
        if ($prevOwner) { $suffix = " taken_over_from=$prevOwner" }
        Write-Output "$Mode owner=$owner generation=$gen role=$role ttl=$ttl$suffix"
    } finally { Release-Lock $paths.TxLock }
}

function Cmd-Heartbeat {
    $paths = Resolve-Paths
    $owner = Require-Opt 'owner'
    Acquire-Lock $paths.TxLock
    try {
        $existing = Read-Lease $paths
        if (-not $existing.Present) { Fail 12 "no lease to renew at $($paths.Lease)" }
        if (-not $existing.Valid) { Fail 18 "lease is corrupt ($($existing.Error)); cannot renew" }
        $L = $existing.Lease
        if ($L.owner_id -ne $owner) { Fail 13 "not the owner: lease owned by '$($L.owner_id)', you presented '$owner'" }
        if ($opts.ContainsKey('expected-generation')) {
            $exp = [int]$opts['expected-generation']
            if ($exp -ne [int]$L.generation) { Fail 3 "generation mismatch: expected $exp, current $($L.generation)" }
        }
        $gen = [int]$L.generation + 1
        $now = Format-Utc ([datetime]::UtcNow)
        $rec = [ordered]@{
            schema          = 'orchestra/lease@1'
            role            = $L.role
            owner_id        = $L.owner_id
            session_id      = $L.session_id
            root            = $L.root
            host            = $L.host
            pid             = $L.pid
            pid_started     = $L.pid_started
            acquired        = $L.acquired
            heartbeat       = $now
            ttl_seconds     = $L.ttl_seconds
            generation      = $gen
            taken_over_from = $L.taken_over_from
        }
        Write-Lease $paths $rec
        Write-Output "heartbeat owner=$owner generation=$gen"
    } finally { Release-Lock $paths.TxLock }
}

function Cmd-Release {
    $paths = Resolve-Paths
    $force = [bool](Opt 'force' $false)
    $owner = [string](Opt 'owner' '')
    if (-not $force -and -not $owner) { Fail 2 "release requires --owner (or --force)" }
    Acquire-Lock $paths.TxLock
    try {
        $existing = Read-Lease $paths
        if (-not $existing.Present) { Write-Output 'not-held'; return }  # idempotent
        if (-not $existing.Valid) {
            if (-not $force) { Fail 18 "lease is corrupt ($($existing.Error)); use --force to remove it" }
        } else {
            $L = $existing.Lease
            if (-not $force -and $L.owner_id -ne $owner) {
                # Late-cleanup-race guard: an old run's straggler cleanup must not tear
                # down a lease that has since been taken over by someone else.
                Fail 13 "refusing to release lease owned by '$($L.owner_id)' (you presented '$owner'); a takeover may have occurred"
            }
        }
        Remove-Item -LiteralPath $paths.LockDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Output 'released'
    } finally { Release-Lock $paths.TxLock }
}

function Cmd-Verify {
    # Addressed ownership check for resume: is the current lease *our* processor's
    # lease for *this* project root, and is it live or stale?
    $paths = Resolve-Paths
    $existing = Read-Lease $paths
    if (-not $existing.Present) { Write-Output 'no-lease'; exit 14 }
    if (-not $existing.Valid) { Write-Output "corrupt-lease ($($existing.Error))"; exit 18 }
    $L = $existing.Lease
    if ($opts.ContainsKey('require-root') -and $L.root -ne [string](Opt 'require-root')) {
        Write-Output "root-mismatch lease-root=$($L.root)"; exit 15
    }
    if ($opts.ContainsKey('require-role') -and $L.role -ne [string](Opt 'require-role')) {
        Write-Output "role-mismatch lease-role=$($L.role)"; exit 16
    }
    if ($opts.ContainsKey('owner') -and $L.owner_id -ne [string](Opt 'owner')) {
        Write-Output "owner-mismatch lease-owner=$($L.owner_id)"; exit 13
    }
    $live = Get-Liveness $L ([datetime]::UtcNow)
    if ($live.Live) { Write-Output "own-live owner=$($L.owner_id) role=$($L.role) ($($live.Reason))"; return }
    Write-Output "own-stale owner=$($L.owner_id) role=$($L.role) ($($live.Reason))"; exit 17
}

function Cmd-Status {
    $paths = Resolve-Paths
    $existing = Read-Lease $paths
    if (-not $existing.Present) {
        if ([bool](Opt 'json' $false)) { Write-Output (@{ present = $false } | ConvertTo-Json -Compress) }
        else { Write-Output 'no-lease' }
        exit 14
    }
    if (-not $existing.Valid) {
        if ([bool](Opt 'json' $false)) { Write-Output (@{ present = $true; valid = $false; error = $existing.Error } | ConvertTo-Json -Compress) }
        else { Write-Output "corrupt-lease ($($existing.Error))" }
        exit 18
    }
    $L = $existing.Lease
    $live = Get-Liveness $L ([datetime]::UtcNow)
    if ([bool](Opt 'json' $false)) {
        $out = [ordered]@{
            present            = $true
            valid              = $true
            role               = $L.role
            owner_id           = $L.owner_id
            session_id         = $L.session_id
            root               = $L.root
            host               = $L.host
            pid                = $L.pid
            acquired           = $L.acquired
            heartbeat          = $L.heartbeat
            ttl_seconds        = $L.ttl_seconds
            generation         = $L.generation
            live               = $live.Live
            liveness_basis     = $live.Basis
            heartbeat_age_secs = $live.HeartbeatAgeSec
            reason             = $live.Reason
        }
        Write-Output ($out | ConvertTo-Json -Compress)
    } else {
        $state = if ($live.Live) { 'live' } else { 'stale' }
        Write-Output "lease $state owner=$($L.owner_id) role=$($L.role) host=$($L.host) pid=$($L.pid) generation=$($L.generation) heartbeat_age=$($live.HeartbeatAgeSec)s ($($live.Reason))"
    }
}

# --------------------------------------------------------------------------
# Commands: transition validation & control generation
# --------------------------------------------------------------------------
function Cmd-CheckTransition {
    $kind = Require-Opt 'kind'
    $from = Require-Opt 'from'
    $to = Require-Opt 'to'
    if (-not $script:Transitions.ContainsKey($kind)) {
        Fail 2 "unknown --kind '$kind' (valid: task, cohort, integration)"
    }
    $tbl = $script:Transitions[$kind]
    if (-not $tbl.ContainsKey($from)) {
        Fail 2 "unknown $kind state --from '$from' (valid: $((@($tbl.Keys) | Sort-Object) -join ', '))"
    }
    if (-not $tbl.ContainsKey($to)) {
        Fail 2 "unknown $kind state --to '$to' (valid: $((@($tbl.Keys) | Sort-Object) -join ', '))"
    }
    $allowed = @($tbl[$from])
    if ($allowed -contains $to) { Write-Output "ok ${kind}: $from -> $to"; return }
    $allowedStr = if ($allowed.Count -gt 0) { $allowed -join ', ' } else { '(terminal, none)' }
    Fail 8 "illegal $kind transition: $from -> $to (allowed from '$from': $allowedStr)"
}

function Cmd-Generation {
    $paths = Resolve-Paths
    Write-Output (Get-ControlGeneration $paths.State)
}
function Cmd-BumpGeneration {
    $paths = Resolve-Paths
    Acquire-Lock $paths.TxLock
    try {
        if ($opts.ContainsKey('expected-generation')) {
            $exp = [int]$opts['expected-generation']
            $cur = Get-ControlGeneration $paths.State
            if ($exp -ne $cur) { Fail 3 "generation mismatch: expected $exp, current $cur" }
        }
        $g = (Get-ControlGeneration $paths.State) + 1
        Set-ControlGeneration $paths.State $g
        Write-Output "generation=$g"
    } finally { Release-Lock $paths.TxLock }
}

# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------
try {
    switch ($Command) {
        'acquire'          { Invoke-Acquire 'acquire' }
        'takeover'         { Invoke-Acquire 'takeover' }
        'heartbeat'        { Cmd-Heartbeat }
        'release'          { Cmd-Release }
        'verify'           { Cmd-Verify }
        'status'           { Cmd-Status }
        'check-transition' { Cmd-CheckTransition }
        'generation'       { Cmd-Generation }
        'bump-generation'  { Cmd-BumpGeneration }
        default {
            Fail 2 "unknown command '$Command'. Valid: acquire, takeover, heartbeat, release, verify, status, check-transition, generation, bump-generation"
        }
    }
} catch {
    $m = [string]$_.Exception.Message
    if ($m -like 'STXERR|*') {
        $parts = $m -split '\|', 3
        [Console]::Error.WriteLine("state-tx: $($parts[2])")
        exit ([int]$parts[1])
    }
    [Console]::Error.WriteLine("state-tx: $m")
    if ($env:STATE_TX_DEBUG) { [Console]::Error.WriteLine($_.ScriptStackTrace) }
    exit 1
}
