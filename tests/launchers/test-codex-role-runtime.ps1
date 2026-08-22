# ci:posix
<# Hermetic coverage for the interactive Codex runtime used by direct roles. #>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$runtime = (Resolve-Path (Join-Path $PSScriptRoot '..\..\tools\codex-role-runtime.ps1')).Path
$failures = New-Object System.Collections.ArrayList

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { [void]$failures.Add("FAIL - $Message") }
}

$base = Join-Path ([System.IO.Path]::GetTempPath()) ('orc-codex-role-' + [Guid]::NewGuid().ToString('N'))
$project = Join-Path $base 'project'
$orchestraHome = Join-Path $base 'orchestra'
$prompt = Join-Path $base 'role.md'
$fake = Join-Path $base 'fake-codex.ps1'
$argsFile = Join-Path $base 'args.txt'
New-Item -ItemType Directory -Force -Path $project | Out-Null
New-Item -ItemType Directory -Force -Path $orchestraHome | Out-Null
Set-Content -LiteralPath $prompt -Value 'FULL-CANONICAL-ROLE-PROMPT' -Encoding utf8
@'
$args | Set-Content -LiteralPath $env:FAKE_ARGS_FILE -Encoding utf8
Write-Output 'FAKE CODEX ROLE TUI'
Write-Output ('TOPIC_ENV=' + $env:ORCHESTRA_CODEX_ROLE_TOPIC)
Write-Output ('CODEX_HOME=' + $env:CODEX_HOME)
$code = if ($env:FAKE_EXIT_CODE) { [int]$env:FAKE_EXIT_CODE } else { 0 }
exit $code
'@ | Set-Content -LiteralPath $fake -Encoding utf8

function Invoke-RoleRuntime {
    param(
        [string]$Role,
        [string[]]$Additional = @(),
        [hashtable]$Environment = @{},
        [string]$PromptOverride = $prompt
    )
    $vars = @{
        FAKE_ARGS_FILE = $argsFile
        FAKE_EXIT_CODE = '0'
        ORCHESTRA_CODEX_ROLE_TOPIC = ''
        ORCHESTRA_HOME = $orchestraHome
    }
    $configKeys = @('ORCHESTRA_CODEX_MODEL', 'ORCHESTRA_CODEX_REASONING', 'ORCHESTRA_CODEX_SANDBOX', 'CODEX_HOME')
    $configLines = @(
        foreach ($key in $Environment.Keys) {
            if ($configKeys -contains $key -and -not [string]::IsNullOrWhiteSpace([string]$Environment[$key])) {
                '{0}: {1}' -f $key, $Environment[$key]
            }
        }
    )
    if (-not $Environment.ContainsKey('CODEX_HOME')) {
        $configLines += 'CODEX_HOME: ' + (Join-Path $orchestraHome '.codex')
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $orchestraHome 'root-config.md'),
        (($configLines -join "`n") + "`n"),
        (New-Object System.Text.UTF8Encoding($false)))
    foreach ($key in $Environment.Keys) {
        if ($configKeys -notcontains $key) { $vars[$key] = $Environment[$key] }
    }
    $old = @{}
    foreach ($key in $vars.Keys) {
        $old[$key] = [Environment]::GetEnvironmentVariable($key)
        [Environment]::SetEnvironmentVariable($key, [string]$vars[$key])
    }
    try {
        $outFile = Join-Path $base ('out-' + [Guid]::NewGuid().ToString('N') + '.txt')
        $errFile = Join-Path $base ('err-' + [Guid]::NewGuid().ToString('N') + '.txt')
        $argv = @(
            '-NoProfile', '-File', $runtime,
            '-Role', $Role,
            '-Root', $project,
            '-PromptPath', $PromptOverride,
            '-CodexCmd', $fake
        ) + @($Additional)
        $process = Start-Process -FilePath 'pwsh' -ArgumentList $argv -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Out = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
            Err = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
        }
    } finally {
        foreach ($key in $old.Keys) {
            [Environment]::SetEnvironmentVariable($key, $old[$key])
        }
    }
}

try {
    $r = Invoke-RoleRuntime -Role thinker -Additional @('-RequestedProvider', 'codex') `
        -Environment @{ ORCHESTRA_CODEX_ROLE_TOPIC = 'consider queue fairness' }
    Assert-True ($r.ExitCode -eq 0) "thinker starts successfully (exit=$($r.ExitCode), err=$($r.Err))"
    $captured = @()
    if (Test-Path -LiteralPath $argsFile) { $captured = @(Get-Content -LiteralPath $argsFile) }
    if ($captured.Count -eq 0) { throw "fake Codex was not invoked: exit=$($r.ExitCode), err=$($r.Err)" }
    Assert-True (-not ($captured -contains 'exec')) 'thinker launches interactive codex, not codex exec'
    Assert-True (-not ($captured -contains '--json')) 'thinker does not select JSONL output'
    Assert-True ($captured -contains '-C') 'thinker pins the project root'
    Assert-True ($captured -contains 'danger-full-access') 'direct roles inherit the autonomous Codex sandbox default'
    Assert-True (($captured -contains 'approval_policy="never"') -or ($captured -contains 'approval_policy=never')) 'direct roles disable nested approval prompts'
    $bootstrap = [string]$captured[-1]
    Assert-True ($bootstrap.Contains($prompt)) 'bootstrap points to the complete canonical role prompt'
    Assert-True (-not $bootstrap.Contains('FULL-CANONICAL-ROLE-PROMPT')) 'bootstrap does not copy the full role prompt into argv'
    Assert-True ($bootstrap.Contains('consider queue fairness')) 'thinker receives the opening topic after provider parsing'
    Assert-True ($bootstrap.Contains('Never invoke or fall back to Claude')) 'bootstrap reinforces the Claude-free provider boundary'
    Assert-True ($r.Out -match 'FAKE CODEX ROLE TUI') 'child TUI inherits the visible stdout stream'
    Assert-True ($r.Out -match '(?m)^TOPIC_ENV=\s*$') 'transient opening topic is removed before Codex starts'
    Assert-True ($r.Out -match ('(?m)^CODEX_HOME=' + [regex]::Escape((Join-Path $orchestraHome '.codex')) + '\s*$')) 'direct roles pass the configured Codex home to the TUI'

    $r = Invoke-RoleRuntime -Role thinker -Additional @('-RequestedProvider', 'codex') `
        -Environment @{ ORCHESTRA_CODEX_ROLE_TOPIC = '-Sandbox is topic text' }
    $captured = @(Get-Content -LiteralPath $argsFile)
    Assert-True ($captured -contains 'danger-full-access') 'opening topic cannot rebind a known runtime parameter'
    Assert-True ([string]$captured[-1] -match '\-Sandbox is topic text') 'parameter-shaped opening text remains topic data'

    $r = Invoke-RoleRuntime -Role code_auditor -Environment @{
        ORCHESTRA_CODEX_REASONING = 'xhigh'
        ORCHESTRA_CODEX_SANDBOX = 'workspace-write'
        FAKE_EXIT_CODE = '7'
    }
    Assert-True ($r.ExitCode -eq 7) 'code_auditor forwards the Codex TUI exit code'
    $captured = @(Get-Content -LiteralPath $argsFile)
    Assert-True ($captured -contains 'model_reasoning_effort="xhigh"') 'operator reasoning override reaches Codex'
    Assert-True ($captured -contains 'workspace-write') 'operator sandbox override reaches Codex'
    Assert-True ([string]$captured[-1] -match 'Start the repository source-code audit now') 'code_auditor starts its fixed workflow'

    $r = Invoke-RoleRuntime -Role enhancement_scout
    Assert-True ($r.ExitCode -eq 0) 'enhancement_scout starts successfully'
    Assert-True ([string](Get-Content -LiteralPath $argsFile | Select-Object -Last 1) -match 'Start the project enhancement analysis now') 'enhancement_scout starts its fixed workflow'

    $r = Invoke-RoleRuntime -Role thinker -Environment @{ ORCHESTRA_CODEX_REASONING = 'invalid' }
    Assert-True ($r.ExitCode -eq 2) 'invalid reasoning fails closed before Codex starts'

    $missing = Join-Path $base 'missing-role.md'
    $r = Invoke-RoleRuntime -Role thinker -PromptOverride $missing
    Assert-True ($r.ExitCode -eq 12) 'missing canonical prompt fails closed'
} finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "test-codex-role-runtime: $($failures.Count) failure(s):"
    foreach ($failure in $failures) { Write-Host "  $failure" }
    exit 1
}
Write-Host 'OK - direct analytical roles open the inherited Codex TUI, load canonical prompts, and preserve provider configuration and exit status.'
