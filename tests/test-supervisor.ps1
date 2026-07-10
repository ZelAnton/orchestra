<#
.SYNOPSIS
    Deterministic, offline tests (T-093) for the execution supervisor tool
    tools/supervisor.ps1.

.DESCRIPTION
    tools/supervisor.ps1 bounds one executor call with a policy-configurable deadline /
    attempt / output-volume / cohort-budget and classifies the stop into one of four
    materially different reasons (ok / timeout / cancelled / crash / error, plus the
    budget stop), each mapped to a distinct exit code the processor routes on. Because it
    IS code, it is unit tested directly: each scenario drives the real tool as a child
    pwsh process against throwaway worker stubs under the temp dir and asserts on the
    JSON verdict / exit code / side-effect files. Nothing here touches this repository's
    own .work/ and nothing reaches the network.

    Covered (per T-093's acceptance criteria):
      * Four-way stop classification with distinct exit codes: ok(0), timeout(3),
        cancelled(4), crash(5) - by crash-exit-code AND by spawn failure - and a
        substantive error(6); the reason drives the exit code.
      * Deadline: a call that overruns is terminated and returns PROMPTLY (bounded by the
        deadline, not the child's own sleep).
      * Cooperative cancellation: a cancel-file mid-run stops the call, saves a
        lease-compatible checkpoint (owner_id + heartbeat + ttl, resumable) and does not
        remove the lease.
      * Whole child process TREE termination: a grandchild spawned by the call is gone
        after a cancel/timeout kill.
      * Output-volume cap: a flooding call is truncated to --output-max-bytes in the
        transient capture while the full byte count is still reported.
      * Privacy: the durable verdict (--result-file) and `observe` outputs carry NO raw
        call output - a secret printed by the call never reaches them; only the transient
        stdout capture holds it.
      * supervise retry loop: transient (timeout/crash) is retried up to --max-attempts;
        a substantive error is NOT retried (quarantine path); a success after retries wins.
      * Cohort budget: a call's deadline is trimmed to the remaining budget, and once the
        budget is exhausted a further supervise call stops with reason=budget without
        running the child.
      * observe: emits a non-sensitive journal line + codex.attempt event args that the
        real tools/outbox.ps1 accepts.

.EXAMPLE
    pwsh -File tests/test-supervisor.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$script:Tool = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\supervisor.ps1')).Path
$script:Outbox = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\outbox.ps1')).Path
$script:PsExe = ([System.Diagnostics.Process]::GetCurrentProcess()).MainModule.FileName
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:TempDirs = [System.Collections.Generic.List[string]]::new()

function New-TempDir {
    $d = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'spv-t-' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($d)
    $script:TempDirs.Add($d)
    return $d
}
function Read-File { param([string]$Path) if (Test-Path -LiteralPath $Path) { return [System.IO.File]::ReadAllText($Path, $script:Utf8) } else { return '' } }
function Write-File { param([string]$Path, [string]$Text) [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8) }
function ArgsJson { param([string[]]$A) return (, $A | ConvertTo-Json -Compress) }

# Runs supervisor.ps1 as a child pwsh process; returns @{ ExitCode; Out; Err }.
function Invoke-Spv {
    param([string[]]$ToolArgs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:PsExe
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8
    $psi.StandardErrorEncoding = $script:Utf8
    foreach ($a in (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:Tool) + $ToolArgs)) { $psi.ArgumentList.Add($a) }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outT = $proc.StandardOutput.ReadToEndAsync()
    $errT = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Out = $outT.Result; Err = $errT.Result }
}
function Invoke-Outbox {
    param([string[]]$ToolArgs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:PsExe
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8
    $psi.StandardErrorEncoding = $script:Utf8
    foreach ($a in (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:Outbox) + $ToolArgs)) { $psi.ArgumentList.Add($a) }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outT = $proc.StandardOutput.ReadToEndAsync()
    $errT = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Out = $outT.Result; Err = $errT.Result }
}

function Assert-True { param([bool]$Cond, [string]$Msg) if (-not $Cond) { $script:Failures.Add("FAIL - $Msg") } }
function Assert-Equal { param($Expected, $Actual, [string]$Msg) if ($Expected -ne $Actual) { $script:Failures.Add("FAIL - ${Msg}: expected [$Expected], got [$Actual]") } }
function Assert-Exit { param($R, [int]$Code, [string]$Msg) if ($R.ExitCode -ne $Code) { $script:Failures.Add("FAIL - ${Msg}: expected exit $Code, got $($R.ExitCode) (err=[$($R.Err.Trim())] out=[$($R.Out.Trim())])") } }
function Assert-Contains { param([string]$Haystack, [string]$Needle, [string]$Msg) if ($Haystack.IndexOf($Needle, [System.StringComparison]::Ordinal) -lt 0) { $script:Failures.Add("FAIL - ${Msg}: [$Needle] not found") } }
function Assert-NotContains { param([string]$Haystack, [string]$Needle, [string]$Msg) if ($Haystack.IndexOf($Needle, [System.StringComparison]::Ordinal) -ge 0) { $script:Failures.Add("FAIL - ${Msg}: [$Needle] must NOT be present but was") } }

# A parametric worker stub every scenario drives. Understands --code/--sleep/--flood/
# --cancel-after(+--touch)/--spawn-marker/--counter(+--fail-until +--fail-code)/--print.
function New-Worker {
    param([string]$Dir)
    $p = Join-Path $Dir 'worker.ps1'
    $body = @'
param()
$code=0;$sleep=0;$flood=0;$cancelAfter=0;$touch='';$spawn='';$counter='';$failUntil=0;$failCode=42;$print=''
for($i=0;$i -lt $args.Count;$i++){switch([string]$args[$i]){
 '--code'{$code=[int]$args[++$i]} '--sleep'{$sleep=[int]$args[++$i]} '--flood'{$flood=[int]$args[++$i]}
 '--cancel-after'{$cancelAfter=[int]$args[++$i]} '--touch'{$touch=[string]$args[++$i]}
 '--spawn-marker'{$spawn=[string]$args[++$i]} '--counter'{$counter=[string]$args[++$i]}
 '--fail-until'{$failUntil=[int]$args[++$i]} '--fail-code'{$failCode=[int]$args[++$i]}
 '--print'{$print=[string]$args[++$i]} }}
if($print){ Write-Output $print }
if($flood -gt 0){ $line=('y'*63); for($j=0;$j -lt $flood;$j++){ Write-Output $line } }
if($spawn){ $exe=(Get-Process -Id $PID).Path; Start-Process -FilePath $exe -ArgumentList @('-NoProfile','-NonInteractive','-Command',"Start-Sleep 4; Set-Content -LiteralPath '$spawn' done") -WindowStyle Hidden | Out-Null }
if($counter){ $n=0; if(Test-Path -LiteralPath $counter){ $n=[int](Get-Content -LiteralPath $counter -Raw) }; $n++; Set-Content -LiteralPath $counter "$n"; if($n -le $failUntil){ exit $failCode } }
if($cancelAfter -gt 0 -and $touch){ Start-Sleep -Seconds $cancelAfter; Set-Content -LiteralPath $touch 'stop' }
if($sleep -gt 0){ Start-Sleep -Seconds $sleep }
exit $code
'@
    Write-File $p $body
    return $p
}

# =============================================================================
# 0. version
# =============================================================================
{
    $r = Invoke-Spv @('version')
    Assert-Exit $r 0 'version rc=0'
    Assert-Contains $r.Out 'orchestra-supervisor' 'version identifies the tool'
}.Invoke()

# =============================================================================
# 1. Four-way stop classification -> distinct exit codes.
# =============================================================================
{
    $d = New-TempDir; $w = New-Worker $d

    $ok = Invoke-Spv @('run', '--file', $w, '--args-json', (ArgsJson @('--code', '0', '--print', 'done')), '--json')
    Assert-Exit $ok 0 'ok -> exit 0'
    $okObj = $ok.Out | ConvertFrom-Json
    Assert-Equal 'ok' $okObj.reason 'ok reason'
    Assert-True ($okObj.output_bytes -gt 0) 'ok captured the output (bytes > 0)'

    $err = Invoke-Spv @('run', '--file', $w, '--args-json', (ArgsJson @('--code', '1')), '--json')
    Assert-Exit $err 6 'substantive error -> exit 6'
    Assert-Equal 'error' (($err.Out | ConvertFrom-Json).reason) 'error reason'

    $crash = Invoke-Spv @('run', '--file', $w, '--args-json', (ArgsJson @('--code', '42')), '--crash-exit-codes', '42', '--json')
    Assert-Exit $crash 5 'crash-exit-code -> exit 5'
    Assert-Equal 'crash' (($crash.Out | ConvertFrom-Json).reason) 'crash reason'

    # spawn failure (nonexistent exe) is a crash, not an error.
    $spawn = Invoke-Spv @('run', '--exe', (Join-Path $d 'no-such-binary-xyz.exe'), '--json')
    Assert-Exit $spawn 5 'spawn failure -> crash exit 5'
    Assert-Equal 'crash' (($spawn.Out | ConvertFrom-Json).reason) 'spawn-failure reason is crash'
}.Invoke()

# =============================================================================
# 2. Deadline: overrun is terminated and returns promptly (bounded, not the child sleep).
# =============================================================================
{
    $d = New-TempDir; $w = New-Worker $d
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Spv @('run', '--file', $w, '--args-json', (ArgsJson @('--sleep', '30')), '--deadline-sec', '1', '--json')
    $sw.Stop()
    Assert-Exit $r 3 'timeout -> exit 3'
    $o = $r.Out | ConvertFrom-Json
    Assert-Equal 'timeout' $o.reason 'timeout reason'
    Assert-True ([bool]$o.timed_out) 'timed_out flag set'
    Assert-True ($sw.Elapsed.TotalSeconds -lt 15) "returns promptly on deadline (was $([int]$sw.Elapsed.TotalSeconds)s, child sleep was 30s)"
}.Invoke()

# =============================================================================
# 3. Cooperative cancellation -> lease-compatible checkpoint; lease untouched.
# =============================================================================
{
    $d = New-TempDir; $w = New-Worker $d
    $work = New-TempDir
    [void][System.IO.Directory]::CreateDirectory((Join-Path $work 'orchestrator.lock'))
    $leasePath = Join-Path $work 'orchestrator.lock/lease.json'
    Write-File $leasePath '{"schema":"orchestra/lease@1","owner_id":"OWNER-Z","role":"processor","root":"/x","host":"h","heartbeat":"2026-07-10T11:00:00Z","ttl_seconds":900,"generation":1}'
    $leaseBefore = Read-File $leasePath
    $cancel = Join-Path $d 'cancel.flag'
    $cp = Join-Path $d 'cp.json'
    $r = Invoke-Spv @('run', '--file', $w,
        '--args-json', (ArgsJson @('--sleep', '30', '--cancel-after', '1', '--touch', $cancel)),
        '--cancel-file', $cancel, '--deadline-sec', '20',
        '--checkpoint-file', $cp, '--work', $work, '--owner', 'OWNER-Z', '--task-id', 'T-7', '--batch-id', 'B-20260101T000000Z', '--json')
    Assert-Exit $r 4 'cancelled -> exit 4'
    Assert-Equal 'cancelled' (($r.Out | ConvertFrom-Json).reason) 'cancelled reason'
    Assert-True (Test-Path -LiteralPath $cp) 'checkpoint file written on cancel'
    $cpObj = Read-File $cp | ConvertFrom-Json
    Assert-Equal 'OWNER-Z' $cpObj.owner_id 'checkpoint carries the lease owner_id'
    Assert-Equal 'T-7' $cpObj.task_id 'checkpoint carries the task id'
    Assert-Equal 'cancelled' $cpObj.reason 'checkpoint records the reason'
    Assert-True ([bool]$cpObj.resumable) 'checkpoint marks a cancelled call resumable'
    Assert-True (($cpObj.PSObject.Properties.Name -contains 'heartbeat') -and ($cpObj.PSObject.Properties.Name -contains 'ttl_seconds')) 'checkpoint carries heartbeat + ttl (lease-compatible)'
    Assert-Equal $leaseBefore (Read-File $leasePath) 'the lease itself is NOT modified/removed by the checkpoint'
}.Invoke()

# =============================================================================
# 4. Whole child process TREE termination: a grandchild is gone after the kill.
# =============================================================================
{
    $d = New-TempDir; $w = New-Worker $d
    $marker = Join-Path $d 'grandchild-marker.txt'
    $r = Invoke-Spv @('run', '--file', $w, '--args-json', (ArgsJson @('--sleep', '30', '--spawn-marker', $marker)), '--deadline-sec', '1', '--json')
    Assert-Exit $r 3 'tree-kill scenario times out'
    # the grandchild would write the marker at +4s; the tree was killed at ~1s. Wait past +4s.
    Start-Sleep -Seconds 6
    Assert-True (-not (Test-Path -LiteralPath $marker)) 'grandchild was terminated with the tree (no marker written)'
}.Invoke()

# =============================================================================
# 5. Output-volume cap: transient capture truncated; full byte count still reported.
# =============================================================================
{
    $d = New-TempDir; $w = New-Worker $d
    $capFile = Join-Path $d 'cap.txt'
    $r = Invoke-Spv @('run', '--file', $w, '--args-json', (ArgsJson @('--flood', '1000')), '--output-max-bytes', '256', '--stdout-file', $capFile, '--json')
    Assert-Exit $r 0 'capped run still succeeds'
    $o = $r.Out | ConvertFrom-Json
    Assert-True ([bool]$o.output_truncated) 'output_truncated flag set when flooded'
    Assert-True ($o.output_bytes -gt 256) 'full byte count reported (larger than the cap)'
    $capBytes = [System.Text.Encoding]::UTF8.GetByteCount((Read-File $capFile))
    Assert-True ($capBytes -le 256) "transient capture is capped to the limit (was $capBytes bytes)"
}.Invoke()

# =============================================================================
# 6. Privacy: a secret printed by the call never reaches the durable verdict / observe.
# =============================================================================
{
    $d = New-TempDir; $w = New-Worker $d
    $secret = 'AKIAIOSFODNN7EXAMPLE'
    $resFile = Join-Path $d 'result.json'
    $stdoutFile = Join-Path $d 'out.txt'
    $r = Invoke-Spv @('run', '--file', $w, '--args-json', (ArgsJson @('--print', $secret, '--code', '0')), '--result-file', $resFile, '--stdout-file', $stdoutFile, '--json')
    Assert-Exit $r 0 'privacy run succeeds'
    Assert-Contains (Read-File $stdoutFile) $secret 'the transient stdout capture DOES hold the raw output'
    Assert-NotContains (Read-File $resFile) $secret 'the durable verdict does NOT contain the raw output (privacy)'
    Assert-NotContains $r.Out $secret 'the stdout verdict does NOT contain the raw output'

    $obs = Invoke-Spv @('observe', '--result-file', $resFile, '--task-id', 'T-9', '--role', 'coder', '--mode', 'full', '--json')
    Assert-Exit $obs 0 'observe rc=0'
    Assert-NotContains $obs.Out $secret 'observe output carries no raw call output'
    $obsObj = $obs.Out | ConvertFrom-Json
    Assert-Equal 'ok' $obsObj.reason 'observe reports the reason'
    # the event args observe emits must be accepted by the REAL outbox tool.
    $ev = Join-Path $d 'events.jsonl'
    $eventArgs = @('append', '--events', $ev) + @($obsObj.event_args | ForEach-Object { [string]$_ })
    $ap = Invoke-Outbox $eventArgs
    Assert-Exit $ap 0 'outbox accepts the codex.attempt event args observe emits'
}.Invoke()

# =============================================================================
# 7. supervise retry: transient retried up to max-attempts; substantive error NOT retried.
# =============================================================================
{
    $d = New-TempDir; $w = New-Worker $d
    $counter = Join-Path $d 'attempts.txt'
    # crash (exit 42) on attempts 1..2, succeed on attempt 3.
    $r = Invoke-Spv @('supervise', '--file', $w,
        '--args-json', (ArgsJson @('--counter', $counter, '--fail-until', '2', '--fail-code', '42')),
        '--crash-exit-codes', '42', '--max-attempts', '3', '--json')
    Assert-Exit $r 0 'supervise recovers a transient crash within max-attempts -> exit 0'
    $o = $r.Out | ConvertFrom-Json
    Assert-Equal 'ok' $o.reason 'final reason ok after retries'
    Assert-Equal 3 $o.attempts 'used exactly 3 attempts (2 crashes + 1 success)'

    # a substantive error (exit 1) is NOT retried: attempts stays 1.
    $d2 = New-TempDir; $w2 = New-Worker $d2
    $r2 = Invoke-Spv @('supervise', '--file', $w2, '--args-json', (ArgsJson @('--code', '1')), '--max-attempts', '5', '--json')
    Assert-Exit $r2 6 'substantive error -> exit 6 (quarantine path)'
    Assert-Equal 1 (($r2.Out | ConvertFrom-Json).attempts) 'a substantive error is not retried (attempts=1)'

    # transient exhausts attempts -> escalate as timeout/crash (not silently ok).
    $d3 = New-TempDir; $w3 = New-Worker $d3
    $r3 = Invoke-Spv @('supervise', '--file', $w3, '--args-json', (ArgsJson @('--code', '42')), '--crash-exit-codes', '42', '--max-attempts', '2', '--json')
    Assert-Exit $r3 5 'a persistent crash exhausts attempts and stays crash (exit 5)'
    Assert-Equal 2 (($r3.Out | ConvertFrom-Json).attempts) 'crash retried up to max-attempts (2)'
}.Invoke()

# =============================================================================
# 8. Cohort budget: deadline trimmed to remaining budget; exhausted -> reason=budget.
# =============================================================================
{
    $d = New-TempDir; $w = New-Worker $d
    $budget = Join-Path $d 'budget.json'
    # init a 2-second cohort budget.
    $bi = Invoke-Spv @('budget', '--budget-file', $budget, '--budget-sec', '2', '--json')
    Assert-Exit $bi 0 'budget init rc=0'
    Assert-Equal $false ([bool](($bi.Out | ConvertFrom-Json).exhausted)) 'fresh budget is not exhausted'

    # a call that would sleep 30s with a 20s deadline gets its deadline TRIMMED to the ~2s
    # budget remaining, so it times out at the budget edge and consumes the budget.
    $r = Invoke-Spv @('supervise', '--file', $w, '--args-json', (ArgsJson @('--sleep', '30')),
        '--deadline-sec', '20', '--max-attempts', '1', '--budget-file', $budget, '--json')
    Assert-Exit $r 3 'budget-trimmed call times out at the budget edge (exit 3)'

    # the budget is now exhausted; a further supervise call refuses to run the child.
    $r2 = Invoke-Spv @('supervise', '--file', $w, '--args-json', (ArgsJson @('--code', '0')),
        '--max-attempts', '1', '--budget-file', $budget, '--json')
    Assert-Exit $r2 7 'an exhausted cohort budget -> reason=budget (exit 7), child not run'
    Assert-Equal 'budget' (($r2.Out | ConvertFrom-Json).reason) 'budget reason'
    $bs = Invoke-Spv @('budget', '--budget-file', $budget, '--json')
    Assert-True ([bool](($bs.Out | ConvertFrom-Json).exhausted)) 'budget reports exhausted'
}.Invoke()

# =============================================================================
# 9. Usage errors are rc=2.
# =============================================================================
{
    $bad = Invoke-Spv @('run', '--file', 'x.ps1', '--exe', 'y')
    Assert-Exit $bad 2 'both --file and --exe is a usage error'
    $none = Invoke-Spv @('run', '--json')
    Assert-Exit $none 2 'neither --file nor --exe is a usage error'
    $badcmd = Invoke-Spv @('frobnicate')
    Assert-Exit $badcmd 2 'unknown command is a usage error'
}.Invoke()

# =============================================================================
# Report + cleanup
# =============================================================================
foreach ($d in $script:TempDirs) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }

if ($script:Failures.Count -eq 0) {
    Write-Host "OK - all supervisor tests passed."
    exit 0
}
Write-Host "FAILED - $($script:Failures.Count) assertion(s):"
foreach ($f in $script:Failures) { Write-Host "  $f" }
exit 1
