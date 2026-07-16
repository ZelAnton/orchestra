# Tests for tools/queue-tx.ps1 - the transactional queue interface (task T-082).
#
# These are scriptable, LLM-free tests. Each scenario builds a throwaway .work
# sandbox under $env:TEMP, drives the real tool as a child process, and asserts
# on its output/exit code and the resulting Tasks_Queue.md. Nothing here touches
# this repository's own .work/. Covered (per T-082's criteria):
#   - allocate-id / propose / generation counter, header format preserved
#   - idempotent dedup (duplicate title rejected)
#   - predecessor chain, fan-in, fan-out, parallel-independent readiness
#   - dependency validation: missing / self-reference / cycle / infeasible
#   - capture (preserves format + попытка), quarantine return (preserves the
#     dependency edge + increments попытка), escalation on exhausted attempts
#   - optimistic generation compare-and-swap (stale writer rejected)
#   - crash/retry mid-transaction (fault injection leaves queue+gen intact)
#   - inbox add/drain, including immutable quarantine of rejected records
#   - several concurrent writers with no lost update / no duplicate id
#
# The tool is invoked with pwsh (PowerShell 7) when available, else the current
# powershell.exe; the tool file itself is UTF-8 with BOM so its Cyrillic status
# literals survive either host.

. (Join-Path $PSScriptRoot 'common.ps1')

$script:ToolPath = Join-Path $script:RepoRoot 'tools\queue-tx.ps1'
$script:PwshHost = 'powershell'
$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwshCmd) { $script:PwshHost = $pwshCmd.Source }

function New-Work {
    $root = Join-Path $env:TEMP ("orc-queuetx-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    return $root
}

# Runs the tool once, returns @{ ExitCode; Output }. stderr is merged into
# Output; $ErrorActionPreference is relaxed for the native call only (a non-zero
# tool exit writes to stderr, which would otherwise terminate under 'Stop').
function Run-Tool {
    param([string[]] $ToolArgs, [hashtable] $EnvVars = @{})
    $applied = @{}
    foreach ($k in $EnvVars.Keys) {
        $applied[$k] = [Environment]::GetEnvironmentVariable($k)
        Set-Item -Path "env:$k" -Value $EnvVars[$k]
    }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $script:PwshHost -NoProfile -ExecutionPolicy Bypass -File $script:ToolPath @ToolArgs 2>&1 | Out-String
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEap
        foreach ($k in $EnvVars.Keys) {
            if ($null -eq $applied[$k]) { Remove-Item -Path "env:$k" -ErrorAction SilentlyContinue }
            else { Set-Item -Path "env:$k" -Value $applied[$k] }
        }
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $out }
}

function Read-Queue {
    param([string] $Work)
    $p = Join-Path $Work 'Tasks_Queue.md'
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    return [System.IO.File]::ReadAllText($p)
}
function Propose {
    param([string] $Work, [string] $Title, [string] $Body = 'body', [string] $Preds = $null)
    $a = @('propose', '--work', $Work, '--title', $Title, '--body', $Body)
    if ($Preds) { $a += @('--predecessors', $Preds) }
    $r = Run-Tool $a
    Assert-Equal 0 $r.ExitCode "propose '$Title' should succeed (got: $($r.Output))"
    return $r
}
function Get-QueueIds {
    param([string] $Work)
    $ids = @()
    foreach ($m in [regex]::Matches((Read-Queue $Work), '###\s+\[T-0*(\d+)\]')) { $ids += [int]$m.Groups[1].Value }
    return ,$ids
}
function Assert-Match {
    param([string] $Text, [string] $Pattern, [string] $Message = '')
    if ($Text -notmatch $Pattern) { throw "Assertion failed: ${Message}: [$Pattern] not found in [$Text]" }
}

Invoke-Test -Name 'queue-tx.ps1' -Body {

    # --- Scenario 1: propose basics, generation, header format preserved ----
    $W = New-Work
    try {
        $r = Run-Tool @('allocate-id', '--work', $W)
        Assert-Equal 0 $r.ExitCode '[alloc] empty-queue allocate-id exit'
        Assert-Match $r.Output 'T-001' '[alloc] first id is T-001'

        Propose $W 'Add feature A' 'Do the A thing.' | Out-Null
        $r = Propose $W 'Add feature B' 'Do B.' 'T-001'
        Assert-Match $r.Output 'id=T-002 generation=2' '[propose] second task id/generation'

        $r = Run-Tool @('generation', '--work', $W)
        Assert-Match $r.Output '2' '[gen] generation is 2'

        $q = Read-Queue $W
        Assert-Match $q '### \[T-001\] Add feature A — статус: не начата' '[format] header untouched'
        Assert-Match $q 'Предпосылки: T-001' '[format] machine-readable predecessor edge in body'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 2: idempotent dedup rejects a duplicate title -------------
    $W = New-Work
    try {
        Propose $W 'Cache catalog responses' 'x' | Out-Null
        $r = Run-Tool @('propose', '--work', $W, '--title', 'cache   catalog   responses', '--body', 'y')
        Assert-Equal 4 $r.ExitCode '[dedup] duplicate (normalized) title rejected with exit 4'
        Assert-Equal 1 (Get-QueueIds $W).Count '[dedup] only one task remains in the queue'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 3: predecessor chain readiness (A <- B <- C) --------------
    $W = New-Work
    try {
        Propose $W 'Chain A' 'a' | Out-Null
        Propose $W 'Chain B' 'b' 'T-001' | Out-Null
        Propose $W 'Chain C' 'c' 'T-002' | Out-Null
        $r = Run-Tool @('ready', '--work', $W)
        Assert-Match $r.Output 'ready: T-001' '[chain] only head of chain is ready'
        Assert-Match $r.Output 'not-ready: T-002.*waiting on T-001' '[chain] B waits on A'
        Assert-Match $r.Output 'not-ready: T-003.*waiting on T-002' '[chain] C waits on B'

        # archive A (into Tasks_Done) -> B becomes ready
        Set-Content -LiteralPath (Join-Path $W 'Tasks_Done.md') -Value '### [T-001] Chain A — статус: не начата' -Encoding utf8
        Run-Tool @('archive', '--work', $W, '--id', 'T-001') | Out-Null
        $r = Run-Tool @('ready', '--work', $W)
        Assert-Match $r.Output 'ready: T-002' '[chain] B ready once A archived'
        Assert-Match $r.Output 'not-ready: T-003' '[chain] C still waits on B'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 3b: archive body mentions do not satisfy prerequisites ----
    $W = New-Work
    try {
        $q = @(
            '# Очередь задач', '',
            '### [T-101] Pending prerequisite — статус: не начата', 'body', '',
            '### [T-102] Dependent task — статус: не начата', 'body', 'Предпосылки: T-101'
        ) -join "`n"
        $done = @(
            '# Архив выполненных задач', '',
            '### [T-100] Completed task — статус: завершена',
            'Prerequisites: T-101'
        ) -join "`n"
        [System.IO.File]::WriteAllText((Join-Path $W 'Tasks_Queue.md'), $q, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText((Join-Path $W 'Tasks_Done.md'), $done, (New-Object System.Text.UTF8Encoding($false)))

        $r = Run-Tool @('ready', '--work', $W)
        Assert-Match $r.Output 'ready: T-101' '[archive-header] pending prerequisite itself remains ready'
        Assert-Match $r.Output 'not-ready: T-102.*waiting on T-101' '[archive-header] body mention does not complete T-101'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 4: fan-in (one task waits on several predecessors) --------
    $W = New-Work
    try {
        Propose $W 'FanIn A' 'a' | Out-Null
        Propose $W 'FanIn B' 'b' | Out-Null
        Propose $W 'FanIn C' 'c' 'T-001, T-002' | Out-Null
        $r = Run-Tool @('ready', '--work', $W)
        Assert-Match $r.Output 'ready: T-001 T-002' '[fan-in] both independents ready'
        Assert-Match $r.Output 'not-ready: T-003.*waiting on T-001.*waiting on T-002' '[fan-in] C waits on both'

        # archive only A -> C still not ready (still waits on B)
        Set-Content -LiteralPath (Join-Path $W 'Tasks_Done.md') -Value '### [T-001] FanIn A — статус: завершена' -Encoding utf8
        Run-Tool @('archive', '--work', $W, '--id', 'T-001') | Out-Null
        $r = Run-Tool @('ready', '--work', $W, '--id', 'T-003')
        Assert-Equal 6 $r.ExitCode '[fan-in] C not ready with one predecessor still open'
        Assert-Match $r.Output 'waiting on T-002' '[fan-in] blocking predecessor named'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 5: fan-out (several tasks depend on one) ------------------
    $W = New-Work
    try {
        Propose $W 'FanOut A' 'a' | Out-Null
        Propose $W 'FanOut B' 'b' 'T-001' | Out-Null
        Propose $W 'FanOut C' 'c' 'T-001' | Out-Null
        $r = Run-Tool @('ready', '--work', $W)
        Assert-Match $r.Output 'ready: T-001' '[fan-out] only shared predecessor ready'
        Assert-Match $r.Output 'not-ready: T-002.*T-001' '[fan-out] B waits on A'
        Assert-Match $r.Output 'not-ready: T-003.*T-001' '[fan-out] C waits on A'

        Set-Content -LiteralPath (Join-Path $W 'Tasks_Done.md') -Value '### [T-001] FanOut A — статус: завершена' -Encoding utf8
        Run-Tool @('archive', '--work', $W, '--id', 'T-001') | Out-Null
        $r = Run-Tool @('ready', '--work', $W)
        Assert-Match $r.Output 'ready: T-002 T-003' '[fan-out] both dependents ready once A archived'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 6: parallel independent tasks are not blocked on each other
    $W = New-Work
    try {
        Propose $W 'Independent X' 'x' | Out-Null
        Propose $W 'Independent Y' 'y' | Out-Null
        $r = Run-Tool @('ready', '--work', $W)
        Assert-Match $r.Output 'ready: T-001 T-002' '[parallel] both independent tasks ready together'
        Assert-True (-not ($r.Output -match 'not-ready')) '[parallel] no not-ready lines'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 7: dependency validation (missing / self-ref / cycle / infeasible)
    $W = New-Work
    try {
        # cycle T-001 -> T-003 -> T-002 -> T-001, plus a self-ref, missing, infeasible
        $q = @(
            '# Очередь задач', '',
            '### [T-001] Alpha — статус: не начата', 'x', 'Предпосылки: T-003', '',
            '### [T-002] Beta — статус: не начата', 'x', 'Предпосылки: T-001', '',
            '### [T-003] Gamma — статус: не начата', 'x', 'Предпосылки: T-002', '',
            '### [T-004] Delta — статус: не начата', 'x', 'Предпосылки: T-004', '',
            '### [T-005] Epsilon — статус: не начата', 'x', 'Предпосылки: T-099', '',
            '### [T-006] Zeta — статус: эскалирована · причина=dead', 'x', '',
            '### [T-007] Eta — статус: не начата', 'x', 'Предпосылки: T-006'
        ) -join "`n"
        [System.IO.File]::WriteAllText((Join-Path $W 'Tasks_Queue.md'), $q, (New-Object System.Text.UTF8Encoding($false)))
        $r = Run-Tool @('validate-deps', '--work', $W)
        Assert-Equal 5 $r.ExitCode '[validate] invalid graph exits 5'
        Assert-Match $r.Output 'cycle in dependency graph' '[validate] cycle detected'
        Assert-Match $r.Output 'T-004: self-reference' '[validate] self-reference detected'
        Assert-Match $r.Output 'T-005: missing predecessor T-099' '[validate] missing predecessor detected'
        Assert-Match $r.Output 'T-007: infeasible predecessor T-006' '[validate] infeasible (escalated) predecessor detected'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 7b: propose-time dependency rejection (cycle + missing) ---
    $W = New-Work
    try {
        Propose $W 'PT A' 'a' | Out-Null
        Propose $W 'PT B' 'b' 'T-001' | Out-Null
        # explicit id T-001 depending on T-002 would close a cycle T-001<->T-002
        $r = Run-Tool @('propose', '--work', $W, '--title', 'PT Cyclic', '--body', 'c', '--id', 'T-001', '--predecessors', 'T-002')
        Assert-Equal 5 $r.ExitCode '[propose-dep] duplicate explicit id rejected'
        $r = Run-Tool @('propose', '--work', $W, '--title', 'PT Missing', '--body', 'c', '--predecessors', 'T-404')
        Assert-Equal 5 $r.ExitCode '[propose-dep] missing predecessor rejected at propose time'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 8: capture + quarantine return preserving the graph -------
    $W = New-Work
    try {
        Propose $W 'Cap A' 'a' | Out-Null
        Propose $W 'Cap B' 'b' 'T-001' | Out-Null
        $r = Run-Tool @('capture', '--work', $W, '--id', 'T-002', '--batch', 'B-20260101T000000Z')
        Assert-Equal 0 $r.ExitCode '[capture] exit'
        $q = Read-Queue $W
        Assert-Match $q '### \[T-002\] Cap B — статус: в работе · батч=B-20260101T000000Z · worktree=.work/worktrees/T-002 · ветка=task/T-002' '[capture] header format'

        # quarantine return: attempt increments, predecessor edge preserved
        $r = Run-Tool @('return', '--work', $W, '--id', 'T-002', '--reason', 'merge conflict')
        Assert-Match $r.Output 'requeued T-002' '[return] requeued'
        $q = Read-Queue $W
        Assert-Match $q 'статус: не начата · попытка=2 · карантин=merge conflict' '[return] quarantine suffix set, base status stays не начата'
        Assert-Match $q 'Предпосылки: T-001' '[return] dependency edge survives quarantine'

        # re-capture carries попытка forward
        $r = Run-Tool @('capture', '--work', $W, '--id', 'T-002', '--batch', 'B-2')
        Assert-Match (Read-Queue $W) 'в работе.*попытка=2' '[recapture] попытка carried into capture'

        # exhaust attempts -> escalate
        Run-Tool @('return', '--work', $W, '--id', 'T-002', '--reason', 'again', '--max-attempts', '2') | Out-Null
        $q = Read-Queue $W
        Assert-Match $q 'статус: эскалирована · причина=карантин повторился 2 раз' '[return] escalates when attempts exhausted'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 8c: escalated task with "не начата" inside reason does NOT get captured ---
    $W = New-Work
    try {
        Propose $W 'Escalate Trap A' 'a' | Out-Null
        # Manually set task to escalated with a reason that contains "не начата".
        $q = @(
            '# Очередь задач', '',
            '### [T-001] Escalate Trap A — статус: эскалирована · причина=карантин повторился 3 раз: задача не начата корректно'
        ) -join "`n"
        [System.IO.File]::WriteAllText((Join-Path $W 'Tasks_Queue.md'), $q, (New-Object System.Text.UTF8Encoding($false)))

        $r = Run-Tool @('capture', '--work', $W, '--id', 'T-001', '--batch', 'B-20260101T000000Z')
        Assert-Equal 8 $r.ExitCode '[escalated-trap] capture of escalated task fails with exit 8'
        Assert-Match $r.Output 'cannot capture T-001.*status is' '[escalated-trap] error message confirms status classification'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 9: optimistic generation compare-and-swap -----------------
    $W = New-Work
    try {
        Propose $W 'Gen A' 'a' | Out-Null   # generation -> 1
        $r = Run-Tool @('propose', '--work', $W, '--title', 'Gen Stale', '--body', 'b', '--expected-generation', '0')
        Assert-Equal 3 $r.ExitCode '[cas] stale expected-generation rejected with exit 3'
        $r = Run-Tool @('propose', '--work', $W, '--title', 'Gen Fresh', '--body', 'b', '--expected-generation', '1')
        Assert-Equal 0 $r.ExitCode '[cas] correct expected-generation accepted'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 10: crash/retry mid-transaction ---------------------------
    $W = New-Work
    try {
        Propose $W 'Crash A' 'a' | Out-Null
        $genBefore = (Run-Tool @('generation', '--work', $W)).Output.Trim()
        $qBefore = Read-Queue $W
        $r = Run-Tool @('propose', '--work', $W, '--title', 'Crash B', '--body', 'b') -EnvVars @{ QUEUE_TX_FAULT = 'before-rename' }
        Assert-True ($r.ExitCode -ne 0) '[crash] injected fault makes the transaction fail'
        Assert-Equal $genBefore ((Run-Tool @('generation', '--work', $W)).Output.Trim()) '[crash] generation unchanged after fault'
        Assert-Equal $qBefore (Read-Queue $W) '[crash] queue file unchanged after fault'
        # retry (no fault) succeeds and does not double-add
        $r = Run-Tool @('propose', '--work', $W, '--title', 'Crash B', '--body', 'b')
        Assert-Equal 0 $r.ExitCode '[crash] retry succeeds once fault cleared'
        Assert-Equal 2 (Get-QueueIds $W).Count '[crash] exactly two tasks (no double-add)'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 11: inbox add + drain -------------------------------------
    $W = New-Work
    try {
        Run-Tool @('inbox-add', '--work', $W, '--title', 'Inbox One', '--body', 'first') | Out-Null
        Run-Tool @('inbox-add', '--work', $W, '--title', 'Inbox Two', '--body', 'second', '--predecessors', 'T-001') | Out-Null
        Assert-NoFileExists (Join-Path $W 'Tasks_Queue.md') '[inbox] queue untouched before drain'
        $r = Run-Tool @('inbox-drain', '--work', $W)
        Assert-Match $r.Output 'added: T-001 T-002' '[inbox] both proposals landed on drain'
        Assert-Equal 2 (Get-QueueIds $W).Count '[inbox] queue has both tasks'
        Assert-Match (Read-Queue $W) 'Предпосылки: T-001' '[inbox] predecessor edge carried through inbox'
        $remaining = @(Get-ChildItem -LiteralPath (Join-Path $W 'queue_inbox') -Filter '*.json' -ErrorAction SilentlyContinue)
        Assert-Equal 0 $remaining.Count '[inbox] drained entries removed'

        # a re-added duplicate is skipped on drain, not double-inserted
        Run-Tool @('inbox-add', '--work', $W, '--title', 'Inbox One', '--body', 'dup') | Out-Null
        $r = Run-Tool @('inbox-drain', '--work', $W)
        Assert-Match $r.Output 'skipped-dup' '[inbox] duplicate proposal skipped on drain'
        Assert-Equal 2 (Get-QueueIds $W).Count '[inbox] no duplicate inserted'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 11a: dependency rejection is quarantined and non-blocking -
    $W = New-Work
    try {
        Run-Tool @('inbox-add', '--work', $W, '--title', 'Rejected Dependency', '--body', 'bad', '--predecessors', 'T-999') | Out-Null
        $r = Run-Tool @('inbox-drain', '--work', $W)
        Assert-Equal 0 $r.ExitCode '[inbox-rejected-dep] rejection is a successfully processed record'
        Assert-Match $r.Output 'rejected: .*DEP:missing predecessor T-999' '[inbox-rejected-dep] exact dependency error reported'

        $inbox = Join-Path $W 'queue_inbox'
        $rejectedDir = Join-Path $inbox 'rejected'
        Assert-True (Test-Path -LiteralPath $rejectedDir -PathType Container) '[inbox-rejected-dep] rejected path is a directory'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $inbox -Filter '*.json' -File).Count '[inbox-rejected-dep] rejected record removed from hot inbox'
        $rejectedRecords = @(Get-ChildItem -LiteralPath $rejectedDir -Filter '*.json' -File)
        $metadata = @(Get-ChildItem -LiteralPath $rejectedDir -Filter '*.metadata.txt' -File)
        Assert-Equal 1 $rejectedRecords.Count '[inbox-rejected-dep] rejected JSON retained in audit trail'
        Assert-Equal 1 $metadata.Count '[inbox-rejected-dep] companion metadata retained'
        Assert-Match $rejectedRecords[0].Name '^\d{8}T\d{6}-.+\.json$' '[inbox-rejected-dep] sortable timestamp prefixes rejected filename'
        $metadataText = [System.IO.File]::ReadAllText($metadata[0].FullName)
        Assert-Match $metadataText 'Rejection reason: DEP:missing predecessor T-999' '[inbox-rejected-dep] exact rejection reason preserved'
        Assert-Match $metadataText 'Timestamp of rejection: \d{4}-\d{2}-\d{2}T' '[inbox-rejected-dep] rejection timestamp preserved'

        $r = Run-Tool @('inbox-drain', '--work', $W)
        Assert-Equal 0 $r.ExitCode '[inbox-rejected-dep] repeated drain stays successful'
        Assert-Match $r.Output 'inbox empty' '[inbox-rejected-dep] repeated drain does not re-process quarantine'
        Assert-Equal 1 @(Get-ChildItem -LiteralPath $rejectedDir -Filter '*.json' -File).Count '[inbox-rejected-dep] audit trail is append-only across repeated drain'

        Run-Tool @('inbox-add', '--work', $W, '--title', 'Valid After Dependency Rejection', '--body', 'good') | Out-Null
        $r = Run-Tool @('inbox-drain', '--work', $W)
        Assert-Equal 0 $r.ExitCode '[inbox-rejected-dep] later valid drain succeeds'
        Assert-Match $r.Output 'added: T-001' '[inbox-rejected-dep] rejection does not consume an id'
        Assert-Match (Read-Queue $W) 'Valid After Dependency Rejection' '[inbox-rejected-dep] later valid record reaches queue'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 11b: unreadable JSON is quarantined and non-blocking -------
    $W = New-Work
    try {
        $inbox = Join-Path $W 'queue_inbox'
        New-Item -ItemType Directory -Force -Path $inbox | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $inbox 'broken.json'), '{"title":', (New-Object System.Text.UTF8Encoding($false)))

        $r = Run-Tool @('inbox-drain', '--work', $W)
        Assert-Equal 0 $r.ExitCode '[inbox-rejected-json] unreadable JSON is a successfully processed record'
        Assert-Match $r.Output 'rejected: broken\.json' '[inbox-rejected-json] unreadable JSON reported'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $inbox -Filter '*.json' -File).Count '[inbox-rejected-json] unreadable JSON removed from hot inbox'
        $rejectedDir = Join-Path $inbox 'rejected'
        $rejectedRecords = @(Get-ChildItem -LiteralPath $rejectedDir -Filter '*.json' -File)
        $metadata = @(Get-ChildItem -LiteralPath $rejectedDir -Filter '*.metadata.txt' -File)
        Assert-Equal 1 $rejectedRecords.Count '[inbox-rejected-json] unreadable JSON retained in audit trail'
        Assert-Equal 1 $metadata.Count '[inbox-rejected-json] parse diagnostic metadata retained'
        $metadataText = [System.IO.File]::ReadAllText($metadata[0].FullName)
        Assert-Match $metadataText 'Rejection reason: .+' '[inbox-rejected-json] parser error message preserved'
        Assert-Match $metadataText 'Timestamp of rejection: \d{4}-\d{2}-\d{2}T' '[inbox-rejected-json] rejection timestamp preserved'

        $r = Run-Tool @('inbox-drain', '--work', $W)
        Assert-Equal 0 $r.ExitCode '[inbox-rejected-json] repeated drain stays successful'
        Assert-Match $r.Output 'inbox empty' '[inbox-rejected-json] repeated drain does not re-process quarantine'

        Run-Tool @('inbox-add', '--work', $W, '--title', 'Valid After Broken JSON', '--body', 'good') | Out-Null
        $r = Run-Tool @('inbox-drain', '--work', $W)
        Assert-Equal 0 $r.ExitCode '[inbox-rejected-json] later valid drain succeeds'
        Assert-Match (Read-Queue $W) 'Valid After Broken JSON' '[inbox-rejected-json] later valid record reaches queue'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 11c: valid and rejected records share one successful drain -
    $W = New-Work
    try {
        Run-Tool @('inbox-add', '--work', $W, '--title', 'Mixed Rejected', '--body', 'bad', '--predecessors', 'T-999') | Out-Null
        Run-Tool @('inbox-add', '--work', $W, '--title', 'Mixed Valid', '--body', 'good') | Out-Null
        $r = Run-Tool @('inbox-drain', '--work', $W)
        Assert-Equal 0 $r.ExitCode '[inbox-mixed] accepted and rejected records are fully processed'
        Assert-Match $r.Output 'added: T-001' '[inbox-mixed] valid record is added normally'
        Assert-Match $r.Output 'rejected: .*DEP:missing predecessor T-999' '[inbox-mixed] invalid record is quarantined'
        Assert-Equal 1 (Get-QueueIds $W).Count '[inbox-mixed] only valid record reaches queue'
        Assert-Match (Read-Queue $W) 'Mixed Valid' '[inbox-mixed] valid title preserved'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath (Join-Path $W 'queue_inbox') -Filter '*.json' -File).Count '[inbox-mixed] hot inbox fully drained'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 12: concurrent writers, no lost update / no duplicate id --
    $W = New-Work
    try {
        $N = 8
        $procs = @()
        for ($i = 1; $i -le $N; $i++) {
            $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:ToolPath,
                'propose', '--work', $W, '--title', "Concurrent-$i", '--body', "body-$i")
            $procs += Start-Process -FilePath $script:PwshHost -ArgumentList $a -NoNewWindow -PassThru
        }
        $procs | Wait-Process -Timeout 90
        foreach ($p in $procs) { Assert-Equal 0 $p.ExitCode "[concurrent] writer pid $($p.Id) exit" }

        $ids = Get-QueueIds $W
        Assert-Equal $N $ids.Count "[concurrent] all $N proposals present (no lost update)"
        $distinct = @($ids | Sort-Object -Unique)
        Assert-Equal $N $distinct.Count "[concurrent] all ids unique (no reuse)"
        $gen = (Run-Tool @('generation', '--work', $W)).Output.Trim()
        Assert-Equal "$N" $gen "[concurrent] generation advanced exactly once per writer"
        # the dependency graph of the resulting queue is still well-formed
        $r = Run-Tool @('validate-deps', '--work', $W)
        Assert-Equal 0 $r.ExitCode '[concurrent] resulting queue graph valid'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }
}
