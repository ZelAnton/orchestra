<#
.SYNOPSIS
    The EXTENDED crash matrix (T-093): the fuller enumeration of fault-injection points
    over tools/harness.ps1, run SEPARATELY from the mandatory CI gate with its own
    documented time limit (it does not block the normal build).

.DESCRIPTION
    tests/test-harness.ps1 is the fast, mandatory slice (a few representative scenarios +
    one fault spot-check). THIS runner is the exhaustive companion: for every scenario and
    every documented fault-injection point (target:stage, discovered from the harness's own
    `list-faults`), on git AND - when the binary is present - jj, it asserts that a
    faulted-then-recovered run converges to EXACTLY the same final fingerprint (trunk tree +
    Tasks archive + deduplicated events.jsonl) as the uninterrupted run of that scenario,
    and that the fault actually fired. A fault a given scenario never reaches is skipped
    (not a failure); a divergence, an unsafe halt the harness caught (exit 4), or a crash of
    the harness itself is a failure.

    Because each harness scenario spawns many child transaction-tool processes, the full
    matrix is intentionally expensive - which is exactly why it is a SEPARATE, non-blocking
    CI job with a `timeout-minutes` bound (see .github/workflows/ci.yml, job `crash-matrix`),
    rather than part of the mandatory validate gate. It can be narrowed with filters for a
    quicker local run.

.PARAMETER (options, --key value | --flag)
    --vcs git|jj|both     which backends to exercise (default: both; jj self-skips if absent)
    --scenarios a,b,c     restrict to these scenarios (default: all from list-scenarios)
    --faults t:s,t:s      restrict to these fault points (default: all from list-faults)
    --json                emit a machine-readable summary object at the end

.EXAMPLE
    pwsh -File tests/test-harness-crashmatrix.ps1
    pwsh -File tests/test-harness-crashmatrix.ps1 --vcs git --scenarios clean,policy
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$opts = @{}
$BoolFlags = @('json')
for ($i = 0; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    if ($a -like '--*') {
        $key = $a.Substring(2)
        if ($BoolFlags -contains $key) { $opts[$key] = $true; continue }
        $i++
        if ($i -lt $args.Count) { $opts[$key] = [string]$args[$i] } else { $opts[$key] = '' }
    }
}
function Opt { param([string]$Name, $Default = $null) if ($opts.ContainsKey($Name)) { return $opts[$Name] } else { return $Default } }

$script:Tool = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\harness.ps1')).Path
$script:PsExe = ([System.Diagnostics.Process]::GetCurrentProcess()).MainModule.FileName
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)

function Invoke-Harness {
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

# Discover the scenario and fault sets from the harness itself, so this runner tracks the
# harness's own catalogue without a hardcoded copy.
function Get-Scenarios {
    $r = Invoke-Harness @('list-scenarios')
    if ($r.ExitCode -ne 0) { throw "list-scenarios failed: $($r.Err)" }
    return @($r.Out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
function Get-Faults {
    $r = Invoke-Harness @('list-faults')
    if ($r.ExitCode -ne 0) { throw "list-faults failed: $($r.Err)" }
    $faults = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($r.Out -split "`n")) {
        $m = [regex]::Match($line.Trim(), '^([a-z\-]+):\s*(.+)$')
        if ($m.Success) {
            foreach ($stage in ($m.Groups[2].Value -split ',')) {
                $s = $stage.Trim()
                if ($s) { $faults.Add("$($m.Groups[1].Value):$s") }
            }
        }
    }
    return @($faults.ToArray())
}

$failures = New-Object System.Collections.Generic.List[string]
$checked = 0; $matched = 0; $skippedUnreached = 0; $diverged = 0

$vcsOpt = [string](Opt 'vcs' 'both')
$vcsList = New-Object System.Collections.Generic.List[string]
if ($vcsOpt -in @('git', 'both')) { $vcsList.Add('git') }
if ($vcsOpt -in @('jj', 'both')) { $vcsList.Add('jj') }

$scenarios = Get-Scenarios
$faults = Get-Faults
if ($opts.ContainsKey('scenarios')) { $sel = @(([string]$opts['scenarios']) -split '[,\s]+' | Where-Object { $_ }); $scenarios = @($scenarios | Where-Object { $sel -contains $_ }) }
if ($opts.ContainsKey('faults')) { $sel = @(([string]$opts['faults']) -split '[,\s]+' | Where-Object { $_ }); $faults = @($faults | Where-Object { $sel -contains $_ }) }

$sw = [System.Diagnostics.Stopwatch]::StartNew()
Write-Host "crash matrix: vcs=[$($vcsList -join ',')] scenarios=$($scenarios.Count) faults=$($faults.Count) (this is the slow, non-blocking matrix)"

foreach ($vcs in $vcsList) {
    # A single probe run: exit 3 means the backend is absent -> skip the whole vcs.
    $probe = Invoke-Harness @('scenario', '--vcs', $vcs, '--name', $scenarios[0], '--json')
    if ($probe.ExitCode -eq 3) { Write-Host "SKIP - $vcs backend not installed."; continue }

    foreach ($name in $scenarios) {
        $baseRun = Invoke-Harness @('scenario', '--vcs', $vcs, '--name', $name, '--json')
        if ($baseRun.ExitCode -eq 3) { continue }
        if ($baseRun.ExitCode -ne 0) { $failures.Add("[$vcs/$name] baseline run failed (exit $($baseRun.ExitCode)): $($baseRun.Err.Trim())"); continue }
        $baseFp = ($baseRun.Out.Trim() | ConvertFrom-Json).fingerprint

        foreach ($fault in $faults) {
            $r = Invoke-Harness @('scenario', '--vcs', $vcs, '--name', $name, '--fault', $fault, '--json')
            if ($r.ExitCode -eq 2 -and $r.Err -match 'never reached') { $skippedUnreached++; continue }
            $checked++
            if ($r.ExitCode -ne 0) {
                $diverged++
                $failures.Add("[$vcs/$name/$fault] harness exit $($r.ExitCode): $($r.Err.Trim())")
                Write-Host "  DIVERGE $vcs/$name/$fault -> exit $($r.ExitCode)"
                continue
            }
            $fp = ($r.Out.Trim() | ConvertFrom-Json)
            if (-not $fp.fault_fired) {
                $diverged++
                $failures.Add("[$vcs/$name/$fault] fault did not fire")
                Write-Host "  NOFIRE  $vcs/$name/$fault"
                continue
            }
            if ($fp.fingerprint -ne $baseFp) {
                $diverged++
                $failures.Add("[$vcs/$name/$fault] fingerprint diverged from the clean run")
                Write-Host "  DIVERGE $vcs/$name/$fault -> fingerprint mismatch"
                continue
            }
            $matched++
        }
        Write-Host "  ok $vcs/$name (checked so far=$checked matched=$matched skipped=$skippedUnreached, elapsed=$([int]$sw.Elapsed.TotalSeconds)s)"
    }
}
$sw.Stop()

if ($opts.ContainsKey('json')) {
    $out = [ordered]@{
        checked           = $checked
        matched           = $matched
        diverged          = $diverged
        skipped_unreached = $skippedUnreached
        elapsed_sec       = [int]$sw.Elapsed.TotalSeconds
        failures          = @($failures)
    }
    Write-Output ($out | ConvertTo-Json -Depth 6 -Compress)
}

if ($failures.Count -eq 0) {
    Write-Host "OK - crash matrix: $matched fault-injection points converged, $skippedUnreached unreached-skipped, in $([int]$sw.Elapsed.TotalSeconds)s."
    exit 0
}
Write-Host "FAILED - crash matrix: $($failures.Count) divergence(s) of $checked checked:"
foreach ($f in $failures) { Write-Host "  $f" }
exit 1
