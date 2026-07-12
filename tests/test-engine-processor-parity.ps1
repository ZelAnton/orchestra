<#
.SYNOPSIS
    The pre-cutover EQUIVALENCE ORACLE (task T-110): run ONE cohort scenario two ways -
    (a) the prose control loop `agents/processor.md` as exercised by `tools/harness.ps1`,
    and (b) the deterministic Rust engine (`engine run --once`, engine/src/run.rs) - over
    equivalent hermetic sandboxes, and assert both converge to the SAME timestamp- and
    event-id-independent final-state fingerprint that `tools/harness.ps1` already computes
    (the deduplicated set of event IDENTITIES: type + entity + transition, NOT occurred_at /
    event_id). A drift between the two paths fails the check (non-zero exit).

.DESCRIPTION
    Intent doc plans/DETERMINISTIC_ORCHESTRATOR_INTENT.md §9.2 makes this the cutover
    criterion: "бинарь и проза-процессор на одном сценарии обязаны сходиться к одному
    fingerprint - tools/harness.ps1 уже вычисляет ровно такой timestamp/event-id-независимый
    отпечаток конечного состояния". This script is that measurable oracle - and ONLY an
    oracle. A big-bang cutover of processor.md remains forbidden (§13); this never replaces
    the processor, it only measures how far the engine has converged toward it.

    WHY THE OUTBOX EVENT-IDENTITY SET IS THE RIGHT SURFACE. The two paths do NOT yet cover the
    same span of the lifecycle: `tools/harness.ps1` (the processor-prose stand-in, whose
    header explains it drives the REAL queue-tx/state-tx/outbox tools that mediate every
    critical processor transition) drives the WHOLE cohort lifecycle (capture -> review ->
    ready -> integrate -> publish -> archive), whereas `engine run --once` (T-109) is the
    engine's FIRST composed control loop and deliberately covers only ONE cohort/phase: take
    the lease, open the cohort, capture each admitted task, run ONE supervised round that
    advances `в работе -> на ревью`, then close admission. The `.work/events.jsonl` outbox is
    append-only, so the events of that shared "phase 1" prefix survive verbatim inside a full
    harness run; the outbox event-identity set is therefore the one fingerprint dimension both
    paths produce identically today. (The queue/descriptor/tree dimensions of the harness's
    combined fingerprint diverge only because the harness run CONTINUES past phase 1 to archive
    the tasks and mutate a real VCS trunk - state the engine's one-round run has not reached.)

    So the oracle compares the harness's own event-identity digest and the engine's, each
    RESTRICTED to the phase-1 vocabulary both implement:
        * cohort.opened
        * task.captured
        * task.status_changed with transition `в работе>на ревью`
    and asserts the two restricted sets (hence their SHA-256 fingerprint) are byte-equal. This
    is exactly the equivalence guarantee that must hold before any cutover, computed the same
    way the harness computes its fingerprint (Get-OutboxDigest: identity = type|batch|task|
    from>to, deduplicated by event_id, sorted). As the engine grows to cover later phases, the
    shared vocabulary widens and this oracle tightens - without ever licensing a big-bang.

    FAITHFULNESS. The identity extractor here reproduces `tools/harness.ps1`'s Get-OutboxDigest
    byte-for-byte; a hard assertion cross-checks that running it over the harness's own kept
    events.jsonl reproduces the harness's self-reported `outbox` digest exactly, so "the same
    fingerprint the harness already computes" is not merely claimed but proven each run. A
    deliberate negative self-check perturbs one identity and confirms the fingerprint changes,
    so a real drift cannot slip through as a false green.

    HERMETIC / OFFLINE. Both runs are against throwaway temp fixtures: the harness builds its
    own disposable, offline, never-pushed git repo + isolated .work; the engine runs over a
    fresh temp sandbox `.work` seeded through the REAL queue-tx.ps1 propose. Neither path ever
    touches THIS repository's live `.work`, and nothing performs a network operation. Every
    temp fixture is removed on exit.

    SELF-SKIP DISCIPLINE (mirrors the rest of the suite's optional-prerequisite skips). git
    absent -> skip the whole check (the harness path needs it), never fail. The engine binary
    is located at engine/target/debug and, if absent, built once via `cargo build` from this
    checkout's engine crate; cargo absent, or the crate failing to build, is a skip (the engine
    crate's own build/test/lint gate is the separate `engine-tui` CI job, not this oracle) -
    never a redundant failure here.

.NOTES
    Runs under PowerShell 7 (pwsh) and Windows PowerShell 5.1, like the rest of tests/*.ps1.

    Exit codes:
      0   the two paths converged on the shared phase-1 fingerprint (or the check self-skipped
          because a prerequisite - git / cargo / a buildable engine crate - was absent)
      1   a drift was detected, or a run failed unexpectedly

.EXAMPLE
    pwsh -File tests/test-engine-processor-parity.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:Harness = Join-Path $script:Root 'tools/harness.ps1'
$script:QueueTx = Join-Path $script:Root 'tools/queue-tx.ps1'
$script:ToolsDir = Join-Path $script:Root 'tools'
$script:EngineDir = Join-Path $script:Root 'engine'
$script:PsExe = ([System.Diagnostics.Process]::GetCurrentProcess()).MainModule.FileName
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:OnWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows)
$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:TempDirs = [System.Collections.Generic.List[string]]::new()

# The exact phase-1 status transition both paths emit (в работе -> на ревью).
$script:ReviewTransition = 'в работе>на ревью'

function Assert-True { param([bool]$Cond, [string]$Msg) if (-not $Cond) { $script:Failures.Add("FAIL - $Msg") } }
function Assert-Equal { param($Expected, $Actual, [string]$Msg) if ("$Expected" -cne "$Actual") { $script:Failures.Add("FAIL - ${Msg}: expected [$Expected], got [$Actual]") } }

# --------------------------------------------------------------------------
# Child-process helpers (no shell; UTF-8 stdio), matching the suite's style.
# --------------------------------------------------------------------------
function Invoke-Proc {
    param([string]$File, [string[]]$ProcArgs, [string]$WorkDir = '')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8
    $psi.StandardErrorEncoding = $script:Utf8
    if ($WorkDir) { $psi.WorkingDirectory = $WorkDir }
    foreach ($a in $ProcArgs) { $psi.ArgumentList.Add([string]$a) }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outT = $proc.StandardOutput.ReadToEndAsync()
    $errT = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Out = $outT.Result; Err = $errT.Result }
}
# Run one of the repo's .ps1 tools through the current PowerShell host.
function Invoke-Ps {
    param([string]$Script, [string[]]$ScriptArgs)
    return (Invoke-Proc $script:PsExe (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $ScriptArgs))
}
function Has-Bin { param([string]$Name) return [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# --------------------------------------------------------------------------
# Fingerprint reproduction. These mirror tools/harness.ps1's Get-OutboxDigest
# EXACTLY (identity = type|batch|task|from>to, deduplicated by event_id, sorted)
# so the same fingerprint is computed over BOTH paths' events.jsonl outboxes.
# --------------------------------------------------------------------------
function JHas { param($Obj, [string]$Name) return ($null -ne $Obj -and $null -ne $Obj.PSObject.Properties[$Name]) }
function JGet { param($Obj, [string]$Name) if (JHas $Obj $Name) { return $Obj.$Name } else { return $null } }
function Sha256Hex {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $h = $sha.ComputeHash($script:Utf8.GetBytes($Text)) } finally { $sha.Dispose() }
    return -join ($h | ForEach-Object { $_.ToString('x2') })
}

# The deduplicated list of event identities from a .work/events.jsonl outbox.
function Get-OutboxIdentities {
    param([string]$EventsPath)
    $ids = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $EventsPath)) { return $ids }
    $seen = @{}
    foreach ($line in ([System.IO.File]::ReadAllText($EventsPath, $script:Utf8) -split "`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $o = $null
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if (-not (JHas $o 'event_id')) { continue }
        $eid = [string]$o.event_id
        if ($seen.ContainsKey($eid)) { continue }
        $seen[$eid] = $true
        $batch = [string](JGet $o 'batch_id')
        $task = [string](JGet $o 'task_id')
        $trans = ''
        $pl = JGet $o 'payload'
        if ($pl) {
            $from = [string](JGet $pl 'from')
            $to = [string](JGet $pl 'to')
            if ($from -or $to) { $trans = "$from>$to" }
        }
        $ids.Add(("{0}|{1}|{2}|{3}" -f [string]$o.type, $batch, $task, $trans))
    }
    return $ids
}
# The harness's own digest form: sorted identities joined by ';' (Get-OutboxDigest output).
function Digest-Of { param($Ids) return ((@($Ids) | Sort-Object) -join ';') }

# Restrict an identity list to the phase-1 vocabulary both paths implement today.
function Select-PhaseOne {
    param($Ids)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($id in @($Ids)) {
        $parts = [string]$id -split '\|', 4
        $type = $parts[0]
        $trans = if ($parts.Count -ge 4) { $parts[3] } else { '' }
        if ($type -eq 'cohort.opened' -or $type -eq 'task.captured') { $out.Add([string]$id); continue }
        if ($type -eq 'task.status_changed' -and $trans -eq $script:ReviewTransition) { $out.Add([string]$id); continue }
    }
    return $out
}
# The timestamp/event-id-independent phase-1 fingerprint: SHA-256 of the sorted, unique
# phase-1 identity set.
function PhaseOne-Fingerprint { param($Ids) return (Sha256Hex ((@(Select-PhaseOne $Ids) | Sort-Object -Unique) -join ';')) }

# --------------------------------------------------------------------------
# Cleanup of every temp fixture we created (best-effort, always runs).
# --------------------------------------------------------------------------
function Cleanup {
    foreach ($d in $script:TempDirs) {
        if ($d -and (Test-Path -LiteralPath $d)) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ==========================================================================
# Prerequisites (self-skip like the rest of the suite when one is absent).
# ==========================================================================
if (-not (Has-Bin 'git')) {
    Write-Host 'SKIP - git is not installed; the processor-prose (harness) path needs it. Skipping the parity oracle.'
    exit 0
}

# Locate the engine binary from THIS checkout; build it once if needed.
$binName = if ($script:OnWindows) { 'orchestra-engine.exe' } else { 'orchestra-engine' }
$script:EngineBin = Join-Path $script:EngineDir (Join-Path 'target/debug' $binName)
if (-not (Test-Path -LiteralPath $script:EngineBin)) {
    if (-not (Has-Bin 'cargo')) {
        Write-Host 'SKIP - the engine binary is not built and cargo is unavailable; cannot run the engine path. Skipping.'
        exit 0
    }
    Write-Host 'Building the engine crate once (cargo build --locked --bin orchestra-engine)...'
    $build = Invoke-Proc 'cargo' @('build', '--locked', '--bin', 'orchestra-engine') $script:EngineDir
    if ($build.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $script:EngineBin)) {
        Write-Host 'SKIP - the engine crate did not build here (its build/test/lint gate is the separate engine-tui CI job, not this oracle):'
        Write-Host ($build.Err.Trim())
        exit 0
    }
}

# ==========================================================================
# Path (a): the processor-prose control loop via tools/harness.ps1 (clean scenario).
# --keep so we can read (and cross-check) its events.jsonl; we remove it ourselves.
# ==========================================================================
$harnessJson = $null
$harnessEvents = ''
try {
    $hr = Invoke-Ps $script:Harness @('scenario', '--vcs', 'git', '--name', 'clean', '--keep', '--json')
    if ($hr.ExitCode -ne 0) {
        $script:Failures.Add("FAIL - harness clean scenario exited $($hr.ExitCode): $($hr.Err.Trim())")
    } else {
        try { $harnessJson = $hr.Out.Trim() | ConvertFrom-Json }
        catch { $script:Failures.Add("FAIL - harness produced unparseable JSON: $($hr.Out)") }
    }
    if ($harnessJson) {
        $script:TempDirs.Add([string]$harnessJson.fixture)
        $harnessEvents = Join-Path ([string]$harnessJson.fixture) 'repo/.work/events.jsonl'
        Assert-True (Test-Path -LiteralPath $harnessEvents) 'harness kept fixture exposes its events.jsonl outbox'
    }

    # ======================================================================
    # Path (b): the deterministic engine over a fresh, equivalently-seeded sandbox.
    # Seed the SAME task ids and batch id the harness clean scenario uses so the two
    # phase-1 identity sets are directly comparable.
    # ======================================================================
    $batchId = 'B-20260101T000000Z'   # tools/harness.ps1 New-Fixture's fixed BatchId.
    $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('orc-parity-engine-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $sandbox
    $script:TempDirs.Add($sandbox)

    $seedOk = $true
    foreach ($seed in @(@('T-101', 'clean one'), @('T-102', 'clean two'))) {
        $p = Invoke-Ps $script:QueueTx @('propose', '--work', $sandbox, '--id', $seed[0], '--title', $seed[1])
        if ($p.ExitCode -ne 0) { $script:Failures.Add("FAIL - seed propose $($seed[0]) exited $($p.ExitCode): $($p.Err.Trim())"); $seedOk = $false }
    }

    $engineEvents = Join-Path $sandbox 'events.jsonl'
    if ($seedOk) {
        $er = Invoke-Proc $script:EngineBin @(
            'run', '--once',
            '--work', $sandbox,
            '--tools', $script:ToolsDir,
            '--base', 'sandbox-base',
            '--batch', $batchId,
            '--cohort-size', '2',
            '--json')
        if ($er.ExitCode -ne 0) {
            $script:Failures.Add("FAIL - engine run --once exited $($er.ExitCode): $($er.Err.Trim())$($er.Out.Trim())")
        } else {
            Assert-True (Test-Path -LiteralPath $engineEvents) 'engine run wrote its events.jsonl outbox'
        }
    }

    # ======================================================================
    # Compare the fingerprints.
    # ======================================================================
    if ($harnessJson -and (Test-Path -LiteralPath $harnessEvents) -and (Test-Path -LiteralPath $engineEvents)) {
        $harnessIds = Get-OutboxIdentities $harnessEvents
        $engineIds = Get-OutboxIdentities $engineEvents

        # Faithfulness: our extractor reproduces the harness's own Get-OutboxDigest byte-for-byte,
        # so "the same fingerprint the harness already computes" is proven, not merely asserted.
        Assert-Equal ([string]$harnessJson.outbox) (Digest-Of $harnessIds) `
            'our identity extractor reproduces harness Get-OutboxDigest byte-for-byte over the same events.jsonl'

        $harnessPhaseOne = @(Select-PhaseOne $harnessIds | Sort-Object -Unique)
        $enginePhaseOne = @(Select-PhaseOne $engineIds | Sort-Object -Unique)

        # Vacuous-pass guard: the shared phase-1 surface is exactly these five identities
        # (cohort.opened + two task.captured + two task.status_changed в работе->на ревью),
        # so an empty-vs-empty match can never masquerade as convergence.
        $expected = @(
            "cohort.opened|$batchId||",
            "task.captured|$batchId|T-101|",
            "task.captured|$batchId|T-102|",
            "task.status_changed||T-101|$script:ReviewTransition",
            "task.status_changed||T-102|$script:ReviewTransition"
        ) | Sort-Object
        Assert-Equal ($expected -join "`n") ($harnessPhaseOne -join "`n") 'processor-prose (harness) emits exactly the shared phase-1 identity set'
        Assert-Equal ($expected -join "`n") ($enginePhaseOne -join "`n") 'the engine emits exactly the shared phase-1 identity set'

        # THE ORACLE: both paths converge on the SAME phase-1 fingerprint.
        $harnessFp = PhaseOne-Fingerprint $harnessIds
        $engineFp = PhaseOne-Fingerprint $engineIds
        Assert-Equal $harnessFp $engineFp 'engine and processor-prose converge on the SAME phase-1 final-state fingerprint (cutover oracle, intent §9.2)'
        Write-Host "phase-1 fingerprint (processor-prose): $harnessFp"
        Write-Host "phase-1 fingerprint (engine)         : $engineFp"

        # Negative self-check: the detector has teeth. Perturbing ONE identity (a drifted
        # transition) must change the fingerprint, so a real divergence cannot pass green.
        $perturbed = @($enginePhaseOne) + @("task.status_changed||T-999|$script:ReviewTransition")
        $perturbedFp = Sha256Hex ((@($perturbed) | Sort-Object -Unique) -join ';')
        Assert-True ($perturbedFp -cne $engineFp) 'a perturbed identity set yields a DIFFERENT fingerprint (drift detector has teeth)'
    }
} finally {
    Cleanup
}

# ==========================================================================
# Report.
# ==========================================================================
if ($script:Failures.Count -eq 0) {
    Write-Host 'OK - engine and processor-prose converge on the shared phase-1 fingerprint (pre-cutover equivalence oracle).'
    exit 0
}
Write-Host "FAILED - $($script:Failures.Count) assertion(s):"
foreach ($f in $script:Failures) { Write-Host "  $f" }
exit 1
