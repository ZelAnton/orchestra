<#
  Interactive Codex TUI runtime for directly launched analytical roles.

  The Codex CLI has no top-level equivalent of `claude --agent <name>`. This runtime
  therefore starts the normal TUI with inherited terminal streams and gives it a short
  bootstrap that points at the complete canonical role prompt. It never uses `codex exec`,
  never emits JSONL, and never invokes or falls back to Claude.
#>

[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('thinker', 'code_auditor', 'enhancement_scout')]
    [string]$Role,

    [string]$Root = (Get-Location).Path,
    [string]$PromptPath,
    [string]$CodexCmd,
    [string]$Model,
    [string]$Reasoning,
    [string]$Sandbox,
    [Alias('provider')]
    [string]$RequestedProvider,
    [string]$OpeningTopic
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $global:PSNativeCommandUseErrorActionPreference = $false
}

function Stop-Runtime {
    param([int]$Code, [string]$Message)
    [Console]::Error.WriteLine("codex-role-runtime: $Message")
    exit $Code
}

function Resolve-EffectiveValue {
    param([string]$Explicit, [string]$EnvironmentName, [string]$Default)
    if ($Explicit) { return $Explicit }
    $fromEnv = [Environment]::GetEnvironmentVariable($EnvironmentName)
    if ($fromEnv) { return $fromEnv }
    return $Default
}

function Resolve-RolePrompt {
    param([string]$RoleName)
    if ($PromptPath) {
        try { return (Resolve-Path -LiteralPath $PromptPath -ErrorAction Stop).Path }
        catch { Stop-Runtime 12 "role prompt not found: $PromptPath" }
    }

    # Checkout: <repo>/tools -> <repo>/agents.
    # cc-sync provider mirror: ~/.claude/scripts -> ~/.claude/agents.
    $agentsRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'agents'
    $candidate = Join-Path $agentsRoot ($RoleName + '.md')
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return (Resolve-Path -LiteralPath $candidate).Path
    }
    Stop-Runtime 12 "Codex role prompt '$RoleName.md' is missing; run cc-sync from the Orchestra checkout."
}

function Resolve-CodexProcessLaunch {
    param($CommandInfo, [string[]]$Arguments)
    $source = [string]$CommandInfo.Source
    $extension = [System.IO.Path]::GetExtension($source).ToLowerInvariant()
    if ($extension -eq '.ps1') {
        $pwsh = Get-Command 'pwsh' -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $pwsh) { Stop-Runtime 10 'PowerShell 7 is required to launch the Codex TUI wrapper.' }
        return [pscustomobject]@{
            FilePath = $pwsh.Source
            Arguments = @('-NoProfile', '-File', $source) + @($Arguments)
        }
    }
    if ($extension -in @('.cmd', '.bat')) {
        $siblingPowerShell = [System.IO.Path]::ChangeExtension($source, '.ps1')
        if (-not (Test-Path -LiteralPath $siblingPowerShell -PathType Leaf)) {
            Stop-Runtime 10 "Codex command '$source' is a batch wrapper without a sibling .ps1 launcher; set CODEX_CMD to a native executable or PowerShell launcher."
        }
        $pwsh = Get-Command 'pwsh' -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $pwsh) { Stop-Runtime 10 'PowerShell 7 is required to launch the Codex TUI wrapper.' }
        return [pscustomobject]@{
            FilePath = $pwsh.Source
            Arguments = @('-NoProfile', '-File', $siblingPowerShell) + @($Arguments)
        }
    }
    return [pscustomobject]@{ FilePath = $source; Arguments = @($Arguments) }
}

try { $resolvedRoot = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path }
catch { Stop-Runtime 2 "project root does not exist: $Root" }

$CodexCmd = Resolve-EffectiveValue $CodexCmd 'CODEX_CMD' 'codex'
$Model = Resolve-EffectiveValue $Model 'ORCHESTRA_CODEX_MODEL' ''
$Reasoning = Resolve-EffectiveValue $Reasoning 'ORCHESTRA_CODEX_REASONING' 'high'
$Sandbox = Resolve-EffectiveValue $Sandbox 'ORCHESTRA_CODEX_SANDBOX' 'danger-full-access'
$OpeningTopic = Resolve-EffectiveValue $OpeningTopic 'ORCHESTRA_CODEX_ROLE_TOPIC' ''
# The launcher uses this process-scoped variable only to cross cmd.exe's free-form argv
# boundary safely. Do not leak the operator's topic into the Codex child environment.
[Environment]::SetEnvironmentVariable('ORCHESTRA_CODEX_ROLE_TOPIC', $null, 'Process')
if ($Reasoning -notin @('low', 'medium', 'high', 'xhigh')) {
    Stop-Runtime 2 "invalid Codex reasoning '$Reasoning' (allowed: low, medium, high, xhigh)"
}
if ($Sandbox -notin @('workspace-write', 'danger-full-access')) {
    Stop-Runtime 2 "invalid Codex sandbox '$Sandbox' (allowed: workspace-write, danger-full-access)"
}

if ($RequestedProvider) {
    if ($RequestedProvider.ToLowerInvariant() -ne 'codex') {
        Stop-Runtime 2 "this runtime only launches provider codex, not '$RequestedProvider'"
    }
}

$cmd = Get-Command $CodexCmd -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $cmd) { Stop-Runtime 10 "Codex command not found: $CodexCmd" }
$promptFile = Resolve-RolePrompt -RoleName $Role

$roleDirective = switch ($Role) {
    'thinker' {
        if ($OpeningTopic) {
            'Begin with this operator-supplied opening topic: ' + $OpeningTopic
        } else {
            'Introduce yourself briefly as the project thinker, then wait for the operator to provide a topic in this interactive chat.'
        }
    }
    'code_auditor' {
        'Start the repository source-code audit now and enqueue validated findings exactly as the role instructions require.'
    }
    'enhancement_scout' {
        'Start the project enhancement analysis now and enqueue validated proposals exactly as the role instructions require.'
    }
}

$userPrompt = "Before any other action, open and read the complete UTF-8 role instructions at the exact path $promptFile. Ignore only its Claude-specific YAML frontmatter fields; follow the Markdown body as the controlling instructions for this entire Codex TUI session. The project root is $resolvedRoot. $roleDirective Never invoke or fall back to Claude."
$argv = @(
    '-C', $resolvedRoot,
    '--sandbox', $Sandbox,
    '-c', 'approval_policy="never"',
    '-c', ('sandbox_mode="' + $Sandbox + '"'),
    '-c', ('model_reasoning_effort="' + $Reasoning + '"')
)
if ($Model) { $argv += @('-m', $Model) }
$argv += @($userPrompt)

$launch = Resolve-CodexProcessLaunch -CommandInfo $cmd -Arguments $argv
$process = $null
try {
    Write-Host "Starting Orchestra provider=codex UI=tui role=$Role root=$resolvedRoot sandbox=$Sandbox reasoning=$Reasoning"
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $launch.FilePath
    $startInfo.WorkingDirectory = $resolvedRoot
    $startInfo.UseShellExecute = $false
    foreach ($argument in $launch.Arguments) {
        [void]$startInfo.ArgumentList.Add([string]$argument)
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'process start returned false' }
    $process.WaitForExit()
    exit $process.ExitCode
} catch {
    [Console]::Error.WriteLine("codex-role-runtime: failed to launch Codex TUI: $($_.Exception.Message)")
    exit 10
} finally {
    if ($process) { $process.Dispose() }
}
