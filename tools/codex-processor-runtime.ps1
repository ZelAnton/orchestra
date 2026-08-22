<#
  Interactive Codex-native root processor runtime.

  This is deliberately separate from tools/codex-runtime.ps1: that older runtime drives
  one sandboxed leaf adapter inside a Claude processor. This runtime owns the entire
  processor session, enables Codex multi-agent roles, persists the exact root thread id,
  and never invokes or falls back to Claude.
#>

[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0)]
    [ValidateSet('start', 'resume', 'handoff', 'check')]
    [string]$Action = 'start',

    [string]$Root = (Get-Location).Path,
    [string]$HandoffFrom,
    [string]$PromptPath,
    [string]$CodexCmd,
    [string]$Model,
    [string]$Reasoning,
    [string]$Sandbox,
    [int]$MaxThreads = 0,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$commonCandidates = @((Join-Path $PSScriptRoot 'common.ps1'))
if (-not [string]::IsNullOrWhiteSpace([string]$env:ORCHESTRA_HOME)) {
    $commonCandidates += Join-Path $env:ORCHESTRA_HOME 'scripts/common.ps1'
}
$profileRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not [string]::IsNullOrWhiteSpace($profileRoot)) {
    $commonCandidates += Join-Path $profileRoot '.orchestra/scripts/common.ps1'
}
$commonPath = $commonCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $commonPath) { throw 'Orchestra common runtime is missing; run cc-sync from the Orchestra checkout.' }
. $commonPath
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $global:PSNativeCommandUseErrorActionPreference = $false
}

$script:RequiredAgents = @(
    'orchestra_planner', 'orchestra_executor', 'orchestra_coder_fast',
    'orchestra_coder', 'orchestra_coder_deep', 'orchestra_reviewer_std',
    'orchestra_reviewer', 'orchestra_full_reviewer', 'orchestra_merger',
    'orchestra_knowledge_curator', 'orchestra_inbox_curator',
    'orchestra_dependency_curator'
)
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:ExplicitPromptPath = $PromptPath
$script:OnWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows)

function Stop-Runtime {
    param([int]$Code, [string]$Message)
    [Console]::Error.WriteLine("codex-processor-runtime: $Message")
    exit $Code
}

function Resolve-EffectiveValue {
    param([string]$Explicit, [string]$ConfigKey, [string]$Default, [string]$Work)
    if ($Explicit) { return $Explicit }
    return Get-OrchestraConfigValue -Work $Work -Key $ConfigKey -Default $Default
}

function Resolve-ProcessorPrompt {
    if ($script:ExplicitPromptPath) {
        try { return (Resolve-Path -LiteralPath $script:ExplicitPromptPath -ErrorAction Stop).Path }
        catch { Stop-Runtime 12 "processor prompt not found: $($script:ExplicitPromptPath)" }
    }
    $checkout = Join-Path (Split-Path -Parent $PSScriptRoot) 'codex\processor.md'
    if (Test-Path -LiteralPath $checkout -PathType Leaf) { return (Resolve-Path -LiteralPath $checkout).Path }
    $mirror = Join-Path $PSScriptRoot 'codex-processor.md'
    if (Test-Path -LiteralPath $mirror -PathType Leaf) { return (Resolve-Path -LiteralPath $mirror).Path }
    Stop-Runtime 12 'Codex processor prompt is missing; run cc-sync from the Orchestra checkout.'
}

function Get-CodexHome {
    $configured = Get-OrchestraConfigValue -Work (Join-Path $script:ResolvedRoot '.work') -Key 'CODEX_HOME' -Default ''
    if ($configured -eq '~') { $configured = $HOME }
    elseif ($configured.StartsWith('~/' ) -or $configured.StartsWith('~\')) { $configured = Join-Path $HOME $configured.Substring(2) }
    if ($configured) { return [System.IO.Path]::GetFullPath($configured) }
    return [System.IO.Path]::GetFullPath((Join-Path $HOME '.codex'))
}

function Test-RolePackage {
    $agentDir = Join-Path (Get-CodexHome) 'agents'
    $missing = New-Object System.Collections.ArrayList
    $invalid = New-Object System.Collections.ArrayList
    $pathComparer = if ($script:OnWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    $expectedPaths = [System.Collections.Generic.HashSet[string]]::new($pathComparer)
    foreach ($name in $script:RequiredAgents) {
        $path = Join-Path $agentDir ($name + '.toml')
        [void]$expectedPaths.Add([System.IO.Path]::GetFullPath($path))
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            [void]$missing.Add($name)
            continue
        }
        try {
            $text = [System.IO.File]::ReadAllText($path)
            $escaped = [regex]::Escape($name)
            $hasName = $text -match ('(?m)^\s*name\s*=\s*["'']' + $escaped + '["'']\s*$')
            $hasDescription = $text -match '(?m)^\s*description\s*='
            $hasInstructions = $text -match '(?m)^\s*developer_instructions\s*='
            if (-not ($hasName -and $hasDescription -and $hasInstructions)) {
                [void]$invalid.Add($name)
            }
        } catch {
            [void]$invalid.Add($name)
        }
    }
    if ($missing.Count -gt 0) {
        [Console]::Error.WriteLine('codex-processor-runtime: missing Codex role package: ' + ($missing -join ', '))
        [Console]::Error.WriteLine('Run cc-sync from the Orchestra checkout to install generated roles into $CODEX_HOME/agents.')
        return $false
    }
    if ($invalid.Count -gt 0) {
        [Console]::Error.WriteLine('codex-processor-runtime: invalid Codex role definition(s): ' + ($invalid -join ', '))
        [Console]::Error.WriteLine('Run cc-sync from the Orchestra checkout to reinstall generated roles.')
        return $false
    }

    # The TOML `name` field, not the filename, is the agent identity. Reject a second
    # global definition and any project-local definition of an Orchestra name: either
    # would make custom-agent precedence ambiguous or override the generated contract.
    $collisions = New-Object System.Collections.ArrayList
    $scanDirs = @(
        [pscustomobject]@{ Scope = 'global'; Path = $agentDir }
        [pscustomobject]@{ Scope = 'project'; Path = (Join-Path $script:ResolvedRoot '.codex\agents') }
    )
    foreach ($scan in $scanDirs) {
        if (-not (Test-Path -LiteralPath $scan.Path -PathType Container)) { continue }
        foreach ($file in (Get-ChildItem -LiteralPath $scan.Path -File -Filter '*.toml' -ErrorAction SilentlyContinue)) {
            $full = [System.IO.Path]::GetFullPath($file.FullName)
            if ($scan.Scope -eq 'global' -and $expectedPaths.Contains($full)) { continue }
            try {
                $candidateText = [System.IO.File]::ReadAllText($full)
                $nameMatch = [regex]::Match($candidateText, '(?m)^\s*name\s*=\s*["''](?<name>[^"'']+)["'']\s*$')
                if ($nameMatch.Success -and $script:RequiredAgents -contains $nameMatch.Groups['name'].Value) {
                    [void]$collisions.Add("$($scan.Scope):$($file.Name)")
                }
            } catch { }
        }
    }
    if ($collisions.Count -gt 0) {
        [Console]::Error.WriteLine('codex-processor-runtime: conflicting Codex role definition(s): ' + ($collisions -join ', '))
        [Console]::Error.WriteLine('Remove project/global duplicates of orchestra_* role names; only cc-sync managed definitions may own them.')
        return $false
    }

    # In checkout layout, prove the installed package is byte-for-byte current. In the
    # mirror-only layout the generated sources are intentionally absent, so structural
    # validation above remains the fail-closed boundary and cc-sync owns freshness.
    if (-not $script:ExplicitPromptPath) {
        $sourceDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'codex\agents'
        if (Test-Path -LiteralPath $sourceDir -PathType Container) {
            $stale = New-Object System.Collections.ArrayList
            foreach ($name in $script:RequiredAgents) {
                $source = Join-Path $sourceDir ($name + '.toml')
                $installed = Join-Path $agentDir ($name + '.toml')
                if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                    [void]$stale.Add("$name (source missing)")
                    continue
                }
                $sourceBytes = [System.IO.File]::ReadAllBytes($source)
                $installedBytes = [System.IO.File]::ReadAllBytes($installed)
                if (-not [System.Linq.Enumerable]::SequenceEqual([byte[]]$sourceBytes, [byte[]]$installedBytes)) {
                    [void]$stale.Add($name)
                }
            }
            if ($stale.Count -gt 0) {
                [Console]::Error.WriteLine('codex-processor-runtime: installed Codex role package is stale: ' + ($stale -join ', '))
                [Console]::Error.WriteLine('Run cc-sync from this Orchestra checkout before starting the Codex provider.')
                return $false
            }
        }
    }
    return $true
}

function Write-SessionMetadata {
    param([string]$Path, [string]$ThreadId, [string]$EffectiveAction)
    $dir = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $created = [DateTime]::UtcNow.ToString('o')
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            $old = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
            if ($old.created_at) { $created = [string]$old.created_at }
        } catch { }
    }
    $obj = [ordered]@{
        schema = 'orchestra/codex-processor-session@1'
        provider = 'codex'
        thread_id = $ThreadId
        root = $script:ResolvedRoot
        created_at = $created
        updated_at = [DateTime]::UtcNow.ToString('o')
        last_action = $EffectiveAction
    }
    $tmp = $Path + '.tmp.' + [Guid]::NewGuid().ToString('N')
    [System.IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Depth 4), $script:Utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Read-SessionId {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $obj = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
        if ($obj.schema -ne 'orchestra/codex-processor-session@1' -or $obj.provider -ne 'codex') { return $null }
        if ([string]$obj.root -ne $script:ResolvedRoot) { return $null }
        $id = [string]$obj.thread_id
        if ($id -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return $id }
    } catch { }
    return $null
}

function Test-HasDurableRecoveryState {
    param([string]$Work)

    foreach ($name in @('batch.md', 'cohort_state.md', 'integration_state.md', 'merge_report.md', 'review_integration.md')) {
        if (Test-Path -LiteralPath (Join-Path $Work $name) -PathType Leaf) { return $true }
    }
    if (Test-Path -LiteralPath (Join-Path $Work 'orchestrator.lock')) { return $true }

    $tasks = Join-Path $Work 'tasks'
    if (Test-Path -LiteralPath $tasks -PathType Container) {
        if (Get-ChildItem -LiteralPath $tasks -Recurse -File -Filter 'task.md' -ErrorAction SilentlyContinue | Select-Object -First 1) {
            return $true
        }
    }

    $worktrees = Join-Path $Work 'worktrees'
    if (Test-Path -LiteralPath $worktrees -PathType Container) {
        if (Get-ChildItem -LiteralPath $worktrees -Directory -ErrorAction SilentlyContinue | Select-Object -First 1) {
            return $true
        }
    }

    # Covers the narrow crash window after executor marked a queue item but before the
    # processor durably completed the task/cohort descriptor set.
    $queue = Join-Path $Work 'Tasks_Queue.md'
    if (Test-Path -LiteralPath $queue -PathType Leaf) {
        try {
            if ([System.IO.File]::ReadAllText($queue) -match '(?im)статус\s*:\s*в работе(?:\s|·|$)') { return $true }
        } catch { }
    }
    return $false
}

function Assert-HandoffLeaseSafe {
    param([string]$Work)

    $stateTx = Join-Path $PSScriptRoot 'state-tx.ps1'
    if (-not (Test-Path -LiteralPath $stateTx -PathType Leaf)) {
        Stop-Runtime 15 'provider handoff cannot prove processor lease safety because state-tx.ps1 is missing; run cc-sync.'
    }

    $pwsh = Get-Command 'pwsh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pwsh) { Stop-Runtime 15 'provider handoff cannot inspect the processor lease because PowerShell 7 is unavailable.' }
    $statusOutput = @(& $pwsh.Source -NoProfile -File $stateTx status --work $Work --json 2>&1)
    $statusCode = $LASTEXITCODE
    $statusText = (($statusOutput | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if ($statusCode -eq 14) { return }
    if ($statusCode -ne 0) {
        Stop-Runtime 15 "provider handoff refused: processor lease state is not safely readable (state-tx exit $statusCode): $statusText"
    }

    try { $status = $statusText | ConvertFrom-Json -ErrorAction Stop }
    catch { Stop-Runtime 15 "provider handoff refused: state-tx returned invalid JSON: $statusText" }
    if (-not [bool]$status.present) { return }
    if (-not [bool]$status.valid) { Stop-Runtime 15 'provider handoff refused: processor lease is invalid.' }
    if ([string]$status.role -ne 'processor') {
        Stop-Runtime 15 "provider handoff refused: the existing lease belongs to role '$($status.role)', not processor."
    }
    try { $leaseRoot = [System.IO.Path]::GetFullPath([string]$status.root) }
    catch { Stop-Runtime 15 'provider handoff refused: the existing processor lease has an invalid root.' }
    $comparison = if ($script:OnWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not [string]::Equals($leaseRoot, $script:ResolvedRoot, $comparison)) {
        Stop-Runtime 15 "provider handoff refused: processor lease root '$leaseRoot' does not match '$($script:ResolvedRoot)'."
    }
    if ([bool]$status.live) {
        Stop-Runtime 15 "provider handoff refused: a live processor lease still exists (owner=$($status.owner_id), $($status.reason)). Stop the Claude processor first."
    }
    Write-Host "Provider handoff preflight: stale processor lease is safe to recover in Phase 0 (owner=$($status.owner_id), generation=$($status.generation))."
}

function Get-CodexRolloutFiles {
    param([datetime]$StartedLocal)
    $sessionsRoot = Join-Path (Get-CodexHome) 'sessions'
    if (-not (Test-Path -LiteralPath $sessionsRoot -PathType Container)) { return @() }

    # Codex partitions rollouts by the local calendar date. Include adjacent dates so a
    # session started across midnight or on a host with a changing offset is still found.
    $files = New-Object System.Collections.ArrayList
    foreach ($offset in @(-1, 0, 1)) {
        $date = $StartedLocal.Date.AddDays($offset)
        $dayDir = Join-Path $sessionsRoot (Join-Path $date.ToString('yyyy') (Join-Path $date.ToString('MM') $date.ToString('dd')))
        if (-not (Test-Path -LiteralPath $dayDir -PathType Container)) { continue }
        foreach ($file in (Get-ChildItem -LiteralPath $dayDir -File -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue)) {
            [void]$files.Add($file.FullName)
        }
    }
    return @($files)
}

function Find-InvocationThreadId {
    param(
        [datetime]$StartedLocal,
        [System.Collections.Generic.HashSet[string]]$Baseline,
        [string]$InvocationMarker
    )
    $pathComparison = if ($script:OnWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    foreach ($path in (Get-CodexRolloutFiles -StartedLocal $StartedLocal)) {
        $fullPath = [System.IO.Path]::GetFullPath($path)
        if ($Baseline.Contains($fullPath)) { continue }
        try {
            $stream = [System.IO.File]::Open($fullPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
            try {
                $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true, 4096, $true)
                try {
                    $firstLine = $reader.ReadLine()
                    if ([string]::IsNullOrWhiteSpace($firstLine)) { continue }
                    $meta = $firstLine | ConvertFrom-Json -ErrorAction Stop
                    if ($meta.type -ne 'session_meta' -or [string]$meta.payload.originator -ne 'codex-tui') { continue }
                    $candidateRoot = [System.IO.Path]::GetFullPath([string]$meta.payload.cwd)
                    if (-not [string]::Equals($candidateRoot, $script:ResolvedRoot, $pathComparison)) { continue }
                    $candidateId = [string]$meta.payload.id
                    if ($candidateId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { continue }

                    # A second TUI may be open in the same repository. The unique marker in
                    # this invocation's initial user message disambiguates its rollout without
                    # reading or persisting any transcript content.
                    $stream.Position = 0
                    $reader.DiscardBufferedData()
                    $buffer = New-Object char[] 2097152
                    $read = $reader.ReadBlock($buffer, 0, $buffer.Length)
                    if ((New-Object string($buffer, 0, $read)).Contains($InvocationMarker)) {
                        return $candidateId
                    }
                } finally {
                    $reader.Dispose()
                }
            } finally {
                $stream.Dispose()
            }
        } catch {
            # The TUI may still be creating/flushing the rollout. Poll again while it runs.
        }
    }
    return $null
}

function Resolve-CodexProcessLaunch {
    param($CommandInfo, [string[]]$Arguments)
    $source = [string]$CommandInfo.Source
    $extension = [System.IO.Path]::GetExtension($source).ToLowerInvariant()
    if ($extension -eq '.ps1') {
        $pwsh = Get-Command 'pwsh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $pwsh) { Stop-Runtime 10 'PowerShell 7 is required to launch the Codex TUI wrapper.' }
        return [pscustomobject]@{ FilePath = $pwsh.Source; Arguments = @('-NoProfile', '-File', $source) + @($Arguments) }
    }
    if ($extension -in @('.cmd', '.bat')) {
        $siblingPowerShell = [System.IO.Path]::ChangeExtension($source, '.ps1')
        if (-not (Test-Path -LiteralPath $siblingPowerShell -PathType Leaf)) {
            Stop-Runtime 10 "Codex command '$source' is a batch wrapper without a sibling .ps1 launcher; set CODEX_CMD to a native executable or PowerShell launcher."
        }
        $pwsh = Get-Command 'pwsh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $pwsh) { Stop-Runtime 10 'PowerShell 7 is required to launch the Codex TUI wrapper.' }
        return [pscustomobject]@{ FilePath = $pwsh.Source; Arguments = @('-NoProfile', '-File', $siblingPowerShell) + @($Arguments) }
    }
    return [pscustomobject]@{ FilePath = $source; Arguments = @($Arguments) }
}

try { $script:ResolvedRoot = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path }
catch { Stop-Runtime 2 "project root does not exist: $Root" }
if ($Action -eq 'handoff') {
    if (-not $HandoffFrom) { Stop-Runtime 2 'handoff requires -HandoffFrom claude' }
    if ($HandoffFrom -ne 'claude') { Stop-Runtime 2 "unsupported handoff source '$HandoffFrom' (allowed: claude)" }
} elseif ($HandoffFrom) {
    Stop-Runtime 2 '-HandoffFrom is valid only with the handoff action'
}

$configWork = Join-Path $script:ResolvedRoot '.work'
$CodexCmd = Resolve-EffectiveValue $CodexCmd 'CODEX_CMD' 'codex' $configWork
$Model = Resolve-EffectiveValue $Model 'ORCHESTRA_CODEX_MODEL' '' $configWork
$Reasoning = Resolve-EffectiveValue $Reasoning 'ORCHESTRA_CODEX_REASONING' 'high' $configWork
$Sandbox = Resolve-EffectiveValue $Sandbox 'ORCHESTRA_CODEX_SANDBOX' 'danger-full-access' $configWork
if (-not $PSBoundParameters.ContainsKey('MaxThreads')) {
    $rawThreads = Get-OrchestraConfigValue -Work $configWork -Key 'ORCHESTRA_CODEX_MAX_THREADS' -Default '6'
    if ($rawThreads -and -not [int]::TryParse($rawThreads, [ref]$MaxThreads)) {
        Stop-Runtime 2 "invalid ORCHESTRA_CODEX_MAX_THREADS '$rawThreads' (expected positive integer)"
    }
    if (-not $rawThreads) { $MaxThreads = 6 }
}
if ($Reasoning -notin @('low', 'medium', 'high', 'xhigh')) {
    Stop-Runtime 2 "invalid Codex reasoning '$Reasoning' (allowed: low, medium, high, xhigh)"
}
if ($Sandbox -notin @('workspace-write', 'danger-full-access')) {
    Stop-Runtime 2 "invalid Codex sandbox '$Sandbox' (allowed for the root processor: workspace-write, danger-full-access)"
}
if ($MaxThreads -lt 2 -or $MaxThreads -gt 32) {
    Stop-Runtime 2 "invalid Codex max threads '$MaxThreads' (allowed: 2..32)"
}

$cmd = Get-Command $CodexCmd -ErrorAction SilentlyContinue
if (-not $cmd) { Stop-Runtime 10 "Codex command not found: $CodexCmd" }
$promptFile = Resolve-ProcessorPrompt
$rolesReady = Test-RolePackage

if ($Action -eq 'check') {
    if (-not $rolesReady) { exit 12 }
    Write-Host "OK   Codex command = $($cmd.Source)"
    Write-Host "OK   Codex processor prompt = $promptFile"
    Write-Host "OK   Codex custom roles = $($script:RequiredAgents.Count)"
    Write-Host "OK   Codex root sandbox = $Sandbox"
    Write-Host "OK   Codex reasoning = $Reasoning"
    Write-Host "OK   Codex max threads = $MaxThreads"
    exit 0
}
if (-not $rolesReady) { exit 12 }

$work = Join-Path $script:ResolvedRoot '.work'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$runtimeLockPath = Join-Path $work 'codex-processor-runtime.lock'
try {
    # Serialize the outer Codex process before a new rollout session_meta can rewrite
    # the addressed-session pointer. FileShare.None is held by the OS for this process
    # lifetime and is released automatically after a crash (no stale lock protocol).
    $runtimeLock = [System.IO.File]::Open($runtimeLockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
} catch {
    Stop-Runtime 14 "another Codex processor runtime is already active for this project ($runtimeLockPath)"
}
$sessionPath = Join-Path $work 'codex_processor_session.json'
$threadId = if ($Action -eq 'resume') { Read-SessionId -Path $sessionPath } else { $null }
$effectiveAction = if ($Action -eq 'resume' -and $threadId) {
    'resume'
} elseif ($Action -eq 'handoff' -or ($Action -eq 'resume' -and (Test-HasDurableRecoveryState -Work $work))) {
    'handoff'
} else {
    'start'
}

if ($effectiveAction -eq 'handoff') {
    Assert-HandoffLeaseSafe -Work $work
}

# A start or provider handoff supersedes any previous addressed Codex root thread.
# Invalidate the old pointer only after the handoff lease preflight, but before spawning,
# so a later cc-resume cannot silently attach to a session from before the provider switch.
if ($effectiveAction -in @('start', 'handoff') -and (Test-Path -LiteralPath $sessionPath -PathType Leaf)) {
    Remove-Item -LiteralPath $sessionPath -Force
}

$common = @(
    '-c', 'approval_policy="never"',
    '-c', ('sandbox_mode="' + $Sandbox + '"'),
    '-c', ('model_reasoning_effort="' + $Reasoning + '"'),
    '-c', 'features.multi_agent=true',
    '-c', 'agents.max_depth=1',
    '-c', ('agents.max_threads=' + $MaxThreads)
)
if ($Model) { $common += @('-m', $Model) }
if ($ExtraArgs) { $common += @($ExtraArgs) }

$invocationMarker = 'orchestra-codex-root-' + [Guid]::NewGuid().ToString('N')
if ($effectiveAction -eq 'resume') {
    $userPrompt = "Orchestra runtime invocation marker: $invocationMarker. Continue the exact Codex-native Orchestra processor session. Reconcile durable .work state using Phase 0, retain ORCHESTRA_PROVIDER=codex, and process the queue to its terminal state without invoking Claude."
    $argv = @('resume', '-C', $script:ResolvedRoot, '--sandbox', $Sandbox) + $common + @($threadId, $userPrompt)
} else {
    # The interactive CLI accepts its initial prompt only as argv. Keep that prompt short
    # (especially for Windows' command-line limit) and make the canonical generated file
    # the explicit source the root must read before taking any task action.
    $modeText = if ($effectiveAction -eq 'handoff') {
        $sourceText = if ($HandoffFrom) { "the terminated $HandoffFrom processor" } else { 'an interrupted processor whose Codex thread is unavailable' }
        "Operator-authorized provider handoff from $sourceText. No conversation transcript is imported: durable .work artifacts and VCS are the source of truth. Reconcile the complete in-flight cohort in Phase 0, preserve existing worktrees, branches, task descriptors, and uncommitted work, and do not restart or discard work merely because another provider created it."
    } elseif ($Action -eq 'resume') {
        'Cold recovery: no valid addressed Codex processor thread and no durable in-flight Orchestra state were found.'
    } else {
        'Start a new Codex-native Orchestra processor session.'
    }
    $userPrompt = "Orchestra runtime invocation marker: $invocationMarker. Before any other action, open and read the complete UTF-8 processor instructions at the exact path $promptFile, then follow them for this entire root session. $modeText Acquire or safely recover the lease, process .work/Tasks_Queue.md end to end, and never invoke Claude."
    $argv = @('-C', $script:ResolvedRoot, '--sandbox', $Sandbox) + $common + @($userPrompt)
}

$startedLocal = [DateTime]::Now
$pathComparer = if ($script:OnWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
$rolloutBaseline = [System.Collections.Generic.HashSet[string]]::new($pathComparer)
foreach ($path in (Get-CodexRolloutFiles -StartedLocal $startedLocal)) {
    [void]$rolloutBaseline.Add([System.IO.Path]::GetFullPath($path))
}
$observedThread = $threadId
$launch = Resolve-CodexProcessLaunch -CommandInfo $cmd -Arguments $argv
$process = $null
$exitCode = 10

try {
    Write-Host "Starting Orchestra provider=codex UI=tui action=$effectiveAction root=$script:ResolvedRoot sandbox=$Sandbox reasoning=$Reasoning threads=$MaxThreads"
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $launch.FilePath
    $startInfo.WorkingDirectory = $script:ResolvedRoot
    $startInfo.UseShellExecute = $false
    # The CLI discovers its sessions/agents through CODEX_HOME. Resolve that path
    # from root-config and pass the effective value to the child; it is not an
    # operator configuration read from the ambient process environment.
    $startInfo.Environment['CODEX_HOME'] = Get-CodexHome
    foreach ($argument in $launch.Arguments) { [void]$startInfo.ArgumentList.Add([string]$argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'process start returned false' }

    do {
        $candidateThread = Find-InvocationThreadId -StartedLocal $startedLocal -Baseline $rolloutBaseline -InvocationMarker $invocationMarker
        if ($candidateThread -and $candidateThread -ne $observedThread) {
            $observedThread = $candidateThread
            Write-SessionMetadata -Path $sessionPath -ThreadId $observedThread -EffectiveAction $effectiveAction
        }
    } while (-not $process.WaitForExit(100))
    $process.WaitForExit()
    $exitCode = $process.ExitCode

    # The process can finish between its rollout write and the last polling interval.
    $candidateThread = Find-InvocationThreadId -StartedLocal $startedLocal -Baseline $rolloutBaseline -InvocationMarker $invocationMarker
    if ($candidateThread) { $observedThread = $candidateThread }

    if ($observedThread) {
        Write-SessionMetadata -Path $sessionPath -ThreadId $observedThread -EffectiveAction $effectiveAction
    } elseif ($exitCode -eq 0) {
        [Console]::Error.WriteLine('codex-processor-runtime: Codex TUI exited successfully but no matching session_meta rollout was found; addressed resume metadata was not written.')
        $exitCode = 13
    }
} catch {
    [Console]::Error.WriteLine("codex-processor-runtime: failed to launch or monitor Codex TUI: $($_.Exception.Message)")
    $exitCode = 10
} finally {
    if ($process) { $process.Dispose() }
    $runtimeLock.Dispose()
}
exit $exitCode
