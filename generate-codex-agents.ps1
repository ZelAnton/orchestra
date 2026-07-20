# Generates the Codex-native Orchestra role package from the canonical Claude role
# instructions in agents/*.md. The Markdown files remain the single source of role
# behaviour; this generator only removes Claude frontmatter and prepends a small
# provider overlay that maps named role dispatch onto Codex custom agents.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$agentsDir = Join-Path $root 'agents'
$outDir = Join-Path $root 'codex\agents'
$processorOut = Join-Path $root 'codex\processor.md'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$onWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows)

$roles = [ordered]@{
    planner           = 'high'
    executor          = 'medium'
    coder_fast        = 'medium'
    coder              = 'high'
    coder_deep         = 'xhigh'
    reviewer_std       = 'medium'
    reviewer           = 'high'
    full_reviewer      = 'high'
    merger             = 'high'
    knowledge_curator  = 'medium'
}

function Read-AgentSource {
    param([Parameter(Mandatory)][string]$Name)

    $path = Join-Path $agentsDir ($Name + '.md')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing canonical agent source: $path"
    }
    $raw = [System.IO.File]::ReadAllText($path).Replace("`r`n", "`n").Replace("`r", "`n")
    $match = [regex]::Match($raw, '\A---\n(?<frontmatter>[\s\S]*?)\n---\n(?<body>[\s\S]*)\z')
    if (-not $match.Success) {
        throw "Agent source has no valid first-byte YAML frontmatter: $path"
    }
    $frontmatter = $match.Groups['frontmatter'].Value
    $descriptionMatch = [regex]::Match($frontmatter, '(?m)^description:\s*(?<value>.+)$')
    if (-not $descriptionMatch.Success) {
        throw "Agent source has no description: $path"
    }
    return [pscustomobject]@{
        Body = $match.Groups['body'].Value.TrimEnd() + "`n"
        Description = $descriptionMatch.Groups['value'].Value.Trim()
    }
}

function ConvertTo-TomlString {
    param([Parameter(Mandatory)][string]$Value)
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"').Replace("`t", '\t').Replace("`n", '\n') + '"'
}

$leafOverlay = @'
# Codex-native provider contract

You are a leaf custom agent of Orchestra running natively inside Codex. The canonical
instructions below were written for the Claude-backed runtime and remain authoritative
for role boundaries, files, phases, reports, VCS rules, and safety invariants. Apply these
provider translations without changing that behaviour:

- Mentions of Claude/Sonnet/Opus/Haiku describe the historical tier, not a command to run.
  Never invoke `claude`, `codex exec`, `coder_codex`, or `reviewer_codex`.
- You already are the selected Codex role. Use Codex tools directly and complete exactly
  the role invocation passed by the parent `orchestra_processor`.
- Do not spawn further agents. Only the root `orchestra_processor` owns orchestration.
- Treat the worktree, task id, WORK path, VCS, mode, and limits supplied in the invocation
  as binding. Preserve every maker/checker and single-writer boundary from the canonical
  instructions.
- A reviewer is independent when it runs in a distinct Codex agent thread that did not
  implement the change. Never reuse the maker thread for review.

--- canonical role instructions ---
'@

$processorOverlay = @'
# Codex-native Orchestra processor

This is the full Codex provider for the legacy Orchestra state machine. The canonical
processor instructions below remain authoritative for phases 0-6, transactions, leases,
worktrees, review loops, publication, CI, cleanup, and crash recovery. Apply the following
provider contract at higher precedence whenever provider-specific wording conflicts:

1. You are the root processor. Never invoke `claude`, `claude -p`, `coder_codex`,
   `reviewer_codex`, or `tools/codex-runtime.ps1`. All model work is native Codex work.
2. Dispatch every canonical role through a NEW named Codex custom-agent thread:
   `planner` -> `orchestra_planner`; `executor` -> `orchestra_executor`;
   `coder_fast` -> `orchestra_coder_fast`; `coder` -> `orchestra_coder`;
   `coder_deep` -> `orchestra_coder_deep`; `reviewer_std` ->
   `orchestra_reviewer_std`; `reviewer` -> `orchestra_reviewer`;
   `full_reviewer` -> `orchestra_full_reviewer`; `merger` -> `orchestra_merger`;
   `knowledge_curator` -> `orchestra_knowledge_curator`.
3. The canonical `Agent(...)` operation means spawning the mapped custom agent, passing
   the complete task-specific invocation, and waiting/steering/collecting it through Codex
   multi-agent tools. Preserve the same concurrency and round barriers.
4. Ignore `CODEX_CODER`, `CODEX_REVIEWER`, `CODEX_CIFIX`, Codex adapter preflight,
   adapter sentinels, and every fallback-to-Claude branch. The provider has already been
   selected outside the model by the launcher. Choose the canonical tier, then dispatch
   its `orchestra_*` role. Integration `F-` fixes use a fresh `orchestra_coder` or
   `orchestra_coder_deep` thread exactly as the canonical tier resolver requires.
5. Maker/checker independence is thread-based in this provider: the reviewing custom
   agent must be a new thread that did not implement or fix the reviewed change. Record
   implementation source as `codex`; a separate Codex reviewer satisfies the provider's
   checker boundary. Never ask the maker to self-review.
6. Names Sonnet/Opus/Haiku and phrases such as “Claude reviewer” are tier labels only.
   The custom-agent TOML selects Codex reasoning effort for that tier; they never authorize
   an Anthropic call.
7. Do not modify `.claude/settings*`, `.codex/config.toml`, or `.codex/agents` during a
   run. Provider configuration belongs to `cc-sync`, the launcher, and the operator.
8. `ORCHESTRA_PROVIDER=codex` is an external runtime fact. Do not change it and do not
   switch providers mid-cohort. On a role failure, follow the canonical bounded retry,
   requeue, quarantine, or escalation path without falling back to Claude.

--- canonical processor instructions ---
'@

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$fileNameComparer = if ($onWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
$expectedFiles = [System.Collections.Generic.HashSet[string]]::new($fileNameComparer)
foreach ($role in $roles.Keys) { [void]$expectedFiles.Add('orchestra_' + $role + '.toml') }
foreach ($existing in (Get-ChildItem -LiteralPath $outDir -File -Filter 'orchestra_*.toml' -ErrorAction SilentlyContinue)) {
    if (-not $expectedFiles.Contains($existing.Name)) {
        Remove-Item -LiteralPath $existing.FullName -Force
        Write-Host "Removed stale Codex role: $($existing.Name)"
    }
}

foreach ($role in $roles.Keys) {
    $source = Read-AgentSource -Name $role
    if ($source.Body.Contains("'''")) {
        throw "Canonical body for $role contains TOML literal-string terminator '''"
    }
    $name = 'orchestra_' + $role
    $description = "Orchestra Codex-native role '$role'. $($source.Description)"
    $instructions = ($leafOverlay.TrimEnd() + "`n`n" + $source.Body).Replace("`r`n", "`n")
    $toml = @(
        '# Generated by generate-codex-agents.ps1. Do not edit directly.'
        ('name = ' + (ConvertTo-TomlString $name))
        ('description = ' + (ConvertTo-TomlString $description))
        ('model_reasoning_effort = ' + (ConvertTo-TomlString ([string]$roles[$role])))
        "developer_instructions = '''"
        $instructions.TrimEnd()
        "'''"
        ''
    ) -join "`n"
    [System.IO.File]::WriteAllText((Join-Path $outDir ($name + '.toml')), $toml, $utf8NoBom)
    Write-Host "Generated Codex role: $name"
}

$processor = Read-AgentSource -Name 'processor'
$processorText = ($processorOverlay.TrimEnd() + "`n`n" + $processor.Body).Replace("`r`n", "`n")
[System.IO.File]::WriteAllText($processorOut, $processorText, $utf8NoBom)
Write-Host 'Generated Codex processor prompt: codex/processor.md'
