<# Contract regressions for exact-SHA evidence reuse in canonical/generated roles. #>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Failures = [System.Collections.Generic.List[string]]::new()
function Read-Text { param([string]$Relative) Get-Content -LiteralPath (Join-Path $Root $Relative) -Raw }
function Assert-Contains {
    param([string]$Text, [string]$Needle, [string]$Message)
    if (-not $Text.Contains($Needle)) { $Failures.Add("FAIL - $Message (missing [$Needle])") }
}
function Assert-NotContains {
    param([string]$Text, [string]$Needle, [string]$Message)
    if ($Text.Contains($Needle)) { $Failures.Add("FAIL - $Message (unexpected [$Needle])") }
}

$processor = Read-Text 'agents/processor.md'
$reviewerTemplate = Read-Text 'agents/reviewer.template.md'
$reviewer = Read-Text 'agents/reviewer.md'
$reviewerStd = Read-Text 'agents/reviewer_std.md'
$fullReviewer = Read-Text 'agents/full_reviewer.md'
$codexProcessor = Read-Text 'codex/processor.md'
$codexReviewer = Read-Text 'codex/agents/orchestra_reviewer.toml'
$codexReviewerStd = Read-Text 'codex/agents/orchestra_reviewer_std.toml'
$codexFullReviewer = Read-Text 'codex/agents/orchestra_full_reviewer.toml'
$supervisor = Read-Text 'tools/supervisor.ps1'
$verification = Read-Text 'tools/verification.ps1'

foreach ($pair in @(
    @($processor, 'processor'),
    @($reviewerTemplate, 'reviewer template'),
    @($fullReviewer, 'full reviewer')
)) {
    Assert-Contains $pair[0] '--require-pass' "$($pair[1]) uses the single mechanical reusable-evidence gate"
    Assert-Contains $pair[0] 'survivors=0' "$($pair[1]) requires terminal cleanup"
    Assert-Contains $pair[0] 'publish-CI' "$($pair[1]) keeps local evidence separate from publish CI"
    Assert-Contains $pair[0] '<result-file>.run.lock' "$($pair[1]) addresses one in-flight logical verification"
    Assert-Contains $pair[0] 'Внешний timeout оболочки не является terminal outcome supervisor' "$($pair[1]) does not confuse wrapper timeout with supervisor completion"
    Assert-Contains $pair[0] 'минимум на 120 секунд' "$($pair[1]) keeps the outer wait beyond the computed completion bound"
}

Assert-Contains $processor 'REVIEW_FINAL_CLEAN_PASSES=<2 для strict, иначе 1>' 'processor dispatches strict final-clean count'
Assert-Contains $processor 'последние два' 'processor preserves two final substantive clean passes'
Assert-Contains $reviewerTemplate 'два независимых' 'task reviewer repeats independent analysis after fixes'
Assert-Contains $reviewerTemplate 'Новая находка, сигнал риска' 'task reviewer invalidates reuse on risk/finding'
Assert-Contains $reviewerTemplate '--revision task/<T-ID>' 'task reviewer seals exact task bookmark instead of workspace @'
Assert-Contains $fullReviewer 'Reuse не заменяет содержательный анализ' 'integration reviewer never treats evidence as analysis'
Assert-Contains $fullReviewer 'exempt' 'integration reviewer rejects exempt evidence for reuse'
Assert-Contains $fullReviewer '--revision integration/<B-id>' 'integration reviewer seals exact integration bookmark'
Assert-Contains $processor '--revision integration/<B-id>' 'processor checks the sealed integration bookmark'
Assert-Contains $processor 'второй проход не' 'processor forbids an identical focused rerun on the second clean analysis pass'
Assert-Contains $reviewerTemplate 'Второй последовательный чистый проход на неизменном' 'task reviewer separates the second clean analysis from command repetition'
Assert-Contains $fullReviewer 'Второй последовательный чистый проход на неизменном' 'integration reviewer separates the second clean analysis from command repetition'
Assert-Contains $supervisor 'Acquire-ResultFileRunLock' 'supervisor serializes calls by their stable result path'
Assert-Contains $verification 'Acquire-Lock -LockPath $runLock' 'verification runner serializes whole-profile runs by evidence path'

foreach ($generated in @(
    @($reviewer, 'generated reviewer'),
    @($reviewerStd, 'generated reviewer_std'),
    @($codexProcessor, 'generated Codex processor'),
    @($codexReviewer, 'generated Codex reviewer'),
    @($codexReviewerStd, 'generated Codex reviewer_std'),
    @($codexFullReviewer, 'generated Codex full reviewer')
)) {
    Assert-Contains $generated[0] '--require-pass' "$($generated[1]) includes exact-SHA evidence contract"
    Assert-Contains $generated[0] 'publish-CI' "$($generated[1]) preserves full publish CI"
    Assert-Contains $generated[0] '--revision' "$($generated[1]) includes sealed revision contract"
    Assert-Contains $generated[0] '<result-file>.run.lock' "$($generated[1]) preserves in-flight duplicate prevention"
    Assert-Contains $generated[0] 'Внешний timeout оболочки не является terminal outcome supervisor' "$($generated[1]) preserves terminal-outcome semantics"
    Assert-Contains $generated[0] 'минимум на 120 секунд' "$($generated[1]) preserves the outer wait margin"
}

Assert-NotContains $reviewerTemplate 'reuse evidence считается содержательным проходом' 'reviewer template has no analysis-reuse shortcut'
Assert-NotContains $fullReviewer 'reuse evidence считается содержательным проходом' 'full reviewer has no analysis-reuse shortcut'

if ($Failures.Count -gt 0) {
    Write-Host "FAILED - $($Failures.Count) assertion(s):"
    $Failures | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Write-Host 'OK - canonical and generated roles reuse only exact terminal-green evidence without weakening review or publish CI.'
exit 0
