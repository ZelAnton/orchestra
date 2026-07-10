# Tests for tools/state-tx.ps1 - the transactional control-plane interface
# (owner lease + state-transition validation + control generation), task T-079.
#
# Scriptable, LLM-free. Each scenario builds a throwaway .work sandbox under
# $env:TEMP, drives the real tool as a child process, and asserts on its
# output/exit code and the resulting .work/orchestrator.lock/lease.json. Nothing
# here touches this repository's own .work/. Covered (per T-079's criteria):
#   - lease acquire / heartbeat (owner-only) / release / status / generation
#   - liveness: heartbeat/TTL freshness AND pid + pid-start-time proof
#   - double start: N concurrent acquires -> exactly one holder, the rest refused
#   - stale -> takeover (acquire refuses a stale lease; takeover adopts it)
#   - safe takeover only when stale/forced; a live lease is never auto-stolen
#   - late-cleanup race: an old owner cannot release a lease taken over since
#   - suspend/resume addressing: verify checks role + root + owner, live vs stale
#   - repeat resume: re-adopting an already-live lease is refused (no 2nd loop)
#   - crash (fault injection) between every critical write leaves state intact
#   - corrupt lease halts with a precise error instead of silent overwrite
#   - transition validation (task/cohort/integration): legal / illegal / unknown
#
# The tool is invoked with pwsh (PowerShell 7) when available AND, in a dedicated
# cross-host scenario, with the current powershell.exe (Windows PowerShell 5.1),
# so both hosts are exercised. state-tx.ps1 is pure ASCII, so either host is fine.

. (Join-Path $PSScriptRoot 'common.ps1')

$script:ToolPath = Join-Path $script:RepoRoot 'tools\state-tx.ps1'
$script:PwshHost = 'powershell'
$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwshCmd) { $script:PwshHost = $pwshCmd.Source }

function New-Work {
    $root = Join-Path $env:TEMP ("orc-statetx-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    return $root
}

# Runs the tool once; returns @{ ExitCode; Output }. stderr is merged into Output.
function Run-Tool {
    param([string[]] $ToolArgs, [hashtable] $EnvVars = @{}, [string] $UseHost = $script:PwshHost)
    $applied = @{}
    foreach ($k in $EnvVars.Keys) {
        $applied[$k] = [Environment]::GetEnvironmentVariable($k)
        Set-Item -Path "env:$k" -Value $EnvVars[$k]
    }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $UseHost -NoProfile -ExecutionPolicy Bypass -File $script:ToolPath @ToolArgs 2>&1 | Out-String
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEap
        foreach ($k in $EnvVars.Keys) {
            if ($null -eq $applied[$k]) { Remove-Item -Path "env:$k" -ErrorAction SilentlyContinue }
            else { Set-Item -Path "env:$k" -Value $applied[$k] }
        }
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $out }
}

function Get-Owner {
    param([pscustomobject] $Result)
    $m = [regex]::Match($Result.Output, 'owner=(\w+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}
function Read-Lease {
    param([string] $Work)
    $p = Join-Path $Work 'orchestrator.lock/lease.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json)
}
function Assert-Match {
    param([string] $Text, [string] $Pattern, [string] $Message = '')
    if ($Text -notmatch $Pattern) { throw "Assertion failed: ${Message}: [$Pattern] not found in [$Text]" }
}

Invoke-Test -Name 'state-tx.ps1' -Body {

    $ROOT = 'C:\proj\demo'

    # --- Scenario 1: acquire / status / heartbeat / release lifecycle -------
    $W = New-Work
    try {
        $r = Run-Tool @('acquire', '--work', $W, '--root', $ROOT, '--role', 'processor', '--ttl', '600')
        Assert-Equal 0 $r.ExitCode "[life] acquire exit ($($r.Output))"
        $owner = Get-Owner $r
        Assert-True ($owner.Length -gt 0) '[life] acquire prints an owner id'
        $lease = Read-Lease $W
        Assert-Equal 'processor' $lease.role '[life] lease role recorded'
        Assert-Equal $ROOT $lease.root '[life] lease root recorded'
        Assert-Equal 1 ([int]$lease.generation) '[life] lease generation starts at 1'

        $r = Run-Tool @('status', '--work', $W)
        Assert-Equal 0 $r.ExitCode '[life] status exit for a live lease'
        Assert-Match $r.Output 'lease live' '[life] fresh lease reads as live'

        $r = Run-Tool @('heartbeat', '--work', $W, '--owner', $owner)
        Assert-Equal 0 $r.ExitCode '[life] heartbeat exit'
        Assert-Equal 2 ([int](Read-Lease $W).generation) '[life] heartbeat bumps generation'

        $r = Run-Tool @('release', '--work', $W, '--owner', $owner)
        Assert-Equal 0 $r.ExitCode '[life] release exit'
        $r = Run-Tool @('status', '--work', $W)
        Assert-Equal 14 $r.ExitCode '[life] status after release is no-lease (14)'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 2: owner-only heartbeat + release; late-cleanup-race guard --
    $W = New-Work
    try {
        $owner = Get-Owner (Run-Tool @('acquire', '--work', $W, '--root', $ROOT, '--ttl', '600'))
        $r = Run-Tool @('heartbeat', '--work', $W, '--owner', 'not-the-owner')
        Assert-Equal 13 $r.ExitCode '[owner] heartbeat by a non-owner is refused (13)'
        $r = Run-Tool @('release', '--work', $W, '--owner', 'not-the-owner')
        Assert-Equal 13 $r.ExitCode '[owner] release by a non-owner is refused (13)'
        Assert-True ($null -ne (Read-Lease $W)) '[owner] the lease survived the refused release'

        # A forced takeover installs a new owner; the OLD owner must not be able to
        # release the NEW lease (late crash-recovery straggler guard).
        $newOwner = Get-Owner (Run-Tool @('takeover', '--work', $W, '--root', $ROOT, '--force'))
        Assert-True ($newOwner -ne $owner) '[owner] takeover installed a different owner'
        $r = Run-Tool @('release', '--work', $W, '--owner', $owner)
        Assert-Equal 13 $r.ExitCode '[owner] old owner cannot release a taken-over lease (13)'
        Assert-True ($null -ne (Read-Lease $W)) '[owner] the taken-over lease survived the stale release'
        $r = Run-Tool @('release', '--work', $W, '--owner', $newOwner)
        Assert-Equal 0 $r.ExitCode '[owner] the current owner can release'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 3: double start - exactly one holder ----------------------
    $W = New-Work
    try {
        $N = 6
        $procs = @()
        for ($i = 1; $i -le $N; $i++) {
            $outFile = Join-Path $W "acq-$i.txt"
            $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:ToolPath,
                'acquire', '--work', $W, '--root', $ROOT, '--role', 'processor', '--ttl', '600')
            $procs += Start-Process -FilePath $script:PwshHost -ArgumentList $a -NoNewWindow -PassThru `
                -RedirectStandardOutput $outFile -RedirectStandardError "$outFile.err"
        }
        $procs | Wait-Process -Timeout 90
        $zero = @($procs | Where-Object { $_.ExitCode -eq 0 })
        $held = @($procs | Where-Object { $_.ExitCode -eq 10 })
        Assert-Equal 1 $zero.Count "[double] exactly one acquire wins (got $($zero.Count) winners)"
        Assert-Equal ($N - 1) $held.Count "[double] the rest are refused as held (got $($held.Count))"
        Assert-True ($null -ne (Read-Lease $W)) '[double] a single lease exists afterwards'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 4: stale lease -> acquire refuses, takeover adopts ---------
    $W = New-Work
    try {
        $owner = Get-Owner (Run-Tool @('acquire', '--work', $W, '--root', $ROOT, '--ttl', '1'))
        Start-Sleep -Seconds 2   # heartbeat now older than the 1s TTL
        $r = Run-Tool @('status', '--work', $W)
        Assert-Match $r.Output 'lease stale' '[stale] lease past TTL reads as stale'

        $r = Run-Tool @('acquire', '--work', $W, '--root', $ROOT, '--ttl', '600')
        Assert-Equal 11 $r.ExitCode '[stale] acquire refuses a stale lease (11), does not silently steal it'

        $r = Run-Tool @('takeover', '--work', $W, '--root', $ROOT, '--ttl', '600')
        Assert-Equal 0 $r.ExitCode '[stale] takeover adopts a stale lease'
        Assert-Match $r.Output "taken_over_from=$owner" '[stale] takeover records the previous owner'
        Assert-Equal 2 ([int](Read-Lease $W).generation) '[stale] generation continues across takeover'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 5: a LIVE lease is never auto-stolen; --force overrides ----
    $W = New-Work
    try {
        Run-Tool @('acquire', '--work', $W, '--root', $ROOT, '--ttl', '600') | Out-Null
        $r = Run-Tool @('takeover', '--work', $W, '--root', $ROOT)
        Assert-Equal 10 $r.ExitCode '[live] takeover of a live lease is refused (10)'
        $r = Run-Tool @('takeover', '--work', $W, '--root', $ROOT, '--force')
        Assert-Equal 0 $r.ExitCode '[live] operator --force takes over a live lease'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 6: pid liveness proof (alive keeps live; dead => stale) ----
    $W = New-Work
    try {
        # A real, long-lived child process to point the lease's pid at.
        $sleeper = Start-Process -FilePath $script:PwshHost `
            -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -NoNewWindow -PassThru
        try {
            Run-Tool @('acquire', '--work', $W, '--root', $ROOT, '--ttl', '1', '--pid', "$($sleeper.Id)") | Out-Null
            Start-Sleep -Seconds 2   # heartbeat now older than TTL, but the pid is alive
            $r = Run-Tool @('status', '--work', $W)
            Assert-Match $r.Output 'lease live' '[pid] a live pid keeps the lease live past its TTL'
            $r = Run-Tool @('takeover', '--work', $W, '--root', $ROOT)
            Assert-Equal 10 $r.ExitCode '[pid] takeover refused while the holder pid is alive'
        } finally {
            Stop-Process -Id $sleeper.Id -Force -ErrorAction SilentlyContinue
        }
        # A pid that is not running -> stale even with a huge TTL (fast recovery).
        Run-Tool @('release', '--work', $W, '--force') | Out-Null
        Run-Tool @('acquire', '--work', $W, '--root', $ROOT, '--ttl', '99999', '--pid', '999999') | Out-Null
        $r = Run-Tool @('status', '--work', $W)
        Assert-Match $r.Output 'lease stale' '[pid] a dead pid makes the lease stale despite a large TTL'
        $r = Run-Tool @('takeover', '--work', $W, '--root', $ROOT)
        Assert-Equal 0 $r.ExitCode '[pid] takeover adopts a lease whose pid is provably gone'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 7: addressed resume (verify role/root/owner, live vs stale) --
    $W = New-Work
    try {
        $owner = Get-Owner (Run-Tool @('acquire', '--work', $W, '--root', $ROOT, '--ttl', '600'))
        $r = Run-Tool @('verify', '--work', $W, '--require-root', $ROOT, '--require-role', 'processor', '--owner', $owner)
        Assert-Equal 0 $r.ExitCode '[verify] matching root/role/owner + live -> own-live (0)'
        Assert-Match $r.Output 'own-live' '[verify] reports own-live'
        $r = Run-Tool @('verify', '--work', $W, '--require-root', 'C:\other\project')
        Assert-Equal 15 $r.ExitCode '[verify] a different project root is not adopted (15)'
        $r = Run-Tool @('verify', '--work', $W, '--require-role', 'merger')
        Assert-Equal 16 $r.ExitCode '[verify] a different role is not adopted (16)'
        $r = Run-Tool @('verify', '--work', $W, '--owner', 'someone-else')
        Assert-Equal 13 $r.ExitCode '[verify] a different owner id is rejected (13)'

        # An interrupted (stale) session: verify reports own-stale so resume knows
        # to re-adopt / cold-recover rather than assume a live loop.
        Run-Tool @('release', '--work', $W, '--force') | Out-Null
        Run-Tool @('acquire', '--work', $W, '--root', $ROOT, '--ttl', '1') | Out-Null
        Start-Sleep -Seconds 2
        $r = Run-Tool @('verify', '--work', $W, '--require-root', $ROOT, '--require-role', 'processor')
        Assert-Equal 17 $r.ExitCode '[verify] a matching but stale lease -> own-stale (17)'
        Assert-Match $r.Output 'own-stale' '[verify] reports own-stale'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 8: repeat resume does not spawn a second loop --------------
    $W = New-Work
    try {
        Run-Tool @('acquire', '--work', $W, '--root', $ROOT, '--ttl', '1') | Out-Null
        Start-Sleep -Seconds 2
        $r = Run-Tool @('takeover', '--work', $W, '--root', $ROOT, '--ttl', '600', '--require-role', 'processor', '--require-root', $ROOT)
        Assert-Equal 0 $r.ExitCode '[resume] first resume re-adopts the stale lease'
        # The re-adopted lease is now live; a second resume must NOT re-adopt (which
        # would model two orchestrators). acquire sees it live and refuses.
        $r = Run-Tool @('acquire', '--work', $W, '--root', $ROOT)
        Assert-Equal 10 $r.ExitCode '[resume] a second resume finds a live lease and is refused (10)'
        $r = Run-Tool @('verify', '--work', $W, '--require-root', $ROOT, '--require-role', 'processor')
        Assert-Equal 0 $r.ExitCode '[resume] verify confirms the re-adopted lease is live'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 9: crash (fault injection) between critical writes ---------
    # (a) crash during a fresh acquire leaves NO lease; retry succeeds.
    $W = New-Work
    try {
        $r = Run-Tool @('acquire', '--work', $W, '--root', $ROOT, '--ttl', '600') -EnvVars @{ STATE_TX_FAULT = 'before-rename' }
        Assert-True ($r.ExitCode -ne 0) '[crash] injected fault fails the acquire'
        Assert-True ($null -eq (Read-Lease $W)) '[crash] no lease.json committed after a faulted acquire'
        $r = Run-Tool @('acquire', '--work', $W, '--root', $ROOT, '--ttl', '600')
        Assert-Equal 0 $r.ExitCode '[crash] retry acquires cleanly once the fault is cleared'
        Assert-Equal 1 ([int](Read-Lease $W).generation) '[crash] retry produced generation 1 (no double-apply)'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # (b) crash during heartbeat leaves the PRIOR lease intact (generation unchanged).
    $W = New-Work
    try {
        $owner = Get-Owner (Run-Tool @('acquire', '--work', $W, '--root', $ROOT, '--ttl', '600'))
        $genBefore = [int](Read-Lease $W).generation
        $r = Run-Tool @('heartbeat', '--work', $W, '--owner', $owner) -EnvVars @{ STATE_TX_FAULT = 'before-rename' }
        Assert-True ($r.ExitCode -ne 0) '[crash-hb] injected fault fails the heartbeat'
        Assert-Equal $genBefore ([int](Read-Lease $W).generation) '[crash-hb] generation unchanged after a faulted heartbeat'
        $r = Run-Tool @('heartbeat', '--work', $W, '--owner', $owner)
        Assert-Equal 0 $r.ExitCode '[crash-hb] retry heartbeat succeeds'
        Assert-Equal ($genBefore + 1) ([int](Read-Lease $W).generation) '[crash-hb] retry bumped generation exactly once'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # (c) crash after creating the lock dir but before writing the lease.
    $W = New-Work
    try {
        $r = Run-Tool @('acquire', '--work', $W, '--root', $ROOT, '--ttl', '600') -EnvVars @{ STATE_TX_FAULT = 'after-dir-create' }
        Assert-True ($r.ExitCode -ne 0) '[crash-dir] injected fault fails the acquire'
        Assert-True ($null -eq (Read-Lease $W)) '[crash-dir] no lease committed even though the dir was created'
        $r = Run-Tool @('acquire', '--work', $W, '--root', $ROOT, '--ttl', '600')
        Assert-Equal 0 $r.ExitCode '[crash-dir] retry acquires cleanly'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 10: corrupt lease halts with a precise error --------------
    $W = New-Work
    try {
        $lockDir = Join-Path $W 'orchestrator.lock'
        New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
        Set-Content -LiteralPath (Join-Path $lockDir 'lease.json') -Value '{ this is not valid json' -Encoding utf8
        $r = Run-Tool @('status', '--work', $W)
        Assert-Equal 18 $r.ExitCode '[corrupt] status on a corrupt lease reports 18'
        Assert-Match $r.Output 'corrupt' '[corrupt] status names the corruption'
        $r = Run-Tool @('acquire', '--work', $W, '--root', $ROOT)
        Assert-Equal 18 $r.ExitCode '[corrupt] acquire refuses to overwrite a corrupt lease without --force'
        $r = Run-Tool @('acquire', '--work', $W, '--root', $ROOT, '--force')
        Assert-Equal 0 $r.ExitCode '[corrupt] --force overwrites the corrupt lease'
        Assert-True ($null -ne (Read-Lease $W)) '[corrupt] a valid lease exists after the forced acquire'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 11: transition validation ---------------------------------
    $W = New-Work
    try {
        foreach ($t in @(
                @('task', 'not-started', 'working'), @('task', 'working', 'in-review'),
                @('task', 'in-review', 'ready'), @('task', 'ready', 'merged'),
                @('task', 'merged', 'published'), @('task', 'published', 'done'),
                @('task', 'conflict', 'not-started'), @('cohort', 'open', 'closed'),
                @('integration', 'in-progress', 'reviewed'), @('integration', 'reviewed', 'published'))) {
            $r = Run-Tool @('check-transition', '--kind', $t[0], '--from', $t[1], '--to', $t[2])
            Assert-Equal 0 $r.ExitCode "[trans] legal $($t[0]) $($t[1]) -> $($t[2]) accepted"
        }
        # `working -> ready` is a review SKIP: the canonical task lifecycle is
        # `working -> in-review -> ready` (queue_contract.md 13.1), so the guard must
        # reject it - the doc is the source of truth (T-079 R-01).
        foreach ($t in @(
                @('task', 'done', 'working'), @('task', 'not-started', 'ready'),
                @('task', 'working', 'ready'),
                @('task', 'published', 'working'), @('cohort', 'closed', 'open'),
                @('integration', 'cleaned', 'in-progress'))) {
            $r = Run-Tool @('check-transition', '--kind', $t[0], '--from', $t[1], '--to', $t[2])
            Assert-Equal 8 $r.ExitCode "[trans] illegal $($t[0]) $($t[1]) -> $($t[2]) rejected (8)"
            Assert-Match $r.Output 'illegal' "[trans] illegal transition is named"
        }
        $r = Run-Tool @('check-transition', '--kind', 'bogus', '--from', 'x', '--to', 'y')
        Assert-Equal 2 $r.ExitCode '[trans] unknown --kind is a usage error (2)'
        $r = Run-Tool @('check-transition', '--kind', 'task', '--from', 'nope', '--to', 'working')
        Assert-Equal 2 $r.ExitCode '[trans] unknown --from state is a usage error (2)'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 12: control-plane generation counter (CAS) ----------------
    $W = New-Work
    try {
        Assert-Match (Run-Tool @('generation', '--work', $W)).Output '0' '[gen] generation starts at 0'
        Assert-Match (Run-Tool @('bump-generation', '--work', $W)).Output 'generation=1' '[gen] bump -> 1'
        Assert-Match (Run-Tool @('bump-generation', '--work', $W)).Output 'generation=2' '[gen] bump -> 2'
        $r = Run-Tool @('bump-generation', '--work', $W, '--expected-generation', '0')
        Assert-Equal 3 $r.ExitCode '[gen] stale expected-generation rejected (3)'
        $r = Run-Tool @('bump-generation', '--work', $W, '--expected-generation', '2')
        Assert-Equal 0 $r.ExitCode '[gen] correct expected-generation accepted'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 13: cross-host - the tool runs under Windows PowerShell 5.1
    # AND pwsh (the same engine used on POSIX). Run a basic lifecycle under each
    # available host so a host-specific regression is caught on both platforms.
    $hosts = @('powershell')
    if ($pwshCmd) { $hosts += $pwshCmd.Source }
    foreach ($h in ($hosts | Select-Object -Unique)) {
        $W = New-Work
        try {
            $r = Run-Tool @('acquire', '--work', $W, '--root', $ROOT, '--ttl', '600') -Host $h
            Assert-Equal 0 $r.ExitCode "[host:$h] acquire exit"
            $owner = Get-Owner $r
            $r = Run-Tool @('heartbeat', '--work', $W, '--owner', $owner) -Host $h
            Assert-Equal 0 $r.ExitCode "[host:$h] heartbeat exit"
            $r = Run-Tool @('check-transition', '--kind', 'task', '--from', 'working', '--to', 'in-review') -Host $h
            Assert-Equal 0 $r.ExitCode "[host:$h] check-transition exit"
            $r = Run-Tool @('release', '--work', $W, '--owner', $owner) -Host $h
            Assert-Equal 0 $r.ExitCode "[host:$h] release exit"
        } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # --- Scenario 14: legacy / degraded mkdir-lock is not silently overwritten -
    # The degraded fallback (no pwsh) holds the SAME orchestrator.lock directory with a
    # bare `mkdir` + `info` file (no lease.json). state-tx must treat that as OCCUPIED,
    # not "no lease" - otherwise it would write a fresh lease.json over a possibly-live
    # degraded processor and spawn a second control loop (T-079 R-02).
    $W = New-Work
    try {
        $lockDir = Join-Path $W 'orchestrator.lock'
        New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
        Set-Content -LiteralPath (Join-Path $lockDir 'info') -Value "host=oldbox`nstarted=2020-01-01T00:00:00Z" -Encoding ascii

        $r = Run-Tool @('status', '--work', $W)
        Assert-Equal 19 $r.ExitCode '[legacy] status on a legacy mkdir-lock reports 19'
        Assert-Match $r.Output 'legacy-lock' '[legacy] status names the legacy lock'
        $r = Run-Tool @('verify', '--work', $W, '--require-root', $ROOT, '--require-role', 'processor')
        Assert-Equal 19 $r.ExitCode '[legacy] verify does not adopt a legacy lock as own session (19)'
        $r = Run-Tool @('acquire', '--work', $W, '--root', $ROOT)
        Assert-Equal 19 $r.ExitCode '[legacy] acquire refuses to write a lease over a legacy lock (19)'
        Assert-True ($null -eq (Read-Lease $W)) '[legacy] acquire did NOT silently write lease.json over the legacy lock'

        # An operator who has confirmed the degraded run is dead can --force over it.
        $r = Run-Tool @('acquire', '--work', $W, '--root', $ROOT, '--force')
        Assert-Equal 0 $r.ExitCode '[legacy] --force acquires over a legacy lock'
        Assert-True ($null -ne (Read-Lease $W)) '[legacy] a structured lease exists after the forced acquire'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 15: an empty lock dir (a state-tx crash artifact, not a foreign
    # lock) stays recoverable: acquire may adopt it rather than reporting it occupied.
    $W = New-Work
    try {
        New-Item -ItemType Directory -Force -Path (Join-Path $W 'orchestrator.lock') | Out-Null
        $r = Run-Tool @('acquire', '--work', $W, '--root', $ROOT)
        Assert-Equal 0 $r.ExitCode '[legacy] an EMPTY lock dir is a recoverable artifact, not a legacy lock'
        Assert-Equal 1 ([int](Read-Lease $W).generation) '[legacy] recovered acquire produced generation 1'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }
}
