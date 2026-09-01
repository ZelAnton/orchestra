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
. (Join-Path $PSScriptRoot '..\tools\common.ps1')

$script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ('orchestra-inbox-test-' + [guid]::NewGuid().ToString('N'))
$script:RepoA = Join-Path $script:Root 'sender-repo'
$script:RepoB = Join-Path $script:Root 'receiver-repo'
$script:RepoC = Join-Path $script:Root 'unrelated-repo'
$script:RepoD = Join-Path $script:Root 'retired-repo'
$script:RepoE = Join-Path $script:Root 'never-audited-repo'
$script:Registry = Join-Path $script:Root 'profile/projects.json'
$script:RegistryTool = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\project-registry.ps1')).Path
$script:InboxTool = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\inbox.ps1')).Path
$script:Pwsh = Get-PowerShellHostExecutable
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

function Get-ExpectedReleaseMessageId {
    # Independently re-derives the documented deterministic per-target fan-out id
    # (sender id, target id, dedupe key "release:<release-id>") instead of trusting the
    # id the tool reports back, so an added target can be proved to reuse it.
    param([string]$FromId, [string]$ToId, [string]$ReleaseId)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($script:Utf8.GetBytes("$FromId|$ToId|release:$ReleaseId")) }
    finally { $sha.Dispose() }
    $hex = -join ($hash | ForEach-Object { $_.ToString('x2') })
    return 'msg-send-' + $hex.Substring(0, 32)
}

function Get-ReleaseRecordFile {
    param([string]$Root, [string]$Version)
    return @(Get-ChildItem -LiteralPath (Join-Path $Root '.inbox/releases') -File -Filter 'rel-*.json') |
        ForEach-Object { [pscustomobject]@{ Path = $_.FullName; Record = ([System.IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json) } } |
        Where-Object { [string]$_.Record.version -eq $Version } | Select-Object -First 1
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
    $null = New-Item -ItemType Directory -Force -Path $script:RepoA, $script:RepoB, $script:RepoD

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
    Assert-True (Test-Path -LiteralPath (Join-Path $script:RepoA '.inbox/releases') -PathType Container) 'sender release audit directory created'

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

    $sentPath = Join-Path $script:RepoB ('.inbox/messages/' + $messageId + '.json')
    $corrupt = [System.IO.File]::ReadAllText($sentPath) | ConvertFrom-Json
    $corrupt.from_project.name = "Sender`nInjected"
    Write-TestFile $sentPath ($corrupt | ConvertTo-Json -Depth 12)
    $invalidEndpoint = Invoke-Inbox @('show', '--root', $script:RepoB, '--id', $messageId, '--json')
    Assert-Exit $invalidEndpoint 5 'message endpoint display names reject control characters'
    $corrupt.from_project.name = 'Sender'
    Write-TestFile $sentPath ($corrupt | ConvertTo-Json -Depth 12)

    $newList = Invoke-Inbox @('list', '--root', $script:RepoB, '--status', 'new', '--json')
    Assert-Exit $newList 0 'list new messages'
    Assert-Equal 1 ([int](($newList.Out | ConvertFrom-Json).count)) 'receiver sees one new message'
    $humanShow = Invoke-Inbox @('show', '--root', $script:RepoB, '--id', $messageId)
    Assert-Exit $humanShow 0 'show renders a human-readable message without --json'
    Assert-True ($humanShow.Out -match ('id=' + [regex]::Escape($messageId))) 'human show includes message identity'
    Assert-True ($humanShow.Out -match 'body:') 'human show labels the message body'

    # Aggregate operations retain valid messages and expose diagnostics when another
    # cross-project writer leaves a stale or malformed record in the inbox.
    $brokenMessageId = 'msg-corrupt-0001'
    Write-TestFile (Join-Path $script:RepoB ('.inbox/messages/' + $brokenMessageId + '.json')) '{not-json'
    $listWithBrokenRecord = Invoke-Inbox @('list', '--root', $script:RepoB, '--json')
    Assert-Exit $listWithBrokenRecord 0 'list skips a malformed unrelated message record'
    $listWithBrokenProjection = $listWithBrokenRecord.Out | ConvertFrom-Json
    Assert-Equal 1 ([int]$listWithBrokenProjection.count) 'list keeps valid messages when another record is malformed'
    Assert-Equal $brokenMessageId ([string]$listWithBrokenProjection.errors[0].id) 'list identifies the skipped malformed record'

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

### [T-999] Unrelated task — status: not started
No inbox provenance.

### [P-001] Non-executable proposal — kind: proposal — status: proposed
Inbox message: $messageId
"@
    Write-TestFile (Join-Path $script:RepoB '.work/Tasks_Queue.md') $queue
    $reconcile = Invoke-Inbox @('reconcile', '--root', $script:RepoB, '--json')
    Assert-Exit $reconcile 0 'reconcile queue provenance into message state'
    if ($reconcile.ExitCode -ne 0) { throw "reconcile failed: $($reconcile.Err) $($reconcile.Out)" }
    Assert-Equal 1 ([int](($reconcile.Out | ConvertFrom-Json).count)) 'one message reconciled'
    Assert-Equal $brokenMessageId ([string](($reconcile.Out | ConvertFrom-Json).errors[0].id)) 'reconcile reports but skips the malformed record'
    $queued = (Invoke-Inbox @('show', '--root', $script:RepoB, '--id', $messageId, '--json')).Out | ConvertFrom-Json
    Assert-Equal 'queued' ([string]$queued.processing_status) 'read message becomes queued after task allocation'
    Assert-Equal 'T-101,T-102' ((@($queued.queue_tasks) | Sort-Object) -join ',') 'all derived tasks are linked to the message'
    Assert-True (@($queued.remarks).Count -ge 2) 'assessment and automatic queue-link remarks are retained'

    $beforeDoneResult = Invoke-Inbox @('actionable', '--root', $script:RepoB, '--json')
    if ($beforeDoneResult.ExitCode -ne 0) { throw "actionable before completion failed: $($beforeDoneResult.Err) $($beforeDoneResult.Out)" }
    $beforeDone = $beforeDoneResult.Out | ConvertFrom-Json
    Assert-Equal 0 ([int]$beforeDone.count) 'queued work is not completable before archive evidence exists'
    Assert-Equal $brokenMessageId ([string]$beforeDone.errors[0].id) 'actionable reports but skips the malformed record'
    $premature = Invoke-Inbox @('mark', '--root', $script:RepoB, '--id', $messageId, '--status', 'implemented', '--remark', 'Must not be accepted yet.')
    Assert-Exit $premature 6 'implemented is rejected until every linked task is archived'

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
    $pendingReply = (Invoke-Inbox @('actionable', '--root', $script:RepoB, '--json')).Out | ConvertFrom-Json
    Assert-Equal 1 ([int]$pendingReply.count) 'terminal status without final reply remains actionable'
    Assert-Equal $messageId ([string]$pendingReply.reply_pending[0]) 'implemented request is exposed as reply_pending'
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
    $legacyReplyPath = Join-Path $script:RepoA ('.inbox/messages/' + [string]$reply.id + '.json')
    $legacyReply = [System.IO.File]::ReadAllText($legacyReplyPath) | ConvertFrom-Json
    $legacyReply.PSObject.Properties.Remove('conversation_id')
    $legacyReply.PSObject.Properties.Remove('message_type')
    $legacyReply.PSObject.Properties.Remove('release')
    Write-TestFile $legacyReplyPath ($legacyReply | ConvertTo-Json -Depth 12)
    $legacyRead = (Invoke-Inbox @('show', '--root', $script:RepoA, '--id', ([string]$reply.id), '--json')).Out | ConvertFrom-Json
    Assert-Equal $messageId ([string]$legacyRead.conversation_id) 'early schema-1 reply without conversation_id is normalized on read'
    Assert-Equal 'reply' ([string]$legacyRead.message_type) 'early schema-1 reply derives its missing message type'
    $replyRead = Invoke-Inbox @('mark', '--root', $script:RepoA, '--id', ([string]$reply.id), '--status', 'read', '--remark', 'Final upstream outcome recorded.', '--actor', 'inbox_curator')
    Assert-Exit $replyRead 0 'incoming reply can be marked read'
    $senderActionable = (Invoke-Inbox @('actionable', '--root', $script:RepoA, '--json')).Out | ConvertFrom-Json
    Assert-Equal 0 ([int]$senderActionable.count) 'a read reply is not reprocessed as an unresolved request'
    $finalOriginal = (Invoke-Inbox @('show', '--root', $script:RepoB, '--id', $messageId, '--json')).Out | ConvertFrom-Json
    Assert-Equal 'final' ([string]$finalOriginal.reply_status) 'original message records final reply status'
    Assert-Equal 1 (@($finalOriginal.reply_ids).Count) 'original stores one reply id after retry'
    Assert-Equal ($remarkCountBeforeReply + 1) (@($finalOriginal.remarks).Count) 'idempotent reply retry does not append a duplicate remark'
    $afterReply = (Invoke-Inbox @('actionable', '--root', $script:RepoB, '--json')).Out | ConvertFrom-Json
    Assert-Equal 0 ([int]$afterReply.count) 'recorded final reply clears reply_pending'

    Add-Content -LiteralPath (Join-Path $script:RepoB '.work/Tasks_Queue.md') -Value "`n### [T-103] Late unrelated task — status: not started`nInbox message: $messageId`n" -Encoding utf8
    $terminalReconcile = Invoke-Inbox @('reconcile', '--root', $script:RepoB, '--json')
    Assert-Exit $terminalReconcile 0 'reconcile tolerates provenance added after terminal status'
    Assert-Equal 0 ([int](($terminalReconcile.Out | ConvertFrom-Json).count)) 'reconcile does not mutate terminal records'
    $terminalState = (Invoke-Inbox @('show', '--root', $script:RepoB, '--id', $messageId, '--json')).Out | ConvertFrom-Json
    Assert-Equal 'T-101,T-102' ((@($terminalState.queue_tasks) | Sort-Object) -join ',') 'terminal message task links remain immutable'

    Write-TestFile $replyBody 'Conflicting content under the same dedupe key.'
    $conflict = Invoke-Inbox @('reply', '--root', $script:RepoB, '--id', $messageId, '--reply-status', 'final', '--dedupe-key', 'final-v1', '--body-file', $replyBody)
    Assert-Exit $conflict 6 'same reply dedupe key cannot overwrite different content'

    $stableBody = Join-Path $script:Root 'stable-request.md'
    Write-TestFile $stableBody 'A request whose sender may lose command output.'
    $maxSubject = 'S' * 240
    $stable1 = Invoke-Inbox @('send', '--root', $script:RepoA, '--to', 'Receiver', '--subject', $maxSubject, '--body-file', $stableBody, '--dedupe-key', 'reviewer-T-200-R-01-v1', '--json')
    $stable2 = Invoke-Inbox @('send', '--root', $script:RepoA, '--to', 'Receiver', '--subject', $maxSubject, '--body-file', $stableBody, '--dedupe-key', 'reviewer-T-200-R-01-v1', '--json')
    Assert-Exit $stable1 0 'stable initial send succeeds'
    Assert-Exit $stable2 0 'stable initial send retry is idempotent'
    $stableMessage = $stable1.Out | ConvertFrom-Json
    $stableRetry = $stable2.Out | ConvertFrom-Json
    Assert-Equal ([string]$stableMessage.id) ([string]$stableRetry.id) 'stable initial send retry returns the same message id'
    Write-TestFile $stableBody 'Conflicting request content under the same key.'
    $stableConflict = Invoke-Inbox @('send', '--root', $script:RepoA, '--to', 'Receiver', '--subject', $maxSubject, '--body-file', $stableBody, '--dedupe-key', 'reviewer-T-200-R-01-v1')
    Assert-Exit $stableConflict 6 'stable initial send key cannot overwrite different content'

    $stableId = [string]$stableMessage.id
    Assert-Exit (Invoke-Inbox @('mark', '--root', $script:RepoB, '--id', $stableId, '--status', 'read', '--remark', 'Assessed before refusal.')) 0 'crash-recovery request can be marked read'
    Assert-Exit (Invoke-Inbox @('mark', '--root', $script:RepoB, '--id', $stableId, '--status', 'rejected', '--remark', 'A local alternative is preferred.')) 0 'crash-recovery request can be rejected'
    Write-TestFile $replyBody 'First delivered final response wins after a crash.'
    $previousFault = [Environment]::GetEnvironmentVariable('ORCHESTRA_INBOX_FAULT')
    try {
        [Environment]::SetEnvironmentVariable('ORCHESTRA_INBOX_FAULT', 'after-reply-delivery')
        $crashedReply = Invoke-Inbox @('reply', '--root', $script:RepoB, '--id', $stableId, '--reply-status', 'final', '--dedupe-key', 'final-v1', '--body-file', $replyBody, '--json')
    } finally {
        [Environment]::SetEnvironmentVariable('ORCHESTRA_INBOX_FAULT', $previousFault)
    }
    Assert-Exit $crashedReply 1 'injected crash occurs after remote reply delivery'
    $crashedState = (Invoke-Inbox @('show', '--root', $script:RepoB, '--id', $stableId, '--json')).Out | ConvertFrom-Json
    Assert-Equal 'none' ([string]$crashedState.reply_status) 'source remains reply_pending after delivery-before-source crash'
    Write-TestFile $replyBody 'Reconstructed text differs, but must not replace delivered history.'
    $recoveredReply = Invoke-Inbox @('reply', '--root', $script:RepoB, '--id', $stableId, '--reply-status', 'final', '--dedupe-key', 'final-v1', '--body-file', $replyBody, '--json')
    Assert-Exit $recoveredReply 0 'retry repairs source state from the already delivered reply'
    $recovered = $recoveredReply.Out | ConvertFrom-Json
    Assert-Equal 'First delivered final response wins after a crash.' ([string]$recovered.body) 'recovery preserves first delivered reply content'
    Assert-Equal 240 ([string]$recovered.subject).Length 'default reply subject is safely truncated to its schema limit'
    $recoveredState = (Invoke-Inbox @('show', '--root', $script:RepoB, '--id', $stableId, '--json')).Out | ConvertFrom-Json
    Assert-Equal 'final' ([string]$recoveredState.reply_status) 'recovery records the final reply on the source request'
    $postRecoveryConflict = Invoke-Inbox @('reply', '--root', $script:RepoB, '--id', $stableId, '--reply-status', 'final', '--dedupe-key', 'final-v1', '--body-file', $replyBody)
    Assert-Exit $postRecoveryConflict 6 'different content fails after reply recovery is committed'

    $null = New-Item -ItemType Directory -Force -Path $script:RepoC
    $c1 = Invoke-Registry @('register', '--root', $script:RepoC, '--name', 'Unrelated', '--ensure-inbox', '--json')
    Assert-Exit $c1 0 'register unrelated project for release routing negative control'

    $sourceGraphPath = Join-Path $script:Root 'source-graph.json'
    Write-TestFile $sourceGraphPath @'
{
  "schema": "orchestra/project-graph-snapshot@1",
  "base_graph_generation": 0,
  "products": ["nuget:Sender.Package", "nuget:Sender.Tool"],
  "dependencies": []
}
'@
    $sourceGraph = Invoke-Registry @('graph-sync', '--root', $script:RepoA, '--snapshot-file', $sourceGraphPath, '--json')
    Assert-Exit $sourceGraph 0 'source product graph sync'
    Assert-True ([bool](($sourceGraph.Out | ConvertFrom-Json).changed)) 'first source graph sync changes registry'

    $malformedGraphPath = Join-Path $script:Root 'malformed-graph.json'
    Write-TestFile $malformedGraphPath '{"schema":"orchestra/project-graph-snapshot@1","base_graph_generation":1,"products":"nuget:NotAnArray","dependencies":[]}'
    Assert-Exit (Invoke-Registry @('graph-sync', '--root', $script:RepoA, '--snapshot-file', $malformedGraphPath)) 5 'graph sync rejects a scalar products field'
    Write-TestFile $malformedGraphPath '{"schema":"orchestra/project-graph-snapshot@1","base_graph_generation":1,"products":[],"dependencies":[{"upstream":"missing-shape"}]}'
    Assert-Exit (Invoke-Registry @('graph-sync', '--root', $script:RepoA, '--snapshot-file', $malformedGraphPath)) 5 'graph sync rejects incomplete dependency objects before resolution'

    $dependentGraphPath = Join-Path $script:Root 'dependent-graph.json'
    Write-TestFile $dependentGraphPath (@"
{
  "schema": "orchestra/project-graph-snapshot@1",
  "base_graph_generation": 0,
  "products": ["nuget:Receiver.Package"],
  "dependencies": [
    {
      "upstream": "$([string]$senderProject.id)",
      "products": ["nuget:Sender.Package"],
      "evidence": ["Directory.Packages.props: Sender.Package"]
    }
  ]
}
"@)
    $dependentGraph1 = Invoke-Registry @('graph-sync', '--root', $script:RepoB, '--snapshot-file', $dependentGraphPath, '--json')
    $dependentGraph2 = Invoke-Registry @('graph-sync', '--root', $script:RepoB, '--snapshot-file', $dependentGraphPath, '--json')
    Assert-Exit $dependentGraph1 0 'dependent graph sync'
    Assert-Exit $dependentGraph2 0 'unchanged dependent graph sync is idempotent'
    Assert-True ([bool](($dependentGraph1.Out | ConvertFrom-Json).changed)) 'first dependent graph sync changes registry'
    Assert-True (-not [bool](($dependentGraph2.Out | ConvertFrom-Json).changed)) 'second dependent graph sync reports unchanged'

    $staleGraphPath = Join-Path $script:Root 'stale-dependent-graph.json'
    Write-TestFile $staleGraphPath (@"
{
  "schema": "orchestra/project-graph-snapshot@1",
  "base_graph_generation": 0,
  "products": ["nuget:Stale.Writer"],
  "dependencies": []
}
"@)
    Assert-Exit (Invoke-Registry @('graph-sync', '--root', $script:RepoB, '--snapshot-file', $staleGraphPath)) 6 'stale changing graph snapshot loses the generation CAS'
    $afterStaleGraph = (Invoke-Registry @('graph-show', '--root', $script:RepoB, '--json')).Out | ConvertFrom-Json
    Assert-Equal 1 ([long]$afterStaleGraph.project.graph_generation) 'rejected stale writer does not advance graph generation'
    Assert-Equal 'nuget:Receiver.Package' ([string]$afterStaleGraph.products[0]) 'rejected stale writer does not replace graph content'

    $unrelatedGraphPath = Join-Path $script:Root 'unrelated-graph.json'
    Write-TestFile $unrelatedGraphPath (@"
{
  "schema": "orchestra/project-graph-snapshot@1",
  "base_graph_generation": 0,
  "products": [],
  "dependencies": [
    {
      "upstream": "$([string]$senderProject.id)",
      "products": ["nuget:Sender.Tool"],
      "evidence": ["tools.json: Sender.Tool"]
    }
  ]
}
"@)
    Assert-Exit (Invoke-Registry @('graph-sync', '--root', $script:RepoC, '--snapshot-file', $unrelatedGraphPath)) 0 'second dependent registers a different source product'
    $dependents = Invoke-Registry @('dependents', '--project', ([string]$senderProject.id), '--json')
    Assert-Exit $dependents 0 'reverse dependency lookup'
    $dependentState = $dependents.Out | ConvertFrom-Json
    Assert-Equal 2 ([int]$dependentState.count) 'reverse lookup reports both repository-level dependents'
    Assert-Equal ([string]$receiver.id) ([string]$dependentState.dependents[0].id) 'reverse lookup returns receiver'

    $releaseNotes = Join-Path $script:Root 'release-notes.md'
    Write-TestFile $releaseNotes 'Release delivery must recover after the destination write.'
    $unknownProduct = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', 'invalid-product-probe', '--notes-file', $releaseNotes, '--product', 'nuget:NotPublished')
    Assert-Exit $unknownProduct 6 'release rejects a product not declared by the source graph'
    $previousReleaseFault = [Environment]::GetEnvironmentVariable('ORCHESTRA_INBOX_FAULT')
    try {
        [Environment]::SetEnvironmentVariable('ORCHESTRA_INBOX_FAULT', 'after-release-delivery')
        $crashedRelease = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '1.9.0', '--notes-file', $releaseNotes, '--product', 'nuget:Sender.Package', '--json')
    } finally {
        [Environment]::SetEnvironmentVariable('ORCHESTRA_INBOX_FAULT', $previousReleaseFault)
    }
    Assert-Exit $crashedRelease 6 'release reports partial delivery after destination-before-source injected fault'
    if ($crashedRelease.ExitCode -ne 6 -or $crashedRelease.Err -notmatch 'release notification delivery failed') {
        throw "injected release did not reach the delivery fault: err=[$($crashedRelease.Err)] out=[$($crashedRelease.Out)]"
    }
    $resumedRelease = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '1.9.0', '--resume', '--json')
    Assert-Exit $resumedRelease 0 'release resume repairs the source delivery record idempotently'
    if ($resumedRelease.ExitCode -eq 0) {
        Assert-Equal 1 ([int](($resumedRelease.Out | ConvertFrom-Json).delivered_count)) 'resumed release confirms its dependent delivery'
    } else {
        throw "release resume failed: err=[$($resumedRelease.Err)] out=[$($resumedRelease.Out)]"
    }

    Write-TestFile $releaseNotes "Sender.Package 2.0.0`n`n- Added bounded cancellation.`n- Changed the compatibility baseline."
    $release1 = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '2.0.0', '--notes-file', $releaseNotes, '--product', 'nuget:Sender.Package', '--release-url', 'https://example.invalid/releases/2.0.0', '--source-revision', 'abc123', '--json')
    $release2 = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '2.0.0', '--resume', '--json')
    $invalidResume = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '2.0.0', '--resume', '--notes-file', $releaseNotes)
    Assert-Exit $release1 0 'release notification fan-out'
    Assert-Exit $release2 0 'release notification resume is idempotent'
    Assert-Exit $invalidResume 2 'release resume rejects replacement content options'
    $releaseResult = $release1.Out | ConvertFrom-Json
    Assert-Equal 1 ([int]$releaseResult.target_count) 'release freezes one graph-derived target'
    Assert-Equal 1 ([int]$releaseResult.delivered_count) 'release delivers to its dependent'
    $releaseMessageId = [string]$releaseResult.deliveries[0].message_id
    $releaseMessage = (Invoke-Inbox @('show', '--root', $script:RepoB, '--id', $releaseMessageId, '--json')).Out | ConvertFrom-Json
    Assert-Equal 'release' ([string]$releaseMessage.message_type) 'dependent receives structured release message'
    Assert-Equal '2.0.0' ([string]$releaseMessage.release.version) 'release metadata carries version'
    Assert-Equal 'nuget:Sender.Package' ([string]$releaseMessage.release.products[0]) 'release metadata preserves product identity while normalizing ecosystem'
    $unrelatedInbox = (Invoke-Inbox @('list', '--root', $script:RepoC, '--json')).Out | ConvertFrom-Json
    Assert-Equal 0 ([int]$unrelatedInbox.count) 'dependent on a different product receives no product-specific release notification'

    $offlineRepoB = "$($script:RepoB)-offline"
    Move-Item -LiteralPath $script:RepoB -Destination $offlineRepoB
    try {
        $completedResume = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '2.0.0', '--resume', '--json')
        Assert-Exit $completedResume 0 'release resume skips a previously recorded delivery whose target is now unavailable'
        Assert-Equal 1 ([int](($completedResume.Out | ConvertFrom-Json).delivered_count)) 'skipped completed delivery remains represented in the resume result'
    } finally {
        Move-Item -LiteralPath $offlineRepoB -Destination $script:RepoB
    }

    Move-Item -LiteralPath $script:RepoB -Destination $offlineRepoB
    try {
        Write-TestFile $releaseNotes 'A permanently unavailable target needs an explicit audited skip.'
        $blockedRelease = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '2.0.2', '--notes-file', $releaseNotes, '--product', 'nuget:Sender.Package', '--json')
        Assert-Exit $blockedRelease 6 'release records but reports a permanently unavailable undelivered target'
        $skippedRelease = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '2.0.2', '--resume', '--skip-target', ([string]$receiver.id), '--skip-reason', 'receiver repository retired', '--json')
        Assert-Exit $skippedRelease 0 'release resume can explicitly skip an unavailable frozen target'
        if ($skippedRelease.ExitCode -eq 0) {
            $skippedProjection = $skippedRelease.Out | ConvertFrom-Json
            Assert-Equal 1 ([int]$skippedProjection.skipped_count) 'skipped frozen target is reported separately from delivery'
            Assert-Equal ([string]$receiver.id) ([string]$skippedProjection.skipped_targets[0].project_id) 'skip preserves the frozen target identity'
        }
        $skipRetry = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '2.0.2', '--resume', '--json')
        Assert-Exit $skipRetry 0 'release resume converges after the audited target skip'
    } finally {
        Move-Item -LiteralPath $offlineRepoB -Destination $script:RepoB
    }

    Write-TestFile $releaseNotes 'Whitespace around an operator-supplied version is not part of release identity.'
    $trimmedRelease = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', ' 2.0.1 ', '--notes-file', $releaseNotes, '--product', 'nuget:Sender.Package', '--json')
    Assert-Exit $trimmedRelease 0 'release canonicalizes surrounding version whitespace'
    Assert-Equal '2.0.1' ([string](($trimmedRelease.Out | ConvertFrom-Json).version)) 'release result carries the canonical version'
    $releaseAuditFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:RepoA '.inbox/releases') -File -Filter 'rel-*.json')
    Assert-Equal 4 $releaseAuditFiles.Count 'source stores canonical release audit records including recovered, normalized, and skipped fan-out'

    Write-TestFile $releaseNotes 'Changed notes must not rewrite a started fan-out.'
    $releaseConflict = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '2.0.0', '--notes-file', $releaseNotes)
    Assert-Exit $releaseConflict 6 'canonical release content is immutable after fan-out starts'

    Write-TestFile $dependentGraphPath @'
{
  "schema": "orchestra/project-graph-snapshot@1",
  "base_graph_generation": 1,
  "products": ["nuget:Receiver.Package"],
  "dependencies": []
}
'@
    Assert-Exit (Invoke-Registry @('graph-sync', '--root', $script:RepoB, '--snapshot-file', $dependentGraphPath)) 0 'dependency removal refreshes graph'
    $afterRemoval = (Invoke-Registry @('dependents', '--project', ([string]$senderProject.id), '--json')).Out | ConvertFrom-Json
    Assert-Equal 1 ([int]$afterRemoval.count) 'removing one edge preserves the dependent on another product'
    $frozenResume = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '2.0.0', '--resume', '--json')
    Assert-Exit $frozenResume 0 'existing release retains its original frozen audience after graph changes'
    Assert-Equal 1 ([int](($frozenResume.Out | ConvertFrom-Json).target_count)) 'frozen release audience is not recomputed'
    Write-TestFile $releaseNotes 'No current dependents should receive this release.'
    $releaseNoTargets = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '2.1.0', '--notes-file', $releaseNotes, '--product', 'nuget:Sender.Package', '--json')
    Assert-Exit $releaseNoTargets 0 'release with no dependents is a successful auditable no-op'
    Assert-Equal 0 ([int](($releaseNoTargets.Out | ConvertFrom-Json).target_count)) 'new release uses the refreshed empty audience'

    $retiredRegister = Invoke-Registry @('register', '--root', $script:RepoD, '--name', 'Retired', '--ensure-inbox', '--json')
    Assert-Exit $retiredRegister 0 'register retired project for removal workflow'
    $retired = ($retiredRegister.Out | ConvertFrom-Json).project
    $receiverGraphBeforeRetirement = (Invoke-Registry @('graph-show', '--root', $script:RepoB, '--json')).Out | ConvertFrom-Json
    $retiredDependencyPath = Join-Path $script:Root 'retired-dependent-graph.json'
    Write-TestFile $retiredDependencyPath (@"
{
  "schema": "orchestra/project-graph-snapshot@1",
  "base_graph_generation": $($receiverGraphBeforeRetirement.project.graph_generation),
  "products": ["nuget:Receiver.Package"],
  "dependencies": [
    {
      "upstream": "$($retired.id)",
      "products": [],
      "evidence": ["retired fixture"]
    }
  ]
}
"@)
    Assert-Exit (Invoke-Registry @('graph-sync', '--root', $script:RepoB, '--snapshot-file', $retiredDependencyPath)) 0 'add dependent edge before registry removal'
    $blockedUnregister = Invoke-Registry @('unregister', '--project', ([string]$retired.id))
    Assert-Exit $blockedUnregister 6 'registry refuses to remove an upstream with live dependent edges'
    $unregistered = Invoke-Registry @('unregister', '--project', ([string]$retired.id), '--detach-dependents', '--json')
    Assert-Exit $unregistered 0 'registry removal atomically detaches dependent edges'
    if ($unregistered.ExitCode -eq 0) {
        Assert-Equal 1 (@(($unregistered.Out | ConvertFrom-Json).detached_dependents).Count) 'registry removal reports every detached dependent'
    }
    Assert-Exit (Invoke-Registry @('resolve', '--project', ([string]$retired.id))) 4 'unregistered project no longer resolves'
    $receiverGraphAfterRetirement = (Invoke-Registry @('graph-show', '--root', $script:RepoB, '--json')).Out | ConvertFrom-Json
    Assert-Equal 0 (@($receiverGraphAfterRetirement.dependencies).Count) 'registry removal leaves no dangling dependency edge'

    # --- T-318: a registered-but-never-audited project must not look independent by omission ---
    $null = New-Item -ItemType Directory -Force -Path $script:RepoE
    $eRegisterJson = Invoke-Registry @('register', '--root', $script:RepoE, '--name', 'NeverAudited', '--ensure-inbox', '--json')
    Assert-Exit $eRegisterJson 0 'register a project that stays unaudited (graph_generation=0)'
    $neverAudited = ($eRegisterJson.Out | ConvertFrom-Json).project
    Assert-Equal 0 ([long]$neverAudited.graph_generation) 'freshly registered project starts unaudited'

    $eRegisterHuman = Invoke-Registry @('register', '--root', $script:RepoE, '--name', 'NeverAudited', '--ensure-inbox')
    Assert-Exit $eRegisterHuman 0 'repeat human-readable registration of an unaudited project'
    Assert-True ($eRegisterHuman.Out -match 'dependency graph') 'register hints that an unaudited project has an empty dependency graph'

    $aRegisterHuman = Invoke-Registry @('register', '--root', $script:RepoA, '--name', 'Sender', '--ensure-inbox')
    Assert-Exit $aRegisterHuman 0 'repeat human-readable registration of an already-audited project'
    Assert-True ($aRegisterHuman.Out -notmatch 'dependency graph') 'register prints no hint for an already-audited project'

    Write-TestFile $releaseNotes 'A registered-but-never-audited project must not look independent by omission.'
    $unauditedFreeze = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '3.0.0', '--notes-file', $releaseNotes, '--product', 'nuget:Sender.Package', '--json')
    Assert-Exit $unauditedFreeze 0 'release freezing an incomplete audience still succeeds (non-blocking)'
    $unauditedResult = $unauditedFreeze.Out | ConvertFrom-Json
    Assert-Equal 1 ([int]$unauditedResult.unaudited_count) 'release surfaces exactly the one never-audited registered project'
    Assert-Equal ([string]$neverAudited.id) ([string]$unauditedResult.unaudited_projects[0]) 'unaudited evidence identifies the never-audited project'

    $unauditedFreezeHuman = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '3.0.1', '--notes-file', $releaseNotes, '--product', 'nuget:Sender.Package')
    Assert-Exit $unauditedFreezeHuman 0 'human-readable release with an incomplete audience still succeeds'
    Assert-True ($unauditedFreezeHuman.Out -match 'never had their dependency graph audited') 'human-readable freeze call warns about the incomplete audience'
    Assert-True ($unauditedFreezeHuman.Out -notmatch 'consumer') 'warning avoids over-claiming the unaudited project is a consumer'

    $unauditedResume = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '3.0.1', '--resume')
    Assert-Exit $unauditedResume 0 'resume of an unaudited-audience release still succeeds'
    Assert-True ($unauditedResume.Out -notmatch 'never had their dependency graph audited') 'resume does not repeat the freeze-time warning'

    $auditedGraphPath = Join-Path $script:Root 'never-audited-graph.json'
    Write-TestFile $auditedGraphPath @'
{
  "schema": "orchestra/project-graph-snapshot@1",
  "base_graph_generation": 0,
  "products": ["nuget:NeverAudited.Package"],
  "dependencies": []
}
'@
    $neverAuditedSync = Invoke-Registry @('graph-sync', '--root', $script:RepoE, '--snapshot-file', $auditedGraphPath, '--json')
    Assert-Exit $neverAuditedSync 0 'audit the previously unaudited project'
    Assert-Equal 1 ([long](($neverAuditedSync.Out | ConvertFrom-Json).project.graph_generation)) 'a real content change advances graph_generation past zero'
    Write-TestFile $releaseNotes 'A release where every registered project is already audited reports nothing extra.'
    $fullyAuditedRelease = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '3.1.0', '--notes-file', $releaseNotes, '--product', 'nuget:Sender.Package', '--json')
    Assert-Exit $fullyAuditedRelease 0 'release where every registered project is audited still succeeds'
    Assert-Equal 0 ([int](($fullyAuditedRelease.Out | ConvertFrom-Json).unaudited_count)) 'a fully audited registry reports no unaudited projects'

    $releasePathToPatch = Get-ReleaseRecordFile -Root $script:RepoA -Version '3.0.0'
    Assert-True ($null -ne $releasePathToPatch) 'locate the on-disk record for the unaudited-freeze release'
    if ($null -ne $releasePathToPatch) {
        $oldFormatRecord = $releasePathToPatch.Record
        $oldFormatRecord.unaudited_projects = $null
        Write-TestFile $releasePathToPatch.Path ($oldFormatRecord | ConvertTo-Json -Depth 14)
        $nullUnauditedResume = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '3.0.0', '--resume', '--json')
        Assert-Exit $nullUnauditedResume 5 'a release record with null unaudited_projects is rejected'

        $oldFormatRecord.unaudited_projects = [string]$neverAudited.id
        Write-TestFile $releasePathToPatch.Path ($oldFormatRecord | ConvertTo-Json -Depth 14)
        $scalarUnauditedResume = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '3.0.0', '--resume', '--json')
        Assert-Exit $scalarUnauditedResume 5 'a release record with scalar unaudited_projects is rejected'

        $oldFormatRecord.unaudited_projects = [object[]]::new(0)
        Write-TestFile $releasePathToPatch.Path ($oldFormatRecord | ConvertTo-Json -Depth 14)
        $emptyUnauditedResume = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '3.0.0', '--resume', '--json')
        Assert-Exit $emptyUnauditedResume 0 'a release record with an empty unaudited_projects array is accepted'
        Assert-Equal 0 ([int](($emptyUnauditedResume.Out | ConvertFrom-Json).unaudited_count)) 'an empty unaudited_projects array stays empty'

        $oldFormatRecord.PSObject.Properties.Remove('unaudited_projects')
        Write-TestFile $releasePathToPatch.Path ($oldFormatRecord | ConvertTo-Json -Depth 14)
        $oldFormatResume = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '3.0.0', '--resume', '--json')
        Assert-Exit $oldFormatResume 0 'reading a pre-existing release record without the new field does not fail'
        Assert-Equal 0 ([int](($oldFormatResume.Out | ConvertFrom-Json).unaudited_count)) 'a record missing the field defaults to an empty unaudited evidence set'
    }

    # --- T-319: one explicit, audited addition of a dependent missed by the frozen audience ---
    $unrelated = ($c1.Out | ConvertFrom-Json).project
    Write-TestFile $releaseNotes 'A dependent that audits its graph after the freeze must still be reachable.'
    $lateFreeze = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.0.0', '--notes-file', $releaseNotes, '--product', 'nuget:Sender.Package', '--json')
    Assert-Exit $lateFreeze 0 'freeze a release while the late dependent still has no audited edge'
    if ($lateFreeze.ExitCode -ne 0) { throw "late-audience freeze failed: err=[$($lateFreeze.Err)] out=[$($lateFreeze.Out)]" }
    $lateRelease = $lateFreeze.Out | ConvertFrom-Json
    $lateReleaseId = [string]$lateRelease.release_id
    Assert-Equal 0 ([int]$lateRelease.target_count) 'the late dependent is genuinely outside the frozen audience'
    Assert-Equal 0 ([int]$lateRelease.added_count) 'a freshly frozen release has an empty addition audit trail'

    Assert-Exit (Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.0.0',
        '--add-target', ([string]$receiver.id), '--add-reason', 'graph audited late')) 2 'adding a target requires --resume'
    Assert-Exit (Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.0.0', '--resume',
        '--add-target', ([string]$receiver.id), '--add-reason', 'graph audited late', '--notes-file', $releaseNotes)) 2 'adding a target rejects replacement content options'
    Assert-Exit (Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.0.0', '--resume',
        '--add-target', ([string]$receiver.id), '--add-reason', 'graph audited late', '--product', 'nuget:Sender.Tool')) 2 'adding a target rejects replacement product routing'
    Assert-Exit (Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.0.0', '--resume',
        '--add-target', ([string]$receiver.id))) 2 'an addition requires an audit reason'
    Assert-Exit (Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.0.0', '--resume',
        '--add-target', 'Receiver', '--add-reason', 'named target')) 2 'an addition names its target by stable id, never by project name'
    Assert-Exit (Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.0.0', '--resume',
        '--add-target', ([string]$receiver.id), '--add-reason', 'graph audited late',
        '--skip-target', ([string]$receiver.id), '--skip-reason', 'contradictory decision')) 2 'an addition and a skip are not combined in one call'
    Assert-Exit (Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.9.9', '--resume',
        '--add-target', ([string]$receiver.id), '--add-reason', 'no such release')) 4 'a target cannot be added to a release record that does not exist'
    $addUnknownEdge = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.0.0', '--resume',
        '--add-target', ([string]$receiver.id), '--add-reason', 'graph audited late')
    Assert-Exit $addUnknownEdge 6 'a project without a current dependency edge cannot be added'
    Assert-True ($addUnknownEdge.Err -match 'not a current dependent') 'the refusal names the missing dependency edge'
    Assert-Exit (Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.0.0', '--resume',
        '--add-target', ([string]$retired.id), '--add-reason', 'unregistered project')) 6 'an unregistered project cannot be added'
    $addProductMismatch = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.0.0', '--resume',
        '--add-target', ([string]$unrelated.id), '--add-reason', 'different product')
    Assert-Exit $addProductMismatch 6 'a dependent on another product of the same project cannot be added'
    Assert-True ($addProductMismatch.Err -match 'no dependency on any product of this release') 'the refusal distinguishes a product mismatch from a missing edge'
    $stillEmpty = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.0.0', '--resume', '--json')
    Assert-Exit $stillEmpty 0 'the rejected additions leave the release resumable'
    Assert-Equal 0 ([int](($stillEmpty.Out | ConvertFrom-Json).target_count)) 'a rejected addition does not extend the frozen audience'

    $receiverGraphBeforeLateAudit = (Invoke-Registry @('graph-show', '--root', $script:RepoB, '--json')).Out | ConvertFrom-Json
    $lateDependentGraphPath = Join-Path $script:Root 'late-dependent-graph.json'
    Write-TestFile $lateDependentGraphPath (@"
{
  "schema": "orchestra/project-graph-snapshot@1",
  "base_graph_generation": $([long]$receiverGraphBeforeLateAudit.project.graph_generation),
  "products": ["nuget:Receiver.Package"],
  "dependencies": [
    {
      "upstream": "$([string]$senderProject.id)",
      "products": ["nuget:Sender.Package"],
      "evidence": ["Directory.Packages.props: Sender.Package"]
    }
  ]
}
"@)
    Assert-Exit (Invoke-Registry @('graph-sync', '--root', $script:RepoB, '--snapshot-file', $lateDependentGraphPath)) 0 'the missed dependent audits its graph after the freeze'

    $expectedAddedMessageId = Get-ExpectedReleaseMessageId -FromId ([string]$senderProject.id) -ToId ([string]$receiver.id) -ReleaseId $lateReleaseId
    $added1 = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.0.0', '--resume',
        '--add-target', ([string]$receiver.id), '--add-reason', 'dependency graph audited after the freeze', '--json')
    Assert-Exit $added1 0 'a graph-verified late dependent is added to the frozen audience'
    if ($added1.ExitCode -eq 0) {
        $addedResult = $added1.Out | ConvertFrom-Json
        Assert-Equal 1 ([int]$addedResult.target_count) 'the added target joins the frozen audience'
        Assert-Equal 1 ([int]$addedResult.delivered_count) 'the added target receives the release in the same call'
        Assert-Equal 1 ([int]$addedResult.added_count) 'the addition is recorded in the release audit trail'
        Assert-Equal ([string]$receiver.id) ([string]$addedResult.added_targets[0].project_id) 'the audit entry identifies the added project'
        Assert-Equal 'dependency graph audited after the freeze' ([string]$addedResult.added_targets[0].reason) 'the audit entry retains the operator reason'
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$addedResult.added_targets[0].added_at)) 'the audit entry records when the target was added'
        Assert-Equal $expectedAddedMessageId ([string]$addedResult.deliveries[0].message_id) 'the added target reuses the deterministic fan-out message id'
        $addedMessage = (Invoke-Inbox @('show', '--root', $script:RepoB, '--id', $expectedAddedMessageId, '--json')).Out | ConvertFrom-Json
        Assert-Equal 'release' ([string]$addedMessage.message_type) 'the added target receives a structured release message'
        Assert-Equal '4.0.0' ([string]$addedMessage.release.version) 'the added release message carries the frozen version'
        Assert-Equal $lateReleaseId ([string]$addedMessage.release.id) 'the added release message carries the canonical release id'
        Assert-Equal 'nuget:Sender.Package' ([string]$addedMessage.release.products[0]) 'the added release message reuses the frozen products'
        Assert-Equal ('release:' + $lateReleaseId) ([string]$addedMessage.dedupe_key) 'the added delivery reuses the release dedupe key'
        Assert-Equal 'A dependent that audits its graph after the freeze must still be reachable.' ([string]$addedMessage.body) 'the added delivery reuses the frozen canonical notes'
    }

    $receiverMessagesAfterAdd = @(Get-ChildItem -LiteralPath (Join-Path $script:RepoB '.inbox/messages') -File -Filter 'msg-*.json').Count
    $added2 = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.0.0', '--resume',
        '--add-target', ([string]$receiver.id), '--add-reason', 'retry after lost command output', '--json')
    Assert-Exit $added2 0 'repeating the addition for an already delivered target is not an error'
    if ($added2.ExitCode -eq 0) {
        $repeatResult = $added2.Out | ConvertFrom-Json
        Assert-Equal 1 ([int]$repeatResult.added_count) 'a repeated addition does not duplicate the audit entry'
        Assert-Equal 1 ([int]$repeatResult.target_count) 'a repeated addition does not duplicate the audience entry'
        Assert-Equal $expectedAddedMessageId ([string]$repeatResult.deliveries[0].message_id) 'a repeated addition converges on the same message id'
        Assert-Equal 'dependency graph audited after the freeze' ([string]$repeatResult.added_targets[0].reason) 'a repeated addition keeps the original audited reason'
    }
    Assert-Equal $receiverMessagesAfterAdd (@(Get-ChildItem -LiteralPath (Join-Path $script:RepoB '.inbox/messages') -File -Filter 'msg-*.json').Count) 'a repeated addition creates no second message'

    $repeatHuman = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.0.0', '--resume',
        '--add-target', ([string]$receiver.id), '--add-reason', 'retry after lost command output')
    Assert-Exit $repeatHuman 0 'human-readable repeat addition succeeds'
    Assert-True ($repeatHuman.Out -match 'already belongs to the frozen audience') 'human output states that an already present target left the audience unchanged'

    $resumeAfterAdd = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.0.0', '--resume', '--json')
    Assert-Exit $resumeAfterAdd 0 'a plain resume after the addition converges'
    if ($resumeAfterAdd.ExitCode -eq 0) {
        $resumeAfterAddResult = $resumeAfterAdd.Out | ConvertFrom-Json
        Assert-Equal 1 ([int]$resumeAfterAddResult.target_count) 'resume sees the added target as an ordinary audience member'
        Assert-Equal 1 ([int]$resumeAfterAddResult.delivered_count) 'resume reports the added delivery without repeating it'
        Assert-Equal $expectedAddedMessageId ([string]$resumeAfterAddResult.deliveries[0].message_id) 'resume reports the recorded deterministic message id'
    }
    Assert-Exit (Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.0.0', '--resume',
        '--skip-target', ([string]$receiver.id), '--skip-reason', 'too late to skip')) 6 'skip sees the added target as a frozen, already delivered audience member'

    $addedOnDisk = Get-ReleaseRecordFile -Root $script:RepoA -Version '4.0.0'
    Assert-True ($null -ne $addedOnDisk) 'locate the on-disk record carrying the added target'
    if ($null -ne $addedOnDisk) {
        Assert-Equal ([string]$receiver.id) ([string]$addedOnDisk.Record.target_project_ids[0]) 'the stored audience contains the added target'
        Assert-Equal ([string]$receiver.id) ([string]$addedOnDisk.Record.added_targets[0].project_id) 'the stored audit trail identifies the added target'
    }

    # An addition whose delivery cannot complete stays recorded, and the added target then
    # behaves like any other frozen target for the audited skip that converges the fan-out.
    $receiverGraphBeforeDrop = (Invoke-Registry @('graph-show', '--root', $script:RepoB, '--json')).Out | ConvertFrom-Json
    $droppedGraphPath = Join-Path $script:Root 'dropped-dependent-graph.json'
    Write-TestFile $droppedGraphPath (@"
{
  "schema": "orchestra/project-graph-snapshot@1",
  "base_graph_generation": $([long]$receiverGraphBeforeDrop.project.graph_generation),
  "products": ["nuget:Receiver.Package"],
  "dependencies": []
}
"@)
    Assert-Exit (Invoke-Registry @('graph-sync', '--root', $script:RepoB, '--snapshot-file', $droppedGraphPath)) 0 'the dependent edge disappears again before the next freeze'
    Write-TestFile $releaseNotes 'An addition must survive a failed delivery and remain convergeable.'
    $offlineFreeze = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.1.0', '--notes-file', $releaseNotes, '--product', 'nuget:Sender.Package', '--json')
    Assert-Exit $offlineFreeze 0 'freeze a second release without the late dependent'
    $receiverGraphBeforeReaudit = (Invoke-Registry @('graph-show', '--root', $script:RepoB, '--json')).Out | ConvertFrom-Json
    Write-TestFile $lateDependentGraphPath (@"
{
  "schema": "orchestra/project-graph-snapshot@1",
  "base_graph_generation": $([long]$receiverGraphBeforeReaudit.project.graph_generation),
  "products": ["nuget:Receiver.Package"],
  "dependencies": [
    {
      "upstream": "$([string]$senderProject.id)",
      "products": ["nuget:Sender.Package"],
      "evidence": ["Directory.Packages.props: Sender.Package"]
    }
  ]
}
"@)
    Assert-Exit (Invoke-Registry @('graph-sync', '--root', $script:RepoB, '--snapshot-file', $lateDependentGraphPath)) 0 're-audit the dependent edge before the second addition'
    Move-Item -LiteralPath $script:RepoB -Destination $offlineRepoB
    try {
        $offlineAdd = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.1.0', '--resume',
            '--add-target', ([string]$receiver.id), '--add-reason', 'audited late while the repository is unavailable', '--json')
        Assert-Exit $offlineAdd 6 'an addition whose delivery fails reports the failure'
        if ($offlineAdd.ExitCode -eq 6) {
            $offlineAddResult = $offlineAdd.Out | ConvertFrom-Json
            Assert-Equal 1 ([int]$offlineAddResult.added_count) 'a failed delivery still persists the audience addition'
            Assert-Equal 1 ([int]$offlineAddResult.failure_count) 'the unreachable added target is reported as a failure'
            Assert-Equal 0 ([int]$offlineAddResult.delivered_count) 'the unreachable added target is not reported as delivered'
        }
        $skipAdded = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.1.0', '--resume',
            '--skip-target', ([string]$receiver.id), '--skip-reason', 'target unavailable before delivery', '--json')
        Assert-Exit $skipAdded 0 'an added target can afterwards be skipped like any other frozen target'
        if ($skipAdded.ExitCode -eq 0) {
            $skipAddedResult = $skipAdded.Out | ConvertFrom-Json
            Assert-Equal 1 ([int]$skipAddedResult.skipped_count) 'the added target is reported as skipped'
            Assert-Equal 1 ([int]$skipAddedResult.added_count) 'skipping an added target preserves the addition audit trail'
        }
        Assert-Exit (Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.1.0', '--resume', '--json')) 0 'the fan-out converges after the added target is skipped'
        $reviveSkipped = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.1.0', '--resume',
            '--add-target', ([string]$receiver.id), '--add-reason', 'change of mind')
        Assert-Exit $reviveSkipped 6 'an explicitly skipped target is not silently revived by a new addition'
        Assert-True ($reviveSkipped.Err -match 'explicitly skipped') 'the refusal names the recorded skip as authoritative'
    } finally {
        Move-Item -LiteralPath $offlineRepoB -Destination $script:RepoB
    }

    if ($null -ne $addedOnDisk) {
        $addedRecord = $addedOnDisk.Record
        $addedRecord.added_targets = $null
        Write-TestFile $addedOnDisk.Path ($addedRecord | ConvertTo-Json -Depth 14)
        Assert-Exit (Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.0.0', '--resume', '--json')) 5 'a release record with null added_targets is rejected'

        $addedRecord.added_targets = [string]$receiver.id
        Write-TestFile $addedOnDisk.Path ($addedRecord | ConvertTo-Json -Depth 14)
        Assert-Exit (Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.0.0', '--resume', '--json')) 5 'a release record with scalar added_targets is rejected'

        $addedRecord.added_targets = @([pscustomobject][ordered]@{ project_id = [string]$receiver.id; added_at = '2026-01-01T00:00:00.000Z' })
        Write-TestFile $addedOnDisk.Path ($addedRecord | ConvertTo-Json -Depth 14)
        Assert-Exit (Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.0.0', '--resume', '--json')) 5 'an addition audit entry without a reason is rejected'

        $addedRecord.added_targets = @([pscustomobject][ordered]@{ project_id = [string]$unrelated.id; reason = 'never added'; added_at = '2026-01-01T00:00:00.000Z' })
        Write-TestFile $addedOnDisk.Path ($addedRecord | ConvertTo-Json -Depth 14)
        Assert-Exit (Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.0.0', '--resume', '--json')) 5 'an addition audit entry outside the frozen audience is rejected'

        $duplicateEntry = [pscustomobject][ordered]@{ project_id = [string]$receiver.id; reason = 'audited late'; added_at = '2026-01-01T00:00:00.000Z' }
        $addedRecord.added_targets = @($duplicateEntry, $duplicateEntry)
        Write-TestFile $addedOnDisk.Path ($addedRecord | ConvertTo-Json -Depth 14)
        Assert-Exit (Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.0.0', '--resume', '--json')) 5 'a duplicated addition audit entry is rejected'

        $addedRecord.PSObject.Properties.Remove('added_targets')
        Write-TestFile $addedOnDisk.Path ($addedRecord | ConvertTo-Json -Depth 14)
        $legacyAddedResume = Invoke-Inbox @('release', '--root', $script:RepoA, '--version', '4.0.0', '--resume', '--json')
        Assert-Exit $legacyAddedResume 0 'a release record predating added_targets still reads cleanly'
        if ($legacyAddedResume.ExitCode -eq 0) {
            $legacyAddedResult = $legacyAddedResume.Out | ConvertFrom-Json
            Assert-Equal 0 ([int]$legacyAddedResult.added_count) 'a record missing the field defaults to an empty addition audit trail'
            Assert-Equal 1 ([int]$legacyAddedResult.delivered_count) 'the recorded delivery survives the missing addition audit trail'
        }
    }

    $emoji = [string][char]0xD83D + [string][char]0xDE00
    $longSubject = ('a' * 235) + $emoji
    $longRequest = Invoke-Inbox @('send', '--root', $script:RepoA, '--to', 'Receiver', '--subject', $longSubject, '--body', 'Unicode boundary probe.', '--json')
    Assert-Exit $longRequest 0 'send a subject whose reply prefix would cut an emoji surrogate pair'
    if ($longRequest.ExitCode -eq 0) {
        $longReply = Invoke-Inbox @('reply', '--root', $script:RepoB, '--id', ([string](($longRequest.Out | ConvertFrom-Json).id)), '--reply-status', 'acknowledged', '--dedupe-key', 'unicode-subject-boundary', '--body', 'Acknowledged.', '--json')
        Assert-Exit $longReply 0 'reply truncates the default subject at a Unicode scalar boundary'
        if ($longReply.ExitCode -eq 0) {
            $replySubject = [string](($longReply.Out | ConvertFrom-Json).subject)
            Assert-Equal 239 $replySubject.Length 'reply removes the high surrogate instead of retaining it at the 240-unit boundary'
            Assert-True (-not [char]::IsHighSurrogate($replySubject[$replySubject.Length - 1])) 'reply default subject has no dangling high surrogate'
        }
    }
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
