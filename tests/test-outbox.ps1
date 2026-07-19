<#
.SYNOPSIS
    Deterministic, offline tests (T-089) for the transactional event-outbox tool
    tools/outbox.ps1.

.DESCRIPTION
    tools/outbox.ps1 is the single transactional, validated, idempotent, torn-tail-safe
    single-writer interface for Orchestra's durable observability outbox
    `.work/events.jsonl` (see docs/queue_contract.md §19 and agents/processor.md,
    "Событийный outbox"). Because it IS code, it is unit tested directly: each scenario
    drives the real tool as a child pwsh process against throwaway fixtures under the temp
    dir and asserts on output / exit code. Nothing here touches this repository's own
    .work/ and nothing reaches the network.

    Covered (per T-089's acceptance criteria):
      * Stable dedupe key: every event id is a STANDARD UUIDv5 (validated against the RFC
        known-answer vector uuid5(DNS,'python.org')) over a deterministic per-type
        canonical name; the tool's `event-id` equals an independent reference computation;
        the same committed transition recomputes the same id (replay dedups) while retry
        (attempt), new review round, new wave and a different status transition each yield
        a DISTINCT id (distinct observable facts).
      * Idempotent append / crash-replay at every documented emission point: appending the
        same event twice leaves exactly one line; the second call reports skipped-duplicate
        with rc=0.
      * Torn / corrupted tail: a truncated final fragment is repaired (dropped) on the next
        append without mutating any valid committed line and without creating a second
        semantic event; a valid unterminated last line is preserved; newline-terminated
        blank lines are ignored, while meaningful corruption is refused (rc=6).
      * Single-writer invariant: a held lock rejects a parallel writer (rc=7); with --owner
        an append not matching the orchestrator.lock lease owner is rejected (rc=13).
      * Validation at write and lenient read: unknown top-level key / bad schema_version /
        missing field / bad actor / bad id shape / codex.attempt non-allowlisted key /
        absolute path are rejected on write (rc=5); an existing schema_version:1 line with
        no payload_version, a v4 id, an evt- fallback id, or a future unknown top-level key
        still reads/validates without rewrite (no retroactive migration).
      * Reference consumer/cursor: `read` deduplicates by event_id and a durable cursor
        only ever returns new unique events; `metrics` reports phase / critical-path
        durations from timestamps and integer durations only.

.EXAMPLE
    pwsh -File tests/test-outbox.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$script:Tool = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\outbox.ps1')).Path
$script:PsExe = ([System.Diagnostics.Process]::GetCurrentProcess()).MainModule.FileName
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:TempDirs = [System.Collections.Generic.List[string]]::new()

function New-TempDir {
    $d = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'obx-t-' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($d)
    $script:TempDirs.Add($d)
    return $d
}
function New-EventsFile { param([string]$Dir) return (Join-Path $Dir 'events.jsonl') }

# Runs outbox.ps1 as a child pwsh process; returns @{ ExitCode; Out; Err }. Args are
# passed verbatim through ArgumentList (no shell), so JSON with backslashes is exact.
function Invoke-Outbox {
    param([string[]]$ToolArgs, [AllowNull()][string]$InputText)
    $hasInput = $PSBoundParameters.ContainsKey('InputText')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:PsExe
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $hasInput
    $psi.StandardOutputEncoding = $script:Utf8
    $psi.StandardErrorEncoding = $script:Utf8
    foreach ($a in (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:Tool) + $ToolArgs)) {
        $psi.ArgumentList.Add($a)
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($hasInput) {
        $proc.StandardInput.Write($InputText)
        $proc.StandardInput.Close()
    }
    $outT = $proc.StandardOutput.ReadToEndAsync()
    $errT = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Out = $outT.Result; Err = $errT.Result }
}
function Outbox-Id { param([string[]]$ToolArgs) return ((Invoke-Outbox (@('event-id') + $ToolArgs)).Out.Trim()) }

function Read-File { param([string]$Path) if (Test-Path -LiteralPath $Path) { return [System.IO.File]::ReadAllText($Path, $script:Utf8) } else { return '' } }
function Write-File { param([string]$Path, [string]$Text) [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8) }
function Append-Raw { param([string]$Path, [string]$Text) $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write); try { $b = $script:Utf8.GetBytes($Text); $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() } }
function Line-Count { param([string]$Path) $t = Read-File $Path; if ([string]::IsNullOrEmpty($t)) { return 0 }; return @($t -split "`n" | Where-Object { $_ -ne '' }).Count }

function Assert-True { param([bool]$Cond, [string]$Msg) if (-not $Cond) { $script:Failures.Add("FAIL - $Msg") } }
function Assert-Equal { param($Expected, $Actual, [string]$Msg) if ($Expected -ne $Actual) { $script:Failures.Add("FAIL - ${Msg}: expected [$Expected], got [$Actual]") } }
function Assert-Exit { param($R, [int]$Code, [string]$Msg) if ($R.ExitCode -ne $Code) { $script:Failures.Add("FAIL - ${Msg}: expected exit $Code, got $($R.ExitCode) (err=[$($R.Err.Trim())])") } }
function Assert-Contains { param([string]$Haystack, [string]$Needle, [string]$Msg) if ($Haystack.IndexOf($Needle, [System.StringComparison]::Ordinal) -lt 0) { $script:Failures.Add("FAIL - ${Msg}: [$Needle] not found in [$Haystack]") } }
function Assert-NotContains { param([string]$Haystack, [string]$Needle, [string]$Msg) if ($Haystack.IndexOf($Needle, [System.StringComparison]::Ordinal) -ge 0) { $script:Failures.Add("FAIL - ${Msg}: [$Needle] must NOT be present but was") } }

# Independent reference UUIDv5 (RFC 4122) - proves the tool uses standard UUIDv5, not an
# ad-hoc scheme. Deliberately a separate implementation from the tool's.
function Ref-UuidV5 {
    param([string]$Name, [guid]$Namespace = ([guid]'6ba7b811-9dad-11d1-80b4-00c04fd430c8'))
    $b = $Namespace.ToByteArray()
    $ns = New-Object 'byte[]' 16
    $ns[0] = $b[3]; $ns[1] = $b[2]; $ns[2] = $b[1]; $ns[3] = $b[0]; $ns[4] = $b[5]; $ns[5] = $b[4]; $ns[6] = $b[7]; $ns[7] = $b[6]
    [System.Array]::Copy($b, 8, $ns, 8, 8)
    $nm = [System.Text.Encoding]::UTF8.GetBytes($Name)
    $buf = New-Object 'byte[]' ($ns.Length + $nm.Length)
    [System.Array]::Copy($ns, 0, $buf, 0, $ns.Length); [System.Array]::Copy($nm, 0, $buf, $ns.Length, $nm.Length)
    $sha1 = [System.Security.Cryptography.SHA1]::Create(); try { $h = $sha1.ComputeHash($buf) } finally { $sha1.Dispose() }
    $o = New-Object 'byte[]' 16; [System.Array]::Copy($h, 0, $o, 0, 16)
    $o[6] = [byte](($o[6] -band 0x0F) -bor 0x50); $o[8] = [byte](($o[8] -band 0x3F) -bor 0x80)
    $sb = New-Object System.Text.StringBuilder; foreach ($x in $o) { [void]$sb.Append($x.ToString('x2')) }; $s = $sb.ToString()
    return ($s.Substring(0, 8) + '-' + $s.Substring(8, 4) + '-' + $s.Substring(12, 4) + '-' + $s.Substring(16, 4) + '-' + $s.Substring(20, 12))
}

# =============================================================================
# 1. Stable dedupe key: standard UUIDv5, deterministic, matches an independent ref.
# =============================================================================
{
    # RFC known-answer vector (proves the reference is itself correct).
    Assert-Equal '886313e1-3b8a-5372-9b90-0c9aee199e5d' (Ref-UuidV5 'python.org' ([guid]'6ba7b810-9dad-11d1-80b4-00c04fd430c8')) 'UUIDv5 reference matches RFC known-answer vector'

    # The tool's event-id equals the independent reference for each type's canonical name.
    $cases = @(
        @{ Args = @('--type', 'cohort.opened', '--batch-id', 'B-1'); Name = 'orchestra/cohort.opened/B-1' },
        @{ Args = @('--type', 'cohort.round_started', '--batch-id', 'B-1', '--wave', '2'); Name = 'orchestra/cohort.round_started/B-1/w2' },
        @{ Args = @('--type', 'task.captured', '--batch-id', 'B-1', '--task-id', 'T-014', '--attempt', '1'); Name = 'orchestra/task.captured/B-1/T-014/a1' },
        @{ Args = @('--type', 'task.status_changed', '--task-id', 'T-014', '--from', 'в работе', '--to', 'на ревью', '--attempt', '1', '--round', '1'); Name = 'orchestra/task.status_changed/T-014/в работе>на ревью/a1/r1' },
        @{ Args = @('--type', 'codex.attempt', '--task-id', 'T-014', '--role', 'coder', '--mode', 'full', '--attempt-number', '1'); Name = 'orchestra/codex.attempt/T-014/coder/full/1' }
    )
    foreach ($c in $cases) {
        $got = Outbox-Id $c.Args
        Assert-Equal (Ref-UuidV5 $c.Name) $got "event-id is standard UUIDv5 over canonical name [$($c.Name)]"
        # version nibble is 5, variant is RFC 4122 (8|9|a|b).
        Assert-True ($got[14] -eq '5') "event-id version nibble is 5 for [$($c.Name)]"
        Assert-True ('89ab'.IndexOf([string]$got[19]) -ge 0) "event-id variant is RFC 4122 for [$($c.Name)]"
    }

    # Determinism: same coordinates -> same id (replay stability).
    $a = Outbox-Id @('--type', 'task.status_changed', '--task-id', 'T-014', '--from', 'в работе', '--to', 'на ревью', '--attempt', '1', '--round', '1')
    $b = Outbox-Id @('--type', 'task.status_changed', '--task-id', 'T-014', '--from', 'в работе', '--to', 'на ревью', '--attempt', '1', '--round', '1')
    Assert-Equal $a $b 'same committed transition -> same event id (replay dedups)'
}.Invoke()

# =============================================================================
# 2. Distinct facts stay distinct: attempt, round, wave, transition, tuple differ.
# =============================================================================
{
    $base = Outbox-Id @('--type', 'task.status_changed', '--task-id', 'T-014', '--from', 'в работе', '--to', 'на ревью', '--attempt', '1', '--round', '1')
    $round2 = Outbox-Id @('--type', 'task.status_changed', '--task-id', 'T-014', '--from', 'в работе', '--to', 'на ревью', '--attempt', '1', '--round', '2')
    $attempt2 = Outbox-Id @('--type', 'task.status_changed', '--task-id', 'T-014', '--from', 'в работе', '--to', 'на ревью', '--attempt', '2', '--round', '1')
    $otherTrans = Outbox-Id @('--type', 'task.status_changed', '--task-id', 'T-014', '--from', 'на ревью', '--to', 'готова к слиянию', '--attempt', '1', '--round', '1')
    Assert-True ($base -ne $round2) 'new review round is a distinct fact'
    Assert-True ($base -ne $attempt2) 'new attempt (retry) is a distinct fact'
    Assert-True ($base -ne $otherTrans) 'a different status transition is a distinct fact'

    $w1 = Outbox-Id @('--type', 'cohort.round_started', '--batch-id', 'B-1', '--wave', '1')
    $w2 = Outbox-Id @('--type', 'cohort.round_started', '--batch-id', 'B-1', '--wave', '2')
    Assert-True ($w1 -ne $w2) 'new wave (round) is a distinct fact'

    $cx1 = Outbox-Id @('--type', 'codex.attempt', '--task-id', 'T-014', '--role', 'coder', '--mode', 'full', '--attempt-number', '1')
    $cx2 = Outbox-Id @('--type', 'codex.attempt', '--task-id', 'T-014', '--role', 'coder', '--mode', 'full', '--attempt-number', '2')
    Assert-True ($cx1 -ne $cx2) 'new codex attempt_number is a distinct fact'
}.Invoke()

# =============================================================================
# 3. Idempotent append / crash-replay at every documented emission point.
# =============================================================================
{
    $emissions = @(
        @('--type', 'cohort.opened', '--batch-id', 'B-1', '--payload', '{"wave":1}'),
        @('--type', 'cohort.round_started', '--batch-id', 'B-1', '--wave', '1', '--payload', '{"wave":1}'),
        @('--type', 'cohort.round_closed', '--batch-id', 'B-1', '--wave', '1', '--payload', '{"wave":1}'),
        @('--type', 'cohort.admission_closed', '--batch-id', 'B-1', '--payload', '{"reason":"COHORT_SIZE"}'),
        @('--type', 'cohort.join_started', '--batch-id', 'B-1', '--payload', '{}'),
        @('--type', 'cohort.published', '--batch-id', 'B-1', '--payload', '{"pushed":true}'),
        @('--type', 'cohort.closed', '--batch-id', 'B-1', '--payload', '{}'),
        @('--type', 'task.captured', '--batch-id', 'B-1', '--task-id', 'T-014', '--attempt', '1', '--payload', '{"level":"coder"}'),
        @('--type', 'task.status_changed', '--task-id', 'T-014', '--from', 'в работе', '--to', 'на ревью', '--attempt', '1', '--round', '1', '--payload', '{"from":"в работе","to":"на ревью"}'),
        @('--type', 'codex.attempt', '--task-id', 'T-014', '--role', 'coder', '--mode', 'full', '--attempt-number', '1', '--payload', '{"role":"coder","mode":"full","attempt_number":1,"outcome":"success"}')
    )
    foreach ($e in $emissions) {
        $dir = New-TempDir; $ev = New-EventsFile $dir
        $r1 = Invoke-Outbox (@('append', '--events', $ev) + $e)
        Assert-Exit $r1 0 "append emission [$($e[1])]"
        Assert-Contains $r1.Out 'appended' "first append writes [$($e[1])]"
        # replay: same committed fact re-emitted -> deduped, exactly one line.
        $r2 = Invoke-Outbox (@('append', '--events', $ev) + $e)
        Assert-Exit $r2 0 "replay append emission [$($e[1])]"
        Assert-Contains $r2.Out 'skipped-duplicate' "replay is deduplicated [$($e[1])]"
        Assert-Equal 1 (Line-Count $ev) "exactly one line after replay [$($e[1])]"
    }
}.Invoke()

# =============================================================================
# 4. Torn tail: repaired without losing/mutating valid lines or double-emitting.
# =============================================================================
{
    $dir = New-TempDir; $ev = New-EventsFile $dir
    $r = Invoke-Outbox @('append', '--events', $ev, '--type', 'cohort.opened', '--batch-id', 'B-1', '--payload', '{"wave":1}')
    Assert-Exit $r 0 'seed valid line'
    $good = (Read-File $ev).TrimEnd("`n")

    # a truncated final fragment (no trailing newline) simulates a crash mid-append.
    Append-Raw $ev '{"schema_version":1,"event_id":"1111","occurred_at":"2026-07-10T11:00:00Z","typ'
    $v = Invoke-Outbox @('verify', '--events', $ev)
    Assert-Contains $v.Out 'torn tail present' 'verify detects a torn tail'

    $r2 = Invoke-Outbox @('append', '--events', $ev, '--type', 'cohort.closed', '--batch-id', 'B-1', '--payload', '{}')
    Assert-Exit $r2 0 'append repairs torn tail'
    Assert-Contains $r2.Out 'repaired-torn-tail' 'append reports the repair'
    Assert-Equal 2 (Line-Count $ev) 'torn fragment dropped, two valid lines remain'
    Assert-Equal $good ((Read-File $ev) -split "`n")[0] 'the pre-torn valid line is preserved byte-for-byte'
    $vf = Invoke-Outbox @('verify', '--events', $ev, '--json'); Assert-Exit $vf 0 'verify clean after repair'

    # a torn DUPLICATE fragment of a committed event must not become a second semantic event.
    $dir2 = New-TempDir; $ev2 = New-EventsFile $dir2
    $c = Invoke-Outbox @('append', '--events', $ev2, '--type', 'cohort.opened', '--batch-id', 'B-9', '--payload', '{"wave":1}')
    $committed = (Read-File $ev2).TrimEnd("`n")
    Append-Raw $ev2 ($committed.Substring(0, 40))   # torn partial re-write of the same line
    $c2 = Invoke-Outbox @('append', '--events', $ev2, '--type', 'cohort.opened', '--batch-id', 'B-9', '--payload', '{"wave":1}')
    Assert-Exit $c2 0 'replay after torn duplicate'
    Assert-Contains $c2.Out 'skipped-duplicate' 'torn duplicate + replay dedups to one fact'
    Assert-Equal 1 (Line-Count $ev2) 'no second semantic event for a committed fact'

    # a VALID but unterminated last line (lost trailing newline) is preserved, not dropped.
    $dir3 = New-TempDir; $ev3 = New-EventsFile $dir3
    Invoke-Outbox @('append', '--events', $ev3, '--type', 'cohort.opened', '--batch-id', 'B-3', '--payload', '{}') | Out-Null
    $line = (Read-File $ev3).TrimEnd("`n")
    Write-File $ev3 $line   # rewrite WITHOUT trailing newline (still a valid complete line)
    $r3 = Invoke-Outbox @('append', '--events', $ev3, '--type', 'cohort.closed', '--batch-id', 'B-3', '--payload', '{}')
    Assert-Exit $r3 0 'append after a valid unterminated last line'
    Assert-NotContains $r3.Out 'repaired-torn-tail' 'a valid unterminated line is not treated as torn'
    Assert-Equal 2 (Line-Count $ev3) 'valid unterminated line kept and separated'
}.Invoke()

# =============================================================================
# 5. Blank committed lines are ignored; meaningful corruption is still refused.
# =============================================================================
{
    $dir = New-TempDir; $ev = New-EventsFile $dir
    Invoke-Outbox @('append', '--events', $ev, '--type', 'cohort.opened', '--batch-id', 'B-1', '--payload', '{}') | Out-Null

    # Accidental empty and whitespace-only newline-terminated separators are not corruption.
    Append-Raw $ev "`n `t `n"
    $blankRead = Invoke-Outbox @('read', '--events', $ev, '--json')
    Assert-Exit $blankRead 0 'read continues past blank committed lines'
    $blankReadObj = $blankRead.Out | ConvertFrom-Json
    Assert-Equal 1 $blankReadObj.new_count 'read still delivers the valid event around blank lines'
    Assert-Equal 2 $blankReadObj.skipped_invalid 'read retains skipped_invalid accounting for blank lines'
    $blankVerify = Invoke-Outbox @('verify', '--events', $ev, '--json')
    Assert-Exit $blankVerify 0 'verify does not treat blank committed lines as blocking corruption'

    $afterBlank = Invoke-Outbox @('append', '--events', $ev, '--type', 'cohort.closed', '--batch-id', 'B-1', '--payload', '{}')
    Assert-Exit $afterBlank 0 'append continues after empty and whitespace-only committed lines'
    Assert-Contains $afterBlank.Out 'appended' 'append writes the event after blank committed lines'

    Append-Raw $ev "garbage that is not json`n"
    $v = Invoke-Outbox @('verify', '--events', $ev)
    Assert-Exit $v 6 'verify flags a corrupt committed line (rc=6)'
    $a = Invoke-Outbox @('append', '--events', $ev, '--type', 'cohort.join_started', '--batch-id', 'B-1', '--payload', '{}')
    Assert-Exit $a 6 'append refuses to write over corruption (rc=6)'
}.Invoke()

# =============================================================================
# 6. Single-writer invariant: held lock rejects a parallel writer; owner binding.
# =============================================================================
{
    $dir = New-TempDir; $ev = New-EventsFile $dir
    Write-File "$ev.lock" '99999'   # simulate a concurrently held lock
    $r = Invoke-Outbox @('append', '--events', $ev, '--type', 'cohort.opened', '--batch-id', 'B-1', '--payload', '{}', '--lock-timeout-ms', '400')
    Assert-Exit $r 7 'a parallel writer that cannot take the lock is rejected (rc=7)'
    Remove-Item -LiteralPath "$ev.lock" -Force

    # owner binding against the orchestrator.lock lease.
    $work = New-TempDir
    [void][System.IO.Directory]::CreateDirectory((Join-Path $work 'orchestrator.lock'))
    Write-File (Join-Path $work 'orchestrator.lock/lease.json') '{"schema":"orchestra/lease@1","owner_id":"OWNER-A","role":"processor","root":"/x","host":"h","heartbeat":"2026-07-10T11:00:00Z","ttl_seconds":900,"generation":1}'
    $mism = Invoke-Outbox @('append', '--work', $work, '--owner', 'OWNER-B', '--type', 'cohort.opened', '--batch-id', 'B-1', '--payload', '{}')
    Assert-Exit $mism 13 'a non-owner writer is rejected (rc=13)'
    $ok = Invoke-Outbox @('append', '--work', $work, '--owner', 'OWNER-A', '--type', 'cohort.opened', '--batch-id', 'B-1', '--payload', '{}')
    Assert-Exit $ok 0 'the lease owner may write (rc=0)'

    $work2 = New-TempDir
    $noLease = Invoke-Outbox @('append', '--work', $work2, '--owner', 'X', '--type', 'cohort.opened', '--batch-id', 'B-1', '--payload', '{}')
    Assert-Exit $noLease 13 'no lease + --owner is rejected (rc=13)'
}.Invoke()

# =============================================================================
# 7. Write validation is strict; read validation is lenient forward.
# =============================================================================
{
    $dir = New-TempDir; $ev = New-EventsFile $dir

    # unknown --type -> usage error (rc=2)
    $t = Invoke-Outbox @('append', '--events', $ev, '--type', 'bogus.type', '--batch-id', 'B-1', '--payload', '{}')
    Assert-Exit $t 2 'unknown --type is a usage error'

    # bad schema_version via raw json-line (rc=5)
    $sv = Invoke-Outbox @('append', '--events', $ev, '--json-line', '{"schema_version":2,"event_id":"11111111-1111-1111-1111-111111111111","occurred_at":"2026-07-10T11:00:00Z","type":"cohort.opened","actor":{"kind":"agent","name":"processor"},"payload":{}}')
    Assert-Exit $sv 5 'unsupported schema_version rejected'

    # unknown top-level key on write (rc=5)
    $uk = Invoke-Outbox @('append', '--events', $ev, '--json-line', '{"schema_version":1,"event_id":"11111111-1111-1111-1111-111111111111","occurred_at":"2026-07-10T11:00:00Z","type":"cohort.opened","actor":{"kind":"agent","name":"processor"},"payload":{},"surprise":"x"}')
    Assert-Exit $uk 5 'unknown top-level key rejected on write'

    # missing required field (rc=5)
    $mf = Invoke-Outbox @('append', '--events', $ev, '--json-line', '{"schema_version":1,"event_id":"11111111-1111-1111-1111-111111111111","type":"cohort.opened","actor":{"kind":"agent","name":"processor"},"payload":{}}')
    Assert-Exit $mf 5 'missing occurred_at rejected'

    # bad actor kind (rc=5)
    $ak = Invoke-Outbox @('append', '--events', $ev, '--json-line', '{"schema_version":1,"event_id":"11111111-1111-1111-1111-111111111111","occurred_at":"2026-07-10T11:00:00Z","type":"cohort.opened","actor":{"kind":"robot","name":"x"},"payload":{}}')
    Assert-Exit $ak 5 'bad actor.kind rejected'

    # bad task_id shape (rc=5)
    $bid = Invoke-Outbox @('append', '--events', $ev, '--json-line', '{"schema_version":1,"event_id":"11111111-1111-1111-1111-111111111111","occurred_at":"2026-07-10T11:00:00Z","type":"task.status_changed","task_id":"nope","actor":{"kind":"agent","name":"processor"},"payload":{}}')
    Assert-Exit $bid 5 'malformed task_id rejected'

    # codex.attempt non-allowlisted payload key (privacy) (rc=5)
    $cx = Invoke-Outbox @('append', '--events', $ev, '--task-id', 'T-1', '--type', 'codex.attempt', '--role', 'coder', '--mode', 'full', '--attempt-number', '1', '--payload', '{"role":"coder","mode":"full","attempt_number":1,"outcome":"success","prompt":"secret"}')
    Assert-Exit $cx 5 'codex.attempt non-allowlisted key rejected'
    Assert-Contains $cx.Err 'allowlist' 'rejection cites the privacy allowlist'

    # absolute path anywhere in payload (privacy) (rc=5) - exact JSON, no shell mangling.
    $ap = Invoke-Outbox @('append', '--events', $ev, '--type', 'cohort.opened', '--batch-id', 'B-1', '--payload', '{"p":"C:\\secret\\creds"}')
    Assert-Exit $ap 5 'absolute Windows path in payload rejected'
    $ap2 = Invoke-Outbox @('append', '--events', $ev, '--type', 'cohort.opened', '--batch-id', 'B-1', '--payload', '{"p":"/etc/shadow"}')
    Assert-Exit $ap2 5 'absolute POSIX path in payload rejected'
    # a relative .work path is fine.
    $rel = Invoke-Outbox @('append', '--events', $ev, '--type', 'task.captured', '--batch-id', 'B-1', '--task-id', 'T-1', '--attempt', '1', '--payload', '{"worktree":".work/worktrees/T-1"}')
    Assert-Exit $rel 0 'a relative .work/worktrees path is allowed'

    # the file was never corrupted by any rejected write.
    $vf = Invoke-Outbox @('verify', '--events', $ev, '--json')
    Assert-True ($vf.ExitCode -eq 0) 'rejected writes never corrupted the outbox'
}.Invoke()

# =============================================================================
# 8. Existing lines read without rewrite / retroactive migration.
# =============================================================================
{
    $dir = New-TempDir; $ev = New-EventsFile $dir
    # schema_version:1, a random v4 id, NO payload_version (the pre-T-089 shape).
    Write-File $ev ('{"schema_version":1,"event_id":"9d3f7c2a-1b4e-4a6f-8c2d-0e1f2a3b4c5d","occurred_at":"2026-07-08T09:31:07Z","type":"cohort.opened","batch_id":"B-0","actor":{"kind":"agent","name":"processor"},"payload":{}}' + "`n")
    # an evt- fallback id line.
    Append-Raw $ev ('{"schema_version":1,"event_id":"evt-2026-07-08T09:31:07Z-abcd","occurred_at":"2026-07-08T09:31:08Z","type":"cohort.closed","batch_id":"B-0","actor":{"kind":"agent","name":"processor"},"payload":{}}' + "`n")
    # a future unknown top-level key (forward compat) line.
    Append-Raw $ev ('{"schema_version":1,"event_id":"7a1c9e55-2b3d-4e6f-9a0b-1c2d3e4f5a6b","occurred_at":"2026-07-08T09:31:09Z","type":"cohort.join_started","batch_id":"B-0","run_id":"run-1","actor":{"kind":"agent","name":"processor"},"payload":{}}' + "`n")
    $v = Invoke-Outbox @('verify', '--events', $ev, '--json')
    Assert-Exit $v 0 'legacy + forward-compat lines read valid without migration'
    $obj = $v.Out | ConvertFrom-Json
    Assert-Equal 3 $obj.valid 'all three existing lines are valid on read'

    # but appending an event with a future unknown top-level key is rejected (write is strict).
    $w = Invoke-Outbox @('append', '--events', $ev, '--json-line', '{"schema_version":1,"event_id":"7a1c9e55-2b3d-4e6f-9a0b-1c2d3e4f5a6b","occurred_at":"2026-07-08T09:31:09Z","type":"cohort.join_started","batch_id":"B-0","run_id":"run-1","actor":{"kind":"agent","name":"processor"},"payload":{}}')
    Assert-Exit $w 5 'strict writer rejects an unknown top-level key that lenient read tolerates'
}.Invoke()

# =============================================================================
# 9. Reference consumer/cursor: dedup by event_id; durable cursor returns only new.
# =============================================================================
{
    $dir = New-TempDir; $ev = New-EventsFile $dir
    Invoke-Outbox @('append', '--events', $ev, '--type', 'cohort.opened', '--batch-id', 'B-1', '--payload', '{}') | Out-Null
    Invoke-Outbox @('append', '--events', $ev, '--type', 'cohort.round_started', '--batch-id', 'B-1', '--wave', '1', '--payload', '{"wave":1}') | Out-Null
    # a manually-duplicated committed line (a redelivered replay landing in the file).
    $first = ((Read-File $ev) -split "`n")[0]
    Append-Raw $ev ($first + "`n")
    $rd = Invoke-Outbox @('read', '--events', $ev, '--json') | Select-Object -First 1
    $obj = $rd.Out | ConvertFrom-Json
    Assert-Equal 2 $obj.new_count 'read deduplicates by event_id (2 unique of 3 lines)'
    Assert-Equal 1 $obj.skipped_dup 'read counts the duplicate as skipped'

    # cursor: first read returns 2, advances; a subsequent read returns 0 until new events.
    $dir2 = New-TempDir; $ev2 = New-EventsFile $dir2; $cur = Join-Path $dir2 'events_cursor.json'
    Invoke-Outbox @('append', '--events', $ev2, '--type', 'cohort.opened', '--batch-id', 'B-2', '--payload', '{}') | Out-Null
    Invoke-Outbox @('append', '--events', $ev2, '--type', 'cohort.join_started', '--batch-id', 'B-2', '--payload', '{}') | Out-Null
    $c1 = (Invoke-Outbox @('read', '--events', $ev2, '--cursor', $cur, '--json')).Out | ConvertFrom-Json
    Assert-Equal 2 $c1.new_count 'cursor first read delivers all events'
    $c2 = (Invoke-Outbox @('read', '--events', $ev2, '--cursor', $cur, '--json')).Out | ConvertFrom-Json
    Assert-Equal 0 $c2.new_count 'cursor re-read delivers nothing new'
    Invoke-Outbox @('append', '--events', $ev2, '--type', 'cohort.closed', '--batch-id', 'B-2', '--payload', '{}') | Out-Null
    $c3 = (Invoke-Outbox @('read', '--events', $ev2, '--cursor', $cur, '--json')).Out | ConvertFrom-Json
    Assert-Equal 1 $c3.new_count 'cursor delivers only the newly appended event'
}.Invoke()

# =============================================================================
# 10. Metrics: phase / critical-path durations from timestamps and durations only.
# =============================================================================
{
    $dir = New-TempDir; $ev = New-EventsFile $dir
    Invoke-Outbox @('append', '--events', $ev, '--batch-id', 'B-1', '--task-id', 'T-014', '--type', 'task.captured', '--attempt', '1', '--occurred-at', '2026-07-10T10:00:00.000Z', '--payload', '{"level":"coder"}') | Out-Null
    Invoke-Outbox @('append', '--events', $ev, '--batch-id', 'B-1', '--task-id', 'T-014', '--type', 'codex.attempt', '--role', 'coder', '--mode', 'full', '--attempt-number', '1', '--payload', '{"role":"coder","mode":"full","attempt_number":1,"duration_ms":2000,"outcome":"success"}') | Out-Null
    Invoke-Outbox @('append', '--events', $ev, '--batch-id', 'B-1', '--type', 'cohort.round_started', '--wave', '1', '--occurred-at', '2026-07-10T10:00:00.000Z', '--payload', '{"wave":1}') | Out-Null
    Invoke-Outbox @('append', '--events', $ev, '--batch-id', 'B-1', '--type', 'cohort.round_closed', '--wave', '1', '--occurred-at', '2026-07-10T10:00:30.000Z', '--payload', '{"wave":1}') | Out-Null
    Invoke-Outbox @('append', '--events', $ev, '--task-id', 'T-014', '--type', 'task.status_changed', '--from', 'опубликована', '--to', 'выполнена', '--attempt', '1', '--round', '1', '--occurred-at', '2026-07-10T10:05:00.000Z', '--payload', '{"from":"опубликована","to":"выполнена"}') | Out-Null

    $m = Invoke-Outbox @('metrics', '--events', $ev, '--json')
    Assert-Exit $m 0 'metrics runs'
    $obj = $m.Out | ConvertFrom-Json
    Assert-Equal 5 $obj.total_events 'metrics sees all events'
    Assert-Equal 1 $obj.codex_attempt.n 'metrics aggregates codex.attempt count'
    Assert-Equal 2000 $obj.codex_attempt.avg_ms 'metrics reports codex.attempt duration'
    Assert-Equal 30000 $obj.round_durations[0].duration_ms 'metrics reports round wall-time (30s)'
    Assert-Equal 300000 $obj.critical_paths[0].critical_path_ms 'metrics reports captured->done critical path (5min)'
    Assert-NotContains $m.Out 'secret' 'metrics carries no sensitive text'
}.Invoke()

# =============================================================================
# 11. version
# =============================================================================
{
    $r = Invoke-Outbox @('version')
    Assert-Exit $r 0 'version rc=0'
    Assert-Contains $r.Out 'orchestra-outbox' 'version identifies the tool'
}.Invoke()

# =============================================================================
# 12. usage.recorded (T-248): dedup key (source is a coordinate), strict scalar
#     allowlist + shape guard on write, forward-lenient read, metrics split of
#     ACTUAL vs ESTIMATED tokens by source.
# =============================================================================
{
    # dedup key: source distinguishes a codex attempt from its Claude fallback for the
    # SAME (task,role,mode,attempt); the id is a standard UUIDv5 over the canonical name.
    $u1 = Outbox-Id @('--type', 'usage.recorded', '--source', 'codex', '--task-id', 'T-1', '--role', 'coder', '--mode', 'full', '--attempt-number', '1')
    $u2 = Outbox-Id @('--type', 'usage.recorded', '--source', 'claude', '--task-id', 'T-1', '--role', 'coder', '--mode', 'full', '--attempt-number', '1')
    Assert-True ($u1 -ne $u2) 'usage.recorded source is a dedup-key coordinate (codex vs claude are distinct facts)'
    Assert-Equal (Ref-UuidV5 'orchestra/usage.recorded/codex/T-1/coder/full/1') $u1 'usage.recorded event-id is standard UUIDv5 over its canonical name'

    $dir = New-TempDir; $ev = New-EventsFile $dir
    $payload = '{"task_id":"T-1","role":"coder","mode":"full","attempt_number":1,"source":"codex","model":"default","input_tokens":1200,"output_tokens":450,"cache_read_input_tokens":300,"cache_creation_input_tokens":0,"total_tokens":1950,"estimated":false}'
    $a1 = Invoke-Outbox @('append', '--events', $ev, '--batch-id', 'B-1', '--type', 'usage.recorded', '--source', 'codex', '--task-id', 'T-1', '--role', 'coder', '--mode', 'full', '--attempt-number', '1', '--payload', $payload)
    Assert-Exit $a1 0 'usage.recorded actual usage appends'
    $a2 = Invoke-Outbox @('append', '--events', $ev, '--batch-id', 'B-1', '--type', 'usage.recorded', '--source', 'codex', '--task-id', 'T-1', '--role', 'coder', '--mode', 'full', '--attempt-number', '1', '--payload', $payload)
    Assert-Contains $a2.Out 'skipped-duplicate' 'usage.recorded replay dedups by event_id'
    Assert-Equal 1 (Line-Count $ev) 'usage.recorded replay leaves exactly one line'

    # non-allowlisted payload key rejected on write (privacy, like codex.attempt).
    $bad = Invoke-Outbox @('append', '--events', $ev, '--type', 'usage.recorded', '--source', 'codex', '--task-id', 'T-2', '--role', 'coder', '--mode', 'full', '--attempt-number', '1', '--payload', '{"prompt":"secret","total_tokens":5}')
    Assert-Exit $bad 5 'usage.recorded non-allowlisted key rejected'
    Assert-Contains $bad.Err 'allowlist' 'usage.recorded rejection cites the privacy allowlist'

    # scalar-shape guard: non-integer token / non-boolean estimated rejected; null is allowed.
    $nonInt = Invoke-Outbox @('append', '--events', $ev, '--type', 'usage.recorded', '--source', 'codex', '--task-id', 'T-2', '--role', 'coder', '--mode', 'full', '--attempt-number', '1', '--payload', '{"total_tokens":"lots"}')
    Assert-Exit $nonInt 5 'usage.recorded non-integer token rejected'
    $badEst = Invoke-Outbox @('append', '--events', $ev, '--type', 'usage.recorded', '--source', 'codex', '--task-id', 'T-2', '--role', 'coder', '--mode', 'full', '--attempt-number', '1', '--payload', '{"total_tokens":5,"estimated":"yes"}')
    Assert-Exit $badEst 5 'usage.recorded non-boolean estimated rejected'
    $nullTok = Invoke-Outbox @('append', '--events', $ev, '--batch-id', 'B-1', '--type', 'usage.recorded', '--source', 'claude', '--task-id', 'T-2', '--role', 'reviewer', '--mode', 'full', '--attempt-number', '1', '--payload', '{"source":"claude","input_tokens":null,"total_tokens":800,"estimated":true}')
    Assert-Exit $nullTok 0 'usage.recorded null token field ("unknown for this call") is allowed'

    # forward-lenient read: a usage.recorded line with a FUTURE unknown payload key reads valid
    # without rewrite (strict write still refuses it); an OLD codex.attempt line still reads too.
    $dir2 = New-TempDir; $ev2 = New-EventsFile $dir2
    $fid = Outbox-Id @('--type', 'usage.recorded', '--source', 'codex', '--task-id', 'T-3', '--role', 'coder', '--mode', 'full', '--attempt-number', '1')
    $futureLine = '{"schema_version":1,"event_id":"' + $fid + '","occurred_at":"2026-07-17T10:00:00Z","type":"usage.recorded","batch_id":"B-1","task_id":"T-3","actor":{"kind":"tool","name":"codex"},"payload":{"source":"codex","total_tokens":10,"estimated":false,"future_field":"x"}}'
    Write-File $ev2 ($futureLine + "`n")
    Append-Raw $ev2 ('{"schema_version":1,"event_id":"208af7d9-b848-4bd9-a215-3791e2b5c94d","occurred_at":"2026-07-17T10:00:01Z","type":"codex.attempt","task_id":"T-3","actor":{"kind":"tool","name":"codex"},"payload":{"role":"coder","attempt_number":1}}' + "`n")
    $vr = Invoke-Outbox @('verify', '--events', $ev2, '--json')
    Assert-Exit $vr 0 'forward-lenient: future usage payload key + old codex.attempt read valid without migration'
    Assert-Equal 2 (($vr.Out | ConvertFrom-Json).valid) 'both existing lines are valid on read'
    $wfut = Invoke-Outbox @('append', '--events', $ev2, '--json-line', $futureLine)
    Assert-Exit $wfut 5 'strict writer refuses a future usage payload key that lenient read tolerates'

    # metrics: ACTUAL and ESTIMATED usage are aggregated in SEPARATE buckets, split by source.
    $dir3 = New-TempDir; $ev3 = New-EventsFile $dir3
    Invoke-Outbox @('append', '--events', $ev3, '--batch-id', 'B-1', '--type', 'usage.recorded', '--source', 'codex', '--task-id', 'T-1', '--role', 'coder', '--mode', 'full', '--attempt-number', '1', '--payload', '{"source":"codex","input_tokens":1000,"output_tokens":500,"total_tokens":1500,"estimated":false}') | Out-Null
    Invoke-Outbox @('append', '--events', $ev3, '--batch-id', 'B-1', '--type', 'usage.recorded', '--source', 'claude', '--task-id', 'T-1', '--role', 'reviewer', '--mode', 'full', '--attempt-number', '1', '--payload', '{"source":"claude","total_tokens":800,"estimated":true}') | Out-Null
    $m = Invoke-Outbox @('metrics', '--events', $ev3, '--json')
    Assert-Exit $m 0 'metrics runs over usage.recorded'
    $mo = $m.Out | ConvertFrom-Json
    Assert-Equal 1500 $mo.usage.actual.total_tokens 'metrics sums ACTUAL usage'
    Assert-Equal 1000 $mo.usage.actual.input_tokens 'metrics sums ACTUAL input tokens component'
    Assert-Equal 800 $mo.usage.estimated.total_tokens 'metrics keeps ESTIMATED usage in a separate bucket (never merged with actual)'
    Assert-Equal 1500 $mo.usage.by_source.codex.actual_total_tokens 'metrics splits ACTUAL usage by source'
    Assert-Equal 800 $mo.usage.by_source.claude.estimated_total_tokens 'metrics splits ESTIMATED usage by source'
    Assert-NotContains $m.Out 'secret' 'metrics carries no sensitive text'
}.Invoke()

# =============================================================================
# 13. Coordinate payload-fallback (T-261): a CLI flag that is ALSO always present
#     in the type's documented --payload (--wave for cohort.round_started/closed,
#     --from/--to for task.status_changed) may be omitted from the CLI and read
#     from --payload instead - fixing the "outbox: missing required option --wave"
#     trap without weakening the explicit-flag-wins priority or the "absent from
#     both -> Fail 2" regression case.
# =============================================================================
{
    # cohort.round_started / round_closed: --wave omitted, only present in --payload
    # -> succeeds, and the computed event_id equals the explicit --wave branch
    # (detereminism across the two coordinate sources is not broken).
    foreach ($type in @('cohort.round_started', 'cohort.round_closed')) {
        $explicit = Outbox-Id @('--type', $type, '--batch-id', 'B-1', '--wave', '3')
        $viaPayload = Outbox-Id @('--type', $type, '--batch-id', 'B-1', '--payload', '{"wave":3,"active":0,"free_slots":5}')
        Assert-Equal $explicit $viaPayload "[$type] event_id from --payload-only wave matches the explicit --wave branch"
        Assert-Equal (Ref-UuidV5 "orchestra/$type/B-1/w3") $viaPayload "[$type] --payload-only wave is still the standard UUIDv5 over the documented canonical name"

        # end-to-end: `append` without --wave (only in --payload) actually succeeds (not Fail 2).
        $dir = New-TempDir; $ev = New-EventsFile $dir
        $r = Invoke-Outbox @('append', '--events', $ev, '--type', $type, '--batch-id', 'B-1', '--payload', '{"wave":3,"active":0,"free_slots":5}')
        Assert-Exit $r 0 "[$type] append succeeds without a separate --wave flag (payload fallback)"
        Assert-Contains $r.Out "event_id=$viaPayload" "[$type] append computes the same event_id as the --payload fallback"
    }

    # Conflict: an explicit --wave that disagrees with --payload's wave is NOT silently
    # overridden by the payload - the explicit flag keeps priority (documented decision,
    # docs/queue_contract.md §19.2 / tools/outbox.ps1 Get-CoordFallback comment).
    $conflictId = Outbox-Id @('--type', 'cohort.round_started', '--batch-id', 'B-1', '--wave', '5', '--payload', '{"wave":3}')
    Assert-Equal (Ref-UuidV5 'orchestra/cohort.round_started/B-1/w5') $conflictId 'explicit --wave wins over a conflicting --payload wave (priority not silently overridden)'
    Assert-True ($conflictId -ne (Ref-UuidV5 'orchestra/cohort.round_started/B-1/w3')) 'a conflicting --payload wave is NOT what the id is computed from'

    # Absent from BOTH the CLI flag and --payload: still Fail 2 (no regression), and the
    # message still names the missing option like the pre-T-261 Require-Opt diagnostic.
    $missingBoth = Invoke-Outbox @('event-id', '--type', 'cohort.round_started', '--batch-id', 'B-1')
    Assert-Exit $missingBoth 2 'wave absent from both CLI flag and payload is still a usage error (rc=2)'
    Assert-Contains $missingBoth.Err 'missing required option --wave' 'the rc=2 diagnostic still names --wave'
    $missingBothPayload = Invoke-Outbox @('event-id', '--type', 'cohort.round_started', '--batch-id', 'B-1', '--payload', '{"active":0}')
    Assert-Exit $missingBothPayload 2 'wave absent from an unrelated --payload is still a usage error (rc=2)'

    # task.status_changed: --from/--to also fall back to --payload (same trap class).
    $tExplicit = Outbox-Id @('--type', 'task.status_changed', '--task-id', 'T-014', '--from', 'в работе', '--to', 'на ревью', '--attempt', '1', '--round', '1')
    $tViaPayload = Outbox-Id @('--type', 'task.status_changed', '--task-id', 'T-014', '--attempt', '1', '--round', '1', '--payload', '{"from":"в работе","to":"на ревью"}')
    Assert-Equal $tExplicit $tViaPayload 'task.status_changed: event_id from --payload-only from/to matches the explicit --from/--to branch'
    $tMissing = Invoke-Outbox @('event-id', '--type', 'task.status_changed', '--task-id', 'T-014', '--attempt', '1', '--round', '1')
    Assert-Exit $tMissing 2 'task.status_changed: from/to absent from both CLI and payload is still a usage error (rc=2)'
}.Invoke()

# =============================================================================
# 14. Raw append is physically single-line: pretty-printed JSON supplied through
#     --json-line or --stdin is rejected before validation/write, while compact
#     raw JSON and subsequent appends remain valid.
# =============================================================================
{
    $dir = New-TempDir; $ev = New-EventsFile $dir
    $singleLine1 = '{"schema_version":1,"event_id":"10000000-0000-4000-8000-000000000001","occurred_at":"2026-07-19T10:00:00Z","type":"cohort.opened","batch_id":"B-raw","actor":{"kind":"agent","name":"processor"},"payload":{}}'
    $singleLine2 = '{"schema_version":1,"event_id":"10000000-0000-4000-8000-000000000002","occurred_at":"2026-07-19T10:01:00Z","type":"cohort.closed","batch_id":"B-raw","actor":{"kind":"agent","name":"processor"},"payload":{}}'
    $pretty = @'
{
  "schema_version": 1,
  "event_id": "10000000-0000-4000-8000-000000000003",
  "occurred_at": "2026-07-19T10:02:00Z",
  "type": "cohort.opened",
  "batch_id": "B-raw",
  "actor": { "kind": "agent", "name": "processor" },
  "payload": {}
}
'@

    $compact = Invoke-Outbox @('append', '--events', $ev, '--json-line', $singleLine1)
    Assert-Exit $compact 0 'single-line --json-line append still succeeds'
    Assert-Equal 1 (Line-Count $ev) 'single-line raw append writes exactly one physical line'

    $jsonLine = Invoke-Outbox @('append', '--events', $ev, '--json-line', $pretty)
    Assert-Exit $jsonLine 5 'multiline --json-line is rejected before append'
    Assert-Contains $jsonLine.Err 'serialized event contains a newline' 'multiline --json-line reports the newline guard'
    Assert-Equal 1 (Line-Count $ev) 'rejected multiline --json-line does not alter events.jsonl'

    $afterJsonLine = Invoke-Outbox @('append', '--events', $ev, '--json-line', $singleLine2)
    Assert-Exit $afterJsonLine 0 'single-line raw append still works after --json-line rejection'
    Assert-Equal 2 (Line-Count $ev) 'subsequent raw append remains one event per physical line'

    $stdin = Invoke-Outbox -ToolArgs @('append', '--events', $ev, '--stdin') -InputText $pretty
    Assert-Exit $stdin 5 'multiline --stdin is rejected before append'
    Assert-Contains $stdin.Err 'serialized event contains a newline' 'multiline --stdin reports the same newline guard'
    Assert-Equal 2 (Line-Count $ev) 'rejected multiline --stdin does not alter events.jsonl'

    $afterStdin = Invoke-Outbox @('append', '--events', $ev, '--type', 'cohort.published', '--batch-id', 'B-raw', '--payload', '{}')
    Assert-Exit $afterStdin 0 'built append still works after --stdin rejection'
    Assert-Equal 3 (Line-Count $ev) 'built append after raw rejection preserves physical line boundaries'
    $verify = Invoke-Outbox @('verify', '--events', $ev, '--json')
    Assert-Exit $verify 0 'events.jsonl remains line-by-line valid after raw multiline rejections'
}.Invoke()

# =============================================================================
# Report + cleanup
# =============================================================================
foreach ($d in $script:TempDirs) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }

if ($script:Failures.Count -eq 0) {
    Write-Host "OK - all outbox tests passed."
    exit 0
}
Write-Host "FAILED - $($script:Failures.Count) assertion(s):"
foreach ($f in $script:Failures) { Write-Host "  $f" }
exit 1
