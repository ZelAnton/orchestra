<#
.SYNOPSIS
    Deterministic, offline tests (T-286) for the shared consumer-side projection layer
    tools/events-common.ps1 over `.work/events.jsonl`.

.DESCRIPTION
    tools/events-common.ps1 is the single home for what tools/outbox.ps1's `metrics` command
    and tools/metrics.ps1's `aggregate` command both do to the event stream: the safe
    property helpers (K-048), the stream read + event_id dedup (Read-EventStream) and the one
    canonical usage interpretation (Get-EventUsage - the total-tokens rule and the
    estimated/actual split). Two halves:

      * Unit: the module is dot-sourced and its functions are exercised directly - the K-048
        zero-property guard, the Get-EventUsage total rule (explicit total wins; flat
        component sum; nested token_usage; estimated routing; source default; cost), and the
        Read-EventStream dedup / torn-tail accounting.
      * Cross-command: ONE shared events.jsonl (written through the real outbox.ps1) is
        projected by BOTH real CLIs, asserting they now agree on the shared usage semantics -
        the consistency this task exists to guarantee.

    Nothing here touches this repository's own .work/ and nothing reaches the network.

.EXAMPLE
    pwsh -File tests/test-events-common.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:Outbox = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\outbox.ps1')).Path
$script:Metrics = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\metrics.ps1')).Path
$script:PsExe = ([System.Diagnostics.Process]::GetCurrentProcess()).MainModule.FileName
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:TempDirs = [System.Collections.Generic.List[string]]::new()

function Assert-True { param([bool]$Cond, [string]$Msg) if (-not $Cond) { $script:Failures.Add("FAIL - $Msg") } }
function Assert-Equal { param($Expected, $Actual, [string]$Msg) if ($Expected -ne $Actual) { $script:Failures.Add("FAIL - ${Msg}: expected [$Expected], got [$Actual]") } }
function Assert-Exit { param($R, [int]$Code, [string]$Msg) if ($R.ExitCode -ne $Code) { $script:Failures.Add("FAIL - ${Msg}: expected exit $Code, got $($R.ExitCode) (err=[$($R.Err.Trim())])") } }

function New-TempDir {
    $d = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'evc-t-' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($d)
    $script:TempDirs.Add($d)
    return $d
}
function Write-File { param([string]$Path, [string]$Text) [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8) }
function Append-Raw { param([string]$Path, [string]$Text) $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write); try { $b = $script:Utf8.GetBytes($Text); $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() } }

# Runs a tool (outbox.ps1 / metrics.ps1) as a child pwsh process; args pass verbatim.
function Invoke-Tool {
    param([string]$Tool, [string[]]$ToolArgs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:PsExe
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8
    $psi.StandardErrorEncoding = $script:Utf8
    foreach ($a in (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Tool) + $ToolArgs)) { $psi.ArgumentList.Add($a) }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outT = $proc.StandardOutput.ReadToEndAsync()
    $errT = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Out = $outT.Result; Err = $errT.Result }
}

# =============================================================================
# Unit tests: dot-source the shared layer and exercise its functions directly.
# common.ps1 first (Read-EventStream reports a read failure through its Fail).
# =============================================================================
. (Join-Path $script:Root 'tools/common.ps1')
. (Join-Path $script:Root 'tools/events-common.ps1')
$script:ErrPrefix = 'EVCOMMONTEST'

function From-Json { param([string]$Json) return ($Json | ConvertFrom-Json) }

# --- K-048: Has-Prop on a zero-property object must not throw and returns $false. ---
{
    $empty = From-Json '{}'
    $threw = $false; $result = $true
    try { $result = Has-Prop $empty 'anything' } catch { $threw = $true }
    Assert-True (-not $threw) 'Has-Prop on a zero-property object does not throw (K-048 safe indexer)'
    Assert-True (-not $result) 'Has-Prop on a zero-property object returns $false'
    Assert-True ($null -eq (Get-Prop $empty 'anything')) 'Get-Prop on a zero-property object returns $null'
}.Invoke()

# --- Get-EventUsage: the single canonical total rule + split. ---
{
    # 1. an explicit total wins over the flat component sum.
    $u = Get-EventUsage (From-Json '{"payload":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":300,"total_tokens":1950}}')
    Assert-Equal 1950 $u.Total 'explicit total_tokens wins over the component sum'
    Assert-Equal 1000 $u.InputTokens 'flat input component exposed for the per-component breakdown'
    Assert-Equal 500 $u.OutputTokens 'flat output component exposed'
    Assert-Equal 300 $u.CacheReadTokens 'flat cache-read component exposed'
    Assert-True (-not $u.Estimated) 'no estimated flag => actual'
    Assert-Equal 'unknown' $u.Source 'source defaults to unknown when absent'

    # 2. flat top-level components sum when there is no explicit or nested total (unified rule).
    $u2 = Get-EventUsage (From-Json '{"payload":{"input_tokens":100,"output_tokens":50}}')
    Assert-Equal 150 $u2.Total 'flat component sum credited when no explicit/nested total (unified rule)'

    # 3. a nested token_usage object is summed (metrics' broader shape).
    $u3 = Get-EventUsage (From-Json '{"payload":{"token_usage":{"input_tokens":700,"output_tokens":500}}}')
    Assert-Equal 1200 $u3.Total 'nested token_usage components summed'

    # 4. estimated is detected and the source is read from the payload.
    $u4 = Get-EventUsage (From-Json '{"payload":{"source":"claude","total_tokens":800,"estimated":true}}')
    Assert-True $u4.Estimated 'estimated flag detected'
    Assert-Equal 800 $u4.Total 'estimated total read'
    Assert-Equal 'claude' $u4.Source 'source read from payload'

    # 5. cost is extracted from any of the cost_* spellings.
    $u5 = Get-EventUsage (From-Json '{"payload":{"total_cost_usd":0.42,"source":"codex"}}')
    Assert-Equal 0.42 $u5.Cost 'total_cost_usd extracted as cost'

    # 6. a non-usage event yields a null total (a projection skips it, crediting nothing).
    $u6 = Get-EventUsage (From-Json '{"payload":{"from":"в работе","to":"на ревью"}}')
    Assert-True ($null -eq $u6.Total) 'a non-usage event yields a null total'
    Assert-True ($null -eq $u6.Cost) 'a non-usage event yields a null cost'
}.Invoke()

# --- Read-EventStream: dedup by event_id, torn-tail counted invalid, non-object skipped. ---
{
    $dir = New-TempDir; $ev = Join-Path $dir 'events.jsonl'
    $e1 = '{"schema_version":1,"event_id":"a1","occurred_at":"2026-07-20T10:00:00Z","type":"cohort.opened","batch_id":"B-1","actor":{"kind":"tool","name":"fixture"},"payload":{}}'
    $e2 = '{"schema_version":1,"event_id":"a2","occurred_at":"2026-07-20T10:00:01Z","type":"cohort.closed","batch_id":"B-1","actor":{"kind":"tool","name":"fixture"},"payload":{}}'
    Write-File $ev ($e1 + "`n" + $e2 + "`n" + $e1 + "`n")   # a1 appears twice -> deduped to one
    Append-Raw $ev '{"schema_version":1,"event_id":"torn"'   # unterminated torn fragment
    $stream = Read-EventStream $ev
    Assert-Equal 2 $stream.Events.Count 'Read-EventStream dedups by event_id (2 unique of 3 committed lines)'
    Assert-Equal 1 $stream.Invalid 'the unterminated torn fragment is counted invalid'
    Assert-True $stream.Present 'the present flag is set for an existing stream'

    $missing = Read-EventStream (Join-Path $dir 'nope.jsonl')
    Assert-Equal 0 $missing.Events.Count 'a missing stream yields no events'
    Assert-True (-not $missing.Present) 'a missing stream reports Present=$false'
}.Invoke()

# =============================================================================
# Cross-command consistency: one shared events.jsonl, projected by BOTH real CLIs.
# One completed task carrying one ACTUAL (1500) and one ESTIMATED (800) usage.recorded,
# so metrics.ps1's per-completed-task token figure equals the raw actual sum and can be
# compared directly to outbox.ps1's usage bucket totals.
# =============================================================================
{
    $dir = New-TempDir; $ev = Join-Path $dir 'events.jsonl'
    $setup = @(
        @('append', '--events', $ev, '--batch-id', 'B-1', '--task-id', 'T-1', '--type', 'task.captured', '--attempt', '1', '--occurred-at', '2026-07-20T10:00:00.000Z', '--payload', '{"level":"coder"}'),
        @('append', '--events', $ev, '--batch-id', 'B-1', '--task-id', 'T-1', '--type', 'usage.recorded', '--source', 'codex', '--role', 'coder', '--mode', 'full', '--attempt-number', '1', '--payload', '{"source":"codex","input_tokens":1000,"output_tokens":500,"total_tokens":1500,"estimated":false}'),
        @('append', '--events', $ev, '--batch-id', 'B-1', '--task-id', 'T-1', '--type', 'usage.recorded', '--source', 'claude', '--role', 'coder', '--mode', 'full', '--attempt-number', '1', '--payload', '{"source":"claude","total_tokens":800,"estimated":true}'),
        @('append', '--events', $ev, '--task-id', 'T-1', '--type', 'task.status_changed', '--from', 'на ревью', '--to', 'выполнена', '--attempt', '1', '--round', '1', '--occurred-at', '2026-07-20T11:00:00.000Z', '--payload', '{"from":"на ревью","to":"выполнена"}'),
        @('append', '--events', $ev, '--batch-id', 'B-1', '--type', 'cohort.closed', '--occurred-at', '2026-07-20T12:00:00.000Z', '--payload', '{}')
    )
    $ok = $true
    foreach ($s in $setup) { $r = Invoke-Tool $script:Outbox $s; if ($r.ExitCode -ne 0) { $ok = $false; $script:Failures.Add("FAIL - cross-command fixture append [$($s[5])] exit $($r.ExitCode) err=[$($r.Err.Trim())]") } }

    if ($ok) {
        $om = Invoke-Tool $script:Outbox @('metrics', '--events', $ev, '--json')
        Assert-Exit $om 0 'outbox.ps1 metrics runs on the shared fixture'
        $od = $om.Out | ConvertFrom-Json

        $mm = Invoke-Tool $script:Metrics @('aggregate', '--work', $dir, '--last', '1', '--json')
        Assert-Exit $mm 0 'metrics.ps1 aggregate runs on the shared fixture'
        $md = $mm.Out | ConvertFrom-Json

        # outbox's own buckets (via the shared Get-EventUsage).
        Assert-Equal 1500 $od.usage.actual.total_tokens 'outbox metrics: ACTUAL total via the shared usage layer'
        Assert-Equal 1000 $od.usage.actual.input_tokens 'outbox metrics: ACTUAL input component via the shared usage layer'
        Assert-Equal 800 $od.usage.estimated.total_tokens 'outbox metrics: ESTIMATED total in its own bucket'
        Assert-Equal 1500 $od.usage.by_source.codex.actual_total_tokens 'outbox metrics: ACTUAL usage split by source'
        Assert-Equal 800 $od.usage.by_source.claude.estimated_total_tokens 'outbox metrics: ESTIMATED usage split by source'

        # metrics.ps1 completed exactly one task, so its per-task token figure equals the raw sum.
        Assert-Equal 1 $md.cost_per_completed_task.completed_tasks 'metrics.ps1 sees exactly one completed task'

        # THE consistency guarantee: both commands agree on ACTUAL and ESTIMATED tokens.
        Assert-Equal $od.usage.actual.total_tokens $md.cost_per_completed_task.tokens 'both commands agree on the ACTUAL token total (shared usage layer)'
        Assert-Equal $od.usage.estimated.total_tokens $md.cost_per_completed_task.estimated_tokens 'both commands agree on the ESTIMATED token total (shared usage layer)'

        # Neither projection ever leaks estimated into the actual figure.
        Assert-True ($md.cost_per_completed_task.tokens -ne $md.cost_per_completed_task.estimated_tokens) 'estimated usage is never merged into the actual total'
    }
}.Invoke()

# =============================================================================
# Report + cleanup
# =============================================================================
foreach ($d in $script:TempDirs) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }

if ($script:Failures.Count -eq 0) {
    Write-Host 'OK - all events-common (shared projection layer) tests passed.'
    exit 0
}
Write-Host "FAILED - $($script:Failures.Count) assertion(s):"
foreach ($f in $script:Failures) { Write-Host "  $f" }
exit 1
