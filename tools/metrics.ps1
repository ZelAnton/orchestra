<#
.SYNOPSIS
    Read-only aggregation of Orchestra operational metrics.
.DESCRIPTION
    Uses `.work/events.jsonl` as the primary source and completed batch blocks in
    `.work/journal.md` as a field-level fallback. It never writes under --work and
    never acquires orchestrator.lock. Malformed JSONL lines are skipped independently.
.EXAMPLE
    pwsh -File tools/metrics.ps1 aggregate --work /abs/.work --last 5
    pwsh -File tools/metrics.ps1 aggregate --work /abs/.work --since 2026-07-01
.NOTES
    Exit codes: 0 success (including no data), 2 usage, 3 input read failure.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$Command = if ($args.Count -ge 1) { [string]$args[0] } else { '' }
$opts = @{}
for ($i = 1; $i -lt $args.Count; $i++) {
    $arg = [string]$args[$i]
    if ($arg -notlike '--*') { throw "METRICSERR|2|unexpected argument '$arg'" }
    $key = $arg.Substring(2)
    if ($key -eq 'json') { $opts[$key] = $true; continue }
    $i++
    if ($i -ge $args.Count) { throw "METRICSERR|2|missing value for --$key" }
    $opts[$key] = [string]$args[$i]
}

function Fail { param([int]$Code, [string]$Message) throw ('METRICSERR|' + $Code + '|' + $Message) }
function Opt { param([string]$Name, $Default = $null) if ($opts.ContainsKey($Name)) { return $opts[$Name] }; return $Default }
function Has-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    return ($null -ne $Object.PSObject.Properties[$Name])
}
function Get-Prop { param($Object, [string]$Name) if (Has-Prop $Object $Name) { return $Object.$Name }; return $null }
function Get-FirstProp {
    param($Object, [string[]]$Names)
    foreach ($name in $Names) {
        if (Has-Prop $Object $name) {
            $value = $Object.$name
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) { return $value }
        }
    }
    return $null
}
function To-Number {
    param($Value)
    if ($null -eq $Value) { return $null }
    $number = 0.0
    if ([double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -and $number -ge 0) { return $number }
    return $null
}
function To-Time {
    param($Value)
    if ($null -eq $Value) { return $null }
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return $parsed.ToUniversalTime() }
    return $null
}
function Set-Earlier { param($Object, [string]$Name, $Value) if ($null -ne $Value -and ($null -eq $Object.$Name -or $Value -lt $Object.$Name)) { $Object.$Name = $Value } }
function Set-Later { param($Object, [string]$Name, $Value) if ($null -ne $Value -and ($null -eq $Object.$Name -or $Value -gt $Object.$Name)) { $Object.$Name = $Value } }

function New-Batch {
    param([string]$Id)
    [pscustomobject]@{
        Id=$Id; Start=$null; End=$null; LastSeen=$null; Tasks=@{}; R=@{}; F=$null; CI=$null
        Escalated=@{}; Quarantined=@{}; Interrupted=$false; Recovered=$false
        Tokens=0.0; TokenObserved=$false; CostUsd=0.0; CostObserved=$false
        JournalTaskCount=$null; JournalEscalated=$null; JournalQuarantined=$null
        SourceEvents=$false; SourceJournal=$false
    }
}
function Get-Batch {
    param([hashtable]$Batches, [string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
    if (-not $Batches.ContainsKey($Id)) { $Batches[$Id] = New-Batch $Id }
    return $Batches[$Id]
}
function Get-Task {
    param($Batch, [string]$TaskId)
    if ($null -eq $Batch -or [string]::IsNullOrWhiteSpace($TaskId)) { return $null }
    if (-not $Batch.Tasks.ContainsKey($TaskId)) { $Batch.Tasks[$TaskId] = [pscustomobject]@{ Id=$TaskId; Queued=$null; Verified=$null } }
    return $Batch.Tasks[$TaskId]
}

function Read-EventStream {
    param([string]$Path)
    $events = New-Object Collections.Generic.List[object]
    $invalid = 0
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]@{ Events=$events; Invalid=0; Present=$false } }
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $lineBytes = New-Object Collections.Generic.List[byte]
        $decoder = New-Object Text.UTF8Encoding($false, $true)
        $buffer = New-Object 'byte[]' 65536
        try {
            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                for ($offset = 0; $offset -lt $read; $offset++) {
                    $byte = $buffer[$offset]
                    if ($byte -ne 10) { $lineBytes.Add($byte); continue }
                    try { $line = $decoder.GetString($lineBytes.ToArray()).TrimEnd("`r") } catch { $invalid++; $lineBytes.Clear(); continue }
                    $lineBytes.Clear()
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    try { $event = $line | ConvertFrom-Json } catch { $invalid++; continue }
                    if ($null -eq $event -or -not (Has-Prop $event 'type') -or $null -eq (To-Time (Get-Prop $event 'occurred_at'))) { $invalid++; continue }
                    [void]$events.Add($event)
                }
            }
            # Like the engine tail reader, never consume an unterminated final record.
            if ($lineBytes.Count -gt 0) { $invalid++ }
        } finally { $stream.Dispose() }
    } catch { Fail 3 "cannot read $Path ($($_.Exception.Message))" }
    $seen = New-Object 'Collections.Generic.HashSet[string]'
    $deduped = New-Object Collections.Generic.List[object]
    foreach ($event in $events) {
        $id = [string](Get-Prop $event 'event_id')
        if ($id -and -not $seen.Add($id)) { continue }
        [void]$deduped.Add($event)
    }
    return [pscustomobject]@{ Events=$deduped; Invalid=$invalid; Present=$true }
}

function Get-EventNumber {
    param($Event, [string[]]$Names)
    $raw = Get-FirstProp (Get-Prop $Event 'payload') $Names
    if ($null -eq $raw) { $raw = Get-FirstProp $Event $Names }
    return (To-Number $raw)
}
function Get-AttemptNumber {
    param($Event, [string[]]$Names)
    $direct = Get-EventNumber $Event $Names
    if ($null -ne $direct) { return $direct }
    $payload = Get-Prop $Event 'payload'
    foreach ($name in $Names) {
        $node = Get-Prop $payload $name
        if ($null -ne $node -and $node -isnot [string]) {
            $number = To-Number (Get-FirstProp $node @('attempts','runs','count','total'))
            if ($null -ne $number) { return $number }
        }
    }
    return $null
}
function Add-Usage {
    param($Batch, $Event)
    if ($null -eq $Batch) { return }
    $payload = Get-Prop $Event 'payload'
    $usage = Get-FirstProp $payload @('token_usage','usage')
    $total = Get-EventNumber $Event @('total_tokens','tokens','token_count')
    if ($null -eq $total -and $null -ne $usage -and $usage -isnot [string]) {
        $total = To-Number (Get-FirstProp $usage @('total_tokens','tokens','total'))
        if ($null -eq $total) {
            $sum = 0.0; $found = $false
            foreach ($name in @('input_tokens','output_tokens','cache_creation_input_tokens','cache_read_input_tokens')) {
                $number = To-Number (Get-Prop $usage $name)
                if ($null -ne $number) { $sum += $number; $found = $true }
            }
            if ($found) { $total = $sum }
        }
    }
    if ($null -ne $total) { $Batch.Tokens += $total; $Batch.TokenObserved = $true }
    $cost = Get-EventNumber $Event @('cost_usd','usd_cost','total_cost_usd')
    if ($null -ne $cost) { $Batch.CostUsd += $cost; $Batch.CostObserved = $true }
}

function Apply-Events {
    param([hashtable]$Batches, $Events)
    $taskToBatch = @{}
    foreach ($event in $Events) {
        if ([string](Get-Prop $event 'type') -eq 'task.captured') {
            $taskId = [string](Get-Prop $event 'task_id'); $batchId = [string](Get-Prop $event 'batch_id')
            if ($taskId -and $batchId) { $taskToBatch[$taskId] = $batchId }
        }
    }
    foreach ($event in $Events) {
        $type = [string](Get-Prop $event 'type'); $payload = Get-Prop $event 'payload'
        $taskId = [string](Get-Prop $event 'task_id'); $batchId = [string](Get-Prop $event 'batch_id')
        if (-not $batchId -and $taskId -and $taskToBatch.ContainsKey($taskId)) { $batchId = $taskToBatch[$taskId] }
        $batch = Get-Batch $Batches $batchId
        if ($null -eq $batch) { continue }
        $batch.SourceEvents = $true
        $at = To-Time (Get-Prop $event 'occurred_at'); Set-Later $batch 'LastSeen' $at
        if ($type -eq 'cohort.opened') { Set-Earlier $batch 'Start' $at }
        if ($type -eq 'cohort.closed') { Set-Later $batch 'End' $at }

        if ($type -eq 'task.captured') {
            $task = Get-Task $batch $taskId
            $queued = To-Time (Get-FirstProp $payload @('queued_at','enqueued_at','captured_at'))
            if ($null -eq $queued) { $queued = $at }
            Set-Earlier $task 'Queued' $queued
        }
        if ($type -eq 'task.status_changed') {
            $task = Get-Task $batch $taskId
            $to = [string](Get-FirstProp $payload @('to','status')); $toLower = $to.ToLowerInvariant()
            if ($toLower -match 'на ревью|reviewing|review$') {
                $batch.R[$taskId] = if ($batch.R.ContainsKey($taskId)) { [double]$batch.R[$taskId] + 1 } else { 1.0 }
            }
            if ($toLower -match 'готова к слиянию|verified|проверена|выполнена|done|опубликована') {
                $verified = To-Time (Get-FirstProp $payload @('verified_at','completed_at'))
                if ($null -eq $verified) { $verified = $at }
                Set-Earlier $task 'Verified' $verified
            }
            if ($toLower -match 'эскал') { $batch.Escalated[$taskId] = $true }
            if ($toLower -match 'конфликт|карантин|quarant') { $batch.Quarantined[$taskId] = $true }
            $review = Get-EventNumber $event @('r_attempts','review_attempts','review_cycles','r_cycles')
            if ($null -ne $review -and $taskId) { $batch.R[$taskId] = $review }
        }

        $fix = Get-AttemptNumber $event @('f_attempts','fix_attempts','integration_fix_cycles','f_cycles')
        if ($null -ne $fix) { $batch.F = $fix }
        $ci = Get-AttemptNumber $event @('ci_attempts','ci_runs','ci')
        if ($null -ne $ci) { $batch.CI = $ci }

        $interrupted = Get-FirstProp $payload @('interrupted','was_interrupted')
        $stopReason = [string](Get-FirstProp $payload @('stop_reason','outcome_reason'))
        if ($type -match '(^|\.)(interrupted|crashed|cancelled)$|^recovery\.started$' -or $interrupted -eq $true -or $stopReason -match 'crash|interrupt|timeout|cancel') { $batch.Interrupted = $true }
        $recovered = Get-FirstProp $payload @('recovered','recovery_success')
        $outcome = [string](Get-FirstProp $payload @('outcome','result'))
        if (($type -match '^recovery\.(completed|succeeded)$' -and $outcome -notmatch 'fail') -or $recovered -eq $true) { $batch.Recovered = $true }
        Add-Usage $batch $event
    }
    foreach ($batch in $Batches.Values) { if ($batch.Interrupted -and $null -ne $batch.End) { $batch.Recovered = $true } }
}

function Apply-Journal {
    param([hashtable]$Batches, [string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try { $text = [IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false, $true))) }
    catch { Fail 3 "cannot read $Path ($($_.Exception.Message))" }
    if ([string]::IsNullOrWhiteSpace($text)) { return $true }
    $matches = [regex]::Matches($text, '(?m)^## Batch (?<id>B-[^\s]+)\s+—\s+(?<start>.+?)\s+→\s+(?<end>.+?)\s*$')
    for ($i = 0; $i -lt $matches.Count; $i++) {
        $match = $matches[$i]
        $blockEnd = if ($i + 1 -lt $matches.Count) { $matches[$i + 1].Index } else { $text.Length }
        $block = $text.Substring($match.Index, $blockEnd - $match.Index)
        $batch = Get-Batch $Batches $match.Groups['id'].Value; $batch.SourceJournal = $true
        $start = To-Time $match.Groups['start'].Value.Trim(); $end = To-Time $match.Groups['end'].Value.Trim()
        Set-Earlier $batch 'Start' $start; Set-Later $batch 'End' $end; Set-Later $batch 'LastSeen' $end

        foreach ($taskMatch in [regex]::Matches($block, '(?m)^- \[(?<id>T-\d+)\].*$')) {
            $taskId = $taskMatch.Groups['id'].Value; [void](Get-Task $batch $taskId); $line = $taskMatch.Value
            $review = [regex]::Match($line, 'циклов ревью=(?<n>\d+)', 'IgnoreCase')
            if (-not $batch.R.ContainsKey($taskId) -and $review.Success) { $batch.R[$taskId] = [double]$review.Groups['n'].Value }
            if ($line -match 'quarantined=|карантин') { $batch.Quarantined[$taskId] = $true }
            if ($line -match 'эскал') { $batch.Escalated[$taskId] = $true }
        }
        $count = [regex]::Match($block, 'задач в когорте:\s*(?<n>\d+)', 'IgnoreCase')
        if ($count.Success) { $batch.JournalTaskCount = [int]$count.Groups['n'].Value }
        if ($null -eq $batch.F) {
            $fix = [regex]::Match($block, 'Интеграционных F-циклов:\s*(?<n>\d+)', 'IgnoreCase')
            if ($fix.Success) { $batch.F = [double]$fix.Groups['n'].Value }
        }
        if ($null -eq $batch.CI) {
            $ci = [regex]::Match($block, 'CI:\s*(?<n>\d+)\s+попыт', 'IgnoreCase')
            if ($ci.Success) { $batch.CI = [double]$ci.Groups['n'].Value }
            elseif ($block -match 'CI:\s*прош[её]л') { $batch.CI = 1.0 }
            elseif ($block -match 'CI:\s*пропущен') { $batch.CI = 0.0 }
        }
        $outcome = [regex]::Match($block, 'Итог:\s*(?<merged>\d+)\s+слито,\s*(?<q>\d+)\s+карантин.*?,\s*(?<e>\d+)\s+эскалировано', 'IgnoreCase')
        if ($outcome.Success) {
            $batch.JournalQuarantined = [int]$outcome.Groups['q'].Value
            $batch.JournalEscalated = [int]$outcome.Groups['e'].Value
        }
        # Cost is intentionally event-only: the pre-T-248 journal has no stable usage
        # contract, so prose estimates must not become an apparently exact value.
    }
    return $true
}

function Get-Stat {
    param([object[]]$Values)
    $numbers = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object)
    if ($numbers.Count -eq 0) { return $null }
    $sum = 0.0; foreach ($number in $numbers) { $sum += $number }
    $index = [Math]::Ceiling(0.95 * $numbers.Count) - 1
    return [pscustomobject]@{ n=$numbers.Count; average=[Math]::Round($sum / $numbers.Count, 2); p95=[Math]::Round($numbers[$index], 2) }
}
function Format-Number { param($Value) if ($null -eq $Value) { return 'недоступно' }; return ([double]$Value).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture) }
function Format-Duration {
    param($Milliseconds)
    if ($null -eq $Milliseconds) { return 'недоступно' }
    $span = [TimeSpan]::FromMilliseconds([double]$Milliseconds)
    if ($span.TotalDays -ge 1) { return $span.TotalDays.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture) + ' д' }
    if ($span.TotalHours -ge 1) { return $span.TotalHours.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture) + ' ч' }
    if ($span.TotalMinutes -ge 1) { return $span.TotalMinutes.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture) + ' мин' }
    return $span.TotalSeconds.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture) + ' с'
}
function Format-Percent { param($Numerator, $Denominator) if ($Denominator -le 0) { return 'недоступно' }; return ([Math]::Round(100.0 * $Numerator / $Denominator, 2)).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture) + '%' }

function Cmd-Aggregate {
    $work = [string](Opt 'work' '')
    if ([string]::IsNullOrWhiteSpace($work)) { Fail 2 'missing required option --work' }
    if (-not (Test-Path -LiteralPath $work -PathType Container)) { Fail 3 "work directory does not exist: $work" }
    foreach ($key in $opts.Keys) { if (@('work','last','since','json') -notcontains $key) { Fail 2 "unknown option --$key" } }
    if ($opts.ContainsKey('last') -and $opts.ContainsKey('since')) { Fail 2 'use either --last or --since, not both' }

    $last = $null; $since = $null
    if ($opts.ContainsKey('last')) {
        $raw = [string]$opts['last']
        if ($raw -notmatch '^\d+$' -or [int]$raw -lt 1) { Fail 2 '--last must be a positive integer' }
        $last = [int]$raw
    } elseif ($opts.ContainsKey('since')) {
        $raw = [string]$opts['since']
        if ($raw -notmatch '^\d{4}-\d{2}-\d{2}$') { Fail 2 '--since must be YYYY-MM-DD' }
        $since = To-Time ($raw + 'T00:00:00Z')
        if ($null -eq $since -or $since.ToString('yyyy-MM-dd') -ne $raw) { Fail 2 '--since is not a valid calendar date' }
    } else { $last = 10 }

    $stream = Read-EventStream (Join-Path $work 'events.jsonl')
    $batches = @{}; Apply-Events $batches $stream.Events
    $journalPresent = Apply-Journal $batches (Join-Path $work 'journal.md')
    $eventsStatus = if (-not $stream.Present) { 'missing' } elseif ($stream.Events.Count -eq 0) { 'empty' } else { 'ok' }
    $selected = @($batches.Values | Where-Object {
        $stamp = if ($null -ne $_.End) { $_.End } elseif ($null -ne $_.LastSeen) { $_.LastSeen } else { $_.Start }
        $null -ne $stamp -and ($null -eq $since -or $stamp -ge $since)
    } | Sort-Object @{Expression={ if ($null -ne $_.End) { $_.End } elseif ($null -ne $_.LastSeen) { $_.LastSeen } else { $_.Start } }}, Id)
    if ($null -ne $last -and $selected.Count -gt $last) { $selected = @($selected | Select-Object -Last $last) }
    $selector = if ($null -ne $since) { "since $($since.ToString('yyyy-MM-dd'))" } else { "last $last" }

    if ($selected.Count -eq 0) {
        $empty = [ordered]@{ status='no_data'; batches=0; selector=$selector; sources=[ordered]@{ events_status=$eventsStatus; event_count=$stream.Events.Count; journal_present=[bool]$journalPresent; skipped_jsonl_lines=$stream.Invalid } }
        if ([bool](Opt 'json' $false)) { Write-Output ($empty | ConvertTo-Json -Depth 5 -Compress) }
        else {
            Write-Output 'Нет данных: выбранный период не содержит батчей.'
            if ($eventsStatus -eq 'missing') { Write-Output 'Диагностика: events.jsonl отсутствует.' }
            elseif ($eventsStatus -eq 'empty') { Write-Output 'Диагностика: events.jsonl пуст.' }
            if ($stream.Invalid -gt 0) { Write-Output "Пропущено некорректных строк JSONL: $($stream.Invalid)" }
        }
        return
    }

    $rValues=@(); $fValues=@(); $ciValues=@(); $leadValues=@()
    $taskTotal=0; $escalatedTotal=0; $quarantinedTotal=0
    $interrupted=0; $recovered=0; $tokens=0.0; $tokenObserved=$false; $costUsd=0.0; $costObserved=$false
    foreach ($batch in $selected) {
        foreach ($taskId in $batch.Tasks.Keys) {
            $task=$batch.Tasks[$taskId]
            if ($null -ne $task.Queued -and $null -ne $task.Verified -and $task.Verified -ge $task.Queued) { $leadValues += ($task.Verified - $task.Queued).TotalMilliseconds }
        }
        foreach ($taskId in $batch.R.Keys) { $rValues += [double]$batch.R[$taskId] }
        if ($null -ne $batch.F) { $fValues += $batch.F }; if ($null -ne $batch.CI) { $ciValues += $batch.CI }
        $batchTaskTotal=$batch.Tasks.Count; if ($null -ne $batch.JournalTaskCount) { $batchTaskTotal=[Math]::Max($batchTaskTotal,$batch.JournalTaskCount) }; $taskTotal += $batchTaskTotal
        $batchEscalated=$batch.Escalated.Count; if ($null -ne $batch.JournalEscalated) { $batchEscalated=[Math]::Max($batchEscalated,$batch.JournalEscalated) }; $escalatedTotal += $batchEscalated
        $batchQuarantined=$batch.Quarantined.Count; if ($null -ne $batch.JournalQuarantined) { $batchQuarantined=[Math]::Max($batchQuarantined,$batch.JournalQuarantined) }; $quarantinedTotal += $batchQuarantined
        if ($batch.Interrupted) { $interrupted++; if ($batch.Recovered) { $recovered++ } }
        if ($batch.TokenObserved) { $tokens += $batch.Tokens; $tokenObserved=$true }
        if ($batch.CostObserved) { $costUsd += $batch.CostUsd; $costObserved=$true }
    }
    $completedTasks=@($selected | ForEach-Object { $_.Tasks.Values } | Where-Object { $null -ne $_.Verified }).Count
    if ($completedTasks -eq 0) { $completedTasks=$taskTotal-$escalatedTotal-$quarantinedTotal; if ($completedTasks -lt 0) { $completedTasks=0 } }
    $rStat=Get-Stat $rValues; $fStat=Get-Stat $fValues; $ciStat=Get-Stat $ciValues; $leadStat=Get-Stat $leadValues
    $tokensPerTask=if ($tokenObserved -and $completedTasks -gt 0) { [Math]::Round($tokens/$completedTasks,2) } else { $null }
    $costPerTask=if ($costObserved -and $completedTasks -gt 0) { [Math]::Round($costUsd/$completedTasks,4) } else { $null }

    $result=[ordered]@{
        status='ok'; batches=$selected.Count; batch_ids=@($selected | ForEach-Object { $_.Id }); selector=$selector
        attempts=[ordered]@{ review_r=$rStat; fix_f=$fStat; ci=$ciStat }; lead_time_queue_to_verified_ms=$leadStat
        escalation=[ordered]@{ tasks=$escalatedTotal; total_tasks=$taskTotal; share=if ($taskTotal -gt 0) { [Math]::Round($escalatedTotal/[double]$taskTotal,4) } else { $null } }
        quarantine=[ordered]@{ tasks=$quarantinedTotal; total_tasks=$taskTotal; share=if ($taskTotal -gt 0) { [Math]::Round($quarantinedTotal/[double]$taskTotal,4) } else { $null } }
        recovery=if ($interrupted -gt 0) { [ordered]@{ interruptions=$interrupted; recovered=$recovered; success_share=[Math]::Round($recovered/[double]$interrupted,4) } } else { $null }
        cost_per_completed_task=[ordered]@{ completed_tasks=$completedTasks; tokens=$tokensPerTask; usd=$costPerTask; available=($null -ne $tokensPerTask -or $null -ne $costPerTask) }
        sources=[ordered]@{ events_status=$eventsStatus; event_count=$stream.Events.Count; journal_present=[bool]$journalPresent; skipped_jsonl_lines=$stream.Invalid }
    }
    if ([bool](Opt 'json' $false)) { Write-Output ($result | ConvertTo-Json -Depth 10 -Compress); return }

    Write-Output "Orchestra metrics — батчей: $($selected.Count) ($selector)"
    Write-Output '| Метрика | Выборка | Среднее | p95 / доля |'; Write-Output '|---|---:|---:|---:|'
    Write-Output "| R-попытки (review) | $(if ($null -ne $rStat) {$rStat.n} else {0}) | $(if ($null -ne $rStat) {Format-Number $rStat.average} else {'недоступно'}) | $(if ($null -ne $rStat) {Format-Number $rStat.p95} else {'недоступно'}) |"
    Write-Output "| F-попытки (fix-cycle) | $(if ($null -ne $fStat) {$fStat.n} else {0}) | $(if ($null -ne $fStat) {Format-Number $fStat.average} else {'недоступно'}) | $(if ($null -ne $fStat) {Format-Number $fStat.p95} else {'недоступно'}) |"
    Write-Output "| CI-прогоны | $(if ($null -ne $ciStat) {$ciStat.n} else {0}) | $(if ($null -ne $ciStat) {Format-Number $ciStat.average} else {'недоступно'}) | $(if ($null -ne $ciStat) {Format-Number $ciStat.p95} else {'недоступно'}) |"
    Write-Output "| Lead time очередь → verified | $(if ($null -ne $leadStat) {$leadStat.n} else {0}) | $(if ($null -ne $leadStat) {Format-Duration $leadStat.average} else {'недоступно'}) | $(if ($null -ne $leadStat) {Format-Duration $leadStat.p95} else {'недоступно'}) |"
    Write-Output "| Эскалации | $escalatedTotal / $taskTotal | — | $(Format-Percent $escalatedTotal $taskTotal) |"
    Write-Output "| Карантины | $quarantinedTotal / $taskTotal | — | $(Format-Percent $quarantinedTotal $taskTotal) |"
    Write-Output "| Recovery после прерывания | $(if ($interrupted -gt 0) {"$recovered / $interrupted"} else {'недоступно'}) | — | $(if ($interrupted -gt 0) {Format-Percent $recovered $interrupted} else {'недоступно'}) |"
    $costText=if ($null -ne $tokensPerTask) { "$(Format-Number $tokensPerTask) tokens/task" } elseif ($null -ne $costPerTask) { '$'+(Format-Number $costPerTask)+'/task' } else { 'недоступно' }
    Write-Output "| Стоимость на завершённую задачу | $completedTasks | $costText | — |"
    if ($eventsStatus -eq 'missing') { Write-Output 'Диагностика: events.jsonl отсутствует; доступны только fallback-поля journal.md.' }
    elseif ($eventsStatus -eq 'empty') { Write-Output 'Диагностика: events.jsonl пуст; доступны только fallback-поля journal.md.' }
    if ($stream.Invalid -gt 0) { Write-Output "Пропущено некорректных строк JSONL: $($stream.Invalid)" }
}

try {
    switch ($Command) { 'aggregate' { Cmd-Aggregate }; default { Fail 2 "unknown command '$Command'. Valid: aggregate" } }
} catch {
    $message=[string]$_.Exception.Message
    if ($message -like 'METRICSERR|*') { $parts=$message -split '\|',3; [Console]::Error.WriteLine("metrics: $($parts[2])"); exit ([int]$parts[1]) }
    [Console]::Error.WriteLine("metrics: $message"); if ($env:METRICS_DEBUG) { [Console]::Error.WriteLine($_.ScriptStackTrace) }; exit 1
}
