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

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $Failures.Add("FAIL - $Message")
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
foreach ($marker in @(
    'scope_paths',
    'по запятым',
    'каждый компонент',
    'path intersection',
    'широкими',
    'Ограничение радиуса',
    'committed `BASE`',
    'live worktree',
    'При `KB=off` или отсутствии каталога — пропусти')) {
    Assert-Contains $adapter $marker "coder_codex anchored KB contract includes [$marker]"
}

# Hermetic reference fixture for the shared normalization rule. This deliberately
# exercises anchored components, comma-separated paths, and an unanchored glob scope.
function Normalize-ScopeFixture {
    param([Parameter(Mandatory)][string]$Scope)
    $components = @($Scope -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $paths = @(
        foreach ($component in $components) {
            $separator = $component.IndexOf('::', [System.StringComparison]::Ordinal)
            if ($separator -gt 0) {
                $suffix = $component.Substring($separator + 2)
                if ($suffix.StartsWith('heading:', [System.StringComparison]::OrdinalIgnoreCase) -or
                    $suffix -match '^[A-Za-z_][A-Za-z0-9_.-]*$') {
                    $component.Substring(0, $separator)
                    continue
                }
            }
            $component
        }
    )
    [pscustomobject]@{
        Paths = $paths
        Broad = ($components.Count -gt 1 -or (@($paths | Where-Object { $_ -match '[*?\[\]]' }).Count -gt 0))
    }
}
 $singleAnchor = Normalize-ScopeFixture 'agents/planner.md::Invoke-Plan'
Assert-True (@($singleAnchor.Paths).Count -eq 1 -and $singleAnchor.Paths[0] -eq 'agents/planner.md' -and -not $singleAnchor.Broad) `
    'scope_file fixture strips a symbol anchor before path intersection'
 $headingAnchor = Normalize-ScopeFixture 'docs/guide.md::heading:Safety'
Assert-True (@($headingAnchor.Paths).Count -eq 1 -and $headingAnchor.Paths[0] -eq 'docs/guide.md' -and -not $headingAnchor.Broad) `
    'scope_file fixture strips a heading anchor before path intersection'
 $multiPath = Normalize-ScopeFixture 'agents/planner.md, agents/thinker.md'
Assert-True (@($multiPath.Paths).Count -eq 2 -and $multiPath.Paths[0] -eq 'agents/planner.md' -and
    $multiPath.Paths[1] -eq 'agents/thinker.md' -and $multiPath.Broad) `
    'scope_paths fixture preserves trimmed comma-separated components and broadness'
 $multiGlob = Normalize-ScopeFixture 'agents/*.md, codex/**'
Assert-True (@($multiGlob.Paths).Count -eq 2 -and $multiGlob.Paths[0] -eq 'agents/*.md' -and
    $multiGlob.Paths[1] -eq 'codex/**' -and $multiGlob.Broad) `
    'scope_paths fixture keeps multi-path/glob scopes relevant but broad'
Assert-True ((Normalize-ScopeFixture 'agents/*.md').Broad) `
    'scope_file fixture preserves a broad unanchored scope'

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
