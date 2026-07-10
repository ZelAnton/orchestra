<#
.SYNOPSIS
    Regression tests (T-074) for the reviewer_codex "clean pass" / SUMMARY-R gate
    contract described in agents/reviewer_codex.md ("Критерий «чистого прогона»",
    "Число прогонов", "Гейт `SUMMARY-R`").

.DESCRIPTION
    agents/reviewer_codex.md is a hand-written prose prompt for an LLM agent, not
    executable code - there is no real parser to unit-test directly. What this
    script does instead is provide a small, self-contained REFERENCE
    IMPLEMENTATION of the pass-evaluation algorithm the spec mandates (a "clean
    pass" requires RC=0 AND a fully-parsed, non-contradictory RECHECK section AND
    a fully-parsed, non-contradictory NEW section; only clean passes count toward
    REVIEW_MIN_PASSES or feed SUMMARY-R), and exercises it against fake/fixture
    codex output covering the five scenarios required by T-074's acceptance
    criteria:
      1. Partial success no longer counted: a pass with a missing or duplicated
         RECHECK line must NOT be treated as clean (this was the pre-T-074 bug).
      2. A second required pass fails (ordinary/content failure) after a first
         one succeeded: the failure must not be counted as clean, but must not
         immediately escalate either (it is within the ordinary-failure retry
         budget).
      3. A missing RECHECK on one pass does not silently corrupt the whole
         cycle: the invalid pass is discarded (not counted, not applied), and a
         later clean retry still lets the cycle reach its required clean-pass
         count.
      4. A single output mixing `NEW: none` and one or more `NEW | ...` lines is
         a contradictory, invalid NEW section - the pass must not be treated as
         clean.
      5. A fully clean sequence (every required pass clean, last pass
         `NEW: none`, RECHECK fully answered) reaches SUMMARY-R.

    This mirrors tools/check-codex-sandbox-guard.ps1's approach of encoding a
    prose contract as an executable check, but here the "contract" is a
    decision procedure over pass sequences rather than a set of regexes over
    the spec text itself. If agents/reviewer_codex.md's algorithm changes, this
    file's reference implementation must be updated to match by hand (same
    caveat the spec file states for reviewer.md/reviewer_std.md sync).

.EXAMPLE
    pwsh -File tests/test-reviewer-codex-gate.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Reference implementation of the "clean pass" contract --------------------

# Validates the RECHECK section of one pass's output lines against the set of
# R-IDs that were actually requested (see agents/reviewer_codex.md, "Критерий
# «чистого прогона»"). Returns $true/$false.
function Test-RecheckSectionValid {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Lines,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $RequestedIds
    )
    if ($RequestedIds.Count -eq 0) {
        # No RECHECK was requested this cycle (first review with nothing to
        # re-check, or augment mode) - section is automatically valid ("N/A").
        return $true
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($line in $Lines) {
        if ($line -match '^RECHECK\s+(\S+):\s+(resolved|reopen\s+—\s+.+)$') {
            $id = $Matches[1]
            if ($RequestedIds -notcontains $id) { return $false }   # unknown/unrequested ID
            if (-not $seen.Add($id)) { return $false }              # duplicate line for same ID
        }
        elseif ($line -match '^RECHECK\b') {
            # Starts with RECHECK but does not match the full format
            # (truncated / malformed status) - the whole section is unreliable.
            return $false
        }
    }
    foreach ($id in $RequestedIds) {
        if (-not $seen.Contains($id)) { return $false }             # missing/skipped ID
    }
    return $true
}

# Validates the NEW section of one pass's output lines. Returns $true/$false.
function Test-NewSectionValid {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Lines)
    $hasNone = $false
    $hasItem = $false
    foreach ($line in $Lines) {
        if ($line -eq 'NEW: none') {
            $hasNone = $true
        }
        elseif ($line -match '^NEW\s*\|') {
            $parts = $line -split '\|'
            # Exactly 5 pipe-delimited fields: "NEW", file:line, title, why, fix.
            $nonEmptyTail = @($parts[1..4] | Where-Object { $_.Trim() -ne '' })
            if ($parts.Count -eq 5 -and $nonEmptyTail.Count -eq 4) {
                $hasItem = $true
            }
            else {
                return $false   # truncated / malformed NEW line
            }
        }
    }
    if ($hasNone -and $hasItem) { return $false }        # mixed/contradictory output
    if (-not $hasNone -and -not $hasItem) { return $false }  # neither present - not parsed at all
    return $true
}

# A "clean pass" = RC=0 AND both sections valid.
function Test-CleanPass {
    param(
        [Parameter(Mandatory)] [int] $RC,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Lines,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $RequestedIds
    )
    if ($RC -ne 0) { return $false }
    return (Test-RecheckSectionValid -Lines $Lines -RequestedIds $RequestedIds) -and
    (Test-NewSectionValid -Lines $Lines)
}

# Simulates one review cycle: a sequence of passes (each @{ RC; Lines; EnvLimit }),
# applying the counting/retry/escalation rules from "Число прогонов" and "Вызов
# codex" (ordinary-failure retry budget: at most 2 retries per required pass,
# i.e. 3 attempts total, before CODEX_FAILED - retry limit exceeded; any
# EnvLimit=$true pass escalates immediately with no retry at all).
#
# $OpenRecordsRemaining models condition (б) of the SUMMARY-R gate (whether any
# other open R- record exists in review.md, independent of this pass sequence);
# fixtures below default it to 0 (nothing else open) since this suite is about
# the pass-counting/RECHECK-completeness logic, not review.md bookkeeping.
function Invoke-ReviewCycleSimulation {
    param(
        [Parameter(Mandatory)] [array] $Passes,
        [string[]] $RequestedIds = @(),
        [int] $MinPasses = 2,
        [int] $RetryLimit = 2,
        [int] $OpenRecordsRemaining = 0
    )
    $cleanCount = 0
    $lastCleanLines = $null
    $consecutiveOrdinaryFailures = 0

    foreach ($p in $Passes) {
        if ($p.EnvLimit) {
            return [pscustomobject]@{
                Escalated     = $true
                Reason        = 'ENV_LIMIT'
                CleanCount    = $cleanCount
                SummaryIssued = $false
            }
        }
        $clean = Test-CleanPass -RC $p.RC -Lines $p.Lines -RequestedIds $RequestedIds
        if ($clean) {
            $cleanCount++
            $lastCleanLines = $p.Lines
            $consecutiveOrdinaryFailures = 0
        }
        else {
            $consecutiveOrdinaryFailures++
            if ($consecutiveOrdinaryFailures -gt $RetryLimit) {
                return [pscustomobject]@{
                    Escalated     = $true
                    Reason        = 'RETRY_LIMIT_EXCEEDED'
                    CleanCount    = $cleanCount
                    SummaryIssued = $false
                }
            }
        }
    }

    $summaryIssued = $false
    if ($cleanCount -ge $MinPasses -and $null -ne $lastCleanLines -and $OpenRecordsRemaining -eq 0) {
        if ($lastCleanLines -contains 'NEW: none') {
            $summaryIssued = $true
        }
    }
    return [pscustomobject]@{
        Escalated     = $false
        Reason        = $null
        CleanCount    = $cleanCount
        SummaryIssued = $summaryIssued
    }
}

# --- Tiny local assertion helpers (self-contained; no shared harness needed) --

$script:failures = [System.Collections.Generic.List[string]]::new()
function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { $script:failures.Add($Message) }
}
function Assert-Equal {
    param($Expected, $Actual, [string] $Message)
    if ($Expected -ne $Actual) {
        $script:failures.Add("${Message}: expected [$Expected], got [$Actual]")
    }
}

# --- Scenario 1: partial success (RECHECK skipped or duplicated) not counted --

$scenario1Missing = @('RECHECK R-01: resolved', 'NEW: none')  # R-02 never answered
Assert-True (-not (Test-CleanPass -RC 0 -Lines $scenario1Missing -RequestedIds @('R-01', 'R-02'))) `
    'Scenario 1a: pass with a missing RECHECK id must not be clean'

$scenario1Duplicate = @('RECHECK R-01: resolved', 'RECHECK R-01: reopen — regression found', 'NEW: none')
Assert-True (-not (Test-CleanPass -RC 0 -Lines $scenario1Duplicate -RequestedIds @('R-01'))) `
    'Scenario 1b: pass with a duplicated RECHECK id must not be clean'

$cycle1 = Invoke-ReviewCycleSimulation -Passes @(@{ RC = 0; Lines = $scenario1Missing; EnvLimit = $false }) `
    -RequestedIds @('R-01', 'R-02') -MinPasses 1
Assert-Equal 0 $cycle1.CleanCount 'Scenario 1: incomplete-RECHECK pass must not increment the clean-pass counter'
Assert-Equal $false $cycle1.SummaryIssued 'Scenario 1: SUMMARY-R must not be issued off an incomplete-RECHECK pass'

# --- Scenario 2: second required pass fails (ordinary) after the first passed -

$pass1Clean = @('NEW: none')
$pass2Garbled = @('sorry, something went wrong mid-response')  # RC=0 but unparseable - ordinary failure
$cycle2 = Invoke-ReviewCycleSimulation -Passes @(
    @{ RC = 0; Lines = $pass1Clean; EnvLimit = $false },
    @{ RC = 0; Lines = $pass2Garbled; EnvLimit = $false }
) -RequestedIds @() -MinPasses 2
Assert-Equal 1 $cycle2.CleanCount 'Scenario 2: only the first (clean) pass should count'
Assert-Equal $false $cycle2.Escalated 'Scenario 2: a single ordinary failure must stay within the retry budget (no escalation yet)'
Assert-Equal $false $cycle2.SummaryIssued 'Scenario 2: SUMMARY-R must not be issued before REVIEW_MIN_PASSES clean passes are reached'

# --- Scenario 3: a missing RECHECK on one pass is discarded, cycle recovers ---

$pass1MissingRecheck = @('RECHECK R-01: resolved', 'NEW: none')  # R-02 missing
$pass2FullyValid = @('RECHECK R-01: resolved', 'RECHECK R-02: resolved', 'NEW: none')
$cycle3 = Invoke-ReviewCycleSimulation -Passes @(
    @{ RC = 0; Lines = $pass1MissingRecheck; EnvLimit = $false },
    @{ RC = 0; Lines = $pass2FullyValid; EnvLimit = $false }
) -RequestedIds @('R-01', 'R-02') -MinPasses 1
Assert-Equal 1 $cycle3.CleanCount 'Scenario 3: the invalid first pass must not count, only the valid retry does'
Assert-Equal $false $cycle3.Escalated 'Scenario 3: one missing-RECHECK pass followed by a valid retry must not escalate'
Assert-Equal $true $cycle3.SummaryIssued 'Scenario 3: cycle must reach SUMMARY-R once a fully valid pass is obtained'

# --- Scenario 4: mixed NEW / NEW:none in one output is invalid ----------------

$scenarioMixed = @(
    'NEW | src/foo.py:42 | off-by-one in loop bound | drops last element | fix bound to <=',
    'NEW: none'
)
Assert-True (-not (Test-NewSectionValid -Lines $scenarioMixed)) `
    'Scenario 4: a NEW section with both NEW: none and a NEW | ... line must be invalid'
Assert-True (-not (Test-CleanPass -RC 0 -Lines $scenarioMixed -RequestedIds @())) `
    'Scenario 4: a pass with a contradictory mixed NEW section must not be clean'

$cycle4 = Invoke-ReviewCycleSimulation -Passes @(@{ RC = 0; Lines = $scenarioMixed; EnvLimit = $false }) `
    -RequestedIds @() -MinPasses 1
Assert-Equal 0 $cycle4.CleanCount 'Scenario 4: the contradictory pass must not count as clean'
Assert-Equal $false $cycle4.SummaryIssued 'Scenario 4: SUMMARY-R must not be issued off a contradictory NEW section'

# --- Scenario 5: fully clean result reaches SUMMARY-R -------------------------

$pass1 = @('RECHECK R-01: resolved', 'NEW | src/bar.py:10 | missing null check | can crash on None | add guard')
$pass2 = @('RECHECK R-01: resolved', 'NEW: none')
$cycle5 = Invoke-ReviewCycleSimulation -Passes @(
    @{ RC = 0; Lines = $pass1; EnvLimit = $false },
    @{ RC = 0; Lines = $pass2; EnvLimit = $false }
) -RequestedIds @('R-01') -MinPasses 2
Assert-Equal 2 $cycle5.CleanCount 'Scenario 5: both fully-formed passes must count as clean'
Assert-Equal $false $cycle5.Escalated 'Scenario 5: a fully clean sequence must never escalate'
Assert-Equal $true $cycle5.SummaryIssued 'Scenario 5: SUMMARY-R must be issued once REVIEW_MIN_PASSES clean passes are reached and the last one is NEW: none'

# --- Bonus: environmental failure escalates immediately, no retry budget used -

$cycleEnv = Invoke-ReviewCycleSimulation -Passes @(
    @{ RC = 0; Lines = @('NEW: none'); EnvLimit = $false },
    @{ RC = 1; Lines = @(); EnvLimit = $true }
) -RequestedIds @() -MinPasses 2
Assert-Equal $true $cycleEnv.Escalated 'Bonus: an ENV_LIMIT pass must escalate immediately'
Assert-Equal 'ENV_LIMIT' $cycleEnv.Reason 'Bonus: ENV_LIMIT escalation reason must be reported as such'

# --- Bonus: ordinary-failure retry budget is enforced (not unbounded) ---------

$cycleRetryLimit = Invoke-ReviewCycleSimulation -Passes @(
    @{ RC = 1; Lines = @(); EnvLimit = $false },
    @{ RC = 1; Lines = @(); EnvLimit = $false },
    @{ RC = 1; Lines = @(); EnvLimit = $false },
    @{ RC = 1; Lines = @(); EnvLimit = $false }
) -RequestedIds @() -MinPasses 1 -RetryLimit 2
Assert-Equal $true $cycleRetryLimit.Escalated 'Bonus: exceeding the ordinary-failure retry budget must escalate (CODEX_FAILED - retry limit exceeded)'
Assert-Equal 'RETRY_LIMIT_EXCEEDED' $cycleRetryLimit.Reason 'Bonus: retry-limit escalation reason must be reported as such'

# --- Report --------------------------------------------------------------------

if ($script:failures.Count -eq 0) {
    Write-Host 'OK - reviewer_codex clean-pass / SUMMARY-R gate reference model holds for all fixture scenarios.'
    exit 0
}

Write-Host "Found $($script:failures.Count) failing assertion(s):`n"
foreach ($f in $script:failures) {
    Write-Host "FAIL - $f"
}
exit 1
