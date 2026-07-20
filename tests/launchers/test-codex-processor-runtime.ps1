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
    foreach ($name in @('orchestra_planner','orchestra_executor','orchestra_coder_fast','orchestra_coder','orchestra_coder_deep','orchestra_reviewer_std','orchestra_reviewer','orchestra_full_reviewer','orchestra_merger','orchestra_knowledge_curator')) {
        Set-Content -LiteralPath (Join-Path $codexHome "agents\$name.toml") -Value "name = '$name'`ndescription = 'fixture'`ndeveloper_instructions = 'fixture'" -Encoding utf8
    }
    $prompt = Join-Path $base 'processor.md'
    Set-Content -LiteralPath $prompt -Value 'FULL-PROCESSOR-PROMPT' -Encoding utf8
    $fakeScript = Join-Path $bin 'fake-codex.ps1'
    @'
$args | Set-Content -LiteralPath $env:FAKE_ARGS_FILE -Encoding utf8
[Console]::In.ReadToEnd() | Set-Content -LiteralPath $env:FAKE_STDIN_FILE -Encoding utf8
$id = if ($env:FAKE_THREAD_ID) { $env:FAKE_THREAD_ID } else { '11111111-2222-3333-4444-555555555555' }
if ($env:FAKE_EMIT_THREAD -ne '0') { Write-Output ('{"type":"thread.started","thread_id":"' + $id + '"}') }
Write-Output '{"type":"item.completed","item":{"type":"agent_message","text":"done"}}'
$code = if ($env:FAKE_EXIT_CODE) { [int]$env:FAKE_EXIT_CODE } else { 0 }
exit $code
'@ | Set-Content -LiteralPath $fakeScript -Encoding utf8
    if ($onWindows) {
        $fake = Join-Path $bin 'codex.cmd'
        "@echo off`r`npwsh -NoProfile -File `"%~dp0fake-codex.ps1`" %*`r`n" | Set-Content -LiteralPath $fake -Encoding ascii -NoNewline
    } else {
        $fake = Join-Path $bin 'codex'
        "#!/bin/sh`nexec pwsh -NoProfile -File `"`$(dirname -- `"`$0`")/fake-codex.ps1`" `"`$@`"`n" | Set-Content -LiteralPath $fake -Encoding utf8 -NoNewline
        & chmod '+x' $fake
    }
    return [pscustomobject]@{ Base=$base; Project=$project; CodexHome=$codexHome; Prompt=$prompt; Fake=$fake; Args=(Join-Path $base 'args.txt'); Stdin=(Join-Path $base 'stdin.txt') }
}
function Invoke-Runtime {
    param($Fixture, [string]$Action, [hashtable]$Environment = @{}, [string[]]$Additional = @())
    $old = @{}
    $vars = @{
        CODEX_HOME = $Fixture.CodexHome
        FAKE_ARGS_FILE = $Fixture.Args
        FAKE_STDIN_FILE = $Fixture.Stdin
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

$f = New-Fixture
try {
    $r = Invoke-Runtime $f 'start'
    Assert-True ($r.ExitCode -eq 0) "start exits 0 (got $($r.ExitCode), err=$($r.Err))"
    $capturedArgs = @(Get-Content -LiteralPath $f.Args)
    Assert-True ($capturedArgs[0] -eq 'exec') 'start invokes codex exec'
    Assert-True ($capturedArgs -contains '-C') 'start pins project root with -C'
    Assert-True ($capturedArgs -contains 'danger-full-access') 'start defaults root processor to danger-full-access'
    Assert-True (($capturedArgs -contains 'approval_policy="never"') -or ($capturedArgs -contains 'approval_policy=never')) 'start disables interactive approvals'
    Assert-True ($capturedArgs -contains 'features.multi_agent=true') 'start explicitly enables multi-agent'
    Assert-True ($capturedArgs -contains 'agents.max_depth=1') 'start keeps leaf agents from recursively spawning'
    Assert-True ($capturedArgs -contains '--skip-git-repo-check') 'start preserves Orchestra support for pure-jj repositories'
    Assert-True ($capturedArgs -contains '--json') 'start requests machine-readable thread id'
    $stdin = Get-Content -LiteralPath $f.Stdin -Raw
    Assert-True ($stdin.Contains('FULL-PROCESSOR-PROMPT')) 'start sends full processor prompt over stdin'
    Assert-True ($stdin.Contains('never invoke Claude')) 'start invocation reinforces no-Claude contract'
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
    Assert-True ($capturedArgs[0] -eq 'exec' -and $capturedArgs[1] -eq 'resume') 'resume invokes codex exec resume'
    Assert-True ($capturedArgs -contains '11111111-2222-3333-4444-555555555555') 'resume addresses exact saved thread id'
    Assert-True (-not ($capturedArgs -ccontains '-C')) 'resume does not pass unsupported -C option'
    Assert-True ($capturedArgs -contains '--skip-git-repo-check') 'resume preserves Orchestra support for pure-jj repositories'
    $resumeStdin = Get-Content -LiteralPath $f.Stdin -Raw
    Assert-True (-not $resumeStdin.Contains('FULL-PROCESSOR-PROMPT')) 'exact resume does not duplicate the full processor prompt into thread context'
    Assert-True ($resumeStdin.Contains('Continue the exact Codex-native Orchestra processor session')) 'exact resume sends a focused continuation prompt'

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
    Assert-True (-not ($capturedArgs -contains 'resume')) 'malformed addressed id is never passed to codex exec resume'
    Assert-True ((Get-Content -LiteralPath $f.Stdin -Raw).Contains('FULL-PROCESSOR-PROMPT')) 'cold recovery still receives the full processor prompt'

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
    Set-Content -LiteralPath $globalDuplicate -Value "name = 'orchestra_reviewer'`ndescription = 'duplicate'`ndeveloper_instructions = 'duplicate'" -Encoding utf8
    $r = Invoke-Runtime $f 'check'
    Assert-True ($r.ExitCode -eq 12) 'second global custom agent cannot duplicate a managed Orchestra role name'
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

    Remove-Item -LiteralPath (Join-Path $f.CodexHome 'agents\orchestra_merger.toml') -Force
    $r = Invoke-Runtime $f 'check'
    Assert-True ($r.ExitCode -eq 12) 'missing required custom role fails preflight'

    Set-Content -LiteralPath (Join-Path $f.CodexHome 'agents\orchestra_merger.toml') -Value "name = 'orchestra_merger'" -Encoding utf8
    $r = Invoke-Runtime $f 'check'
    Assert-True ($r.ExitCode -eq 12) 'structurally invalid custom role fails preflight'
} finally {
    Remove-Item -LiteralPath $f.Base -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "test-codex-processor-runtime: $($failures.Count) failure(s):"
    foreach ($failure in $failures) { Write-Host "  $failure" }
    exit 1
}
Write-Host 'OK - Codex processor runtime starts/resumes exact native sessions, enforces no-prompt autonomy, and validates the complete role package.'
