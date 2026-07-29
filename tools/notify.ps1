<#
.SYNOPSIS
    Sends one bounded, redacted operator notification for a human-attention event.

.DESCRIPTION
    `NOTIFY_CMD` is an explicitly operator-owned command in `<work>/config.md`. When it is
    unset, this tool is a successful no-op. When set, `send` first runs the supplied text through
    `redaction.ps1`, collapses it to a short single line, then appends the event and that safe
    text as the final two arguments to NOTIFY_CMD. The command itself runs once through
    `supervisor.ps1 run` with a fixed short deadline.

    Delivery is deliberately best-effort: disabled, redaction-unavailable, timeout and command
    failure all return a structured result with process exit 0. The processor records that safe
    result in its journal and continues its normal state transition. Invalid caller arguments are
    usage errors (exit 2), because silently changing the event type would hide a bad integration.

    No raw notification command output, original text, or redaction error is emitted or written.
    The caller receives only `event`, `status`, `reason`, and the supervised duration.

.EXAMPLE
    pwsh -File tools/notify.ps1 send --work .work --root . --event task.escalated --text "T-17 needs an operator" --json
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'proc-tree.ps1')
$script:ErrPrefix = 'NTFERR'
$script:AllowedEvents = @('task.escalated', 'approval.pending', 'publish.ci_failed')
$script:DeadlineSec = 10
$script:OutputMaxBytes = 4096
$script:TextLimit = 400
# A notification must never wait longer for redaction than it can wait for delivery itself.
$script:RedactionDeadlineMs = 5000

$parsed = Parse-CliArgs $args -BoolFlags @('json')
$Command = $parsed.Command
$opts = $parsed.Opts

function Get-ConfigValue {
    param([string]$Work, [string]$Key)
    $file = Join-Path $Work 'config.md'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return '' }
    foreach ($line in (Get-Content -LiteralPath $file -Encoding UTF8)) {
        $entry = ConvertFrom-OrchestraConfigLine -Line ([string]$line)
        if ($null -ne $entry -and [string]::Equals($entry.Key, $Key, [System.StringComparison]::Ordinal)) { return $entry.Value }
    }
    return ''
}

function ConvertTo-PosixShellLiteral {
    param([string]$Text)
    # POSIX's single-quote escape is '"'"': terminate the quote, emit one literal apostrophe
    # inside double quotes, then resume the single-quoted literal. Keep untrusted text out of
    # the operator's command syntax even though the command itself is intentionally trusted.
    $apostrophe = [string][char]39
    $replacement = $apostrophe + '"' + $apostrophe + '"' + $apostrophe
    return $apostrophe + $Text.Replace($apostrophe, $replacement) + $apostrophe
}

function Get-RedactedShortText {
    param([string]$Text, [string]$Work)
    $redactor = Join-Path $PSScriptRoot 'redaction.ps1'
    if (-not (Test-Path -LiteralPath $redactor -PathType Leaf)) { return $null }
    $psExe = ([System.Diagnostics.Process]::GetCurrentProcess()).MainModule.FileName
    if ([string]::IsNullOrWhiteSpace($psExe)) { return $null }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($a in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $redactor, 'redact', '--stdin', '--work', $Work)) { $psi.ArgumentList.Add($a) }
    $process = $null
    # The redactor can exit while a helper retains an inherited output pipe. Give it a
    # dedicated POSIX process group so cleanup can reach that reparented helper; Windows
    # receives $null from Resolve-SetsidLauncher and retains its ordinary launch behavior.
    $setsidLauncher = Resolve-SetsidLauncher
    if ($setsidLauncher) {
        $redactorArgs = @($psi.ArgumentList)
        $psi.FileName = $setsidLauncher
        $psi.ArgumentList.Clear()
        $psi.ArgumentList.Add($psExe)
        foreach ($arg in $redactorArgs) { $psi.ArgumentList.Add($arg) }
    }
    $posixPgid = 0
    try {
        $process = [System.Diagnostics.Process]::Start($psi)
        if ($setsidLauncher) { $posixPgid = [int]$process.Id }
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($Text); $process.StandardInput.Close()
        if (-not $process.WaitForExit($script:RedactionDeadlineMs)) {
            # Do not pass unredacted text to the operator command after a redaction timeout.
            # Stop-ProcessTree includes the Windows PowerShell 5.1 taskkill /T fallback and
            # waits for the captured process after requesting the full tree's termination.
            Stop-ProcessTree $process -PosixProcessGroupId $posixPgid
            return $null
        }
        $out = ''
        try {
            if (-not $outTask.Wait($script:RedactionDeadlineMs)) {
                # An inherited stdout handle can keep ReadToEndAsync pending after the root
                # exits. Reap the captured redactor tree before returning the safe fallback.
                Stop-ProcessTree $process -PosixProcessGroupId $posixPgid
                return $null
            }
            $out = [string]$outTask.GetAwaiter().GetResult()
        } catch {
            Stop-ProcessTree $process -PosixProcessGroupId $posixPgid
            return $null
        }
        if ($process.ExitCode -ne 0) {
            Stop-ProcessTree $process -PosixProcessGroupId $posixPgid
            return $null
        }
    }
    catch {
        # This covers input/stream errors after the redactor has started as well as startup
        # failures. Stop-ProcessTree is a no-op for a null process.
        Stop-ProcessTree $process -PosixProcessGroupId $posixPgid
        return $null
    }
    finally {
        if ($null -ne $process) { try { $process.Dispose() } catch { } }
    }
    $short = [regex]::Replace($out, '\s+', ' ').Trim()
    if ($short.Length -gt $script:TextLimit) {
        $short = $short.Substring(0, $script:TextLimit - 3) + '...'
    }
    return $short
}

function Write-Result {
    param([string]$EventType, [string]$Status, [string]$Reason, [int]$DurationMs = 0)
    $result = [ordered]@{
        schema      = 'orchestra/notification@1'
        event       = $EventType
        status      = $Status
        reason      = $Reason
        duration_ms = $DurationMs
    }
    if ([bool](Opt 'json' $false)) {
        Write-Output ($result | ConvertTo-Json -Compress)
    } else {
        Write-Output "notification event=$EventType status=$Status reason=$Reason duration_ms=$DurationMs"
    }
}

function Cmd-Send {
    $work = Require-Opt 'work'
    $eventType = Require-Opt 'event'
    $text = Require-Opt 'text'
    if ($eventType -notin $script:AllowedEvents) {
        Fail 2 "--event must be one of: $($script:AllowedEvents -join ', ')"
    }
    if ([string]::IsNullOrWhiteSpace($text)) { Fail 2 '--text must not be empty' }
    if (-not (Test-Path -LiteralPath $work -PathType Container)) { Fail 2 "--work is not a directory: $work" }

    $command = Get-ConfigValue -Work $work -Key 'NOTIFY_CMD'
    if ([string]::IsNullOrWhiteSpace($command)) {
        Write-Result -EventType $eventType -Status 'disabled' -Reason 'not-configured'
        return
    }

    $safeText = Get-RedactedShortText -Text $text -Work $work
    if ($null -eq $safeText) {
        Write-Result -EventType $eventType -Status 'failed' -Reason 'redaction-unavailable'
        return
    }

    $root = [string](Opt 'root' '')
    if ([string]::IsNullOrWhiteSpace($root)) { $root = Split-Path -Parent ([System.IO.Path]::GetFullPath($work)) }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        Fail 2 "--root is not a directory: $root"
    }

    $shellCommand = $command + ' ' + (ConvertTo-PosixShellLiteral $eventType) + ' ' + (ConvertTo-PosixShellLiteral $safeText)
    $supervisor = Join-Path $PSScriptRoot 'supervisor.ps1'
    if (-not (Test-Path -LiteralPath $supervisor -PathType Leaf)) {
        Write-Result -EventType $eventType -Status 'failed' -Reason 'supervisor-unavailable'
        return
    }
    $psExe = ([System.Diagnostics.Process]::GetCurrentProcess()).MainModule.FileName
    if ([string]::IsNullOrWhiteSpace($psExe)) {
        Write-Result -EventType $eventType -Status 'failed' -Reason 'supervisor-unavailable'
        return
    }
    $supervisorArgs = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $supervisor, 'run',
        '--shell-command', $shellCommand,
        '--working-directory', $root,
        '--deadline-sec', "$($script:DeadlineSec)",
        '--output-max-bytes', "$($script:OutputMaxBytes)",
        '--json'
    )
    $raw = @(& $psExe @supervisorArgs 2>$null)
    $exitCode = $LASTEXITCODE
    $verdict = $null
    try { $verdict = (($raw -join "`n") | ConvertFrom-Json) } catch { }
    $reason = if ($verdict -and $verdict.PSObject.Properties['reason']) { [string]$verdict.reason } else { 'supervisor-unavailable' }
    $duration = if ($verdict -and $verdict.PSObject.Properties['duration_ms']) { [int]$verdict.duration_ms } else { 0 }
    if ($exitCode -eq 0 -and $reason -eq 'ok') {
        Write-Result -EventType $eventType -Status 'sent' -Reason 'ok' -DurationMs $duration
    } else {
        Write-Result -EventType $eventType -Status 'failed' -Reason $reason -DurationMs $duration
    }
}

try {
    switch ($Command) {
        'send' { Cmd-Send }
        'version' { Write-Output 'orchestra-notify 1' }
        default { Fail 2 "unknown command '$Command'. Valid: send, version" }
    }
} catch {
    exit (Resolve-CatchExit $_ 'NTFERR' 'notify' 'NOTIFY_DEBUG')
}
