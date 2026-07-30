<# Hermetic scheduler/benchmark regressions for tests/launchers/run-all.ps1. #>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$Runner = Join-Path $PSScriptRoot 'launchers\run-all.ps1'
$PsExe = ([System.Diagnostics.Process]::GetCurrentProcess()).MainModule.FileName
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Failures = [System.Collections.Generic.List[string]]::new()
$Roots = [System.Collections.Generic.List[string]]::new()

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
function Invoke-Runner {
    param(
        [string]$Directory,
        [string]$Mode,
        [int]$MaxParallel,
        [bool]$FixtureMarkers,
        [string]$Supervisor = '',
        [bool]$RequireGate = $false
    )
    $summary = Join-Path $Directory "$($Mode.ToLowerInvariant()).summary.json"
    $out = Join-Path $Directory "$($Mode.ToLowerInvariant()).runner.out.txt"
    $err = Join-Path $Directory "$($Mode.ToLowerInvariant()).runner.err.txt"
    $gate = Join-Path $Directory 'release.gate'
    $env:ORCHESTRA_RUN_ALL_BENCH_STATE = Join-Path $Directory 'state.json'
    $env:ORCHESTRA_RUN_ALL_BENCH_GATE = $gate
    $env:ORCHESTRA_RUN_ALL_BENCH_REQUIRE_GATE = if ($RequireGate) { '1' } else { '0' }
    $runnerArgs = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $Runner,
        '-Mode', $Mode,
        '-MaxParallel', [string]$MaxParallel,
        '-TestTimeoutSec', '30',
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
            while (@(Get-ChildItem -LiteralPath $Directory -Filter '*.started' -ErrorAction SilentlyContinue).Count -lt 2) {
                if ($proc.HasExited -or $producerDeadline.Elapsed.TotalSeconds -ge 15) { break }
                Start-Sleep -Milliseconds 50
            }
            $started = @(Get-ChildItem -LiteralPath $Directory -Filter '*.started' -ErrorAction SilentlyContinue).Count
            Assert-True ($started -ge 2) 'optimized fixture proves overlap before producer release'
            Write-Utf8 $gate 'release'
        }
        if (-not $proc.WaitForExit(60000)) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            $Failures.Add("FAIL - $Mode runner exceeded independently bounded completion wait")
        }
        $proc.Refresh()
        $exit = $proc.ExitCode
        $stdout = if (Test-Path -LiteralPath $out) { Get-Content -LiteralPath $out -Raw } else { '' }
        $stderr = if (Test-Path -LiteralPath $err) { Get-Content -LiteralPath $err -Raw } else { '' }
        $json = if (Test-Path -LiteralPath $summary) {
            Get-Content -LiteralPath $summary -Raw | ConvertFrom-Json
        } else { $null }
        return [pscustomobject]@{
            Exit = $exit; Out = $stdout; Err = $stderr; Summary = $json
            WallMs = [int64]$watch.Elapsed.TotalMilliseconds
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

    Assert-Eq 0 $serial.Exit 'serial benchmark runner exits zero'
    Assert-Eq 0 $optimized.Exit 'optimized benchmark runner exits zero'
    Assert-Eq 4 $serial.Summary.discovered 'serial discovery count'
    Assert-Eq 4 $optimized.Summary.discovered 'optimized discovery count'
    Assert-Eq 4 $serial.Summary.child_launches 'serial child launch count'
    Assert-Eq 4 $optimized.Summary.child_launches 'optimized child launch count'
    Assert-Eq 1 $serialState.max_active 'serial fixture has no overlap'
    Assert-True ($optimizedState.max_active -ge 2) 'optimized fixture records actual overlap'
    Assert-True ($optimizedState.max_active -le 3) 'optimized fixture honors bounded parallelism'
    Assert-Eq 0 $serial.Summary.survivors 'serial terminal survivors'
    Assert-Eq 0 $optimized.Summary.survivors 'optimized terminal survivors'
    Assert-True ($optimized.WallMs -lt $serial.WallMs) 'optimized benchmark wall-clock beats serial'
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
Write-Host ("OK - run-all benchmark serial={0}ms optimized={1}ms suites=4 launches=4 max-parallel={2} survivors=0" -f
    $serial.WallMs, $optimized.WallMs, $optimizedState.max_active)
exit 0
