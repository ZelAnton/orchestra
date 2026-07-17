<#
.SYNOPSIS
    Execution supervisor for Orchestra's executor calls: a policy-configurable
    deadline / attempt / output-volume / cohort-budget bound around one child
    invocation, with a four-way stop-reason classification and a lease-compatible
    cancellation checkpoint (task T-093).

.DESCRIPTION
    Orchestra's control loop (agents/processor.md) spawns executor calls (coder /
    reviewer / merger / codex) whose duration and output are otherwise unbounded: a
    hung or run-away call can hold a whole round, and there is no single place that
    (a) enforces a deadline, (b) bounds the retry count, (c) caps the captured output
    volume, (d) tracks a cohort-wide wall-clock budget, and (e) tells the FOUR
    materially different stop reasons apart so the processor can route each to its own
    handling. This tool is that place. It is the executable companion of
    tools/queue-tx.ps1 / state-tx.ps1 / outbox.ps1: it never mutates the queue, the
    lease, or the outbox itself - it supervises ONE call and returns a structured,
    non-sensitive verdict the processor acts on.

    The four stop reasons (each a distinct exit code and a distinct processor path):

      * ok        (exit 0) - the call finished with a success exit code.
      * timeout   (exit 3) - the call exceeded --deadline-sec; its whole child process
                             tree was terminated. TRANSIENT: a bounded safe retry is
                             appropriate (supervise retries it up to --max-attempts,
                             then escalates).
      * cancelled (exit 4) - a cooperative cancellation was requested (--cancel-file
                             appeared, e.g. the .work/PAUSE kill switch, or an operator
                             stop). The child tree is terminated and a resume checkpoint
                             is saved; NOT a failure. The processor frees the slot and
                             lets independent ready tasks keep progressing.
      * crash     (exit 5) - a tool/infrastructure crash: the process could not be
                             spawned, was killed by a signal, or exited with a code in
                             --crash-exit-codes. TRANSIENT like timeout: bounded retry.
      * error     (exit 6) - a SUBSTANTIVE executor error: the call ran to completion and
                             reported a content-level failure (a nonzero exit not in the
                             crash set). This is the quarantine/requeue path (bounded by
                             the processor's QUARANTINE_MAX_ATTEMPTS), NOT an infinite
                             retry.
      * budget    (exit 7) - the cohort wall-clock budget (--budget-sec / --budget-file)
                             is exhausted; the call is not (re)started.

    Privacy. The durable verdict (--result-file, and the codex.attempt event args
    `observe` emits) carries only SCALAR, non-sensitive facts - reason, exit code,
    duration_ms, attempt, output byte count and a sha256 of the captured output, plus a
    CLASSIFIER-derived outcome_reason ("deadline exceeded (Ns)", "cancel requested",
    "exit code N", "spawn failed") that is never raw executor output. The raw stdout /
    stderr go ONLY to the transient --stdout-file / --stderr-file capture (bounded to
    --output-max-bytes), never into the durable record, so the outbox/journal cannot leak
    a secret from a call's output (compatible with tools/redaction.ps1, which `observe`
    additionally runs over any free-text reason as defense in depth).

    The cancellation/timeout checkpoint (--checkpoint-file) is additive to and compatible
    with the Phase-0 lease (tools/state-tx.ps1 `.work/orchestrator.lock/lease.json`): it
    carries the run owner_id, a heartbeat and a ttl, records task/batch/attempt/reason/
    elapsed, and NEVER removes or rewrites the lease - a resume re-reads it to continue
    the same task under the same owner.

.NOTES
    Runs under PowerShell 7 (pwsh) and Windows PowerShell 5.1. Child-tree termination uses
    Process.Kill($true) (entire process tree) on .NET 5+, and on Windows PowerShell 5.1
    falls back to taskkill /T /F. All files are read/written UTF-8 without BOM, matching the
    .work/*.md convention.

    Exit codes:
      0  ok
      2  usage / argument error
      3  timeout   (deadline exceeded)
      4  cancelled (cooperative cancellation)
      5  crash     (spawn failure / signal kill / crash-exit-code)
      6  error     (substantive executor error)
      7  budget    (cohort budget exhausted)

.EXAMPLE
    pwsh -File tools/supervisor.ps1 run --file worker.ps1 --args-json '["--id","T-1"]' --deadline-sec 60 --result-file r.json
    pwsh -File tools/supervisor.ps1 supervise --exe git --args-json '["status"]' --max-attempts 2 --budget-file b.json --budget-sec 600 --checkpoint-file cp.json --work /abs/.work --owner OWN --task-id T-1
    pwsh -File tools/supervisor.ps1 observe --result-file r.json --stdout-file out.txt --task-id T-1 --role coder --source claude --work /abs/.work --json
    pwsh -File tools/supervisor.ps1 budget --budget-file b.json --json
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# Shared infrastructure primitives (arg-parse, Fail/Opt/Require-Opt + catch dispatcher,
# Read-TextOrEmpty, Format-UtcNow, ConvertTo-Win32Arg/ConvertTo-Win32CommandLine; T-240).
# Dot-sourced like tools/proc-tree.ps1 (loaded below).
. (Join-Path $PSScriptRoot 'common.ps1')
$script:ErrPrefix = 'SPVERR'  # coded-error tag decoded by the catch dispatcher

# --------------------------------------------------------------------------
# Argument parsing:  <command> [--key value | --flag] ...  (shape of queue-tx.ps1)
# --------------------------------------------------------------------------
$parsed = Parse-CliArgs $args -BoolFlags @('json', 'reset', 'no-checkpoint')
$Command = $parsed.Command
$opts = $parsed.Opts

function Has-Prop { param($Obj, [string]$Name) return ($null -ne $Obj -and $null -ne $Obj.PSObject.Properties[$Name]) }
function Get-Prop { param($Obj, [string]$Name) if (Has-Prop $Obj $Name) { return $Obj.$Name } else { return $null } }

# --------------------------------------------------------------------------
# Reason -> exit-code contract (single source of truth).
# --------------------------------------------------------------------------
$script:ReasonExit = [ordered]@{ ok = 0; timeout = 3; cancelled = 4; crash = 5; error = 6; budget = 7 }
# TRANSIENT reasons are the ones `supervise` retries (a safe bounded retry); ok/error/
# cancelled/budget are terminal for the loop (success / quarantine / checkpoint / stop).
$script:TransientReasons = @('timeout', 'crash')

# --------------------------------------------------------------------------
# Small IO helpers.
# --------------------------------------------------------------------------
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
# Read-TextOrEmpty comes from tools/common.ps1 (T-240). Write-TextNoBom / Write-JsonAtomic
# stay local: they write with the explicit no-BOM $script:Utf8 encoding this tool pins.
function Write-TextNoBom {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    [System.IO.File]::WriteAllText($Path, $Content, $script:Utf8)
}
function Write-JsonAtomic {
    param([string]$Path, $Object)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, ($Object | ConvertTo-Json -Depth 12), $script:Utf8)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Sha256Hex { param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $h = $sha.ComputeHash($Bytes) } finally { $sha.Dispose() }
    return -join ($h | ForEach-Object { $_.ToString('x2') })
}
# Format-UtcNow comes from tools/common.ps1 (T-240).
function Parse-IntOpt {
    param([string]$Name, [int]$Default, [int]$Min = 0)
    $raw = [string](Opt $Name "$Default")
    if ([string]::IsNullOrEmpty($raw)) { return $Default }
    if ($raw -notmatch '^-?\d+$') { Fail 2 "--$Name must be an integer (got '$raw')" }
    $n = [int]$raw
    if ($n -lt $Min) { Fail 2 "--$Name must be >= $Min (got $n)" }
    return $n
}
function Parse-IntList {
    param([string]$Raw)
    $out = New-Object System.Collections.Generic.List[int]
    if ($Raw) { foreach ($t in ($Raw -split '[,\s]+')) { if ($t -match '^-?\d+$') { [void]$out.Add([int]$t) } } }
    return , $out.ToArray()
}

# CommandLineToArgvW-correct quoting for the Windows PowerShell 5.1 fallback
# (ConvertTo-Win32Arg / ConvertTo-Win32CommandLine) comes from tools/common.ps1 (T-240),
# shared with tools/codex-runtime.ps1 instead of a per-file copy.

# --------------------------------------------------------------------------
# Resolve the call target: --file <script.ps1> runs through this pwsh host; --exe
# <path> is spawned directly. Arguments come as a JSON array (--args-json), so a value
# with spaces/quotes/metacharacters is one argv element, never a shell fragment.
# --------------------------------------------------------------------------
function Resolve-Target {
    $file = [string](Opt 'file' '')
    $exe = [string](Opt 'exe' '')
    if ($file -and $exe) { Fail 2 "use either --file or --exe, not both" }
    $extraArgs = @()
    $argsJson = [string](Opt 'args-json' '')
    if ($argsJson) {
        $parsed = $null
        try { $parsed = $argsJson | ConvertFrom-Json } catch { Fail 2 "--args-json is not valid JSON" }
        if ($null -eq $parsed) { $parsed = @() }
        if ($parsed -isnot [array]) { $parsed = @($parsed) }
        $extraArgs = @($parsed | ForEach-Object { [string]$_ })
    }
    if ($file) {
        $psHost = ([System.Diagnostics.Process]::GetCurrentProcess()).MainModule.FileName
        return [pscustomobject]@{ FilePath = $psHost; Args = (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $file) + $extraArgs) }
    }
    if (-not $exe) { Fail 2 "need --file <script.ps1> or --exe <path>" }
    return [pscustomobject]@{ FilePath = $exe; Args = @($extraArgs) }
}

# --------------------------------------------------------------------------
# Terminate the whole child process TREE (so a call that itself spawned workers
# leaves nothing behind on cancel/timeout). Single-sourced in tools/proc-tree.ps1
# so this and tools/codex-runtime.ps1 share one hardened implementation rather than
# a per-file copy that could drift (T-256).
# --------------------------------------------------------------------------
. (Join-Path $PSScriptRoot 'proc-tree.ps1')

# --------------------------------------------------------------------------
# Cap a captured stream to $MaxBytes (0 = unlimited) on a UTF-8 byte budget, reporting
# the FULL byte count (for observability) alongside the (possibly truncated) text kept
# for the transient capture file. GetString over a byte slice never throws on a cut
# multibyte char (it emits a replacement char), which is fine for a truncated capture.
# --------------------------------------------------------------------------
function Get-CappedText {
    param([string]$Text, [int]$MaxBytes)
    if ($null -eq $Text) { $Text = '' }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    if ($MaxBytes -le 0 -or $bytes.Length -le $MaxBytes) {
        return [pscustomobject]@{ Text = $Text; TotalBytes = $bytes.Length; Truncated = $false }
    }
    $kept = [System.Text.Encoding]::UTF8.GetString($bytes, 0, $MaxBytes)
    return [pscustomobject]@{ Text = $kept; TotalBytes = $bytes.Length; Truncated = $true }
}

# ==========================================================================
# Core: supervise ONE child call. Returns a structured, non-sensitive result.
# ==========================================================================
function Invoke-SupervisedCall {
    param(
        [string]$FilePath, [string[]]$CallArgs, [string]$StdinText,
        [int]$DeadlineSec, [string]$CancelFile, [int]$OutputMaxBytes,
        [int[]]$CrashExitCodes, [int[]]$ErrorExitCodes
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($prop in @('StandardOutputEncoding', 'StandardErrorEncoding', 'StandardInputEncoding')) {
        if ($psi | Get-Member -Name $prop -MemberType Property -ErrorAction SilentlyContinue) { try { $psi.$prop = $script:Utf8 } catch { } }
    }
    $hasArgList = [bool]($psi | Get-Member -Name 'ArgumentList' -MemberType Property -ErrorAction SilentlyContinue)
    if ($hasArgList) { foreach ($a in $CallArgs) { $psi.ArgumentList.Add($a) } }
    else { $psi.Arguments = ConvertTo-Win32CommandLine $CallArgs }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try { [void]$proc.Start() }
    catch {
        # The process could not even be spawned - a tool/infrastructure crash.
        $sw.Stop()
        return [pscustomobject]@{
            reason = 'crash'; exit_code = $null; timed_out = $false; cancelled = $false
            duration_ms = [int]$sw.Elapsed.TotalMilliseconds; output_bytes = 0; output_truncated = $false
            output_sha256 = (Sha256Hex ([byte[]]@())); stdout = ''; stderr = ''
            outcome_reason = "spawn failed: $($_.Exception.Message)"; pid = $null
        }
    }

    # Async .NET reads (Task<string>, no PowerShell scriptblock on a raw thread) so a large
    # stdout/stderr cannot deadlock against the stdin write; the byte cap is applied after.
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    try { $proc.StandardInput.Write($StdinText); $proc.StandardInput.Close() }
    catch {
        # The child may exit before consuming stdin - not fatal.
    }

    $timedOut = $false
    $cancelled = $false
    $deadlineMs = if ($DeadlineSec -gt 0) { [int64]$DeadlineSec * 1000 } else { 0 }
    while (-not $proc.WaitForExit(100)) {
        if ($deadlineMs -gt 0 -and $sw.Elapsed.TotalMilliseconds -ge $deadlineMs) { $timedOut = $true; break }
        if ($CancelFile -and (Test-Path -LiteralPath $CancelFile)) { $cancelled = $true; break }
    }
    if ($timedOut -or $cancelled) { Stop-ProcessTree $proc }
    else { try { $proc.WaitForExit() } catch { } }
    $sw.Stop()

    $stdoutFull = ''; $stderrFull = ''
    try { $stdoutFull = [string]$outTask.GetAwaiter().GetResult() } catch { $stdoutFull = '' }
    try { $stderrFull = [string]$errTask.GetAwaiter().GetResult() } catch { $stderrFull = '' }
    $outRes = Get-CappedText $stdoutFull $OutputMaxBytes
    $errRes = Get-CappedText $stderrFull $OutputMaxBytes
    $stdout = $outRes.Text
    $stderr = $errRes.Text
    $totalBytes = [int]($outRes.TotalBytes + $errRes.TotalBytes)
    $truncated = ($outRes.Truncated -or $errRes.Truncated)
    # sha over the FULL captured bytes (an integrity fingerprint of what the call produced,
    # independent of the display truncation) - a non-sensitive scalar for the durable record.
    $sha = Sha256Hex ($script:Utf8.GetBytes($stdoutFull + $stderrFull))

    $rc = $null
    try { $rc = $proc.ExitCode } catch { $rc = $null }
    $procId = $null
    try { $procId = $proc.Id } catch { $procId = $null }
    try { $proc.Dispose() } catch { }

    # Classify the four stop reasons.
    $reason = 'error'
    $outcomeReason = ''
    if ($cancelled) {
        $reason = 'cancelled'; $outcomeReason = 'cancel requested'
    } elseif ($timedOut) {
        $reason = 'timeout'; $outcomeReason = "deadline exceeded (${DeadlineSec}s)"
    } elseif ($null -eq $rc) {
        $reason = 'crash'; $outcomeReason = 'exit code unavailable after run'
    } elseif ($rc -eq 0) {
        $reason = 'ok'; $outcomeReason = 'exit code 0'
    } elseif ($CrashExitCodes -contains $rc) {
        $reason = 'crash'; $outcomeReason = "crash exit code $rc"
    } elseif ($ErrorExitCodes.Count -gt 0 -and ($ErrorExitCodes -notcontains $rc)) {
        # Caller declared an explicit substantive-error set; a nonzero code outside BOTH
        # the crash set and the error set is treated as a crash (unknown/abnormal).
        $reason = 'crash'; $outcomeReason = "unclassified exit code $rc"
    } else {
        $reason = 'error'; $outcomeReason = "exit code $rc"
    }

    return [pscustomobject]@{
        reason = $reason; exit_code = $rc; timed_out = $timedOut; cancelled = $cancelled
        duration_ms = [int]$sw.Elapsed.TotalMilliseconds; output_bytes = $totalBytes
        output_truncated = $truncated; output_sha256 = $sha; stdout = $stdout; stderr = $stderr
        outcome_reason = $outcomeReason; pid = $procId
    }
}

# --------------------------------------------------------------------------
# Persist the (non-sensitive) verdict + the (transient) captured streams.
# --------------------------------------------------------------------------
function Save-CallArtifacts {
    param(
        $Res,
        [int]$Attempt = 1,
        [int]$BudgetRemainingMs = -1,
        [int]$TotalDurationMs = -1,
        [string]$Checkpoint = ''
    )
    $stdoutFile = [string](Opt 'stdout-file' '')
    $stderrFile = [string](Opt 'stderr-file' '')
    if ($stdoutFile) { Write-TextNoBom $stdoutFile $Res.stdout }
    if ($stderrFile) { Write-TextNoBom $stderrFile $Res.stderr }
    $verdict = New-Verdict $Res $Attempt $BudgetRemainingMs
    if ($TotalDurationMs -ge 0) { $verdict['total_duration_ms'] = $TotalDurationMs }
    if ($Checkpoint) { $verdict['checkpoint'] = $Checkpoint }
    $resultFile = [string](Opt 'result-file' '')
    if ($resultFile) { Write-JsonAtomic $resultFile $verdict }
    return $verdict
}
# The DURABLE verdict: scalars only, NO raw stdout/stderr (privacy).
function New-Verdict {
    param($Res, [int]$Attempt = 1, [int]$BudgetRemainingMs = -1)
    $v = [ordered]@{
        reason           = $Res.reason
        exit_code        = $Res.exit_code
        timed_out        = $Res.timed_out
        cancelled        = $Res.cancelled
        duration_ms      = $Res.duration_ms
        attempts         = $Attempt
        output_bytes     = $Res.output_bytes
        output_truncated = $Res.output_truncated
        output_sha256    = $Res.output_sha256
        outcome_reason   = $Res.outcome_reason
        occurred_at      = (Format-UtcNow)
    }
    if ($BudgetRemainingMs -ge 0) { $v['budget_remaining_ms'] = $BudgetRemainingMs }
    return $v
}

# --------------------------------------------------------------------------
# Cancellation / timeout checkpoint - additive to and compatible with the Phase-0
# lease (owner_id + heartbeat + ttl), never removing or rewriting the lease itself.
# --------------------------------------------------------------------------
function Read-LeaseOwner {
    param([string]$Work)
    if (-not $Work) { return '' }
    $lease = Join-Path $Work 'orchestrator.lock/lease.json'
    if (-not (Test-Path -LiteralPath $lease)) { return '' }
    try { return [string]((Read-TextOrEmpty $lease | ConvertFrom-Json).owner_id) } catch { return '' }
}
function Write-Checkpoint {
    param($Res, [int]$Attempt)
    if ([bool](Opt 'no-checkpoint' $false)) { return $null }
    $cp = [string](Opt 'checkpoint-file' '')
    if (-not $cp) {
        $work = [string](Opt 'work' '')
        $taskId = [string](Opt 'task-id' '')
        if ($work -and $taskId) { $cp = Join-Path $work "tasks/$taskId/supervisor_checkpoint.json" }
    }
    if (-not $cp) { return $null }
    $owner = [string](Opt 'owner' '')
    if (-not $owner) { $owner = Read-LeaseOwner ([string](Opt 'work' '')) }
    $now = Format-UtcNow
    $rec = [ordered]@{
        schema         = 'orchestra/supervisor-checkpoint@1'
        task_id        = [string](Opt 'task-id' '')
        batch_id       = [string](Opt 'batch-id' '')
        owner_id       = $owner
        attempt        = $Attempt
        reason         = $Res.reason
        outcome_reason = $Res.outcome_reason
        elapsed_ms     = $Res.duration_ms
        heartbeat      = $now
        ttl_seconds    = (Parse-IntOpt 'ttl' 900 1)
        occurred_at    = $now
        resumable      = ($Res.reason -in @('cancelled', 'timeout', 'crash'))
    }
    Write-JsonAtomic $cp $rec
    return $cp
}

# --------------------------------------------------------------------------
# Cohort wall-clock budget file: { budget_sec, consumed_ms, started_at, batch_id, owner_id }.
# --------------------------------------------------------------------------
function Read-Budget {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Read-TextOrEmpty $Path | ConvertFrom-Json) } catch { return $null }
}
function Init-Budget {
    param([string]$Path, [int]$BudgetSec)
    $rec = [ordered]@{
        schema      = 'orchestra/cohort-budget@1'
        budget_sec  = $BudgetSec
        consumed_ms = 0
        started_at  = (Format-UtcNow)
        batch_id    = [string](Opt 'batch-id' '')
        owner_id    = [string](Opt 'owner' '')
    }
    Write-JsonAtomic $Path $rec
    return $rec
}
function Get-BudgetRemainingMs {
    param($Budget)
    if ($null -eq $Budget) { return -1 }
    $bs = [int](Get-Prop $Budget 'budget_sec')
    if ($bs -le 0) { return [int]::MaxValue }   # 0 = unlimited
    $consumed = [int](Get-Prop $Budget 'consumed_ms')
    return ([int64]$bs * 1000 - $consumed)
}
function Consume-Budget {
    param([string]$Path, $Budget, [int]$DeltaMs)
    if ($null -eq $Budget) { return }
    $consumed = [int](Get-Prop $Budget 'consumed_ms') + $DeltaMs
    $rec = [ordered]@{
        schema      = 'orchestra/cohort-budget@1'
        budget_sec  = [int](Get-Prop $Budget 'budget_sec')
        consumed_ms = $consumed
        started_at  = [string](Get-Prop $Budget 'started_at')
        batch_id    = [string](Get-Prop $Budget 'batch_id')
        owner_id    = [string](Get-Prop $Budget 'owner_id')
    }
    Write-JsonAtomic $Path $rec
}

# --------------------------------------------------------------------------
# Shared option resolution for run / supervise.
# --------------------------------------------------------------------------
function Resolve-CallOptions {
    $stdin = ''
    if ($opts.ContainsKey('stdin-text')) { $stdin = [string]$opts['stdin-text'] }
    elseif ($opts.ContainsKey('stdin-file')) { $stdin = Read-TextOrEmpty ([string]$opts['stdin-file']) }
    return [pscustomobject]@{
        Deadline    = (Parse-IntOpt 'deadline-sec' 0 0)
        CancelFile  = [string](Opt 'cancel-file' '')
        OutputMax   = (Parse-IntOpt 'output-max-bytes' 1048576 0)
        Crash       = (Parse-IntList ([string](Opt 'crash-exit-codes' '')))
        ErrorCodes  = (Parse-IntList ([string](Opt 'error-exit-codes' '')))
        Stdin       = $stdin
    }
}

# ==========================================================================
# Commands
# ==========================================================================
function Cmd-Run {
    $target = Resolve-Target
    $co = Resolve-CallOptions
    $res = Invoke-SupervisedCall -FilePath $target.FilePath -CallArgs $target.Args -StdinText $co.Stdin `
        -DeadlineSec $co.Deadline -CancelFile $co.CancelFile -OutputMaxBytes $co.OutputMax `
        -CrashExitCodes $co.Crash -ErrorExitCodes $co.ErrorCodes
    $verdict = Save-CallArtifacts $res 1 -1
    if ($res.reason -in @('cancelled', 'timeout')) { [void](Write-Checkpoint $res 1) }
    Emit-Verdict $verdict
    exit ([int]$script:ReasonExit[$res.reason])
}

function Cmd-Supervise {
    $target = Resolve-Target
    $co = Resolve-CallOptions
    $maxAttempts = Parse-IntOpt 'max-attempts' 2 1

    # Cohort budget (optional).
    $budgetFile = [string](Opt 'budget-file' '')
    $budget = $null
    if ($budgetFile) {
        $budget = Read-Budget $budgetFile
        if ($null -eq $budget) {
            $bs = Parse-IntOpt 'budget-sec' 0 0
            $budget = Init-Budget $budgetFile $bs
        }
        $remaining = Get-BudgetRemainingMs $budget
        if ($remaining -le 0) {
            $res = [pscustomobject]@{ reason = 'budget'; exit_code = $null; timed_out = $false; cancelled = $false; duration_ms = 0; output_bytes = 0; output_truncated = $false; output_sha256 = (Sha256Hex ([byte[]]@())); stdout = ''; stderr = ''; outcome_reason = 'cohort budget exhausted'; pid = $null }
            $verdict = Save-CallArtifacts $res 0 0 0
            Emit-Verdict $verdict
            exit ([int]$script:ReasonExit['budget'])
        }
    }

    $attempt = 0
    $res = $null
    $totalMs = 0
    while ($attempt -lt $maxAttempts) {
        $attempt++
        # Trim this call's deadline to what the cohort budget still allows.
        $callDeadline = $co.Deadline
        if ($null -ne $budget) {
            $remainingSec = [int][math]::Floor((Get-BudgetRemainingMs $budget) / 1000.0)
            if ($remainingSec -le 0) { break }
            if ($callDeadline -le 0 -or $remainingSec -lt $callDeadline) { $callDeadline = $remainingSec }
        }
        $res = Invoke-SupervisedCall -FilePath $target.FilePath -CallArgs $target.Args -StdinText $co.Stdin `
            -DeadlineSec $callDeadline -CancelFile $co.CancelFile -OutputMaxBytes $co.OutputMax `
            -CrashExitCodes $co.Crash -ErrorExitCodes $co.ErrorCodes
        $totalMs += $res.duration_ms
        if ($null -ne $budget) { Consume-Budget $budgetFile $budget $res.duration_ms; $budget = Read-Budget $budgetFile }
        # Terminal reasons stop the loop immediately: ok (done), error (quarantine),
        # cancelled (checkpoint + free slot). Only timeout/crash retry.
        if ($res.reason -notin $script:TransientReasons) { break }
        # A transient failure: retry only if attempts AND budget remain.
        if ($attempt -ge $maxAttempts) { break }
        if ($null -ne $budget -and (Get-BudgetRemainingMs $budget) -le 0) { break }
    }

    # The budget can be positive but under a second (sub-deadline granularity): the loop
    # then breaks before running any call. Report it as a budget stop rather than trimming
    # the deadline to 0 (which would DISABLE the deadline) or dereferencing a null result.
    if ($null -eq $res) {
        $res = [pscustomobject]@{ reason = 'budget'; exit_code = $null; timed_out = $false; cancelled = $false; duration_ms = 0; output_bytes = 0; output_truncated = $false; output_sha256 = (Sha256Hex ([byte[]]@())); stdout = ''; stderr = ''; outcome_reason = 'cohort budget too small to run a call'; pid = $null }
        $attempt = 0
    }

    $budgetRemaining = if ($null -ne $budget) { [int][math]::Max(0, (Get-BudgetRemainingMs $budget)) } else { -1 }
    $cp = $null
    if ($res.reason -in @('cancelled', 'timeout', 'crash')) { $cp = Write-Checkpoint $res $attempt }
    $checkpointName = if ($cp) { Split-Path -Leaf $cp } else { '' }
    $verdict = Save-CallArtifacts $res $attempt $budgetRemaining $totalMs $checkpointName
    Emit-Verdict $verdict
    exit ([int]$script:ReasonExit[$res.reason])
}

# ==========================================================================
# observe : turn a verdict into non-sensitive observability outputs (a journal line
# + codex.attempt event args) with any free-text run through redaction. NEVER emits
# raw stdout/stderr. With --stdout-file it ALSO parses per-call token usage out of a
# headless `claude -p --output-format stream-json` transcript and surfaces a
# usage.recorded event-args set (T-248) - only the non-sensitive integer counts, never
# the transcript text; absent/garbled input just omits it.
# ==========================================================================
function Invoke-Redact {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $redactor = Join-Path $PSScriptRoot 'redaction.ps1'
    if (-not (Test-Path -LiteralPath $redactor)) { return $Text }
    try {
        $psExe = ([System.Diagnostics.Process]::GetCurrentProcess()).MainModule.FileName
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $psExe
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        foreach ($a in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $redactor, 'redact')) { $psi.ArgumentList.Add($a) }
        $p = [System.Diagnostics.Process]::Start($psi)
        $outT = $p.StandardOutput.ReadToEndAsync()
        $p.StandardInput.Write($Text); $p.StandardInput.Close()
        $p.WaitForExit()
        $o = $outT.GetAwaiter().GetResult()
        return ([string]$o)
    } catch {
        # Redaction is defense in depth over already-classifier-derived text; if the
        # redactor cannot be spawned, fall back to the (non-raw) input unchanged.
        return $Text
    }
}

# --------------------------------------------------------------------------
# Per-call token usage from a headless `claude -p --output-format stream-json` transcript
# (T-248). The authoritative figures ride the FINAL `{"type":"result", ...}` event's `usage`
# object (last result wins); earlier assistant/tool events are ignored. These are provider-
# ACTUAL counts (estimated=$false). Best-effort: an absent/garbled transcript yields $null and
# no usage is surfaced - exactly like the rest of the telemetry, it never changes control flow.
# The transcript is read ONLY to extract non-sensitive integer counts; no raw text is emitted.
# --------------------------------------------------------------------------
function Read-UsageInt {
    param($UsageObj, [string]$Name)
    if ((Has-Prop $UsageObj $Name)) {
        $v = $UsageObj.$Name
        if ($null -ne $v -and ([string]$v -match '^\d+$')) { return [int]$v }
    }
    return 0
}
function Get-StreamJsonUsage {
    param([string]$Transcript)
    if ([string]::IsNullOrEmpty($Transcript)) { return $null }
    $usage = $null
    foreach ($line in ($Transcript -split "`n")) {
        $t = $line.Trim()
        if (-not $t.StartsWith('{')) { continue }
        $ev = $null
        try { $ev = $t | ConvertFrom-Json } catch { continue }
        if ($null -eq $ev) { continue }
        if (([string](Get-Prop $ev 'type')) -ne 'result') { continue }
        $u = Get-Prop $ev 'usage'
        if ($null -ne $u -and $u -is [System.Management.Automation.PSCustomObject]) { $usage = $u }   # last result wins
    }
    if ($null -eq $usage) { return $null }
    $in = Read-UsageInt $usage 'input_tokens'
    $out = Read-UsageInt $usage 'output_tokens'
    $cRead = Read-UsageInt $usage 'cache_read_input_tokens'
    $cCreate = Read-UsageInt $usage 'cache_creation_input_tokens'
    return [pscustomobject]@{
        source                      = 'claude'
        estimated                   = $false
        input_tokens                = $in
        output_tokens               = $out
        cache_read_input_tokens     = $cRead
        cache_creation_input_tokens = $cCreate
        total_tokens                = ($in + $out + $cRead + $cCreate)
    }
}

function Cmd-Observe {
    $resultFile = Require-Opt 'result-file'
    if (-not (Test-Path -LiteralPath $resultFile)) { Fail 2 "--result-file not found: $resultFile" }
    $v = $null
    try { $v = Read-TextOrEmpty $resultFile | ConvertFrom-Json } catch { Fail 2 "--result-file is not valid JSON" }
    $reason = [string](Get-Prop $v 'reason')
    $exit = Get-Prop $v 'exit_code'
    $dur = [int](Get-Prop $v 'duration_ms')
    $attempts = if (Has-Prop $v 'attempts') { [int]$v.attempts } else { 1 }
    $bytes = [int](Get-Prop $v 'output_bytes')
    $rawReason = [string](Get-Prop $v 'outcome_reason')
    $safeReason = (Invoke-Redact $rawReason).Trim()

    $taskId = [string](Opt 'task-id' '')
    $role = [string](Opt 'role' 'coder')
    $mode = [string](Opt 'mode' 'full')
    $source = [string](Opt 'source' 'claude')
    $budgetMs = if (Has-Prop $v 'budget_remaining_ms') { [int]$v.budget_remaining_ms } else { -1 }

    # T-248: best-effort claude usage from the captured stream-json transcript (--stdout-file,
    # optional). Never fatal, never emits raw text - only the non-sensitive integer counts.
    $usage = $null
    $stdoutFile = [string](Opt 'stdout-file' '')
    if ($stdoutFile -and (Test-Path -LiteralPath $stdoutFile)) {
        $usage = Get-StreamJsonUsage (Read-TextOrEmpty $stdoutFile)
    }

    # A one-line, non-sensitive journal/status summary.
    $journal = "supervisor: reason=$reason attempts=$attempts elapsed_ms=$dur output_bytes=$bytes exit=$exit"
    if ($budgetMs -ge 0) { $journal += " budget_remaining_ms=$budgetMs" }
    if ($safeReason) { $journal += " ($safeReason)" }
    if ($null -ne $usage) { $journal += " usage_tokens=$($usage.total_tokens)$(if ($usage.estimated) { '~est' } else { '' })" }

    # codex.attempt event args for tools/outbox.ps1 - scalar allowlist only.
    $eventArgs = @(
        '--type', 'codex.attempt', '--task-id', $taskId, '--role', $role, '--mode', $mode,
        '--attempt-number', "$attempts",
        '--payload', ([pscustomobject]@{
                task_id        = $taskId
                role           = $role
                mode           = $mode
                attempt_number = $attempts
                duration_ms    = $dur
                exit_code      = $exit
                outcome        = $reason
                outcome_reason = $safeReason
            } | ConvertTo-Json -Compress)
    )

    # usage.recorded event args (T-248) - only when usage was actually captured. Scalar
    # allowlist only; the processor supplies the identity coordinates for the dedup key.
    $usageEventArgs = @()
    if ($null -ne $usage) {
        $usagePayload = [ordered]@{
            task_id                     = $taskId
            role                        = $role
            mode                        = $mode
            attempt_number              = $attempts
            source                      = $source
            input_tokens                = $usage.input_tokens
            output_tokens               = $usage.output_tokens
            cache_read_input_tokens     = $usage.cache_read_input_tokens
            cache_creation_input_tokens = $usage.cache_creation_input_tokens
            total_tokens                = $usage.total_tokens
            estimated                   = $usage.estimated
        }
        $usageEventArgs = @(
            '--type', 'usage.recorded', '--task-id', $taskId, '--role', $role, '--mode', $mode,
            '--attempt-number', "$attempts", '--source', $source,
            '--payload', ($usagePayload | ConvertTo-Json -Compress)
        )
    }

    if ([bool](Opt 'json' $false)) {
        $out = [ordered]@{
            reason              = $reason
            attempts            = $attempts
            duration_ms         = $dur
            output_bytes        = $bytes
            exit_code           = $exit
            budget_remaining_ms = $budgetMs
            journal_line        = $journal
            outcome_reason      = $safeReason
            event_args          = $eventArgs
            usage               = $usage
            usage_event_args    = $usageEventArgs
        }
        Write-Output ($out | ConvertTo-Json -Depth 8 -Compress)
    } else {
        Write-Output $journal
    }
}

# ==========================================================================
# budget : initialize / inspect the cohort budget file.
# ==========================================================================
function Cmd-Budget {
    $path = Require-Opt 'budget-file'
    if ([bool](Opt 'reset' $false) -or -not (Test-Path -LiteralPath $path)) {
        $bs = Parse-IntOpt 'budget-sec' 0 0
        [void](Init-Budget $path $bs)
    }
    $b = Read-Budget $path
    if ($null -eq $b) { Fail 3 "budget file unreadable: $path" }
    $remaining = Get-BudgetRemainingMs $b
    $remOut = if ($remaining -eq [int]::MaxValue) { -1 } else { $remaining }   # -1 signals unlimited
    if ([bool](Opt 'json' $false)) {
        $out = [ordered]@{
            budget_sec         = [int](Get-Prop $b 'budget_sec')
            consumed_ms        = [int](Get-Prop $b 'consumed_ms')
            remaining_ms       = $remOut
            exhausted          = ($remaining -le 0)
            started_at         = [string](Get-Prop $b 'started_at')
            batch_id           = [string](Get-Prop $b 'batch_id')
        }
        Write-Output ($out | ConvertTo-Json -Compress)
    } else {
        Write-Output "budget: budget_sec=$([int](Get-Prop $b 'budget_sec')) consumed_ms=$([int](Get-Prop $b 'consumed_ms')) remaining_ms=$remOut exhausted=$($remaining -le 0)"
    }
}

function Emit-Verdict {
    param($Verdict)
    if ([bool](Opt 'json' $false)) { Write-Output ($Verdict | ConvertTo-Json -Depth 8 -Compress) }
    else { Write-Output "reason=$($Verdict.reason) attempts=$($Verdict.attempts) exit_code=$($Verdict.exit_code) duration_ms=$($Verdict.duration_ms) output_bytes=$($Verdict.output_bytes) ($($Verdict.outcome_reason))" }
}

function Cmd-Version { Write-Output 'orchestra-supervisor 1' }

# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------
try {
    switch ($Command) {
        'run'       { Cmd-Run }
        'supervise' { Cmd-Supervise }
        'observe'   { Cmd-Observe }
        'budget'    { Cmd-Budget }
        'version'   { Cmd-Version }
        default {
            Fail 2 "unknown command '$Command'. Valid: run, supervise, observe, budget, version"
        }
    }
} catch {
    exit (Resolve-CatchExit $_ 'SPVERR' 'supervisor' 'SUPERVISOR_DEBUG')
}
