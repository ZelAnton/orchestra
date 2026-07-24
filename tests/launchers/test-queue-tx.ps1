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
#   - delivery lane (§11.1): next_major parked out of the default `ready`, shown
#     under `--next-major`, `ready --id` capture gate refusal, and the forbidden
#     current -> next_major dependency edge (validate-deps + propose) (task T-246)
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

    # --- Scenario 3c: the ONE normative archive-header contract (docs/queue_contract.md §12).
    # All previously divergent heading shapes — H2 `##`, H3 `###`, legacy H1 ru/en — satisfy a
    # prerequisite identically, while a body mention and a digitless `### [T-]` header do NOT.
    # This is the SAME archive fixture the engine (`state::util`) and tui (`done_task_ids`) unit
    # tests assert, so all three resolvers agree on one archive record (T-293).
    $W = New-Work
    try {
        $q = @(
            '# Очередь задач', '',
            '### [T-200] All-shapes dependent — статус: не начата',
            'body',
            'Предпосылки: T-090, T-091, T-092, T-093', '',
            '### [T-201] Body-mention dependent — статус: не начата',
            'body',
            'Предпосылки: T-999'
        ) -join "`n"
        $done = @(
            '# Выполненные задачи', '',
            '## [T-090] H2 archive entry — статус: завершена',
            '### [T-091] H3 archive entry — статус: завершена',
            '# Активная задача T-092',
            'Состояние: завершена',
            '# Active task T-093', '',
            'Body mention of T-999 must not count',
            '### [T-] digitless header must not count'
        ) -join "`n"
        [System.IO.File]::WriteAllText((Join-Path $W 'Tasks_Queue.md'), $q, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText((Join-Path $W 'Tasks_Done.md'), $done, (New-Object System.Text.UTF8Encoding($false)))

        $r = Run-Tool @('ready', '--work', $W, '--id', 'T-200')
        Assert-Equal 0 $r.ExitCode '[archive-header-contract] H2/H3/legacy-H1 headings all satisfy the prerequisite'
        Assert-Match $r.Output 'ready\s+T-200' '[archive-header-contract] all four normative shapes recognized'

        $r = Run-Tool @('ready', '--work', $W, '--id', 'T-201')
        Assert-Equal 6 $r.ExitCode '[archive-header-contract] a body mention / digitless header does not satisfy'
        Assert-Match $r.Output 'missing predecessor T-999' '[archive-header-contract] body mention T-999 is not an archive record'
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
        $exitFiles = @()
        $writerWrapper = Join-Path $W 'concurrent-writer.ps1'
        $writerWrapperText = @'
param([string]$ToolPath, [string]$Work, [string]$Title, [string]$Body, [string]$ExitFile)
$hostPath = (Get-Process -Id $PID).Path
& $hostPath -NoProfile -ExecutionPolicy Bypass -File $ToolPath propose --work $Work --title $Title --body $Body
$rc = $LASTEXITCODE
[System.IO.File]::WriteAllText($ExitFile, [string]$rc)
exit $rc
'@
        [System.IO.File]::WriteAllText($writerWrapper, $writerWrapperText, (New-Object System.Text.UTF8Encoding($false)))
        for ($i = 1; $i -le $N; $i++) {
            $exitFile = Join-Path $W ("writer-$i.exit")
            $exitFiles += $exitFile
            $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $writerWrapper,
                '-ToolPath', $script:ToolPath, '-Work', $W,
                '-Title', "Concurrent-$i", '-Body', "body-$i", '-ExitFile', $exitFile)
            $procs += Start-Process -FilePath $script:PwshHost -ArgumentList $a -NoNewWindow -PassThru
        }
        # PowerShell 7.6 installed through WindowsApps can leave Start-Process.Process.ExitCode
        # as $null even after WaitForExit()/Refresh(). Each wrapper therefore persists the real
        # child exit code; the retained handles are used only for bounded waiting.
        for ($i = 0; $i -lt $procs.Count; $i++) {
            $p = $procs[$i]
            Assert-True ($p.WaitForExit(90000)) "[concurrent] writer pid $($p.Id) completed within 90s"
            Assert-True (Test-Path -LiteralPath $exitFiles[$i] -PathType Leaf) "[concurrent] writer pid $($p.Id) persisted its exit code"
            $writerExit = if (Test-Path -LiteralPath $exitFiles[$i] -PathType Leaf) { [System.IO.File]::ReadAllText($exitFiles[$i]).Trim() } else { '(missing)' }
            Assert-Equal '0' $writerExit "[concurrent] writer pid $($p.Id) exit"
        }

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

    # --- Scenario 13: proposal lane is invisible to every T-task operation ---
    # A P-NNN proposal shares the unified backlog but is never a candidate /
    # predecessor / readiness or validate-deps subject, and its own id sequence
    # is independent of T-NNN (task T-245).
    $W = New-Work
    try {
        Propose $W 'Real task A' 'do A' | Out-Null                       # T-001
        $r = Run-Tool @('propose', '--work', $W, '--kind', 'proposal', '--title', 'Idea one', '--body', 'raw idea body', '--source', 'user', '--suggested-target', 'next_major')
        Assert-Equal 0 $r.ExitCode '[proposal] propose --kind proposal succeeds'
        Assert-Match $r.Output 'id=P-001' '[proposal] proposals get their own P-NNN id sequence'
        Propose $W 'Real task B' 'do B' | Out-Null                       # T-002

        $q = Read-Queue $W
        Assert-Match $q '### \[P-001\] Idea one — kind: proposal — status: proposed' '[proposal] header form with explicit kind + english status'
        Assert-Match $q 'Suggested target: next_major' '[proposal] provenance field preserved'
        Assert-Match $q 'Source: user' '[proposal] source provenance field preserved'

        # id allocation lanes are independent: next task is T-003, next proposal is P-002
        Assert-Match (Run-Tool @('allocate-id', '--work', $W)).Output 'T-003' '[proposal] task id lane unaffected by proposals'
        Assert-Match (Run-Tool @('allocate-id', '--work', $W, '--kind', 'proposal')).Output 'P-002' '[proposal] proposal id lane independent'

        # readiness / validate-deps never surface a proposal
        $r = Run-Tool @('ready', '--work', $W)
        Assert-Match $r.Output 'ready: T-001 T-002' '[proposal] only real tasks are ready'
        Assert-True (-not ($r.Output -match 'P-0')) '[proposal] no proposal appears in readiness output'
        Assert-Equal 0 (Run-Tool @('validate-deps', '--work', $W)).ExitCode '[proposal] proposals do not break the dependency graph'

        # list-proposals surfaces only the proposal lane
        $r = Run-Tool @('list-proposals', '--work', $W, '--status', 'proposed')
        Assert-Match $r.Output 'P-001 proposed Idea one' '[proposal] list-proposals shows the proposed record'
        Assert-True (-not ($r.Output -match 'Real task')) '[proposal] list-proposals never lists tasks'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 14: end-to-end conversion preserves provenance ------------
    # proposal_curator flow: create the real task from the need, then convert the
    # proposal, whose ORIGINAL text stays byte-for-byte while only status flips and
    # evaluation fields are appended - even after an unrelated T-task mutation.
    $W = New-Work
    try {
        Run-Tool @('propose', '--work', $W, '--kind', 'proposal', '--title', 'Batch schema updates', '--body', "We repeatedly hand-edit schema.`nAuthor suggests a batch API.", '--source', 'user') | Out-Null   # P-001
        Propose $W 'Existing task' 'x' | Out-Null                        # T-001

        # guard: a proposal id can never be captured as an executable task
        $r = Run-Tool @('capture', '--work', $W, '--id', 'P-001', '--batch', 'B-1')
        Assert-Equal 2 $r.ExitCode '[convert] capturing a P-NNN is refused (exit 2)'
        Assert-Match $r.Output 'proposal.*not executable' '[convert] refusal names the proposal invariant'

        # guard: converted requires --tasks, and each must exist
        Assert-Equal 2 (Run-Tool @('classify-proposal', '--work', $W, '--id', 'P-001', '--outcome', 'converted')).ExitCode '[convert] converted without --tasks rejected'
        Assert-Equal 5 (Run-Tool @('classify-proposal', '--work', $W, '--id', 'P-001', '--outcome', 'converted', '--tasks', 'T-999')).ExitCode '[convert] converted with a non-existent task rejected'

        # curator creates the scoped task from the NEED, then converts
        Propose $W 'Add batch schema-update API' 'Introduce a batch endpoint. Происхождение: P-001' | Out-Null  # T-002
        $r = Run-Tool @('classify-proposal', '--work', $W, '--id', 'P-001', '--outcome', 'converted', '--tasks', 'T-002', '--reason', 'Real need; scoped task created.')
        Assert-Equal 0 $r.ExitCode '[convert] classify converted succeeds'
        Assert-Match $r.Output 'classified P-001 status=converted' '[convert] outcome reported'

        # an unrelated task mutation must not disturb the proposal record
        Run-Tool @('capture', '--work', $W, '--id', 'T-001', '--batch', 'B-20260101T000000Z') | Out-Null
        $q = Read-Queue $W
        Assert-Match $q '### \[P-001\] Batch schema updates — kind: proposal — status: converted' '[convert] status flipped to converted'
        Assert-Match $q 'We repeatedly hand-edit schema\.' '[convert] original proposal prose preserved verbatim (provenance)'
        Assert-Match $q 'Author suggests a batch API\.' '[convert] full original body preserved'
        Assert-Match $q 'Converted: T-002' '[convert] forward provenance link to the created task'
        Assert-Match $q 'Rationale: Real need; scoped task created\.' '[convert] rationale recorded without touching original text'
        Assert-Match $q '### \[T-002\] Add batch schema-update API' '[convert] the created executable task exists'
        Assert-Match $q 'Происхождение: P-001' '[convert] backward provenance link on the created task'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 15: proposal dedup, inbox lane, idempotent re-classify ----
    $W = New-Work
    try {
        # proposal dedup rejects a normalized-title duplicate
        Run-Tool @('propose', '--work', $W, '--kind', 'proposal', '--title', 'Cache the results', '--body', 'a') | Out-Null
        $r = Run-Tool @('propose', '--work', $W, '--kind', 'proposal', '--title', 'cache   the   results', '--body', 'b')
        Assert-Equal 4 $r.ExitCode '[proposal-dup] duplicate proposal title rejected (exit 4)'

        # inbox lane: a proposal submitted under an active lock drains into a P-record
        Run-Tool @('inbox-add', '--work', $W, '--kind', 'proposal', '--title', 'Inbox idea', '--body', 'idea body', '--source', 'thinker') | Out-Null
        Run-Tool @('inbox-add', '--work', $W, '--title', 'Inbox task', '--body', 'task body') | Out-Null
        $r = Run-Tool @('inbox-drain', '--work', $W)
        Assert-Equal 0 $r.ExitCode '[proposal-inbox] mixed proposal+task drain succeeds'
        $q = Read-Queue $W
        Assert-Match $q '### \[P-002\] Inbox idea — kind: proposal — status: proposed' '[proposal-inbox] proposal drained into a P-record'
        Assert-Match $q 'Source: thinker' '[proposal-inbox] provenance carried through the inbox'
        Assert-Match $q '### \[T-001\] Inbox task — статус: не начата' '[proposal-inbox] task drained into a T-record'

        # idempotent re-classification replaces the evaluation field, not duplicates it
        Run-Tool @('classify-proposal', '--work', $W, '--id', 'P-002', '--outcome', 'deferred', '--reason', 'later') | Out-Null
        Run-Tool @('classify-proposal', '--work', $W, '--id', 'P-002', '--outcome', 'rejected', '--reason', 'not needed') | Out-Null
        $q = Read-Queue $W
        Assert-Match $q '### \[P-002\] Inbox idea — kind: proposal — status: rejected' '[proposal-reclassify] final status is rejected'
        $reasonCount = ([regex]::Matches($q, 'Причина:')).Count
        Assert-Equal 1 $reasonCount '[proposal-reclassify] re-classify replaces the reason field (no duplication)'
        Assert-Match $q 'Причина: not needed' '[proposal-reclassify] latest reason kept'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 16: a proposal is never a blocking/unblocking predecessor --
    # A P-id in a task's `Предпосылки:` line forms no graph edge, so the task is
    # ready and the graph is valid (proposals never gate tasks - task T-245).
    $W = New-Work
    try {
        $q = @(
            '# Очередь задач', '',
            '### [P-001] A raw idea — kind: proposal — status: proposed', 'idea body', '',
            '### [T-001] Task referencing a proposal — статус: не начата', 'x', 'Предпосылки: P-001'
        ) -join "`n"
        [System.IO.File]::WriteAllText((Join-Path $W 'Tasks_Queue.md'), $q, (New-Object System.Text.UTF8Encoding($false)))

        $r = Run-Tool @('validate-deps', '--work', $W)
        Assert-Equal 0 $r.ExitCode '[proposal-pred] a P-id in Предпосылки is not a missing/edge dependency'
        $r = Run-Tool @('ready', '--work', $W)
        Assert-Match $r.Output 'ready: T-001' '[proposal-pred] the task is ready - a proposal never blocks it'
        Assert-True (-not ($r.Output -match 'not-ready')) '[proposal-pred] no blocking predecessor from the proposal'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 17: delivery lane excludes next_major from the ordinary ready --
    # A `Delivery target: next_major` task (docs/queue_contract.md §11.1) is parked out
    # of the default current-lane `ready` output planner captures from; it surfaces only
    # under `--next-major`, and the capture gate `ready --id` refuses it (task T-246).
    $W = New-Work
    try {
        $q = @(
            '# Очередь задач', '',
            '### [T-001] Ordinary current work — статус: не начата', 'body', 'Delivery target: current', '',
            '### [T-002] Parked breaking work — статус: не начата', 'body', 'Delivery target: next_major', '',
            '### [T-003] Fieldless legacy task — статус: не начата', 'body'
        ) -join "`n"
        [System.IO.File]::WriteAllText((Join-Path $W 'Tasks_Queue.md'), $q, (New-Object System.Text.UTF8Encoding($false)))

        # default `ready`: current lane only (T-001 and the fieldless T-003), never the next_major T-002
        $r = Run-Tool @('ready', '--work', $W)
        Assert-Match $r.Output 'ready: T-001 T-003' '[delivery] default ready lists current + fieldless(=current) tasks'
        Assert-True (-not ($r.Output -match 'T-002')) '[delivery] next_major task is absent from the default ready output'

        # `--next-major`: only the parked backlog, never the current-lane tasks
        $r = Run-Tool @('ready', '--work', $W, '--next-major')
        Assert-Match $r.Output 'ready: T-002' '[delivery] --next-major lists only the parked next_major backlog'
        Assert-True (-not ($r.Output -match 'T-001')) '[delivery] --next-major excludes current-lane tasks'

        # capture gate: `ready --id` on a next_major task refuses (exit 6) with a lane reason
        $r = Run-Tool @('ready', '--work', $W, '--id', 'T-002')
        Assert-Equal 6 $r.ExitCode '[delivery] ready --id on a next_major task is not-ready (capture gate refuses)'
        Assert-Match $r.Output 'next_major delivery lane' '[delivery] refusal names the next_major lane'

        # capture gate on a current task is unaffected
        $r = Run-Tool @('ready', '--work', $W, '--id', 'T-001')
        Assert-Equal 0 $r.ExitCode '[delivery] ready --id on a current task is ready'
        Assert-Match $r.Output 'ready T-001' '[delivery] current task ready via the capture gate'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 18: validate-deps rejects a current -> next_major edge --------
    $W = New-Work
    try {
        # T-002 (current, default) depends on T-001 (next_major) -> forbidden edge.
        $q = @(
            '# Очередь задач', '',
            '### [T-001] Breaking migration — статус: не начата', 'x', 'Delivery target: next_major', '',
            '### [T-002] Ordinary task — статус: не начата', 'x', 'Предпосылки: T-001'
        ) -join "`n"
        [System.IO.File]::WriteAllText((Join-Path $W 'Tasks_Queue.md'), $q, (New-Object System.Text.UTF8Encoding($false)))
        $r = Run-Tool @('validate-deps', '--work', $W)
        Assert-Equal 5 $r.ExitCode '[delivery-dep] current -> next_major edge is an invalid graph (exit 5)'
        Assert-Match $r.Output 'T-002: current task depends on next_major predecessor T-001' '[delivery-dep] finding names the forbidden edge'

        # The reverse edge (next_major -> current) is allowed: a valid graph.
        $q = @(
            '# Очередь задач', '',
            '### [T-001] Foundation current work — статус: не начата', 'x', '',
            '### [T-002] Breaking follow-up — статус: не начата', 'x', 'Delivery target: next_major', 'Предпосылки: T-001'
        ) -join "`n"
        [System.IO.File]::WriteAllText((Join-Path $W 'Tasks_Queue.md'), $q, (New-Object System.Text.UTF8Encoding($false)))
        $r = Run-Tool @('validate-deps', '--work', $W)
        Assert-Equal 0 $r.ExitCode '[delivery-dep] next_major -> current edge is a valid graph (exit 0)'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 19: propose rejects a current task depending on next_major ----
    $W = New-Work
    try {
        # A next_major task authored with the field in its body.
        $r = Run-Tool @('propose', '--work', $W, '--title', 'Parked breaking work', '--body', "desc`nDelivery target: next_major")
        Assert-Equal 0 $r.ExitCode '[delivery-propose] a next_major task can be proposed'
        Assert-Match $r.Output 'id=T-001' '[delivery-propose] next_major task got T-001'
        Assert-Match (Read-Queue $W) 'Delivery target: next_major' '[delivery-propose] delivery field preserved in the body'

        # a current-lane task (default, no field) may NOT declare the next_major task as predecessor
        $r = Run-Tool @('propose', '--work', $W, '--title', 'Current dependent', '--body', 'desc', '--predecessors', 'T-001')
        Assert-Equal 5 $r.ExitCode '[delivery-propose] current -> next_major predecessor rejected at propose time (exit 5)'
        Assert-Match $r.Output 'current task cannot depend on next_major predecessor T-001' '[delivery-propose] rejection names the rule'
        Assert-Equal 1 (Get-QueueIds $W).Count '[delivery-propose] rejected task never entered the queue'

        # but a next_major task MAY depend on the next_major task (next_major -> next_major is fine)
        $r = Run-Tool @('propose', '--work', $W, '--title', 'Breaking follow-up', '--body', "desc`nDelivery target: next_major", '--predecessors', 'T-001')
        Assert-Equal 0 $r.ExitCode '[delivery-propose] next_major -> next_major predecessor is allowed'
        Assert-Match $r.Output 'id=T-002' '[delivery-propose] the follow-up next_major task lands'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 20a: explicit task id already present in archive ------------
    $W = New-Work
    try {
        $done = @(
            '# Завершённые задачи', '',
            '### [T-700] Archived task — статус: завершена',
            'done'
        ) -join [Environment]::NewLine
        [System.IO.File]::WriteAllText((Join-Path $W 'Tasks_Done.md'), $done, (New-Object System.Text.UTF8Encoding($false)))

        $r = Run-Tool @('propose', '--work', $W, '--title', 'Reuse archived id', '--body', 'x', '--id', 'T-700')
        Assert-Equal 5 $r.ExitCode '[explicit-id-archive] archived id rejected with exit 5'
        Assert-Match $r.Output 'explicit id T-700 already exists in archive' '[explicit-id-archive] rejection names the archive source'
        Assert-Equal 0 (Get-QueueIds $W).Count '[explicit-id-archive] rejected task never entered the queue'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 20b: explicit task id already present in active tasks -------
    $W = New-Work
    try {
        $taskDir = Join-Path $W 'tasks\T-701'
        New-Item -ItemType Directory -Force -Path $taskDir | Out-Null
        $task = @(
            '# Дескриптор задачи T-701', '',
            '### [T-701] Active task'
        ) -join [Environment]::NewLine
        [System.IO.File]::WriteAllText((Join-Path $taskDir 'task.md'), $task, (New-Object System.Text.UTF8Encoding($false)))

        $r = Run-Tool @('propose', '--work', $W, '--title', 'Reuse active id', '--body', 'x', '--id', 'T-701')
        Assert-Equal 5 $r.ExitCode '[explicit-id-active] active id rejected with exit 5'
        Assert-Match $r.Output 'explicit id T-701 already exists in active tasks' '[explicit-id-active] rejection names the active-task source'
        Assert-Equal 0 (Get-QueueIds $W).Count '[explicit-id-active] rejected task never entered the queue'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 20c: explicit task id already present in queue --------------
    $W = New-Work
    try {
        $r = Run-Tool @('propose', '--work', $W, '--title', 'Original queued id', '--body', 'x', '--id', 'T-702')
        Assert-Equal 0 $r.ExitCode '[explicit-id-queue] initial explicit id accepted'

        $r = Run-Tool @('propose', '--work', $W, '--title', 'Reuse queued id', '--body', 'x', '--id', 'T-702')
        Assert-Equal 5 $r.ExitCode '[explicit-id-queue] queued id rejected with exit 5'
        Assert-Match $r.Output 'explicit id T-702 already in queue' '[explicit-id-queue] rejection names the queue source'
        Assert-Equal 1 (Get-QueueIds $W).Count '[explicit-id-queue] duplicate id never entered the queue'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 20d: malformed explicit task id is a usage error ------------
    $W = New-Work
    try {
        $r = Run-Tool @('propose', '--work', $W, '--title', 'Malformed explicit id', '--body', 'x', '--id', 'P-001')
        Assert-Equal 2 $r.ExitCode '[explicit-id-invalid] malformed task id rejected with exit 2'
        Assert-Match $r.Output 'invalid --id for --kind task: expected T-NNN, got P-001' '[explicit-id-invalid] usage error explains the expected task id form'
        Assert-Equal 0 (Get-QueueIds $W).Count '[explicit-id-invalid] malformed id was not auto-allocated'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }

    # --- Scenario 20e: unused explicit task id remains accepted ---------------
    $W = New-Work
    try {
        $r = Run-Tool @('propose', '--work', $W, '--title', 'Fresh explicit id', '--body', 'x', '--id', 'T-999')
        Assert-Equal 0 $r.ExitCode '[explicit-id-fresh] unused explicit id accepted'
        Assert-Match $r.Output 'id=T-999' '[explicit-id-fresh] requested id is preserved'
        Assert-Match (Read-Queue $W) '### \[T-999\] Fresh explicit id' '[explicit-id-fresh] task entered the queue under the requested id'
    } finally { Remove-Item -LiteralPath $W -Recurse -Force -ErrorAction SilentlyContinue }
}
