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
      * (c) fresh lock: a lock younger than the threshold is never broken; the waiter retries
        until TimeoutMs and fails with rc=7 without disturbing the live lock.

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
# 4. Acquire-Lock end-to-end (c): a FRESH lock (younger than the threshold) is never broken;
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
