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
. (Join-Path $PSScriptRoot '..\tools\common.ps1')

$script:Tool = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\notify.ps1')).Path
$script:PsExe = Get-PowerShellHostExecutable
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Failures = [System.Collections.Generic.List[string]]::new()
$fixtureChildPid = 0

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
function Invoke-Notify { param([string[]]$ToolArgs, [string]$Tool = $script:Tool)
    $out = @(& $script:PsExe -NoProfile -File $Tool @ToolArgs 2>&1)
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

    # A dedicated fixture redactor deterministically creates a sleeping child and then hangs.
    # The timeout path must reap BOTH the redactor and that child before returning. Copying the
    # small notify dependency set keeps production script resolution unchanged while allowing
    # the fixture redactor to occupy the normal sibling path used by notify.ps1.
    $fixtureTools = Join-Path $root 'fixture-tools'
    New-Item -ItemType Directory -Force -Path $fixtureTools | Out-Null
    foreach ($name in @('notify.ps1', 'common.ps1', 'proc-tree.ps1')) {
        Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $script:Tool) $name) -Destination (Join-Path $fixtureTools $name)
    }
    $childScript = Join-Path $fixtureTools 'fixture-child.ps1'
    Write-Utf8 $childScript 'Start-Sleep -Seconds 120'
    $childPidFile = Join-Path $work 'redactor-child.pid'
    $enteredFile = Join-Path $work 'redactor-entered.marker'
    $env:ORCHESTRA_NOTIFY_FIXTURE_CHILD_PID_FILE = $childPidFile
    $env:ORCHESTRA_NOTIFY_FIXTURE_ENTERED_FILE = $enteredFile
    Write-Utf8 (Join-Path $fixtureTools 'redaction.ps1') @'
. (Join-Path $PSScriptRoot 'common.ps1')
[System.IO.File]::WriteAllText($env:ORCHESTRA_NOTIFY_FIXTURE_ENTERED_FILE, 'entered')
$psExe = Get-PowerShellHostExecutable
$child = Start-Process -FilePath $psExe -ArgumentList @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'fixture-child.ps1')) -PassThru
[System.IO.File]::WriteAllText($env:ORCHESTRA_NOTIFY_FIXTURE_CHILD_PID_FILE, [string]$child.Id)
Start-Sleep -Seconds 120
'@
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $redactionTimeout = Invoke-Notify -Tool (Join-Path $fixtureTools 'notify.ps1') -ToolArgs @('send', '--work', $work, '--root', $root, '--event', 'task.escalated', '--text', 'fixture timeout', '--json')
    $timer.Stop()
    Assert-Equal 0 $redactionTimeout.ExitCode 'redaction timeout remains a best-effort notification result'
    $redactionTimeoutJson = $redactionTimeout.Output | ConvertFrom-Json
    Assert-Equal 'failed' ([string]$redactionTimeoutJson.status) 'redaction timeout is reported as failed'
    Assert-Equal 'redaction-unavailable' ([string]$redactionTimeoutJson.reason) 'redaction timeout has the documented safe reason'
    # Five seconds are reserved for redaction and Stop-ProcessTree itself waits up to five
    # more seconds for teardown; leave startup/scheduling headroom without permitting an
    # unbounded wait.
    Assert-True ($timer.Elapsed.TotalSeconds -lt 15) 'notify redaction timeout remains bounded'
    Assert-True (Test-Path -LiteralPath $enteredFile -PathType Leaf) 'fixture redactor was invoked before timing out'
    Assert-True (Test-Path -LiteralPath $childPidFile -PathType Leaf) 'fixture redactor recorded its child PID before timing out'
    if (Test-Path -LiteralPath $childPidFile -PathType Leaf) {
        $fixtureChildPid = [int][System.IO.File]::ReadAllText($childPidFile).Trim()
        Start-Sleep -Milliseconds 200
        Assert-True ($null -eq (Get-Process -Id $fixtureChildPid -ErrorAction SilentlyContinue)) 'redaction timeout leaves no surviving child redactor process'
    }
    Remove-Item Env:ORCHESTRA_NOTIFY_FIXTURE_CHILD_PID_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:ORCHESTRA_NOTIFY_FIXTURE_ENTERED_FILE -ErrorAction SilentlyContinue

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
    if ($fixtureChildPid -gt 0) { Stop-Process -Id $fixtureChildPid -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:ORCHESTRA_NOTIFY_FIXTURE_CHILD_PID_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:ORCHESTRA_NOTIFY_FIXTURE_ENTERED_FILE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures.Count -gt 0) {
    Write-Host "test-notify: $($script:Failures.Count) failure(s):"
    foreach ($failure in $script:Failures) { Write-Host "  $failure" }
    exit 1
}
Write-Host 'OK - tools/notify.ps1 redacts, supervises and contains the optional operator notification hook.'
