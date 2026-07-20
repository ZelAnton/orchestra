<#
  Headless Codex-native root processor runtime.

  This is deliberately separate from tools/codex-runtime.ps1: that older runtime drives
  one sandboxed leaf adapter inside a Claude processor. This runtime owns the entire
  processor session, enables Codex multi-agent roles, persists the exact root thread id,
  and never invokes or falls back to Claude.
#>

[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0)]
    [ValidateSet('start', 'resume', 'check')]
    [string]$Action = 'start',

    [string]$Root = (Get-Location).Path,
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
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $global:PSNativeCommandUseErrorActionPreference = $false
}

$script:RequiredAgents = @(
    'orchestra_planner', 'orchestra_executor', 'orchestra_coder_fast',
    'orchestra_coder', 'orchestra_coder_deep', 'orchestra_reviewer_std',
    'orchestra_reviewer', 'orchestra_full_reviewer', 'orchestra_merger',
    'orchestra_knowledge_curator'
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
    param([string]$Explicit, [string]$EnvironmentName, [string]$Default)
    if ($Explicit) { return $Explicit }
    $fromEnv = [Environment]::GetEnvironmentVariable($EnvironmentName)
    if ($fromEnv) { return $fromEnv }
    return $Default
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
    if ($env:CODEX_HOME) { return [System.IO.Path]::GetFullPath($env:CODEX_HOME) }
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

try { $script:ResolvedRoot = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path }
catch { Stop-Runtime 2 "project root does not exist: $Root" }

$CodexCmd = Resolve-EffectiveValue $CodexCmd 'CODEX_CMD' 'codex'
$Model = Resolve-EffectiveValue $Model 'ORCHESTRA_CODEX_MODEL' ''
$Reasoning = Resolve-EffectiveValue $Reasoning 'ORCHESTRA_CODEX_REASONING' 'high'
$Sandbox = Resolve-EffectiveValue $Sandbox 'ORCHESTRA_CODEX_SANDBOX' 'danger-full-access'
if (-not $PSBoundParameters.ContainsKey('MaxThreads')) {
    $rawThreads = [Environment]::GetEnvironmentVariable('ORCHESTRA_CODEX_MAX_THREADS')
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
    # Serialize the outer Codex process before thread.started can rewrite the
    # addressed-session pointer. FileShare.None is held by the OS for this process
    # lifetime and is released automatically after a crash (no stale lock protocol).
    $runtimeLock = [System.IO.File]::Open($runtimeLockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
} catch {
    Stop-Runtime 14 "another Codex processor runtime is already active for this project ($runtimeLockPath)"
}
$sessionPath = Join-Path $work 'codex_processor_session.json'
$threadId = if ($Action -eq 'resume') { Read-SessionId -Path $sessionPath } else { $null }
$effectiveAction = if ($Action -eq 'resume' -and $threadId) { 'resume' } else { 'start' }

# An explicit start supersedes any previous addressed root thread. Invalidate the old
# pointer before spawning so an auth/config/spawn failure cannot make a later cc-resume
# silently attach to the superseded run.
if ($Action -eq 'start' -and (Test-Path -LiteralPath $sessionPath -PathType Leaf)) {
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

if ($effectiveAction -eq 'resume') {
    $argv = @('exec', 'resume') + $common + @('--skip-git-repo-check', '--json', $threadId, '-')
    $userPrompt = 'Continue the exact Codex-native Orchestra processor session. Reconcile durable .work state using Phase 0, retain ORCHESTRA_PROVIDER=codex, and process the queue to its terminal state without invoking Claude.'
} else {
    # Orchestra supports pure-jj repositories with no colocated .git directory. Codex's
    # repository guard only recognizes Git, so bypass that guard and let the processor's
    # own Phase-0 git/jj root validation remain authoritative.
    $argv = @('exec', '-C', $script:ResolvedRoot, '--sandbox', $Sandbox) + $common + @('--skip-git-repo-check', '--json', '-')
    $modeText = if ($Action -eq 'resume') { 'Cold recovery: no valid addressed Codex processor thread was recorded.' } else { 'Start a new Codex-native Orchestra processor session.' }
    $userPrompt = "$modeText Follow the complete processor instructions, acquire or safely recover the lease, process .work/Tasks_Queue.md end to end, and never invoke Claude."
}

if ($effectiveAction -eq 'resume') {
    # The exact thread already contains the full canonical processor prompt. Re-sending
    # it on every resume needlessly consumes context and can eventually crowd out the
    # durable-state recovery work this continuation is meant to perform.
    $fullPrompt = $userPrompt + "`n"
} else {
    $basePrompt = [System.IO.File]::ReadAllText($promptFile)
    $fullPrompt = $basePrompt.TrimEnd() + "`n`n--- runtime invocation ---`n" + $userPrompt + "`n"
}
$observedThread = $threadId

try {
    Write-Host "Starting Orchestra provider=codex action=$effectiveAction root=$script:ResolvedRoot sandbox=$Sandbox reasoning=$Reasoning threads=$MaxThreads"
    $fullPrompt | & $cmd.Source @argv 2>&1 | ForEach-Object {
        $line = [string]$_
        [Console]::Out.WriteLine($line)
        if (-not $observedThread) {
            try {
                $jsonEvent = $line | ConvertFrom-Json -ErrorAction Stop
                if ($jsonEvent.type -eq 'thread.started' -and ([string]$jsonEvent.thread_id -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')) {
                    $observedThread = [string]$jsonEvent.thread_id
                    Write-SessionMetadata -Path $sessionPath -ThreadId $observedThread -EffectiveAction $effectiveAction
                }
            } catch { }
        }
    }
    $exitCode = $LASTEXITCODE

    if ($observedThread) {
        Write-SessionMetadata -Path $sessionPath -ThreadId $observedThread -EffectiveAction $effectiveAction
    } elseif ($exitCode -eq 0) {
        [Console]::Error.WriteLine('codex-processor-runtime: Codex exited successfully but emitted no thread.started id; addressed resume metadata was not written.')
        $exitCode = 13
    }
} finally {
    $runtimeLock.Dispose()
}
exit $exitCode
