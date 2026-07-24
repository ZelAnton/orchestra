<#
.SYNOPSIS
    Transactional cross-project message inbox for Orchestra repositories.

.DESCRIPTION
    Messages are JSON records under <repo>/.inbox/messages. Repository roots are never
    accepted from a message or from the caller for the destination: routing goes through
    the user-global project registry populated by cc-config. Message bodies are external
    data for the recipient and never executable instructions.

.EXAMPLE
    pwsh -File tools/inbox.ps1 send --root . --to ProcessKit-rs --subject "Need API" --body-file request.md
    pwsh -File tools/inbox.ps1 list --root . --status new --json
    pwsh -File tools/inbox.ps1 mark --root . --id msg-... --status read --remark "Validated" --actor inbox_curator
    pwsh -File tools/inbox.ps1 reply --root . --id msg-... --reply-status final --dedupe-key final-v1 --body-file reply.md
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'project-registry-lib.ps1')
$script:ErrPrefix = 'INBERR'
$script:FaultEnv = 'ORCHESTRA_INBOX_FAULT'
$script:LockName = 'project-inbox'
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Statuses = @('new', 'read', 'queued', 'implemented', 'rejected')
$script:ReplyStatuses = @('none', 'acknowledged', 'final')

$parsed = Parse-CliArgs $args -BoolFlags @('json') -RepeatKeys @('task')
$Command = $parsed.Command
$opts = $parsed.Opts

function Get-Root { return (Resolve-OrchestraProjectRoot (Require-Opt 'root')) }
function Get-Registry { return (Get-OrchestraRegistryPath ([string](Opt 'registry' ''))) }
function Get-InboxPath { param([string]$Root) return (Join-Path $Root '.inbox') }
function Get-MessagesPath { param([string]$Root) return (Join-Path (Get-InboxPath $Root) 'messages') }
function Get-InboxLockPath { param([string]$Root) return (Join-Path (Get-InboxPath $Root) 'inbox.lock') }

function Assert-InboxExists {
    param([string]$Root)
    $inbox = Get-InboxPath $Root
    $messages = Get-MessagesPath $Root
    if (-not (Test-Path -LiteralPath $inbox -PathType Container) -or -not (Test-Path -LiteralPath $messages -PathType Container)) {
        Fail 4 "project inbox is not initialized; run cc-config from the repository root: $Root"
    }
    Assert-OrchestraPlainDirectory -Path $inbox -Label 'project inbox'
    Assert-OrchestraPlainDirectory -Path $messages -Label 'project inbox messages'
}

function Get-MessagePath {
    param([string]$Root, [string]$Id)
    if ($Id -notmatch '^msg-[a-z0-9-]{8,120}$') { Fail 2 "invalid message id: $Id" }
    return (Join-Path (Get-MessagesPath $Root) ($Id + '.json'))
}

function Read-Message {
    param([string]$Root, [string]$Id)
    $path = Get-MessagePath -Root $Root -Id $Id
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Fail 4 "inbox message not found: $Id" }
    Assert-OrchestraPlainFile -Path $path -Label 'inbox message'
    try { $message = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json }
    catch { Fail 5 "inbox message is not valid JSON: $Id" }
    if ([string]$message.schema -ne 'orchestra/inbox-message@1' -or [string]$message.id -ne $Id) {
        Fail 5 "inbox message has an invalid schema or id: $Id"
    }
    # Compatibility with the earliest schema-1 records installed during rollout:
    # originals derive their own conversation id; first-level replies derive the
    # recorded parent. The next mutation persists the normalized field.
    $conversationProperty = $message.PSObject.Properties['conversation_id']
    if ($null -eq $conversationProperty -or [string]::IsNullOrWhiteSpace([string]$conversationProperty.Value)) {
        $derivedConversation = if ([string]::IsNullOrWhiteSpace([string]$message.in_reply_to)) { $Id } else { [string]$message.in_reply_to }
        if ($null -eq $conversationProperty) {
            $message | Add-Member -NotePropertyName conversation_id -NotePropertyValue $derivedConversation
        } else {
            $message.conversation_id = $derivedConversation
        }
    }
    if ([string]$message.processing_status -notin $script:Statuses -or
        [string]$message.reply_status -notin $script:ReplyStatuses) {
        Fail 5 "inbox message has an invalid status: $Id"
    }
    foreach ($endpoint in @('from_project', 'to_project')) {
        if ([string]$message.$endpoint.id -notmatch '^repo-[a-f0-9]{20}$' -or
            [string]::IsNullOrWhiteSpace([string]$message.$endpoint.name) -or
            ([string]$message.$endpoint.name).Length -gt 120 -or
            [string]$message.$endpoint.name -match '[\x00-\x1f\x7f]') {
            Fail 5 "inbox message has an invalid $endpoint identity: $Id"
        }
    }
    foreach ($task in @($message.queue_tasks)) {
        if ([string]$task -notmatch '^T-\d+$') { Fail 5 "inbox message has an invalid queue task id: $Id" }
    }
    foreach ($replyId in @($message.reply_ids)) {
        if ([string]$replyId -notmatch '^msg-[a-z0-9-]{8,120}$') { Fail 5 "inbox message has an invalid reply id: $Id" }
    }
    Assert-MessageText -Subject ([string]$message.subject) -Body ([string]$message.body)
    if ([string]$message.from_project.id -eq [string]$message.to_project.id) {
        Fail 5 "inbox message has identical sender and recipient: $Id"
    }
    if ([string]$message.conversation_id -notmatch '^msg-[a-z0-9-]{8,120}$') {
        Fail 5 "inbox message has an invalid conversation id: $Id"
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$message.in_reply_to) -and
        [string]$message.in_reply_to -notmatch '^msg-[a-z0-9-]{8,120}$') {
        Fail 5 "inbox message has an invalid in_reply_to id: $Id"
    }
    Assert-DedupeKey -Value ([string]$message.dedupe_key)
    return $message
}

function Write-Message {
    param([string]$Root, $Message)
    $Message.updated_at = Format-UtcNow
    $Message.queue_tasks = @($Message.queue_tasks)
    $Message.remarks = @($Message.remarks)
    $Message.reply_ids = @($Message.reply_ids)
    $path = Get-MessagePath -Root $Root -Id ([string]$Message.id)
    # Get-Item inspects the directory entry itself and therefore also catches a dangling
    # symlink which Test-Path reports as absent. A fixed atomic-write temp name must never
    # be allowed to redirect the narrow cross-project writer outside .inbox/messages.
    $existingPath = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if ($null -ne $existingPath) { Assert-OrchestraPlainFile -Path $path -Label 'inbox message' }
    $tempPath = "$path.tmp"
    $existingTemp = Get-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $existingTemp) { Assert-OrchestraPlainFile -Path $tempPath -Label 'inbox message temporary file' }
    Write-TextAtomic -Path $path `
        -Content ($Message | ConvertTo-Json -Depth 12)
}

function Get-TextOption {
    param([string]$Name, [string]$FileName, [switch]$Required)
    if ($opts.ContainsKey($FileName)) {
        $path = [string]$opts[$FileName]
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Fail 2 "--$FileName not found: $path" }
        $value = [System.IO.File]::ReadAllText($path)
    } else { $value = [string](Opt $Name '') }
    if ($Required -and [string]::IsNullOrWhiteSpace($value)) { Fail 2 "missing required option --$Name or --$FileName" }
    return $value
}

function Assert-MessageText {
    param([string]$Subject, [string]$Body)
    if ([string]::IsNullOrWhiteSpace($Subject) -or $Subject.Length -gt 240 -or $Subject -match '[\x00-\x1f\x7f]') {
        Fail 2 'message subject must contain 1-240 characters and no control characters'
    }
    $bytes = $script:Utf8.GetByteCount($Body)
    if ($bytes -gt 262144) { Fail 2 "message body exceeds the 262144-byte limit ($bytes bytes)" }
}

function New-RandomMessageId {
    return 'msg-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ').ToLowerInvariant() + '-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
}

function Get-StableReplyId {
    param([string]$OriginalId, [string]$FromId, [string]$DedupeKey)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($script:Utf8.GetBytes("$OriginalId|$FromId|$DedupeKey")) }
    finally { $sha.Dispose() }
    $hex = -join ($hash | ForEach-Object { $_.ToString('x2') })
    return 'msg-reply-' + $hex.Substring(0, 32)
}

function Get-StableSendId {
    param([string]$FromId, [string]$ToId, [string]$DedupeKey)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($script:Utf8.GetBytes("$FromId|$ToId|$DedupeKey")) }
    finally { $sha.Dispose() }
    $hex = -join ($hash | ForEach-Object { $_.ToString('x2') })
    return 'msg-send-' + $hex.Substring(0, 32)
}

function Assert-DedupeKey {
    param([string]$Value, [switch]$Required)
    if ($Required -and [string]::IsNullOrWhiteSpace($Value)) { Fail 2 'dedupe key is required' }
    if ($Value.Length -gt 120 -or $Value -match '[\x00-\x1f\x7f]') {
        Fail 2 'dedupe key must contain at most 120 characters and no control characters'
    }
}

function New-MessageRecord {
    param(
        $From, $To, [string]$Id, [string]$Subject, [string]$Body,
        [string]$InReplyTo = '', [string]$ConversationId = '', [string]$DedupeKey = ''
    )
    $now = Format-UtcNow
    if ([string]::IsNullOrWhiteSpace($ConversationId)) { $ConversationId = $Id }
    return [pscustomobject][ordered]@{
        schema            = 'orchestra/inbox-message@1'
        id                = $Id
        from_project      = [pscustomobject][ordered]@{ id = [string]$From.id; name = [string]$From.name }
        to_project        = [pscustomobject][ordered]@{ id = [string]$To.id; name = [string]$To.name }
        created_at        = $now
        updated_at        = $now
        subject           = $Subject
        body              = $Body
        in_reply_to       = $InReplyTo
        conversation_id   = $ConversationId
        dedupe_key        = $DedupeKey
        processing_status = 'new'
        reply_status      = 'none'
        queue_tasks       = @()
        remarks           = @()
        reply_ids         = @()
    }
}

function Write-NewMessage {
    param([string]$Root, $Message, [switch]$Idempotent, [switch]$RecoverExisting)
    Assert-InboxExists $Root
    $lock = Get-InboxLockPath $Root
    Acquire-Lock -LockPath $lock
    try {
        $path = Get-MessagePath -Root $Root -Id ([string]$Message.id)
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            if (-not $Idempotent) { Fail 5 "message id already exists: $([string]$Message.id)" }
            $existing = Read-Message -Root $Root -Id ([string]$Message.id)
            foreach ($field in @('id', 'in_reply_to', 'conversation_id', 'dedupe_key')) {
                if ([string]$existing.$field -ne [string]$Message.$field) { Fail 6 "idempotent reply conflicts with existing message $([string]$Message.id)" }
            }
            foreach ($endpoint in @('from_project', 'to_project')) {
                if ([string]$existing.$endpoint.id -ne [string]$Message.$endpoint.id) {
                    Fail 6 "idempotent reply conflicts with existing message $([string]$Message.id)"
                }
            }
            $contentMatches = ([string]$existing.subject -eq [string]$Message.subject -and
                [string]$existing.body -eq [string]$Message.body)
            if (-not $contentMatches -and -not $RecoverExisting) {
                Fail 6 "idempotent message conflicts with existing message $([string]$Message.id)"
            }
            return $existing
        }
        Write-Message -Root $Root -Message $Message
        return $Message
    } finally { Release-Lock -LockPath $lock }
}

function Resolve-Route {
    param([string]$Root, [string]$Target = '')
    $registryPath = Get-Registry
    $registry = Read-OrchestraRegistry $registryPath
    $from = Get-OrchestraRegistryProjectByRoot -Registry $registry -Root $Root
    $to = if ($Target) { Resolve-OrchestraRegistryProject -Registry $registry -Selector $Target } else { $null }
    if ($null -ne $to) {
        if (-not (Test-Path -LiteralPath ([string]$to.root) -PathType Container)) { Fail 4 "destination project root is unavailable: $([string]$to.root)" }
        Assert-InboxExists ([string]$to.root)
    }
    return [pscustomobject]@{ RegistryPath = $registryPath; Registry = $registry; From = $from; To = $to }
}

function Get-AllMessages {
    param([string]$Root)
    Assert-InboxExists $Root
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath (Get-MessagesPath $Root) -File -Filter 'msg-*.json' -ErrorAction SilentlyContinue)) {
        $id = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $items.Add((Read-Message -Root $Root -Id $id))
    }
    return @($items.ToArray() | Sort-Object created_at, id)
}

function Assert-StatusTransition {
    param([string]$From, [string]$To)
    if ($script:Statuses -notcontains $To) { Fail 2 "invalid processing status '$To'" }
    if ($From -eq $To) { return }
    $allowed = @{
        new = @('read')
        read = @('queued', 'rejected')
        queued = @('implemented', 'rejected')
        implemented = @()
        rejected = @()
    }
    if (@($allowed[$From]) -notcontains $To) { Fail 6 "invalid message status transition: $From -> $To" }
}

function Add-Remark {
    param($Message, [string]$Text, [string]$Actor)
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    if ($script:Utf8.GetByteCount($Text) -gt 16384) { Fail 2 'remark exceeds the 16384-byte limit' }
    if ([string]::IsNullOrWhiteSpace($Actor)) { $Actor = 'agent' }
    if ($Actor.Length -gt 120 -or $Actor -match '[\x00-\x1f\x7f]') {
        Fail 2 'remark actor must contain 1-120 characters and no control characters'
    }
    $Message.remarks = @($Message.remarks) + @([pscustomobject][ordered]@{
        at = Format-UtcNow
        actor = $Actor
        text = $Text
    })
}

function Get-TaskIdsFromArchive {
    param([string]$Root)
    $ids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $path = Join-Path $Root '.work/Tasks_Done.md'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return ,$ids }
    $text = [System.IO.File]::ReadAllText($path)
    # Keep the runtime source ASCII-only: cc-config supports Windows PowerShell 5.1,
    # which misdecodes BOM-less UTF-8 before parsing. Regex \u escapes still match the
    # real Russian legacy heading "Active task" without introducing non-ASCII bytes.
    $activeTask = '\u0410\u043A\u0442\u0438\u0432\u043D\u0430\u044F \u0437\u0430\u0434\u0430\u0447\u0430'
    foreach ($m in [regex]::Matches($text, ('(?im)^#{1,6}\s+(?:\[(T-\d+)\](?:\s|$)|' + $activeTask + '\s+(T-\d+)\b)'))) {
        $id = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
        [void]$ids.Add($id.ToUpperInvariant())
    }
    return ,$ids
}

function Add-TaskLinksFromText {
    param([string]$Text, [hashtable]$Links, [string]$FixedTaskId = '')
    $currentTask = $FixedTaskId
    $activeTask = '\u0410\u043A\u0442\u0438\u0432\u043D\u0430\u044F \u0437\u0430\u0434\u0430\u0447\u0430'
    foreach ($line in (($Text -replace "`r`n", "`n") -split "`n")) {
        if (-not $FixedTaskId) {
            $recordHeader = [regex]::Match($line, '^#{1,6}\s+\[([A-Z]+-\d+)\](?:\s|$)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($recordHeader.Success) {
                $recordId = $recordHeader.Groups[1].Value
                $currentTask = if ($recordId -match '^T-') { $recordId } else { '' }
            } else {
                $legacyHeader = [regex]::Match($line, ('^#{1,6}\s+' + $activeTask + '\s+(T-\d+)\b'), [Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if ($legacyHeader.Success) { $currentTask = $legacyHeader.Groups[1].Value }
            }
        }
        $marker = [regex]::Match($line, '^\s*Inbox message:\s*(msg-[a-z0-9-]+)\s*$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($marker.Success -and $currentTask) {
            $messageId = $marker.Groups[1].Value.ToLowerInvariant()
            if (-not $Links.ContainsKey($messageId)) { $Links[$messageId] = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
            [void]$Links[$messageId].Add($currentTask.ToUpperInvariant())
        }
    }
}

function Get-InboxTaskLinks {
    param([string]$Root)
    $links = @{}
    foreach ($name in @('Tasks_Queue.md', 'Tasks_Done.md')) {
        $path = Join-Path $Root ('.work/' + $name)
        if (Test-Path -LiteralPath $path -PathType Leaf) { Add-TaskLinksFromText -Text ([System.IO.File]::ReadAllText($path)) -Links $links }
    }
    $tasksRoot = Join-Path $Root '.work/tasks'
    if (Test-Path -LiteralPath $tasksRoot -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $tasksRoot -Recurse -File -Filter 'task.md' -ErrorAction SilentlyContinue)) {
            $parent = Split-Path -Leaf (Split-Path -Parent $file.FullName)
            if ($parent -match '^T-\d+$') { Add-TaskLinksFromText -Text ([System.IO.File]::ReadAllText($file.FullName)) -Links $links -FixedTaskId $parent }
        }
    }
    return $links
}

function Cmd-Send {
    $root = Get-Root
    Assert-InboxExists $root
    $target = Require-Opt 'to'
    $subject = Require-Opt 'subject'
    $body = Get-TextOption -Name 'body' -FileName 'body-file' -Required
    Assert-MessageText -Subject $subject -Body $body
    $route = Resolve-Route -Root $root -Target $target
    if ([string]$route.From.id -eq [string]$route.To.id) { Fail 2 'send targets another registered project; use local project artifacts for self-notes' }
    $dedupeKey = [string](Opt 'dedupe-key' '')
    Assert-DedupeKey -Value $dedupeKey
    $messageId = if ($dedupeKey) {
        Get-StableSendId -FromId ([string]$route.From.id) -ToId ([string]$route.To.id) -DedupeKey $dedupeKey
    } else { New-RandomMessageId }
    $message = New-MessageRecord -From $route.From -To $route.To -Id $messageId -Subject $subject -Body $body -DedupeKey $dedupeKey
    $message = Write-NewMessage -Root ([string]$route.To.root) -Message $message -Idempotent:([bool]$dedupeKey)
    if ([bool](Opt 'json' $false)) { $message | ConvertTo-Json -Depth 10 }
    else { Write-Output "sent id=$($message.id) from=$($route.From.name) to=$($route.To.name)" }
}

function Cmd-List {
    $root = Get-Root
    $messages = @(Get-AllMessages $root)
    $statusRaw = [string](Opt 'status' '')
    if ($statusRaw) {
        $wanted = @($statusRaw -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
        foreach ($status in $wanted) { if ($script:Statuses -notcontains $status) { Fail 2 "invalid processing status '$status'" } }
        $messages = @($messages | Where-Object { $wanted -contains [string]$_.processing_status })
    }
    if ([bool](Opt 'json' $false)) { [pscustomobject]@{ count = $messages.Count; messages = $messages } | ConvertTo-Json -Depth 12 }
    else {
        foreach ($message in $messages) {
            Write-Output "$($message.id)  $($message.processing_status)/$($message.reply_status)  from=$($message.from_project.name)  $($message.subject)"
        }
        Write-Output "count=$($messages.Count)"
    }
}

function Cmd-Show {
    $root = Get-Root
    $message = Read-Message -Root $root -Id (Require-Opt 'id')
    if ([bool](Opt 'json' $false)) { $message | ConvertTo-Json -Depth 12 }
    else { $message | ConvertTo-Json -Depth 12 }
}

function Cmd-Mark {
    $root = Get-Root
    Assert-InboxExists $root
    $id = Require-Opt 'id'
    $targetStatus = Require-Opt 'status'
    $actor = [string](Opt 'actor' 'agent')
    $lock = Get-InboxLockPath $root
    Acquire-Lock -LockPath $lock
    try {
        $message = Read-Message -Root $root -Id $id
        Assert-StatusTransition -From ([string]$message.processing_status) -To $targetStatus
        $tasks = @()
        if ($opts.ContainsKey('task')) {
            $tasks = @($opts['task'] | ForEach-Object { ([string]$_).ToUpperInvariant() })
            foreach ($task in $tasks) { if ($task -notmatch '^T-\d+$') { Fail 2 "invalid task id: $task" } }
        }
        if ($tasks.Count -gt 0 -and $targetStatus -ne 'queued') {
            Fail 2 '--task is accepted only while marking a message queued'
        }
        if ($targetStatus -eq 'queued' -and @($message.queue_tasks).Count -eq 0 -and $tasks.Count -eq 0) {
            Fail 2 'queued status requires at least one --task T-NNN'
        }
        if ($targetStatus -eq 'implemented') {
            $linkedTasks = @($message.queue_tasks)
            if ($linkedTasks.Count -eq 0) { Fail 6 'implemented status requires linked queue tasks' }
            $done = Get-TaskIdsFromArchive $root
            $missing = @($linkedTasks | Where-Object { -not $done.Contains([string]$_) })
            if ($missing.Count -gt 0) {
                Fail 6 ('implemented status requires every linked task in Tasks_Done.md; missing: ' + ($missing -join ', '))
            }
        }
        $message.queue_tasks = @(@($message.queue_tasks) + $tasks | Sort-Object -Unique)
        $message.processing_status = $targetStatus
        Add-Remark -Message $message -Text ([string](Opt 'remark' '')) -Actor $actor
        Write-Message -Root $root -Message $message
    } finally { Release-Lock -LockPath $lock }
    if ([bool](Opt 'json' $false)) { $message | ConvertTo-Json -Depth 12 }
    else { Write-Output "updated id=$id status=$targetStatus tasks=$(@($message.queue_tasks) -join ',')" }
}

function Cmd-Reconcile {
    $root = Get-Root
    Assert-InboxExists $root
    $links = Get-InboxTaskLinks $root
    $updated = [System.Collections.Generic.List[string]]::new()
    $lock = Get-InboxLockPath $root
    Acquire-Lock -LockPath $lock
    try {
        foreach ($message in @(Get-AllMessages $root)) {
            $id = [string]$message.id
            if (-not $links.ContainsKey($id)) { continue }
            if ([string]$message.processing_status -in @('implemented', 'rejected')) { continue }
            $tasks = @($links[$id] | Sort-Object)
            $merged = @(@($message.queue_tasks) + $tasks | Sort-Object -Unique)
            $changed = (@($message.queue_tasks) -join ',') -ne ($merged -join ',')
            $message.queue_tasks = $merged
            if ([string]$message.processing_status -eq 'read' -and $merged.Count -gt 0) {
                $message.processing_status = 'queued'
                Add-Remark -Message $message -Text ('Linked to queue task(s): ' + ($merged -join ', ')) -Actor 'inbox-reconcile'
                $changed = $true
            }
            if ($changed) { Write-Message -Root $root -Message $message; $updated.Add($id) }
        }
    } finally { Release-Lock -LockPath $lock }
    $result = [pscustomobject]@{ updated = @($updated.ToArray()); count = $updated.Count }
    if ([bool](Opt 'json' $false)) { $result | ConvertTo-Json -Depth 5 }
    else { Write-Output "reconciled=$($updated.Count)" }
}

function Cmd-Actionable {
    $root = Get-Root
    $done = Get-TaskIdsFromArchive $root
    $new = [System.Collections.Generic.List[string]]::new()
    $unresolved = [System.Collections.Generic.List[string]]::new()
    $completable = [System.Collections.Generic.List[string]]::new()
    $replyPending = [System.Collections.Generic.List[string]]::new()
    foreach ($message in @(Get-AllMessages $root)) {
        $status = [string]$message.processing_status
        if ($status -in @('implemented', 'rejected') -and [string]$message.reply_status -ne 'final') {
            $replyPending.Add([string]$message.id)
            continue
        }
        if ($status -eq 'new') { $new.Add([string]$message.id); continue }
        if ($status -eq 'read' -and [string]$message.reply_status -eq 'none' -and
            [string]::IsNullOrWhiteSpace([string]$message.in_reply_to)) {
            $unresolved.Add([string]$message.id)
            continue
        }
        if ($status -eq 'queued' -and @($message.queue_tasks).Count -gt 0) {
            $allDone = $true
            foreach ($task in @($message.queue_tasks)) { if (-not $done.Contains([string]$task)) { $allDone = $false; break } }
            if ($allDone) { $completable.Add([string]$message.id) }
        }
    }
    $result = [pscustomobject][ordered]@{
        count = $new.Count + $unresolved.Count + $completable.Count + $replyPending.Count
        new = @($new.ToArray())
        unresolved = @($unresolved.ToArray())
        completable = @($completable.ToArray())
        reply_pending = @($replyPending.ToArray())
    }
    if ([bool](Opt 'json' $false)) { $result | ConvertTo-Json -Depth 5 }
    else { Write-Output "actionable=$($result.count) new=$($new.Count) unresolved=$($unresolved.Count) completable=$($completable.Count) reply_pending=$($replyPending.Count)" }
}

function Cmd-Reply {
    $root = Get-Root
    Assert-InboxExists $root
    $id = Require-Opt 'id'
    $replyStatus = [string](Opt 'reply-status' 'acknowledged')
    if ($replyStatus -notin @('acknowledged', 'final')) { Fail 2 "invalid --reply-status '$replyStatus'" }
    $dedupeKey = Require-Opt 'dedupe-key'
    Assert-DedupeKey -Value $dedupeKey -Required
    $body = Get-TextOption -Name 'body' -FileName 'body-file' -Required
    $original = Read-Message -Root $root -Id $id
    if ($replyStatus -eq 'final' -and [string]$original.processing_status -notin @('implemented', 'rejected')) {
        Fail 6 'a final reply requires the original message to be implemented or rejected first'
    }
    $route = Resolve-Route -Root $root -Target ([string]$original.from_project.id)
    if ([string]$route.From.id -ne [string]$original.to_project.id) { Fail 6 'current project is not the recipient recorded by the original message' }
    $defaultSubject = 'Re: ' + [string]$original.subject
    if ($defaultSubject.Length -gt 240) { $defaultSubject = $defaultSubject.Substring(0, 240) }
    $subject = [string](Opt 'subject' $defaultSubject)
    Assert-MessageText -Subject $subject -Body $body
    $replyId = Get-StableReplyId -OriginalId $id -FromId ([string]$route.From.id) -DedupeKey $dedupeKey
    $conversationId = if ([string]::IsNullOrWhiteSpace([string]$original.conversation_id)) { $id } else { [string]$original.conversation_id }
    $reply = New-MessageRecord -From $route.From -To $route.To -Id $replyId -Subject $subject -Body $body `
        -InReplyTo $id -ConversationId $conversationId -DedupeKey $dedupeKey
    $sourceAlreadyRecorded = @($original.reply_ids) -contains $replyId
    $reply = Write-NewMessage -Root ([string]$route.To.root) -Message $reply -Idempotent `
        -RecoverExisting:(-not $sourceAlreadyRecorded)
    Maybe-Fault 'after-reply-delivery'

    $lock = Get-InboxLockPath $root
    Acquire-Lock -LockPath $lock
    try {
        $current = Read-Message -Root $root -Id $id
        $alreadyRecorded = @($current.reply_ids) -contains $replyId
        if ($alreadyRecorded -and $replyStatus -eq 'final' -and [string]$current.reply_status -ne 'final') {
            Fail 6 'the dedupe key was already used for an acknowledged reply; use a distinct key for the final reply'
        }
        $current.reply_ids = @(@($current.reply_ids) + @($replyId) | Sort-Object -Unique)
        if ($replyStatus -eq 'final' -or [string]$current.reply_status -eq 'final') { $current.reply_status = 'final' }
        else { $current.reply_status = 'acknowledged' }
        if (-not $alreadyRecorded) {
            Add-Remark -Message $current -Text ("Reply sent: $replyId ($replyStatus)") -Actor ([string](Opt 'actor' 'agent'))
            Write-Message -Root $root -Message $current
        }
    } finally { Release-Lock -LockPath $lock }
    if ([bool](Opt 'json' $false)) { $reply | ConvertTo-Json -Depth 12 }
    else { Write-Output "replied id=$replyId to=$($route.To.name) original=$id status=$replyStatus" }
}

try {
    switch ($Command) {
        'send' { Cmd-Send }
        'list' { Cmd-List }
        'show' { Cmd-Show }
        'mark' { Cmd-Mark }
        'reconcile' { Cmd-Reconcile }
        'actionable' { Cmd-Actionable }
        'reply' { Cmd-Reply }
        default { Fail 2 "unknown command '$Command' (expected send, list, show, mark, reconcile, actionable, or reply)" }
    }
    exit 0
} catch {
    exit (Resolve-CatchExit $_ 'INBERR' 'inbox' 'ORCHESTRA_INBOX_DEBUG')
}
