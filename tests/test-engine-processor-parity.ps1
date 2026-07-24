<#
.SYNOPSIS
    The pre-cutover EQUIVALENCE ORACLE (task T-110, extended by T-129 to the per-task review
    and fix-cycle surface, and by T-243 to the join-barrier surface — merge / integration
    review / publication / archival): run cohort scenarios TWO ways - (a) the prose control loop
    `agents/processor.md` as exercised by `tools/harness.ps1`, and (b) the deterministic Rust
    engine (`engine run --once`, engine/src/run.rs) - over equivalent hermetic sandboxes, and
    assert both converge to the SAME timestamp- and event-id-independent final-state fingerprint
    that `tools/harness.ps1` already computes (the deduplicated set of event IDENTITIES: type +
    entity + transition, NOT occurred_at / event_id). A drift between the two paths fails the
    check (non-zero exit).

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
    engine's FIRST composed control loop and deliberately covers only the phases it has grown
    to implement so far: take the lease, open the cohort, capture each admitted task, run ONE
    supervised round that advances `в работе -> на ревью`, then - as of T-128, opt-in via
    `--review` - drive the per-task review FIX CYCLE (a clean pass promotes `на ревью -> готова
    к слиянию`; findings loop `на ревью -> на ревью` under a `REVIEW_LOOP_MAX` cap before
    escalating `на ревью -> эскалирована`), close admission, and - as of T-243, opt-in via
    `--join` - drive the JOIN BARRIER (phases 4-6): sequential merge of the ready branches into
    `_integration` (decided off `merge_report.md`), the bounded integration review cycle
    (`INTEGRATION_LOOP_MAX`, the same clean/findings gate over `F-`/`SUMMARY-F`), the ff-merge into
    main and per-task publication/archival, and one `cohort.closed` that terminally processes the
    cohort even when nothing was ready to merge. The `.work/events.jsonl`
    outbox is append-only, so the events of that shared, growing prefix survive verbatim inside
    a full harness run; the outbox event-identity set is therefore the one fingerprint dimension
    both paths produce identically today. (The queue/descriptor/tree dimensions of the harness's
    combined fingerprint diverge only because the harness run CONTINUES past this prefix to
    integrate, publish, archive the tasks and mutate a real VCS trunk - state the engine's
    one-round run has not reached.)

    So the oracle compares the harness's own event-identity digest and the engine's, each
    RESTRICTED to the vocabulary both implement:
        * cohort.opened
        * task.captured
        * task.status_changed with transition `в работе>на ревью`               (T-110, phase 1)
        * task.status_changed with transition `на ревью>готова к слиянию`       (T-128, clean pass)
        * task.status_changed with transition `на ревью>на ревью`               (T-128, incomplete/
          findings cycle - re-review, `Циклов-ревью: N`)
        * task.status_changed with transition `на ревью>эскалирована`           (T-128,
          `REVIEW_LOOP_MAX` exhaustion - a CLEAN terminal escalation, not a re-interpretation)
        * cohort.join_started                                                   (T-243, join barrier
          entered - integration `none>in-progress`, ready branches handed to the merger)
        * cohort.published                                                      (T-243, batch
          ff-merged into main / publication pinned)
        * cohort.closed                                                         (T-243, cohort
          terminally processed - emitted in BOTH pairings, even when nothing was published)
        * task.status_changed with transition `опубликована>выполнена`          (T-243, Phase 6.1
          archival - the one per-task publication identity both paths emit byte-for-byte)
    and asserts the two restricted sets (hence their SHA-256 fingerprint) are byte-equal. This
    is exactly the equivalence guarantee that must hold before any cutover, computed the same
    way the harness computes its fingerprint (Get-OutboxDigest: identity = type|batch|task|
    from>to, deduplicated by event_id, sorted). As the engine grows to cover later phases, the
    shared vocabulary widens and this oracle tightens - without ever licensing a big-bang.

    SIX PAIRED HERMETIC RUNS. The `на ревью>готова к слиянию` identities come for free from the
    SAME clean two-task scenario the T-110 oracle already drove (harness scenario `clean` /
    engine `run --once --review` over T-101+T-102 - both simply reach a clean review pass at
    cycle 1). The incomplete-cycle and REVIEW_LOOP_MAX-escalation identities need a task whose
    review never converges, so a SECOND, independent hermetic pairing exercises exactly that:
    harness scenario `review-cycle` (a single task T-101, one incomplete cycle then escalation)
    against `engine run --once --review --inject-findings T-101 --review-loop-max 1` (the same
    deterministic "findings persist, budget of 1" shape) over a FRESH sandbox/fixture. Each
    path's identity set is the UNION of what its two runs produced (the outbox is append-only
    within a run, but here the two runs are separate fixtures entirely); the shared task id
    `T-101` recurring across the two independent fixtures is expected (harness convention:
    every scenario function names its primary task `T-101`) and harmless - the compared surface
    is a set of `type|batch|task|from>to` tuples, and the tuples differ by transition.

    Four further independent pairings cover the terminal `conflict`, `quarantine`, `policy`, and
    `checks` harness scenarios. Their fingerprints are compared pair-by-pair, with an
    anti-vacuity assertion for every scenario, so identities contributed by the clean pairing
    cannot mask a missing terminal path. The policy pairing compares its structural common
    surface and separately asserts both safe terminal outcomes: the harness intentionally does
    not emit a policy escalation status event, while the engine's fail-closed staging does.

    FAITHFULNESS. The identity extractor here reproduces `tools/harness.ps1`'s Get-OutboxDigest
    byte-for-byte; a hard assertion cross-checks that running it over EACH harness run's own kept
    events.jsonl reproduces THAT run's self-reported `outbox` digest exactly, so "the same
    fingerprint the harness already computes" is not merely claimed but proven each run - for
    both the `clean` and the `review-cycle` pairing.

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
      0   the two paths converged on the shared fingerprint (or the check self-skipped
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

# The exact status transitions both paths emit today (T-110 phase 1 + T-128 per-task review /
# fix-cycle, extended by T-129; T-243 adds the join-barrier publication->done transition).
$script:ReviewTransition = 'в работе>на ревью'                 # T-110: working -> in-review
$script:ReadyTransition = 'на ревью>готова к слиянию'          # T-128: clean review pass
$script:ReviewLoopTransition = 'на ревью>на ревью'             # T-128: incomplete/findings cycle
$script:ReviewEscalateTransition = 'на ревью>эскалирована'     # T-128: REVIEW_LOOP_MAX exhausted
$script:PublishTransition = 'опубликована>выполнена'           # T-243: join barrier — publication -> done (Phase 6.1 archive)

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

# Restrict an identity list to the vocabulary both paths implement today: the T-110 phase-1
# prefix PLUS the T-128 per-task review / fix-cycle transitions extended by T-129, PLUS the T-243
# join-barrier surface (the cohort-level `cohort.join_started`/`cohort.published`/`cohort.closed`
# events and the per-task `опубликована>выполнена` archival transition). The intermediate
# publication transitions differ by construction between the two paths and are deliberately NOT
# compared: the engine advances `готова к слиянию -> слита -> опубликована` through the real §13.1
# state machine (`ready -> merged -> published`), while the processor-prose harness simplifies its
# per-task publication to a single `готова к слиянию -> опубликована` step — so only the shared
# `опубликована -> выполнена` archival step is a byte-equal per-task identity.
function Select-Compared {
    param($Ids)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($id in @($Ids)) {
        $parts = [string]$id -split '\|', 4
        $type = $parts[0]
        $trans = if ($parts.Count -ge 4) { $parts[3] } else { '' }
        if ($type -eq 'cohort.opened' -or $type -eq 'task.captured' -or
            $type -eq 'cohort.join_started' -or $type -eq 'cohort.published' -or
            $type -eq 'cohort.closed') {
            $out.Add([string]$id); continue
        }
        if ($type -eq 'task.status_changed' -and (
                $trans -eq $script:ReviewTransition -or
                $trans -eq $script:ReadyTransition -or
                $trans -eq $script:ReviewLoopTransition -or
                $trans -eq $script:ReviewEscalateTransition -or
                $trans -eq $script:PublishTransition)) {
            $out.Add([string]$id); continue
        }
    }
    return $out
}
# The timestamp/event-id-independent compared-surface fingerprint: SHA-256 of the sorted,
# unique identity set restricted to the shared vocabulary.
function Compared-Fingerprint { param($Ids) return (Sha256Hex ((@(Select-Compared $Ids) | Sort-Object -Unique) -join ';')) }

# `harness` deliberately models a policy denial without a separate task.status_changed event,
# while the engine's fail-closed leaf reports its own escalation transition. The stable common
# parity surface for that one pairing is therefore the structural lifecycle only; endpoint
# outcome assertions below make the terminal policy branch non-vacuous.
function Select-PolicyCompared {
    param($Ids)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($id in @($Ids)) {
        $type = ([string]$id -split '\|', 2)[0]
        if ($type -eq 'cohort.opened' -or $type -eq 'task.captured' -or $type -eq 'cohort.closed') {
            $out.Add([string]$id)
        }
    }
    return $out
}

function Assert-ScenarioPair {
    param(
        [string]$Name,
        $HarnessJson,
        [string]$HarnessEvents,
        [string]$EngineEvents,
        [switch]$PolicySurface
    )
    Assert-True ($null -ne $HarnessJson) "$Name harness scenario returned JSON"
    Assert-True (Test-Path -LiteralPath $HarnessEvents) "$Name harness scenario wrote events.jsonl"
    Assert-True (Test-Path -LiteralPath $EngineEvents) "$Name engine scenario wrote events.jsonl"
    if ($null -eq $HarnessJson -or -not (Test-Path -LiteralPath $HarnessEvents) -or -not (Test-Path -LiteralPath $EngineEvents)) { return }

    $harnessIds = Get-OutboxIdentities $HarnessEvents
    $engineIds = Get-OutboxIdentities $EngineEvents
    Assert-Equal ([string]$HarnessJson.outbox) (Digest-Of $harnessIds) `
        "$Name extractor reproduces harness Get-OutboxDigest"
    $harnessCompared = if ($PolicySurface) { @(Select-PolicyCompared $harnessIds | Sort-Object -Unique) } else { @(Select-Compared $harnessIds | Sort-Object -Unique) }
    $engineCompared = if ($PolicySurface) { @(Select-PolicyCompared $engineIds | Sort-Object -Unique) } else { @(Select-Compared $engineIds | Sort-Object -Unique) }
    Assert-True ($harnessCompared.Count -gt 0) "$Name compared event surface is non-empty"
    Assert-Equal ($harnessCompared -join "`n") ($engineCompared -join "`n") `
        "$Name processor-prose and engine terminal event surfaces converge"
}

function New-EngineFixture {
    param([string]$Label, [object[]]$Seeds)
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('orc-parity-engine-' + $Label + '-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $work
    $script:TempDirs.Add($work)
    $ok = $true
    foreach ($seed in @($Seeds)) {
        $p = Invoke-Ps $script:QueueTx @('propose', '--work', $work, '--id', [string]$seed.Id, '--title', [string]$seed.Title)
        if ($p.ExitCode -ne 0) {
            $script:Failures.Add("FAIL - $Label seed propose $($seed.Id) exited $($p.ExitCode): $($p.Err.Trim())")
            $ok = $false
            continue
        }
        $descDir = Join-Path (Join-Path $work 'tasks') ([string]$seed.Id)
        $null = New-Item -ItemType Directory -Force -Path $descDir
        $descText = "# $($seed.Id)`nСтатус: не начата`nБатч: $batchId`nКонфликт-домен: $($seed.Domain)`n"
        [System.IO.File]::WriteAllText((Join-Path $descDir 'task.md'), $descText, $script:Utf8)
    }
    return [pscustomobject]@{ Work = $work; Events = (Join-Path $work 'events.jsonl'); SeedOk = $ok }
}

function Invoke-EngineScenario {
    param($Fixture, [string[]]$Extra)
    return (Invoke-Proc $script:EngineBin (@('run', '--once', '--work', $Fixture.Work, '--tools', $script:ToolsDir,
        '--base', 'sandbox-base', '--batch', $batchId, '--json') + $Extra))
}

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

$batchId = 'B-20260101T000000Z'   # tools/harness.ps1 New-Fixture's fixed BatchId (every scenario).

try {
    # ======================================================================
    # PAIRING 1 (T-110 phase 1 + T-128 clean review pass): harness scenario `clean` (T-101 +
    # T-102, both converge cleanly) vs `engine run --once --review` over an equivalently-seeded
    # sandbox. --keep so we can read (and cross-check) the harness's events.jsonl.
    # ======================================================================
    $harnessJson1 = $null
    $harnessEvents1 = ''
    $hr1 = Invoke-Ps $script:Harness @('scenario', '--vcs', 'git', '--name', 'clean', '--keep', '--json')
    if ($hr1.ExitCode -ne 0) {
        $script:Failures.Add("FAIL - harness clean scenario exited $($hr1.ExitCode): $($hr1.Err.Trim())")
    } else {
        try { $harnessJson1 = $hr1.Out.Trim() | ConvertFrom-Json }
        catch { $script:Failures.Add("FAIL - harness clean scenario produced unparseable JSON: $($hr1.Out)") }
    }
    if ($harnessJson1) {
        $script:TempDirs.Add([string]$harnessJson1.fixture)
        $harnessEvents1 = Join-Path ([string]$harnessJson1.fixture) 'repo/.work/events.jsonl'
        Assert-True (Test-Path -LiteralPath $harnessEvents1) 'harness clean fixture exposes its events.jsonl outbox'
    }

    # Seed the SAME task ids and batch id the harness clean scenario uses so the two identity
    # sets are directly comparable.
    $sandbox1 = Join-Path ([System.IO.Path]::GetTempPath()) ('orc-parity-engine-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $sandbox1
    $script:TempDirs.Add($sandbox1)

    # Seed each task's on-disk descriptor with an explicit, NON-OVERLAPPING `Конфликт-домен:`
    # BEFORE the engine's admission reads it. T-126 taught `engine run` to read the real
    # conflict-domain from each `tasks/<id>/task.md` and, per its own acceptance criteria, to fail
    # CLOSED on a missing/malformed domain (treat it as conflicting with everything) so two
    # undomained tasks are never packed into one cohort by accident. `queue-tx propose` writes ONLY
    # the queue entry (no descriptor), so without a seeded domain the engine sees two unknown
    # domains and admits just ONE of T-101/T-102 - collapsing the shared identity surface this
    # oracle asserts. Disjoint domains (alpha/** vs beta/**) keep the round genuinely admitting
    # BOTH into one cohort, now via real domain-based packing.
    $seedOk1 = $true
    foreach ($seed in @(@('T-101', 'clean one', 'alpha/**'), @('T-102', 'clean two', 'beta/**'))) {
        $p = Invoke-Ps $script:QueueTx @('propose', '--work', $sandbox1, '--id', $seed[0], '--title', $seed[1])
        if ($p.ExitCode -ne 0) { $script:Failures.Add("FAIL - seed propose $($seed[0]) exited $($p.ExitCode): $($p.Err.Trim())"); $seedOk1 = $false; continue }
        $descDir = Join-Path (Join-Path $sandbox1 'tasks') $seed[0]
        $null = New-Item -ItemType Directory -Force -Path $descDir
        $descText = "# $($seed[0])`nСтатус: не начата`nБатч: $batchId`nКонфликт-домен: $($seed[2])`n"
        [System.IO.File]::WriteAllText((Join-Path $descDir 'task.md'), $descText, $script:Utf8)
    }

    # `--review`: run the T-128 per-task review round too (T-129) - both tasks pass clean at
    # cycle 1 and promote `на ревью -> готова к слиянию`, matching what the harness clean
    # scenario's own Step-ToReady already emits for T-101/T-102.
    $engineEvents1 = Join-Path $sandbox1 'events.jsonl'
    if ($seedOk1) {
        $er1 = Invoke-Proc $script:EngineBin @(
            'run', '--once',
            '--work', $sandbox1,
            '--tools', $script:ToolsDir,
            '--base', 'sandbox-base',
            '--batch', $batchId,
            '--cohort-size', '2',
            '--review',
            '--join',
            '--json')
        if ($er1.ExitCode -ne 0) {
            $script:Failures.Add("FAIL - engine run --once (clean pairing) exited $($er1.ExitCode): $($er1.Err.Trim())$($er1.Out.Trim())")
        } else {
            Assert-True (Test-Path -LiteralPath $engineEvents1) 'engine run (clean pairing) wrote its events.jsonl outbox'
        }
    }

    # ======================================================================
    # PAIRING 2 (T-128 review fix cycle -> REVIEW_LOOP_MAX escalation, T-129): harness scenario
    # `review-cycle` (a single task T-101 whose review never converges) vs
    # `engine run --once --review --inject-findings T-101 --review-loop-max 1` over a FRESH,
    # independent sandbox. Same deterministic shape: findings persist, the budget is 1, so the
    # task takes exactly ONE incomplete cycle (`на ревью -> на ревью`) then escalates
    # (`на ревью -> эскалирована`).
    # ======================================================================
    $harnessJson2 = $null
    $harnessEvents2 = ''
    $hr2 = Invoke-Ps $script:Harness @('scenario', '--vcs', 'git', '--name', 'review-cycle', '--keep', '--json')
    if ($hr2.ExitCode -ne 0) {
        $script:Failures.Add("FAIL - harness review-cycle scenario exited $($hr2.ExitCode): $($hr2.Err.Trim())")
    } else {
        try { $harnessJson2 = $hr2.Out.Trim() | ConvertFrom-Json }
        catch { $script:Failures.Add("FAIL - harness review-cycle scenario produced unparseable JSON: $($hr2.Out)") }
    }
    if ($harnessJson2) {
        $script:TempDirs.Add([string]$harnessJson2.fixture)
        $harnessEvents2 = Join-Path ([string]$harnessJson2.fixture) 'repo/.work/events.jsonl'
        Assert-True (Test-Path -LiteralPath $harnessEvents2) 'harness review-cycle fixture exposes its events.jsonl outbox'
    }

    $sandbox2 = Join-Path ([System.IO.Path]::GetTempPath()) ('orc-parity-engine-review-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $sandbox2
    $script:TempDirs.Add($sandbox2)

    $seedOk2 = $true
    $p2 = Invoke-Ps $script:QueueTx @('propose', '--work', $sandbox2, '--id', 'T-101', '--title', 'review-cycle one')
    if ($p2.ExitCode -ne 0) { $script:Failures.Add("FAIL - seed propose T-101 (review pairing) exited $($p2.ExitCode): $($p2.Err.Trim())"); $seedOk2 = $false }
    else {
        $descDir2 = Join-Path (Join-Path $sandbox2 'tasks') 'T-101'
        $null = New-Item -ItemType Directory -Force -Path $descDir2
        $descText2 = "# T-101`nСтатус: не начата`nБатч: $batchId`nКонфликт-домен: zeta/**`n"
        [System.IO.File]::WriteAllText((Join-Path $descDir2 'task.md'), $descText2, $script:Utf8)
    }

    $engineEvents2 = Join-Path $sandbox2 'events.jsonl'
    if ($seedOk2) {
        $er2 = Invoke-Proc $script:EngineBin @(
            'run', '--once',
            '--work', $sandbox2,
            '--tools', $script:ToolsDir,
            '--base', 'sandbox-base',
            '--batch', $batchId,
            '--cohort-size', '1',
            '--review',
            '--join',
            '--inject-findings', 'T-101',
            '--review-loop-max', '1',
            '--json')
        if ($er2.ExitCode -ne 0) {
            $script:Failures.Add("FAIL - engine run --once (review-cycle pairing) exited $($er2.ExitCode): $($er2.Err.Trim())$($er2.Out.Trim())")
        } else {
            Assert-True (Test-Path -LiteralPath $engineEvents2) 'engine run (review-cycle pairing) wrote its events.jsonl outbox'
        }
    }

    # ======================================================================
    # TERMINAL PAIRING 3 (T-304): a merge conflict quarantines T-102 while
    # T-101 still publishes. The engine's deterministic merger injection is
    # the equivalent hermetic staging knob.
    # ======================================================================
    $harnessJson3 = $null; $harnessEvents3 = ''
    $hr3 = Invoke-Ps $script:Harness @('scenario', '--vcs', 'git', '--name', 'conflict', '--keep', '--json')
    if ($hr3.ExitCode -ne 0) { $script:Failures.Add("FAIL - harness conflict scenario exited $($hr3.ExitCode): $($hr3.Err.Trim())") }
    else { try { $harnessJson3 = $hr3.Out.Trim() | ConvertFrom-Json } catch { $script:Failures.Add("FAIL - harness conflict scenario produced unparseable JSON: $($hr3.Out)") } }
    if ($harnessJson3) { $script:TempDirs.Add([string]$harnessJson3.fixture); $harnessEvents3 = Join-Path ([string]$harnessJson3.fixture) 'repo/.work/events.jsonl' }
    $fixture3 = New-EngineFixture 'conflict' @(
        [pscustomobject]@{ Id = 'T-101'; Title = 'conf one'; Domain = 'alpha/**' },
        [pscustomobject]@{ Id = 'T-102'; Title = 'conf two'; Domain = 'beta/**' })
    if ($fixture3.SeedOk) {
        $er3 = Invoke-EngineScenario $fixture3 @('--cohort-size', '2', '--review', '--join', '--inject-merge-conflict', 'T-102')
        if ($er3.ExitCode -ne 0) { $script:Failures.Add("FAIL - engine conflict pairing exited $($er3.ExitCode): $($er3.Err.Trim())$($er3.Out.Trim())") }
        else {
            Assert-True ($er3.Out -match '"quarantined":\["T-102"\]') 'engine conflict staging quarantined T-102'
            Assert-True ($er3.Out -match '"published":\["T-101"\]') 'engine conflict staging published survivor T-101'
        }
    }

    # ======================================================================
    # TERMINAL PAIRING 4 (T-304): a required integration check never clears
    # quarantine in the prose harness; the engine's deterministic failing
    # integration gate leaves its batch unpublished. Both share the terminal
    # cohort event surface (open/capture/review/ready/join/closed, no publish).
    # ======================================================================
    $harnessJson4 = $null; $harnessEvents4 = ''
    $hr4 = Invoke-Ps $script:Harness @('scenario', '--vcs', 'git', '--name', 'quarantine', '--keep', '--json')
    if ($hr4.ExitCode -ne 0) { $script:Failures.Add("FAIL - harness quarantine scenario exited $($hr4.ExitCode): $($hr4.Err.Trim())") }
    else { try { $harnessJson4 = $hr4.Out.Trim() | ConvertFrom-Json } catch { $script:Failures.Add("FAIL - harness quarantine scenario produced unparseable JSON: $($hr4.Out)") } }
    if ($harnessJson4) { $script:TempDirs.Add([string]$harnessJson4.fixture); $harnessEvents4 = Join-Path ([string]$harnessJson4.fixture) 'repo/.work/events.jsonl' }
    $fixture4 = New-EngineFixture 'quarantine' @([pscustomobject]@{ Id = 'T-101'; Title = 'flaky one'; Domain = 'alpha/**' })
    if ($fixture4.SeedOk) {
        $er4 = Invoke-EngineScenario $fixture4 @('--cohort-size', '1', '--review', '--join', '--inject-f-findings', '--integration-loop-max', '1')
        if ($er4.ExitCode -ne 0) { $script:Failures.Add("FAIL - engine quarantine pairing exited $($er4.ExitCode): $($er4.Err.Trim())$($er4.Out.Trim())") }
        else { Assert-True ($er4.Out -match '"integration":"failed"' -and $er4.Out -match '"published":\[\]') 'engine failing integration gate left the batch unpublished' }
    }

    # ======================================================================
    # TERMINAL PAIRING 5 (T-304): denylisted policy work terminates safely.
    # The harness invokes the real policy guard; the engine uses its existing
    # fail-closed deterministic leaf escalation staging knob.
    # ======================================================================
    $harnessJson5 = $null; $harnessEvents5 = ''
    $hr5 = Invoke-Ps $script:Harness @('scenario', '--vcs', 'git', '--name', 'policy', '--keep', '--json')
    if ($hr5.ExitCode -ne 0) { $script:Failures.Add("FAIL - harness policy scenario exited $($hr5.ExitCode): $($hr5.Err.Trim())") }
    else { try { $harnessJson5 = $hr5.Out.Trim() | ConvertFrom-Json } catch { $script:Failures.Add("FAIL - harness policy scenario produced unparseable JSON: $($hr5.Out)") } }
    if ($harnessJson5) { $script:TempDirs.Add([string]$harnessJson5.fixture); $harnessEvents5 = Join-Path ([string]$harnessJson5.fixture) 'repo/.work/events.jsonl' }
    $fixture5 = New-EngineFixture 'policy' @([pscustomobject]@{ Id = 'T-101'; Title = 'policy one'; Domain = 'alpha/**' })
    if ($fixture5.SeedOk) {
        $er5 = Invoke-EngineScenario $fixture5 @('--cohort-size', '1', '--review', '--join', '--inject-escalate', 'T-101')
        if ($er5.ExitCode -ne 0) { $script:Failures.Add("FAIL - engine policy pairing exited $($er5.ExitCode): $($er5.Err.Trim())$($er5.Out.Trim())") }
        else { Assert-True ($er5.Out -match '"to":"escalated"') 'engine policy staging escalated the denied task' }
    }

    # ======================================================================
    # TERMINAL PAIRING 6 (T-304): a passing required-check gate reaches the
    # same one-task publication/archival surface as the engine join barrier.
    # ======================================================================
    $harnessJson6 = $null; $harnessEvents6 = ''
    $hr6 = Invoke-Ps $script:Harness @('scenario', '--vcs', 'git', '--name', 'checks', '--keep', '--json')
    if ($hr6.ExitCode -ne 0) { $script:Failures.Add("FAIL - harness checks scenario exited $($hr6.ExitCode): $($hr6.Err.Trim())") }
    else { try { $harnessJson6 = $hr6.Out.Trim() | ConvertFrom-Json } catch { $script:Failures.Add("FAIL - harness checks scenario produced unparseable JSON: $($hr6.Out)") } }
    if ($harnessJson6) { $script:TempDirs.Add([string]$harnessJson6.fixture); $harnessEvents6 = Join-Path ([string]$harnessJson6.fixture) 'repo/.work/events.jsonl' }
    $fixture6 = New-EngineFixture 'checks' @([pscustomobject]@{ Id = 'T-101'; Title = 'checks one'; Domain = 'alpha/**' })
    if ($fixture6.SeedOk) {
        $er6 = Invoke-EngineScenario $fixture6 @('--cohort-size', '1', '--review', '--join')
        if ($er6.ExitCode -ne 0) { $script:Failures.Add("FAIL - engine checks pairing exited $($er6.ExitCode): $($er6.Err.Trim())$($er6.Out.Trim())") }
        else { Assert-True ($er6.Out -match '"published":\["T-101"\]') 'engine checks staging published T-101' }
    }

    # ======================================================================
    # Compare the fingerprints.
    # ======================================================================
    if ($harnessJson1 -and $harnessJson2 -and (Test-Path -LiteralPath $harnessEvents1) -and (Test-Path -LiteralPath $harnessEvents2) -and
        (Test-Path -LiteralPath $engineEvents1) -and (Test-Path -LiteralPath $engineEvents2)) {
        $harnessIds1 = Get-OutboxIdentities $harnessEvents1
        $harnessIds2 = Get-OutboxIdentities $harnessEvents2
        $engineIds1 = Get-OutboxIdentities $engineEvents1
        $engineIds2 = Get-OutboxIdentities $engineEvents2

        # Faithfulness: our extractor reproduces the harness's own Get-OutboxDigest byte-for-byte
        # over EACH run's own events.jsonl, so "the same fingerprint the harness already
        # computes" is proven, not merely asserted - for both pairings.
        Assert-Equal ([string]$harnessJson1.outbox) (Digest-Of $harnessIds1) `
            'our identity extractor reproduces harness Get-OutboxDigest byte-for-byte (clean pairing)'
        Assert-Equal ([string]$harnessJson2.outbox) (Digest-Of $harnessIds2) `
            'our identity extractor reproduces harness Get-OutboxDigest byte-for-byte (review-cycle pairing)'

        # The compared surface is the UNION of both pairings' identities (each pairing is its own
        # independent hermetic fixture; the outbox itself is never shared between them).
        $harnessAll = @($harnessIds1) + @($harnessIds2)
        $engineAll = @($engineIds1) + @($engineIds2)
        $harnessCompared = @(Select-Compared $harnessAll | Sort-Object -Unique)
        $engineCompared = @(Select-Compared $engineAll | Sort-Object -Unique)

        # Vacuous-pass guard: the shared surface is exactly these fourteen identities. Cohort-level
        # events collapse across the two pairings that reuse the harness's fixed BatchId: the two
        # `cohort.opened` collapse to one, and so does `cohort.closed` (both the `clean` pairing and
        # the `review-cycle` pairing emit it — the latter closes the cohort even though its single
        # task escalated and nothing was published), while `cohort.join_started`/`cohort.published`
        # come ONLY from the `clean` pairing (the `review-cycle` pairing has no ready task to merge,
        # so its join barrier emits only `cohort.closed`). T-101's `в работе>на ревью` also collapses
        # (T-101 recurs, by harness convention, as the primary task id of both scenarios). So an
        # empty-vs-empty match can never masquerade as convergence, and a missing transition is
        # caught explicitly.
        $expected = @(
            "cohort.opened|$batchId||",
            "task.captured|$batchId|T-101|",
            "task.captured|$batchId|T-102|",
            "task.status_changed||T-101|$script:ReviewTransition",
            "task.status_changed||T-102|$script:ReviewTransition",
            "task.status_changed||T-101|$script:ReadyTransition",
            "task.status_changed||T-102|$script:ReadyTransition",
            "task.status_changed||T-101|$script:ReviewLoopTransition",
            "task.status_changed||T-101|$script:ReviewEscalateTransition",
            "cohort.join_started|$batchId||",
            "cohort.published|$batchId||",
            "cohort.closed|$batchId||",
            "task.status_changed||T-101|$script:PublishTransition",
            "task.status_changed||T-102|$script:PublishTransition"
        ) | Sort-Object
        Assert-Equal ($expected -join "`n") ($harnessCompared -join "`n") 'processor-prose (harness) emits exactly the shared compared identity set'
        Assert-Equal ($expected -join "`n") ($engineCompared -join "`n") 'the engine emits exactly the shared compared identity set'

        # THE ORACLE: both paths converge on the SAME compared-surface fingerprint.
        $harnessFp = Compared-Fingerprint $harnessAll
        $engineFp = Compared-Fingerprint $engineAll
        Assert-Equal $harnessFp $engineFp 'engine and processor-prose converge on the SAME final-state fingerprint over the shared vocabulary (cutover oracle, intent §9.2)'
        Write-Host "compared-surface fingerprint (processor-prose): $harnessFp"
        Write-Host "compared-surface fingerprint (engine)         : $engineFp"

        # Negative self-check: the detector has teeth. Perturbing ONE identity (a drifted
        # review/fix-cycle transition) must change the fingerprint, so a real divergence cannot
        # pass green.
        $perturbed = @($engineCompared) + @("task.status_changed||T-999|$script:ReviewEscalateTransition")
        $perturbedFp = Sha256Hex ((@($perturbed) | Sort-Object -Unique) -join ';')
        Assert-True ($perturbedFp -cne $engineFp) 'a perturbed review/fix-cycle identity yields a DIFFERENT fingerprint (drift detector has teeth)'
    }

    # Each terminal pairing is checked independently. Do not merge these into the aggregate
    # clean/review-cycle fingerprint above: doing so would allow a clean scenario to make a
    # terminal pairing vacuous by contributing the same broad event identities.
    if ($harnessJson3) { Assert-Equal 'partial' ([string]$harnessJson3.outcome) 'harness conflict terminal outcome is partial publication' }
    Assert-ScenarioPair 'conflict' $harnessJson3 $harnessEvents3 $fixture3.Events
    if ($harnessJson4) { Assert-Equal 'escalated' ([string]$harnessJson4.outcome) 'harness quarantine terminal outcome is escalation after bounded retries' }
    Assert-ScenarioPair 'quarantine/check-gate' $harnessJson4 $harnessEvents4 $fixture4.Events
    if ($harnessJson5) { Assert-Equal 'escalated' ([string]$harnessJson5.outcome) 'harness policy terminal outcome is safe escalation' }
    Assert-ScenarioPair 'policy' $harnessJson5 $harnessEvents5 $fixture5.Events -PolicySurface
    if ($harnessJson6) { Assert-Equal 'published' ([string]$harnessJson6.outcome) 'harness required-check terminal outcome is publication' }
    Assert-ScenarioPair 'checks' $harnessJson6 $harnessEvents6 $fixture6.Events
} finally {
    Cleanup
}

# ==========================================================================
# Report.
# ==========================================================================
if ($script:Failures.Count -eq 0) {
    Write-Host 'OK - engine and processor-prose converge on clean, review-cycle and terminal conflict/quarantine/policy/checks parity surfaces (pre-cutover equivalence oracle, T-110 + T-128 + T-304).'
    exit 0
}
Write-Host "FAILED - $($script:Failures.Count) assertion(s):"
foreach ($f in $script:Failures) { Write-Host "  $f" }
exit 1
