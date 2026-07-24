# ci:posix
<# Hermetic cross-platform coverage for generate-codex-agents.ps1. #>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$failures = New-Object System.Collections.ArrayList
$utf8 = New-Object System.Text.UTF8Encoding($false)
$onWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
$sourceGenerator = (Resolve-Path (Join-Path $PSScriptRoot '..\..\generate-codex-agents.ps1')).Path
$root = Join-Path ([System.IO.Path]::GetTempPath()) ('orc-codex-gen-' + [Guid]::NewGuid().ToString('N'))

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { [void]$failures.Add("FAIL - $Message") } }
function Get-Sha256 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($Path))) }
    finally { $sha.Dispose() }
}
function Write-Agent {
    param([string]$Name, [string]$Description = 'fixture role')
    $text = "---`nname: $Name`ndescription: $Description`nmodel: sonnet`ntools: Read, Bash`npermissionMode: auto`n---`n`n# Role $Name`n`nBODY-$Name`n"
    [System.IO.File]::WriteAllText((Join-Path $root "agents\$Name.md"), $text, $utf8)
}

try {
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'agents') | Out-Null
    Copy-Item -LiteralPath $sourceGenerator -Destination (Join-Path $root 'generate-codex-agents.ps1')
    foreach ($role in @('planner','executor','coder_fast','coder','coder_deep','reviewer_std','reviewer','full_reviewer','merger','knowledge_curator','inbox_curator','processor')) {
        Write-Agent -Name $role
    }

    & pwsh -NoProfile -File (Join-Path $root 'generate-codex-agents.ps1') *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'generator exits 0'
    $generated = @(Get-ChildItem -LiteralPath (Join-Path $root 'codex\agents') -Filter 'orchestra_*.toml' -File)
    Assert-True ($generated.Count -eq 11) "exactly 11 leaf custom agents generated (got $($generated.Count))"
    $coder = Join-Path $root 'codex\agents\orchestra_coder.toml'
    $coderText = [System.IO.File]::ReadAllText($coder)
    Assert-True ($coderText.Contains('name = "orchestra_coder"')) 'generated TOML carries namespaced role name'
    Assert-True ($coderText.Contains('model_reasoning_effort = "high"')) 'generated coder carries configured reasoning tier'
    Assert-True ($coderText.Contains('BODY-coder')) 'generated TOML embeds canonical role body'
    Assert-True ($coderText.Contains('Never invoke `claude`')) 'generated leaf carries no-Claude provider overlay'
    $bytes = [System.IO.File]::ReadAllBytes($coder)
    Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'generated TOML is UTF-8 without BOM'

    $processor = Join-Path $root 'codex\processor.md'
    $processorText = [System.IO.File]::ReadAllText($processor)
    Assert-True ($processorText.Contains('orchestra_full_reviewer')) 'processor overlay carries complete role mapping'
    Assert-True ($processorText.Contains('orchestra_inbox_curator')) 'processor overlay maps the inbox curator role'
    Assert-True ($processorText.Contains('BODY-processor')) 'processor prompt embeds canonical processor body'
    Assert-True ($processorText.Contains('without falling back to Claude')) 'processor overlay forbids provider fallback'

    $hashBefore = Get-Sha256 $coder
    $staleRole = Join-Path $root 'codex\agents\orchestra_removed_role.toml'
    [System.IO.File]::WriteAllText($staleRole, "name = 'orchestra_removed_role'`n", $utf8)
    $caseStaleRole = Join-Path $root 'codex\agents\ORCHESTRA_CODER.toml'
    if (-not $onWindows) { [System.IO.File]::WriteAllText($caseStaleRole, "name = 'orchestra_coder'`n", $utf8) }
    & pwsh -NoProfile -File (Join-Path $root 'generate-codex-agents.ps1') *> $null
    $hashAfter = Get-Sha256 $coder
    Assert-True ($hashBefore -eq $hashAfter) 'generation is byte-for-byte idempotent'
    Assert-True (-not (Test-Path -LiteralPath $staleRole)) 'generation prunes stale namespaced role output after a role removal/rename'
    if (-not $onWindows) { Assert-True (-not (Test-Path -LiteralPath $caseStaleRole)) 'generation prunes POSIX case-distinct stale namespaced output' }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "test-generate-codex-agents: $($failures.Count) failure(s):"
    foreach ($failure in $failures) { Write-Host "  $failure" }
    exit 1
}
Write-Host 'OK - generate-codex-agents.ps1 emits deterministic namespaced Codex role configs and processor overlay.'
