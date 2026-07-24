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
         derived from the resolved events path (`outbox-tx.lock` beside canonical
         `events.jsonl`); a forbidden parallel writer that cannot take the lock fails
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
      6   unrepairable corruption (a newline-terminated committed line is meaningfully invalid)
      7   could not acquire the outbox lock (timeout; another writer or reader holds it -
          `append`, `read`, `verify` and `metrics` all serialize on this same lock, see
          "Concurrent read vs. the writer" below)
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

# Shared infrastructure primitives (arg-parse, Fail/Opt/Require-Opt + catch dispatcher,
# crash-safe IO, CreateNew lock, UTC helpers; T-240). Dot-sourced like tools/policy-schema.ps1.
. (Join-Path $PSScriptRoot 'common.ps1')
# Shared consumer-side projection layer over events.jsonl (Has-Prop/Get-Prop, the read+dedup
# stream reader and the usage extractor; T-286). MUST load AFTER common.ps1 (Read-EventStream
# reports read failure through common.ps1's Fail). The `metrics` command reads and projects
# through this; the transactional reader Read-Outbox below stays outbox-local by design.
. (Join-Path $PSScriptRoot 'events-common.ps1')
$script:ErrPrefix = 'OBXERR'        # coded-error tag decoded by the catch dispatcher
$script:FaultEnv  = 'OUTBOX_FAULT'  # crash-injection hook read by Maybe-Fault
$script:LockName  = 'outbox'        # label in the Acquire-Lock failure message

# --------------------------------------------------------------------------
# Argument parsing:  <command> [--key value | --flag] ...
# --------------------------------------------------------------------------
$parsed = Parse-CliArgs $args -BoolFlags @('json', 'stdin')
$Command = $parsed.Command
$opts = $parsed.Opts

# Has-Prop / Get-Prop are the single canonical copy in tools/events-common.ps1 (K-048's safe
# indexer form `$Obj.PSObject.Properties[$Name]`, NOT `.Properties.Name -contains`, which
# throws under Set-StrictMode on a zero-property object such as an empty --payload '{}').

# --------------------------------------------------------------------------
# Parsed --payload, shared by Get-CanonicalName's coordinate fallback (below) and
# Build-EventLine. Parsed at most ONCE per process invocation (cached) so the
# `event-id`/`append` dedupe-key computation and the actual envelope-building step
# never validate the same --payload text twice or risk drifting apart.
# --------------------------------------------------------------------------
$script:PayloadParsed = $false
$script:PayloadCache = $null
function Get-ParsedPayload {
    if (-not $script:PayloadParsed) {
        $raw = [string](Opt 'payload' '{}')
        $p = $null
        try { $p = $raw | ConvertFrom-Json } catch { Fail 5 "--payload is not valid JSON" }
        if ($null -eq $p) { $p = [pscustomobject]@{} }
        $script:PayloadCache = $p
        $script:PayloadParsed = $true
    }
    return $script:PayloadCache
}

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
    'task.captured', 'task.status_changed', 'codex.attempt', 'usage.recorded'
)
# codex.attempt payload is a strict scalar allowlist (privacy: no prompt/diff/paths/secrets).
$script:CodexAttemptKeys = @(
    'task_id', 'role', 'mode', 'attempt_number', 'started_at', 'ended_at', 'duration_ms',
    'effective_model', 'effective_reasoning', 'effective_sandbox', 'effective_network',
    'exit_code', 'outcome', 'outcome_reason'
)
# usage.recorded payload is a strict SCALAR allowlist (T-248): per-model-call token usage,
# uniformly for both a headless `claude -p --output-format stream-json` result event and a
# `codex exec` token count. Same privacy posture as codex.attempt - no prompt/diff/paths/
# secrets, only non-sensitive integer counts, a source/role/mode label and the estimated flag.
# `estimated` marks a heuristic (never-exact) figure so a consumer never mixes it with actual
# usage (plans/OBSERVABILITY_PLATFORM_PLAN.md §8). The reader tolerates future unknown payload
# keys (it only allowlists on WRITE), so a later field never breaks an already-written line.
$script:UsageRecordedKeys = @(
    'task_id', 'role', 'mode', 'attempt_number', 'source', 'model',
    'input_tokens', 'output_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens',
    'total_tokens', 'estimated'
)
# usage.recorded token/count fields that, WHEN PRESENT and non-null, must be non-negative
# integers (a scalar-shape write guard; null = "unknown for this call", which stays allowed).
$script:UsageIntKeys = @(
    'attempt_number', 'input_tokens', 'output_tokens', 'cache_read_input_tokens',
    'cache_creation_input_tokens', 'total_tokens'
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

# A stable-key coordinate that is ALSO always present in the type's documented
# --payload (docs/queue_contract.md §19.2/19.3; agents/processor.md "Эскизы payload"):
# an explicit CLI flag, when given, always wins (kept as the priority source even if
# it disagrees with --payload - an intentional out-of-band caller is not treated as
# an error here; see docs/queue_contract.md §19.2 for the documented rationale). When
# the flag is absent, the SAME coordinate is read from --payload's field of the same
# name, with the same format validation the flag would have had - so a caller no
# longer has to duplicate a value the event's payload contract already requires as a
# separate CLI flag (T-261: "outbox: missing required option --wave" trap). Only when
# the coordinate is present in NEITHER place does this fail exactly like the old
# always-Require-Opt shape (rc=2, same class of diagnostic).
function Get-CoordFallback {
    param([string]$FlagName, [string]$PayloadField, $Payload, [string]$Pattern = $null, [string]$PatternMsg = $null)
    $val = $null
    if ($opts.ContainsKey($FlagName) -and -not [string]::IsNullOrEmpty([string]$opts[$FlagName])) {
        $val = [string]$opts[$FlagName]
    } elseif ($null -ne $Payload -and (Has-Prop $Payload $PayloadField)) {
        $pv = Get-Prop $Payload $PayloadField
        if ($null -ne $pv -and -not [string]::IsNullOrEmpty([string]$pv)) { $val = [string]$pv }
    }
    if ($null -eq $val) { Fail 2 "missing required option --$FlagName (also absent from --payload field '$PayloadField')" }
    if ($Pattern -and $val -notmatch $Pattern) { Fail 2 $PatternMsg }
    return $val
}

function Get-CanonicalName {
    param([string]$Type, $Payload = $null)
    switch -Regex ($Type) {
        '^cohort\.(opened|admission_closed|join_started|published|closed)$' {
            $b = Require-Opt 'batch-id'
            return "orchestra/$Type/$b"
        }
        '^cohort\.round_(started|closed)$' {
            $b = Require-Opt 'batch-id'
            $w = Get-CoordFallback -FlagName 'wave' -PayloadField 'wave' -Payload $Payload -Pattern '^\d+$' -PatternMsg "--wave (or --payload field 'wave') must be a non-negative integer"
            return "orchestra/$Type/$b/w$w"
        }
        '^task\.captured$' {
            $b = Require-Opt 'batch-id'
            $t = Require-Opt 'task-id'
            return "orchestra/$Type/$b/$t/a$(Get-CoordAttempt)"
        }
        '^task\.status_changed$' {
            $t = Require-Opt 'task-id'
            # --from/--to fall back to --payload's own from/to (docs/queue_contract.md §19.3:
            # "Смены статуса - это task.status_changed с from/to в payload" - the value is
            # ALWAYS documented to be there, same trap class as cohort.round_*'s --wave).
            $from = Get-CoordFallback -FlagName 'from' -PayloadField 'from' -Payload $Payload
            $to = Get-CoordFallback -FlagName 'to' -PayloadField 'to' -Payload $Payload
            return "orchestra/$Type/$t/$from>$to/a$(Get-CoordAttempt)/r$(Get-CoordRound)"
        }
        # codex.attempt / usage.recorded deliberately keep plain Require-Opt (no payload
        # fallback, T-261): task_id/role/mode/attempt_number(/source) are already carried by
        # the processor's tracked `Codex-попытка` telemetry reservation (agents/processor.md,
        # "codex.attempt: схема и идемпотентность") through a dedicated crash-safe emission
        # codepath, not a one-off free-text instruction like cohort.round_*/task.status_changed
        # - so the "forgot to duplicate the flag" trap this task fixes is materially less
        # likely here. Revisit if this assumption stops holding in practice.
        '^codex\.attempt$' {
            $t = Require-Opt 'task-id'
            $role = Require-Opt 'role'
            $mode = Require-Opt 'mode'
            $an = [string](Require-Opt 'attempt-number')
            if ($an -notmatch '^\d+$') { Fail 2 "--attempt-number must be a non-negative integer" }
            return "orchestra/$Type/$t/$role/$mode/$an"
        }
        '^usage\.recorded$' {
            # Per-model-call usage keyed by the CALL identity (T-248). `source` (claude|codex)
            # is a key coordinate so a codex attempt and its Claude fallback for the SAME
            # (task,role,mode,attempt) stay two distinct usage facts (the fallback is a separate
            # model call), rather than colliding on one event_id. All coordinates are durably
            # reconstructable (same reservation as codex.attempt for codex; the processor supplies
            # role/attempt for a Claude call), so a crash/replay rebuilds the same id and dedups.
            $src = Require-Opt 'source'
            $t = Require-Opt 'task-id'
            $role = Require-Opt 'role'
            $mode = Require-Opt 'mode'
            $an = [string](Require-Opt 'attempt-number')
            if ($an -notmatch '^\d+$') { Fail 2 "--attempt-number must be a non-negative integer" }
            return "orchestra/$Type/$src/$t/$role/$mode/$an"
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
    if ($work) { $work = [System.IO.Path]::GetFullPath($work) }
    if (-not $events) {
        if (-not $work) { Fail 2 "need --work or --events" }
        $events = Join-Path $work 'events.jsonl'
    }
    $events = [System.IO.Path]::GetFullPath($events)

    # The default lock is a function of the RESOLVED events file, never of whether the
    # caller spelled that file as `--work X` or `--events X/events.jsonl`. Otherwise an
    # append using the first spelling and a consumer using the second can enter the same
    # FileShare.None critical section through different locks. Preserve the established
    # .work/outbox-tx.lock name for canonical events.jsonl; explicit non-canonical event
    # filenames receive an unambiguous per-file companion lock.
    $eventsDir = Split-Path -Parent $events
    $eventsLeaf = Split-Path -Leaf $events
    $defaultLock = if ([string]::Equals($eventsLeaf, 'events.jsonl', [System.StringComparison]::OrdinalIgnoreCase)) {
        Join-Path $eventsDir 'outbox-tx.lock'
    } else {
        "$events.lock"
    }
    $lock = [string](Opt 'lock' $defaultLock)
    $lock = [System.IO.Path]::GetFullPath($lock)
    $lease = ''
    if ($work) { $lease = Join-Path $work 'orchestrator.lock/lease.json' }
    return [pscustomobject]@{ Work = $work; Events = $events; Lock = $lock; Lease = $lease }
}

# --------------------------------------------------------------------------
# Crash-safe IO. Read-TextOrEmpty / Write-TextAtomic / Maybe-Fault, the short
# serialization lock (Acquire-Lock / Release-Lock) and the time helpers (Format-UtcNow /
# Parse-Utc) come from tools/common.ps1 (T-240); Read-BytesOrEmpty is outbox-specific (the
# durable outbox is byte-addressed for torn-tail repair). Maybe-Fault reads $script:FaultEnv
# (OUTBOX_FAULT set above); the shared Write-TextAtomic only faults on the before/after-rename
# stages, which outbox never injects (its OUTBOX_FAULT stages are before-open/-write/-flush).
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
    if ([string]::IsNullOrWhiteSpace($Text)) {
        # A committed blank separator is ignorable to the writer's corruption gate.
        # Readers retain their historical skipped_invalid accounting for such lines.
        if ($Mode -eq 'write') { return [pscustomobject]@{ Obj = $null; Valid = $true; Error = $null } }
        return [pscustomobject]@{ Obj = $null; Valid = $false; Error = 'empty line' }
    }
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
        if ([string]$Obj.type -eq 'usage.recorded') {
            foreach ($k in $payload.PSObject.Properties.Name) {
                if ($script:UsageRecordedKeys -notcontains $k) { return "usage.recorded payload key '$k' is not in the privacy allowlist" }
            }
            # Scalar-shape guard: token/count fields, when present and non-null, are non-negative
            # integers; `estimated`, when present, is a boolean. This keeps the allowlist strictly
            # scalar (no nested object smuggled through a token field) without rejecting a null
            # ("unknown for this call") value.
            foreach ($k in $script:UsageIntKeys) {
                if (Has-Prop $payload $k) {
                    $val = $payload.$k
                    if ($null -ne $val -and ([string]$val -notmatch '^\d+$')) { return "usage.recorded payload key '$k' must be a non-negative integer or null" }
                }
            }
            if (Has-Prop $payload 'estimated') {
                $est = $payload.estimated
                if ($null -ne $est -and $est -isnot [bool]) { return "usage.recorded payload key 'estimated' must be a boolean" }
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

# NB: the `metrics` command projects over the deduplicated CONSUMER stream via the shared
# Read-EventStream (tools/events-common.ps1), not over Read-Outbox's transactional record
# model, so the old outbox-local Get-DedupedEvents is gone (both events.jsonl projections now
# dedup in one place). Read-Outbox above stays for the writer-side paths (verify/read/append).

# --------------------------------------------------------------------------
# Concurrent read vs. the writer (T-294). Cmd-Append opens events.jsonl with
# [System.IO.FileShare]::None for its whole write critical section (the file is EXCLUSIVE
# while open: Windows sharing is governed by the FIRST opener's granted share mode, so a
# reader that merely requests a more permissive share - e.g. FileShare.ReadWrite, as
# tools/events-common.ps1::Read-EventStream does - still fails with IOException while that
# handle is open; changing only the reader's requested share cannot close this race).
#
# The chosen fix is therefore lock-based, not share-based: `read`, `verify` and `metrics`
# below each take the SAME outbox lock (Paths.Lock, canonically derived from the resolved
# events path regardless of `--work`/`--events` spelling, Acquire-Lock/
# Release-Lock, shared with Cmd-Append) for their entire read. Cmd-Append already holds
# this lock for its ENTIRE critical section, including the FileShare.None open/write/flush/
# dispose - so a reader that holds the same lock is GUARANTEED to never attempt to open
# events.jsonl while a write is in flight; it simply waits (bounded by its own
# --lock-timeout-ms, default 30000 like `append`) and reads only once the writer has
# released. This is airtight (proven by construction, not by a share-flag combination),
# unlike option (a). A genuinely unreadable file (missing/corrupt outside any writer
# window, e.g. permission-denied) still surfaces as Fail 3 from Read-BytesOrEmpty/
# Read-EventStream, unmasked by this change - only the "writer is mid-flight" IOException is
# eliminated.
#
# Cursor-file concurrency (Cmd-Read, `--cursor`): because Cmd-Read now holds this SAME lock
# across its ENTIRE body (cursor read -> outbox read -> Write-TextAtomic cursor write-back),
# concurrent `read` invocations - whether against the same or a different --cursor path, and
# whether concurrent with each other or with an `append` - are fully serialized by this one
# lock. The cursor's read-modify-write is therefore atomic relative to any other cursor
# advance: two overlapping `read --cursor X` calls can never interleave (one always
# completes, including its Write-TextAtomic rename, before the other even opens the cursor
# file), so there is no lost-update window on byte_offset/delivered_ids. This is an explicit
# design choice (not merely Write-TextAtomic's own rename-atomicity, which only makes ONE
# write atomic, not a concurrent read+advance sequence) - do not remove the lock from
# Cmd-Read without re-establishing an equivalent guarantee.
# --------------------------------------------------------------------------

# Acquire through the shared primitive. The optional test signal is deliberately emitted
# only after an atomic CreateNew probe has ACTUALLY observed the target lock as contended;
# tests use it to prove a reader reached the blocked state before releasing a simulated
# writer's FileShare.None hold. Normal invocations do not set this environment variable and
# take the production path directly.
function Acquire-OutboxLock {
    param([string]$LockPath, [int]$TimeoutMs)
    $waitSignal = [Environment]::GetEnvironmentVariable('OUTBOX_TEST_LOCK_WAIT_SIGNAL')
    if ($waitSignal) {
        $probe = $null
        try {
            $probe = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        } catch [System.IO.IOException] {
            $signalDir = Split-Path -Parent $waitSignal
            if ($signalDir -and -not (Test-Path -LiteralPath $signalDir)) {
                [void][System.IO.Directory]::CreateDirectory($signalDir)
            }
            [System.IO.File]::WriteAllText($waitSignal, 'contended', (New-Object System.Text.UTF8Encoding($false)))
        } finally {
            if ($null -ne $probe) {
                $probe.Dispose()
                Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Acquire-Lock $LockPath $TimeoutMs
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
    # Get-ParsedPayload defaults to {} when --payload is absent, so a caller that never
    # relies on the payload fallback (no --payload given) behaves exactly as before.
    $name = Get-CanonicalName $type (Get-ParsedPayload)
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
    # Same parsed/cached payload the event-id computation below (Cmd-Append) already used
    # for its coordinate fallback - parsed exactly once per invocation (Get-ParsedPayload).
    $payload = Get-ParsedPayload

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
        if ($line -match "[\r\n]") { Fail 5 "serialized event contains a newline (payload has a raw control char)" }
    } else {
        if ($opts.ContainsKey('event-id') -and $opts['event-id']) { $eid = [string]$opts['event-id'] }
        else { $eid = New-UuidV5 (Get-CanonicalName (Require-Opt 'type') (Get-ParsedPayload)) }
        $line = Build-EventLine $eid
    }

    # write-mode validation of the exact bytes we intend to append.
    $chk = Test-EventText $line 'write'
    if (-not $chk.Valid -or $null -eq $chk.Obj) {
        $reason = if ($chk.Error) { $chk.Error } else { 'empty line' }
        Fail 5 "refusing to append an invalid event: $reason"
    }
    $eid = [string]$chk.Obj.event_id

    $timeout = [int](Opt 'lock-timeout-ms' 30000)
    Acquire-OutboxLock $paths.Lock $timeout
    try {
        $ob = Read-Outbox $paths.Events 'read'
        # A meaningfully invalid newline-terminated committed line is unrepairable
        # corruption (append repairs only the trailing unterminated fragment). Blank
        # separator lines are valid in write mode and therefore do not block appends.
        foreach ($r in $ob.Records) {
            if (-not $r.Valid -and -not $r.Unterminated) {
                $writeCheck = Test-EventText $r.Text 'write'
                if (-not $writeCheck.Valid) { Fail 6 "a committed line is invalid ($($r.Error)); refuse to append over corruption (run 'verify')" }
            }
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
    # Take the SAME outbox lock Cmd-Append holds for its whole write ("Concurrent read vs.
    # the writer" above): guarantees this read never races the writer's FileShare.None
    # window, instead of merely hoping a share-flag combination happens to be compatible.
    $timeout = [int](Opt 'lock-timeout-ms' 30000)
    Acquire-OutboxLock $paths.Lock $timeout
    try {
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
        # A meaningfully invalid newline-terminated line is hard corruption; blank separator
        # lines remain skipped-invalid diagnostics and do not make verification blocking.
        $hardBad = @($ob.Records | Where-Object { -not $_.Valid -and -not $_.Unterminated -and -not [string]::IsNullOrWhiteSpace($_.Text) })
        if ($hardBad.Count -gt 0) { exit 6 }
        if ($dups.Count -gt 0) { exit 4 }
    } finally { Release-Lock $paths.Lock }
}

# ==========================================================================
# read : reference consumer/cursor. Dedup by event_id; optional durable cursor.
# ==========================================================================
function Cmd-Read {
    $paths = Resolve-Paths
    # Take the SAME outbox lock Cmd-Append holds for its whole write, for this command's
    # ENTIRE body (cursor read through cursor write-back) - see "Concurrent read vs. the
    # writer" above for why this is what actually closes the race, and why it is also what
    # makes a concurrent cursor read-modify-write safe (no lost update between two
    # overlapping `read --cursor` calls).
    $timeout = [int](Opt 'lock-timeout-ms' 30000)
    Acquire-OutboxLock $paths.Lock $timeout
    try {
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
    } finally { Release-Lock $paths.Lock }
}

# ==========================================================================
# metrics : phase / critical-path duration projection over the deduped stream, plus a
# usage.recorded token projection (T-248). All figures are timestamps / integer durations /
# integer token counts only - no sensitive payload data. ACTUAL and ESTIMATED usage are
# reported in separate buckets and never summed together (OBSERVABILITY_PLATFORM_PLAN §8).
# The stream read+dedup and the per-event usage figure both come from the shared consumer
# layer (tools/events-common.ps1), the same one metrics.ps1 aggregate uses (T-286).
# ==========================================================================
function Cmd-Metrics {
    $paths = Resolve-Paths
    # Same outbox lock as Cmd-Append/Cmd-Verify/Cmd-Read ("Concurrent read vs. the writer"
    # above): Read-EventStream (tools/events-common.ps1) itself already opens with
    # FileShare.ReadWrite, but that alone cannot survive the writer's FileShare.None window
    # (the FIRST opener's share governs); the lock is what actually closes the race.
    $timeout = [int](Opt 'lock-timeout-ms' 30000)
    Acquire-OutboxLock $paths.Lock $timeout
    try {
        $stream = Read-EventStream $paths.Events
        $events = $stream.Events

        $typeCounts = [ordered]@{}
        foreach ($t in $script:KnownTypes) { $typeCounts[$t] = 0 }
        $codexDur = New-Object System.Collections.Generic.List[int]
        $roundStart = @{}   # "batch|wave" -> occurred_at
        $roundDur = New-Object System.Collections.Generic.List[object]
        $taskCaptured = @{} # task_id -> earliest occurred_at
        $taskDone = @{}     # task_id -> occurred_at of status_changed to выполнена
        # usage.recorded aggregation (T-248). ACTUAL and ESTIMATED are summed into SEPARATE buckets
        # and never merged into one figure (plans/OBSERVABILITY_PLATFORM_PLAN.md §8): a heuristic
        # estimate must never be presented as, or added to, a provider-exact count.
        $usageActual = [ordered]@{ n = 0; input_tokens = 0; output_tokens = 0; cache_read_input_tokens = 0; cache_creation_input_tokens = 0; total_tokens = 0 }
        $usageEstimated = [ordered]@{ n = 0; total_tokens = 0 }
        $usageBySource = @{}   # source -> @{ actual_total_tokens; estimated_total_tokens; n }

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
                'usage.recorded' {
                    # Single shared usage interpretation (tools/events-common.ps1 Get-EventUsage):
                    # the total-tokens rule and the estimated/actual split, identical to metrics.ps1.
                    # Cast to [int] to keep this projection's integer token contract (an outbox
                    # usage.recorded token field is a validated non-negative integer on write).
                    $u = Get-EventUsage $e
                    $tot = if ($null -ne $u.Total) { [int]$u.Total } else { 0 }
                    $src = $u.Source
                    if (-not $usageBySource.ContainsKey($src)) { $usageBySource[$src] = [ordered]@{ actual_total_tokens = 0; estimated_total_tokens = 0; n = 0 } }
                    $usageBySource[$src].n = $usageBySource[$src].n + 1
                    if ($u.Estimated) {
                        $usageEstimated.n = $usageEstimated.n + 1
                        $usageEstimated.total_tokens = $usageEstimated.total_tokens + $tot
                        $usageBySource[$src].estimated_total_tokens = $usageBySource[$src].estimated_total_tokens + $tot
                    } else {
                        $usageActual.n = $usageActual.n + 1
                        $usageActual.input_tokens = $usageActual.input_tokens + [int]$u.InputTokens
                        $usageActual.output_tokens = $usageActual.output_tokens + [int]$u.OutputTokens
                        $usageActual.cache_read_input_tokens = $usageActual.cache_read_input_tokens + [int]$u.CacheReadTokens
                        $usageActual.cache_creation_input_tokens = $usageActual.cache_creation_input_tokens + [int]$u.CacheCreationTokens
                        $usageActual.total_tokens = $usageActual.total_tokens + $tot
                        $usageBySource[$src].actual_total_tokens = $usageBySource[$src].actual_total_tokens + $tot
                    }
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

        $usage = [ordered]@{
            actual    = $usageActual
            estimated = $usageEstimated
            by_source = $usageBySource
        }

        $out = [ordered]@{
            total_events   = $events.Count
            type_counts    = $typeCounts
            codex_attempt  = (Stat $codexDur)
            round_durations = $roundDur
            critical_paths = $critical
            usage          = $usage
        }
        if ([bool](Opt 'json' $false)) {
            Write-Output ($out | ConvertTo-Json -Depth 8 -Compress)
        } else {
            Write-Output "metrics: events=$($events.Count) codex.attempt(n=$($out.codex_attempt.n) avg_ms=$($out.codex_attempt.avg_ms)) rounds=$($roundDur.Count) critical_paths=$($critical.Count) usage(actual_tokens=$($usageActual.total_tokens) n=$($usageActual.n); estimated_tokens=$($usageEstimated.total_tokens) n=$($usageEstimated.n))"
        }
    } finally { Release-Lock $paths.Lock }
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
    exit (Resolve-CatchExit $_ 'OBXERR' 'outbox' 'OUTBOX_DEBUG')
}
