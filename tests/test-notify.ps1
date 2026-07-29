<#
.SYNOPSIS
    Deterministic, offline contract tests for tools/notify.ps1.

.DESCRIPTION
    Verifies that the optional notification hook is disabled by default, redacts text before an
    operator command receives it, passes only event + safe text as final argv, contains a failed
    command through supervisor, and rejects an unknown event rather than silently relabelling it.

    Usage: pwsh -File tests/test-notify.ps1
#>

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$script:Tool = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\notify.ps1')).Path
$script:PsExe = ([System.Diagnostics.Process]::GetCurrentProcess()).MainModule.FileName
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Failures = [System.Collections.Generic.List[string]]::new()

function New-TempDir {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('orchestra-notify-test-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    return $path
}
function Write-Utf8 { param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8)
}
function Invoke-Notify { param([string[]]$ToolArgs)
    $out = @(& $script:PsExe -NoProfile -File $script:Tool @ToolArgs 2>&1)
    $exitCode = $LASTEXITCODE
    # This helper deliberately exercises rejected tool invocations. Preserve their code for the
    # assertion, but do not leak it to a CI wrapper that invokes this test via `& $p`.
    Set-Variable -Name LASTEXITCODE -Value 0 -Scope Global
    return [pscustomobject]@{ ExitCode = $exitCode; Output = ($out -join "`n") }
}
function Assert-Equal { param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { $script:Failures.Add("FAIL - ${Message}: expected [$Expected], got [$Actual]") }
}
function Assert-True { param([bool]$Condition, [string]$Message)
    if (-not $Condition) { $script:Failures.Add("FAIL - $Message") }
}
function Assert-Contains { param([string]$Haystack, [string]$Needle, [string]$Message)
    if (-not $Haystack.Contains($Needle)) { $script:Failures.Add("FAIL - ${Message}: missing [$Needle]") }
}
function Assert-NotContains { param([string]$Haystack, [string]$Needle, [string]$Message)
    if ($Haystack.Contains($Needle)) { $script:Failures.Add("FAIL - ${Message}: unexpectedly found [$Needle]") }
}

$root = New-TempDir
try {
    $work = Join-Path $root '.work'
    New-Item -ItemType Directory -Force -Path $work | Out-Null

    $disabled = Invoke-Notify @('send', '--work', $work, '--root', $root, '--event', 'task.escalated', '--text', 'T-17 needs an operator', '--json')
    Assert-Equal 0 $disabled.ExitCode 'unset NOTIFY_CMD is a successful no-op'
    $disabledJson = $disabled.Output | ConvertFrom-Json
    Assert-Equal 'disabled' ([string]$disabledJson.status) 'unset NOTIFY_CMD reports disabled'
    Assert-Equal 'not-configured' ([string]$disabledJson.reason) 'unset NOTIFY_CMD has explicit reason'

    # `supervisor --shell-command` uses bash. The explicitly operator-owned command invokes a
    # tiny POSIX fixture that writes its first two notification arguments to a capture file.
    $capture = Join-Path $root 'captured.txt'
    $scriptPath = Join-Path $root 'capture#fast.sh'
    Write-Utf8 $scriptPath @'
#!/bin/sh
printf '%s|%s' "$2" "$3" > "$1"
printf '%s' 'fixture-output-must-not-leak'
'@
    $posixScript = $scriptPath.Replace('\', '/')
    $posixCapture = $capture.Replace('\', '/')
    Write-Utf8 (Join-Path $work 'config.md') (("NOTIFY_CMD: sh '{0}' '{1}'" -f $posixScript, $posixCapture) + ' # operator hook')

    $secret = 'AKIAIOSFODNN7EXAMPLE'
    $sent = Invoke-Notify @('send', '--work', $work, '--root', $root, '--event', 'task.escalated', '--text', "operator's CI report carries $secret", '--json')
    Assert-Equal 0 $sent.ExitCode 'supervised successful notification still returns success'
    $sentJson = $sent.Output | ConvertFrom-Json
    Assert-Equal 'sent' ([string]$sentJson.status) 'successful operator command is sent'
    Assert-Equal 'ok' ([string]$sentJson.reason) 'successful operator command preserves only safe verdict'
    $captured = Get-Content -LiteralPath $capture -Raw -Encoding utf8
    Assert-Contains $captured 'task.escalated|' 'operator command receives the exact event as first appended argv'
    Assert-Contains $captured '[redacted:aws-access-key:' 'operator command receives a redaction marker'
    Assert-Contains $captured "operator's CI report" 'single quote in the redacted text stays data, not shell syntax'
    Assert-NotContains $captured $secret 'operator command never receives the raw secret'
    Assert-NotContains $sent.Output $secret 'notify result never echoes the raw text'
    Assert-NotContains $sent.Output 'fixture-output-must-not-leak' 'notify result never forwards operator stdout'

    Write-Utf8 (Join-Path $work 'constraints.md') ('## Redaction patterns' + "`n" + '- (a+)+$')
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $redactionTimeout = Invoke-Notify @('send', '--work', $work, '--root', $root, '--event', 'task.escalated', '--text', (('a' * 20000) + '!'), '--json')
    $timer.Stop()
    Assert-Equal 0 $redactionTimeout.ExitCode 'redaction timeout remains a best-effort notification result'
    $redactionTimeoutJson = $redactionTimeout.Output | ConvertFrom-Json
    Assert-Equal 'failed' ([string]$redactionTimeoutJson.status) 'redaction timeout is reported as failed'
    Assert-Equal 'redaction-unavailable' ([string]$redactionTimeoutJson.reason) 'redaction timeout has the documented safe reason'
    Assert-True ($timer.Elapsed.TotalSeconds -lt 12) 'notify redaction timeout remains bounded'
    Remove-Item -LiteralPath (Join-Path $work 'constraints.md') -Force

    Write-Utf8 (Join-Path $work 'config.md') 'NOTIFY_CMD: false'
    $failed = Invoke-Notify @('send', '--work', $work, '--root', $root, '--event', 'approval.pending', '--text', 'approval apr-1 requires an operator', '--json')
    Assert-Equal 0 $failed.ExitCode 'failed operator command does not fail the processor-facing hook'
    $failedJson = $failed.Output | ConvertFrom-Json
    Assert-Equal 'failed' ([string]$failedJson.status) 'failed operator command is visible as failed'
    Assert-Equal 'error' ([string]$failedJson.reason) 'failed command retains only the supervisor classification'

    $invalid = Invoke-Notify @('send', '--work', $work, '--root', $root, '--event', 'made.up', '--text', 'bad event', '--json')
    Assert-Equal 2 $invalid.ExitCode 'unknown event is a usage error, never a silently mislabelled notification'
    Assert-Contains $invalid.Output '--event must be one of' 'unknown event lists the stable allowed set'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures.Count -gt 0) {
    Write-Host "test-notify: $($script:Failures.Count) failure(s):"
    foreach ($failure in $script:Failures) { Write-Host "  $failure" }
    exit 1
}
Write-Host 'OK - tools/notify.ps1 redacts, supervises and contains the optional operator notification hook.'
