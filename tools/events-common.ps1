<#
.SYNOPSIS
    The shared consumer-side projection layer over Orchestra's observability event stream
    `.work/events.jsonl` (task T-286). Dot-sourced by tools/outbox.ps1 (the `metrics`
    command) and tools/metrics.ps1 (the `aggregate` command).

.DESCRIPTION
    `.work/events.jsonl` had TWO independent readers of the same append-only stream, drifting
    apart in their details:

      * tools/outbox.ps1 read it byte-addressed (`Read-Outbox`) and deduped valid records by
        event_id (`Get-DedupedEvents`) for its `metrics` projection;
      * tools/metrics.ps1 read it with its OWN streaming byte reader (`Read-EventStream`) and
        its OWN inline dedup for `aggregate`.

    Both `Has-Prop`/`Get-Prop` (K-048's safe indexer form) and the usage-aggregation core
    (the total-tokens rule and the estimated-vs-actual split) were duplicated too, again with
    subtle divergences (nested `token_usage`/`usage` objects and `cost_*` keys recognised by
    metrics only; the flat-component fallback present in outbox only).

    This module is the single home for that CONSUMER-side "read the stream, dedup by event_id,
    project a usage figure" concern. Both `outbox.ps1 metrics` and `metrics.ps1 aggregate` now
    read events THROUGH `Read-EventStream` here and derive every usage figure through the one
    `Get-EventUsage` here, so the two commands can no longer disagree on the semantics that
    task T-286 called out.

    Scope boundary (deliberate): tools/outbox.ps1's TRANSACTIONAL reader `Read-Outbox` -
    byte-span line model, strict envelope validation, torn-tail repair and the durable read
    cursor - stays in outbox.ps1. That is the WRITER-side / cursor concern (append integrity,
    `verify`, `read`), not the projection stream this module owns; it is genuinely separate,
    not a third copy of the same thing.

    This is a LIBRARY: it only defines functions and performs no top-level action, so it is
    safe to dot-source (`. tools/events-common.ps1`), following the tools/policy-schema.ps1 /
    tools/common.ps1 precedent. It must be dot-sourced AFTER tools/common.ps1, because
    `Read-EventStream` reports an unreadable stream through common.ps1's `Fail` (which resolves
    the sourcing tool's `$script:ErrPrefix`); both callers already load common.ps1 first.

.NOTES
    Runs under PowerShell 7 (pwsh) and Windows PowerShell 5.1.
#>

Set-StrictMode -Version Latest

# --------------------------------------------------------------------------
# Property helpers - the single canonical copy (was independently duplicated in
# tools/outbox.ps1 and tools/metrics.ps1). K-048: under Set-StrictMode -Version Latest,
# `$Obj.PSObject.Properties.Name -contains $Name` throws InvalidOperation when $Obj has
# ZERO properties (e.g. an empty `--payload '{}'`), because `.Name`/`.Count` on the empty
# PSMemberInfoCollection itself throws - NOT because the target property is absent. The safe
# form is the indexer `$Obj.PSObject.Properties[$Name]`, which returns $null cleanly either
# way. Keep this indexer form; a regression to the `.Name -contains` shape reopens K-048.
# --------------------------------------------------------------------------
function Has-Prop {
    param($Obj, [string]$Name)
    return ($null -ne $Obj -and $null -ne $Obj.PSObject.Properties[$Name])
}
function Get-Prop {
    param($Obj, [string]$Name)
    if (Has-Prop $Obj $Name) { return $Obj.$Name } else { return $null }
}
# First of $Names whose value is present and non-blank (used by the metrics projection to
# accept a field under any of several historical spellings).
function Get-FirstProp {
    param($Object, [string[]]$Names)
    foreach ($name in $Names) {
        if (Has-Prop $Object $name) {
            $value = $Object.$name
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) { return $value }
        }
    }
    return $null
}

# --------------------------------------------------------------------------
# Scalar coercions used across the projection. To-Number is a NON-NEGATIVE invariant-culture
# float parse (a negative or unparseable value is "unknown", i.e. $null); To-Time parses an
# ISO-8601 / offset timestamp as UTC (AssumeUniversal, so an offset-less string is read as
# UTC, never as host-local), returning $null when unparseable.
# --------------------------------------------------------------------------
function To-Number {
    param($Value)
    if ($null -eq $Value) { return $null }
    $number = 0.0
    if ([double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -and $number -ge 0) { return $number }
    return $null
}
function To-Time {
    param($Value)
    if ($null -eq $Value) { return $null }
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return $parsed.ToUniversalTime() }
    return $null
}

# --------------------------------------------------------------------------
# Read + dedup of the projection stream. Streams the file in 64 KiB chunks, splits on LF,
# strictly UTF-8 decodes each line (an undecodable line is counted invalid, not silently
# replaced), skips blank separators, JSON-parses, and keeps only objects that carry the two
# fields every projection needs (`type` and a parseable `occurred_at`). Like the durable
# outbox reader it NEVER consumes an unterminated final record (a torn tail is counted
# invalid). Finally it deduplicates by event_id, first occurrence wins; an object with no
# event_id cannot collide and is always kept.
#
# This is intentionally LENIENT (no envelope schema validation): the consumer stream carries
# a broader, more historical vocabulary than outbox.ps1's strict WRITE allowlist - e.g. the
# `run.interrupted` / `recovery.*` types metrics.ps1 projects, and pre-T-248 usage shapes -
# which a strict envelope check would wrongly drop. Returns @{ Events; Invalid; Present }.
# --------------------------------------------------------------------------
function Read-EventStream {
    param([string]$Path)
    $events = New-Object Collections.Generic.List[object]
    $invalid = 0
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]@{ Events=$events; Invalid=0; Present=$false } }
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $lineBytes = New-Object Collections.Generic.List[byte]
        $decoder = New-Object Text.UTF8Encoding($false, $true)
        $buffer = New-Object 'byte[]' 65536
        try {
            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                for ($offset = 0; $offset -lt $read; $offset++) {
                    $byte = $buffer[$offset]
                    if ($byte -ne 10) { $lineBytes.Add($byte); continue }
                    try { $line = $decoder.GetString($lineBytes.ToArray()).TrimEnd("`r") } catch { $invalid++; $lineBytes.Clear(); continue }
                    $lineBytes.Clear()
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    try { $event = $line | ConvertFrom-Json } catch { $invalid++; continue }
                    if ($null -eq $event -or -not (Has-Prop $event 'type') -or $null -eq (To-Time (Get-Prop $event 'occurred_at'))) { $invalid++; continue }
                    [void]$events.Add($event)
                }
            }
            # Like the engine tail reader, never consume an unterminated final record.
            if ($lineBytes.Count -gt 0) { $invalid++ }
        } finally { $stream.Dispose() }
    } catch { Fail 3 "cannot read $Path ($($_.Exception.Message))" }
    $seen = New-Object 'Collections.Generic.HashSet[string]'
    $deduped = New-Object Collections.Generic.List[object]
    foreach ($event in $events) {
        $id = [string](Get-Prop $event 'event_id')
        if ($id -and -not $seen.Add($id)) { continue }
        [void]$deduped.Add($event)
    }
    return [pscustomobject]@{ Events=$deduped; Invalid=$invalid; Present=$true }
}

# --------------------------------------------------------------------------
# Unified usage extraction from ONE event. This is the single canonical interpretation of a
# usage figure shared by `outbox.ps1 metrics` and `metrics.ps1 aggregate` (task T-286).
# Returns a record:
#   Total      : [double] or $null - the call's token total, or $null when the event carries
#                no usage signal at all (so a projection skips non-usage events).
#   Estimated  : [bool]  - payload.estimated -eq $true. An estimate is a heuristic, never a
#                provider-exact figure, so a caller routes it to a SEPARATE bucket and never
#                sums it into an actual-token total (plans/OBSERVABILITY_PLATFORM_PLAN.md §8).
#                This estimated/actual split is uniform for BOTH commands.
#   Source     : [string] - payload.source, or 'unknown'.
#   Cost       : [double] or $null - cost_usd | usd_cost | total_cost_usd (payload, then top-level).
#   Input/Output/CacheRead/CacheCreation Tokens : [double] - the flat top-level component
#                counts (0 when absent); consumed only by outbox's per-component breakdown.
#
# Total rule (single source of truth, replacing the two prior divergent copies):
#   1. an explicit total field wins: total_tokens | tokens | token_count (payload, then top-level);
#   2. else, if payload carries a nested usage object (token_usage | usage): that object's
#      total_tokens|tokens|total, else the sum of its input/output/cache_* components;
#   3. else, the sum of the flat top-level input/output/cache_* components, when any is present.
# So an explicit total always wins over a components sum (was outbox's rule), and a
# components-only figure is still credited (step 3 - previously metrics required a nested
# object for that; unifying here credits flat-component usage for BOTH commands. This is a
# deliberate consistency extension, not a silent drift: it changes no golden-fixture output -
# every usage fixture carries either an explicit total or a nested object - and only affects
# an event that has flat top-level token components with neither an explicit nor a nested
# total, a shape no current writer emits).
#
# WHY the nested-object / tokens-alias / cost_* branches read as outbox-inert: outbox.ps1's
# `usage.recorded` payload allowlist ($UsageRecordedKeys) is FLAT-SCALAR-ONLY - it rejects on
# WRITE any nested token_usage/usage object, the tokens/token_count aliases and every cost_*
# key - so for an outbox-written event only steps 1 and 3 are ever reachable and Cost is
# always $null. Those extra branches exist for metrics.ps1, which additionally reads the
# broader pre-T-248 / journal-adjacent vocabulary that predates that strict allowlist (its
# own tests feed a nested `token_usage` usage.recorded line). Keeping them in the ONE shared
# extractor - rather than as a metrics-only variant - is what makes the two commands share a
# single usage semantics; on the outbox side they are simply never exercised.
# --------------------------------------------------------------------------
function Get-EventUsage {
    param($Event)
    $payload = Get-Prop $Event 'payload'
    $flatNames = @('input_tokens', 'output_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens')

    # Step 1: an explicit total (payload first, then top-level - matches the historical
    # metrics `Get-EventNumber` lookup order).
    $rawTotal = Get-FirstProp $payload @('total_tokens', 'tokens', 'token_count')
    if ($null -eq $rawTotal) { $rawTotal = Get-FirstProp $Event @('total_tokens', 'tokens', 'token_count') }
    $total = To-Number $rawTotal

    # Step 2: a nested usage object (metrics' broader shape; never present on an outbox event).
    $nested = Get-FirstProp $payload @('token_usage', 'usage')
    if ($null -eq $total -and $null -ne $nested -and $nested -isnot [string]) {
        $nestedTotal = To-Number (Get-FirstProp $nested @('total_tokens', 'tokens', 'total'))
        if ($null -ne $nestedTotal) {
            $total = $nestedTotal
        } else {
            $sum = 0.0; $found = $false
            foreach ($name in $flatNames) {
                $n = To-Number (Get-Prop $nested $name)
                if ($null -ne $n) { $sum += $n; $found = $true }
            }
            if ($found) { $total = $sum }
        }
    }

    # Flat top-level components: outbox's per-component breakdown AND the step-3 fallback total.
    $comp = @{}
    $flatSum = 0.0; $flatFound = $false
    foreach ($name in $flatNames) {
        $n = To-Number (Get-Prop $payload $name)
        if ($null -ne $n) { $comp[$name] = $n; $flatSum += $n; $flatFound = $true } else { $comp[$name] = 0.0 }
    }
    if ($null -eq $total -and $flatFound) { $total = $flatSum }

    # Cost (payload first, then top-level) - metrics only; outbox events never carry a cost_* key.
    $rawCost = Get-FirstProp $payload @('cost_usd', 'usd_cost', 'total_cost_usd')
    if ($null -eq $rawCost) { $rawCost = Get-FirstProp $Event @('cost_usd', 'usd_cost', 'total_cost_usd') }
    $cost = To-Number $rawCost

    $source = if (Has-Prop $payload 'source') { [string]$payload.source } else { 'unknown' }
    $estimated = ((Get-Prop $payload 'estimated') -eq $true)

    return [pscustomobject]@{
        Total               = $total
        Estimated           = $estimated
        Source              = $source
        Cost                = $cost
        InputTokens         = $comp['input_tokens']
        OutputTokens        = $comp['output_tokens']
        CacheReadTokens     = $comp['cache_read_input_tokens']
        CacheCreationTokens = $comp['cache_creation_input_tokens']
    }
}
