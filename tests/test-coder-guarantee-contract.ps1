<# Contract regressions for prose guarantee verification in canonical/generated coders. #>
# ci:posix
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Failures = [System.Collections.Generic.List[string]]::new()

function Read-Text {
    param([string]$Relative)
    Get-Content -LiteralPath (Join-Path $Root $Relative) -Raw
}

function Assert-Contains {
    param([string]$Text, [string]$Needle, [string]$Message)
    $normalizedText = [regex]::Replace($Text, '\s+', ' ')
    $normalizedNeedle = [regex]::Replace($Needle, '\s+', ' ')
    if (-not $normalizedText.Contains($normalizedNeedle)) {
        $Failures.Add("FAIL - $Message (missing [$Needle])")
    }
}

function Get-Section {
    param([string]$Text, [string]$Start, [string]$End)
    $startIndex = $Text.IndexOf($Start, [StringComparison]::Ordinal)
    if ($startIndex -lt 0) { return '' }
    $endIndex = $Text.IndexOf($End, $startIndex + $Start.Length, [StringComparison]::Ordinal)
    if ($endIndex -lt 0) { return $Text.Substring($startIndex) }
    return $Text.Substring($startIndex, $endIndex - $startIndex)
}

function Assert-CoderModes {
    param([string]$Text, [string]$Label)
    $mode1 = Get-Section $Text '## Режим 1 — реализация задачи' '## Режим 2 — устранение находок'
    $mode2 = Get-Section $Text '## Режим 2 — устранение находок' '## Режим 3 — точечный фикс'
    foreach ($pair in @(
        @($mode1, 'implementation mode'),
        @($mode2, 'finding-fixing mode')
    )) {
        Assert-Contains $pair[0] 'нормативное правило' "$Label $($pair[1]) applies the prose rule"
        Assert-Contains $pair[0] '`docs/queue_contract.md`, §21' "$Label $($pair[1]) cites the normative source"
        Assert-Contains $pair[0] 'только к прозе, не к коду и тестам' "$Label $($pair[1]) keeps the rule prose-only"
    }
}

$contract = Read-Text 'docs/queue_contract.md'
Assert-Contains $contract '## 21. Нормативное правило проверяемости прозы о гарантиях' 'queue contract defines section 21'
Assert-Contains $contract 'базовой ревизии (`BASE`)' 'section 21 verifies claims against committed BASE code'
Assert-Contains $contract 'CHANGELOG и release notes описывают внешний delta' 'section 21 records release deltas from baseline'
Assert-Contains $contract '«достижимо через A или B»' 'section 21 checks A-or-B gating equivalence'
Assert-Contains $contract 'переиспользуй её' 'section 21 reuses honest existing formulations'

$coderTemplate = Read-Text 'agents/coder.template.md'
Assert-CoderModes $coderTemplate 'coder template'

foreach ($relative in @(
    'agents/coder.md',
    'agents/coder_fast.md',
    'agents/coder_deep.md'
)) {
    Assert-CoderModes (Read-Text $relative) $relative
}

$adapter = Read-Text 'agents/coder_codex.md'
$hardRules = Get-Section $adapter 'Hard rules (violation = failure):' '```'
foreach ($claim in @(
    'When adding or updating prose about guarantees, coverage, or conditions',
    'committed code of the baseline revision',
    'Record CHANGELOG/release-notes relative to baseline state',
    'Verify equivalence of any A-or-B gating conditions',
    'Reuse existing honest formulations',
    'claims about behavior after fixing are checked against post-fix code'
)) {
    Assert-Contains $hardRules $claim "coder_codex hard rules include [$claim]"
}

foreach ($relative in @(
    'codex/agents/orchestra_coder.toml',
    'codex/agents/orchestra_coder_fast.toml',
    'codex/agents/orchestra_coder_deep.toml'
)) {
    Assert-CoderModes (Read-Text $relative) $relative
}

if ($Failures.Count -gt 0) {
    Write-Host "FAILED - $($Failures.Count) assertion(s):"
    $Failures | ForEach-Object { Write-Host "  $_" }
    exit 1
}

Write-Host 'OK - prose guarantee verification is present in the normative source, both coder modes, the Codex adapter, and all generated coder roles.'
exit 0
