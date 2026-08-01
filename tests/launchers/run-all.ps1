<#
  Runs every tests/launchers/test-*.ps1 in an isolated child PowerShell process.

  The default optimized mode parallelizes only the explicit allow-list below. Every
  unclassified or process-sensitive suite stays serial, so adding a new test can never
  silently widen concurrency. Each suite is contained by tools/supervisor.ps1; a suite is
  green only when its terminal result says reason=ok, exit_code=0 and survivors=0.

  On Windows all suites run under Windows PowerShell 5.1. On POSIX only files marked
  `# ci:posix` run, under PowerShell 7.

  Exit code: zero only when every discovered/eligible suite is terminal green. Output and
  the final summary are emitted in deterministic file-name order, independently of
  completion order.
#>

[CmdletBinding()]
param(
    [ValidateSet('Optimized', 'Serial')]
    [string] $Mode = 'Optimized',
    [ValidateRange(1, 16)]
    [int] $MaxParallel = 4,
    [ValidateRange(1, 7200)]
    [int] $TestTimeoutSec = 1800,
    [ValidateRange(1, 300)]
    [int] $SupervisorGraceSec = 15,
    [string] $TestDirectory = $PSScriptRoot,
    [string] $SummaryPath = '',
    [string] $SupervisorPath = '',
    # Test-only seam used by tests/test-run-all.ps1. Production discovery never relies
    # on a self-asserted marker; its parallel population is the reviewed allow-list.
    [switch] $AllowFixtureParallelMarkers
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$onWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows)
$hostExe = if ($onWindows) {
    'powershell.exe'
} else {
    $pwshCmd = @(Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue) |
        Select-Object -First 1
    if (-not $pwshCmd) {
        Write-Host 'FAIL - pwsh (PowerShell 7) not found on PATH.'
        exit 1
    }
    [string]$pwshCmd.Source
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $repoRoot 'tools\proc-tree.ps1')
if (-not $SupervisorPath) { $SupervisorPath = Join-Path $repoRoot 'tools\supervisor.ps1' }
if (-not (Test-Path -LiteralPath $SupervisorPath -PathType Leaf)) {
    Write-Host "FAIL - supervisor not found: $SupervisorPath"
    exit 1
}
$resolvedTestDirectory = (Resolve-Path -LiteralPath $TestDirectory).Path
$isProductionDirectory = [string]::Equals(
    $resolvedTestDirectory, (Resolve-Path -LiteralPath $PSScriptRoot).Path,
    [System.StringComparison]::OrdinalIgnoreCase)

$allFiles = @(Get-ChildItem -LiteralPath $resolvedTestDirectory -Filter 'test-*.ps1' -File |
    Sort-Object Name)
if ($allFiles.Count -eq 0) {
    Write-Host 'No test-*.ps1 files found.'
    exit 1
}

if ($isProductionDirectory) {
    $requiredLauncherTests = @(
        'test-cc-metrics.ps1',
        'test-cc-pause.ps1',
        'test-cc-unpause.ps1'
    )
    $presentNames = @($allFiles | ForEach-Object { $_.Name })
    $missingRequired = @($requiredLauncherTests | Where-Object { $_ -notin $presentNames })
    if ($missingRequired.Count -gt 0) {
        Write-Host ('Required launcher test(s) missing: ' + ($missingRequired -join ', '))
        exit 1
    }
}

if ($onWindows) {
    $testFiles = $allFiles
} else {
    $testFiles = @($allFiles | Where-Object {
        $head = Get-Content -LiteralPath $_.FullName -TotalCount 40 -ErrorAction SilentlyContinue
        ($head -join "`n") -match '(?m)^#\s*ci:posix\b'
    })
    $skipped = @($allFiles | Where-Object { $testFiles -notcontains $_ })
    if ($skipped.Count -gt 0) {
        Write-Host ("Skipping {0} Windows-only launcher test(s) on this OS: {1}" -f
            $skipped.Count, (($skipped | ForEach-Object { $_.Name }) -join ', '))
    }
    if ($testFiles.Count -eq 0) {
        Write-Host 'No cross-platform (# ci:posix) test-*.ps1 files found.'
        exit 1
    }
}

# Every listed suite documents or inherits a unique-temp-root contract and runs in a
# separate child process. test-state-tx.ps1 remains explicit serial because its
# process-liveness race is timing-sensitive under concurrent process load. Newly
# discovered suites default to serial until this allow-list is deliberately reviewed.
$parallelSafeNames = @(
    'test-cc-audit.ps1',
    'test-cc-config.ps1',
    'test-cc-deps.ps1',
    'test-cc-enhance.ps1',
    'test-cc-github.ps1',
    'test-cc-inbox.ps1',
    'test-cc-journal.ps1',
    'test-cc-metrics.ps1',
    'test-cc-pause.ps1',
    'test-cc-processor.ps1',
    'test-cc-proposal.ps1',
    'test-cc-queue.ps1',
    'test-cc-resume.ps1',
    'test-cc-status.ps1',
    'test-cc-thinker.ps1',
    'test-cc-unpause.ps1',
    'test-codex-all-routing.ps1',
    'test-codex-processor-runtime.ps1',
    'test-codex-role-runtime.ps1',
    'test-doctor-runtime.ps1',
    'test-generate-coders.ps1',
    'test-generate-codex-agents.ps1',
    'test-launcher-line-endings.ps1',
    'test-processkit-runtime.ps1',
    'test-queue-tx.ps1',
    'test-sync-launcher.ps1',
    'test-sync-runtime.ps1'
)
$parallelFiles = @()
$serialFiles = @()
foreach ($file in $testFiles) {
    $fixtureSafe = $false
    if ($AllowFixtureParallelMarkers -and -not $isProductionDirectory) {
        $head = Get-Content -LiteralPath $file.FullName -TotalCount 20 -ErrorAction SilentlyContinue
        $fixtureSafe = (($head -join "`n") -match '(?m)^#\s*ci:parallel-safe-fixture\b')
    }
    if ($Mode -eq 'Optimized' -and
        (($isProductionDirectory -and $file.Name -in $parallelSafeNames) -or $fixtureSafe)) {
        $parallelFiles += $file
    } else {
        $serialFiles += $file
    }
}

$runRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'orchestra-run-all-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($runRoot)
$active = [System.Collections.Generic.List[object]]::new()
$results = @{}
$launchCount = 0
$maxObserved = 0
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

function Get-Prop {
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) {
        $value = $Object[$Name]
        if ($value -is [System.Array]) {
            Write-Output -NoEnumerate $value
        } else {
            return $value
        }
        return
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    if ($property.Value -is [System.Array]) {
        Write-Output -NoEnumerate $property.Value
    } else {
        return $property.Value
    }
}

function Test-JsonObject {
    param($Value)
    return ($null -ne $Value -and
        $Value.GetType() -eq [System.Management.Automation.PSCustomObject])
}

function Test-JsonString {
    param($Value)
    return ($null -ne $Value -and $Value.GetType() -eq [string])
}

function Test-JsonIntegerInRange {
    param($Value, [decimal] $Minimum, [decimal] $Maximum)
    if ($null -eq $Value) { return $false }
    $integralTypes = @(
        [sbyte], [byte], [int16], [uint16],
        [int32], [uint32], [int64], [uint64]
    )
    if ($integralTypes -notcontains $Value.GetType()) { return $false }
    $number = [decimal]$Value
    return ($number -ge $Minimum -and $number -le $Maximum)
}

function Test-TerminalSupervisorRecord {
    param($Record)
    if (-not (Test-JsonObject $Record)) { return $false }
    $reason = Get-Prop $Record 'reason'
    $exitCode = Get-Prop $Record 'exit_code'
    $survivors = Get-Prop $Record 'survivor_count_after_cleanup'
    $cleanupAttempted = Get-Prop $Record 'cleanup_attempted'
    return (
        (Test-JsonString $reason) -and $reason -ceq 'ok' -and
        (Test-JsonIntegerInRange $exitCode ([int]::MinValue) ([int]::MaxValue)) -and
            [decimal]$exitCode -eq 0 -and
        (Test-JsonIntegerInRange $survivors 0 ([int]::MaxValue)) -and
            [decimal]$survivors -eq 0 -and
        $null -ne $cleanupAttempted -and
            $cleanupAttempted.GetType() -eq [bool] -and
            $cleanupAttempted -eq $true
    )
}

function Start-Suite {
    param([System.IO.FileInfo] $File, [string] $Group)
    $safe = $File.BaseName -replace '[^A-Za-z0-9_.-]', '_'
    $prefix = Join-Path $runRoot $safe
    $resultFile = "$prefix.result.json"
    $stdoutFile = "$prefix.stdout.txt"
    $stderrFile = "$prefix.stderr.txt"
    $supervisorOut = "$prefix.supervisor.out.txt"
    $supervisorErr = "$prefix.supervisor.err.txt"
    $args = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $SupervisorPath, 'run',
        '--file', $File.FullName,
        '--working-directory', $repoRoot,
        '--deadline-sec', [string]$TestTimeoutSec,
        '--output-max-bytes', '1048576',
        '--result-file', $resultFile,
        '--stdout-file', $stdoutFile,
        '--stderr-file', $stderrFile,
        '--work', $runRoot,
        '--task-id', '_launcher_suite',
        '--role', 'test',
        '--label', $safe,
        '--process-diagnostics'
    )
    try {
        $proc = Start-Process -FilePath $hostExe -ArgumentList $args -NoNewWindow -PassThru `
            -RedirectStandardOutput $supervisorOut -RedirectStandardError $supervisorErr
        $script:launchCount++
        $entry = [pscustomobject]@{
            File = $File
            Group = $Group
            Process = $proc
            ResultFile = $resultFile
            StdoutFile = $stdoutFile
            StderrFile = $stderrFile
            SupervisorOut = $supervisorOut
            SupervisorErr = $supervisorErr
            StartedAt = [DateTime]::UtcNow
            ParentDeadline = [DateTime]::UtcNow.AddSeconds($TestTimeoutSec + $SupervisorGraceSec)
        }
        $script:active.Add($entry)
        if ($script:active.Count -gt $script:maxObserved) {
            $script:maxObserved = $script:active.Count
        }
    } catch {
        $script:results[$File.Name] = [pscustomobject]@{
            name = $File.Name; group = $Group; reason = 'spawn-failed'; exit_code = $null
            survivors = $null; duration_ms = 0; terminal_green = $false
            stdout = ''; stderr = $_.Exception.Message
        }
    }
}

function Complete-Suite {
    param($Entry, [string]$ForcedReason = '', [bool]$CleanupSucceeded = $false)
    $proc = $Entry.Process
    if (-not $ForcedReason) { $proc.WaitForExit() }
    $proc.Refresh()
    $supervisorExit = if ($proc.HasExited) { $proc.ExitCode } else { $null }
    $stdout = if (Test-Path -LiteralPath $Entry.StdoutFile) {
        Get-Content -LiteralPath $Entry.StdoutFile -Raw -ErrorAction SilentlyContinue
    } else { '' }
    $stderr = if (Test-Path -LiteralPath $Entry.StderrFile) {
        Get-Content -LiteralPath $Entry.StderrFile -Raw -ErrorAction SilentlyContinue
    } else { '' }
    $supervisorStderr = if (Test-Path -LiteralPath $Entry.SupervisorErr) {
        Get-Content -LiteralPath $Entry.SupervisorErr -Raw -ErrorAction SilentlyContinue
    } else { '' }
    $record = $null
    $recordState = 'missing-result'
    if (Test-Path -LiteralPath $Entry.ResultFile) {
        try {
            $rawRecord = Get-Content -LiteralPath $Entry.ResultFile -Raw
            if ([string]::IsNullOrWhiteSpace($rawRecord) -or
                -not $rawRecord.TrimStart().StartsWith('{')) {
                throw 'supervisor result body must be one JSON object'
            }
            $record = ConvertFrom-Json -InputObject $rawRecord
            if (-not (Test-JsonObject $record)) {
                throw 'supervisor result body must be one JSON object'
            }
            $rawReason = Get-Prop $record 'reason'
            $recordState = if (Test-JsonString $rawReason) {
                $rawReason
            } else {
                'invalid-result'
            }
        } catch {
            $recordState = 'invalid-result'
            $supervisorStderr = ($supervisorStderr + "`n" + $_.Exception.Message).Trim()
        }
    }
    $childExit = Get-Prop $record 'exit_code'
    $survivors = Get-Prop $record 'survivor_count_after_cleanup'
    $duration = Get-Prop $record 'duration_ms'
    if ($ForcedReason) {
        $recordState = $ForcedReason
        $childExit = $null
        $survivors = if ($CleanupSucceeded) { 0 } else { 1 }
        $duration = [int64]([DateTime]::UtcNow - $Entry.StartedAt).TotalMilliseconds
    }
    $terminalGreen = (
        -not $ForcedReason -and
        $supervisorExit -eq 0 -and
        (Test-TerminalSupervisorRecord $record)
    )
    $script:results[$Entry.File.Name] = [pscustomobject]@{
        name = $Entry.File.Name
        group = $Entry.Group
        reason = $recordState
        exit_code = $childExit
        survivors = $survivors
        duration_ms = if ($null -ne $duration) { [int64]$duration } else { 0 }
        terminal_green = $terminalGreen
        stdout = [string]$stdout
        stderr = ([string]$stderr + "`n" + [string]$supervisorStderr).Trim()
    }
    $proc.Dispose()
    [void]$script:active.Remove($Entry)
}

function Wait-OneSuite {
    while ($script:active.Count -gt 0) {
        foreach ($entry in @($script:active)) {
            if ($entry.Process.HasExited) {
                Complete-Suite $entry
                return
            }
            if ([DateTime]::UtcNow -ge $entry.ParentDeadline) {
                $cleanupSucceeded = $false
                try {
                    Stop-ProcessTree $entry.Process
                    $cleanupSucceeded = $entry.Process.WaitForExit($SupervisorGraceSec * 1000)
                } catch { }
                Complete-Suite $entry 'parent-timeout' $cleanupSucceeded
                return
            }
        }
        Start-Sleep -Milliseconds 50
    }
}

try {
    foreach ($file in $parallelFiles) {
        while ($active.Count -ge $MaxParallel) { Wait-OneSuite }
        Start-Suite $file 'parallel'
    }
    while ($active.Count -gt 0) { Wait-OneSuite }

    foreach ($file in $serialFiles) {
        Start-Suite $file 'serial'
        while ($active.Count -gt 0) { Wait-OneSuite }
    }
} finally {
    # A runner-internal exception must not strand a partially launched suite tree.
    foreach ($entry in @($active)) {
        try {
            if (-not $entry.Process.HasExited) {
                Stop-ProcessTree $entry.Process
            }
        } catch { }
        try { $entry.Process.Dispose() } catch { }
    }
    $stopwatch.Stop()
}

$ordered = @($testFiles | ForEach-Object {
    if ($results.ContainsKey($_.Name)) { $results[$_.Name] }
    else {
        [pscustomobject]@{
            name = $_.Name; group = 'unknown'; reason = 'missing-aggregate-result'
            exit_code = $null; survivors = $null; duration_ms = 0
            terminal_green = $false; stdout = ''; stderr = ''
        }
    }
})
foreach ($result in $ordered) {
    if ($result.stdout) { Write-Host ([string]$result.stdout).TrimEnd() }
    if ($result.stderr) { Write-Host ([string]$result.stderr).TrimEnd() }
}

$failed = @($ordered | Where-Object { -not $_.terminal_green })
$survivorsTotal = 0
foreach ($result in $ordered) {
    if (Test-JsonIntegerInRange $result.survivors 0 ([int]::MaxValue)) {
        $survivorsTotal += [int]$result.survivors
    }
}
$summary = [ordered]@{
    schema = 'orchestra/launcher-suite-summary@1'
    mode = $Mode.ToLowerInvariant()
    discovered = $testFiles.Count
    child_launches = $launchCount
    max_parallel_observed = $maxObserved
    duration_ms = [int64]$stopwatch.Elapsed.TotalMilliseconds
    verdict = if ($failed.Count -eq 0 -and $launchCount -eq $testFiles.Count -and
        $survivorsTotal -eq 0) { 'pass' } else { 'fail' }
    survivors = $survivorsTotal
    results = @($ordered | ForEach-Object {
        [ordered]@{
            name = $_.name; group = $_.group; reason = $_.reason
            exit_code = $_.exit_code; survivors = $_.survivors
            duration_ms = $_.duration_ms; terminal_green = $_.terminal_green
        }
    })
}
if ($SummaryPath) {
    $summaryDir = Split-Path -Parent $SummaryPath
    if ($summaryDir -and -not (Test-Path -LiteralPath $summaryDir)) {
        [void][System.IO.Directory]::CreateDirectory($summaryDir)
    }
    [System.IO.File]::WriteAllText(
        $SummaryPath,
        ($summary | ConvertTo-Json -Depth 8),
        (New-Object System.Text.UTF8Encoding($false)))
}

Write-Host ''
Write-Host ("== {0}/{1} test files terminal green; mode={2}; launches={3}; max-parallel={4}; wall={5}ms; survivors={6} ==" -f
    ($testFiles.Count - $failed.Count), $testFiles.Count, $summary.mode,
    $launchCount, $maxObserved, $summary.duration_ms, $survivorsTotal)
if ($failed.Count -gt 0) {
    Write-Host ('Failed: ' + (($failed | ForEach-Object {
        "$($_.name)[$($_.reason)/exit=$($_.exit_code)/survivors=$($_.survivors)]"
    }) -join ', '))
}

Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
if ($summary.verdict -ne 'pass') { exit ([Math]::Max(1, $failed.Count)) }
exit 0
