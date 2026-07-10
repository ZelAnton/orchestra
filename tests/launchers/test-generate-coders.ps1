<#
  Fixture tests for generate-coders.ps1 - the template-driven generator that produces
  agents/coder.md, coder_fast.md, coder_deep.md (from coder.template.md) and
  agents/reviewer.md, reviewer_std.md (from reviewer.template.md), task T-090.

  Side-effect-free: the generator + the two templates are copied into a throwaway tree
  and run there, so this repository's real agents/*.md are never rewritten. Because the
  generator is a single pwsh script, running this under pwsh on Windows and on Linux
  drives byte-for-byte the same generation, so its pass/fail result is the cross-platform
  equivalence proof for generation (analogous to test-sync-runtime.ps1 / test-doctor-runtime.ps1).

  Covered:
    - the five variants are produced, each UTF-8 without BOM, LF-only, with no leftover
      {{PLACEHOLDER}};
    - generation is deterministic/idempotent: a second run yields byte-identical output;
    - generation REPRODUCES the committed agents/*.md byte-for-byte (so the committed
      variants are exactly what the templates generate on this OS - the same guarantee the
      CI drift check enforces, proved here without mutating the working tree).

  Usage:
    pwsh -File tests/launchers/test-generate-coders.ps1
#>

# ci:posix - cross-platform; run-all.ps1 runs this under pwsh on Linux in CI too.
$ErrorActionPreference = 'Stop'

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:Failures = New-Object System.Collections.ArrayList

$script:Pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)
if (-not $script:Pwsh) {
    Write-Host 'SKIP - pwsh not found on PATH; the generator equivalence test requires PowerShell 7.'
    exit 0
}

$script:Variants = @('coder.md', 'coder_fast.md', 'coder_deep.md', 'reviewer.md', 'reviewer_std.md')

function Assert-True { param([bool]$Cond, [string]$Msg) if (-not $Cond) { [void]$script:Failures.Add("FAIL - $Msg") } }
function Get-Bytes { param([string]$Path) return [System.IO.File]::ReadAllBytes($Path) }
function Test-BytesEqual { param([byte[]]$A, [byte[]]$B) return [System.Linq.Enumerable]::SequenceEqual([byte[]]$A, [byte[]]$B) }

function New-GenTree {
    # A throwaway copy of the generator + its two source templates, laid out exactly as
    # generate-coders.ps1 expects (script at the root, templates under agents/).
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("orc-gen-test-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'agents') | Out-Null
    Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'generate-coders.ps1') -Destination (Join-Path $root 'generate-coders.ps1') -Force
    foreach ($tpl in @('coder.template.md', 'reviewer.template.md')) {
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot (Join-Path 'agents' $tpl)) -Destination (Join-Path $root (Join-Path 'agents' $tpl)) -Force
    }
    return $root
}

function Invoke-Generator {
    param([string]$Root)
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $p = Start-Process -FilePath $script:Pwsh.Source `
        -ArgumentList @('-NoProfile', '-File', (Join-Path $Root 'generate-coders.ps1')) `
        -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $err = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $outFile, $errFile -ErrorAction SilentlyContinue
    $exit = if ($null -ne $p -and $null -ne $p.ExitCode) { [int]$p.ExitCode } else { -1 }
    $errStr = if ($null -eq $err) { '' } else { [string]$err }
    return [pscustomobject]@{ ExitCode = $exit; Err = $errStr }
}

# =============================================================================
# 1) Generation succeeds and each variant is well-formed (no BOM, LF-only, no {{}})
# =============================================================================
$tree = New-GenTree
$g = Invoke-Generator -Root $tree
Assert-True ($g.ExitCode -eq 0) "generation exits 0 (got $($g.ExitCode); err=$($g.Err))"
foreach ($v in $script:Variants) {
    $path = Join-Path $tree (Join-Path 'agents' $v)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        [void]$script:Failures.Add("FAIL - $v was not generated")
        continue
    }
    $bytes = Get-Bytes $path
    Assert-True ($bytes.Length -ge 3 -and -not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) "$v is UTF-8 without BOM"
    Assert-True (-not ($bytes -contains 0x0D)) "$v has LF-only line endings (no CR)"
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    Assert-True (-not [regex]::IsMatch($text, '\{\{[A-Za-z_]+\}\}')) "$v has no leftover {{PLACEHOLDER}}"
}

# =============================================================================
# 2) Deterministic/idempotent: a second run yields byte-identical output
# =============================================================================
$first = @{}
foreach ($v in $script:Variants) { $first[$v] = Get-Bytes (Join-Path $tree (Join-Path 'agents' $v)) }
$g2 = Invoke-Generator -Root $tree
Assert-True ($g2.ExitCode -eq 0) 'second generation exits 0'
foreach ($v in $script:Variants) {
    $again = Get-Bytes (Join-Path $tree (Join-Path 'agents' $v))
    Assert-True (Test-BytesEqual $first[$v] $again) "$v is byte-identical on re-generation (deterministic)"
}

# =============================================================================
# 3) Generation reproduces the committed agents/*.md byte-for-byte
# =============================================================================
foreach ($v in $script:Variants) {
    $generated = Get-Bytes (Join-Path $tree (Join-Path 'agents' $v))
    $committed = Get-Bytes (Join-Path $script:RepoRoot (Join-Path 'agents' $v))
    Assert-True (Test-BytesEqual $generated $committed) "${v}: generated output equals the committed agents/$v (no drift)"
}

Remove-Item -LiteralPath $tree -Recurse -Force -ErrorAction SilentlyContinue

# =============================================================================
# Report
# =============================================================================
if ($script:Failures.Count -gt 0) {
    Write-Host "test-generate-coders: $($script:Failures.Count) failure(s):"
    foreach ($f in $script:Failures) { Write-Host "  $f" }
    exit 1
}
Write-Host 'OK - generate-coders.ps1 produces well-formed, deterministic output that reproduces the committed agent variants.'
exit 0
