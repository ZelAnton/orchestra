<#
.SYNOPSIS
    Transactional, validated, idempotent single-writer interface for Orchestra's
    durable observability event-outbox `.work/events.jsonl` (task T-089).

.DESCRIPTION
    `.work/events.jsonl` is Orchestra's append-only machine event-outbox: one JSON
    object per line, written best-effort by the single orchestrator.lock owner
    (processor) so a future observability platform can rebuild state projections
    without parsing Markdown. This tool is the companion of tools/queue-tx.ps1
    (the queue) and tools/state-tx.ps1 (the control plane); it is the single
    transactional interface for that outbox. It turns a bare `printf ... >>` append
    into a mechanism that is:

      1. Deterministically deduplicated. Every event id is a UUIDv5 derived from a
         STABLE dedupe key (type + entity + transition + per-entity state generation
         + attempt number), NOT a fresh random UUID per resume. A crash/replay of the
         SAME committed transition recomputes the SAME id and is deduplicated; a genuine
         retry (new attempt), a new review round, a new wave and a new status transition
         each produce a DISTINCT id and stay separate observable facts. The stable-key
         coordinates are all durably reconstructable from the Markdown source of truth
         (queue `попытка=N`, task-descriptor `Циклов-ревью: N`, cohort wave, batch/task
         ids), so replay is stable WITHOUT introducing any new persistent counter.

      2. Schema-validated at write and at read. The envelope (`schema_version`,
         `event_id`, `occurred_at`, `type`, optional `batch_id`/`task_id`/`payload_version`,
         `actor`, `payload`) and the per-type payload allowlist are validated before an
         append and when a consumer reads. Read validation is lenient forward (tolerates
         unknown future top-level keys and a missing `payload_version`) so EVERY existing
         previously-written line still reads without any rewrite / retroactive migration.

      3. Torn-tail safe. A crash mid-append can only leave an incomplete final record
         (append-only + single writer). `append` repairs it by dropping ONLY the trailing
         unterminated fragment that does not parse as a valid event; it never touches a
         byte of any newline-terminated line before it, so no valid committed line is lost
         and no second semantic event is ever created for an already-committed fact.

      4. Single-writer. Concurrent appends serialize behind an atomic CreateNew lock
         (`<events>.lock`); a forbidden parallel writer that cannot take the lock fails
         (exit 7). With `--owner`, an append is additionally bound to the current
         orchestrator.lock lease owner, so a writer that is not the run owner is rejected
         (exit 13) even if it momentarily holds the short lock.

      5. Consumable. `read` is a reference consumer/cursor: it reads the outbox, validates
         and deduplicates by `event_id`, skips a torn tail, and (with `--cursor`) advances
         a durable read position so it only ever returns new unique events. `metrics`
         is a projection over the deduplicated stream that reports phase / critical-path
         transaction durations (round wall-time, codex.attempt durations, per-task
         captured->done critical path) computed only from timestamps and non-sensitive
         integer durations.

    Emission stays best-effort and strictly additive to the Markdown updates: a failed
    append never blocks a phase/status transition. Sensitive-text redaction is a separate
    concern handled upstream (tools/redaction.ps1, docs/queue_contract.md §18) before a
    free-text `reason` reaches this tool; this tool additionally refuses obviously unsafe
    payload shapes (absolute paths, the codex.attempt non-allowlisted keys).

.NOTES
    Runs under both PowerShell 7 (pwsh) and Windows PowerShell 5.1. Emitted JSON is a
    single compact line; the file is UTF-8 without BOM.

    Exit codes:
      0   success (an idempotent duplicate skip is success, not an error)
      2   usage / argument error
      3   input read failure (unreadable events file / cursor)
      4   integrity conflict (same event_id already present with a different type)
      5   validation failure (envelope / payload invalid)
      6   unrepairable corruption (a newline-terminated committed line is invalid)
      7   could not acquire the outbox lock (timeout; a parallel writer holds it)
      13  not the run owner (--owner does not match the orchestrator.lock lease)

.EXAMPLE
    pwsh -File tools/outbox.ps1 event-id --type task.status_changed --task-id T-014 --from "в работе" --to "на ревью" --attempt 1 --round 1
    pwsh -File tools/outbox.ps1 append --work /abs/.work --owner <id> --type cohort.opened --batch-id B-... --payload '{"wave":1}'
    pwsh -File tools/outbox.ps1 read   --work /abs/.work --cursor /abs/.work/events_cursor.json --json
    pwsh -File tools/outbox.ps1 verify --work /abs/.work
    pwsh -File tools/outbox.ps1 metrics --work /abs/.work --json
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# --------------------------------------------------------------------------
# Argument parsing:  <command> [--key value | --flag] ...
# --------------------------------------------------------------------------
$Command = if ($args.Count -ge 1) { [string]$args[0] } else { '' }
$BoolFlags = @('json', 'stdin')
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

function Fail { param([int]$Code, [string]$Message) throw ('OBXERR|' + $Code + '|' + $Message) }
function Opt { param([string]$Name, $Default = $null) if ($opts.ContainsKey($Name)) { return $opts[$Name] } else { return $Default } }
function Require-Opt {
    param([string]$Name)
    if (-not $opts.ContainsKey($Name) -or [string]::IsNullOrEmpty([string]$opts[$Name])) { Fail 2 "missing required option --$Name" }
    return [string]$opts[$Name]
}
function Has-Prop { param($Obj, [string]$Name) return ($null -ne $Obj -and $Obj.PSObject.Properties.Name -contains $Name) }
function Get-Prop { param($Obj, [string]$Name) if (Has-Prop $Obj $Name) { return $Obj.$Name } else { return $null } }

# --------------------------------------------------------------------------
# Contract constants: the versioned envelope + type set + payload allowlists.
# This is the single source of truth the writer and the consumer share.
# --------------------------------------------------------------------------
$script:SchemaVersion = 1
$script:KnownEnvelopeKeys = @('schema_version', 'event_id', 'occurred_at', 'type', 'batch_id', 'task_id', 'payload_version', 'actor', 'payload')
$script:KnownActorKinds = @('agent', 'human', 'tool')
$script:KnownTypes = @(
    'cohort.opened', 'cohort.round_started', 'cohort.round_closed', 'cohort.admission_closed',
    'cohort.join_started', 'cohort.published', 'cohort.closed',
    'task.captured', 'task.status_changed', 'codex.attempt'
)
# codex.attempt payload is a strict scalar allowlist (privacy: no prompt/diff/paths/secrets).
$script:CodexAttemptKeys = @(
    'task_id', 'role', 'mode', 'attempt_number', 'started_at', 'ended_at', 'duration_ms',
    'effective_model', 'effective_reasoning', 'effective_sandbox', 'effective_network',
    'exit_code', 'outcome', 'outcome_reason'
)
$script:UuidRegex = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
# The pre-T-089 no-generator fallback id shape (kept read-compatible so old lines validate).
$script:EvtFallbackRegex = '^evt-[0-9A-Za-z:_.\-]+$'
$script:IsoUtcRegex = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$'

# --------------------------------------------------------------------------
# UUIDv5 (RFC 4122, SHA1) over the standard URL namespace. No built-in in .NET,
# so it is implemented from the primitive. GUID.ToByteArray() emits the first
# three fields little-endian; RFC 4122 hashing needs big-endian, hence the swap.
# --------------------------------------------------------------------------
$script:UrlNamespace = [guid]'6ba7b811-9dad-11d1-80b4-00c04fd430c8'

function Convert-GuidToRfcBytes {
    param([guid]$G)
    $b = $G.ToByteArray()
    $r = New-Object 'byte[]' 16
    $r[0] = $b[3]; $r[1] = $b[2]; $r[2] = $b[1]; $r[3] = $b[0]
    $r[4] = $b[5]; $r[5] = $b[4]
    $r[6] = $b[7]; $r[7] = $b[6]
    [System.Array]::Copy($b, 8, $r, 8, 8)
    return $r
}
function Format-RfcBytesToGuid {
    param([byte[]]$R)
    $sb = New-Object System.Text.StringBuilder
    foreach ($x in $R) { [void]$sb.Append($x.ToString('x2')) }
    $h = $sb.ToString()
    return ($h.Substring(0, 8) + '-' + $h.Substring(8, 4) + '-' + $h.Substring(12, 4) + '-' + $h.Substring(16, 4) + '-' + $h.Substring(20, 12))
}
function New-UuidV5 {
    param([string]$Name, [guid]$Namespace = $script:UrlNamespace)
    $nsBytes = Convert-GuidToRfcBytes $Namespace
    $nameBytes = [System.Text.Encoding]::UTF8.GetBytes($Name)
    $buf = New-Object 'byte[]' ($nsBytes.Length + $nameBytes.Length)
    [System.Array]::Copy($nsBytes, 0, $buf, 0, $nsBytes.Length)
    [System.Array]::Copy($nameBytes, 0, $buf, $nsBytes.Length, $nameBytes.Length)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try { $hash = $sha1.ComputeHash($buf) } finally { $sha1.Dispose() }
    $out = New-Object 'byte[]' 16
    [System.Array]::Copy($hash, 0, $out, 0, 16)
    $out[6] = [byte](($out[6] -band 0x0F) -bor 0x50)   # version 5
    $out[8] = [byte](($out[8] -band 0x3F) -bor 0x80)   # RFC 4122 variant
    return (Format-RfcBytesToGuid $out)
}

# --------------------------------------------------------------------------
# Stable dedupe-key canonical name (-> UUIDv5). Per-type coordinate assembly is
# the single normative definition of event identity (see docs/queue_contract.md
# §19). Each coordinate is durably reconstructable from the Markdown state, so a
# crash/replay of the same committed fact rebuilds the same name and dedups.
# --------------------------------------------------------------------------
function Get-CoordAttempt { $a = [string](Opt 'attempt' '1'); if ($a -notmatch '^\d+$') { Fail 2 "--attempt must be a non-negative integer" }; return [int]$a }
function Get-CoordRound { $r = [string](Opt 'round' '1'); if ($r -notmatch '^\d+$') { Fail 2 "--round must be a non-negative integer" }; return [int]$r }

function Get-CanonicalName {
    param([string]$Type)
    switch -Regex ($Type) {
        '^cohort\.(opened|admission_closed|join_started|published|closed)$' {
            $b = Require-Opt 'batch-id'
            return "orchestra/$Type/$b"
        }
        '^cohort\.round_(started|closed)$' {
            $b = Require-Opt 'batch-id'
            $w = [string](Require-Opt 'wave')
            if ($w -notmatch '^\d+$') { Fail 2 "--wave must be a non-negative integer" }
            return "orchestra/$Type/$b/w$w"
        }
        '^task\.captured$' {
            $b = Require-Opt 'batch-id'
            $t = Require-Opt 'task-id'
            return "orchestra/$Type/$b/$t/a$(Get-CoordAttempt)"
        }
        '^task\.status_changed$' {
            $t = Require-Opt 'task-id'
            $from = Require-Opt 'from'
            $to = Require-Opt 'to'
            return "orchestra/$Type/$t/$from>$to/a$(Get-CoordAttempt)/r$(Get-CoordRound)"
        }
        '^codex\.attempt$' {
            $t = Require-Opt 'task-id'
            $role = Require-Opt 'role'
            $mode = Require-Opt 'mode'
            $an = [string](Require-Opt 'attempt-number')
            if ($an -notmatch '^\d+$') { Fail 2 "--attempt-number must be a non-negative integer" }
            return "orchestra/$Type/$t/$role/$mode/$an"
        }
        default { Fail 2 "unknown --type '$Type' (valid: $($script:KnownTypes -join ', '))" }
    }
}

# --------------------------------------------------------------------------
# Paths. Either --work (canonical .work/events.jsonl) or --events (explicit file).
# --------------------------------------------------------------------------
function Resolve-Paths {
    $work = [string](Opt 'work' '')
    $events = [string](Opt 'events' '')
    if (-not $events) {
        if (-not $work) { Fail 2 "need --work or --events" }
        $events = Join-Path $work 'events.jsonl'
    }
    # With --work the lock follows the .work/<name>-tx.lock convention (companion to
    # queue-tx.lock / state-tx.lock); with a bare --events it sits beside the file.
    $defaultLock = if ($work) { Join-Path $work 'outbox-tx.lock' } else { "$events.lock" }
    $lock = [string](Opt 'lock' $defaultLock)
    $lease = ''
    if ($work) { $lease = Join-Path $work 'orchestrator.lock/lease.json' }
    return [pscustomobject]@{ Work = $work; Events = $events; Lock = $lock; Lease = $lease }
}

# --------------------------------------------------------------------------
# Crash-safe IO helpers (mirror queue-tx / state-tx).
# --------------------------------------------------------------------------
function Read-BytesOrEmpty {
    param([string]$Path)
    # Comma-wrap so PowerShell returns the array itself instead of unrolling it (an
    # empty byte[] would otherwise collapse to $null and break .Length downstream).
    if (Test-Path -LiteralPath $Path) {
        try { return ,([System.IO.File]::ReadAllBytes($Path)) } catch { Fail 3 "cannot read $Path ($($_.Exception.Message))" }
    }
    return ,(New-Object 'byte[]' 0)
}
function Read-TextOrEmpty {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return [System.IO.File]::ReadAllText($Path) }
    return ''
}
function Write-TextAtomic {
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($false)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $Content, $enc)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Maybe-Fault {
    param([string]$Stage)
    if ($env:OUTBOX_FAULT -and $env:OUTBOX_FAULT -eq $Stage) { throw "injected fault at stage '$Stage'" }
}

# --------------------------------------------------------------------------
# Short serialization lock (identical primitive to queue-tx / state-tx).
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
            if ([DateTime]::UtcNow -gt $deadline) { Fail 7 "could not acquire outbox lock at $LockPath (held by another writer)" }
            Start-Sleep -Milliseconds 50
        }
    }
}
function Release-Lock { param([string]$LockPath) Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue }

# --------------------------------------------------------------------------
# Time helpers.
# --------------------------------------------------------------------------
function Format-UtcNow { return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
function Parse-Utc {
    param([string]$S)
    return [System.DateTimeOffset]::Parse($S, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
}
# ConvertFrom-Json coerces ISO-8601 strings to [datetime]; accept either shape and
# never round-trip through a culture-localized ToString() (which would misparse).
function To-Utc {
    param($V)
    if ($V -is [datetime]) { return ([datetime]$V).ToUniversalTime() }
    if ($V -is [System.DateTimeOffset]) { return ([System.DateTimeOffset]$V).UtcDateTime }
    return (Parse-Utc ([string]$V))
}

# --------------------------------------------------------------------------
# Line model over raw bytes: precise byte offsets let torn-tail repair and the
# cursor operate without ever re-encoding a committed line.
# --------------------------------------------------------------------------
function Get-LineSpans {
    param([byte[]]$Bytes)
    $spans = New-Object System.Collections.Generic.List[object]
    $start = 0
    for ($i = 0; $i -lt $Bytes.Length; $i++) {
        if ($Bytes[$i] -eq 0x0A) {
            $spans.Add([pscustomobject]@{ Start = $start; End = $i; HasNewline = $true })
            $start = $i + 1
        }
    }
    if ($start -lt $Bytes.Length) {
        $spans.Add([pscustomobject]@{ Start = $start; End = $Bytes.Length; HasNewline = $false })
    }
    return ,$spans
}
function Decode-Span {
    param([byte[]]$Bytes, $Span)
    $len = $Span.End - $Span.Start
    if ($len -le 0) { return '' }
    return ([System.Text.Encoding]::UTF8.GetString($Bytes, $Span.Start, $len)).TrimEnd("`r")
}

# Parse+validate a decoded line. Returns @{ Obj; Valid; Error }. $Mode is 'read' or 'write'.
function Test-EventText {
    param([string]$Text, [string]$Mode)
    if ([string]::IsNullOrWhiteSpace($Text)) { return [pscustomobject]@{ Obj = $null; Valid = $false; Error = 'empty line' } }
    $obj = $null
    try { $obj = $Text | ConvertFrom-Json } catch { return [pscustomobject]@{ Obj = $null; Valid = $false; Error = 'unparseable JSON' } }
    if ($null -eq $obj -or $obj -is [array] -or $obj.GetType().FullName -ne 'System.Management.Automation.PSCustomObject') {
        return [pscustomobject]@{ Obj = $null; Valid = $false; Error = 'line is not a JSON object' }
    }
    $err = Test-Envelope $obj $Mode
    if ($err) { return [pscustomobject]@{ Obj = $obj; Valid = $false; Error = $err } }
    return [pscustomobject]@{ Obj = $obj; Valid = $true; Error = $null }
}

# Structural envelope + payload validation. Read mode is lenient forward (extra
# unknown top-level keys tolerated, payload_version optional) so existing lines
# always validate; write mode is strict.
function Test-Envelope {
    param($Obj, [string]$Mode)
    foreach ($f in @('schema_version', 'event_id', 'occurred_at', 'type', 'actor', 'payload')) {
        if (-not (Has-Prop $Obj $f)) { return "missing required field '$f'" }
    }
    $sv = $Obj.schema_version
    if (-not ($sv -is [int] -or $sv -is [long] -or ([string]$sv -match '^\d+$'))) { return "schema_version must be an integer" }
    if ([int]$sv -ne $script:SchemaVersion) { return "unsupported schema_version $sv (this tool speaks $($script:SchemaVersion))" }
    $eid = [string]$Obj.event_id
    if ($Mode -eq 'write') {
        if ($eid -notmatch $script:UuidRegex -and $eid -notmatch $script:EvtFallbackRegex) { return "event_id '$eid' is not a UUID or evt- fallback id" }
    } else {
        if ([string]::IsNullOrWhiteSpace($eid) -or $eid -match '\s') { return "event_id must be a non-empty whitespace-free token" }
    }
    $oa = $Obj.occurred_at
    if ($oa -is [datetime] -or $oa -is [System.DateTimeOffset]) {
        # ConvertFrom-Json already parsed a date-like string into a real timestamp.
    } elseif ([string]$oa -notmatch $script:IsoUtcRegex) {
        return "occurred_at '$oa' is not ISO-8601 UTC (…Z)"
    }
    if ($script:KnownTypes -notcontains [string]$Obj.type) { return "unknown type '$($Obj.type)'" }
    if (Has-Prop $Obj 'batch_id') { if ([string]$Obj.batch_id -notmatch '^B-') { return "batch_id '$($Obj.batch_id)' does not look like a B-id" } }
    if (Has-Prop $Obj 'task_id') { if ([string]$Obj.task_id -notmatch '^T-\d') { return "task_id '$($Obj.task_id)' does not look like a T-id" } }
    if (Has-Prop $Obj 'payload_version') {
        $pv = $Obj.payload_version
        if (-not ($pv -is [int] -or $pv -is [long] -or ([string]$pv -match '^\d+$')) -or [int]$pv -lt 1) { return "payload_version must be a positive integer" }
    }
    $actor = $Obj.actor
    if ($null -eq $actor -or $actor.GetType().FullName -ne 'System.Management.Automation.PSCustomObject') { return "actor must be an object" }
    if (-not (Has-Prop $actor 'kind') -or $script:KnownActorKinds -notcontains [string]$actor.kind) { return "actor.kind must be one of $($script:KnownActorKinds -join '/')" }
    if (-not (Has-Prop $actor 'name') -or [string]::IsNullOrEmpty([string]$actor.name)) { return "actor.name is required" }
    $payload = $Obj.payload
    if ($null -eq $payload -or $payload -is [array] -or $payload.GetType().FullName -ne 'System.Management.Automation.PSCustomObject') { return "payload must be an object" }
    if ($Mode -eq 'write') {
        foreach ($k in $Obj.PSObject.Properties.Name) {
            if ($script:KnownEnvelopeKeys -notcontains $k) { return "unknown top-level key '$k' (writer is strict)" }
        }
        $pathErr = Test-NoAbsolutePath $payload
        if ($pathErr) { return $pathErr }
        if ([string]$Obj.type -eq 'codex.attempt') {
            foreach ($k in $payload.PSObject.Properties.Name) {
                if ($script:CodexAttemptKeys -notcontains $k) { return "codex.attempt payload key '$k' is not in the privacy allowlist" }
            }
        }
    }
    return $null
}

# Reject an absolute filesystem path anywhere in the payload (privacy: never persist
# an absolute path; a `.work/worktrees/<T-ID>` relative path is fine).
function Test-NoAbsolutePath {
    param($Node)
    if ($null -eq $Node) { return $null }
    if ($Node -is [string]) {
        if ($Node -match '^[A-Za-z]:[\\/]' -or $Node -match '^/[^/]' -or $Node -match '(?<![\w.])[A-Za-z]:\\') { return "payload contains an absolute path ('$Node'); use .work/worktrees/<T-ID> relative form" }
        return $null
    }
    if ($Node -is [array]) {
        foreach ($e in $Node) { $r = Test-NoAbsolutePath $e; if ($r) { return $r } }
        return $null
    }
    if ($Node.GetType().FullName -eq 'System.Management.Automation.PSCustomObject') {
        foreach ($p in $Node.PSObject.Properties) { $r = Test-NoAbsolutePath $p.Value; if ($r) { return $r } }
    }
    return $null
}

# --------------------------------------------------------------------------
# Read all records of the outbox: valid/invalid classification + torn-tail info.
# --------------------------------------------------------------------------
function Read-Outbox {
    param([string]$Path, [string]$Mode = 'read')
    $bytes = Read-BytesOrEmpty $Path
    $spans = Get-LineSpans $bytes
    $records = New-Object System.Collections.Generic.List[object]
    $tornTail = $null
    $lastCompleteEnd = 0   # byte offset just past the last newline-terminated line
    for ($idx = 0; $idx -lt $spans.Count; $idx++) {
        $span = $spans[$idx]
        $text = Decode-Span $bytes $span
        $res = Test-EventText $text $Mode
        if ($span.HasNewline) { $lastCompleteEnd = $span.End + 1 }
        if (-not $span.HasNewline) {
            # Only the very last span can be unterminated. A valid unterminated final
            # line is a complete event whose trailing newline was lost (keep it); an
            # invalid one is a torn write fragment (repairable).
            if ($res.Valid) {
                $records.Add([pscustomobject]@{ Span = $span; Text = $text; Obj = $res.Obj; Valid = $true; Error = $null; Unterminated = $true })
            } else {
                $tornTail = [pscustomobject]@{ Span = $span; Text = $text; Error = $res.Error }
            }
            continue
        }
        $records.Add([pscustomobject]@{ Span = $span; Text = $text; Obj = $res.Obj; Valid = $res.Valid; Error = $res.Error; Unterminated = $false })
    }
    return [pscustomobject]@{
        Bytes           = $bytes
        Records         = $records
        TornTail        = $tornTail
        LastCompleteEnd = $lastCompleteEnd
    }
}

# Deduplicate a record list by event_id (first occurrence wins). Only valid records.
function Get-DedupedEvents {
    param($Records)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Records) {
        if (-not $r.Valid) { continue }
        $id = [string]$r.Obj.event_id
        if ($seen.Add($id)) { [void]$out.Add($r.Obj) }
    }
    return ,$out
}

# --------------------------------------------------------------------------
# Owner (single-writer) check against the orchestrator.lock lease.
# --------------------------------------------------------------------------
function Assert-Owner {
    param($Paths)
    if (-not $opts.ContainsKey('owner')) { return }   # owner binding is opt-in
    $owner = [string]$opts['owner']
    if (-not $Paths.Lease) { Fail 2 "--owner needs --work to locate the orchestrator.lock lease" }
    if (-not (Test-Path -LiteralPath $Paths.Lease)) { Fail 13 "no lease present; a non-owner may not write the durable outbox" }
    $lease = $null
    try { $lease = (Read-TextOrEmpty $Paths.Lease) | ConvertFrom-Json } catch { Fail 13 "lease is unreadable; refuse to write the durable outbox as an unverified writer" }
    if (-not (Has-Prop $lease 'owner_id') -or [string]$lease.owner_id -ne $owner) {
        Fail 13 "not the run owner: lease owner is '$([string](Get-Prop $lease 'owner_id'))', you presented '$owner' (single-writer invariant)"
    }
}

# ==========================================================================
# event-id : compute the deterministic dedupe id from the stable key.
# ==========================================================================
function Cmd-EventId {
    $type = Require-Opt 'type'
    $name = Get-CanonicalName $type
    Write-Output (New-UuidV5 $name)
}

# ==========================================================================
# append : validated, idempotent, torn-tail-safe, single-writer append.
# ==========================================================================
function Build-EventLine {
    param([string]$EventId)
    $type = Require-Opt 'type'
    $occurred = [string](Opt 'occurred-at' (Format-UtcNow))
    if ($occurred -notmatch $script:IsoUtcRegex) { Fail 5 "--occurred-at '$occurred' is not ISO-8601 UTC (yyyy-MM-ddTHH:mm:ss[.fff]Z)" }
    $actorKind = [string](Opt 'actor-kind' 'agent')
    $actorName = [string](Opt 'actor-name' 'processor')
    $payloadRaw = [string](Opt 'payload' '{}')
    $payload = $null
    try { $payload = $payloadRaw | ConvertFrom-Json } catch { Fail 5 "--payload is not valid JSON" }
    if ($null -eq $payload) { $payload = [pscustomobject]@{} }

    $rec = [ordered]@{ schema_version = $script:SchemaVersion; event_id = $EventId; occurred_at = $occurred; type = $type }
    if ($opts.ContainsKey('batch-id') -and $opts['batch-id']) { $rec['batch_id'] = [string]$opts['batch-id'] }
    if ($opts.ContainsKey('task-id') -and $opts['task-id']) { $rec['task_id'] = [string]$opts['task-id'] }
    if ($opts.ContainsKey('payload-version') -and $opts['payload-version']) { $rec['payload_version'] = [int]$opts['payload-version'] }
    $rec['actor'] = [ordered]@{ kind = $actorKind; name = $actorName }
    $rec['payload'] = $payload

    $line = ($rec | ConvertTo-Json -Depth 30 -Compress)
    if ($line -match "[\r\n]") { Fail 5 "serialized event contains a newline (payload has a raw control char)" }
    return $line
}

function Cmd-Append {
    $paths = Resolve-Paths
    Assert-Owner $paths

    # event id: explicit --event-id (raw-line callers) or derived from the stable key.
    $eid = ''
    if ($opts.ContainsKey('json-line') -or $opts.ContainsKey('stdin')) {
        $line = if ($opts.ContainsKey('json-line')) { [string]$opts['json-line'] } else { [Console]::In.ReadToEnd() }
        $line = ($line -replace "`r", '').Trim()
    } else {
        if ($opts.ContainsKey('event-id') -and $opts['event-id']) { $eid = [string]$opts['event-id'] }
        else { $eid = New-UuidV5 (Get-CanonicalName (Require-Opt 'type')) }
        $line = Build-EventLine $eid
    }

    # write-mode validation of the exact bytes we intend to append.
    $chk = Test-EventText $line 'write'
    if (-not $chk.Valid) { Fail 5 "refusing to append an invalid event: $($chk.Error)" }
    $eid = [string]$chk.Obj.event_id

    $timeout = [int](Opt 'lock-timeout-ms' 30000)
    Acquire-Lock $paths.Lock $timeout
    try {
        $ob = Read-Outbox $paths.Events 'read'
        # A newline-terminated committed line that is itself invalid is unrepairable
        # corruption (append repairs only the trailing unterminated fragment).
        foreach ($r in $ob.Records) {
            if (-not $r.Valid -and -not $r.Unterminated) { Fail 6 "a committed line is invalid ($($r.Error)); refuse to append over corruption (run 'verify')" }
        }
        # idempotent dedup / integrity conflict against already-present ids.
        $isDuplicate = $false
        foreach ($r in $ob.Records) {
            if ($r.Valid -and [string]$r.Obj.event_id -eq $eid) {
                if ([string]$r.Obj.type -ne [string]$chk.Obj.type) { Fail 4 "event_id $eid already present with a different type '$($r.Obj.type)' (integrity conflict)" }
                $isDuplicate = $true
                break
            }
        }

        # torn-tail repair plan (drop ONLY the trailing unparseable fragment; keep a valid
        # unterminated last line and just separate our append from it).
        $needLeadingNewline = $false
        $truncateTo = $ob.Bytes.Length
        if ($null -ne $ob.TornTail) {
            $truncateTo = $ob.TornTail.Span.Start
        } elseif ($ob.Records.Count -gt 0 -and $ob.Records[$ob.Records.Count - 1].Unterminated) {
            $needLeadingNewline = $true
        }

        Maybe-Fault 'before-open'
        $fs = [System.IO.File]::Open($paths.Events, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $repaired = $false
        try {
            # Repair a torn tail even on the idempotent-skip path, so an append never
            # leaves stray truncated bytes behind (the outbox self-heals on every write).
            if ($truncateTo -lt $fs.Length) { $fs.SetLength($truncateTo); $repaired = $true }
            if (-not $isDuplicate) {
                $fs.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
                $enc = New-Object System.Text.UTF8Encoding($false)
                $prefix = if ($needLeadingNewline) { "`n" } else { '' }
                $bytesOut = $enc.GetBytes($prefix + $line + "`n")
                Maybe-Fault 'before-write'
                $fs.Write($bytesOut, 0, $bytesOut.Length)
                Maybe-Fault 'before-flush'
                $fs.Flush($true)
            }
        } finally { $fs.Dispose() }
        $note = if ($repaired) { ' repaired-torn-tail' } else { '' }
        if ($isDuplicate) { Write-Output "skipped-duplicate event_id=$eid$note" }
        else { Write-Output "appended event_id=$eid$note" }
    } finally { Release-Lock $paths.Lock }
}

# ==========================================================================
# verify : validate the whole outbox (non-mutating).
# ==========================================================================
function Cmd-Verify {
    $paths = Resolve-Paths
    $ob = Read-Outbox $paths.Events 'read'
    $total = 0; $valid = 0
    $invalid = New-Object System.Collections.Generic.List[string]
    $ids = @{}
    $dups = New-Object System.Collections.Generic.List[string]
    $lineNo = 0
    foreach ($r in $ob.Records) {
        $lineNo++
        $total++
        if (-not $r.Valid) { [void]$invalid.Add("line ${lineNo}: $($r.Error)"); continue }
        $valid++
        $id = [string]$r.Obj.event_id
        if ($ids.ContainsKey($id)) { [void]$dups.Add("line ${lineNo}: duplicate event_id $id") } else { $ids[$id] = $true }
    }
    $tornMsg = if ($null -ne $ob.TornTail) { "torn tail present ($($ob.TornTail.Error)) - a subsequent append repairs it" } else { 'none' }
    if ([bool](Opt 'json' $false)) {
        # NB: assign List/collection values directly; an inline @(...) inside an
        # [ordered]@{} literal trips a "Argument types do not match" parser quirk.
        $out = [ordered]@{
            events        = $total
            valid         = $valid
            invalid       = $invalid
            unique_ids    = $ids.Count
            duplicates    = $dups
            torn_tail     = ($null -ne $ob.TornTail)
            torn_detail   = $tornMsg
        }
        Write-Output ($out | ConvertTo-Json -Depth 6 -Compress)
    } else {
        Write-Output "outbox: events=$total valid=$valid unique_ids=$($ids.Count) duplicates=$($dups.Count) torn_tail=$tornMsg"
        foreach ($m in $invalid) { Write-Output "  invalid: $m" }
        foreach ($m in $dups) { Write-Output "  $m" }
    }
    # a newline-terminated invalid line is hard corruption; a torn tail alone is fine.
    $hardBad = @($ob.Records | Where-Object { -not $_.Valid -and -not $_.Unterminated })
    if ($hardBad.Count -gt 0) { exit 6 }
    if ($dups.Count -gt 0) { exit 4 }
}

# ==========================================================================
# read : reference consumer/cursor. Dedup by event_id; optional durable cursor.
# ==========================================================================
function Cmd-Read {
    $paths = Resolve-Paths
    $ob = Read-Outbox $paths.Events 'read'

    $startOffset = 0
    $delivered = New-Object 'System.Collections.Generic.HashSet[string]'
    $cursorPath = [string](Opt 'cursor' '')
    if ($cursorPath -and (Test-Path -LiteralPath $cursorPath)) {
        try {
            $cur = (Read-TextOrEmpty $cursorPath) | ConvertFrom-Json
            if (Has-Prop $cur 'byte_offset') { $startOffset = [int]$cur.byte_offset }
            if (Has-Prop $cur 'delivered_ids') { foreach ($id in @($cur.delivered_ids)) { [void]$delivered.Add([string]$id) } }
        } catch { Fail 3 "cursor $cursorPath is unreadable" }
    }

    $new = New-Object System.Collections.Generic.List[object]
    $skippedInvalid = 0
    $skippedDup = 0
    $advance = $startOffset
    foreach ($r in $ob.Records) {
        if ($r.Unterminated) { continue }                 # never consume a torn/unterminated tail
        if ($r.Span.Start -lt $startOffset) { continue }  # already consumed in a prior cursor read
        $advance = $r.Span.End + 1
        if (-not $r.Valid) { $skippedInvalid++; continue }
        $id = [string]$r.Obj.event_id
        if (-not $delivered.Add($id)) { $skippedDup++; continue }
        [void]$new.Add($r.Obj)
    }

    if ($cursorPath) {
        $curOut = [ordered]@{ byte_offset = $advance; delivered_ids = $delivered }
        Write-TextAtomic $cursorPath ($curOut | ConvertTo-Json -Depth 6 -Compress)
    }

    if ([bool](Opt 'json' $false)) {
        $out = [ordered]@{
            new_count        = $new.Count
            skipped_invalid  = $skippedInvalid
            skipped_dup      = $skippedDup
            byte_offset      = $advance
            events           = $new
        }
        Write-Output ($out | ConvertTo-Json -Depth 30 -Compress)
    } else {
        Write-Output "read: new=$($new.Count) skipped_invalid=$skippedInvalid skipped_dup=$skippedDup byte_offset=$advance"
    }
}

# ==========================================================================
# metrics : phase / critical-path duration projection over the deduped stream.
# All figures are timestamps / integer durations only - no sensitive payload data.
# ==========================================================================
function Cmd-Metrics {
    $paths = Resolve-Paths
    $ob = Read-Outbox $paths.Events 'read'
    $events = Get-DedupedEvents $ob.Records

    $typeCounts = [ordered]@{}
    foreach ($t in $script:KnownTypes) { $typeCounts[$t] = 0 }
    $codexDur = New-Object System.Collections.Generic.List[int]
    $roundStart = @{}   # "batch|wave" -> occurred_at
    $roundDur = New-Object System.Collections.Generic.List[object]
    $taskCaptured = @{} # task_id -> earliest occurred_at
    $taskDone = @{}     # task_id -> occurred_at of status_changed to выполнена

    foreach ($e in $events) {
        $type = [string]$e.type
        if ($typeCounts.Contains($type)) { $typeCounts[$type] = $typeCounts[$type] + 1 }
        $pl = $e.payload
        switch ($type) {
            'codex.attempt' {
                if ((Has-Prop $pl 'duration_ms') -and ([string]$pl.duration_ms -match '^\d+$')) { [void]$codexDur.Add([int]$pl.duration_ms) }
            }
            'cohort.round_started' {
                $w = if (Has-Prop $pl 'wave') { [string]$pl.wave } else { '?' }
                $roundStart["$([string](Get-Prop $e 'batch_id'))|$w"] = $e.occurred_at
            }
            'cohort.round_closed' {
                $w = if (Has-Prop $pl 'wave') { [string]$pl.wave } else { '?' }
                $k = "$([string](Get-Prop $e 'batch_id'))|$w"
                if ($roundStart.ContainsKey($k)) {
                    $ms = [int]((To-Utc $e.occurred_at) - (To-Utc $roundStart[$k])).TotalMilliseconds
                    [void]$roundDur.Add([pscustomobject]@{ key = $k; duration_ms = $ms })
                }
            }
            'task.captured' {
                $t = [string](Get-Prop $e 'task_id')
                if ($t -and (-not $taskCaptured.ContainsKey($t))) { $taskCaptured[$t] = $e.occurred_at }
            }
            'task.status_changed' {
                $t = [string](Get-Prop $e 'task_id')
                $to = if (Has-Prop $pl 'to') { [string]$pl.to } else { '' }
                if ($t -and $to -eq 'выполнена') { $taskDone[$t] = $e.occurred_at }
            }
        }
    }

    $critical = New-Object System.Collections.Generic.List[object]
    foreach ($t in $taskDone.Keys) {
        if ($taskCaptured.ContainsKey($t)) {
            $ms = [int]((To-Utc $taskDone[$t]) - (To-Utc $taskCaptured[$t])).TotalMilliseconds
            [void]$critical.Add([pscustomobject]@{ task_id = $t; critical_path_ms = $ms })
        }
    }

    function Stat { param($List)
        if ($List.Count -eq 0) { return [ordered]@{ n = 0; total_ms = 0; min_ms = 0; max_ms = 0; avg_ms = 0 } }
        $sum = 0; $min = [int]::MaxValue; $max = 0
        foreach ($v in $List) { $sum += $v; if ($v -lt $min) { $min = $v }; if ($v -gt $max) { $max = $v } }
        return [ordered]@{ n = $List.Count; total_ms = $sum; min_ms = $min; max_ms = $max; avg_ms = [int]($sum / $List.Count) }
    }

    $out = [ordered]@{
        total_events   = $events.Count
        type_counts    = $typeCounts
        codex_attempt  = (Stat $codexDur)
        round_durations = $roundDur
        critical_paths = $critical
    }
    if ([bool](Opt 'json' $false)) {
        Write-Output ($out | ConvertTo-Json -Depth 8 -Compress)
    } else {
        Write-Output "metrics: events=$($events.Count) codex.attempt(n=$($out.codex_attempt.n) avg_ms=$($out.codex_attempt.avg_ms)) rounds=$($roundDur.Count) critical_paths=$($critical.Count)"
    }
}

function Cmd-Version { Write-Output 'orchestra-outbox 1' }

# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------
try {
    switch ($Command) {
        'event-id' { Cmd-EventId }
        'append'   { Cmd-Append }
        'verify'   { Cmd-Verify }
        'read'     { Cmd-Read }
        'metrics'  { Cmd-Metrics }
        'version'  { Cmd-Version }
        default {
            Fail 2 "unknown command '$Command'. Valid: event-id, append, verify, read, metrics, version"
        }
    }
} catch {
    $m = [string]$_.Exception.Message
    if ($m -like 'OBXERR|*') {
        $parts = $m -split '\|', 3
        [Console]::Error.WriteLine("outbox: $($parts[2])")
        exit ([int]$parts[1])
    }
    [Console]::Error.WriteLine("outbox: $m")
    if ($env:OUTBOX_DEBUG) { [Console]::Error.WriteLine($_.ScriptStackTrace) }
    exit 1
}
