<#
.SYNOPSIS
    Deterministic cross-platform tests for the global project registry and project inbox.

.DESCRIPTION
    Uses two temporary repositories and an explicit test-local registry. Covers
    idempotent registration, sender identity, routing, status transitions, remarks,
    queue-source reconciliation, both archive-header forms, actionable completion, and
    idempotent final replies. No real user registry or repository is touched.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ('orchestra-inbox-test-' + [guid]::NewGuid().ToString('N'))
$script:RepoA = Join-Path $script:Root 'sender-repo'
$script:RepoB = Join-Path $script:Root 'receiver-repo'
$script:Registry = Join-Path $script:Root 'profile/projects.json'
$script:RegistryTool = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\project-registry.ps1')).Path
$script:InboxTool = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\inbox.ps1')).Path
$script:Pwsh = ([System.Diagnostics.Process]::GetCurrentProcess()).MainModule.FileName
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Failures = [System.Collections.Generic.List[string]]::new()

function Write-TestFile {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Force -Path $parent }
    [System.IO.File]::WriteAllText($Path, $Content, $script:Utf8)
}

function Invoke-Tool {
    param([string]$Tool, [string[]]$ToolArgs)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:Pwsh
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8
    $psi.StandardErrorEncoding = $script:Utf8
    foreach ($arg in (@('-NoProfile', '-File', $Tool) + $ToolArgs)) { $psi.ArgumentList.Add($arg) }
    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Out = $stdout.Result; Err = $stderr.Result }
}

function Invoke-Registry { param([string[]]$ToolArgs) return (Invoke-Tool $script:RegistryTool (@($ToolArgs) + @('--registry', $script:Registry))) }
function Invoke-Inbox { param([string[]]$ToolArgs) return (Invoke-Tool $script:InboxTool (@($ToolArgs) + @('--registry', $script:Registry))) }
function Assert-True { param([bool]$Value, [string]$Message) if (-not $Value) { $script:Failures.Add("FAIL - $Message") } }
function Assert-Equal { param($Expected, $Actual, [string]$Message) if ($Expected -ne $Actual) { $script:Failures.Add("FAIL - ${Message}: expected [$Expected], got [$Actual]") } }
function Assert-Exit { param($Result, [int]$Expected, [string]$Message) if ($Result.ExitCode -ne $Expected) { $script:Failures.Add("FAIL - ${Message}: expected exit $Expected, got $($Result.ExitCode); err=[$($Result.Err.Trim())] out=[$($Result.Out.Trim())]") } }

try {
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        $previousParsePath = [Environment]::GetEnvironmentVariable('ORCHESTRA_PS5_PARSE_PATH')
        try {
            [Environment]::SetEnvironmentVariable('ORCHESTRA_PS5_PARSE_PATH', $script:InboxTool)
            $parseOutput = & powershell -NoProfile -Command '$ErrorActionPreference="Stop"; $p=[Environment]::GetEnvironmentVariable("ORCHESTRA_PS5_PARSE_PATH"); [void][scriptblock]::Create([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8))' 2>&1
            Assert-Equal 0 $LASTEXITCODE "inbox runtime parses under Windows PowerShell 5.1 (output: $($parseOutput -join ' '))"
        } finally {
            [Environment]::SetEnvironmentVariable('ORCHESTRA_PS5_PARSE_PATH', $previousParsePath)
        }
    }
    $null = New-Item -ItemType Directory -Force -Path $script:RepoA, $script:RepoB

    $a1 = Invoke-Registry @('register', '--root', $script:RepoA, '--name', 'Sender', '--ensure-inbox', '--json')
    $b1 = Invoke-Registry @('register', '--root', $script:RepoB, '--name', 'Receiver', '--ensure-inbox', '--json')
    $a2 = Invoke-Registry @('register', '--root', $script:RepoA, '--name', 'Sender', '--ensure-inbox', '--json')
    Assert-Exit $a1 0 'register sender'
    Assert-Exit $b1 0 'register receiver'
    Assert-Exit $a2 0 'repeat sender registration is idempotent'
    if ($a1.ExitCode -ne 0 -or $b1.ExitCode -ne 0 -or $a2.ExitCode -ne 0) {
        throw "registration failed: a1=[$($a1.Err)] b1=[$($b1.Err)] a2=[$($a2.Err)]"
    }
    Assert-True (Test-Path -LiteralPath (Join-Path $script:RepoA '.inbox/messages') -PathType Container) 'sender inbox created'
    Assert-True (Test-Path -LiteralPath (Join-Path $script:RepoB '.inbox/messages') -PathType Container) 'receiver inbox created'

    $list = Invoke-Registry @('list', '--json')
    Assert-Exit $list 0 'list registry'
    $registryState = $list.Out | ConvertFrom-Json
    Assert-Equal 2 (@($registryState.projects).Count) 'repeat registration does not duplicate the project'
    Assert-Equal 3 ([int]$registryState.generation) 'each successful registration advances generation'
    $senderProject = @($registryState.projects | Where-Object name -eq 'Sender')[0]
    $receiver = @($registryState.projects | Where-Object name -eq 'Receiver')[0]
    Assert-True ([string]$senderProject.id -match '^repo-[a-f0-9]{20}$') 'sender has stable path-derived id'
    Assert-True ([string]$receiver.id -match '^repo-[a-f0-9]{20}$') 'receiver has stable path-derived id'

    $bodyPath = Join-Path $script:Root 'request.md'
    Write-TestFile $bodyPath "Observed repeated friction in the shared API.`nPlease evaluate an upstream capability; alternatives are acceptable."
    $send = Invoke-Inbox @('send', '--root', $script:RepoA, '--to', 'Receiver', '--subject', 'Evaluate shared API capability', '--body-file', $bodyPath, '--json')
    Assert-Exit $send 0 'send cross-project request'
    if ($send.ExitCode -ne 0) { throw "send failed: $($send.Err) $($send.Out)" }
    $sent = $send.Out | ConvertFrom-Json
    $messageId = [string]$sent.id
    Assert-Equal ([string]$senderProject.id) ([string]$sent.from_project.id) 'sender identity is registry-derived'
    Assert-Equal 'Sender' ([string]$sent.from_project.name) 'sender name is included automatically'
    Assert-Equal ([string]$receiver.id) ([string]$sent.to_project.id) 'destination identity is registry-derived'

    $newList = Invoke-Inbox @('list', '--root', $script:RepoB, '--status', 'new', '--json')
    Assert-Exit $newList 0 'list new messages'
    Assert-Equal 1 ([int](($newList.Out | ConvertFrom-Json).count)) 'receiver sees one new message'

    $invalid = Invoke-Inbox @('mark', '--root', $script:RepoB, '--id', $messageId, '--status', 'queued', '--task', 'T-101')
    Assert-Exit $invalid 6 'new -> queued transition is rejected until critical review marks read'

    $read = Invoke-Inbox @('mark', '--root', $script:RepoB, '--id', $messageId, '--status', 'read', '--remark', 'Evidence validated; two local deliveries are required.', '--actor', 'inbox_curator')
    Assert-Exit $read 0 'mark message read with assessment remark'

    $queue = @"
### [T-101] First delivery — статус: не начата
Inbox message: $messageId

Implement the first independently reviewable part.

### [T-102] Second delivery — статус: не начата
Inbox message: $messageId

Implement the second independently reviewable part.
"@
    Write-TestFile (Join-Path $script:RepoB '.work/Tasks_Queue.md') $queue
    $reconcile = Invoke-Inbox @('reconcile', '--root', $script:RepoB, '--json')
    Assert-Exit $reconcile 0 'reconcile queue provenance into message state'
    if ($reconcile.ExitCode -ne 0) { throw "reconcile failed: $($reconcile.Err) $($reconcile.Out)" }
    Assert-Equal 1 ([int](($reconcile.Out | ConvertFrom-Json).count)) 'one message reconciled'
    $queued = (Invoke-Inbox @('show', '--root', $script:RepoB, '--id', $messageId, '--json')).Out | ConvertFrom-Json
    Assert-Equal 'queued' ([string]$queued.processing_status) 'read message becomes queued after task allocation'
    Assert-Equal 'T-101,T-102' ((@($queued.queue_tasks) | Sort-Object) -join ',') 'all derived tasks are linked to the message'
    Assert-True (@($queued.remarks).Count -ge 2) 'assessment and automatic queue-link remarks are retained'

    $beforeDoneResult = Invoke-Inbox @('actionable', '--root', $script:RepoB, '--json')
    if ($beforeDoneResult.ExitCode -ne 0) { throw "actionable before completion failed: $($beforeDoneResult.Err) $($beforeDoneResult.Out)" }
    $beforeDone = $beforeDoneResult.Out | ConvertFrom-Json
    Assert-Equal 0 ([int]$beforeDone.count) 'queued work is not completable before archive evidence exists'

    $done = @"
## [T-101] First delivery
completed

# Активная задача T-102
completed
"@
    Write-TestFile (Join-Path $script:RepoB '.work/Tasks_Done.md') $done
    $afterDone = (Invoke-Inbox @('actionable', '--root', $script:RepoB, '--json')).Out | ConvertFrom-Json
    Assert-Equal 1 ([int]$afterDone.count) 'completed linked tasks make the message actionable'
    if (@($afterDone.completable).Count -gt 0) {
        Assert-Equal $messageId ([string]$afterDone.completable[0]) 'both H2 bracket and active-task archive headers resolve completion'
    }

    $implemented = Invoke-Inbox @('mark', '--root', $script:RepoB, '--id', $messageId, '--status', 'implemented', '--remark', 'Both linked deliveries are archived.', '--actor', 'inbox_curator')
    Assert-Exit $implemented 0 'queued -> implemented'
    $implementedState = (Invoke-Inbox @('show', '--root', $script:RepoB, '--id', $messageId, '--json')).Out | ConvertFrom-Json
    $remarkCountBeforeReply = @($implementedState.remarks).Count
    $replyBody = Join-Path $script:Root 'reply.md'
    Write-TestFile $replyBody 'Implemented through T-101 and T-102 after repository-local review.'
    $reply1 = Invoke-Inbox @('reply', '--root', $script:RepoB, '--id', $messageId, '--reply-status', 'final', '--dedupe-key', 'final-v1', '--body-file', $replyBody, '--actor', 'inbox_curator', '--json')
    $reply2 = Invoke-Inbox @('reply', '--root', $script:RepoB, '--id', $messageId, '--reply-status', 'final', '--dedupe-key', 'final-v1', '--body-file', $replyBody, '--actor', 'inbox_curator', '--json')
    Assert-Exit $reply1 0 'send final reply'
    Assert-Exit $reply2 0 'retry final reply is idempotent'
    $reply = $reply1.Out | ConvertFrom-Json
    Assert-Equal $messageId ([string]$reply.in_reply_to) 'reply links to original message'
    Assert-Equal $messageId ([string]$reply.conversation_id) 'reply retains the original conversation id'
    $senderInbox = (Invoke-Inbox @('list', '--root', $script:RepoA, '--status', 'new', '--json')).Out | ConvertFrom-Json
    Assert-Equal 1 ([int]$senderInbox.count) 'idempotent retry creates one response message'
    $replyRead = Invoke-Inbox @('mark', '--root', $script:RepoA, '--id', ([string]$reply.id), '--status', 'read', '--remark', 'Final upstream outcome recorded.', '--actor', 'inbox_curator')
    Assert-Exit $replyRead 0 'incoming reply can be marked read'
    $senderActionable = (Invoke-Inbox @('actionable', '--root', $script:RepoA, '--json')).Out | ConvertFrom-Json
    Assert-Equal 0 ([int]$senderActionable.count) 'a read reply is not reprocessed as an unresolved request'
    $finalOriginal = (Invoke-Inbox @('show', '--root', $script:RepoB, '--id', $messageId, '--json')).Out | ConvertFrom-Json
    Assert-Equal 'final' ([string]$finalOriginal.reply_status) 'original message records final reply status'
    Assert-Equal 1 (@($finalOriginal.reply_ids).Count) 'original stores one reply id after retry'
    Assert-Equal ($remarkCountBeforeReply + 1) (@($finalOriginal.remarks).Count) 'idempotent reply retry does not append a duplicate remark'

    Write-TestFile $replyBody 'Conflicting content under the same dedupe key.'
    $conflict = Invoke-Inbox @('reply', '--root', $script:RepoB, '--id', $messageId, '--reply-status', 'final', '--dedupe-key', 'final-v1', '--body-file', $replyBody)
    Assert-Exit $conflict 6 'same reply dedupe key cannot overwrite different content'
}
finally {
    Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures.Count -eq 0) {
    Write-Host 'OK - project registry and cross-project inbox tests passed.'
    exit 0
}
Write-Host "FAILED - $($script:Failures.Count) assertion(s):"
foreach ($failure in $script:Failures) { Write-Host "  $failure" }
exit 1
