# ci:posix
<# Hermetic tests for the full Codex-native processor launcher runtime. #>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$runtime = (Resolve-Path (Join-Path $PSScriptRoot '..\..\tools\codex-processor-runtime.ps1')).Path
$failures = New-Object System.Collections.ArrayList
$onWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { [void]$failures.Add("FAIL - $Message") } }
function New-Fixture {
    $base = Join-Path ([System.IO.Path]::GetTempPath()) ('orc-codex-runtime-' + [Guid]::NewGuid().ToString('N'))
    $project = Join-Path $base 'project'
    $codexHome = Join-Path $base 'codex-home'
    $bin = Join-Path $base 'bin'
    New-Item -ItemType Directory -Force -Path (Join-Path $project '.work'), (Join-Path $codexHome 'agents'), $bin | Out-Null
    foreach ($name in @('orchestra_planner','orchestra_executor','orchestra_coder_fast','orchestra_coder','orchestra_coder_deep','orchestra_reviewer_std','orchestra_reviewer','orchestra_full_reviewer','orchestra_merger','orchestra_knowledge_curator','orchestra_inbox_curator','orchestra_dependency_curator')) {
        Set-Content -LiteralPath (Join-Path $codexHome "agents\$name.toml") -Value "name = '$name'`ndescription = 'fixture'`ndeveloper_instructions = 'fixture'" -Encoding utf8
    }
    $prompt = Join-Path $base 'processor.md'
    Set-Content -LiteralPath $prompt -Value 'FULL-PROCESSOR-PROMPT' -Encoding utf8
    $fakeScript = Join-Path $bin 'fake-codex.ps1'
    @'
$args | Set-Content -LiteralPath $env:FAKE_ARGS_FILE -Encoding utf8
$prompt = if ($args.Count -gt 0) { [string]$args[-1] } else { '' }
$prompt | Set-Content -LiteralPath $env:FAKE_PROMPT_FILE -Encoding utf8
$id = if ($env:FAKE_THREAD_ID) { $env:FAKE_THREAD_ID } else { '11111111-2222-3333-4444-555555555555' }
if ($env:FAKE_EMIT_THREAD -ne '0') {
    $now = Get-Date
    $sessionDir = Join-Path $env:CODEX_HOME (Join-Path 'sessions' (Join-Path $now.ToString('yyyy') (Join-Path $now.ToString('MM') $now.ToString('dd'))))
    New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null
    $rollout = Join-Path $sessionDir ('rollout-' + $now.ToString('yyyy-MM-ddTHH-mm-ss') + '-' + [guid]::NewGuid().ToString('N') + '.jsonl')
    @{ timestamp=$now.ToUniversalTime().ToString('o'); type='session_meta'; payload=@{ id=$id; cwd=(Get-Location).Path; originator='codex-tui' } } |
        ConvertTo-Json -Compress | Set-Content -LiteralPath $rollout -Encoding utf8
    @{ timestamp=$now.ToUniversalTime().ToString('o'); type='event_msg'; payload=@{ type='user_message'; message=$prompt } } |
        ConvertTo-Json -Compress | Add-Content -LiteralPath $rollout -Encoding utf8
}
Write-Output 'FAKE CODEX TUI'
$code = if ($env:FAKE_EXIT_CODE) { [int]$env:FAKE_EXIT_CODE } else { 0 }
exit $code
'@ | Set-Content -LiteralPath $fakeScript -Encoding utf8
    return [pscustomobject]@{ Base=$base; Project=$project; CodexHome=$codexHome; Prompt=$prompt; Fake=$fakeScript; Args=(Join-Path $base 'args.txt'); InitialPrompt=(Join-Path $base 'prompt.txt') }
}
function Invoke-Runtime {
    param($Fixture, [string]$Action, [hashtable]$Environment = @{}, [string[]]$Additional = @())
    $old = @{}
    $vars = @{
        CODEX_HOME = $Fixture.CodexHome
        FAKE_ARGS_FILE = $Fixture.Args
        FAKE_PROMPT_FILE = $Fixture.InitialPrompt
        FAKE_THREAD_ID = '11111111-2222-3333-4444-555555555555'
        FAKE_EMIT_THREAD = '1'
        FAKE_EXIT_CODE = '0'
        ORCHESTRA_CODEX_SANDBOX = ''
        ORCHESTRA_CODEX_REASONING = ''
        ORCHESTRA_CODEX_MAX_THREADS = ''
    }
    foreach ($key in $Environment.Keys) { $vars[$key] = $Environment[$key] }
    foreach ($key in $vars.Keys) { $old[$key] = [Environment]::GetEnvironmentVariable($key); [Environment]::SetEnvironmentVariable($key, [string]$vars[$key]) }
    try {
        $all = @('-NoProfile','-File',$runtime,$Action,'-Root',$Fixture.Project,'-PromptPath',$Fixture.Prompt,'-CodexCmd',$Fixture.Fake) + $Additional
        $outFile = Join-Path $Fixture.Base ('out-' + [Guid]::NewGuid().ToString('N') + '.txt')
        $errFile = Join-Path $Fixture.Base ('err-' + [Guid]::NewGuid().ToString('N') + '.txt')
        $p = Start-Process -FilePath 'pwsh' -ArgumentList $all -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        return [pscustomobject]@{ ExitCode=$p.ExitCode; Out=(Get-Content $outFile -Raw -ErrorAction SilentlyContinue); Err=(Get-Content $errFile -Raw -ErrorAction SilentlyContinue) }
    } finally {
        foreach ($key in $old.Keys) { [Environment]::SetEnvironmentVariable($key, $old[$key]) }
    }
}
function Write-ProcessorLease {
    param($Fixture, [datetime]$Heartbeat, [int]$TtlSeconds = 900)
    $lockDir = Join-Path $Fixture.Project '.work\orchestrator.lock'
    New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
    $lease = [ordered]@{
        schema = 'orchestra/lease@1'
        role = 'processor'
        owner_id = 'fixture-owner'
        session_id = 'fixture-session'
        root = $Fixture.Project
        host = 'fixture-remote-host'
        pid = $null
        acquired = $Heartbeat.ToUniversalTime().ToString('o')
        heartbeat = $Heartbeat.ToUniversalTime().ToString('o')
        ttl_seconds = $TtlSeconds
        generation = 4
    }
    [System.IO.File]::WriteAllText((Join-Path $lockDir 'lease.json'), ($lease | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
}

$f = New-Fixture
try {
    $r = Invoke-Runtime $f 'check'
    Assert-True ($r.ExitCode -eq 0) "complete 12-role package passes preflight (got $($r.ExitCode), err=$($r.Err))"
    Assert-True ($r.Out -match 'Codex custom roles = 12') 'preflight reports the complete 12-role package'

    $r = Invoke-Runtime $f 'start'
    Assert-True ($r.ExitCode -eq 0) "start exits 0 (got $($r.ExitCode), err=$($r.Err))"
    $capturedArgs = @(Get-Content -LiteralPath $f.Args)
    Assert-True (-not ($capturedArgs -contains 'exec')) 'start invokes the interactive Codex CLI, not codex exec'
    Assert-True ($capturedArgs -contains '-C') 'start pins project root with -C'
    Assert-True ($capturedArgs -contains 'danger-full-access') 'start defaults root processor to danger-full-access'
    Assert-True (($capturedArgs -contains 'approval_policy="never"') -or ($capturedArgs -contains 'approval_policy=never')) 'start disables interactive approvals'
    Assert-True ($capturedArgs -contains 'features.multi_agent=true') 'start explicitly enables multi-agent'
    Assert-True ($capturedArgs -contains 'agents.max_depth=1') 'start keeps leaf agents from recursively spawning'
    Assert-True (-not ($capturedArgs -contains '--json')) 'start does not expose JSONL instead of the TUI'
    $initialPrompt = Get-Content -LiteralPath $f.InitialPrompt -Raw
    Assert-True ($initialPrompt.Contains($f.Prompt)) 'start tells the TUI root to read the canonical processor prompt file'
    Assert-True (-not $initialPrompt.Contains('FULL-PROCESSOR-PROMPT')) 'start keeps the argv bootstrap short instead of copying the full prompt'
    Assert-True ($initialPrompt.Contains('never invoke Claude')) 'start invocation reinforces no-Claude contract'
    Assert-True ($r.Out -match 'FAKE CODEX TUI') 'interactive child inherits the root stdout stream'
    $session = Join-Path $f.Project '.work\codex_processor_session.json'
    Assert-True (Test-Path -LiteralPath $session) 'start persists addressed Codex processor session metadata'
    if (Test-Path -LiteralPath $session) {
        $meta = Get-Content -LiteralPath $session -Raw | ConvertFrom-Json
        Assert-True ($meta.thread_id -eq '11111111-2222-3333-4444-555555555555') 'metadata stores exact thread id'
        Assert-True ($meta.provider -eq 'codex') 'metadata stores provider'
    }

    $r = Invoke-Runtime $f 'resume'
    Assert-True ($r.ExitCode -eq 0) "resume exits 0 (got $($r.ExitCode))"
    $capturedArgs = @(Get-Content -LiteralPath $f.Args)
    Assert-True ($capturedArgs[0] -eq 'resume') 'resume invokes the interactive codex resume TUI'
    Assert-True ($capturedArgs -contains '11111111-2222-3333-4444-555555555555') 'resume addresses exact saved thread id'
    Assert-True ($capturedArgs -ccontains '-C') 'interactive resume pins the project root with its supported -C option'
    $resumePrompt = Get-Content -LiteralPath $f.InitialPrompt -Raw
    Assert-True (-not $resumePrompt.Contains($f.Prompt)) 'exact resume does not ask to reload the full processor prompt into thread context'
    Assert-True ($resumePrompt.Contains('Continue the exact Codex-native Orchestra processor session')) 'exact resume sends a focused continuation prompt'

    # An explicit cross-provider handoff starts a new Codex thread and supersedes the
    # previously addressed Codex session instead of accidentally resuming it.
    $handoffThreadId = '66666666-7777-8888-9999-aaaaaaaaaaaa'
    $r = Invoke-Runtime $f 'handoff' @{ FAKE_THREAD_ID=$handoffThreadId } @('-HandoffFrom', 'claude')
    Assert-True ($r.ExitCode -eq 0) "explicit Claude handoff exits 0 (got $($r.ExitCode), err=$($r.Err))"
    $capturedArgs = @(Get-Content -LiteralPath $f.Args)
    Assert-True (-not ($capturedArgs -contains 'resume')) 'explicit provider handoff starts a new interactive Codex thread'
    $handoffPrompt = Get-Content -LiteralPath $f.InitialPrompt -Raw
    Assert-True ($handoffPrompt.Contains('Operator-authorized provider handoff from the terminated claude processor')) 'explicit handoff identifies its source and operator authorization'
    Assert-True ($handoffPrompt.Contains('No conversation transcript is imported')) 'handoff states the cross-provider transcript boundary'
    Assert-True ($handoffPrompt.Contains('preserve existing worktrees')) 'handoff protects existing in-flight work'
    $meta = Get-Content -LiteralPath $session -Raw | ConvertFrom-Json
    Assert-True ($meta.thread_id -eq $handoffThreadId) 'explicit handoff replaces the superseded addressed Codex UUID'
    Assert-True ($meta.last_action -eq 'handoff') 'explicit handoff persists handoff provenance on the new addressed thread'

    # No addressed Codex thread plus durable cohort state automatically selects the
    # same provider-handoff recovery contract.
    Remove-Item -LiteralPath $session -Force
    Set-Content -LiteralPath (Join-Path $f.Project '.work\batch.md') -Value 'Batch: fixture' -Encoding utf8
    $r = Invoke-Runtime $f 'resume'
    Assert-True ($r.ExitCode -eq 0) "durable-state auto handoff exits 0 (got $($r.ExitCode), err=$($r.Err))"
    $capturedArgs = @(Get-Content -LiteralPath $f.Args)
    Assert-True (-not ($capturedArgs -contains 'resume')) 'auto handoff does not address an unrelated or missing Codex thread'
    $autoPrompt = Get-Content -LiteralPath $f.InitialPrompt -Raw
    Assert-True ($autoPrompt.Contains('Operator-authorized provider handoff')) 'durable-state recovery is explicitly framed as a provider handoff'
    $meta = Get-Content -LiteralPath $session -Raw | ConvertFrom-Json
    Assert-True ($meta.last_action -eq 'handoff') 'auto handoff persists handoff as the effective action'
    Remove-Item -LiteralPath (Join-Path $f.Project '.work\batch.md') -Force

    # A provider handoff must never create a second control loop while the old provider
    # still holds a live lease. It may recover that lease only after it is stale.
    Write-ProcessorLease -Fixture $f -Heartbeat ([DateTime]::UtcNow)
    Remove-Item -LiteralPath $f.Args -Force -ErrorAction SilentlyContinue
    $savedBeforeRefusal = Get-Content -LiteralPath $session -Raw
    $r = Invoke-Runtime $f 'handoff' @{} @('-HandoffFrom', 'claude')
    Assert-True ($r.ExitCode -eq 15) 'provider handoff refuses a live processor lease'
    Assert-True ($r.Err -match 'live processor lease still exists') 'live-lease refusal explains that Claude must be stopped first'
    Assert-True (-not (Test-Path -LiteralPath $f.Args)) 'live-lease refusal happens before Codex is invoked'
    Assert-True ((Get-Content -LiteralPath $session -Raw) -eq $savedBeforeRefusal) 'refused handoff preserves the existing addressed Codex pointer'

    Write-ProcessorLease -Fixture $f -Heartbeat ([DateTime]::UtcNow.AddHours(-2)) -TtlSeconds 1
    $r = Invoke-Runtime $f 'handoff' @{} @('-HandoffFrom', 'claude')
    Assert-True ($r.ExitCode -eq 0) "provider handoff accepts a stale processor lease (got $($r.ExitCode), err=$($r.Err))"
    Assert-True ([string]$r.Out -match 'stale processor lease is safe to recover') 'stale lease path is visible in runtime diagnostics'
    Remove-Item -LiteralPath (Join-Path $f.Project '.work\orchestrator.lock') -Recurse -Force

    $r = Invoke-Runtime $f 'start' @{ ORCHESTRA_CODEX_MAX_THREADS='0' }
    Assert-True ($r.ExitCode -eq 2) 'zero max-thread environment value fails closed'

    # A failed explicit start must not leave the previously addressed thread resumable.
    $r = Invoke-Runtime $f 'start' @{ FAKE_EMIT_THREAD='0'; FAKE_EXIT_CODE='7' }
    Assert-True ($r.ExitCode -eq 7) 'pre-thread Codex failure preserves its exit code'
    Assert-True (-not (Test-Path -LiteralPath $session)) 'failed explicit start invalidates superseded session metadata'

    # A malformed stored id is not passed as a session/thread name; resume cold-recovers.
    @{ schema='orchestra/codex-processor-session@1'; provider='codex'; thread_id='------------------------------------'; root=$f.Project } |
        ConvertTo-Json | Set-Content -LiteralPath $session -Encoding utf8
    $r = Invoke-Runtime $f 'resume'
    Assert-True ($r.ExitCode -eq 0) 'malformed addressed id triggers cold recovery'
    $capturedArgs = @(Get-Content -LiteralPath $f.Args)
    Assert-True (-not ($capturedArgs -contains 'resume')) 'malformed addressed id is never passed to codex resume'
    Assert-True ((Get-Content -LiteralPath $f.InitialPrompt -Raw).Contains($f.Prompt)) 'cold recovery still points the TUI root at the full processor prompt'

    $runtimeLockPath = Join-Path $f.Project '.work\codex-processor-runtime.lock'
    $heldLock = [System.IO.File]::Open($runtimeLockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $r = Invoke-Runtime $f 'start'
        Assert-True ($r.ExitCode -eq 14) 'a concurrent root runtime is rejected before it can replace addressed session metadata'
    } finally {
        $heldLock.Dispose()
    }

    $projectAgentDir = Join-Path $f.Project '.codex\agents'
    New-Item -ItemType Directory -Force -Path $projectAgentDir | Out-Null
    Set-Content -LiteralPath (Join-Path $projectAgentDir 'override.toml') -Value "name = 'orchestra_coder'`ndescription = 'override'`ndeveloper_instructions = 'override'" -Encoding utf8
    $r = Invoke-Runtime $f 'check'
    Assert-True ($r.ExitCode -eq 12) 'project-local custom agent cannot override a managed Orchestra role name'
    Remove-Item -LiteralPath $projectAgentDir -Recurse -Force

    $globalDuplicate = Join-Path $f.CodexHome 'agents\different_filename.toml'
    Set-Content -LiteralPath $globalDuplicate -Value "name = 'orchestra_dependency_curator'`ndescription = 'duplicate'`ndeveloper_instructions = 'duplicate'" -Encoding utf8
    $r = Invoke-Runtime $f 'check'
    Assert-True ($r.ExitCode -eq 12) 'second global custom agent cannot duplicate the dependency curator role name'
    Remove-Item -LiteralPath $globalDuplicate -Force

    if (-not $onWindows) {
        $caseDuplicate = Join-Path $f.CodexHome 'agents\ORCHESTRA_CODER.toml'
        Set-Content -LiteralPath $caseDuplicate -Value "name = 'orchestra_coder'`ndescription = 'case duplicate'`ndeveloper_instructions = 'case duplicate'" -Encoding utf8
        $r = Invoke-Runtime $f 'check'
        Assert-True ($r.ExitCode -eq 12) 'POSIX case-distinct filename cannot evade duplicate role-name detection'
        Remove-Item -LiteralPath $caseDuplicate -Force
    }

    $r = Invoke-Runtime $f 'start' @{ ORCHESTRA_CODEX_SANDBOX='read-only' }
    Assert-True ($r.ExitCode -eq 2) 'read-only root sandbox fails closed before Codex invocation'

    Remove-Item -LiteralPath (Join-Path $f.CodexHome 'agents\orchestra_inbox_curator.toml') -Force
    $r = Invoke-Runtime $f 'check'
    Assert-True ($r.ExitCode -eq 12) 'missing inbox curator role fails preflight'

    Set-Content -LiteralPath (Join-Path $f.CodexHome 'agents\orchestra_inbox_curator.toml') -Value "name = 'orchestra_inbox_curator'" -Encoding utf8
    $r = Invoke-Runtime $f 'check'
    Assert-True ($r.ExitCode -eq 12) 'structurally invalid inbox curator role fails preflight'
} finally {
    Remove-Item -LiteralPath $f.Base -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "test-codex-processor-runtime: $($failures.Count) failure(s):"
    foreach ($failure in $failures) { Write-Host "  $failure" }
    exit 1
}
Write-Host 'OK - Codex processor runtime shows the TUI, starts/resumes exact native sessions, enforces no-prompt autonomy, and validates the complete role package.'
