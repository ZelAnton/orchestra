<#
.SYNOPSIS
    Deterministic, offline tests (T-265) for the shared lock primitive in tools/common.ps1:
    Acquire-Lock / Release-Lock and the stale-break guard (Read-LockSnapshot /
    Test-StaleLockBreakable).

.DESCRIPTION
    Acquire-Lock is the single CreateNew file lock that mutually excludes ALL writers of
    .work/ (queue-tx, state-tx, outbox, harness). A crashed holder leaves its lock file
    behind, so a lock older than $StaleMs is treated as abandoned and broken. The danger this
    file guards is the break path stealing a LIVE lock:
      * a legitimate long transaction (Cmd-InboxDrain re-running Validate-Graph per record,
        Cmd-Append re-reading a large events.jsonl) must never be mistaken for abandoned; and
      * a TOCTOU race - the holder releasing and a NEW holder recreating the lock between the
        age check and Remove-Item - must not delete the stranger's fresh lock.

    These tests exercise the REAL dot-sourced tools/common.ps1 (not a copy of the logic, per
    KB K-041): they load the library in-process and drive the actual Acquire-Lock /
    Read-LockSnapshot / Test-StaleLockBreakable. Content/PID comparison is Ordinal, never via
    the path-comparer (KB K-033). Nothing here touches this repository's own .work/ and
    nothing reaches the network; all fixtures live under a throwaway temp dir.

    Covered (per T-265's acceptance criteria):
      * (a) classic stale-break: a lock older than the threshold whose identity does not
        change is broken and the caller acquires it (existing recovery behaviour intact).
      * (b) TOCTOU: a lock marked old but "recreated" between the age check and removal - with
        a new creation stamp, OR (NTFS tunneling) a preserved stamp but a different recorded
        PID - is NOT breakable; an unchanged old lock still IS (guard does not over-block).
      * (c) release ownership: a stale former holder cannot remove a lock recreated by another
        PID; the current owner still removes its own lock.
      * (d) fresh lock: a lock younger than the threshold is never broken; the waiter retries
        until TimeoutMs and fails with rc=7 without disturbing the live lock.
      * (e) probe handoff: concurrent test-signalled callers starting without a pre-existing
        lock never unlink a replacement PID-bearing lock or overlap their critical sections.

.EXAMPLE
    pwsh -File tests/test-common.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# Load the REAL shared library in-process (K-041: no copied logic).
. (Join-Path $PSScriptRoot '..\tools\common.ps1')

$script:Ascii = [System.Text.Encoding]::ASCII
$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:TempDirs = [System.Collections.Generic.List[string]]::new()

function New-TempDir {
    $d = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'cmn-t-' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($d)
    $script:TempDirs.Add($d)
    return $d
}
function New-LockPath { param([string]$Dir) return (Join-Path $Dir ('lock-' + [guid]::NewGuid().ToString('N'))) }

# Writes a lock file whose contents are $Content (ASCII, exactly as a real holder writes its
# PID) and, if -AgeSeconds is given, whose CreationTimeUtc is backdated so the lock reads as
# that old. Returns the path.
function Write-LockFile {
    param([string]$Path, [string]$Content, [Nullable[int]]$AgeSeconds = $null)
    [System.IO.File]::WriteAllText($Path, $Content, $script:Ascii)
    if ($null -ne $AgeSeconds) {
        [System.IO.File]::SetCreationTimeUtc($Path, [DateTime]::UtcNow.AddSeconds(-[int]$AgeSeconds))
    }
    return $Path
}
function Read-LockContent { param([string]$Path) if (Test-Path -LiteralPath $Path) { return [System.IO.File]::ReadAllText($Path, $script:Ascii) } else { return $null } }
# A snapshot as Read-LockSnapshot produces one, built directly so the guard's decision can be
# probed for exact (ticks, age, content) combinations without depending on filesystem
# timestamp-set fidelity. Test-StaleLockBreakable under test is still the real dot-sourced one.
function New-Snap { param([long]$Ticks, [double]$AgeMs, [string]$Content) return [pscustomobject]@{ CreationTicks = $Ticks; AgeMs = $AgeMs; Content = $Content } }

function Assert-True { param([bool]$Cond, [string]$Msg) if (-not $Cond) { $script:Failures.Add("FAIL - $Msg") } }
function Assert-False { param([bool]$Cond, [string]$Msg) if ($Cond) { $script:Failures.Add("FAIL - $Msg") } }
function Assert-Equal { param($Expected, $Actual, [string]$Msg) if ($Expected -ne $Actual) { $script:Failures.Add("FAIL - ${Msg}: expected [$Expected], got [$Actual]") } }

# =============================================================================
# 1. Read-LockSnapshot: reads the recorded PID and age from disk; $null when unreadable.
# =============================================================================
{
    $dir = New-TempDir
    $p = New-LockPath $dir
    Write-LockFile -Path $p -Content '13579' -AgeSeconds 600 | Out-Null
    $snap = Read-LockSnapshot $p
    Assert-True ($null -ne $snap) 'Read-LockSnapshot returns a snapshot for an existing lock file'
    Assert-Equal '13579' $snap.Content 'snapshot Content is the recorded PID text (ASCII round-trip)'
    Assert-True ($snap.AgeMs -gt 60000) 'snapshot AgeMs reflects the backdated creation time (older than 60s)'

    $fresh = New-LockPath $dir
    Write-LockFile -Path $fresh -Content '2468' | Out-Null
    $snapFresh = Read-LockSnapshot $fresh
    Assert-True ($null -ne $snapFresh) 'Read-LockSnapshot returns a snapshot for a just-created lock file'
    Assert-True ($snapFresh.AgeMs -lt 60000) 'a just-created lock reads as fresh (age below the stale threshold)'

    $missing = New-LockPath $dir
    Assert-True ($null -eq (Read-LockSnapshot $missing)) 'Read-LockSnapshot returns $null for a missing lock file'
}.Invoke()

# =============================================================================
# 2. Test-StaleLockBreakable: the break decision that closes the TOCTOU window.
#    (b) recreated -> NOT breakable; unchanged old lock -> breakable.
# =============================================================================
{
    $old = New-Snap -Ticks 1000 -AgeMs 600000 -Content '111'   # decided: genuinely old, PID 111

    # Unchanged old lock: same identity in both reads -> breakable (no over-blocking; keeps
    # the classic stale-break working so criterion (a) does not regress).
    Assert-True (Test-StaleLockBreakable -Decided $old -Confirm (New-Snap -Ticks 1000 -AgeMs 600000 -Content '111') -StaleMs 60000) `
        'unchanged old lock (same creation stamp AND same PID in both reads) IS breakable'

    # TOCTOU, fresh recreation: a new holder recreated the lock with a NEW creation stamp
    # (age now small) -> must NOT be broken.
    Assert-False (Test-StaleLockBreakable -Decided $old -Confirm (New-Snap -Ticks 2000 -AgeMs 5 -Content '222') -StaleMs 60000) `
        'lock recreated with a new creation stamp between the two reads is NOT breakable'

    # TOCTOU, NTFS tunneling: recreated within the tunneling window so the creation stamp is
    # PRESERVED (same ticks, still reads old), but the recorded PID differs -> the PID guard
    # still refuses to delete the stranger's fresh lock.
    Assert-False (Test-StaleLockBreakable -Decided $old -Confirm (New-Snap -Ticks 1000 -AgeMs 600000 -Content '222') -StaleMs 60000) `
        'lock recreated with a tunneled (preserved) creation stamp but a different PID is NOT breakable'

    # Confirm read failed (file vanished in the gap) -> refuse to break.
    Assert-False (Test-StaleLockBreakable -Decided $old -Confirm $null -StaleMs 60000) `
        'a lock that vanished by confirm time is NOT breakable'
    Assert-False (Test-StaleLockBreakable -Decided $null -Confirm $old -StaleMs 60000) `
        'a lock unreadable at decision time is NOT breakable'

    # Not (yet) stale: decision snapshot is younger than the threshold -> never broken.
    Assert-False (Test-StaleLockBreakable -Decided (New-Snap -Ticks 1000 -AgeMs 5 -Content '111') -Confirm (New-Snap -Ticks 1000 -AgeMs 5 -Content '111') -StaleMs 60000) `
        'a lock younger than the stale threshold is NOT breakable'

    # PID comparison is Ordinal (K-033): a content difference that only case-folding would
    # collapse is still a difference, so the lock is not broken.
    Assert-False (Test-StaleLockBreakable -Decided (New-Snap -Ticks 1000 -AgeMs 600000 -Content 'abc') -Confirm (New-Snap -Ticks 1000 -AgeMs 600000 -Content 'ABC') -StaleMs 60000) `
        'recorded-PID comparison is Ordinal (case-sensitive), so differing content is NOT breakable'
}.Invoke()

# =============================================================================
# 3. Acquire-Lock end-to-end (a): a genuinely stale lock (old stamp, stable identity) is
#    broken and this process acquires it.
# =============================================================================
{
    $dir = New-TempDir
    $p = New-LockPath $dir
    Write-LockFile -Path $p -Content '99999' -AgeSeconds 600 | Out-Null   # crashed holder, PID 99999
    $threw = $false
    try { Acquire-Lock -LockPath $p -TimeoutMs 5000 -StaleMs 60000 } catch { $threw = $true }
    Assert-False $threw 'Acquire-Lock breaks a genuinely stale lock and returns without error'
    Assert-True (Test-Path -LiteralPath $p) 'the lock file exists after acquisition'
    Assert-Equal ([string]$PID) (Read-LockContent $p) 'the lock now records THIS process PID (it was re-created by us, not the stale holder)'
    Release-Lock $p
    Assert-False (Test-Path -LiteralPath $p) 'Release-Lock removes the lock file'
}.Invoke()

# =============================================================================
# 4. Release-Lock owner guard: a former holder must not remove a lock that was broken and
#    recreated by another process. The current holder still releases normally.
# =============================================================================
{
    $dir = New-TempDir
    $p = New-LockPath $dir
    Write-LockFile -Path $p -Content '99999' | Out-Null
    Release-Lock $p 3>$null
    Assert-True (Test-Path -LiteralPath $p) 'Release-Lock preserves a lock owned by another PID'
    Assert-Equal '99999' (Read-LockContent $p) 'Release-Lock leaves the foreign owner identity unchanged'

    Write-LockFile -Path $p -Content ([string]$PID) | Out-Null
    Release-Lock $p
    Assert-False (Test-Path -LiteralPath $p) 'Release-Lock removes a lock owned by this process'
}.Invoke()

# =============================================================================
# 5. Acquire-Lock end-to-end (d): a FRESH lock (younger than the threshold) is never broken;
#    the waiter retries until TimeoutMs and fails with rc=7, leaving the live lock intact.
# =============================================================================
{
    $dir = New-TempDir
    $p = New-LockPath $dir
    Write-LockFile -Path $p -Content '99999' | Out-Null   # fresh live lock held by "PID 99999"
    $code = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Acquire-Lock -LockPath $p -TimeoutMs 250 -StaleMs 60000
    } catch {
        $m = [string]$_.Exception.Message   # coded error: "<ErrPrefix>|7|could not acquire ..."
        $parts = $m -split '\|', 3
        if ($parts.Count -ge 2) { $code = $parts[1] }
    }
    $sw.Stop()
    Assert-Equal '7' $code 'a fresh (non-stale) held lock makes the waiter fail with rc=7 (could not acquire)'
    Assert-True ($sw.ElapsedMilliseconds -ge 200) 'the waiter actually retried up to about TimeoutMs before giving up (did not break the fresh lock immediately)'
    Assert-True (Test-Path -LiteralPath $p) 'the fresh live lock is still present (was not broken)'
    Assert-Equal '99999' (Read-LockContent $p) 'the fresh live lock still records the original holder PID (untouched)'
}.Invoke()

# =============================================================================
# 6. Persistent non-contention I/O failures surface immediately with their real diagnostic.
# =============================================================================
{
    $dir = New-TempDir
    $missingParent = Join-Path $dir 'parent-does-not-exist'
    $p = Join-Path $missingParent 'lock'
    $message = ''
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try { Acquire-Lock -LockPath $p -TimeoutMs 30000 -StaleMs 60000 }
    catch { $message = [string]$_.Exception.Message }
    $sw.Stop()
    Assert-True ($message.Length -gt 0) 'Acquire-Lock surfaces the underlying missing-parent I/O exception'
    Assert-False ($message -match 'held by another writer') 'missing parent is not misreported as lock contention'
    Assert-True ($sw.ElapsedMilliseconds -lt 1000) 'persistent missing-parent failure returns quickly instead of waiting for the lock timeout'
    Assert-False (Test-Path -LiteralPath $p) 'failed Acquire-Lock does not materialize a lock file'
}.Invoke()

# =============================================================================
# 7. Acquire-LockWithTestSignal: the shared wrapper signals only observed contention,
#    removes a successful probe before the real acquisition, and accepts an explicit
#    per-tool environment-variable name.
# =============================================================================
{
    $envName = 'COMMON_TEST_LOCK_WAIT_SIGNAL_' + [guid]::NewGuid().ToString('N')
    $oldSignalValue = [Environment]::GetEnvironmentVariable($envName)
    try {
        # No contention: the CreateNew probe succeeds, is disposed/removed, and the delegated
        # Acquire-Lock creates a fresh PID-bearing lock. If the probe were left behind this
        # call would time out instead of returning.
        $dir = New-TempDir
        $p = New-LockPath $dir
        $signal = Join-Path $dir 'no-contention.signal'
        [Environment]::SetEnvironmentVariable($envName, $signal)
        $threw = $false
        try {
            Acquire-LockWithTestSignal `
                -LockPath $p `
                -TestSignalEnvName $envName `
                -TimeoutMs 1000 `
                -StaleMs 60000
        } catch {
            $threw = $true
        }
        Assert-False $threw 'test-signal wrapper removes its successful probe before delegating to Acquire-Lock'
        Assert-False (Test-Path -LiteralPath $signal) 'successful probe does not emit a false contention signal'
        Assert-Equal ([string]$PID) (Read-LockContent $p) 'delegated Acquire-Lock replaces the probe with the real PID-bearing lock'
        Release-Lock $p
        Assert-False (Test-Path -LiteralPath $p) 'real lock acquired after a successful probe releases normally'

        # Real contention: the failed CreateNew probe observes the existing lock, emits the
        # configured signal, and then delegates to the usual bounded Acquire-Lock path.
        $held = New-LockPath $dir
        Write-LockFile -Path $held -Content '99999' | Out-Null
        $contendedSignal = Join-Path $dir 'nested\contended.signal'
        [Environment]::SetEnvironmentVariable($envName, $contendedSignal)
        $code = $null
        try {
            Acquire-LockWithTestSignal `
                -LockPath $held `
                -TestSignalEnvName $envName `
                -TimeoutMs 250 `
                -StaleMs 60000
        } catch {
            $parts = ([string]$_.Exception.Message) -split '\|', 3
            if ($parts.Count -ge 2) { $code = $parts[1] }
        }
        Assert-Equal '7' $code 'contended wrapper delegates to Acquire-Lock and preserves its timeout failure'
        Assert-True (Test-Path -LiteralPath $contendedSignal) 'failed CreateNew probe emits the configured contention signal'
        if (Test-Path -LiteralPath $contendedSignal) {
            Assert-Equal 'contended' ([System.IO.File]::ReadAllText($contendedSignal)) 'contention signal carries the established marker'
        }
        Assert-Equal '99999' (Read-LockContent $held) 'contention probe does not disturb the existing lock owner'

        # A CreateNew IOException without an extant target (missing parent) is an I/O failure,
        # not contention. The wrapper must not lie to concurrency tests about reaching a held
        # lock, while Acquire-Lock still surfaces the underlying failure.
        $missingParentLock = Join-Path (Join-Path $dir 'missing-parent') 'lock'
        $falseSignal = Join-Path $dir 'false-contention.signal'
        [Environment]::SetEnvironmentVariable($envName, $falseSignal)
        $message = ''
        try {
            Acquire-LockWithTestSignal `
                -LockPath $missingParentLock `
                -TestSignalEnvName $envName `
                -TimeoutMs 1000 `
                -StaleMs 60000
        } catch {
            $message = [string]$_.Exception.Message
        }
        Assert-True ($message.Length -gt 0) 'non-contention probe failure is still surfaced by Acquire-Lock'
        Assert-False (Test-Path -LiteralPath $falseSignal) 'non-contention CreateNew failure does not emit a false signal'
    } finally {
        [Environment]::SetEnvironmentVariable($envName, $oldSignalValue)
    }
}.Invoke()

# =============================================================================
# 8. Acquire-LockWithTestSignal probe handoff: several processes start without a
#    pre-existing lock and repeatedly race through the successful-probe path. Probe cleanup
#    must never unlink another process's replacement PID-bearing lock, the current owner must
#    still release while waiters take snapshot reads, and the resulting critical sections
#    must remain mutually exclusive.
# =============================================================================
{
    $dir = New-TempDir
    $p = New-LockPath $dir
    $start = Join-Path $dir 'start-at-ticks'
    $active = Join-Path $dir 'critical-section-active'
    $leaderHeld = Join-Path $dir 'leader-holds-real-lock'
    $firstPeerSignal = Join-Path $dir 'worker-1-contended'
    $workerScript = Join-Path $dir 'probe-handoff-worker.ps1'
    $commonPath = Join-Path $PSScriptRoot '..\tools\common.ps1'
    $workerCount = 6
    $iterations = 60
    $periodTicks = [TimeSpan]::FromMilliseconds(25).Ticks
    $workerText = @'
param(
    [Parameter(Mandatory)][string]$CommonPath,
    [Parameter(Mandatory)][string]$LockPath,
    [Parameter(Mandatory)][string]$StartPath,
    [Parameter(Mandatory)][string]$ActivePath,
    [Parameter(Mandatory)][string]$LeaderHeldPath,
    [Parameter(Mandatory)][string]$FirstPeerSignalPath,
    [Parameter(Mandatory)][string]$SignalPath,
    [Parameter(Mandatory)][string]$ResultPath,
    [Parameter(Mandatory)][int]$WorkerIndex,
    [Parameter(Mandatory)][int]$Iterations,
    [Parameter(Mandatory)][long]$PeriodTicks
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. $CommonPath
$envName = 'COMMON_HANDOFF_SIGNAL_' + [guid]::NewGuid().ToString('N')
[Environment]::SetEnvironmentVariable($envName, $SignalPath)
$ascii = [System.Text.Encoding]::ASCII
$activeHandle = $null

try {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (-not (Test-Path -LiteralPath $StartPath)) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'timed out waiting for the start barrier' }
        Start-Sleep -Milliseconds 10
    }
    $startTicks = [long]([System.IO.File]::ReadAllText($StartPath, $ascii))

    for ($i = 0; $i -lt $Iterations; $i++) {
        $targetTicks = $startTicks + ($i * $PeriodTicks)
        while ([DateTime]::UtcNow.Ticks -lt $targetTicks) {
            [System.Threading.Thread]::SpinWait(200)
        }

        # Make the first probe-contention handshake deterministic without an artificial
        # pre-created lock: worker 0 starts from an empty path, acquires the real PID-bearing
        # lock through the wrapper, and peers enter their probes only after that ownership is
        # published. The leader does not release until worker 1's wrapper has emitted its
        # real contention signal.
        if ($i -eq 0 -and $WorkerIndex -ne 0) {
            $leaderDeadline = [DateTime]::UtcNow.AddSeconds(20)
            while (-not (Test-Path -LiteralPath $LeaderHeldPath)) {
                if ([DateTime]::UtcNow -gt $leaderDeadline) { throw 'timed out waiting for the leader to acquire the real lock' }
                Start-Sleep -Milliseconds 10
            }
        }

        Acquire-LockWithTestSignal `
            -LockPath $LockPath `
            -TestSignalEnvName $envName `
            -TimeoutMs 30000 `
            -StaleMs 60000
        try {
            $owner = [System.IO.File]::ReadAllText($LockPath, $ascii)
            if (-not [string]::Equals($owner, [string]$PID, [System.StringComparison]::Ordinal)) {
                throw "foreign lock owner observed after acquisition: expected $PID, got $owner"
            }
            if ($i -eq 0 -and $WorkerIndex -eq 0) {
                [System.IO.File]::WriteAllText($LeaderHeldPath, 'held', $ascii)
                $peerDeadline = [DateTime]::UtcNow.AddSeconds(20)
                while (-not (Test-Path -LiteralPath $FirstPeerSignalPath)) {
                    if ([DateTime]::UtcNow -gt $peerDeadline) { throw 'timed out waiting for a peer probe-contention signal' }
                    Start-Sleep -Milliseconds 10
                }
            }
            try {
                $activeHandle = [System.IO.FileStream]::new(
                    $ActivePath,
                    [System.IO.FileMode]::CreateNew,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::None
                )
            } catch [System.IO.IOException] {
                throw 'critical sections overlapped'
            }
            $bytes = $ascii.GetBytes([string]$PID)
            $activeHandle.Write($bytes, 0, $bytes.Length)
            $activeHandle.Flush()
            Start-Sleep -Milliseconds 3
        } finally {
            if ($null -ne $activeHandle) {
                $activeHandle.Dispose()
                $activeHandle = $null
                Remove-Item -LiteralPath $ActivePath -Force -ErrorAction SilentlyContinue
            }
            Release-Lock $LockPath
        }
    }

    [System.IO.File]::WriteAllText($ResultPath, 'ok', $ascii)
    exit 0
} catch {
    [System.IO.File]::WriteAllText($ResultPath, [string]$_.Exception.Message, $ascii)
    exit 1
} finally {
    [Environment]::SetEnvironmentVariable($envName, $null)
}
'@
    [System.IO.File]::WriteAllText($workerScript, $workerText, (New-Object System.Text.UTF8Encoding($false)))

    $psExe = (Get-Process -Id $PID).Path
    $workers = @()
    for ($i = 0; $i -lt $workerCount; $i++) {
        $signal = Join-Path $dir "worker-$i-contended"
        $result = Join-Path $dir "worker-$i-result"
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $psExe
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        foreach ($arg in @(
                '-NoProfile', '-NonInteractive', '-File', $workerScript,
                '-CommonPath', $commonPath,
                '-LockPath', $p,
                '-StartPath', $start,
                '-ActivePath', $active,
                '-LeaderHeldPath', $leaderHeld,
                '-FirstPeerSignalPath', $firstPeerSignal,
                '-SignalPath', $signal,
                '-ResultPath', $result,
                '-WorkerIndex', [string]$i,
                '-Iterations', [string]$iterations,
                '-PeriodTicks', [string]$periodTicks)) {
            [void]$psi.ArgumentList.Add($arg)
        }
        $proc = [System.Diagnostics.Process]::Start($psi)
        $workers += [pscustomobject]@{
            Process = $proc
            OutTask = $proc.StandardOutput.ReadToEndAsync()
            ErrTask = $proc.StandardError.ReadToEndAsync()
            Signal = $signal
            Result = $result
        }
    }

    # Give every child time to load common.ps1, then publish one future timestamp so their
    # first (and subsequent periodic) acquisitions contend without a pre-created lock.
    Start-Sleep -Milliseconds 500
    $startTicks = [DateTime]::UtcNow.AddSeconds(1).Ticks
    [System.IO.File]::WriteAllText($start, [string]$startTicks, $script:Ascii)

    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    foreach ($worker in $workers) {
        $remainingMs = [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if (-not $worker.Process.WaitForExit($remainingMs)) {
            try { $worker.Process.Kill($true) } catch { }
            Assert-True $false 'probe handoff worker finishes within the bounded deadline'
            continue
        }
        $worker.Process.WaitForExit()
        $out = $worker.OutTask.GetAwaiter().GetResult()
        $err = $worker.ErrTask.GetAwaiter().GetResult()
        $detail = if (Test-Path -LiteralPath $worker.Result) {
            [System.IO.File]::ReadAllText($worker.Result, $script:Ascii)
        } else {
            "missing result; stdout=[$($out.Trim())] stderr=[$($err.Trim())]"
        }
        Assert-Equal 0 $worker.Process.ExitCode "probe handoff worker succeeds ($detail)"
        Assert-Equal 'ok' $detail 'probe handoff worker observes only its own PID-bearing lock and no overlap'
        $worker.Process.Dispose()
    }

    Assert-True (@($workers | Where-Object { Test-Path -LiteralPath $_.Signal }).Count -gt 0) `
        'simultaneous test-signalled callers actually observe contention during probe handoff'
    Assert-False (Test-Path -LiteralPath $p) 'all probe-handoff workers release the shared PID-bearing lock'
    Assert-False (Test-Path -LiteralPath $active) 'no critical-section sentinel remains after the concurrent handoff test'
}.Invoke()

# =============================================================================
# 9. Parse-IntOpt: strict decimal syntax, Int32 range, defaults and minimum bounds.
# =============================================================================
{
    $script:ErrPrefix = 'CMNERR'

    $script:opts = @{}
    Assert-Equal 17 (Parse-IntOpt 'count' 17 0) 'omitted integer option returns its default'

    $script:opts = @{ count = '2147483647' }
    Assert-Equal ([int]::MaxValue) (Parse-IntOpt 'count' 0 0) 'Int32 maximum is accepted'

    $script:opts = @{ count = '-2147483648' }
    Assert-Equal ([int]::MinValue) (Parse-IntOpt 'count' 0 ([int]::MinValue)) 'Int32 minimum is accepted when the caller permits it'

    foreach ($case in @(
            @{ Raw = 'not-a-number'; Pattern = '--count must be an integer' },
            @{ Raw = '2147483648'; Pattern = '--count must be an integer in the Int32 range' },
            @{ Raw = '-2147483649'; Pattern = '--count must be an integer in the Int32 range' },
            @{ Raw = '-1'; Pattern = '--count must be >= 0' })) {
        $script:opts = @{ count = $case.Raw }
        $message = ''
        try { [void](Parse-IntOpt 'count' 0 0) } catch { $message = [string]$_.Exception.Message }
        Assert-True ($message -like "CMNERR|2|*$($case.Pattern)*") "invalid integer '$($case.Raw)' is a named usage error"
    }
}.Invoke()

# =============================================================================
# Report + cleanup
# =============================================================================
foreach ($d in $script:TempDirs) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }

if ($script:Failures.Count -eq 0) {
    Write-Host "OK - all common (lock primitive) tests passed."
    exit 0
}
Write-Host "FAILED - $($script:Failures.Count) assertion(s):"
foreach ($f in $script:Failures) { Write-Host "  $f" }
exit 1
