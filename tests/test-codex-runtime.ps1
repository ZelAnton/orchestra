<#
.SYNOPSIS
    Deterministic tests (T-075) for tools/codex-runtime.ps1 - the executable Codex
    adapter runtime - driven against a fake `codex` stub.

.DESCRIPTION
    tools/codex-runtime.ps1 is the real, executable home of the mechanical Codex
    protocol that used to live only as prose in agents/coder_codex.md /
    agents/reviewer_codex.md. Because it IS code, it can be unit-tested directly.
    This suite exercises it end-to-end through a PATH-independent fake `codex`
    (a .ps1 stub whose behaviour - captured argv, captured stdin, emitted
    stdout/stderr, exit code, sleep - is controlled entirely by FAKE_CODEX_*
    environment variables), plus the pure sub-commands directly, covering the
    acceptance cases required by T-075:

      * success (argv is safely constructed, prompt is delivered on stdin,
        stdout/stderr/RC are captured, structured result returned);
      * timeout and non-zero RC;
      * permission / availability refusal (codex not resolvable -> CODEX_UNAVAILABLE);
      * sandbox-init failure (CreateProcessAsUserW failed: 5 -> ENV_LIMIT/sandbox-init);
      * dependency-broker allowlist (accept canonical, reject metacharacters /
        non-allowlisted / non-canonical);
      * invalid codex output (reviewer RECHECK/NEW validation, oversized diff);
      * cleanup correctness after a failure (own worktree only; a main-tree call
        never deletes the untracked .work/);
      * failure-class -> escalation-sentinel mapping.

    The fake codex is a .ps1 so the runtime's process spawn / stdin / stream
    capture path is exercised without any shell, identically on Windows and POSIX
    (the git-backed cleanup/guard tests run wherever `git` is on PATH, which is
    the CI runner). The whole suite is written to be portable; it currently runs
    on the Windows CI runner (see .github/workflows/ci.yml) and is ready for a
    POSIX runner unchanged.

.EXAMPLE
    pwsh -File tests/test-codex-runtime.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$script:Runtime = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\codex-runtime.ps1')).Path
$script:PsExe = ([System.Diagnostics.Process]::GetCurrentProcess()).MainModule.FileName
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:TempItems = [System.Collections.Generic.List[string]]::new()

function New-TempFile {
    $p = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'codex-rt-' + [guid]::NewGuid().ToString('N'))
    $script:TempItems.Add($p)
    return $p
}
function New-TempDir {
    $p = New-TempFile
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    return $p
}

# Runs the runtime as a child process via System.Diagnostics.Process with an
# ArgumentList (exact per-element argv - no Start-Process re-quoting, so an
# argument containing spaces or shell metacharacters reaches the runtime as one
# element). Returns @{ ExitCode; Out; Err; Json }. Env vars are applied to the
# child only (and inherited by the grandchild fake codex).
function Invoke-Runtime {
    param(
        [Parameter(Mandatory)][string[]]$RuntimeArgs,
        [string]$StdinText = $null,
        [hashtable]$EnvVars = @{}
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:PsExe
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.StandardOutputEncoding = $script:Utf8
    $psi.StandardErrorEncoding = $script:Utf8
    $psi.StandardInputEncoding = $script:Utf8
    foreach ($a in (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:Runtime) + $RuntimeArgs)) {
        $psi.ArgumentList.Add($a)
    }
    foreach ($k in $EnvVars.Keys) { $psi.EnvironmentVariables[$k] = [string]$EnvVars[$k] }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if ($null -ne $StdinText) { $proc.StandardInput.Write($StdinText) }
    $proc.StandardInput.Close()
    $proc.WaitForExit()
    $out = $outTask.GetAwaiter().GetResult()
    $err = $errTask.GetAwaiter().GetResult()
    $exit = $proc.ExitCode
    $proc.Dispose()

    $json = $null
    if ($out -and $out.TrimStart().StartsWith('{')) {
        try { $json = $out | ConvertFrom-Json } catch { $json = $null }
    }
    return [pscustomobject]@{ ExitCode = $exit; Out = $out; Err = $err; Json = $json }
}

$script:FakeCodexBody = @'
$argsFile = $env:FAKE_CODEX_ARGS_FILE
if ($argsFile) {
    if ($args.Count -gt 0) { Set-Content -LiteralPath $argsFile -Value $args -Encoding utf8 }
    else { Set-Content -LiteralPath $argsFile -Value @() -Encoding utf8 }
}
$stdin = [Console]::In.ReadToEnd()
if ($env:FAKE_CODEX_STDIN_FILE) {
    [System.IO.File]::WriteAllText($env:FAKE_CODEX_STDIN_FILE, $stdin, (New-Object System.Text.UTF8Encoding($false)))
}
$oIdx = [array]::IndexOf($args, '-o')
if ($oIdx -ge 0 -and ($oIdx + 1) -lt $args.Count -and $env:FAKE_CODEX_OUT_CONTENT) {
    [System.IO.File]::WriteAllText($args[$oIdx + 1], $env:FAKE_CODEX_OUT_CONTENT, (New-Object System.Text.UTF8Encoding($false)))
}
if ($env:FAKE_CODEX_STDOUT) { [Console]::Out.Write($env:FAKE_CODEX_STDOUT) }
if ($env:FAKE_CODEX_STDERR) { [Console]::Error.Write($env:FAKE_CODEX_STDERR) }
if ($env:FAKE_CODEX_SLEEP_MS) { Start-Sleep -Milliseconds ([int]$env:FAKE_CODEX_SLEEP_MS) }
$code = 0
if ($env:FAKE_CODEX_EXIT) { $code = [int]$env:FAKE_CODEX_EXIT }
exit $code
'@

function New-FakeCodex {
    $p = (New-TempFile) + '.ps1'
    [System.IO.File]::WriteAllText($p, $script:FakeCodexBody, $script:Utf8)
    return $p
}

# --- assertion helpers --------------------------------------------------------
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { $script:Failures.Add("FAIL - $Message") }
}
function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { $script:Failures.Add("FAIL - ${Message}: expected [$Expected], got [$Actual]") }
}

function Get-ArgsCaptured {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { return @() }
    return @(Get-Content -LiteralPath $File -Encoding utf8)
}

# =============================================================================
# 1. Success: safe argv, stdin prompt, stream/RC capture, structured result
# =============================================================================
{
    $fake = New-FakeCodex
    $wt = New-TempDir
    $outFile = New-TempFile
    $errFile = New-TempFile
    $resultFile = New-TempFile
    $promptFile = New-TempFile
    $argsCap = New-TempFile
    $stdinCap = New-TempFile
    [System.IO.File]::WriteAllText($promptFile, "Implement the thing.`nDo it well.", $script:Utf8)

    $r = Invoke-Runtime -RuntimeArgs @(
        'run', '--codex-cmd', $fake, '--worktree', $wt, '--sandbox', 'workspace-write',
        '--reasoning', 'medium', '--network', 'on', '--model', 'gpt-5.6-terra',
        '--out-file', $outFile, '--stderr-file', $errFile, '--result-file', $resultFile,
        '--prompt-file', $promptFile
    ) -EnvVars @{
        FAKE_CODEX_ARGS_FILE = $argsCap; FAKE_CODEX_STDIN_FILE = $stdinCap
        FAKE_CODEX_OUT_CONTENT = 'Changed foo.'; FAKE_CODEX_STDOUT = 'progress...'; FAKE_CODEX_EXIT = '0'
    }

    Assert-Equal 0 $r.ExitCode 'success: runtime exit code 0'
    Assert-True ($null -ne $r.Json) 'success: emits parseable JSON result'
    if ($r.Json) {
        Assert-Equal $true $r.Json.ok 'success: result.ok is true'
        Assert-Equal 0 $r.Json.exitCode 'success: captured exitCode 0'
        Assert-Equal 'none' $r.Json.failureClass 'success: failureClass none'
        Assert-True ($null -eq $r.Json.sentinel) 'success: no sentinel on success'
    }
    $cap = Get-ArgsCaptured $argsCap
    Assert-True ($cap.Count -ge 2 -and $cap[0] -eq 'exec') 'success: codex invoked as `exec ...`'
    Assert-True ($cap -contains '--sandbox') 'success: argv has --sandbox'
    Assert-True ($cap -contains 'workspace-write') 'success: argv has sandbox value'
    Assert-True ($cap -contains 'approval_policy=never') 'success: argv pins fail-closed approval policy'
    Assert-True ($cap -contains 'sandbox_workspace_write.network_access=true') 'success: network=on adds the network override'
    Assert-True ($cap -contains 'model_reasoning_effort=medium') 'success: argv carries reasoning effort'
    Assert-True ($cap[$cap.Count - 1] -eq '-') 'success: prompt marker `-` is the final argv element'
    $stdinSeen = if (Test-Path -LiteralPath $stdinCap) { [System.IO.File]::ReadAllText($stdinCap) } else { '' }
    Assert-True ($stdinSeen -like '*Implement the thing.*Do it well.*') 'success: prompt delivered to codex on stdin'
    $outSeen = Get-Content -LiteralPath $outFile -Raw -Encoding utf8 -ErrorAction SilentlyContinue
    Assert-True ($outSeen -like '*Changed foo.*') 'success: codex -o out-file captured'
}.Invoke()

# =============================================================================
# 2. Shell-injection safety: a hostile worktree value stays one argv element
# =============================================================================
{
    $fake = New-FakeCodex
    $hostile = '/tmp/we ird; rm -rf / && echo pwned'
    $argsCap = New-TempFile
    $r = Invoke-Runtime -RuntimeArgs @(
        'run', '--codex-cmd', $fake, '--worktree', $hostile, '--sandbox', 'read-only',
        '--reasoning', 'low', '--out-file', (New-TempFile), '--prompt-file', (New-TempFile)
    ) -EnvVars @{ FAKE_CODEX_ARGS_FILE = $argsCap; FAKE_CODEX_EXIT = '0' }
    $cap = Get-ArgsCaptured $argsCap
    $cIdx = [array]::IndexOf($cap, '-C')
    Assert-True ($cIdx -ge 0 -and ($cIdx + 1) -lt $cap.Count) 'injection: argv has -C <worktree>'
    if ($cIdx -ge 0 -and ($cIdx + 1) -lt $cap.Count) {
        Assert-Equal $hostile $cap[$cIdx + 1] 'injection: hostile worktree preserved as exactly one argv element'
    }
}.Invoke()

# =============================================================================
# 3. Non-zero RC (no env signature) -> ordinary failure, no sentinel from run
# =============================================================================
{
    $fake = New-FakeCodex
    $r = Invoke-Runtime -RuntimeArgs @(
        'run', '--codex-cmd', $fake, '--worktree', (New-TempDir), '--sandbox', 'workspace-write',
        '--reasoning', 'medium', '--out-file', (New-TempFile), '--prompt-file', (New-TempFile)
    ) -EnvVars @{ FAKE_CODEX_STDERR = 'compile error: undefined symbol'; FAKE_CODEX_EXIT = '1' }
    Assert-True ($null -ne $r.Json) 'nonzero-rc: JSON result present'
    if ($r.Json) {
        Assert-Equal $false $r.Json.ok 'nonzero-rc: ok false'
        Assert-Equal 1 $r.Json.exitCode 'nonzero-rc: captured exitCode 1'
        Assert-Equal 'ordinary' $r.Json.failureClass 'nonzero-rc: classified ordinary (retry-eligible)'
        Assert-True ($null -eq $r.Json.sentinel) 'nonzero-rc: run does not escalate an ordinary failure'
    }
}.Invoke()

# =============================================================================
# 4. Timeout: a slow codex is killed and reported as timed out + CODEX_FAILED
# =============================================================================
{
    $fake = New-FakeCodex
    $r = Invoke-Runtime -RuntimeArgs @(
        'run', '--codex-cmd', $fake, '--worktree', (New-TempDir), '--sandbox', 'workspace-write',
        '--reasoning', 'medium', '--out-file', (New-TempFile), '--prompt-file', (New-TempFile),
        '--timeout-sec', '1'
    ) -EnvVars @{ FAKE_CODEX_SLEEP_MS = '10000'; FAKE_CODEX_EXIT = '0' }
    Assert-True ($null -ne $r.Json) 'timeout: JSON result present'
    if ($r.Json) {
        Assert-Equal $true $r.Json.timedOut 'timeout: timedOut true'
        Assert-Equal $false $r.Json.ok 'timeout: ok false'
        Assert-True ($null -ne $r.Json.sentinel -and $r.Json.sentinel -like '*CODEX_FAILED*timed out*') 'timeout: CODEX_FAILED timeout sentinel'
    }
}.Invoke()

# =============================================================================
# 5. Permission / availability refusal: codex not resolvable -> CODEX_UNAVAILABLE
# =============================================================================
{
    $r = Invoke-Runtime -RuntimeArgs @(
        'run', '--codex-cmd', 'definitely-not-a-real-codex-xyz-42', '--worktree', (New-TempDir),
        '--sandbox', 'workspace-write', '--reasoning', 'medium', '--out-file', (New-TempFile),
        '--prompt-file', (New-TempFile)
    )
    Assert-Equal 3 $r.ExitCode 'unavailable: exit code 3'
    Assert-True ($null -ne $r.Json) 'unavailable: JSON result present'
    if ($r.Json) {
        Assert-Equal $false $r.Json.ok 'unavailable: ok false'
        Assert-Equal 'resolve' $r.Json.stage 'unavailable: stage resolve'
        Assert-True ($r.Json.sentinel -like '*CODEX_UNAVAILABLE*') 'unavailable: CODEX_UNAVAILABLE sentinel'
    }
}.Invoke()

# =============================================================================
# 6. Sandbox-init failure -> ENV_LIMIT/sandbox-init escalation
# =============================================================================
{
    $fake = New-FakeCodex
    $r = Invoke-Runtime -RuntimeArgs @(
        'run', '--codex-cmd', $fake, '--worktree', (New-TempDir), '--sandbox', 'workspace-write',
        '--reasoning', 'medium', '--out-file', (New-TempFile), '--prompt-file', (New-TempFile)
    ) -EnvVars @{ FAKE_CODEX_STDERR = 'sandbox error: CreateProcessAsUserW failed: 5 (Access is denied)'; FAKE_CODEX_EXIT = '1' }
    Assert-True ($null -ne $r.Json) 'sandbox-init: JSON result present'
    if ($r.Json) {
        Assert-Equal 'sandbox-init' $r.Json.failureClass 'sandbox-init: classified sandbox-init'
        Assert-Equal $true $r.Json.envLimit 'sandbox-init: envLimit true'
        Assert-True ($r.Json.sentinel -like '*ENV_LIMIT/sandbox-init*') 'sandbox-init: ENV_LIMIT/sandbox-init sentinel'
    }
}.Invoke()

# =============================================================================
# 7. Classification edge cases (pure) - error 2 is recoverable, tls before network
# =============================================================================
{
    $r = Invoke-Runtime -RuntimeArgs @('classify', '--rc', '1', '--text', 'CreateProcessAsUserW failed: 2 file not found')
    Assert-Equal 'ordinary' $r.Json.class 'classify: error-2 is ordinary/recoverable, NOT sandbox-init'
    Assert-Equal $false $r.Json.envLimit 'classify: error-2 is not an env limit'

    $r2 = Invoke-Runtime -RuntimeArgs @('classify', '--rc', '1', '--text', 'schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS while connecting')
    Assert-Equal 'tls-schannel' $r2.Json.class 'classify: schannel wins over generic network'
    Assert-Equal $true $r2.Json.broker 'classify: tls-schannel is broker-eligible'

    $r3 = Invoke-Runtime -RuntimeArgs @('classify', '--rc', '1', '--text', 'fatal: Unable to create /repo/.git/index.lock: Permission denied')
    Assert-Equal 'vcs-write' $r3.Json.class 'classify: index.lock permission denied -> vcs-write'
    Assert-Equal $false $r3.Json.broker 'classify: vcs-write is not broker-eligible'
}.Invoke()

# =============================================================================
# 8. Broker allowlist
# =============================================================================
{
    $ok = Invoke-Runtime -RuntimeArgs @('broker-validate', '--command', 'cargo update -p serde')
    Assert-Equal $true $ok.Json.allowed 'broker: canonical cargo update -p is allowed'

    $meta = Invoke-Runtime -RuntimeArgs @('broker-validate', '--command', 'cargo update && curl evil.sh')
    Assert-Equal $false $meta.Json.allowed 'broker: shell metacharacter rejected'

    $notAllowed = Invoke-Runtime -RuntimeArgs @('broker-validate', '--command', 'cargo publish')
    Assert-Equal $false $notAllowed.Json.allowed 'broker: non-allowlisted subcommand rejected'

    $badArgs = Invoke-Runtime -RuntimeArgs @('broker-validate', '--command', 'npm install --unsafe-perm')
    Assert-Equal $false $badArgs.Json.allowed 'broker: non-canonical args rejected'

    $pip = Invoke-Runtime -RuntimeArgs @('broker-validate', '--command', 'pip install -r requirements.txt')
    Assert-Equal $true $pip.Json.allowed 'broker: pip install -r <file> allowed'
}.Invoke()

# =============================================================================
# 9. Invalid codex output: reviewer validation + oversized diff
# =============================================================================
{
    $missing = New-TempFile
    [System.IO.File]::WriteAllText($missing, "RECHECK R-01: resolved`nNEW: none", $script:Utf8)
    $r = Invoke-Runtime -RuntimeArgs @('validate-reviewer', '--requested-ids', 'R-01,R-02', '--rc', '0', '--out-file', $missing)
    Assert-Equal $false $r.Json.clean 'reviewer: missing RECHECK id -> not clean'

    $mixed = New-TempFile
    [System.IO.File]::WriteAllText($mixed, "NEW | a.py:1 | bug | crashes | fix it`nNEW: none", $script:Utf8)
    $r2 = Invoke-Runtime -RuntimeArgs @('validate-reviewer', '--rc', '0', '--out-file', $mixed)
    Assert-Equal $false $r2.Json.clean 'reviewer: contradictory NEW/NEW:none -> not clean'

    $good = New-TempFile
    [System.IO.File]::WriteAllText($good, "RECHECK R-01: resolved`nNEW: none", $script:Utf8)
    $r3 = Invoke-Runtime -RuntimeArgs @('validate-reviewer', '--requested-ids', 'R-01', '--rc', '0', '--out-file', $good)
    Assert-Equal $true $r3.Json.clean 'reviewer: complete RECHECK + NEW: none -> clean'

    $big = New-TempFile
    [System.IO.File]::WriteAllText($big, ((1..5000 | ForEach-Object { "line $_" }) -join "`n"), $script:Utf8)
    $rd = Invoke-Runtime -RuntimeArgs @('check-diff', '--diff-file', $big, '--max-lines', '4000')
    Assert-Equal $true $rd.Json.overLimit 'check-diff: 5000-line diff exceeds 4000 threshold'
    Assert-Equal 5000 $rd.Json.lines 'check-diff: line count reported'

    $small = New-TempFile
    [System.IO.File]::WriteAllText($small, ((1..10 | ForEach-Object { "line $_" }) -join "`n"), $script:Utf8)
    $rs = Invoke-Runtime -RuntimeArgs @('check-diff', '--diff-file', $small, '--max-lines', '4000')
    Assert-Equal $false $rs.Json.overLimit 'check-diff: small diff under threshold'
}.Invoke()

# =============================================================================
# 10. Fail-closed argv validation (invalid values never reach codex)
# =============================================================================
{
    $r = Invoke-Runtime -RuntimeArgs @('build-argv', '--worktree', 'x', '--sandbox', 'danger-full-access', '--reasoning', 'medium')
    Assert-Equal 2 $r.ExitCode 'build-argv: danger-full-access rejected with exit 2'
    Assert-True ($r.Err -like '*invalid --sandbox*') 'build-argv: reports the invalid sandbox value'

    $r2 = Invoke-Runtime -RuntimeArgs @('build-argv', '--worktree', 'x', '--sandbox', 'read-only', '--reasoning', 'extreme')
    Assert-Equal 2 $r2.ExitCode 'build-argv: invalid reasoning rejected with exit 2'

    $r3 = Invoke-Runtime -RuntimeArgs @('build-argv', '--worktree', 'x', '--sandbox', 'read-only', '--reasoning', 'medium')
    Assert-Equal 0 $r3.ExitCode 'build-argv: valid values accepted'
    Assert-True ($r3.Json.argv -contains 'approval_policy=never') 'build-argv: pins approval_policy=never'
    Assert-True (-not ($r3.Json.argv -contains 'sandbox_workspace_write.network_access=true')) 'build-argv: network defaults off (no override)'

    # T-100: xhigh is a confirmed reasoning-effort tier (codex-cli 0.144.1); reviewer_codex
    # defaults to it, so the runtime must accept it and carry it verbatim into the argv.
    $r4 = Invoke-Runtime -RuntimeArgs @('build-argv', '--worktree', 'x', '--sandbox', 'read-only', '--reasoning', 'xhigh')
    Assert-Equal 0 $r4.ExitCode 'build-argv: xhigh reasoning accepted'
    Assert-True ($r4.Json.argv -contains 'model_reasoning_effort=xhigh') 'build-argv: argv carries xhigh reasoning effort'
}.Invoke()

# =============================================================================
# 11. Sentinel mapping (pure)
# =============================================================================
{
    $u = Invoke-Runtime -RuntimeArgs @('map-sentinel', '--kind', 'unavailable', '--detail', 'no binary')
    Assert-True ($u.Out.Trim() -like '*CODEX_UNAVAILABLE*no binary*') 'sentinel: unavailable mapping'

    $f = Invoke-Runtime -RuntimeArgs @('map-sentinel', '--kind', 'failed', '--detail', 'smoke red')
    Assert-True ($f.Out.Trim() -like '*CODEX_FAILED*smoke red*' -and $f.Out -notlike '*ENV_LIMIT*') 'sentinel: plain CODEX_FAILED (no ENV_LIMIT)'

    $e = Invoke-Runtime -RuntimeArgs @('map-sentinel', '--kind', 'failed', '--class', 'network', '--detail', 'broker gave up')
    Assert-True ($e.Out.Trim() -like '*CODEX_FAILED*ENV_LIMIT/network*broker gave up*') 'sentinel: ENV_LIMIT/<class> mapping'
}.Invoke()

# =============================================================================
# 12. VCS no-commit guard + cleanup (git-backed; runs where git is available)
# =============================================================================
$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    Write-Host 'SKIP - git not on PATH; guard-commit / cleanup git tests skipped (they run on the CI runner).'
} else {
    function New-TempGitRepo {
        $dir = New-TempDir
        & git -C $dir init -q 2>&1 | Out-Null
        & git -C $dir config user.email 'test@example.com' 2>&1 | Out-Null
        & git -C $dir config user.name 'Test' 2>&1 | Out-Null
        & git -C $dir config commit.gpgsign false 2>&1 | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'a.txt'), 'one', $script:Utf8)
        & git -C $dir add -A 2>&1 | Out-Null
        & git -C $dir commit -q -m init 2>&1 | Out-Null
        return $dir
    }

    # guard-commit: codex "committed" -> detected + soft-reset restores HEAD, keeps changes
    {
        $repo = New-TempGitRepo
        $pre = (& git -C $repo rev-parse HEAD).Trim()
        [System.IO.File]::WriteAllText((Join-Path $repo 'a.txt'), 'two', $script:Utf8)
        & git -C $repo add -A 2>&1 | Out-Null
        & git -C $repo commit -q -m 'codex sneaked a commit' 2>&1 | Out-Null
        $post = (& git -C $repo rev-parse HEAD).Trim()
        Assert-True ($pre -ne $post) 'guard-commit: precondition - a commit was made'

        $r = Invoke-Runtime -RuntimeArgs @('guard-commit', '--worktree', $repo, '--vcs', 'git', '--pre', $pre, '--reset')
        Assert-Equal $true $r.Json.committed 'guard-commit: detects the commit drift'
        Assert-Equal 'soft-reset' $r.Json.action 'guard-commit: performs a soft reset'
        $after = (& git -C $repo rev-parse HEAD).Trim()
        Assert-Equal $pre $after 'guard-commit: HEAD restored to pre'
        $content = [System.IO.File]::ReadAllText((Join-Path $repo 'a.txt'))
        Assert-Equal 'two' $content 'guard-commit: soft reset keeps the working-tree change (never --hard)'
    }.Invoke()

    # guard-commit: no commit -> committed false, no action
    {
        $repo = New-TempGitRepo
        $pre = (& git -C $repo rev-parse HEAD).Trim()
        $r = Invoke-Runtime -RuntimeArgs @('guard-commit', '--worktree', $repo, '--vcs', 'git', '--pre', $pre, '--reset')
        Assert-Equal $false $r.Json.committed 'guard-commit: clean history -> not committed'
        Assert-Equal 'none' $r.Json.action 'guard-commit: no action when clean'
    }.Invoke()

    # cleanup (worktree mode): reverts tracked change and removes untracked file
    {
        $repo = New-TempGitRepo
        [System.IO.File]::WriteAllText((Join-Path $repo 'a.txt'), 'dirty', $script:Utf8)
        [System.IO.File]::WriteAllText((Join-Path $repo 'junk.txt'), 'temp', $script:Utf8)
        $r = Invoke-Runtime -RuntimeArgs @('cleanup', '--worktree', $repo, '--vcs', 'git')
        Assert-Equal 'one' ([System.IO.File]::ReadAllText((Join-Path $repo 'a.txt'))) 'cleanup: tracked change reverted'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo 'junk.txt'))) 'cleanup: untracked file removed'
    }.Invoke()

    # cleanup (main-tree mode): NEVER deletes the untracked .work/
    {
        $repo = New-TempGitRepo
        [System.IO.File]::WriteAllText((Join-Path $repo '.gitignore'), ".work/`n", $script:Utf8)
        & git -C $repo add .gitignore 2>&1 | Out-Null
        & git -C $repo commit -q -m 'ignore work' 2>&1 | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $repo '.work') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $repo '.work\keep.txt'), 'coordination', $script:Utf8)
        [System.IO.File]::WriteAllText((Join-Path $repo 'a.txt'), 'dirty', $script:Utf8)
        [System.IO.File]::WriteAllText((Join-Path $repo 'junk.txt'), 'temp', $script:Utf8)
        $r = Invoke-Runtime -RuntimeArgs @('cleanup', '--worktree', $repo, '--vcs', 'git', '--main-tree')
        Assert-Equal 'one' ([System.IO.File]::ReadAllText((Join-Path $repo 'a.txt'))) 'cleanup(main): tracked change reverted'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo 'junk.txt'))) 'cleanup(main): stray untracked file removed'
        Assert-True (Test-Path -LiteralPath (Join-Path $repo '.work\keep.txt')) 'cleanup(main): untracked .work/ PRESERVED (never git clean -fd)'
    }.Invoke()
}

# =============================================================================
# 13. jj no-commit guard (T-120): the fingerprint must be STABLE across a plain
# file edit (auto-snapshot changes commit_id but NOT change_id -> committed=false),
# yet still catch a real drift (`jj new` / a bookmark set onto `@` -> jj-drift).
# Self-skips when jj is not on PATH (optional binary; jj is not installed on CI).
# =============================================================================
$jj = Get-Command jj -ErrorAction SilentlyContinue
if (-not $jj) {
    Write-Host 'SKIP - jj not on PATH; guard-commit jj tests skipped (optional-binary self-skip; jj is not installed on the CI runner).'
} else {
    function New-TempJjRepo {
        # A short-lived jj repo under the OS temp dir. Kept out of the deep
        # scratchpad tree so the internal `.jj/repo/index/segments/<hash>` paths
        # stay under the Windows MAX_PATH limit.
        $dir = New-TempDir
        & jj git init $dir 2>&1 | Out-Null
        & jj -R $dir config set --repo user.name 'Test' 2>&1 | Out-Null
        & jj -R $dir config set --repo user.email 'test@example.com' 2>&1 | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'a.txt'), 'one', $script:Utf8)
        return $dir
    }

    # (a) FALSE-POSITIVE CLOSED: a plain file edit (no VCS-mutating command) must NOT
    # be read as a commit - guard-commit returns committed=false / action=none. This is
    # the exact scenario a successful coder_codex Mode 1/2/3 produces on jj; before T-120
    # the commit_id-based signal flipped on the edit and false-escalated as jj-drift.
    {
        $repo = New-TempJjRepo
        # PRE via the SAME code path guard-commit uses for POST (guard-head), so a pass
        # is proof the fingerprint itself is stable, not an artifact of a matching capture.
        $preR = Invoke-Runtime -RuntimeArgs @('guard-head', '--worktree', $repo, '--vcs', 'jj')
        $pre = $preR.Out.Trim()
        Assert-True ($pre -ne '') 'guard-commit(jj): guard-head yields a non-empty change_id fingerprint'

        # A pure working-copy edit - jj auto-snapshots it (commit_id moves, change_id stays).
        [System.IO.File]::WriteAllText((Join-Path $repo 'a.txt'), 'two - edited, but NOT committed', $script:Utf8)

        $r = Invoke-Runtime -RuntimeArgs @('guard-commit', '--worktree', $repo, '--vcs', 'jj', '--pre', $pre, '--reset')
        Assert-Equal $false $r.Json.committed 'guard-commit(jj): a plain file edit is NOT a commit (committed=false)'
        Assert-Equal 'none' $r.Json.action 'guard-commit(jj): no jj-drift action on a plain edit (false positive closed)'
        Assert-Equal $pre $r.Json.post 'guard-commit(jj): post fingerprint == pre across the edit (change_id stable)'
    }.Invoke()

    # (b) TRUE-POSITIVE PRESERVED - new revision: `jj new` moves the change_id of `@`,
    # a genuine history drift -> committed=true, action=jj-drift (never a rewrite).
    {
        $repo = New-TempJjRepo
        $pre = (Invoke-Runtime -RuntimeArgs @('guard-head', '--worktree', $repo, '--vcs', 'jj')).Out.Trim()
        & jj -R $repo new 2>&1 | Out-Null
        $r = Invoke-Runtime -RuntimeArgs @('guard-commit', '--worktree', $repo, '--vcs', 'jj', '--pre', $pre, '--reset')
        Assert-Equal $true $r.Json.committed 'guard-commit(jj): `jj new` (new change_id) IS detected as drift'
        Assert-Equal 'jj-drift' $r.Json.action 'guard-commit(jj): real drift -> action=jj-drift (reported, never rewritten)'
    }.Invoke()

    # (b') TRUE-POSITIVE PRESERVED - bookmark moved onto `@`: another way codex could
    # "commit" its work. The change_id of `@` is unchanged, so this proves the bookmark
    # component of the fingerprint (not change_id alone) carries the signal.
    {
        $repo = New-TempJjRepo
        $pre = (Invoke-Runtime -RuntimeArgs @('guard-head', '--worktree', $repo, '--vcs', 'jj')).Out.Trim()
        & jj -R $repo bookmark create sneaky -r '@' 2>&1 | Out-Null
        $r = Invoke-Runtime -RuntimeArgs @('guard-commit', '--worktree', $repo, '--vcs', 'jj', '--pre', $pre, '--reset')
        Assert-Equal $true $r.Json.committed 'guard-commit(jj): a bookmark set onto `@` IS detected as drift'
        Assert-Equal 'jj-drift' $r.Json.action 'guard-commit(jj): bookmark drift -> action=jj-drift'
    }.Invoke()
}

# =============================================================================
# Report + cleanup
# =============================================================================
foreach ($item in $script:TempItems) {
    Remove-Item -LiteralPath $item -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures.Count -eq 0) {
    Write-Host 'OK - codex-runtime.ps1 behaves per contract for all fixture scenarios.'
    exit 0
}
Write-Host "Found $($script:Failures.Count) failing assertion(s):`n"
foreach ($f in $script:Failures) { Write-Host $f }
exit 1
