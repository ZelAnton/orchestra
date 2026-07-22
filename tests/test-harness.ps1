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
      * git: diverge (T-098) - main moved out from under the batch after integration but before
        publish is auto-resolved by re-anchoring the integration onto the new tip and
        re-verifying, then published as a true fast-forward (no --force, no lost work), with a
        fault spot-check confirming the recovery still converges.
      * git: diverge-push (T-098/R-03) - over a real (filesystem, still offline) remote: the batch
        is ff-merged into the LOCAL main but the push is not confirmed and origin/main diverged.
        The recovery discriminator reads the un-pushed batch as an ancestor of the LOCAL main
        (the false positive the old Phase 0.4 used) but NOT of origin/main; recovery resets the
        local main to origin/main (never a force-push), re-anchors, re-verifies and re-pushes as a
        genuine ff with no lost work - with a ff->push-window fault spot-check confirming convergence.
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
    foreach ($s in @('clean', 'deps', 'conflict', 'quarantine', 'policy', 'checks', 'publish', 'resume',
            'diverge', 'diverge-push', 'ci-delayed', 'ci-rerun', 'ci-outage', 'approve', 'reject', 'approval-timeout', 'approval-stale', 'linear-publish')) {
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

    # ---- main diverged mid-batch (T-098): safe auto-resolution, not a manual halt -----------
    # main is moved out from under the batch after integration but before publish; processor
    # must re-anchor the integration onto the new tip, RE-VERIFY, and republish as a true ff -
    # never --force, never losing the moved-in commit or the batch's work (the scenario's own
    # internal assertions enforce the no-loss / genuine-ff invariants; a violation exits != 0).
    $diverge = Run-Scenario 'git' 'diverge'
    if ($diverge) {
        Assert-Equal 'published' $diverge.outcome 'diverge git -> published (main moved mid-batch; re-anchored + re-verified; published as a true ff)'
        Assert-Contains $diverge.archive 'T-101' 'diverge git archived T-101 after the safe auto-resolution'
        Assert-True (-not [string]::IsNullOrEmpty($diverge.fingerprint)) 'diverge git yields a fingerprint'
        # crash-recovery equivalence: a fault during the diverge scenario still converges.
        $divFaulted = Run-Scenario 'git' 'diverge' 'integrate:before-write'
        if ($divFaulted) {
            Assert-True ([bool]$divFaulted.fault_fired) 'diverge injected fault fired'
            Assert-Equal $diverge.fingerprint $divFaulted.fingerprint 'diverge faulted-then-recovered run converges to the SAME fingerprint as the clean run'
        }
    }

    # ---- remote push rejection + ff->push crash window (T-098/R-03) -------------------------------
    # A REAL (filesystem, still offline) remote: the batch is ff-merged into the LOCAL main but the
    # push is not confirmed, and origin/main has diverged. The scenario's own internal assertions
    # enforce the R-03 crux (a violation exits != 0): the recovery discriminator must read the
    # un-pushed batch as an ancestor of the LOCAL main (the false positive the old Phase 0.4 used)
    # but NOT of origin/main; recovery resets the local main to origin/main (never a force-push to
    # the remote), re-anchors, re-verifies and re-pushes as a genuine ff with no lost work.
    $divPush = Run-Scenario 'git' 'diverge-push'
    if ($divPush) {
        Assert-Equal 'published' $divPush.outcome 'diverge-push git -> published (push rejected on diverged origin; reset-to-origin + re-anchor + re-verify + re-push, no force, no loss)'
        Assert-Contains $divPush.archive 'T-101' 'diverge-push git archived T-101 only after the confirmed re-push'
        Assert-True (-not [string]::IsNullOrEmpty($divPush.fingerprint)) 'diverge-push git yields a fingerprint'
        # a fault in the ff->push crash window still converges to the clean run.
        $divPushFaulted = Run-Scenario 'git' 'diverge-push' 'publish:before-write'
        if ($divPushFaulted) {
            Assert-True ([bool]$divPushFaulted.fault_fired) 'diverge-push injected fault fired'
            Assert-Equal $divPush.fingerprint $divPushFaulted.fingerprint 'diverge-push faulted-then-recovered run converges to the SAME fingerprint as the clean run'
        }
    }

    # ---- opt-in linear-history publish (T-282): PUBLISH_LINEAR_HISTORY -------------------
    # merger still integrates with MERGE commits (the scenario asserts the reviewed tip is
    # non-linear); at publish the REAL tools/linearize.ps1 re-expresses it as a merge-free chain
    # with a BYTE-IDENTICAL tree, ff-published so the trunk carries the batch with NO merge commit
    # and no lost work (the scenario's own internal assertions enforce those invariants; a
    # violation exits != 0). Default-off is proven unchanged by the untouched clean/conflict/
    # quarantine scenarios above, which keep publishing the merge topology.
    $linear = Run-Scenario 'git' 'linear-publish'
    if ($linear) {
        Assert-Equal 'published' $linear.outcome 'linear-publish git -> published (merge topology linearized to a byte-identical merge-free trunk)'
        Assert-Contains $linear.archive 'T-101' 'linear-publish git archived T-101'
        Assert-Contains $linear.archive 'T-102' 'linear-publish git archived T-102'
        # crash-recovery equivalence: a fault during linear-publish still converges.
        $linFaulted = Run-Scenario 'git' 'linear-publish' 'integrate:before-write'
        if ($linFaulted) {
            Assert-True ([bool]$linFaulted.fault_fired) 'linear-publish injected fault fired'
            Assert-Equal $linear.fingerprint $linFaulted.fingerprint 'linear-publish faulted-then-recovered run converges to the SAME fingerprint as the clean run'
        }
    }

    # ---- crash-recovery equivalence spot check (policy is the cheapest scenario) --------
    if ($policy) {
        $faulted = Run-Scenario 'git' 'policy' 'capture:before-rename'
        if ($faulted) {
            Assert-True ([bool]$faulted.fault_fired) 'the injected fault actually fired'
            Assert-Equal $policy.fingerprint $faulted.fingerprint 'faulted-then-recovered run converges to the SAME fingerprint as the clean run'
        }
    }

    # ---- publish gate (T-095): CI gate + one-time approval scenarios --------------------
    $ciDelayed = Run-Scenario 'git' 'ci-delayed'
    if ($ciDelayed) {
        Assert-Equal 'published' $ciDelayed.outcome 'ci-delayed -> published (waited the whole required set, not the first green run)'
        Assert-Contains $ciDelayed.archive 'T-101' 'ci-delayed archived T-101 after the full CI set went green'
    }
    $ciRerun = Run-Scenario 'git' 'ci-rerun'
    if ($ciRerun) { Assert-Equal 'published' $ciRerun.outcome 'ci-rerun -> published (red check re-run to green)' }

    $ciOutage = Run-Scenario 'git' 'ci-outage'
    if ($ciOutage) {
        Assert-Equal 'ci-unconfirmed' $ciOutage.outcome 'ci-outage -> ci-unconfirmed (fail-closed at the deadline)'
        # fail-closed: the task is NOT archived while required CI is unconfirmed.
        Assert-True ($ciOutage.archive -notmatch 'done:T-101') 'ci-outage: task NOT archived as done while CI is unconfirmed'
        Assert-Contains $ciOutage.archive 'T-101=опубликована' 'ci-outage: task held at published (recovery artifacts kept), not выполнена'
    }

    $approve = Run-Scenario 'git' 'approve'
    if ($approve) {
        Assert-Equal 'published' $approve.outcome 'approve -> published (one-time approval granted)'
        Assert-Contains $approve.archive 'T-101' 'approve archived T-101 after the operator approved'
    }
    $reject = Run-Scenario 'git' 'reject'
    if ($reject) { Assert-Equal 'escalated' $reject.outcome 'reject -> escalated (not published)' }
    $aTimeout = Run-Scenario 'git' 'approval-timeout'
    if ($aTimeout) { Assert-Equal 'escalated' $aTimeout.outcome 'approval-timeout -> escalated (no answer by deadline = fail-closed)' }
    $aStale = Run-Scenario 'git' 'approval-stale'
    if ($aStale) { Assert-Equal 'escalated' $aStale.outcome 'approval-stale -> escalated (decision expired after code change)' }

    # a fault injected into a new scenario also converges to the clean fingerprint.
    if ($ciDelayed) {
        $ciFaulted = Run-Scenario 'git' 'ci-delayed' 'to-review:before-write'
        if ($ciFaulted) {
            Assert-True ([bool]$ciFaulted.fault_fired) 'ci-delayed injected fault fired'
            Assert-Equal $ciDelayed.fingerprint $ciFaulted.fingerprint 'ci-delayed faulted run converges to the clean fingerprint'
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
    # T-282: linear-history publish also works on jj (the runner drives the jj workspace directly).
    $linearJj = Run-Scenario 'jj' 'linear-publish'
    if ($linearJj) {
        Assert-Equal 'published' $linearJj.outcome 'linear-publish jj -> published (byte-identical merge-free trunk)'
        Assert-Contains $linearJj.archive 'T-101' 'linear-publish jj archived T-101'
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
