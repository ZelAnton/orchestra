<#
.SYNOPSIS
    Deterministic offline tests for tools/metrics.ps1 (T-249).
.DESCRIPTION
    Runs the real tool as a child pwsh process against throwaway fixtures. Covers
    averages/nearest-rank p95, journal field fallback, last/since selection,
    malformed and torn JSONL lines, unavailable token cost, empty input and the
    read-only guarantee.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$script:Tool = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\metrics.ps1')).Path
$script:PsExe = ([Diagnostics.Process]::GetCurrentProcess()).MainModule.FileName
$script:Utf8 = New-Object Text.UTF8Encoding($false)
$script:Failures = [Collections.Generic.List[string]]::new()
$script:Dirs = [Collections.Generic.List[string]]::new()

function New-Fixture {
    $dir = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'metrics-t-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($dir); $script:Dirs.Add($dir); return $dir
}
function Write-Utf8 { param([string]$Path, [string]$Text) [IO.File]::WriteAllText($Path, $Text, $script:Utf8) }
function Invoke-Metrics {
    param([string[]]$ToolArgs)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$script:PsExe; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    $psi.StandardOutputEncoding=$script:Utf8; $psi.StandardErrorEncoding=$script:Utf8
    foreach ($arg in (@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$script:Tool)+$ToolArgs)) { $psi.ArgumentList.Add($arg) }
    $process=[Diagnostics.Process]::Start($psi); $outTask=$process.StandardOutput.ReadToEndAsync(); $errTask=$process.StandardError.ReadToEndAsync()
    $process.WaitForExit(); return [pscustomobject]@{ ExitCode=$process.ExitCode; Out=$outTask.Result; Err=$errTask.Result }
}
function Assert-True { param([bool]$Condition,[string]$Message) if (-not $Condition) { $script:Failures.Add("FAIL - $Message") } }
function Assert-Equal { param($Expected,$Actual,[string]$Message) if ($Expected -ne $Actual) { $script:Failures.Add("FAIL - ${Message}: expected [$Expected], got [$Actual]") } }
function Assert-Contains { param([string]$Text,[string]$Part,[string]$Message) if ($Text.IndexOf($Part,[StringComparison]::Ordinal) -lt 0) { $script:Failures.Add("FAIL - ${Message}: [$Part] not in [$Text]") } }

function Event-Line {
    param([string]$Id,[string]$At,[string]$Type,[string]$Batch,[string]$Task='',[hashtable]$Payload=@{})
    $event=[ordered]@{ schema_version=1; event_id=$Id; occurred_at=$At; type=$Type; batch_id=$Batch; actor=[ordered]@{kind='tool';name='fixture'}; payload=$Payload }
    if ($Task) { $event['task_id']=$Task }
    return ($event | ConvertTo-Json -Depth 10 -Compress)
}

# Known distribution: R=[1,2,3,4], lead hours=[1,2,3,4], F=[1,3], CI=[2,4].
$work=New-Fixture; $lines=[Collections.Generic.List[string]]::new()
$lines.Add((Event-Line e01 '2026-07-01T00:00:00Z' 'cohort.opened' B-1))
foreach ($spec in @(@('T-1',1,1),@('T-2',2,2))) {
    $task=$spec[0]; $rounds=[int]$spec[1]; $hours=[int]$spec[2]
    $lines.Add((Event-Line "c-$task" '2026-07-01T00:00:00Z' 'task.captured' B-1 $task))
    for ($round=1; $round -le $rounds; $round++) { $lines.Add((Event-Line "r-$task-$round" "2026-07-01T00:0${round}:00Z" 'task.status_changed' B-1 $task @{from='в работе';to='на ревью'})) }
    $lines.Add((Event-Line "v-$task" ([DateTimeOffset]::Parse('2026-07-01T00:00:00Z').AddHours($hours).ToString('yyyy-MM-ddTHH:mm:ssZ')) 'task.status_changed' B-1 $task @{from='на ревью';to='готова к слиянию'}))
}
$lines.Add((Event-Line e02 '2026-07-01T05:00:00Z' 'run.interrupted' B-1 '' @{stop_reason='crash'}))
$lines.Add((Event-Line e03 '2026-07-01T06:00:00Z' 'cohort.closed' B-1 '' @{f_attempts=1;ci_attempts=2}))
$lines.Add('{broken-but-newline-terminated')
$lines.Add((Event-Line e11 '2026-07-02T00:00:00Z' 'cohort.opened' B-2))
foreach ($spec in @(@('T-3',3,3),@('T-4',4,4))) {
    $task=$spec[0]; $rounds=[int]$spec[1]; $hours=[int]$spec[2]
    $lines.Add((Event-Line "c-$task" '2026-07-02T00:00:00Z' 'task.captured' B-2 $task))
    for ($round=1; $round -le $rounds; $round++) { $lines.Add((Event-Line "r-$task-$round" "2026-07-02T00:0${round}:00Z" 'task.status_changed' B-2 $task @{from='в работе';to='на ревью'})) }
    $lines.Add((Event-Line "v-$task" ([DateTimeOffset]::Parse('2026-07-02T00:00:00Z').AddHours($hours).ToString('yyyy-MM-ddTHH:mm:ssZ')) 'task.status_changed' B-2 $task @{from='на ревью';to='verified'}))
}
$lines.Add((Event-Line c-T-5 '2026-07-02T00:00:00Z' 'task.captured' B-2 T-5))
$lines.Add((Event-Line s-T-5 '2026-07-02T02:00:00Z' 'task.status_changed' B-2 T-5 @{from='в работе';to='эскалирована'}))
$lines.Add((Event-Line c-T-6 '2026-07-02T00:00:00Z' 'task.captured' B-2 T-6))
$lines.Add((Event-Line s-T-6 '2026-07-02T02:00:00Z' 'task.status_changed' B-2 T-6 @{from='готова к слиянию';to='конфликт'}))
$lines.Add((Event-Line e13 '2026-07-02T06:00:00Z' 'cohort.closed' B-2))
$eventsText=($lines -join "`n")+"`n"+'{"schema_version":1,"event_id":"torn"'
$eventBytes=$script:Utf8.GetBytes($eventsText)
$bytesWithInvalidUtf8=New-Object 'byte[]' ($eventBytes.Length+2)
$bytesWithInvalidUtf8[0]=[byte]0xff; $bytesWithInvalidUtf8[1]=[byte]10
[Array]::Copy($eventBytes,0,$bytesWithInvalidUtf8,2,$eventBytes.Length)
[IO.File]::WriteAllBytes((Join-Path $work 'events.jsonl'),$bytesWithInvalidUtf8)
$journal=@'
## Batch B-1 — 2026-07-01T00:00:00Z → 2026-07-01T06:00:00Z
- База: abc; задач в когорте: 2 (волн приёма: 1)
- [T-1] волна=1 · циклов ревью=99 · merged=abc
- [T-2] волна=1 · циклов ревью=99 · merged=def
- Интеграционных F-циклов: 99 (F- всего: 99)
- Push: да · CI: 99 попыток
- Итог: 2 слито, 0 карантин (re-queued), 0 эскалировано

## Batch B-2 — 2026-07-02T00:00:00Z → 2026-07-02T06:00:00Z
- База: def; задач в когорте: 4 (волн приёма: 1)
- [T-3] волна=1 · циклов ревью=99 · merged=ghi
- [T-4] волна=1 · циклов ревью=99 · merged=jkl
- [T-5] волна=1 · эскалирована
- [T-6] волна=1 · quarantined=conflict
- Интеграционных F-циклов: 3 (F- всего: 4)
- Push: да · CI: 4 попыток
- Итог: 2 слито, 1 карантин (re-queued), 1 эскалировано
'@
Write-Utf8 (Join-Path $work 'journal.md') $journal
$beforeEvents=[IO.File]::ReadAllText((Join-Path $work 'events.jsonl')); $beforeJournal=[IO.File]::ReadAllText((Join-Path $work 'journal.md'))

$run=Invoke-Metrics @('aggregate','--work',$work,'--last','2','--json')
Assert-Equal 0 $run.ExitCode "aggregate exits zero (stderr=$($run.Err.Trim()))"; if ($run.ExitCode -eq 0) {
    $data=$run.Out | ConvertFrom-Json
    Assert-Equal 2 $data.batches 'two batches selected'
    Assert-Equal 2.5 $data.attempts.review_r.average 'R average uses events, not conflicting journal fallback'
    Assert-Equal 4 $data.attempts.review_r.p95 'R nearest-rank p95'
    Assert-Equal 2 $data.attempts.fix_f.average 'F average uses event value plus journal fallback'
    Assert-Equal 3 $data.attempts.fix_f.p95 'F p95'
    Assert-Equal 3 $data.attempts.ci.average 'CI average uses event value plus journal fallback'
    Assert-Equal 4 $data.attempts.ci.p95 'CI p95'
    Assert-Equal 9000000 $data.lead_time_queue_to_verified_ms.average 'lead-time average is 2.5 hours'
    Assert-Equal 14400000 $data.lead_time_queue_to_verified_ms.p95 'lead-time p95 is 4 hours'
    Assert-Equal 0.1667 $data.escalation.share 'escalation share'; Assert-Equal 0.1667 $data.quarantine.share 'quarantine share'
    Assert-Equal 1 $data.recovery.interruptions 'interruption observed'; Assert-Equal 1 $data.recovery.recovered 'terminal close proves recovery'
    Assert-True (-not $data.cost_per_completed_task.available) 'cost explicitly unavailable without token-usage events'
    Assert-Equal 3 $data.sources.skipped_jsonl_lines 'invalid UTF-8, broken JSON and torn tail are skipped independently'
}
Assert-Equal $beforeEvents ([IO.File]::ReadAllText((Join-Path $work 'events.jsonl'))) 'events file unchanged (read-only)'
Assert-Equal $beforeJournal ([IO.File]::ReadAllText((Join-Path $work 'journal.md'))) 'journal file unchanged (read-only)'
Assert-True (-not (Test-Path (Join-Path $work 'orchestrator.lock'))) 'tool never creates/acquires orchestrator.lock'

$tableRun=Invoke-Metrics @('aggregate','--work',$work,'--last','2')
Assert-Equal 0 $tableRun.ExitCode 'human-readable table exits zero'
Assert-Contains $tableRun.Out '| R-попытки (review) |' 'human-readable summary contains the R row'
Assert-Contains $tableRun.Out '| Стоимость на завершённую задачу |' 'human-readable summary contains the cost row'

$last=Invoke-Metrics @('aggregate','--work',$work,'--last','1','--json'); Assert-Equal 0 $last.ExitCode "--last exits zero (stderr=$($last.Err.Trim()))"
if ($last.ExitCode -eq 0) { Assert-Equal 'B-2' (($last.Out | ConvertFrom-Json).batch_ids[0]) '--last selects newest batch' }
$since=Invoke-Metrics @('aggregate','--work',$work,'--since','2026-07-02','--json'); Assert-Equal 0 $since.ExitCode "--since exits zero (stderr=$($since.Err.Trim()))"
if ($since.ExitCode -eq 0) { Assert-Equal 1 (($since.Out | ConvertFrom-Json).batches) '--since filters older batch' }

# Explicit usage makes cost available; the prose journal is never treated as exact usage.
$costWork=New-Fixture
$costLines=@(
    (Event-Line u01 '2026-07-03T00:00:00Z' 'cohort.opened' B-3),
    (Event-Line u02 '2026-07-03T00:00:00Z' 'task.captured' B-3 T-9),
    (Event-Line u03 '2026-07-03T01:00:00Z' 'task.status_changed' B-3 T-9 @{from='на ревью';to='verified'}),
    (Event-Line u04 '2026-07-03T01:01:00Z' 'usage.recorded' B-3 T-9 @{token_usage=@{input_tokens=700;output_tokens=500}}),
    (Event-Line u05 '2026-07-03T02:00:00Z' 'cohort.closed' B-3)
)
Write-Utf8 (Join-Path $costWork 'events.jsonl') (($costLines -join "`n")+"`n")
$costRun=Invoke-Metrics @('aggregate','--work',$costWork,'--last','1','--json')
Assert-Equal 0 $costRun.ExitCode 'token-usage fixture exits zero'
if ($costRun.ExitCode -eq 0) { $costData=$costRun.Out|ConvertFrom-Json; Assert-True $costData.cost_per_completed_task.available 'explicit token usage makes cost available'; Assert-Equal 1200 $costData.cost_per_completed_task.tokens 'tokens per completed task' }

# T-248: an `estimated` usage figure is NEVER summed into the actual token total; it is tracked
# separately (plans/OBSERVABILITY_PLATFORM_PLAN.md §8). One actual (1200) + one estimated (9999)
# usage.recorded on one completed task => tokens=1200 (actual only), estimated_tokens=9999.
$estWork=New-Fixture
$estLines=@(
    (Event-Line s01 '2026-07-04T00:00:00Z' 'cohort.opened' B-4),
    (Event-Line s02 '2026-07-04T00:00:00Z' 'task.captured' B-4 T-9),
    (Event-Line s03 '2026-07-04T01:00:00Z' 'task.status_changed' B-4 T-9 @{from='на ревью';to='verified'}),
    (Event-Line s04 '2026-07-04T01:01:00Z' 'usage.recorded' B-4 T-9 @{source='codex';total_tokens=1200;estimated=$false}),
    (Event-Line s05 '2026-07-04T01:02:00Z' 'usage.recorded' B-4 T-9 @{source='codex';total_tokens=9999;estimated=$true}),
    (Event-Line s06 '2026-07-04T02:00:00Z' 'cohort.closed' B-4)
)
Write-Utf8 (Join-Path $estWork 'events.jsonl') (($estLines -join "`n")+"`n")
$estRun=Invoke-Metrics @('aggregate','--work',$estWork,'--last','1','--json')
Assert-Equal 0 $estRun.ExitCode 'estimated-usage fixture exits zero'
if ($estRun.ExitCode -eq 0) {
    $estData=$estRun.Out|ConvertFrom-Json
    Assert-Equal 1200 $estData.cost_per_completed_task.tokens 'actual tokens exclude the estimated figure (never mixed)'
    Assert-Equal 9999 $estData.cost_per_completed_task.estimated_tokens 'estimated tokens are reported in their own field'
}

$empty=New-Fixture; $emptyRun=Invoke-Metrics @('aggregate','--work',$empty,'--last','5')
Assert-Equal 0 $emptyRun.ExitCode 'empty input is success'; Assert-Contains $emptyRun.Out 'Нет данных' 'empty input has explicit no-data output'
Assert-Contains $emptyRun.Out 'events.jsonl отсутствует' 'missing event stream has an explicit diagnostic'

foreach ($dir in $script:Dirs) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
if ($script:Failures.Count -gt 0) { $script:Failures | ForEach-Object { Write-Host $_ -ForegroundColor Red }; exit 1 }
Write-Host 'PASS - metrics aggregation, fallback, filtering, lenient JSONL, empty input and read-only contract'
exit 0
