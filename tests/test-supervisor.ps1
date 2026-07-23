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
    param(
        [string[]]$ToolArgs,
        [hashtable]$EnvironmentOverrides = @{}
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:PsExe
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8
    $psi.StandardErrorEncoding = $script:Utf8
    # Keep host-installed ProcessKit binaries from changing baseline scenarios. Tests
    # opt into a CLI explicitly when they exercise the standalone backend.
    $psi.Environment['CC_PROCESSKIT_CLI'] = 'off'
    $psi.Environment['CC_PROCESSKIT_PYTHON'] = ''
    foreach ($name in $EnvironmentOverrides.Keys) {
        $psi.Environment[[string]$name] = [string]$EnvironmentOverrides[$name]
    }
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
# --cancel-after(+--touch)/--spawn-marker(+--spawn-ready)/
# --counter(+--fail-until +--fail-code)/--print.
function New-Worker {
    param([string]$Dir)
    $p = Join-Path $Dir 'worker.ps1'
    $body = @'
param()
$code=0;$sleep=0;$flood=0;$cancelAfter=0;$touch='';$spawn='';$spawnReady='';$counter='';$failUntil=0;$failCode=42;$print=''
for($i=0;$i -lt $args.Count;$i++){switch([string]$args[$i]){
 '--code'{$code=[int]$args[++$i]} '--sleep'{$sleep=[int]$args[++$i]} '--flood'{$flood=[int]$args[++$i]}
 '--cancel-after'{$cancelAfter=[int]$args[++$i]} '--touch'{$touch=[string]$args[++$i]}
 '--spawn-marker'{$spawn=[string]$args[++$i]} '--counter'{$counter=[string]$args[++$i]}
 '--spawn-ready'{$spawnReady=[string]$args[++$i]}
 '--fail-until'{$failUntil=[int]$args[++$i]} '--fail-code'{$failCode=[int]$args[++$i]}
 '--print'{$print=[string]$args[++$i]} }}
if($print){ Write-Output $print }
if($flood -gt 0){ $line=('y'*63); for($j=0;$j -lt $flood;$j++){ Write-Output $line } }
if($spawn){
 $exe=(Get-Process -Id $PID).Path
 # Do not let the grandchild inherit the supervisor's redirected pipes: a broken
 # tree kill must return promptly enough for the test to observe and clean the orphan.
 $child=Start-Process -FilePath $exe -ArgumentList @('-NoProfile','-NonInteractive','-Command',"Start-Sleep 120; Set-Content -LiteralPath '$spawn' done") -RedirectStandardOutput ($spawn + '.stdout') -RedirectStandardError ($spawn + '.stderr') -PassThru
 if($spawnReady){
  $parentStartTime=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
  $childStartTime=$child.StartTime.ToUniversalTime().Ticks
  Set-Content -LiteralPath $spawnReady "$PID|$parentStartTime,$($child.Id)|$childStartTime"
 }
}
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
# 0b. Trusted shell-command uses the native Bash environment and inherits the
#     short-lived .NET worker policy injected by the supervisor.
# =============================================================================
{
    $d = New-TempDir
    $out = Join-Path $d 'shell.out'
    $r = Invoke-Spv @(
        'run', '--shell-command', 'printf "%s|%s" "$MSBUILDDISABLENODEREUSE" "$DOTNET_CLI_USE_MSBUILD_SERVER"',
        '--working-directory', $d, '--stdout-file', $out, '--json'
    )
    Assert-Exit $r 0 'shell-command succeeds'
    Assert-Equal '1|0' (Read-File $out) 'shell-command inherits disabled MSBuild reuse/server policy'
}.Invoke()

# =============================================================================
# 0c. An explicitly configured kernel-containment backend is fail-closed.
# =============================================================================
{
    $d = New-TempDir; $w = New-Worker $d
    $marker = Join-Path $d 'must-not-run.txt'
    $r = Invoke-Spv -ToolArgs @(
        'run', '--file', $w, '--args-json', (ArgsJson @('--print', 'unexpected')),
        '--stdout-file', $marker, '--json'
    ) -EnvironmentOverrides @{ CC_PROCESSKIT_PYTHON = (Join-Path $d 'missing-python.exe') }
    Assert-Exit $r 2 'missing ProcessKit backend -> fail-closed usage/config error'
    Assert-True (-not (Test-Path -LiteralPath $marker)) 'missing ProcessKit backend must not start the target command'
}.Invoke()

# =============================================================================
# 0d. The standalone CLI contract is also fail-closed and takes precedence over the
#     legacy Python fallback. A missing explicit binary must never start the target.
# =============================================================================
{
    $d = New-TempDir
    $marker = Join-Path $d 'must-not-run-cli.txt'
    $worker = New-Worker $d
    $r = Invoke-Spv @(
        'run', '--file', $worker, '--args-json', (ArgsJson @('--touch', $marker)),
        '--result-file', (Join-Path $d 'result.json')
    ) -EnvironmentOverrides @{
        CC_PROCESSKIT_CLI = (Join-Path $d 'missing-processkit-cli.exe')
        CC_PROCESSKIT_PYTHON = (Join-Path $d 'also-missing-python.exe')
    }
    Assert-Exit $r 2 'missing standalone ProcessKit backend -> fail-closed usage/config error'
    Assert-True (-not (Test-Path -LiteralPath $marker)) 'missing standalone ProcessKit backend must not start the target command'
}.Invoke()

# =============================================================================
# 0e. Process snapshot diffs stay typed and consistent under StrictMode.
#     A real global snapshot cannot deterministically require zero candidates: another
#     process on a shared CI/desktop host may start during this call.
# =============================================================================
{
    $d = New-TempDir
    $diag = Join-Path $d 'empty-process-diagnostics.json'
    $r = Invoke-Spv @(
        'run', '--exe', $script:PsExe,
        '--args-json', (ArgsJson @('-NoProfile', '-NonInteractive', '-Command', 'exit 0')),
        '--process-diagnostics', '--process-log-file', $diag, '--json'
    )
    Assert-Exit $r 0 'process-diff diagnostics do not throw under StrictMode'
    $o = $r.Out | ConvertFrom-Json
    Assert-True ([int]$o.temporal_candidate_count -ge 0) 'process-diff verdict reports a non-negative temporal candidate count'
    Assert-True (Test-Path -LiteralPath $diag) 'process-diff writes diagnostics artifact'
    $diagObj = Read-File $diag | ConvertFrom-Json
    Assert-True ($null -ne $diagObj.PSObject.Properties['temporal_candidates']) 'process-diff artifact keeps temporal_candidates field'
    Assert-Equal ([int]$o.temporal_candidate_count) (@($diagObj.temporal_candidates).Count) 'verdict and process-diff artifact serialize the same candidate count'
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
    Assert-True ($sw.Elapsed.TotalSeconds -lt 25) "returns promptly on deadline (was $([int]$sw.Elapsed.TotalSeconds)s, child sleep was 30s)"
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
    $ready = Join-Path $d 'spawned-processes.txt'
    $spawnedProcesses = @()
    $treeKill = [System.Diagnostics.Process].GetMethod('Kill', [type[]]@([bool]))
    Assert-True ($null -ne $treeKill) 'pwsh 7 exposes Process.Kill(bool) for atomic tree termination'
    # An empty PATH makes taskkill unavailable on Windows. The scenario can therefore
    # pass only through Kill(true), not through the platform fallback.
    try {
        $r = Invoke-Spv -ToolArgs @(
            'run', '--file', $w,
            '--args-json', (ArgsJson @('--sleep', '120', '--spawn-marker', $marker, '--spawn-ready', $ready)),
            '--deadline-sec', '30', '--json'
        ) -EnvironmentOverrides @{ PATH = '' }
        Assert-Exit $r 3 'tree-kill scenario times out'
        $readyExists = Test-Path -LiteralPath $ready
        Assert-True $readyExists 'worker recorded parent + grandchild PIDs before the deadline'
        $spawnedProcesses = if ($readyExists) {
            @((Read-File $ready).Trim() -split ',' | ForEach-Object {
                $identity = $_ -split '\|', 2
                [pscustomobject]@{
                    Id = [int]$identity[0]
                    StartTime = [DateTime]::new([long]$identity[1], [DateTimeKind]::Utc)
                }
            })
        } else { @() }
        Assert-Equal 2 (@($spawnedProcesses).Count) 'tree-kill scenario recorded exactly two process identities'
        if (@($spawnedProcesses).Count -eq 2) {
            $exitWait = [System.Diagnostics.Stopwatch]::StartNew()
            do {
                $aliveIds = @($spawnedProcesses | ForEach-Object {
                    try {
                        $process = Get-Process -Id $_.Id -ErrorAction Stop
                        if ((-not $process.HasExited) -and ($process.StartTime.ToUniversalTime() -eq $_.StartTime)) {
                            $_.Id
                        }
                    } catch { }
                })
                if (@($aliveIds).Count -eq 0) { break }
                Start-Sleep -Milliseconds 100
            } while ($exitWait.Elapsed.TotalSeconds -lt 5)
            foreach ($spawnedProcess in $spawnedProcesses) {
                Assert-True ($aliveIds -notcontains $spawnedProcess.Id) "process $($spawnedProcess.Id) from the spawned tree was terminated"
            }
        }
        Assert-True (-not (Test-Path -LiteralPath $marker)) 'grandchild was terminated with the tree (no marker written)'
    } finally {
        # If the assertion is exercising a regression, do not leave its observed orphan alive.
        foreach ($spawnedProcess in $spawnedProcesses) {
            try {
                $process = Get-Process -Id $spawnedProcess.Id -ErrorAction Stop
                if ($process.StartTime.ToUniversalTime() -eq $spawnedProcess.StartTime) {
                    $process | Stop-Process -Force -ErrorAction SilentlyContinue
                }
            } catch { }
        }
    }
}.Invoke()

# =============================================================================
# 4b. Normal success also reaps reusable/background descendants and records lineage.
# =============================================================================
{
    $d = New-TempDir; $w = New-Worker $d
    $marker = Join-Path $d 'success-grandchild-marker.txt'
    $ready = Join-Path $d 'success-spawned-processes.txt'
    $diag = Join-Path $d 'process-diagnostics.json'
    $spawnedProcesses = @()
    try {
        $r = Invoke-Spv @(
            'run', '--file', $w,
            '--args-json', (ArgsJson @('--spawn-marker', $marker, '--spawn-ready', $ready)),
            '--process-diagnostics', '--process-log-file', $diag, '--task-id', 'T-44',
            '--role', 'coder', '--label', 'smoke', '--json'
        )
        Assert-Exit $r 0 'normal-success cleanup scenario succeeds'
        $o = $r.Out | ConvertFrom-Json
        Assert-True ([bool]$o.cleanup_attempted) 'normal success attempts tree cleanup'
        Assert-Equal 0 $o.survivor_count_after_cleanup 'normal success leaves no descendants'
        Assert-True (Test-Path -LiteralPath $diag) 'normal success writes process diagnostics'
        $diagObj = Read-File $diag | ConvertFrom-Json
        Assert-Equal 'orchestra/process-diagnostics@1' $diagObj.schema 'diagnostics schema'
        Assert-Equal 'T-44' $diagObj.task_id 'diagnostics carries task id'
        Assert-Equal 'smoke' $diagObj.label 'diagnostics carries launch label'
        if (Test-Path -LiteralPath $ready) {
            $spawnedProcesses = @((Read-File $ready).Trim() -split ',' | ForEach-Object {
                $identity = $_ -split '\|', 2
                [pscustomobject]@{ Id = [int]$identity[0]; StartTime = [DateTime]::new([long]$identity[1], [DateTimeKind]::Utc) }
            })
        }
        # Windows retains the exited parent's PPID and reports the helper through lineage.
        # POSIX reparents it before this snapshot, so the global before/after diff reports it
        # as a temporal candidate instead. Require the fixture child PID, not an unrelated
        # process that happened to start during the same global snapshot window.
        Assert-Equal 2 (@($spawnedProcesses).Count) 'normal-success fixture records parent + background child identities'
        $fixtureChildId = if (@($spawnedProcesses).Count -eq 2) { $spawnedProcesses[1].Id } else { -1 }
        $observedBeforeCleanupIds = @((@($diagObj.descendants_before_cleanup) + @($diagObj.temporal_candidates)) | ForEach-Object { [int]$_.pid })
        Assert-True ($observedBeforeCleanupIds -contains $fixtureChildId) 'diagnostics records the fixture background descendant as lineage or temporal evidence before cleanup'
        Assert-Equal 0 (@($diagObj.survivors_after_cleanup).Count) 'diagnostics records no survivor after cleanup'
        Assert-True (-not (Test-Path -LiteralPath $marker)) 'normal-success grandchild was reaped before writing its marker'
    } finally {
        foreach ($spawnedProcess in $spawnedProcesses) {
            try {
                $process = Get-Process -Id $spawnedProcess.Id -ErrorAction Stop
                if ($process.StartTime.ToUniversalTime() -eq $spawnedProcess.StartTime) {
                    $process | Stop-Process -Force -ErrorAction SilentlyContinue
                }
            } catch { }
        }
    }
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
# 6b. T-248: observe parses per-call token usage from a headless `claude -p
#     --output-format stream-json` transcript (--stdout-file) into usage.recorded
#     event args, carrying only the non-sensitive integer counts (never raw text).
# =============================================================================
{
    $d = New-TempDir
    $resFile = Join-Path $d 'result.json'
    # A minimal, valid verdict (the shape supervisor writes).
    Write-File $resFile '{"reason":"ok","exit_code":0,"timed_out":false,"cancelled":false,"duration_ms":1234,"attempts":1,"output_bytes":42,"output_truncated":false,"output_sha256":"ab","outcome_reason":"exit code 0","occurred_at":"2026-07-17T10:00:00Z"}'
    # A stream-json transcript whose FINAL result event carries usage AND a secret in its text.
    $secret = 'AKIAIOSFODNN7EXAMPLE'
    $stdoutFile = Join-Path $d 'out.txt'
    Write-File $stdoutFile (
        '{"type":"system","subtype":"init","model":"sonnet"}' + "`n" +
        '{"type":"assistant","message":{"role":"assistant"}}' + "`n" +
        ('{"type":"result","subtype":"success","is_error":false,"result":"done ' + $secret + '","usage":{"input_tokens":3000,"output_tokens":800,"cache_read_input_tokens":1500,"cache_creation_input_tokens":200}}')
    )
    $obs = Invoke-Spv @('observe', '--result-file', $resFile, '--stdout-file', $stdoutFile, '--task-id', 'T-9', '--role', 'coder', '--mode', 'full', '--source', 'claude', '--json')
    Assert-Exit $obs 0 'observe(usage) rc=0'
    Assert-NotContains $obs.Out $secret 'observe(usage) never emits the raw transcript text'
    $obsObj = $obs.Out | ConvertFrom-Json
    Assert-True ($null -ne $obsObj.usage) 'observe(usage) surfaces a usage block'
    if ($null -ne $obsObj.usage) {
        Assert-Equal $false $obsObj.usage.estimated 'observe(usage): claude result usage is ACTUAL, not estimated'
        Assert-Equal 3000 $obsObj.usage.input_tokens 'observe(usage): input_tokens from the result event'
        Assert-Equal 5500 $obsObj.usage.total_tokens 'observe(usage): total sums input+output+cache'
    }
    Assert-True ($obsObj.usage_event_args.Count -gt 0) 'observe(usage) emits usage.recorded event args'
    # the usage.recorded args observe emits must be accepted by the REAL outbox tool.
    $ev = Join-Path $d 'events.jsonl'
    $usageArgs = @('append', '--events', $ev, '--batch-id', 'B-1') + @($obsObj.usage_event_args | ForEach-Object { [string]$_ })
    $ap = Invoke-Outbox $usageArgs
    Assert-Exit $ap 0 'outbox accepts the usage.recorded event args observe emits'
    Assert-NotContains (Read-File $ev) $secret 'the appended usage.recorded line holds no raw transcript text'

    # No --stdout-file -> no usage surfaced (best-effort, absent input is a clean no-op).
    $obs2 = Invoke-Spv @('observe', '--result-file', $resFile, '--task-id', 'T-9', '--role', 'coder', '--json')
    Assert-Exit $obs2 0 'observe(no usage) rc=0'
    $obs2Obj = $obs2.Out | ConvertFrom-Json
    Assert-True ($null -eq $obs2Obj.usage) 'observe(no usage): usage is null without a transcript'
    Assert-Equal 0 $obs2Obj.usage_event_args.Count 'observe(no usage): no usage.recorded args without a transcript'
}.Invoke()

# =============================================================================
# 7. supervise retry: transient retried up to max-attempts; substantive error NOT retried.
# =============================================================================
{
    $d = New-TempDir; $w = New-Worker $d
    $counter = Join-Path $d 'attempts.txt'
    $resultFile = Join-Path $d 'result.json'
    $budgetFile = Join-Path $d 'budget.json'
    $bi = Invoke-Spv @('budget', '--budget-file', $budgetFile, '--budget-sec', '60', '--json')
    Assert-Exit $bi 0 'retry scenario budget init rc=0'
    # crash (exit 42) on attempts 1..2, succeed on attempt 3.
    $r = Invoke-Spv @('supervise', '--file', $w,
        '--args-json', (ArgsJson @('--counter', $counter, '--fail-until', '2', '--fail-code', '42')),
        '--crash-exit-codes', '42', '--max-attempts', '3', '--budget-file', $budgetFile,
        '--result-file', $resultFile, '--json')
    Assert-Exit $r 0 'supervise recovers a transient crash within max-attempts -> exit 0'
    $o = $r.Out | ConvertFrom-Json
    Assert-Equal 'ok' $o.reason 'final reason ok after retries'
    Assert-Equal 3 $o.attempts 'used exactly 3 attempts (2 crashes + 1 success)'

    # The durable verdict must be the same final verdict as stdout, not the old
    # Save-CallArtifacts defaults (attempts=1 and no budget/total duration).
    $durable = Read-File $resultFile | ConvertFrom-Json
    Assert-Equal 3 $durable.attempts 'retry result-file persists all 3 attempts'
    Assert-Equal $o.budget_remaining_ms $durable.budget_remaining_ms 'retry result-file persists the stdout budget remaining'
    Assert-Equal $o.total_duration_ms $durable.total_duration_ms 'retry result-file persists the stdout total duration'

    $obs = Invoke-Spv @('observe', '--result-file', $resultFile, '--task-id', 'T-230', '--role', 'coder', '--mode', 'full', '--json')
    Assert-Exit $obs 0 'observe accepts the retry result-file'
    $obsObj = $obs.Out | ConvertFrom-Json
    Assert-Equal 3 $obsObj.attempts 'observe reports the durable retry attempt count'
    Assert-Equal $durable.budget_remaining_ms $obsObj.budget_remaining_ms 'observe reports the durable remaining budget'
    $eventArgs = @($obsObj.event_args | ForEach-Object { [string]$_ })
    $attemptArg = [Array]::IndexOf($eventArgs, '--attempt-number')
    Assert-True ($attemptArg -ge 0) 'observe event args contain --attempt-number'
    if ($attemptArg -ge 0) { Assert-Equal '3' $eventArgs[$attemptArg + 1] 'observe event args use the real retry attempt number' }

    $id3 = Invoke-Outbox (@('event-id') + $eventArgs)
    Assert-Exit $id3 0 'outbox computes the retry attempt event id'
    $id1 = Invoke-Outbox @('event-id', '--type', 'codex.attempt', '--task-id', 'T-230', '--role', 'coder', '--mode', 'full', '--attempt-number', '1')
    Assert-Exit $id1 0 'outbox computes the first attempt event id'
    Assert-True ($id3.Out.Trim() -ne $id1.Out.Trim()) 'retry attempt event id differs from the first attempt event id'

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
