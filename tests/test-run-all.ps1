<# Hermetic scheduler/benchmark regressions for tests/launchers/run-all.ps1. #>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$Runner = Join-Path $PSScriptRoot 'launchers\run-all.ps1'
$PsExe = ([System.Diagnostics.Process]::GetCurrentProcess()).MainModule.FileName
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Failures = [System.Collections.Generic.List[string]]::new()
$Roots = [System.Collections.Generic.List[string]]::new()
. (Join-Path $PSScriptRoot '..\tools\proc-tree.ps1')

function Write-Utf8 {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        [void][System.IO.Directory]::CreateDirectory($dir)
    }
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8)
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { $Failures.Add("FAIL - $Message") }
}
function Assert-Eq {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        $Failures.Add("FAIL - ${Message}: expected [$Expected], got [$Actual]")
    }
}
function New-Root {
    $root = Join-Path ([IO.Path]::GetTempPath()) (
        'orchestra-run-all-test-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    $Roots.Add($root)
    return $root
}
function Get-RunnerCompletionPlan {
    param(
        [string]$Directory,
        [string]$Mode,
        [int]$MaxParallel,
        [bool]$FixtureMarkers,
        [int]$TimeoutSec,
        [int]$GraceSec
    )
    $files = @(Get-ChildItem -LiteralPath $Directory -Filter 'test-*.ps1' -File)
    $parallelCount = 0
    if ($Mode -eq 'Optimized' -and $FixtureMarkers) {
        foreach ($file in $files) {
            $head = Get-Content -LiteralPath $file.FullName -TotalCount 20 -ErrorAction SilentlyContinue
            if (($head -join "`n") -match '(?m)^#\s*ci:parallel-safe-fixture\b') {
                $parallelCount++
            }
        }
    }
    $serialCount = $files.Count - $parallelCount
    $parallelWaves = if ($parallelCount -gt 0) {
        [int][Math]::Ceiling($parallelCount / [double]$MaxParallel)
    } else { 0 }
    $waves = if ($Mode -eq 'Serial') { $files.Count } else { $serialCount + $parallelWaves }
    if ($waves -lt 1) { $waves = 1 }

    # run-all gives each supervisor Timeout+Grace before its parent deadline, then
    # Stop-ProcessTree has a bounded five-second reap and one final Grace wait.
    # Add finite process-start/summary overhead per discovered suite. The wrapper
    # deadline therefore scales with the actual serial/parallel wave count instead
    # of imposing an unrelated fixed minute on every fixture.
    $perWaveBoundSec = [int64]$TimeoutSec + (2L * $GraceSec) + 5L
    $startupAllowanceSec = 15L + (5L * $files.Count)
    $completionBoundSec = $startupAllowanceSec + ([int64]$waves * $perWaveBoundSec)
    $completionBoundMs = [Math]::Min([int64][int]::MaxValue, $completionBoundSec * 1000L)
    return [pscustomobject]@{
        SuiteCount = $files.Count
        ParallelCount = $parallelCount
        SerialCount = $serialCount
        Waves = $waves
        PerWaveBoundSec = $perWaveBoundSec
        StartupAllowanceSec = $startupAllowanceSec
        CompletionBoundMs = $completionBoundMs
    }
}
function Invoke-Runner {
    param(
        [string]$Directory,
        [string]$Mode,
        [int]$MaxParallel,
        [bool]$FixtureMarkers,
        [string]$Supervisor = '',
        [bool]$RequireGate = $false,
        [int]$TimeoutSec = 30,
        [int]$GraceSec = 2,
        [string]$RunnerPath = $Runner
    )
    $plan = Get-RunnerCompletionPlan $Directory $Mode $MaxParallel $FixtureMarkers $TimeoutSec $GraceSec
    $summary = Join-Path $Directory "$($Mode.ToLowerInvariant()).summary.json"
    $out = Join-Path $Directory "$($Mode.ToLowerInvariant()).runner.out.txt"
    $err = Join-Path $Directory "$($Mode.ToLowerInvariant()).runner.err.txt"
    $gate = Join-Path $Directory 'release.gate'
    $env:ORCHESTRA_RUN_ALL_BENCH_STATE = Join-Path $Directory 'state.json'
    $env:ORCHESTRA_RUN_ALL_BENCH_GATE = $gate
    $env:ORCHESTRA_RUN_ALL_BENCH_REQUIRE_GATE = if ($RequireGate) { '1' } else { '0' }
    $runnerArgs = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $RunnerPath,
        '-Mode', $Mode,
        '-MaxParallel', [string]$MaxParallel,
        '-TestTimeoutSec', [string]$TimeoutSec,
        '-SupervisorGraceSec', [string]$GraceSec,
        '-TestDirectory', $Directory,
        '-SummaryPath', $summary
    )
    if ($FixtureMarkers) { $runnerArgs += '-AllowFixtureParallelMarkers' }
    if ($Supervisor) { $runnerArgs += @('-SupervisorPath', $Supervisor) }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process -FilePath $PsExe -ArgumentList $runnerArgs -NoNewWindow -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError $err
    try {
        if ($RequireGate) {
            $producerDeadline = [Diagnostics.Stopwatch]::StartNew()
            $producerBoundMs = [Math]::Min(
                $plan.CompletionBoundMs,
                ([int64]$plan.PerWaveBoundSec + $plan.StartupAllowanceSec) * 1000L)
            while (@(Get-ChildItem -LiteralPath $Directory -Filter '*.started' -ErrorAction SilentlyContinue).Count -lt 2) {
                if ($proc.HasExited -or $producerDeadline.ElapsedMilliseconds -ge $producerBoundMs) { break }
                Start-Sleep -Milliseconds 50
            }
            $started = @(Get-ChildItem -LiteralPath $Directory -Filter '*.started' -ErrorAction SilentlyContinue).Count
            Assert-True ($started -ge 2) 'optimized fixture proves overlap before producer release'
            Write-Utf8 $gate 'release'
        }
        $timedOut = -not $proc.WaitForExit([int]$plan.CompletionBoundMs)
        $cleanupSucceeded = $true
        $diagnostic = ''
        if ($timedOut) {
            $cleanupSucceeded = $false
            try {
                Stop-ProcessTree $proc
                $cleanupSucceeded = $proc.WaitForExit($GraceSec * 1000)
            } catch {
                $diagnostic = $_.Exception.Message
            }
            $diagnostic = (
                ("outer completion bound exceeded: mode={0} suites={1} waves={2} " +
                "timeout_sec={3} grace_sec={4} bound_ms={5} root_pid={6} cleanup_exited={7} {8}") -f
                $Mode, $plan.SuiteCount, $plan.Waves, $TimeoutSec, $GraceSec,
                $plan.CompletionBoundMs, $proc.Id, $cleanupSucceeded, $diagnostic).Trim()
        }
        $proc.Refresh()
        if ($proc.HasExited) { $proc.WaitForExit() }
        $exit = if ($proc.HasExited) { $proc.ExitCode } else { $null }
        $stdout = if (Test-Path -LiteralPath $out) { Get-Content -LiteralPath $out -Raw } else { '' }
        $stderr = if (Test-Path -LiteralPath $err) { Get-Content -LiteralPath $err -Raw } else { '' }
        $json = if (Test-Path -LiteralPath $summary) {
            Get-Content -LiteralPath $summary -Raw | ConvertFrom-Json
        } else { $null }
        return [pscustomobject]@{
            Exit = $exit; Out = $stdout; Err = $stderr; Summary = $json
            WallMs = [int64]$watch.Elapsed.TotalMilliseconds
            TimedOut = $timedOut; CleanupSucceeded = $cleanupSucceeded
            Diagnostic = $diagnostic; CompletionBoundMs = $plan.CompletionBoundMs
            SuiteCount = $plan.SuiteCount; Waves = $plan.Waves
        }
    } finally {
        $watch.Stop()
        $proc.Dispose()
        Remove-Item Env:ORCHESTRA_RUN_ALL_BENCH_STATE -ErrorAction SilentlyContinue
        Remove-Item Env:ORCHESTRA_RUN_ALL_BENCH_GATE -ErrorAction SilentlyContinue
        Remove-Item Env:ORCHESTRA_RUN_ALL_BENCH_REQUIRE_GATE -ErrorAction SilentlyContinue
    }
}

$suiteText = @'
# ci:parallel-safe-fixture
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$statePath = $env:ORCHESTRA_RUN_ALL_BENCH_STATE
function Update-State {
    param([int]$Delta)
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($deadline.Elapsed.TotalSeconds -lt 10) {
        $stream = $null
        try {
            $stream = [IO.File]::Open($statePath, [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true, 1024, $true)
            $text = $reader.ReadToEnd()
            $reader.Dispose()
            $state = if ($text) { $text | ConvertFrom-Json } else {
                [pscustomobject]@{ launches = 0; active = 0; max_active = 0 }
            }
            if ($Delta -gt 0) { $state.launches = [int]$state.launches + 1 }
            $state.active = [int]$state.active + $Delta
            if ([int]$state.active -gt [int]$state.max_active) {
                $state.max_active = [int]$state.active
            }
            $bytes = [Text.Encoding]::UTF8.GetBytes(($state | ConvertTo-Json -Compress))
            $stream.SetLength(0)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
            return
        } catch [IO.IOException] {
            Start-Sleep -Milliseconds 10
        } finally {
            if ($stream) { $stream.Dispose() }
        }
    }
    throw 'state lock timeout'
}
Update-State 1
try {
    $name = [IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
    [IO.File]::WriteAllText((Join-Path (Split-Path $statePath -Parent) "$name.started"), 'ready')
    if ($env:ORCHESTRA_RUN_ALL_BENCH_REQUIRE_GATE -eq '1') {
        $wait = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $env:ORCHESTRA_RUN_ALL_BENCH_GATE)) {
            if ($wait.Elapsed.TotalSeconds -ge 10) { throw 'release gate timeout' }
            Start-Sleep -Milliseconds 20
        }
    }
    Start-Sleep -Milliseconds 700
} finally {
    Update-State -1
}
exit 0
'@

try {
    # Same four artificial suites and same exit codes in serial/optimized modes.
    $benchmark = New-Root
    foreach ($name in @('test-a.ps1', 'test-b.ps1', 'test-c.ps1', 'test-d.ps1')) {
        Write-Utf8 (Join-Path $benchmark $name) $suiteText
    }
    $serial = Invoke-Runner $benchmark 'Serial' 3 $true
    $serialState = Get-Content -LiteralPath (Join-Path $benchmark 'state.json') -Raw | ConvertFrom-Json
    Remove-Item -LiteralPath (Join-Path $benchmark 'state.json') -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $benchmark -Filter '*.started' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    $optimized = Invoke-Runner $benchmark 'Optimized' 3 $true -RequireGate $true
    $optimizedState = Get-Content -LiteralPath (Join-Path $benchmark 'state.json') -Raw | ConvertFrom-Json

    if ($null -eq $serial.Summary) {
        throw "serial benchmark summary missing (exit=$($serial.Exit), diagnostic=$($serial.Diagnostic))`nstdout:`n$($serial.Out)`nstderr:`n$($serial.Err)"
    }
    if ($null -eq $optimized.Summary) {
        throw "optimized benchmark summary missing (exit=$($optimized.Exit), diagnostic=$($optimized.Diagnostic))`nstdout:`n$($optimized.Out)`nstderr:`n$($optimized.Err)"
    }
    Assert-True (-not $serial.TimedOut) 'serial benchmark completes inside computed outer bound'
    Assert-True (-not $optimized.TimedOut) 'optimized benchmark completes inside computed outer bound'
    Assert-True ($serial.CompletionBoundMs -gt $optimized.CompletionBoundMs) 'completion bound reflects serial versus parallel wave count'
    Assert-Eq 0 $serial.Exit 'serial benchmark runner exits zero'
    Assert-Eq 0 $optimized.Exit 'optimized benchmark runner exits zero'
    Assert-Eq 'pass' $serial.Summary.verdict 'serial correctness verdict'
    Assert-Eq 'pass' $optimized.Summary.verdict 'optimized correctness verdict'
    Assert-Eq 4 $serial.Summary.discovered 'serial discovery count'
    Assert-Eq 4 $optimized.Summary.discovered 'optimized discovery count'
    Assert-Eq 4 $serial.Summary.child_launches 'serial child launch count'
    Assert-Eq 4 $optimized.Summary.child_launches 'optimized child launch count'
    Assert-Eq 1 $serialState.max_active 'serial fixture has no overlap'
    Assert-True ($optimizedState.max_active -ge 2) 'optimized fixture records actual overlap'
    Assert-True ($optimizedState.max_active -le 3) 'optimized fixture honors bounded parallelism'
    Assert-Eq 0 $serial.Summary.survivors 'serial terminal survivors'
    Assert-Eq 0 $optimized.Summary.survivors 'optimized terminal survivors'
    Assert-Eq 0 @($serial.Summary.results | Where-Object {
        -not $_.terminal_green -or $_.reason -ne 'ok' -or $_.exit_code -ne 0 -or $_.survivors -ne 0
    }).Count 'every serial suite has a terminal-green result'
    Assert-Eq 0 @($optimized.Summary.results | Where-Object {
        -not $_.terminal_green -or $_.reason -ne 'ok' -or $_.exit_code -ne 0 -or $_.survivors -ne 0
    }).Count 'every optimized suite has a terminal-green result'
    $serialCodes = @($serial.Summary.results | Sort-Object name | ForEach-Object { "$($_.name):$($_.exit_code)" })
    $optimizedCodes = @($optimized.Summary.results | Sort-Object name | ForEach-Object { "$($_.name):$($_.exit_code)" })
    Assert-Eq ($serialCodes -join ',') ($optimizedCodes -join ',') 'serial/optimized suite names and exit codes match'

    # Unclassified/conflicting suites are explicitly serialized.
    $serialized = New-Root
    Write-Utf8 (Join-Path $serialized 'test-s1.ps1') ($suiteText -replace '# ci:parallel-safe-fixture', '')
    Write-Utf8 (Join-Path $serialized 'test-s2.ps1') ($suiteText -replace '# ci:parallel-safe-fixture', '')
    $serialGroup = Invoke-Runner $serialized 'Optimized' 4 $true
    $serialGroupState = Get-Content -LiteralPath (Join-Path $serialized 'state.json') -Raw | ConvertFrom-Json
    Assert-Eq 0 $serialGroup.Exit 'unclassified serial group passes'
    Assert-Eq 1 $serialGroup.Summary.max_parallel_observed 'unclassified suites run one at a time'
    Assert-Eq 1 $serialGroupState.max_active 'conflicting group has no actual overlap'
    Assert-Eq 0 @($serialGroup.Summary.results | Where-Object { -not $_.terminal_green }).Count 'serial conflict group is terminal green'

    # One failed parallel suite cannot be masked by successful siblings.
    $partial = New-Root
    Write-Utf8 (Join-Path $partial 'test-ok.ps1') "# ci:parallel-safe-fixture`nexit 0`n"
    Write-Utf8 (Join-Path $partial 'test-fail.ps1') "# ci:parallel-safe-fixture`nexit 9`n"
    $partialResult = Invoke-Runner $partial 'Optimized' 2 $true
    Assert-True ($partialResult.Exit -ne 0) 'partial parallel failure returns nonzero'
    Assert-Eq 'fail' $partialResult.Summary.verdict 'partial parallel failure summary'
    Assert-Eq 2 $partialResult.Summary.child_launches 'partial failure loses no discovered suite'
    Assert-Eq 1 @($partialResult.Summary.results | Where-Object { -not $_.terminal_green }).Count 'exactly failed suite is reported'

    # A nominally successful supervisor result with a survivor is fail-closed.
    $survivorRoot = New-Root
    Write-Utf8 (Join-Path $survivorRoot 'test-survivor.ps1') 'exit 0'
    $fakeSupervisor = Join-Path $survivorRoot 'fake-supervisor.ps1'
    Write-Utf8 $fakeSupervisor @'
$result = ''
$stdout = ''
$stderr = ''
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq '--result-file') { $result = $args[++$i] }
    elseif ($args[$i] -eq '--stdout-file') { $stdout = $args[++$i] }
    elseif ($args[$i] -eq '--stderr-file') { $stderr = $args[++$i] }
}
[IO.File]::WriteAllText($stdout, '')
[IO.File]::WriteAllText($stderr, '')
[IO.File]::WriteAllText($result, '{"reason":"ok","exit_code":0,"duration_ms":1,"cleanup_attempted":true,"survivor_count_after_cleanup":1}')
exit 0
'@
    $survivorResult = Invoke-Runner $survivorRoot 'Serial' 1 $false $fakeSupervisor
    Assert-True ($survivorResult.Exit -ne 0) 'survivors greater than zero fail aggregate runner'
    Assert-Eq 1 $survivorResult.Summary.survivors 'survivor count is preserved in summary'

    # A supervisor process that never emits a result is bounded by the aggregate
    # parent deadline; its descendant tree is killed and a complete failing summary
    # is still produced.
    $hangRoot = New-Root
    Write-Utf8 (Join-Path $hangRoot 'test-hang.ps1') 'exit 0'
    $hangPidFile = Join-Path $hangRoot 'hang-child.pid'
    $env:ORCHESTRA_RUN_ALL_HANG_PID_FILE = $hangPidFile
    $hangSupervisor = Join-Path $hangRoot 'hang-supervisor.ps1'
    Write-Utf8 $hangSupervisor @'
$hostPath = ([Diagnostics.Process]::GetCurrentProcess()).MainModule.FileName
$child = Start-Process -FilePath $hostPath -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 90') -PassThru
[IO.File]::WriteAllText($env:ORCHESTRA_RUN_ALL_HANG_PID_FILE, [string]$child.Id)
Start-Sleep -Seconds 90
'@
    try {
        $hangWatch = [Diagnostics.Stopwatch]::StartNew()
        # Allow enough startup room for the fake supervisor to publish its descendant PID
        # even on a loaded Windows host. The assertion remains well below the fake's
        # 90-second natural completion, so only the runner's parent deadline can pass it.
        $hangResult = Invoke-Runner $hangRoot 'Serial' 1 $false $hangSupervisor $false 15 3
        $hangWatch.Stop()
        Assert-True ($hangWatch.Elapsed.TotalSeconds -lt 60) 'hanging supervisor is bounded by parent deadline and cleanup grace'
        Assert-True ($hangResult.Exit -ne 0) 'hanging supervisor returns nonzero aggregate exit'
        Assert-Eq 'fail' $hangResult.Summary.verdict 'hanging supervisor writes failing summary'
        Assert-Eq 1 @($hangResult.Summary.results).Count 'hanging supervisor preserves complete discovered result set'
        Assert-Eq 'parent-timeout' $hangResult.Summary.results[0].reason 'hanging supervisor gets explicit parent-timeout reason'
        Assert-Eq 0 $hangResult.Summary.survivors 'bounded cleanup reports no surviving tree'
        $pidValue = if (Test-Path -LiteralPath $hangPidFile) { [int](Get-Content -LiteralPath $hangPidFile -Raw) } else { 0 }
        $goneDeadline = [Diagnostics.Stopwatch]::StartNew()
        while ($pidValue -gt 0 -and (Get-Process -Id $pidValue -ErrorAction SilentlyContinue) -and
            $goneDeadline.Elapsed.TotalSeconds -lt 5) {
            Start-Sleep -Milliseconds 50
        }
        Assert-True ($pidValue -gt 0) 'hanging fake published descendant pid'
        Assert-True (-not (Get-Process -Id $pidValue -ErrorAction SilentlyContinue)) 'hanging fake descendant does not survive aggregate cleanup'
    } finally {
        Remove-Item Env:ORCHESTRA_RUN_ALL_HANG_PID_FILE -ErrorAction SilentlyContinue
    }

    # The test wrapper itself also has a formula-derived finite deadline. Exercise its
    # timeout branch with a fake outer runner and prove whole-tree cleanup plus explicit
    # diagnostics; this is distinct from run-all's per-suite supervisor deadline above.
    $outerHangRoot = New-Root
    Write-Utf8 (Join-Path $outerHangRoot 'test-placeholder.ps1') 'exit 0'
    $outerHangPidFile = Join-Path $outerHangRoot 'outer-hang-child.pid'
    $env:ORCHESTRA_RUN_ALL_OUTER_HANG_PID_FILE = $outerHangPidFile
    $outerHangRunner = Join-Path $outerHangRoot 'outer-hang-runner.ps1'
    Write-Utf8 $outerHangRunner @'
$hostPath = ([Diagnostics.Process]::GetCurrentProcess()).MainModule.FileName
$child = Start-Process -FilePath $hostPath -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 90') -PassThru
[IO.File]::WriteAllText($env:ORCHESTRA_RUN_ALL_OUTER_HANG_PID_FILE, [string]$child.Id)
Start-Sleep -Seconds 90
'@
    try {
        $outerHang = Invoke-Runner $outerHangRoot 'Serial' 1 $false -TimeoutSec 3 -GraceSec 2 -RunnerPath $outerHangRunner
        Assert-True $outerHang.TimedOut 'outer wrapper enforces formula-derived completion bound'
        Assert-True $outerHang.CleanupSucceeded 'outer wrapper reaps the timed-out runner tree'
        Assert-True ($outerHang.Diagnostic -like '*mode=Serial*suites=1*waves=1*') 'outer timeout diagnostic records bound inputs'
        Assert-True ($outerHang.WallMs -le ($outerHang.CompletionBoundMs + 15000)) 'outer timeout cleanup stays bounded'
        $outerPid = if (Test-Path -LiteralPath $outerHangPidFile) {
            [int](Get-Content -LiteralPath $outerHangPidFile -Raw)
        } else { 0 }
        Assert-True ($outerPid -gt 0) 'outer hanging fake published descendant pid'
        Assert-True (-not (Get-Process -Id $outerPid -ErrorAction SilentlyContinue)) 'outer wrapper leaves no surviving descendant'
    } finally {
        Remove-Item Env:ORCHESTRA_RUN_ALL_OUTER_HANG_PID_FILE -ErrorAction SilentlyContinue
    }
} finally {
    foreach ($root in $Roots) {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($Failures.Count -gt 0) {
    Write-Host "FAILED - $($Failures.Count) assertion(s):"
    $Failures | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Write-Host ("OK - run-all correctness suites=4 launches=4 max-parallel={0} survivors=0; performance-observation serial={1}ms optimized={2}ms delta={3}ms" -f
    $optimizedState.max_active, $serial.WallMs, $optimized.WallMs, ($serial.WallMs - $optimized.WallMs))
exit 0
