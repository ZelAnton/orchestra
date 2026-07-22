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
. (Join-Path $PSScriptRoot 'common.ps1')
# Shared consumer-side projection layer over events.jsonl (T-286): the single canonical
# Has-Prop/Get-Prop/Get-FirstProp, the numeric/time coercions (To-Number/To-Time), the stream
# reader+dedup (Read-EventStream) and the usage extractor (Get-EventUsage) - the same layer
# outbox.ps1's `metrics` command uses. MUST load AFTER common.ps1 (Read-EventStream reports
# read failure through common.ps1's Fail).
. (Join-Path $PSScriptRoot 'events-common.ps1')
$script:ErrPrefix = 'METRICSERR'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

function Set-Earlier { param($Object, [string]$Name, $Value) if ($null -ne $Value -and ($null -eq $Object.$Name -or $Value -lt $Object.$Name)) { $Object.$Name = $Value } }
function Set-Later { param($Object, [string]$Name, $Value) if ($null -ne $Value -and ($null -eq $Object.$Name -or $Value -gt $Object.$Name)) { $Object.$Name = $Value } }

function New-Batch {
    param([string]$Id)
    [pscustomobject]@{
        Id=$Id; Start=$null; End=$null; LastSeen=$null; Tasks=@{}; R=@{}; F=$null; CI=$null
        Escalated=@{}; Quarantined=@{}; Interrupted=$false; Recovered=$false
        Tokens=0.0; TokenObserved=$false; CostUsd=0.0; CostObserved=$false
        EstimatedTokens=0.0; EstimatedTokenObserved=$false
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

# Read-EventStream (the stream reader + event_id dedup) now lives in tools/events-common.ps1,
# shared with outbox.ps1's `metrics` command (T-286).

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
    # Single shared usage interpretation (tools/events-common.ps1 Get-EventUsage): the
    # total-tokens rule (explicit total wins, else nested token_usage/usage object, else the
    # flat component sum) plus the cost lookup - identical to outbox.ps1's `metrics` command.
    # T-248: an estimate is a heuristic, never a provider-exact figure, so it is routed to a
    # SEPARATE bucket and never summed into the actual-token total (OBSERVABILITY_PLATFORM_PLAN §8).
    $usage = Get-EventUsage $Event
    if ($null -ne $usage.Total) {
        if ($usage.Estimated) { $Batch.EstimatedTokens += $usage.Total; $Batch.EstimatedTokenObserved = $true }
        else { $Batch.Tokens += $usage.Total; $Batch.TokenObserved = $true }
    }
    if ($null -ne $usage.Cost) { $Batch.CostUsd += $usage.Cost; $Batch.CostObserved = $true }
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
    $work = Require-Opt 'work'
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
    $estTokens=0.0; $estTokenObserved=$false
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
        if ($batch.EstimatedTokenObserved) { $estTokens += $batch.EstimatedTokens; $estTokenObserved=$true }
        if ($batch.CostObserved) { $costUsd += $batch.CostUsd; $costObserved=$true }
    }
    $completedTasks=@($selected | ForEach-Object { $_.Tasks.Values } | Where-Object { $null -ne $_.Verified }).Count
    if ($completedTasks -eq 0) { $completedTasks=$taskTotal-$escalatedTotal-$quarantinedTotal; if ($completedTasks -lt 0) { $completedTasks=0 } }
    $rStat=Get-Stat $rValues; $fStat=Get-Stat $fValues; $ciStat=Get-Stat $ciValues; $leadStat=Get-Stat $leadValues
    $tokensPerTask=if ($tokenObserved -and $completedTasks -gt 0) { [Math]::Round($tokens/$completedTasks,2) } else { $null }
    $estTokensPerTask=if ($estTokenObserved -and $completedTasks -gt 0) { [Math]::Round($estTokens/$completedTasks,2) } else { $null }
    $costPerTask=if ($costObserved -and $completedTasks -gt 0) { [Math]::Round($costUsd/$completedTasks,4) } else { $null }

    $result=[ordered]@{
        status='ok'; batches=$selected.Count; batch_ids=@($selected | ForEach-Object { $_.Id }); selector=$selector
        attempts=[ordered]@{ review_r=$rStat; fix_f=$fStat; ci=$ciStat }; lead_time_queue_to_verified_ms=$leadStat
        escalation=[ordered]@{ tasks=$escalatedTotal; total_tasks=$taskTotal; share=if ($taskTotal -gt 0) { [Math]::Round($escalatedTotal/[double]$taskTotal,4) } else { $null } }
        quarantine=[ordered]@{ tasks=$quarantinedTotal; total_tasks=$taskTotal; share=if ($taskTotal -gt 0) { [Math]::Round($quarantinedTotal/[double]$taskTotal,4) } else { $null } }
        recovery=if ($interrupted -gt 0) { [ordered]@{ interruptions=$interrupted; recovered=$recovered; success_share=[Math]::Round($recovered/[double]$interrupted,4) } } else { $null }
        cost_per_completed_task=[ordered]@{ completed_tasks=$completedTasks; tokens=$tokensPerTask; estimated_tokens=$estTokensPerTask; usd=$costPerTask; available=($null -ne $tokensPerTask -or $null -ne $costPerTask) }
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
    $costText=if ($null -ne $tokensPerTask) { "$(Format-Number $tokensPerTask) tokens/task" } elseif ($null -ne $costPerTask) { '$'+(Format-Number $costPerTask)+'/task' } elseif ($null -ne $estTokensPerTask) { "~$(Format-Number $estTokensPerTask) tokens/task (оценка)" } else { 'недоступно' }
    Write-Output "| Стоимость на завершённую задачу | $completedTasks | $costText | — |"
    if ($eventsStatus -eq 'missing') { Write-Output 'Диагностика: events.jsonl отсутствует; доступны только fallback-поля journal.md.' }
    elseif ($eventsStatus -eq 'empty') { Write-Output 'Диагностика: events.jsonl пуст; доступны только fallback-поля journal.md.' }
    if ($stream.Invalid -gt 0) { Write-Output "Пропущено некорректных строк JSONL: $($stream.Invalid)" }
}

try {
    $parsed = Parse-CliArgs -Argv $args -BoolFlags @('json')
    for ($i = 1; $i -lt $args.Count; $i++) {
        $arg = [string]$args[$i]
        if ($arg -notlike '--*') { Fail 2 "unexpected argument '$arg'" }
        $key = $arg.Substring(2)
        if ($key -eq 'json') { continue }
        if ($i + 1 -ge $args.Count -or [string]$args[$i + 1] -like '--*') { Fail 2 "missing value for --$key" }
        $i++
    }
    $Command = $parsed.Command
    $opts = $parsed.Opts
    switch ($Command) { 'aggregate' { Cmd-Aggregate }; default { Fail 2 "unknown command '$Command'. Valid: aggregate" } }
} catch {
    exit (Resolve-CatchExit $_ 'METRICSERR' 'metrics' 'METRICS_DEBUG')
}
