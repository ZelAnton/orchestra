<#
.SYNOPSIS
    The FAST (mandatory-CI) slice of the end-to-end resilience harness matrix (T-093),
    driving tools/harness.ps1.

.DESCRIPTION
    tools/harness.ps1 runs Orchestra's full cohort lifecycle over a disposable, offline
    git (or jj) fixture and, at each critical transition, can inject a crash and verify
    that a recovery replay converges to the SAME final fingerprint (trunk tree + Tasks
    archive + deduplicated events.jsonl) as an uninterrupted run. Each harness scenario
    spawns many child transaction-tool processes, so the FULL scenario x fault x vcs
    cross-product is expensive; that exhaustive enumeration lives in the SEPARATE,
    time-limited, non-blocking tests/test-harness-crashmatrix.ps1. THIS file is the fast
    smoke slice wired into the mandatory CI job: a few representative scenarios (one per
    terminal-outcome class) plus one fault-injection equivalence spot-check, so a
    regression in the harness or the transaction tools it composes fails the normal build
    quickly, without paying for the whole matrix.

    Covered:
      * list-scenarios / list-faults expose the documented scenario and fault sets.
      * git: clean (publication), conflict (partial: one published, one quarantined) and
        policy (escalation halt) each reach their expected terminal outcome.
      * a fault injected after a critical transition converges to the SAME fingerprint as
        the uninterrupted run of that scenario (crash-recovery equivalence), and the fault
        actually fired.
      * jj: the clean scenario also publishes on jj (self-skipped, never failed, when the
        jj binary is absent - mirroring the rest of the suite's optional-binary skips).
      * usage errors (unknown scenario / unknown fault) are rejected (exit 2).

.EXAMPLE
    pwsh -File tests/test-harness.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$script:Tool = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\harness.ps1')).Path
$script:PsExe = ([System.Diagnostics.Process]::GetCurrentProcess()).MainModule.FileName
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Failures = [System.Collections.Generic.List[string]]::new()

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

function Assert-True { param([bool]$Cond, [string]$Msg) if (-not $Cond) { $script:Failures.Add("FAIL - $Msg") } }
function Assert-Equal { param($Expected, $Actual, [string]$Msg) if ($Expected -ne $Actual) { $script:Failures.Add("FAIL - ${Msg}: expected [$Expected], got [$Actual]") } }
function Assert-Exit { param($R, [int]$Code, [string]$Msg) if ($R.ExitCode -ne $Code) { $script:Failures.Add("FAIL - ${Msg}: expected exit $Code, got $($R.ExitCode) (err=[$($R.Err.Trim())])") } }
function Assert-Contains { param([string]$Haystack, [string]$Needle, [string]$Msg) if ($Haystack.IndexOf($Needle, [System.StringComparison]::Ordinal) -lt 0) { $script:Failures.Add("FAIL - ${Msg}: [$Needle] not found") } }

# Runs a scenario and returns the parsed JSON verdict (or $null with a recorded failure).
function Run-Scenario {
    param([string]$Vcs, [string]$Name, [string]$Fault = '')
    $a = @('scenario', '--vcs', $Vcs, '--name', $Name, '--json')
    if ($Fault) { $a += @('--fault', $Fault) }
    $r = Invoke-Harness $a
    if ($r.ExitCode -ne 0) {
        $script:Failures.Add("FAIL - scenario $Vcs/$Name$(if($Fault){"/$Fault"}) exited $($r.ExitCode): $($r.Err.Trim())")
        return $null
    }
    try { return ($r.Out.Trim() | ConvertFrom-Json) }
    catch { $script:Failures.Add("FAIL - scenario $Vcs/$Name produced unparseable JSON: $($r.Out)"); return $null }
}

Write-Host 'harness fast matrix: this spawns many child transaction-tool processes and takes ~1-2 min.'

# =============================================================================
# 1. Catalogue: list-scenarios / list-faults.
# =============================================================================
{
    $ls = Invoke-Harness @('list-scenarios')
    Assert-Exit $ls 0 'list-scenarios rc=0'
    foreach ($s in @('clean', 'deps', 'conflict', 'quarantine', 'policy', 'checks', 'publish', 'resume')) {
        Assert-Contains $ls.Out $s "list-scenarios includes '$s'"
    }
    $lf = Invoke-Harness @('list-faults')
    Assert-Exit $lf 0 'list-faults rc=0'
    foreach ($f in @('lease', 'capture', 'archive', 'to-review', 'integrate', 'publish')) {
        Assert-Contains $lf.Out $f "list-faults includes fault target '$f'"
    }
}.Invoke()

# =============================================================================
# 2. git: one scenario per terminal-outcome class reaches its expected outcome.
# =============================================================================
$hasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
if (-not $hasGit) {
    Write-Host 'SKIP - git is not installed; skipping the git scenarios.'
} else {
    $clean = Run-Scenario 'git' 'clean'
    if ($clean) {
        Assert-Equal 'published' $clean.outcome 'clean git -> published'
        Assert-True (-not [string]::IsNullOrEmpty($clean.fingerprint)) 'clean git yields a fingerprint'
        Assert-Contains $clean.archive 'T-101' 'clean git archived T-101'
        Assert-Contains $clean.archive 'T-102' 'clean git archived T-102'
    }

    $conflict = Run-Scenario 'git' 'conflict'
    if ($conflict) { Assert-Equal 'partial' $conflict.outcome 'conflict git -> partial (one published, one quarantined)' }

    $policy = Run-Scenario 'git' 'policy'
    if ($policy) { Assert-Equal 'escalated' $policy.outcome 'policy git -> escalated (safe halt)' }

    # ---- crash-recovery equivalence spot check (policy is the cheapest scenario) --------
    if ($policy) {
        $faulted = Run-Scenario 'git' 'policy' 'capture:before-rename'
        if ($faulted) {
            Assert-True ([bool]$faulted.fault_fired) 'the injected fault actually fired'
            Assert-Equal $policy.fingerprint $faulted.fingerprint 'faulted-then-recovered run converges to the SAME fingerprint as the clean run'
        }
    }
}

# =============================================================================
# 3. jj: the clean scenario publishes on jj too (self-skip when jj is absent).
# =============================================================================
$hasJj = [bool](Get-Command jj -ErrorAction SilentlyContinue)
if (-not $hasJj) {
    Write-Host 'SKIP - jj is not installed; skipping the jj scenario (optional-binary self-skip).'
} else {
    $cleanJj = Run-Scenario 'jj' 'clean'
    if ($cleanJj) {
        Assert-Equal 'published' $cleanJj.outcome 'clean jj -> published'
        Assert-Contains $cleanJj.archive 'T-101' 'clean jj archived T-101'
    }
}

# =============================================================================
# 4. Usage errors.
# =============================================================================
{
    $badS = Invoke-Harness @('scenario', '--vcs', 'git', '--name', 'nope')
    Assert-Exit $badS 2 'unknown scenario name -> exit 2'
    $badF = Invoke-Harness @('scenario', '--vcs', 'git', '--name', 'clean', '--fault', 'nope:then')
    Assert-Exit $badF 2 'unknown fault target -> exit 2'
    $badV = Invoke-Harness @('scenario', '--vcs', 'svn', '--name', 'clean')
    Assert-Exit $badV 2 'unknown vcs -> exit 2'
}.Invoke()

# =============================================================================
# Report
# =============================================================================
if ($script:Failures.Count -eq 0) {
    Write-Host 'OK - harness fast matrix passed.'
    exit 0
}
Write-Host "FAILED - $($script:Failures.Count) assertion(s):"
foreach ($f in $script:Failures) { Write-Host "  $f" }
exit 1
