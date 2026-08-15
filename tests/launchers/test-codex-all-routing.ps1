# ci:posix
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$failures = [System.Collections.Generic.List[string]]::new()

function Read-RepoText {
    param([Parameter(Mandatory)][string]$RelativePath)
    return Get-Content -LiteralPath (Join-Path $root $RelativePath) -Raw -Encoding utf8
}

function Assert-Contains {
    param([string]$Text, [string]$Needle, [string]$Name)
    if (-not $Text.Contains($Needle)) { $script:failures.Add("$Name - missing: $Needle") }
}

function Assert-NotContains {
    param([string]$Text, [string]$Needle, [string]$Name)
    if ($Text.Contains($Needle)) { $script:failures.Add("$Name - forbidden: $Needle") }
}

# Prose and PowerShell tables wrap across lines, so phrase-level assertions match a
# pattern whose runs of whitespace are flexible instead of a fixed literal.
function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Name)
    if (-not [regex]::IsMatch($Text, $Pattern)) { $script:failures.Add("$Name - no match: $Pattern") }
}

$processor = Read-RepoText 'agents\processor.md'
$generatedProcessor = Read-RepoText 'codex\processor.md'
$coder = Read-RepoText 'agents\coder_codex.md'
$reviewer = Read-RepoText 'agents\reviewer_codex.md'
$schema = Read-RepoText 'tools\policy-schema.ps1'

foreach ($text in @($processor, $generatedProcessor)) {
    Assert-Contains $text '`CODEX_CODER=all` → `coder_codex` для любого `L`' 'processor routes every coder level for all'
    Assert-Contains $text '`CODEX_REVIEWER=all` → `reviewer_codex` (`full`) для любого `L`' 'processor routes every reviewer level for all'
    Assert-Contains $text '`gpt-5.6-sol` с `xhigh`' 'processor pins deep model and reasoning'
}

Assert-Contains $coder '`EFFMODEL=gpt-5.6-sol` и `EFF=xhigh`' 'coder pins deep effective settings'
Assert-Contains $coder '${EFFMODEL:+--model "$EFFMODEL"}' 'coder runtime uses effective model'
Assert-NotContains $coder '${CODEX_MODEL:+--model "$CODEX_MODEL"}' 'coder runtime must not bypass deep override'

Assert-Contains $reviewer '`EFFMODEL=gpt-5.6-sol` и `EFF=xhigh`' 'reviewer pins deep effective settings'
Assert-Contains $reviewer '${EFFMODEL:+--model "$EFFMODEL"}' 'reviewer runtime uses effective model'
Assert-NotContains $reviewer '${CODEX_MODEL:+--model "$CODEX_MODEL"}' 'reviewer runtime must not bypass deep override'
Assert-Contains $reviewer 'отдельным новым `codex exec`/checker-' 'reviewer all uses a fresh checker invocation'

# The deep pin is the DEFAULT model, not a hard block: an explicit per-role deep key wins
# over gpt-5.6-sol, while xhigh reasoning stays pinned and the general CODEX_MODEL still
# never reaches the deep branch.
Assert-Contains $coder '`EFFMODEL=CODEX_CODER_DEEP_MODEL`' 'coder deep model key overrides the pin'
Assert-Contains $coder '`EFFMODEL=CODEX_CODER_MODEL`' 'coder non-deep model key precedes CODEX_MODEL'
Assert-Contains $reviewer '`EFFMODEL=CODEX_REVIEWER_DEEP_MODEL`' 'reviewer deep model key overrides the pin'
Assert-Contains $reviewer '`EFFMODEL=CODEX_REVIEWER_MODEL`' 'reviewer non-deep model key precedes CODEX_MODEL'
foreach ($text in @($coder, $reviewer)) {
    Assert-Match $text 'Общий\s+`CODEX_MODEL`\s+в эту ветку не течёт' `
        'adapter still states the general CODEX_MODEL does not reach the deep branch'
    Assert-Contains $text '`EFF=xhigh`' 'adapter keeps xhigh pinned for deep'
}

Assert-Contains $schema "@('off', 'fast', 'fast+std', 'all')" 'schema accepts CODEX_CODER all'
Assert-Contains $schema "@('off', 'fast', 'fast+std', 'deep', 'all')" 'schema accepts CODEX_REVIEWER all'
foreach ($key in @('CODEX_CODER_MODEL', 'CODEX_CODER_DEEP_MODEL', 'CODEX_REVIEWER_MODEL', 'CODEX_REVIEWER_DEEP_MODEL')) {
    Assert-Contains $schema ("'" + $key + "'") "schema declares $key"
}
Assert-Match $schema "'CODEX_CODER_DEEP_MODEL'\s+'string'\s+'gpt-5\.6-sol'" 'schema documents the deep default model'
Assert-Match $schema "'CODEX_REVIEWER_DEEP_MODEL'\s+'string'\s+'gpt-5\.6-sol'" 'schema documents the deep default review model'

if ($failures.Count -gt 0) {
    Write-Host "test-codex-all-routing: $($failures.Count) failure(s):"
    foreach ($failure in $failures) { Write-Host "  $failure" }
    exit 1
}

Write-Host 'OK - all-level Codex routing and deep gpt-5.6-sol/xhigh overrides are pinned.'
exit 0
