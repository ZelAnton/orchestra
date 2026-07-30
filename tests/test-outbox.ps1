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
        only ever returns new unique events from the normal single-writer stream;
        `delivered_ids` retention is bounded at zero across a long append/read sequence,
        while an anomalous duplicate appended after the saved offset has the documented
        at-least-once trade-off. `metrics` reports phase / critical-path durations from
        timestamps and integer durations only.

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
function New-OutboxLockPath { param([string]$Dir) return (Join-Path $Dir 'outbox-tx.lock') }

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
    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        if ($hasInput) {
            $proc.StandardInput.Write($InputText)
            $proc.StandardInput.Close()
        }
        $outT = $proc.StandardOutput.ReadToEndAsync()
        $errT = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        # Materialize every field before disposing the process and its redirected handles.
        $exitCode = $proc.ExitCode
        $out = $outT.Result
        $err = $errT.Result
        return [pscustomobject]@{ ExitCode = $exitCode; Out = $out; Err = $err }
    } finally {
        if ($null -ne $proc) { $proc.Dispose() }
    }
}

# Starts the real outbox tool without waiting. OUTBOX_TEST_LOCK_WAIT_SIGNAL is consumed by
# the shared common.ps1 wrapper and emitted only after its atomic CreateNew probe has actually
# found the resolved outbox lock contended, giving tests a deterministic handshake.
function Start-OutboxAsync {
    param([string[]]$ToolArgs, [string]$LockWaitSignal)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:PsExe
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8
    $psi.StandardErrorEncoding = $script:Utf8
    if ($LockWaitSignal) { $psi.EnvironmentVariables['OUTBOX_TEST_LOCK_WAIT_SIGNAL'] = $LockWaitSignal }
    foreach ($a in (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:Tool) + $ToolArgs)) {
        $psi.ArgumentList.Add($a)
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    return [pscustomobject]@{
        Process = $proc
        OutTask = $proc.StandardOutput.ReadToEndAsync()
        ErrTask = $proc.StandardError.ReadToEndAsync()
    }
}

function Complete-OutboxAsync {
    param($Running, [int]$TimeoutMs, [string]$Label)
    try {
        $exited = $Running.Process.WaitForExit($TimeoutMs)
        Assert-True $exited "$Label process completes within the safety budget"
        if (-not $exited) {
            try { $Running.Process.Kill() } catch { }
            return [pscustomobject]@{ ExitCode = -999; Out = ''; Err = 'timed out' }
        }
        # Parameterless WaitForExit ensures redirected async output has fully drained.
        $Running.Process.WaitForExit()
        # Capture the complete result before releasing the Process/pipe handles.
        $exitCode = $Running.Process.ExitCode
        $out = $Running.OutTask.Result
        $err = $Running.ErrTask.Result
        return [pscustomobject]@{
            ExitCode = $exitCode
            Out      = $out
            Err      = $err
        }
    } finally {
        $Running.Process.Dispose()
    }
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
    $heldLock = New-OutboxLockPath $dir
    Write-File $heldLock '99999'   # simulate a concurrently held canonical outbox lock
    $r = Invoke-Outbox @('append', '--events', $ev, '--type', 'cohort.opened', '--batch-id', 'B-1', '--payload', '{}', '--lock-timeout-ms', '400')
    Assert-Exit $r 7 'a parallel writer that cannot take the lock is rejected (rc=7)'
    Remove-Item -LiteralPath $heldLock -Force

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
# 6b. Numeric CLI options reject syntax/range errors with rc=2 and named diagnostics.
# =============================================================================
{
    foreach ($raw in @('not-a-number', '2147483648', '0', '-1')) {
        $dir = New-TempDir; $ev = New-EventsFile $dir
        $r = Invoke-Outbox @(
            'append', '--events', $ev, '--type', 'cohort.opened', '--batch-id', 'B-1',
            '--payload', '{}', '--payload-version', $raw
        )
        Assert-Exit $r 2 "invalid --payload-version '$raw' is a usage error"
        Assert-Contains $r.Err '--payload-version' "invalid --payload-version '$raw' names the option"
    }
    $dir = New-TempDir; $ev = New-EventsFile $dir
    $maxPayloadVersion = Invoke-Outbox @(
        'append', '--events', $ev, '--type', 'cohort.opened', '--batch-id', 'B-1',
        '--payload', '{}', '--payload-version', '2147483647'
    )
    Assert-Exit $maxPayloadVersion 0 'Int32 maximum is a valid --payload-version'
    Assert-Equal ([int]::MaxValue) ([int]((Read-File $ev).Trim() | ConvertFrom-Json).payload_version) 'maximum payload_version is stored exactly'

    foreach ($raw in @('not-a-number', '2147483648', '-1')) {
        $dir = New-TempDir; $ev = New-EventsFile $dir
        $commands = @(
            @{ Name = 'append'; Args = @('append', '--events', $ev, '--type', 'cohort.opened', '--batch-id', 'B-1', '--payload', '{}') },
            @{ Name = 'verify'; Args = @('verify', '--events', $ev) },
            @{ Name = 'read'; Args = @('read', '--events', $ev) },
            @{ Name = 'metrics'; Args = @('metrics', '--events', $ev) }
        )
        foreach ($case in $commands) {
            $r = Invoke-Outbox (@($case.Args) + @('--lock-timeout-ms', $raw))
            Assert-Exit $r 2 "$($case.Name) rejects --lock-timeout-ms '$raw' with usage code 2"
            Assert-Contains $r.Err '--lock-timeout-ms' "$($case.Name) names invalid --lock-timeout-ms '$raw'"
        }
    }

    $dir = New-TempDir; $ev = New-EventsFile $dir
    $zeroTimeoutCommands = @(
        @('append', '--events', $ev, '--type', 'cohort.opened', '--batch-id', 'B-1', '--payload', '{}'),
        @('verify', '--events', $ev),
        @('read', '--events', $ev),
        @('metrics', '--events', $ev)
    )
    foreach ($commandArgs in $zeroTimeoutCommands) {
        $r = Invoke-Outbox (@($commandArgs) + @('--lock-timeout-ms', '0'))
        Assert-Exit $r 0 "zero lock timeout remains valid for $($commandArgs[0]) when the lock is free"
    }
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

    # T-321 R-05: the two reserved cohort/integration-scoped pseudo task ids ARE accepted
    # (a usage.recorded unavailable-marker for planner/merger/full_reviewer dispatch carries
    # one of these instead of a real T-id, since there is no per-task identity for it).
    $cohortId = Invoke-Outbox @('append', '--events', $ev, '--json-line', '{"schema_version":1,"event_id":"22222222-2222-2222-2222-222222222222","occurred_at":"2026-07-10T11:00:00Z","type":"usage.recorded","batch_id":"B-1","task_id":"_cohort","actor":{"kind":"tool","name":"supervisor"},"payload":{"task_id":"_cohort","role":"planner","mode":"full","attempt_number":1,"source":"claude","usage_availability":"unavailable"}}')
    Assert-Exit $cohortId 0 '_cohort is an accepted task_id form'
    $integrationId = Invoke-Outbox @('append', '--events', $ev, '--json-line', '{"schema_version":1,"event_id":"33333333-3333-3333-3333-333333333333","occurred_at":"2026-07-10T11:00:01Z","type":"usage.recorded","batch_id":"B-1","task_id":"_integration","actor":{"kind":"tool","name":"supervisor"},"payload":{"task_id":"_integration","role":"merger","mode":"full","attempt_number":1,"source":"claude","usage_availability":"unavailable"}}')
    Assert-Exit $integrationId 0 '_integration is an accepted task_id form'

    # codex.attempt non-allowlisted payload key (privacy) (rc=5)
    $cx = Invoke-Outbox @('append', '--events', $ev, '--task-id', 'T-1', '--type', 'codex.attempt', '--role', 'coder', '--mode', 'full', '--attempt-number', '1', '--payload', '{"role":"coder","mode":"full","attempt_number":1,"outcome":"success","prompt":"secret"}')
    Assert-Exit $cx 5 'codex.attempt non-allowlisted key rejected'
    Assert-Contains $cx.Err 'allowlist' 'rejection cites the privacy allowlist'

    # codex.attempt numeric fields are bounded scalars on write. duration_ms and
    # attempt_number use the non-negative Int64 domain (attempt_number is 1-based);
    # exit_code is nullable but otherwise follows the signed Int32 process-exit domain.
    $validCodexNumbers = Invoke-Outbox @('append', '--events', $ev, '--task-id', 'T-2', '--type', 'codex.attempt', '--role', 'coder', '--mode', 'full', '--attempt-number', '2', '--payload', '{"role":"coder","mode":"full","attempt_number":2,"duration_ms":99999999999999,"exit_code":-1073741819,"outcome":"failed"}')
    Assert-Exit $validCodexNumbers 0 'codex.attempt accepts Int64 duration and signed Int32 exit code'
    foreach ($case in @(
        @{ Name='non-numeric duration'; Attempt='3'; Payload='{"attempt_number":3,"duration_ms":"slow","exit_code":0}' },
        @{ Name='negative duration'; Attempt='4'; Payload='{"attempt_number":4,"duration_ms":-1,"exit_code":0}' },
        @{ Name='overflowing duration'; Attempt='5'; Payload='{"attempt_number":5,"duration_ms":9223372036854775808,"exit_code":0}' },
        @{ Name='zero attempt number'; Attempt='6'; Payload='{"attempt_number":0,"duration_ms":1,"exit_code":0}' },
        @{ Name='overflowing attempt number'; Attempt='7'; Payload='{"attempt_number":9223372036854775808,"duration_ms":1,"exit_code":0}' },
        @{ Name='non-numeric exit code'; Attempt='8'; Payload='{"attempt_number":8,"duration_ms":1,"exit_code":"failed"}' },
        @{ Name='out-of-range exit code'; Attempt='9'; Payload='{"attempt_number":9,"duration_ms":1,"exit_code":2147483648}' },
        @{ Name='duration array'; Attempt='10'; Payload='{"attempt_number":10,"duration_ms":[1],"exit_code":0}' },
        @{ Name='attempt-number array'; Attempt='11'; Payload='{"attempt_number":[1],"duration_ms":1,"exit_code":0}' },
        @{ Name='exit-code array'; Attempt='12'; Payload='{"attempt_number":12,"duration_ms":1,"exit_code":[0]}' },
        @{ Name='numeric string'; Attempt='13'; Payload='{"attempt_number":13,"duration_ms":"1","exit_code":0}' },
        @{ Name='non-integer number'; Attempt='14'; Payload='{"attempt_number":14,"duration_ms":1.5,"exit_code":0}' }
    )) {
        $badCodexNumber = Invoke-Outbox @('append', '--events', $ev, '--task-id', 'T-2', '--type', 'codex.attempt', '--role', 'coder', '--mode', 'full', '--attempt-number', $case.Attempt, '--payload', $case.Payload)
        Assert-Exit $badCodexNumber 5 "codex.attempt rejects $($case.Name)"
    }

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

    $compactCursor = Read-File $cur
    Assert-Contains $compactCursor '"delivered_ids":[]' 'cursor persists an explicit zero-length delivered_ids retention set'

    # A malformed cursor remains a hard input error and is not overwritten by read.
    $badCur = Join-Path $dir2 'bad_cursor.json'
    Write-File $badCur '{"byte_offset":'
    $badCursorBefore = Read-File $badCur
    $badCursorRead = Invoke-Outbox @('read', '--events', $ev2, '--cursor', $badCur, '--json')
    Assert-Exit $badCursorRead 3 'malformed cursor JSON remains a read failure (rc=3)'
    Assert-Equal $badCursorBefore (Read-File $badCur) 'failed cursor read does not overwrite the corrupt cursor'

    # Long-running normal stream: the cursor size stays constant with history, every
    # newly appended event is delivered exactly once, and byte_offset is monotonic.
    $longDir = New-TempDir; $longEvents = New-EventsFile $longDir
    $longCursor = Join-Path $longDir 'events_cursor.json'
    $previousOffset = 0
    $deliveredTotal = 0
    $maxCursorChars = 0
    $rounds = 32
    $eventsPerRound = 16
    for ($roundIndex = 0; $roundIndex -lt $rounds; $roundIndex++) {
        $chunk = New-Object System.Text.StringBuilder
        for ($eventIndex = 0; $eventIndex -lt $eventsPerRound; $eventIndex++) {
            $sequence = ($roundIndex * $eventsPerRound) + $eventIndex + 1
            $eventId = '00000000-0000-4000-8000-' + $sequence.ToString('D12')
            [void]$chunk.Append('{"schema_version":1,"event_id":"' + $eventId + '","occurred_at":"2026-07-29T09:00:00Z","type":"cohort.opened","batch_id":"B-long","actor":{"kind":"agent","name":"processor"},"payload":{}}' + "`n")
        }
        Append-Raw $longEvents $chunk.ToString()

        $longReadResult = Invoke-Outbox @('read', '--events', $longEvents, '--cursor', $longCursor, '--json')
        Assert-Exit $longReadResult 0 "long cursor round $roundIndex succeeds"
        if ($longReadResult.ExitCode -eq 0) {
            $longRead = $longReadResult.Out | ConvertFrom-Json
            Assert-Equal $eventsPerRound $longRead.new_count "long cursor round $roundIndex delivers every new event"
            Assert-Equal 0 $longRead.skipped_dup "long cursor round $roundIndex does not repeat a normal event"
            Assert-True ([int64]$longRead.byte_offset -gt [int64]$previousOffset) "long cursor round $roundIndex advances byte_offset monotonically"
            $previousOffset = [int64]$longRead.byte_offset
            $deliveredTotal += [int]$longRead.new_count
        }

        $longCursorText = Read-File $longCursor
        Assert-Contains $longCursorText '"delivered_ids":[]' "long cursor round $roundIndex retains zero historical ids"
        $maxCursorChars = [Math]::Max($maxCursorChars, $longCursorText.Length)
    }
    Assert-Equal ($rounds * $eventsPerRound) $deliveredTotal 'long cursor sequence delivers all appended events exactly once'
    Assert-True ($maxCursorChars -le 64) 'cursor JSON has an explicit constant-size bound independent of event history'
    $longReplay = Invoke-Outbox @('read', '--events', $longEvents, '--cursor', $longCursor, '--json')
    Assert-Exit $longReplay 0 'long cursor no-op replay succeeds'
    if ($longReplay.ExitCode -eq 0) {
        $longReplayObj = $longReplay.Out | ConvertFrom-Json
        Assert-Equal 0 $longReplayObj.new_count 'long cursor no-op replay returns no event twice'
        Assert-Equal $previousOffset ([int64]$longReplayObj.byte_offset) 'long cursor no-op replay does not move byte_offset backward'
    }

    # Explicit anomaly policy: after the compact cursor has advanced, a manually appended
    # repeat of an OLD event_id lies after byte_offset and is delivered again. Duplicates
    # that coexist inside ONE unread suffix are still suppressed by the in-memory set.
    $anomalyDir = New-TempDir; $anomalyEvents = New-EventsFile $anomalyDir
    $anomalyCursor = Join-Path $anomalyDir 'events_cursor.json'
    Invoke-Outbox @('append', '--events', $anomalyEvents, '--type', 'cohort.opened', '--batch-id', 'B-anomaly', '--payload', '{}') | Out-Null
    $anomalyLine = (Read-File $anomalyEvents).TrimEnd("`r", "`n")
    $anomalyFirst = Invoke-Outbox @('read', '--events', $anomalyEvents, '--cursor', $anomalyCursor, '--json')
    Assert-Exit $anomalyFirst 0 'anomaly fixture initial cursor read succeeds'
    Append-Raw $anomalyEvents ($anomalyLine + "`n")
    $anomalyLater = Invoke-Outbox @('read', '--events', $anomalyEvents, '--cursor', $anomalyCursor, '--json')
    Assert-Exit $anomalyLater 0 'anomalous duplicate after the saved offset is readable'
    if ($anomalyLater.ExitCode -eq 0) {
        $anomalyLaterObj = $anomalyLater.Out | ConvertFrom-Json
        Assert-Equal 1 $anomalyLaterObj.new_count 'anomalous duplicate appended in a later interval is deliberately redelivered'
        Assert-Equal 0 $anomalyLaterObj.skipped_dup 'no unbounded historical set suppresses the later anomalous duplicate'
    }
    Append-Raw $anomalyEvents ($anomalyLine + "`n" + $anomalyLine + "`n")
    $anomalySameSuffix = Invoke-Outbox @('read', '--events', $anomalyEvents, '--cursor', $anomalyCursor, '--json')
    Assert-Exit $anomalySameSuffix 0 'same-suffix anomalous duplicates are readable'
    if ($anomalySameSuffix.ExitCode -eq 0) {
        $anomalySameSuffixObj = $anomalySameSuffix.Out | ConvertFrom-Json
        Assert-Equal 1 $anomalySameSuffixObj.new_count 'one copy of a duplicate id is delivered within the current unread suffix'
        Assert-Equal 1 $anomalySameSuffixObj.skipped_dup 'second copy in the same unread suffix is still deduplicated'
    }
    $anomalyVerify = Invoke-Outbox @('verify', '--events', $anomalyEvents, '--json')
    Assert-Exit $anomalyVerify 4 'verify continues to report persistent duplicate event_ids as an anomaly'
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

    # Existing append-only streams are read-lenient. A historical Int64 duration remains
    # usable, while malformed and beyond-Int64 values are skipped instead of terminating
    # the entire metrics projection.
    $legacyDir = New-TempDir; $legacyEvents = New-EventsFile $legacyDir
    Append-Raw $legacyEvents ('{"schema_version":1,"event_id":"10000000-0000-0000-0000-000000000001","occurred_at":"2026-07-10T10:00:00Z","type":"codex.attempt","task_id":"T-1","actor":{"kind":"tool","name":"fixture"},"payload":{"duration_ms":99999999999999}}' + "`n")
    Append-Raw $legacyEvents ('{"schema_version":1,"event_id":"10000000-0000-0000-0000-000000000002","occurred_at":"2026-07-10T10:00:01Z","type":"codex.attempt","task_id":"T-1","actor":{"kind":"tool","name":"fixture"},"payload":{"duration_ms":9223372036854775808}}' + "`n")
    Append-Raw $legacyEvents ('{"schema_version":1,"event_id":"10000000-0000-0000-0000-000000000003","occurred_at":"2026-07-10T10:00:02Z","type":"codex.attempt","task_id":"T-1","actor":{"kind":"tool","name":"fixture"},"payload":{"duration_ms":"corrupt"}}' + "`n")
    Append-Raw $legacyEvents ('{"schema_version":1,"event_id":"10000000-0000-0000-0000-000000000004","occurred_at":"2026-07-10T10:00:03Z","type":"codex.attempt","task_id":"T-1","actor":{"kind":"tool","name":"fixture"},"payload":{"duration_ms":[99999999999999]}}' + "`n")
    $legacyMetrics = Invoke-Outbox @('metrics', '--events', $legacyEvents, '--json')
    Assert-Exit $legacyMetrics 0 'metrics tolerates malformed historical codex.attempt durations'
    if ($legacyMetrics.ExitCode -eq 0) {
        $legacyObj = $legacyMetrics.Out | ConvertFrom-Json
        Assert-Equal 1 $legacyObj.codex_attempt.n 'metrics skips malformed historical durations'
        Assert-Equal ([int64]99999999999999) ([int64]$legacyObj.codex_attempt.avg_ms) 'metrics preserves historical Int64 duration'
        Assert-Equal ([int64]99999999999999) ([int64]$legacyObj.codex_attempt.total_ms) 'metrics total preserves historical Int64 duration'
    }

    # A 31-day interval is greater than Int32.MaxValue milliseconds. Both timestamp-
    # derived metric paths must preserve it as Int64 instead of terminating metrics with
    # an OverflowException.
    $longDir = New-TempDir; $longEvents = New-EventsFile $longDir
    Invoke-Outbox @('append', '--events', $longEvents, '--batch-id', 'B-long', '--task-id', 'T-2147483648', '--type', 'task.captured', '--attempt', '1', '--occurred-at', '2026-01-01T00:00:00.000Z', '--payload', '{"level":"coder"}') | Out-Null
    Invoke-Outbox @('append', '--events', $longEvents, '--batch-id', 'B-long', '--type', 'cohort.round_started', '--wave', '1', '--occurred-at', '2026-01-01T00:00:00.000Z', '--payload', '{"wave":1}') | Out-Null
    Invoke-Outbox @('append', '--events', $longEvents, '--batch-id', 'B-long', '--type', 'cohort.round_closed', '--wave', '1', '--occurred-at', '2026-02-01T00:00:00.000Z', '--payload', '{"wave":1}') | Out-Null
    Invoke-Outbox @('append', '--events', $longEvents, '--task-id', 'T-2147483648', '--type', 'task.status_changed', '--from', 'опубликована', '--to', 'выполнена', '--attempt', '1', '--round', '1', '--occurred-at', '2026-02-01T00:00:00.000Z', '--payload', '{"from":"опубликована","to":"выполнена"}') | Out-Null

    $longMetrics = Invoke-Outbox @('metrics', '--events', $longEvents, '--json')
    Assert-Exit $longMetrics 0 'metrics accepts timestamp intervals beyond Int32.MaxValue ms'
    $longObj = $longMetrics.Out | ConvertFrom-Json
    Assert-Equal ([long]2678400000) ([long]$longObj.round_durations[0].duration_ms) 'metrics preserves a 31-day round duration as Int64 milliseconds'
    Assert-Equal ([long]2678400000) ([long]$longObj.critical_paths[0].critical_path_ms) 'metrics preserves a 31-day critical path as Int64 milliseconds'
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
    # dedup key: source distinguishes a codex attempt from its Claude fallback, while
    # batch_id distinguishes legitimate calls after the same task is recaptured.
    $u1 = Outbox-Id @('--type', 'usage.recorded', '--source', 'codex', '--task-id', 'T-1', '--batch-id', 'B-1', '--role', 'coder', '--mode', 'full', '--attempt-number', '1')
    $u2 = Outbox-Id @('--type', 'usage.recorded', '--source', 'claude', '--task-id', 'T-1', '--batch-id', 'B-1', '--role', 'coder', '--mode', 'full', '--attempt-number', '1')
    $u3 = Outbox-Id @('--type', 'usage.recorded', '--source', 'codex', '--task-id', 'T-1', '--batch-id', 'B-2', '--role', 'coder', '--mode', 'full', '--attempt-number', '1')
    Assert-True ($u1 -ne $u2) 'usage.recorded source is a dedup-key coordinate (codex vs claude are distinct facts)'
    Assert-True ($u1 -ne $u3) 'usage.recorded batch_id prevents collisions when a task is recaptured'
    Assert-Equal (Ref-UuidV5 'orchestra/usage.recorded/codex/T-1/B-1/coder/full/1') $u1 'usage.recorded event-id includes batch_id in its canonical UUIDv5 name'
    $missingBatchId = Invoke-Outbox @('event-id', '--type', 'usage.recorded', '--source', 'codex', '--task-id', 'T-1', '--role', 'coder', '--mode', 'full', '--attempt-number', '1')
    Assert-Exit $missingBatchId 2 'usage.recorded event-id requires --batch-id'

    $dir = New-TempDir; $ev = New-EventsFile $dir
    $payload = '{"task_id":"T-1","role":"coder","mode":"full","attempt_number":1,"source":"codex","model":"default","input_tokens":1200,"output_tokens":450,"cache_read_input_tokens":300,"cache_creation_input_tokens":0,"total_tokens":1950,"estimated":false}'
    $a1 = Invoke-Outbox @('append', '--events', $ev, '--batch-id', 'B-1', '--type', 'usage.recorded', '--source', 'codex', '--task-id', 'T-1', '--role', 'coder', '--mode', 'full', '--attempt-number', '1', '--payload', $payload)
    Assert-Exit $a1 0 'usage.recorded actual usage appends'
    $a2 = Invoke-Outbox @('append', '--events', $ev, '--batch-id', 'B-1', '--type', 'usage.recorded', '--source', 'codex', '--task-id', 'T-1', '--role', 'coder', '--mode', 'full', '--attempt-number', '1', '--payload', $payload)
    Assert-Contains $a2.Out 'skipped-duplicate' 'usage.recorded replay dedups by event_id'
    Assert-Equal 1 (Line-Count $ev) 'usage.recorded replay leaves exactly one line'

    # non-allowlisted payload key rejected on write (privacy, like codex.attempt).
    $bad = Invoke-Outbox @('append', '--events', $ev, '--batch-id', 'B-1', '--type', 'usage.recorded', '--source', 'codex', '--task-id', 'T-2', '--role', 'coder', '--mode', 'full', '--attempt-number', '1', '--payload', '{"prompt":"secret","total_tokens":5}')
    Assert-Exit $bad 5 'usage.recorded non-allowlisted key rejected'
    Assert-Contains $bad.Err 'allowlist' 'usage.recorded rejection cites the privacy allowlist'

    # scalar-shape guard: non-integer token / non-boolean estimated rejected; null is allowed.
    $nonInt = Invoke-Outbox @('append', '--events', $ev, '--batch-id', 'B-1', '--type', 'usage.recorded', '--source', 'codex', '--task-id', 'T-2', '--role', 'coder', '--mode', 'full', '--attempt-number', '1', '--payload', '{"total_tokens":"lots"}')
    Assert-Exit $nonInt 5 'usage.recorded non-integer token rejected'
    $badEst = Invoke-Outbox @('append', '--events', $ev, '--batch-id', 'B-1', '--type', 'usage.recorded', '--source', 'codex', '--task-id', 'T-2', '--role', 'coder', '--mode', 'full', '--attempt-number', '1', '--payload', '{"total_tokens":5,"estimated":"yes"}')
    Assert-Exit $badEst 5 'usage.recorded non-boolean estimated rejected'
    $badAvailability = Invoke-Outbox @('append', '--events', $ev, '--batch-id', 'B-1', '--type', 'usage.recorded', '--source', 'claude', '--task-id', 'T-2', '--role', 'coder', '--mode', 'full', '--attempt-number', '2', '--payload', '{"usage_availability":"unknown"}')
    Assert-Exit $badAvailability 5 'usage.recorded invalid usage_availability rejected'
    Assert-Contains $badAvailability.Err 'available or unavailable' 'usage_availability validation reports accepted values'
    $unavailable = Invoke-Outbox @('append', '--events', $ev, '--batch-id', 'B-1', '--type', 'usage.recorded', '--source', 'claude', '--task-id', 'T-2', '--role', 'coder', '--mode', 'full', '--attempt-number', '2', '--payload', '{"source":"claude","usage_availability":"unavailable"}')
    Assert-Exit $unavailable 0 'usage.recorded unavailable marker appends'
    $nullTok = Invoke-Outbox @('append', '--events', $ev, '--batch-id', 'B-1', '--type', 'usage.recorded', '--source', 'claude', '--task-id', 'T-2', '--role', 'reviewer', '--mode', 'full', '--attempt-number', '1', '--payload', '{"source":"claude","input_tokens":null,"total_tokens":800,"estimated":true}')
    Assert-Exit $nullTok 0 'usage.recorded null token field ("unknown for this call") is allowed'

    # forward-lenient read: a usage.recorded line with a FUTURE unknown payload key reads valid
    # without rewrite (strict write still refuses it); an OLD codex.attempt line still reads too.
    $dir2 = New-TempDir; $ev2 = New-EventsFile $dir2
    $fid = Outbox-Id @('--type', 'usage.recorded', '--source', 'codex', '--task-id', 'T-3', '--batch-id', 'B-1', '--role', 'coder', '--mode', 'full', '--attempt-number', '1')
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
# 13. operation.completed: replay-stable identity, scalar privacy contract and
#     explicit shared-operation allocation metadata for Tasks_Done metrics.
# =============================================================================
{
    $payload = '{"operation":"coding","role":"coder","mode":"full","attempt_number":1,"scope":"task","executor_kind":"model","started_at":"2026-07-27T10:00:00Z","ended_at":"2026-07-27T10:01:00Z","duration_ms":60000,"outcome":"success","shared_task_count":1}'
    $id = Outbox-Id @('--type', 'operation.completed', '--batch-id', 'B-op', '--task-id', 'T-70', '--payload', $payload)
    Assert-Equal (Ref-UuidV5 'orchestra/operation.completed/B-op/T-70/coding/coder/full/1') $id 'operation.completed canonical id carries call and task coordinates'
    $dir = New-TempDir; $ev = New-EventsFile $dir
    $ok = Invoke-Outbox @('append', '--events', $ev, '--type', 'operation.completed', '--batch-id', 'B-op', '--task-id', 'T-70', '--payload', $payload)
    Assert-Exit $ok 0 'operation.completed appends'
    $replay = Invoke-Outbox @('append', '--events', $ev, '--type', 'operation.completed', '--batch-id', 'B-op', '--task-id', 'T-70', '--payload', $payload)
    Assert-Contains $replay.Out 'skipped-duplicate' 'operation.completed replay is idempotent'
    Assert-Equal 1 (Line-Count $ev) 'operation.completed replay leaves one line'

    # Keep all event-id coordinates present so this assertion reaches strict payload
    # validation rather than correctly failing earlier in canonical-name construction.
    $missingPayload = '{"operation":"review","role":"reviewer","mode":"full","attempt_number":1}'
    $missing = Invoke-Outbox @('append', '--events', $ev, '--type', 'operation.completed', '--batch-id', 'B-op', '--task-id', 'T-71', '--payload', $missingPayload)
    Assert-Exit $missing 5 'operation.completed requires the complete timing tuple'
    Assert-Contains $missing.Err 'is required' 'missing timing tuple reports the absent required field'
    $secret = Invoke-Outbox @('append', '--events', $ev, '--type', 'operation.completed', '--batch-id', 'B-op', '--task-id', 'T-71', '--payload', ($payload.TrimEnd('}') + ',"prompt":"secret"}'))
    Assert-Exit $secret 5 'operation.completed rejects non-allowlisted sensitive fields'
    $mismatch = Invoke-Outbox @('append', '--events', $ev, '--type', 'operation.completed', '--batch-id', 'B-op', '--task-id', 'T-71', '--operation', 'review', '--payload', $payload)
    Assert-Exit $mismatch 5 'operation.completed rejects a key coordinate that disagrees with payload'
    $badShare = $payload.Replace('"shared_task_count":1', '"shared_task_count":2')
    $badTaskShare = Invoke-Outbox @('append', '--events', $ev, '--type', 'operation.completed', '--batch-id', 'B-op', '--task-id', 'T-72', '--payload', $badShare)
    Assert-Exit $badTaskShare 5 'task-scoped operation cannot divide itself across tasks'
    $badExecutor = $payload.Replace('"executor_kind":"model"', '"executor_kind":"tool"')
    $badExecutorRun = Invoke-Outbox @('append', '--events', $ev, '--type', 'operation.completed', '--batch-id', 'B-op', '--task-id', 'T-72', '--payload', $badExecutor)
    Assert-Exit $badExecutorRun 5 'known model operation rejects a non-model executor kind'
    $pseudo = Invoke-Outbox @('append', '--events', $ev, '--type', 'operation.completed', '--batch-id', 'B-op', '--task-id', '_integration', '--payload', $payload)
    Assert-Exit $pseudo 5 'operation.completed is materialized per real task, never under a pseudo id'
}.Invoke()

# =============================================================================
# 14. Coordinate payload-fallback (T-261): a CLI flag that is ALSO always present
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
# 15. Concurrent read/verify/metrics during an ACTIVE writer hold (T-294). The writer's
#     documented single-writer critical section is: take the outbox lock, THEN open
#     events.jsonl with [System.IO.FileShare]::None for the whole write (Cmd-Append).
#     Windows sharing is governed by the FIRST opener's granted share mode, so a reader
#     that only requests a more permissive share cannot itself survive that window - the
#     fix is that `read`/`verify`/`metrics` now take the SAME lock for their whole read.
#
#     This is deliberately mixed addressing: the simulated writer derives events.jsonl +
#     outbox-tx.lock from a `--work` directory exactly as append does, while every real
#     consumer is invoked with `--events <work>/events.jsonl`. The writer waits on a release
#     handshake instead of sleeping for a guessed duration. The test releases it only after
#     the real consumer reports that its atomic CreateNew probe found that SAME canonical
#     lock contended, proving the consumer reached the blocked state during FileShare.None.
# =============================================================================
{
    $holdWriterText = @'
param(
    [Parameter(Mandatory)][string]$WorkPath,
    [Parameter(Mandatory)][string]$ReadyPath,
    [Parameter(Mandatory)][string]$ReleasePath,
    [Parameter(Mandatory)][int]$TimeoutMs
)
# Mirrors `append --work X`: both paths are derived from X, then the canonical lock is
# acquired before events.jsonl is opened with FileShare.None.
$eventsPath = Join-Path $WorkPath 'events.jsonl'
$lockPath = Join-Path $WorkPath 'outbox-tx.lock'
$lockFs = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
try { $b = [System.Text.Encoding]::ASCII.GetBytes("$PID"); $lockFs.Write($b, 0, $b.Length) } finally { $lockFs.Dispose() }
try {
    $fs = [System.IO.File]::Open($eventsPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        [System.IO.File]::WriteAllText($ReadyPath, 'holding')
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        while (-not (Test-Path -LiteralPath $ReleasePath) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 20
        }
        if (-not (Test-Path -LiteralPath $ReleasePath)) { throw 'timed out waiting for reader-blocked release handshake' }
        $fs.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
        $enc = New-Object System.Text.UTF8Encoding($false)
        $line = '{"schema_version":1,"event_id":"33333333-3333-4333-8333-333333333333","occurred_at":"2026-07-24T09:00:00Z","type":"cohort.opened","batch_id":"B-hold","actor":{"kind":"agent","name":"processor"},"payload":{}}' + "`n"
        $bytes = $enc.GetBytes($line)
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush($true)
    } finally { $fs.Dispose() }
} finally {
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
}
'@

    function Wait-ForPath {
        param([string]$Path, [int]$TimeoutMs)
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        while (-not (Test-Path -LiteralPath $Path) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 20
        }
        return (Test-Path -LiteralPath $Path)
    }

    function Start-WriterHold {
        param([string]$Dir, [int]$TimeoutMs)
        $wrapper = Join-Path $Dir 'hold-writer.ps1'
        [System.IO.File]::WriteAllText($wrapper, $holdWriterText, $script:Utf8)
        $readyPath = Join-Path $Dir 'writer-ready'
        $releasePath = Join-Path $Dir 'release-writer'
        $proc = Start-Process -FilePath $script:PsExe -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapper,
            '-WorkPath', $Dir, '-ReadyPath', $readyPath, '-ReleasePath', $releasePath,
            '-TimeoutMs', "$TimeoutMs"
        ) -NoNewWindow -PassThru
        $ready = Wait-ForPath $readyPath 20000
        Assert-True $ready '[concurrency] the simulated --work writer holds both the canonical lock and FileShare.None before dispatch'
        return [pscustomobject]@{ Process = $proc; ReleasePath = $releasePath }
    }

    # The suite starts many real pwsh children before this section (including the bounded
    # cursor-history sequence). On a shared CI host, a 60-second combined writer-release +
    # consumer-completion window can expire from scheduler pressure even though neither side
    # is deadlocked. Keep each phase independently bounded, within the outer supervisor's
    # 1800-second suite deadline.
    $waitBudgetMs = 180000

    function Invoke-DuringWriterHold {
        param([string]$Command, [string]$Dir, [string[]]$ExtraArgs)
        $eventsPath = New-EventsFile $Dir
        # Exercise the real append --work resolution before mixing in an --events consumer.
        Invoke-Outbox @('append', '--work', $Dir, '--type', 'cohort.opened', '--batch-id', 'B-1', '--payload', '{}') | Out-Null
        $writer = Start-WriterHold -Dir $Dir -TimeoutMs $waitBudgetMs
        $blockedPath = Join-Path $Dir "$Command-reader-blocked"
        $running = Start-OutboxAsync -ToolArgs (@($Command, '--events', $eventsPath, '--lock-timeout-ms', "$waitBudgetMs") + $ExtraArgs) -LockWaitSignal $blockedPath

        # This signal is written only after the real consumer's CreateNew attempt failed
        # against the writer's canonical lock. Until then the writer keeps FileShare.None.
        $blocked = Wait-ForPath $blockedPath 20000
        Assert-True $blocked "[concurrency] $Command --events is confirmed blocked on the --work writer's canonical lock"
        if ($blocked) {
            Assert-True (-not $running.Process.HasExited) "[concurrency] $Command remains pending until the writer is released"
        }

        # Always release after the bounded handshake wait so a failed assertion cannot strand
        # either child. Correct implementations reach this point only after confirmed overlap.
        Write-File $writer.ReleasePath 'release'

        # Confirm the writer observed the release handshake, closed FileShare.None and removed
        # the canonical lock BEFORE starting the consumer's independent completion budget.
        # Waiting for the consumer first incorrectly charged delayed writer scheduling against
        # that budget and hid the primary timeout behind a later missing-JSON-property error.
        $writerExited = $writer.Process.WaitForExit($waitBudgetMs)
        Assert-True $writerExited '[concurrency] the simulated writer completes after the reader-blocked handshake'
        if ($writerExited) { Assert-Equal 0 $writer.Process.ExitCode '[concurrency] the simulated writer exits cleanly' }
        $writer.Process.Dispose()
        $result = Complete-OutboxAsync $running $waitBudgetMs "[concurrency] $Command"
        return $result
    }

    # -- read: blocks behind the mixed-address writer lock, then succeeds on release. --
    $dir1 = New-TempDir
    $r1 = Invoke-DuringWriterHold -Command 'read' -Dir $dir1 -ExtraArgs @()
    Assert-Exit $r1 0 'read during the writer''s active FileShare.None window blocks on the outbox lock and succeeds (no IOException)'
    Assert-NotContains $r1.Err 'cannot read' 'read never surfaces the writer''s FileShare.None window as rc=3 "cannot read"'
    Assert-Contains $r1.Out 'new=2' 'read observes both the pre-existing and the writer''s newly-appended event once released'

    # -- verify: same, and reports both committed events. --
    $dir2 = New-TempDir
    $r2 = Invoke-DuringWriterHold -Command 'verify' -Dir $dir2 -ExtraArgs @('--json')
    $r2ExitCode = [int]$r2.ExitCode
    $r2Out = [string]$r2.Out
    $r2Err = [string]$r2.Err
    Assert-Exit $r2 0 'verify during the writer''s active FileShare.None window blocks on the outbox lock and succeeds (no IOException)'
    Assert-NotContains $r2Err 'cannot read' 'verify never surfaces the writer''s FileShare.None window as rc=3 "cannot read"'
    if ($r2ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($r2Out)) {
        try {
            $vobj = $r2Out | ConvertFrom-Json
            if ($null -ne $vobj -and $vobj.PSObject.Properties.Name -contains 'events') {
                Assert-Equal 2 $vobj.events 'verify sees both events once the writer released'
            } else {
                $script:Failures.Add("FAIL - [concurrency] verify returned JSON without events (exit=[$r2ExitCode], out=[$r2Out], err=[$r2Err])")
            }
        } catch {
            $script:Failures.Add("FAIL - [concurrency] verify returned invalid JSON (exit=[$r2ExitCode], out=[$r2Out], err=[$r2Err], parse=[$($_.Exception.Message)])")
        }
    } else {
        $script:Failures.Add("FAIL - [concurrency] verify returned no JSON (exit=[$r2ExitCode], out=[$r2Out], err=[$r2Err])")
    }

    # -- metrics: same, over the shared events-common reader. --
    $dir3 = New-TempDir
    $r3 = Invoke-DuringWriterHold -Command 'metrics' -Dir $dir3 -ExtraArgs @('--json')
    $r3ExitCode = [int]$r3.ExitCode
    $r3Out = [string]$r3.Out
    $r3Err = [string]$r3.Err
    Assert-Exit $r3 0 'metrics during the writer''s active FileShare.None window blocks on the outbox lock and succeeds (no IOException)'
    Assert-NotContains $r3Err 'cannot read' 'metrics never surfaces the writer''s FileShare.None window as rc=3 "cannot read"'
    if ($r3ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($r3Out)) {
        try {
            $mobj = $r3Out | ConvertFrom-Json
            if ($null -ne $mobj -and $mobj.PSObject.Properties.Name -contains 'total_events') {
                Assert-Equal 2 $mobj.total_events 'metrics sees both events once the writer released'
            } else {
                $script:Failures.Add("FAIL - [concurrency] metrics returned JSON without total_events (exit=[$r3ExitCode], out=[$r3Out], err=[$r3Err])")
            }
        } catch {
            $script:Failures.Add("FAIL - [concurrency] metrics returned invalid JSON (exit=[$r3ExitCode], out=[$r3Out], err=[$r3Err], parse=[$($_.Exception.Message)])")
        }
    } else {
        $script:Failures.Add("FAIL - [concurrency] metrics returned no JSON (exit=[$r3ExitCode], out=[$r3Out], err=[$r3Err])")
    }

    # -- Regression guard: a foreign exclusive holder OUTSIDE the documented lock protocol
    #    (no lock file - i.e. not `append`) still correctly fails as unreadable (rc=3), so
    #    this fix targets the DOCUMENTED writer's lock+FileShare.None window specifically
    #    and does not blanket-mask every IOException as a transient write race. --
    $dir4 = New-TempDir; $ev4 = New-EventsFile $dir4
    Invoke-Outbox @('append', '--events', $ev4, '--type', 'cohort.opened', '--batch-id', 'B-1', '--payload', '{}') | Out-Null
    $rogueFs = [System.IO.File]::Open($ev4, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $rRogue = Invoke-Outbox @('verify', '--events', $ev4, '--lock-timeout-ms', '2000')
        Assert-Exit $rRogue 3 '[concurrency] a foreign exclusive holder outside the lock protocol still correctly fails as unreadable (rc=3)'
        Assert-Contains $rRogue.Err 'cannot read' 'a genuine unreadable-file error still reports "cannot read"'
    } finally { $rogueFs.Dispose() }
}.Invoke()

# =============================================================================
# 16. The outbox-specific signal contract delegates through the shared wrapper without a
#     false handshake on an uncontended lock; the successful probe is replaced by the real
#     acquisition and the command releases that lock normally.
# =============================================================================
{
    $dir = New-TempDir
    $events = New-EventsFile $dir
    $lock = New-OutboxLockPath $dir
    $signal = Join-Path $dir 'unexpected-uncontended-signal'
    $seed = Invoke-Outbox @(
        'append', '--work', $dir, '--type', 'cohort.opened',
        '--batch-id', 'B-uncontended', '--payload', '{}'
    )
    Assert-Exit $seed 0 'uncontended signal contract: seed append succeeds'

    $running = Start-OutboxAsync `
        -ToolArgs @('verify', '--events', $events, '--json', '--lock-timeout-ms', '5000') `
        -LockWaitSignal $signal
    $result = Complete-OutboxAsync $running 20000 'uncontended signal contract: verify'
    Assert-Exit $result 0 'uncontended signal contract: verify succeeds through the shared wrapper'
    Assert-True (-not (Test-Path -LiteralPath $signal)) 'uncontended signal contract: no false OUTBOX_TEST_LOCK_WAIT_SIGNAL is emitted'
    Assert-True (-not (Test-Path -LiteralPath $lock)) 'uncontended signal contract: probe and real outbox lock are both released'
}.Invoke()

# =============================================================================
# 17. append has a strict command-specific allowlist and rejects malformed argv before write.
# =============================================================================
{
    $dir = New-TempDir
    $events = New-EventsFile $dir

    $bad = Invoke-Outbox @(
        'append', '--work', $dir, '--type', 'cohort.opened',
        '--batch-id', 'B-strict', '--payload', '{}', '--event_id',
        '44444444-4444-4444-8444-444444444444'
    )
    Assert-Exit $bad 2 'append rejects misspelled event_id with usage code 2'
    Assert-Contains $bad.Err 'unknown option --event_id' 'append names the unknown event_id option'
    Assert-Equal 0 (Line-Count $events) 'rejected event_id typo does not append or generate a replacement id'

    $positional = Invoke-Outbox @(
        'append', '--work', $dir, 'positional', '--type', 'cohort.opened',
        '--batch-id', 'B-strict', '--payload', '{}'
    )
    Assert-Exit $positional 2 'append rejects positional tokens with usage code 2'
    Assert-Contains $positional.Err "unexpected argument 'positional'" 'append names the positional token'
    Assert-Equal 0 (Line-Count $events) 'rejected positional token does not mutate events'

    $duplicate = Invoke-Outbox @(
        'append', '--work', $dir, '--type', 'cohort.opened', '--type', 'cohort.closed',
        '--batch-id', 'B-strict', '--payload', '{}'
    )
    Assert-Exit $duplicate 2 'append rejects duplicate non-repeat type with usage code 2'
    Assert-Contains $duplicate.Err 'option --type may not be repeated' 'append names the duplicate type'
    Assert-Equal 0 (Line-Count $events) 'rejected duplicate option does not mutate events'

    $good = Invoke-Outbox @(
        'append', '--work', $dir, '--type', 'cohort.opened', '--batch-id', 'B-strict',
        '--payload', '{}', '--event-id', '44444444-4444-4444-8444-444444444444'
    )
    Assert-Exit $good 0 'append accepts the correctly spelled event-id option'
    Assert-Equal 1 (Line-Count $events) 'valid strict append writes exactly one event'
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
