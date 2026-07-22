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
      * active-VCS working-copy status in a colocated jj+git repo where Git is
        clean but jj has a substantive uncommitted working-copy revision;
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
$script:Preflight = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\codex-preflight.ps1')).Path
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
        [string]$ScriptPath = $script:Runtime,
        [string]$StdinText = $null,
        [hashtable]$EnvVars = @{},
        # A watchdog (ms): 0 = wait indefinitely (default, unchanged for existing callers).
        # >0 bounds the wait so a REGRESSION that wedges the runtime host (e.g. on a leaked
        # pipe-inheriting descendant) FAILS the test instead of hanging the suite; on overrun
        # the whole runtime tree is killed and TimedOut is set.
        [int]$TimeoutMs = 0
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
    foreach ($a in (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $RuntimeArgs)) {
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
    $timedOut = $false
    if ($TimeoutMs -gt 0) {
        # Timed overload waits only on process exit (not on redirected-stream EOF), so a
        # wedged host is caught here rather than blocking us the same way it blocked it.
        if (-not $proc.WaitForExit($TimeoutMs)) {
            $timedOut = $true
            try { $proc.Kill($true) } catch { }   # reap the whole runtime tree incl. the offending descendant
            try { $proc.WaitForExit(5000) | Out-Null } catch { }
        }
    } else {
        $proc.WaitForExit()
    }
    $out = $outTask.GetAwaiter().GetResult()
    $err = $errTask.GetAwaiter().GetResult()
    $exit = try { $proc.ExitCode } catch { -1 }
    $proc.Dispose()

    $json = $null
    if ($out -and $out.TrimStart().StartsWith('{')) {
        try { $json = $out | ConvertFrom-Json } catch { $json = $null }
    }
    return [pscustomobject]@{ ExitCode = $exit; Out = $out; Err = $err; Json = $json; TimedOut = $timedOut }
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
if ($env:FAKE_CODEX_ENV_FILE) {
    $cacheEnv = [ordered]@{}
    foreach ($name in @('TEMP','TMP','UV_CACHE_DIR','PIP_CACHE_DIR','NPM_CONFIG_CACHE','XDG_CACHE_HOME','PYTHONPYCACHEPREFIX')) {
        $cacheEnv[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    [System.IO.File]::WriteAllText($env:FAKE_CODEX_ENV_FILE, ($cacheEnv | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
}
if ($env:FAKE_CODEX_CWD_FILE) {
    [System.IO.File]::WriteAllText($env:FAKE_CODEX_CWD_FILE, ([Environment]::CurrentDirectory), (New-Object System.Text.UTF8Encoding($false)))
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
    $envCap = New-TempFile
    $cwdCap = New-TempFile
    [System.IO.File]::WriteAllText($promptFile, "Implement the thing.`nDo it well.", $script:Utf8)

    $r = Invoke-Runtime -RuntimeArgs @(
        'run', '--codex-cmd', $fake, '--worktree', $wt, '--sandbox', 'workspace-write',
        '--reasoning', 'medium', '--network', 'on', '--model', 'gpt-5.6-terra',
        '--out-file', $outFile, '--stderr-file', $errFile, '--result-file', $resultFile,
        '--prompt-file', $promptFile
    ) -EnvVars @{
        FAKE_CODEX_ARGS_FILE = $argsCap; FAKE_CODEX_STDIN_FILE = $stdinCap; FAKE_CODEX_ENV_FILE = $envCap; FAKE_CODEX_CWD_FILE = $cwdCap
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
    $cacheRoot = Join-Path $wt '.work/codex-cache'
    $addDirIndex = [array]::IndexOf($cap, '--add-dir')
    Assert-Equal -1 $addDirIndex 'success: workspace-write does not add a redundant nested writable root'
    Assert-True ($cap -contains 'approval_policy=never') 'success: argv pins fail-closed approval policy'
    Assert-True ($cap -contains 'sandbox_workspace_write.network_access=true') 'success: network=on adds the network override'
    Assert-True ($cap -contains 'model_reasoning_effort=medium') 'success: argv carries reasoning effort'
    Assert-True ($cap[$cap.Count - 1] -eq '-') 'success: prompt marker `-` is the final argv element'
    $stdinSeen = if (Test-Path -LiteralPath $stdinCap) { [System.IO.File]::ReadAllText($stdinCap) } else { '' }
    Assert-True ($stdinSeen -like '*Implement the thing.*Do it well.*') 'success: prompt delivered to codex on stdin'
    $cacheEnv = (Get-Content -LiteralPath $envCap -Raw -Encoding utf8) | ConvertFrom-Json
    Assert-Equal (Join-Path $cacheRoot 'uv') $cacheEnv.UV_CACHE_DIR 'success: uv cache redirected inside ignored worktree .work'
    Assert-Equal (Join-Path $cacheRoot 'tmp') $cacheEnv.TEMP 'success: temp redirected inside ignored worktree .work'
    Assert-True (Test-Path -LiteralPath $cacheEnv.UV_CACHE_DIR -PathType Container) 'success: redirected cache is created before codex starts'
    $cwdSeen = Get-Content -LiteralPath $cwdCap -Raw -Encoding utf8
    Assert-Equal ([IO.Path]::GetFullPath($wt).TrimEnd('\','/')) ([IO.Path]::GetFullPath($cwdSeen).TrimEnd('\','/')) 'success: runtime process cwd is pinned to the assigned worktree'
    $outSeen = Get-Content -LiteralPath $outFile -Raw -Encoding utf8 -ErrorAction SilentlyContinue
    Assert-True ($outSeen -like '*Changed foo.*') 'success: codex -o out-file captured'
}.Invoke()

# =============================================================================
# 2. Shell-injection safety: a hostile worktree value stays one argv element
# =============================================================================
{
    $fake = New-FakeCodex
    $hostile = Join-Path (New-TempDir) 'we ird; rm -rf && echo pwned'
    New-Item -ItemType Directory -Path $hostile | Out-Null
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
    $cacheRoot = Join-Path $hostile '.work/codex-cache'
    $addDirIndex = [array]::IndexOf($cap, '--add-dir')
    Assert-True ($addDirIndex -ge 0 -and $cap[$addDirIndex + 1] -eq $cacheRoot) 'read-only: grants only the narrow worktree-local cache exception'
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
# 6a. T-288: success-aware ENV_LIMIT gate - a coincidental network/vcs-write
#     substring in a clean, successful run's out-file+stdout+stderr blob must
#     NOT force ENV_LIMIT; a genuinely failed run with the very same substring
#     still classifies ENV_LIMIT exactly as before.
# =============================================================================
{
    # (a) False positive: RC==0 AND a non-empty, valid -o result - the network
    # substring appears only incidentally (e.g. quoted from the reviewed diff) -
    # must NOT be classified as ENV_LIMIT.
    $fake = New-FakeCodex
    $r = Invoke-Runtime -RuntimeArgs @(
        'run', '--codex-cmd', $fake, '--worktree', (New-TempDir), '--sandbox', 'workspace-write',
        '--reasoning', 'medium', '--out-file', (New-TempFile), '--prompt-file', (New-TempFile)
    ) -EnvVars @{
        FAKE_CODEX_OUT_CONTENT = "Reviewed the retry helper; it already handles 'Failed to connect' and 'Connection refused' gracefully. No changes needed."
        FAKE_CODEX_STDOUT      = 'progress...'
        FAKE_CODEX_EXIT        = '0'
    }
    Assert-True ($null -ne $r.Json) 'success-gate: false-positive case JSON result present'
    if ($r.Json) {
        Assert-Equal 'none' $r.Json.failureClass 'success-gate: RC0 + valid out-file suppresses coincidental network substring'
        Assert-Equal $false $r.Json.envLimit 'success-gate: RC0 + valid out-file is not an env limit'
        Assert-True ($null -eq $r.Json.sentinel) 'success-gate: no sentinel on the suppressed false positive'
    }

    # (b) True positive, non-zero RC: the run actually failed (RC!=0) with the
    # same substring in the out-file/stdout/stderr blob - must classify ENV_LIMIT
    # exactly as before the gate was introduced.
    $fake2 = New-FakeCodex
    $r2 = Invoke-Runtime -RuntimeArgs @(
        'run', '--codex-cmd', $fake2, '--worktree', (New-TempDir), '--sandbox', 'workspace-write',
        '--reasoning', 'medium', '--out-file', (New-TempFile), '--prompt-file', (New-TempFile)
    ) -EnvVars @{
        FAKE_CODEX_OUT_CONTENT = "Reviewed the retry helper; it already handles 'Failed to connect' and 'Connection refused' gracefully. No changes needed."
        FAKE_CODEX_STDERR      = 'error sending request for url: dns error: Could not resolve host'
        FAKE_CODEX_EXIT        = '1'
    }
    Assert-True ($null -ne $r2.Json) 'success-gate: true-positive (nonzero RC) JSON result present'
    if ($r2.Json) {
        Assert-Equal 'network' $r2.Json.failureClass 'success-gate: nonzero RC + network substring still classifies network'
        Assert-Equal $true $r2.Json.envLimit 'success-gate: nonzero RC + network substring is still an env limit'
        Assert-True ($r2.Json.sentinel -like '*ENV_LIMIT/network*') 'success-gate: nonzero RC still escalates ENV_LIMIT/network'
    }

    # (c) True positive, empty/absent -o result: RC==0 but no --out-file is passed
    # (so no valid -o result exists), and the substring surfaces only via stdout -
    # must still classify ENV_LIMIT, since the success gate requires BOTH RC==0
    # AND a valid out-file.
    $fake3 = New-FakeCodex
    $r3 = Invoke-Runtime -RuntimeArgs @(
        'run', '--codex-cmd', $fake3, '--worktree', (New-TempDir), '--sandbox', 'workspace-write',
        '--reasoning', 'medium', '--prompt-file', (New-TempFile)
    ) -EnvVars @{ FAKE_CODEX_STDOUT = 'warning: dns error: Could not resolve host, retrying...'; FAKE_CODEX_EXIT = '0' }
    Assert-True ($null -ne $r3.Json) 'success-gate: true-positive (no out-file) JSON result present'
    if ($r3.Json) {
        Assert-Equal 'network' $r3.Json.failureClass 'success-gate: RC0 without a valid out-file still classifies network'
        Assert-Equal $true $r3.Json.envLimit 'success-gate: RC0 without a valid out-file is still an env limit'
        Assert-True ($r3.Json.sentinel -like '*ENV_LIMIT/network*') 'success-gate: RC0 without a valid out-file still escalates'
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

    $r4 = Invoke-Runtime -RuntimeArgs @('classify', '--rc', '1', '--text', 'windows unelevated restricted-token sandbox cannot enforce split writable root sets directly')
    Assert-Equal 'sandbox-init-worktree' $r4.Json.class 'classify: split writable-root refusal has a worktree-specific class'
    Assert-Equal $true $r4.Json.envLimit 'classify: worktree-specific sandbox-init is an env limit'
}.Invoke()

# =============================================================================
# 7a. Exact worktree preflight: cwd fidelity and split-root routing class
# =============================================================================
{
    $fake = New-FakeCodex
    $wt = New-TempDir
    $cwdCap = New-TempFile
    $r = Invoke-Runtime -ScriptPath $script:Preflight -RuntimeArgs @(
        '--codex-cmd', $fake, '--workspace', $wt, '--timeout-sec', '10'
    ) -EnvVars @{
        FAKE_CODEX_CWD_FILE = $cwdCap
        FAKE_CODEX_STDERR = 'windows unelevated restricted-token sandbox cannot enforce split writable root sets directly'
        FAKE_CODEX_EXIT = '1'
    }
    Assert-Equal 3 $r.ExitCode 'worktree preflight: split-root refusal returns routing exit 3'
    Assert-True ($null -ne $r.Json) 'worktree preflight: emits JSON'
    if ($r.Json) {
        Assert-Equal 'sandbox-init-worktree' $r.Json.class 'worktree preflight: preserves specific failure class'
        Assert-Equal 'downgrade-worktree' $r.Json.decision 'worktree preflight: downgrades only worktree-scoped Codex coder routing'
        Assert-Equal 'worktree' $r.Json.scope 'worktree preflight: records worktree scope'
        Assert-Equal $false $r.Json.hostLimit 'worktree preflight: does not poison reviewer/main-tree routing'
    }
    $cwdSeen = Get-Content -LiteralPath $cwdCap -Raw -Encoding utf8
    Assert-Equal ([IO.Path]::GetFullPath($wt).TrimEnd('\','/')) ([IO.Path]::GetFullPath($cwdSeen).TrimEnd('\','/')) 'worktree preflight: sandbox child cwd is the exact task worktree'

    $argsCap = New-TempFile
    $clean = Invoke-Runtime -ScriptPath $script:Preflight -RuntimeArgs @(
        '--codex-cmd', $fake, '--workspace', $wt, '--timeout-sec', '10'
    ) -EnvVars @{ FAKE_CODEX_EXIT = '0'; FAKE_CODEX_ARGS_FILE = $argsCap }
    Assert-Equal 0 $clean.ExitCode 'worktree preflight: clean exact-root probe keeps routing'
    Assert-Equal 'unchanged' $clean.Json.decision 'worktree preflight: clean probe decision unchanged'
    # T-279: the exact-worktree probe must measure the SAME sandbox shape the real workspace-write
    # call uses. On native Windows that is the single-root collapse (exclude codex's /tmp+$TMPDIR),
    # so the probe carries those keys; on POSIX it does not (the split is enforceable there).
    $pcap = Get-ArgsCaptured $argsCap
    $onWin = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Windows)
    $probeHasExcl = ($pcap -contains 'sandbox_workspace_write.exclude_slash_tmp=true') -and
                    ($pcap -contains 'sandbox_workspace_write.exclude_tmpdir_env_var=true')
    if ($onWin) {
        Assert-True $probeHasExcl 'worktree preflight: Windows probe mirrors the runtime single-root collapse (excludes codex /tmp+$TMPDIR)'
    }
    else {
        Assert-True (-not $probeHasExcl) 'worktree preflight: POSIX probe keeps codex /tmp+$TMPDIR roots'
    }
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
# 10a. T-279 - native-Windows workspace-write collapses codex's default split
#      writable-root set (`[workdir, /tmp, $TMPDIR]`) to the single `[workdir]` root
#      that the unelevated restricted-token sandbox CAN enforce, by excluding codex's
#      own extra /tmp and $TMPDIR roots. This is the root-cause fix for the
#      ENV_LIMIT/sandbox-init-worktree `cannot enforce split writable root sets` refusal.
#      Windows-scoped: on POSIX the split is enforceable and those roots stay writable.
# =============================================================================
{
    $onWin = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Windows)
    $slashTmp = 'sandbox_workspace_write.exclude_slash_tmp=true'
    $tmpEnv = 'sandbox_workspace_write.exclude_tmpdir_env_var=true'

    $ww = Invoke-Runtime -RuntimeArgs @('build-argv', '--worktree', 'x', '--sandbox', 'workspace-write', '--reasoning', 'medium')
    Assert-Equal 0 $ww.ExitCode 'build-argv: workspace-write valid values accepted'
    $wwHasSlash = $ww.Json.argv -contains $slashTmp
    $wwHasTmp = $ww.Json.argv -contains $tmpEnv
    if ($onWin) {
        Assert-True ($wwHasSlash -and $wwHasTmp) 'build-argv: Windows workspace-write collapses the writable-root set to the single workdir root (excludes codex /tmp and $TMPDIR)'
    }
    else {
        Assert-True ((-not $wwHasSlash) -and (-not $wwHasTmp)) 'build-argv: POSIX workspace-write keeps codex /tmp+$TMPDIR roots (no split-root limit there)'
    }
    # The single-root collapse must never widen the sandbox: no --add-dir on workspace-write,
    # and the fail-closed approval policy is still pinned.
    Assert-True (-not ($ww.Json.argv -contains '--add-dir')) 'build-argv: workspace-write stays add-dir-free (single writable root)'
    Assert-True ($ww.Json.argv -contains 'approval_policy=never') 'build-argv: workspace-write still pins fail-closed approval policy'

    # read-only never carries the workspace-write exclusion keys (they are meaningless there
    # and the narrow cache --add-dir exception is unchanged).
    $ro = Invoke-Runtime -RuntimeArgs @('build-argv', '--worktree', 'x', '--sandbox', 'read-only', '--reasoning', 'medium')
    Assert-True (-not ($ro.Json.argv -contains $slashTmp) -and -not ($ro.Json.argv -contains $tmpEnv)) 'build-argv: read-only carries no workspace-write root-exclusion keys'
    Assert-True ($ro.Json.argv -contains '--add-dir') 'build-argv: read-only keeps its narrow cache --add-dir exception'
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
        $before = Invoke-Runtime -RuntimeArgs @('working-copy-status', '--worktree', $repo, '--vcs', 'git')
        Assert-Equal $false $before.Json.clean 'working-copy-status(git): tracked and untracked changes are not clean'
        Assert-True (@($before.Json.changedFiles) -contains 'a.txt') 'working-copy-status(git): tracked change listed'
        Assert-True (@($before.Json.changedFiles) -contains 'junk.txt') 'working-copy-status(git): untracked change listed'
        $r = Invoke-Runtime -RuntimeArgs @('cleanup', '--worktree', $repo, '--vcs', 'git')
        Assert-Equal 'one' ([System.IO.File]::ReadAllText((Join-Path $repo 'a.txt'))) 'cleanup: tracked change reverted'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo 'junk.txt'))) 'cleanup: untracked file removed'
        $after = Invoke-Runtime -RuntimeArgs @('working-copy-status', '--worktree', $repo, '--vcs', 'git')
        Assert-Equal $true $after.Json.clean 'working-copy-status(git): cleanup leaves the active Git worktree clean'
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
# Case (c) (T-255) additionally covers DIVERGENCE - `@`'s change_id mapping to >1
# visible commit - which the fingerprint comparison alone cannot see (a rewrite
# preserves the change_id) and which the standalone `divergent` probe must catch.
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
        & jj git init --colocate $dir 2>&1 | Out-Null
        & jj -R $dir config set --repo user.name 'Test' 2>&1 | Out-Null
        & jj -R $dir config set --repo user.email 'test@example.com' 2>&1 | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'a.txt'), 'one', $script:Utf8)
        return $dir
    }

    # COLOCATED FALSE-CLEAN REGRESSION: after jj snapshots its working-copy revision,
    # Git's status/diff view can report clean while `jj diff` still contains the real
    # uncommitted change relative to @'s parent. The runtime
    # must query the explicitly selected active VCS, not infer Git from the .git dir.
    if (-not $git) {
        Write-Host 'SKIP - git not on PATH; colocated jj false-clean regression skipped.'
    } else {
        {
            # Start from a real Git commit, then create jj's mutable @ revision on
            # top. Mark the Git index entry assume-unchanged to model the observed
            # colocated boundary: the edit is tracked by jj's change_id but is not
            # represented as Git index/worktree dirt for Git's status machinery.
            $repo = New-TempGitRepo
            & jj git init --colocate $repo 2>&1 | Out-Null
            & jj -R $repo config set --repo user.name 'Test' 2>&1 | Out-Null
            & jj -R $repo config set --repo user.email 'test@example.com' 2>&1 | Out-Null
            & jj -R $repo new 2>&1 | Out-Null
            & git -C $repo update-index --assume-unchanged a.txt 2>&1 | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $repo 'a.txt'), 'jj-only working-copy edit', $script:Utf8)

            Assert-True (Test-Path -LiteralPath (Join-Path $repo '.git')) 'working-copy-status(jj colocated): precondition - .git exists'
            Assert-True (Test-Path -LiteralPath (Join-Path $repo '.jj')) 'working-copy-status(jj colocated): precondition - .jj exists'

            # Snapshot the file into jj's stable change_id-tracked @ revision. This is
            # intentionally uncommitted in the Orchestra sense: no `jj commit`/`jj new`.
            & jj -R $repo status 2>&1 | Out-Null
            $changeId = ([string](& jj -R $repo --no-pager log -r '@' --no-graph -T 'change_id' 2>$null)).Trim()
            Assert-True ($changeId -ne '') 'working-copy-status(jj colocated): @ has a stable change_id'

            $gitStatus = @(& git -C $repo status --porcelain 2>$null)
            $gitDiff = @(& git -C $repo diff --name-only 2>$null)
            Assert-Equal 0 $gitStatus.Count 'working-copy-status(jj colocated): precondition - git status falsely appears clean'
            Assert-Equal 0 $gitDiff.Count 'working-copy-status(jj colocated): precondition - git diff falsely appears empty'

            $jjDiff = @(& jj -R $repo --no-pager diff --name-only 2>$null)
            $jjHasFile = @($jjDiff | Where-Object { (Split-Path -Leaf ([string]$_)) -eq 'a.txt' }).Count -gt 0
            Assert-True $jjHasFile 'working-copy-status(jj colocated): precondition - jj diff sees the uncommitted file'

            $r = Invoke-Runtime -RuntimeArgs @('working-copy-status', '--worktree', $repo, '--vcs', 'jj')
            Assert-Equal 0 $r.ExitCode 'working-copy-status(jj colocated): runtime exits successfully'
            Assert-True ($null -ne $r.Json) 'working-copy-status(jj colocated): JSON result present'
            if ($r.Json) {
                Assert-Equal 'jj' $r.Json.vcs 'working-copy-status(jj colocated): selected VCS is preserved'
                Assert-Equal $false $r.Json.clean 'working-copy-status(jj colocated): jj-only change is NOT clean'
                Assert-True (@($r.Json.changedFiles) -contains 'a.txt') 'working-copy-status(jj colocated): changedFiles comes from jj diff'
            }
        }.Invoke()
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
        Assert-Equal $false $r.Json.divergent 'guard-commit(jj): a plain edit leaves `@` non-divergent (divergent=false)'
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
        Assert-Equal $false $r.Json.divergent 'guard-commit(jj): a moved change_id is drift but not divergence (divergent=false)'
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
        Assert-Equal $false $r.Json.divergent 'guard-commit(jj): a moved bookmark is drift but not divergence (divergent=false)'
    }.Invoke()

    # (c) DIVERGENCE DETECTED (T-255): the exact failure the task guards against - `@`'s
    # change_id maps to >1 visible commit ("multiple visible revisions with one change_id").
    # Divergence PRESERVES the change_id (a rewrite keeps the change_id; only the commit_id
    # forks), so the PRE/POST fingerprint is IDENTICAL (committed=false) and the old detector
    # is blind to it. The standalone `divergent` probe must still catch it and escalate as
    # jj-drift - reported, never rewritten and never auto-reconciled (both would rewrite one
    # divergent side = the unattached risk the guard forbids). Reproduced deterministically
    # with two concurrent rewrites of the same change via `jj --at-op <past-op>` (the single-
    # repo way to fork the operation log so both rewrites stay visible after the auto-merge).
    {
        $repo = New-TempJjRepo
        & jj -R $repo describe -m base 2>&1 | Out-Null
        & jj -R $repo new -m target 2>&1 | Out-Null
        # PRE now: `@` is `target`, change_id X, NOT divergent (captured via the same
        # guard-head code path POST uses, so a match proves divergence was caught by the
        # probe, not smuggled in through the fingerprint).
        $pre = (Invoke-Runtime -RuntimeArgs @('guard-head', '--worktree', $repo, '--vcs', 'jj')).Out.Trim()
        $op0 = (@(& jj -R $repo --no-pager op log --no-graph -T 'id.short()' -n1 2>$null))[0]
        $op0 = ([string]$op0).Trim()
        # Fork the op log: rewrite X from HEAD (v1) and again from op0 (v2). After jj's
        # auto-merge of the concurrent ops, both rewrites of X stay visible -> X divergent.
        & jj -R $repo describe -m v1 2>&1 | Out-Null
        & jj -R $repo --at-op $op0 describe -m v2 2>&1 | Out-Null

        # Precondition: `@` really is divergent now (guard the reproducer itself).
        $divCheck = (@(& jj -R $repo --no-pager log -r '@' --no-graph -T 'if(divergent,"1","0")' 2>$null))[0]
        Assert-Equal '1' ([string]$divCheck).Trim() 'guard-commit(jj): precondition - `@` is a divergent change'

        $r = Invoke-Runtime -RuntimeArgs @('guard-commit', '--worktree', $repo, '--vcs', 'jj', '--pre', $pre, '--reset')
        Assert-Equal $true $r.Json.divergent 'guard-commit(jj): a DIVERGENT `@` is detected (divergent=true)'
        Assert-Equal 'jj-drift' $r.Json.action 'guard-commit(jj): divergence -> action=jj-drift (reported, never rewritten/reconciled)'
        Assert-Equal $false $r.Json.committed 'guard-commit(jj): fingerprint is blind to divergence (change_id preserved, pre==post) - the standalone probe is what caught it'
    }.Invoke()
}

# =============================================================================
# 14. jj cleanup targets the requested worktree even when invoked elsewhere
# =============================================================================
{
    $fakeBin = New-TempDir
    $fakeJj = Join-Path $fakeBin 'jj.ps1'
    $argsCap = New-TempFile
    $wt = New-TempDir
    $callerDir = New-TempDir
    $fakeJjBody = @'
if ($env:FAKE_JJ_ARGS_FILE) {
    Set-Content -LiteralPath $env:FAKE_JJ_ARGS_FILE -Value $args -Encoding utf8
}
'@
    [System.IO.File]::WriteAllText($fakeJj, $fakeJjBody, $script:Utf8)

    Assert-True ((Resolve-Path $callerDir).Path -ne (Resolve-Path $wt).Path) 'cleanup(jj): caller directory differs from requested worktree'
    Push-Location $callerDir
    try {
        $r = Invoke-Runtime -RuntimeArgs @('cleanup', '--worktree', $wt, '--vcs', 'jj') -EnvVars @{
            PATH = $fakeBin + [System.IO.Path]::PathSeparator + $env:PATH
            FAKE_JJ_ARGS_FILE = $argsCap
        }
    } finally {
        Pop-Location
    }

    Assert-Equal 0 $r.ExitCode 'cleanup(jj): runtime exits successfully'
    $cap = Get-ArgsCaptured $argsCap
    Assert-Equal 3 $cap.Count 'cleanup(jj): jj receives exactly the repository selector and restore command'
    if ($cap.Count -eq 3) {
        Assert-Equal '-R' $cap[0] 'cleanup(jj): jj argv starts with -R'
        Assert-Equal $wt $cap[1] 'cleanup(jj): -R targets the requested worktree'
        Assert-Equal 'restore' $cap[2] 'cleanup(jj): restore follows the worktree selector'
    }
}.Invoke()

# =============================================================================
# 15. T-222: `run --emit-json` captures the thread id, and `resume-image`
# attaches an image to a follow-up call in that same session - the runtime side
# of the vision-viewing gap researched/documented in T-222 (agents/coder_codex.md,
# knowledge.md). Confirmed against a real codex-cli 0.144.1 that
# `codex exec resume <thread-id> -i <image>` is a real, working flow and that
# `codex exec resume` has NO `--sandbox` flag; these tests exercise the runtime's
# argv-shape and fail-closed validation against the fake codex, not the real CLI.
# =============================================================================
{
    # (a) run --emit-json: parses `thread.started` off stdout, surfaces threadId.
    $fake = New-FakeCodex
    $threadJsonl = '{"type":"thread.started","thread_id":"019f573e-04f2-71e2-8f32-b70d71adc6d8"}' + "`n" +
                   '{"type":"turn.completed"}'
    $r = Invoke-Runtime -RuntimeArgs @(
        'run', '--codex-cmd', $fake, '--worktree', (New-TempDir), '--sandbox', 'workspace-write',
        '--reasoning', 'medium', '--out-file', (New-TempFile), '--prompt-file', (New-TempFile), '--emit-json'
    ) -EnvVars @{ FAKE_CODEX_STDOUT = $threadJsonl; FAKE_CODEX_OUT_CONTENT = 'Done.'; FAKE_CODEX_EXIT = '0' }
    Assert-True ($null -ne $r.Json) 'emit-json: JSON result present'
    if ($r.Json) {
        Assert-Equal '019f573e-04f2-71e2-8f32-b70d71adc6d8' $r.Json.threadId 'emit-json: thread_id extracted from thread.started event'
    }

    # (a') run WITHOUT --emit-json: threadId stays null (backward compatible - no behaviour
    # change for existing callers that never pass the new opt-in flag), and --json is never
    # added to the argv.
    $argsCap2 = New-TempFile
    $r2 = Invoke-Runtime -RuntimeArgs @(
        'run', '--codex-cmd', $fake, '--worktree', (New-TempDir), '--sandbox', 'workspace-write',
        '--reasoning', 'medium', '--out-file', (New-TempFile), '--prompt-file', (New-TempFile)
    ) -EnvVars @{ FAKE_CODEX_ARGS_FILE = $argsCap2; FAKE_CODEX_EXIT = '0' }
    Assert-True ($null -eq $r2.Json.threadId) 'no-emit-json: threadId is null when not requested'
    Assert-True ((Get-ArgsCaptured $argsCap2) -notcontains '--json') 'no-emit-json: argv unchanged, no --json added'

    # (b) resume-image: safe argv shape - `resume <thread-id>`, `-i <image>`, and
    # deliberately NO --sandbox anywhere (codex exec resume has no such flag).
    $wt = New-TempDir
    $imgPath = Join-Path $wt 'shot.png'
    [System.IO.File]::WriteAllText($imgPath, 'fake-png-bytes', $script:Utf8)
    $argsCap3 = New-TempFile
    $stdinCap3 = New-TempFile
    $r3 = Invoke-Runtime -RuntimeArgs @(
        'resume-image', '--codex-cmd', $fake, '--worktree', $wt,
        '--thread-id', '019f573e-04f2-71e2-8f32-b70d71adc6d8', '--image', $imgPath,
        '--out-file', (New-TempFile), '--prompt-file', (New-TempFile)
    ) -EnvVars @{ FAKE_CODEX_ARGS_FILE = $argsCap3; FAKE_CODEX_STDIN_FILE = $stdinCap3; FAKE_CODEX_OUT_CONTENT = 'red'; FAKE_CODEX_EXIT = '0' }
    Assert-True ($null -ne $r3.Json) 'resume-image: JSON result present'
    if ($r3.Json) {
        Assert-Equal $true $r3.Json.ok 'resume-image: ok true on a clean fake run'
        Assert-Equal 'resume-image' $r3.Json.stage 'resume-image: stage is resume-image'
    }
    $cap3 = Get-ArgsCaptured $argsCap3
    Assert-True ($cap3.Count -ge 2 -and $cap3[0] -eq 'exec' -and $cap3[1] -eq 'resume') 'resume-image: codex invoked as `exec resume ...`'
    Assert-True ($cap3 -contains '019f573e-04f2-71e2-8f32-b70d71adc6d8') 'resume-image: argv carries the thread id'
    Assert-True ($cap3 -contains 'approval_policy=never') 'resume-image: still pins the fail-closed approval policy'
    Assert-True ($cap3 -notcontains '--sandbox') 'resume-image: NEVER adds --sandbox (codex exec resume has no such flag)'
    Assert-True ($cap3 -contains '-i' -and $cap3 -contains $imgPath) 'resume-image: argv carries -i <image>'

    # (c) resume-image: an image outside the worktree is refused (exit 2), never attached.
    $outsideImg = New-TempFile
    [System.IO.File]::WriteAllText($outsideImg, 'x', $script:Utf8)
    $r4 = Invoke-Runtime -RuntimeArgs @(
        'resume-image', '--codex-cmd', $fake, '--worktree', $wt,
        '--thread-id', '019f573e-04f2-71e2-8f32-b70d71adc6d8', '--image', $outsideImg,
        '--out-file', (New-TempFile), '--prompt-file', (New-TempFile)
    )
    Assert-Equal 2 $r4.ExitCode 'resume-image: image outside worktree rejected with exit 2'
    Assert-True ($r4.Err -like '*outside*worktree*') 'resume-image: reports the confinement violation'

    # (d) resume-image: a malformed/non-UUID thread id is rejected (never falls back to --last).
    $r5 = Invoke-Runtime -RuntimeArgs @(
        'resume-image', '--codex-cmd', $fake, '--worktree', $wt,
        '--thread-id', 'last', '--image', $imgPath,
        '--out-file', (New-TempFile), '--prompt-file', (New-TempFile)
    )
    Assert-Equal 2 $r5.ExitCode 'resume-image: non-UUID thread id (e.g. the literal "last") rejected with exit 2'
}.Invoke()

# =============================================================================
# 16. T-256: no hung host and no orphaned descendant after a run whose codex
# leaked a helper that INHERITED the runtime's redirected stdout/stderr pipe.
# Reproduces the observed accumulation: such a descendant keeps the runtime host
# blocked forever on its async stream read (unless the tree is killed) and lingers
# as an orphan .NET process. Asserted for (a) a SUCCESSFUL exit, (b) a NON-ZERO
# (substantive-error) exit, and (c) a TIMEOUT (нештатное завершение) - each must
# return PROMPTLY (never wedge the host) AND leave the leaked descendant terminated.
# =============================================================================

# A fake codex that spawns a grandchild inheriting THIS process's std handles (= the
# runtime's captured pipes) and sleeps long, records the grandchild's identity, then
# returns per FAKE_CODEX_EXIT / FAKE_CODEX_SLEEP_MS. Single-quoted here-string: the
# $-tokens are evaluated when the fake itself runs, not at definition time.
$script:FakeCodexTreeBody = @'
$stdin = [Console]::In.ReadToEnd()
$oIdx = [array]::IndexOf($args, '-o')
if ($oIdx -ge 0 -and ($oIdx + 1) -lt $args.Count -and $env:FAKE_CODEX_OUT_CONTENT) {
    [System.IO.File]::WriteAllText($args[$oIdx + 1], $env:FAKE_CODEX_OUT_CONTENT, (New-Object System.Text.UTF8Encoding($false)))
}
if ($env:FAKE_CODEX_STDOUT) { [Console]::Out.Write($env:FAKE_CODEX_STDOUT) }
$gcSleepMs = if ($env:FAKE_CODEX_GC_SLEEP_MS) { [int]$env:FAKE_CODEX_GC_SLEEP_MS } else { 120000 }
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = (Get-Process -Id $PID).Path
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
# Deliberately DO NOT redirect the grandchild: it inherits THIS process's std handles,
# which are the runtime's captured pipes - that inherited, still-open write end is the leak.
foreach ($a in @('-NoProfile', '-NonInteractive', '-Command', "Start-Sleep -Milliseconds $gcSleepMs")) { $psi.ArgumentList.Add($a) }
$gc = [System.Diagnostics.Process]::Start($psi)
if ($env:FAKE_CODEX_GC_PIDFILE) {
    $startTicks = $gc.StartTime.ToUniversalTime().Ticks
    [System.IO.File]::WriteAllText($env:FAKE_CODEX_GC_PIDFILE, "$($gc.Id)|$startTicks", (New-Object System.Text.UTF8Encoding($false)))
}
if ($env:FAKE_CODEX_SLEEP_MS) { Start-Sleep -Milliseconds ([int]$env:FAKE_CODEX_SLEEP_MS) }
$code = 0
if ($env:FAKE_CODEX_EXIT) { $code = [int]$env:FAKE_CODEX_EXIT }
exit $code
'@
function New-FakeCodexTree {
    $p = (New-TempFile) + '.ps1'
    [System.IO.File]::WriteAllText($p, $script:FakeCodexTreeBody, $script:Utf8)
    return $p
}
# PID-reuse-safe liveness (match Id AND creation time, like tests/test-supervisor.ps1 #4).
function Read-GcIdentity {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { return $null }
    $raw = ([System.IO.File]::ReadAllText($File)).Trim()
    $parts = $raw -split '\|', 2
    if ($parts.Count -ne 2) { return $null }
    return [pscustomobject]@{ Id = [int]$parts[0]; StartTimeUtc = [DateTime]::new([long]$parts[1], [DateTimeKind]::Utc) }
}
function Test-GcAlive {
    param($Gc)
    if ($null -eq $Gc) { return $false }
    try {
        $p = Get-Process -Id $Gc.Id -ErrorAction Stop
        return ((-not $p.HasExited) -and ($p.StartTime.ToUniversalTime() -eq $Gc.StartTimeUtc))
    } catch { return $false }
}
function Wait-GcGone {
    param($Gc, [int]$TimeoutSec = 6)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (($sw.Elapsed.TotalSeconds -lt $TimeoutSec) -and (Test-GcAlive $Gc)) { Start-Sleep -Milliseconds 100 }
    return (-not (Test-GcAlive $Gc))
}
function Stop-GcIfAlive {
    param($Gc)
    if (Test-GcAlive $Gc) { try { & taskkill /PID $Gc.Id /T /F 2>$null | Out-Null } catch { } }
}

# (a) SUCCESS: codex exits 0 but leaks a pipe-inheriting grandchild.
{
    $fake = New-FakeCodexTree
    $gcPidFile = New-TempFile
    $gc = $null
    try {
        $r = Invoke-Runtime -RuntimeArgs @(
            'run', '--codex-cmd', $fake, '--worktree', (New-TempDir), '--sandbox', 'workspace-write',
            '--reasoning', 'medium', '--out-file', (New-TempFile), '--prompt-file', (New-TempFile)
        ) -EnvVars @{
            FAKE_CODEX_GC_PIDFILE = $gcPidFile; FAKE_CODEX_GC_SLEEP_MS = '30000'
            FAKE_CODEX_OUT_CONTENT = 'Done.'; FAKE_CODEX_STDOUT = 'progress'; FAKE_CODEX_EXIT = '0'
        } -TimeoutMs 30000
        Assert-True (-not $r.TimedOut) 'leak(success): runtime returns promptly, host not wedged by the inherited pipe'
        Assert-Equal 0 $r.ExitCode 'leak(success): runtime exit code 0'
        Assert-True ($null -ne $r.Json) 'leak(success): emits parseable JSON result'
        if ($r.Json) { Assert-Equal $true $r.Json.ok 'leak(success): result.ok true' }
        $gc = Read-GcIdentity $gcPidFile
        Assert-True ($null -ne $gc) 'leak(success): fake codex recorded the leaked grandchild identity'
        Assert-True (Wait-GcGone $gc) 'leak(success): the leaked grandchild was terminated with the tree'
    } finally {
        Stop-GcIfAlive $gc
    }
}.Invoke()

# (b) NON-ZERO exit (substantive error) with the same leaked grandchild.
{
    $fake = New-FakeCodexTree
    $gcPidFile = New-TempFile
    $gc = $null
    try {
        $r = Invoke-Runtime -RuntimeArgs @(
            'run', '--codex-cmd', $fake, '--worktree', (New-TempDir), '--sandbox', 'workspace-write',
            '--reasoning', 'medium', '--out-file', (New-TempFile), '--prompt-file', (New-TempFile)
        ) -EnvVars @{
            FAKE_CODEX_GC_PIDFILE = $gcPidFile; FAKE_CODEX_GC_SLEEP_MS = '30000'
            FAKE_CODEX_STDERR = 'boom'; FAKE_CODEX_EXIT = '1'
        } -TimeoutMs 30000
        Assert-True (-not $r.TimedOut) 'leak(error): runtime returns promptly despite the leaked pipe holder'
        Assert-True ($null -ne $r.Json) 'leak(error): JSON result present'
        if ($r.Json) {
            Assert-Equal $false $r.Json.ok 'leak(error): result.ok false'
            Assert-Equal 1 $r.Json.exitCode 'leak(error): captured exitCode 1'
        }
        $gc = Read-GcIdentity $gcPidFile
        Assert-True ($null -ne $gc) 'leak(error): fake codex recorded the leaked grandchild identity'
        Assert-True (Wait-GcGone $gc) 'leak(error): the leaked grandchild was terminated with the tree'
    } finally {
        Stop-GcIfAlive $gc
    }
}.Invoke()

# (c) TIMEOUT (нештатное завершение): codex itself hangs past the deadline AND leaked a
# pipe-inheriting grandchild - the whole tree (codex + grandchild) must be killed. This
# also exercises the tree-kill on the timeout branch (a bare $proc.Kill() left the tree, T-234).
{
    $fake = New-FakeCodexTree
    $gcPidFile = New-TempFile
    $gc = $null
    try {
        # --timeout-sec is set comfortably above a (possibly slow-CI) pwsh cold start so the
        # fake reliably spawns AND records its grandchild before the deadline trips; the fake
        # then sleeps well past the deadline so the runtime actually times out on it.
        $r = Invoke-Runtime -RuntimeArgs @(
            'run', '--codex-cmd', $fake, '--worktree', (New-TempDir), '--sandbox', 'workspace-write',
            '--reasoning', 'medium', '--out-file', (New-TempFile), '--prompt-file', (New-TempFile),
            '--timeout-sec', '8'
        ) -EnvVars @{
            FAKE_CODEX_GC_PIDFILE = $gcPidFile; FAKE_CODEX_GC_SLEEP_MS = '30000'
            FAKE_CODEX_SLEEP_MS = '30000'; FAKE_CODEX_EXIT = '0'
        } -TimeoutMs 30000
        Assert-True (-not $r.TimedOut) 'leak(timeout): runtime honors its own --timeout-sec and returns (test watchdog not tripped)'
        Assert-True ($null -ne $r.Json) 'leak(timeout): JSON result present'
        if ($r.Json) {
            Assert-Equal $true $r.Json.timedOut 'leak(timeout): result marks the codex call timed out'
            Assert-True ($null -ne $r.Json.sentinel -and $r.Json.sentinel -like '*CODEX_FAILED*timed out*') 'leak(timeout): CODEX_FAILED timeout sentinel'
        }
        $gc = Read-GcIdentity $gcPidFile
        Assert-True ($null -ne $gc) 'leak(timeout): fake codex recorded the leaked grandchild identity'
        Assert-True (Wait-GcGone $gc) 'leak(timeout): codex AND its leaked grandchild were terminated with the tree'
    } finally {
        Stop-GcIfAlive $gc
    }
}.Invoke()

# =============================================================================
# 16. T-248: per-call token usage capture in `run`.
#   (a) ACTUAL usage parsed from a `codex exec --json` turn.completed usage event.
#   (b) ESTIMATE (chars/4, marked estimated) when the run carried no structured usage.
# =============================================================================
{
    # (a) ACTUAL: the fake emits a JSONL stream whose turn.completed carries a usage object.
    $fake = New-FakeCodex
    $wt = New-TempDir
    $promptFile = New-TempFile
    [System.IO.File]::WriteAllText($promptFile, 'implement the thing', $script:Utf8)
    $jsonl = '{"type":"thread.started","thread_id":"019f573e-04f2-71e2-8f32-b70d71adc6d8"}' + "`n" +
             '{"type":"turn.completed","usage":{"input_tokens":1200,"cached_input_tokens":300,"output_tokens":450}}'
    $r = Invoke-Runtime -RuntimeArgs @(
        'run', '--codex-cmd', $fake, '--worktree', $wt, '--sandbox', 'workspace-write',
        '--reasoning', 'medium', '--out-file', (New-TempFile), '--prompt-file', $promptFile, '--emit-json'
    ) -EnvVars @{ FAKE_CODEX_STDOUT = $jsonl; FAKE_CODEX_EXIT = '0' }
    Assert-True ($null -ne $r.Json -and $null -ne $r.Json.usage) 'usage(actual): result carries a usage block'
    if ($r.Json -and $r.Json.usage) {
        Assert-Equal $false $r.Json.usage.estimated 'usage(actual): structured usage is not estimated'
        Assert-Equal 'codex' $r.Json.usage.source 'usage(actual): source is codex'
        Assert-Equal 1200 $r.Json.usage.input_tokens 'usage(actual): input tokens parsed from turn.completed'
        Assert-Equal 450 $r.Json.usage.output_tokens 'usage(actual): output tokens parsed'
        Assert-Equal 300 $r.Json.usage.cache_read_input_tokens 'usage(actual): cached_input_tokens mapped to cache_read'
        Assert-Equal 1950 $r.Json.usage.total_tokens 'usage(actual): total is the sum of components'
    }

    # (b) ESTIMATE: no --emit-json / no structured usage -> chars/4 estimate, marked estimated.
    $fake2 = New-FakeCodex
    $promptFile2 = New-TempFile
    [System.IO.File]::WriteAllText($promptFile2, 'implement the thing', $script:Utf8)   # 19 chars -> ceil(19/4)=5
    $outFile2 = New-TempFile
    $r2 = Invoke-Runtime -RuntimeArgs @(
        'run', '--codex-cmd', $fake2, '--worktree', (New-TempDir), '--sandbox', 'read-only',
        '--reasoning', 'low', '--out-file', $outFile2, '--prompt-file', $promptFile2
    ) -EnvVars @{ FAKE_CODEX_STDOUT = 'plain free-form progress, not json'; FAKE_CODEX_OUT_CONTENT = 'sixteen char msg'; FAKE_CODEX_EXIT = '0' }
    Assert-True ($null -ne $r2.Json -and $null -ne $r2.Json.usage) 'usage(estimate): result carries a usage block'
    if ($r2.Json -and $r2.Json.usage) {
        Assert-Equal $true $r2.Json.usage.estimated 'usage(estimate): no structured usage is explicitly marked estimated'
        Assert-Equal 5 $r2.Json.usage.input_tokens 'usage(estimate): input estimated chars/4 from the prompt'
        Assert-Equal 4 $r2.Json.usage.output_tokens 'usage(estimate): output estimated chars/4 from the -o message'
        Assert-Equal 9 $r2.Json.usage.total_tokens 'usage(estimate): total is the sum of the estimated components'
    }
}.Invoke()

# =============================================================================
# 17. T-289: jj working-copy view warm-up before a read-only reviewer pass.
# A colocated jj `workspace add` worktree auto-snapshots `@` on nearly every jj
# command; once another process (processor's between-pass commit on the MAIN
# workspace) has advanced the shared operation log, the NEXT jj command in the
# review workspace must reconcile by writing `.jj/working_copy/checkout` under the
# exclusive `working_copy.lock` - a write the fully read-only codex sandbox denies,
# so the SECOND reviewer_codex pass escalated ENV_LIMIT/vcs-write. The runtime now
# refreshes that view OUTSIDE the sandbox (a plain `jj -R <wt> log -r @`) right
# before `codex exec`, so codex's own in-sandbox jj queries find the working copy
# synced and take no lock.
# These assert the warm-up's INVOCATION CONTRACT against a fake `jj` on PATH (args
# recorded to a file) - a real jj binary is intentionally NOT required, because the
# reproduced fault is the presence/shape/gating of the out-of-sandbox jj call, not
# an OS-level lock (the mechanism itself was verified separately on a real jj repo,
# see the code comment in tools/codex-runtime.ps1::Invoke-JjViewWarmup).
# =============================================================================
$script:FakeJjWarmupBody = @'
if ($env:FAKE_JJ_ARGS_FILE) { Set-Content -LiteralPath $env:FAKE_JJ_ARGS_FILE -Value $args -Encoding utf8 }
exit 0
'@
function New-FakeJjBin {
    # A directory holding a `jj.ps1` stub; prepended to the child PATH so the runtime's
    # bare `& jj` resolves it (PowerShell finds a `.ps1` on PATH on both Windows and POSIX,
    # so this needs no real jj and runs on the CI matrix where jj is absent).
    $bin = New-TempDir
    [System.IO.File]::WriteAllText((Join-Path $bin 'jj.ps1'), $script:FakeJjWarmupBody, $script:Utf8)
    return $bin
}

# (a) jj worktree + read-only: the warm-up fires, scoped to THIS worktree, read-only,
#     and WITHOUT widening the sandbox (still exactly the one narrow cache --add-dir).
{
    $fakeBin = New-FakeJjBin
    $fakeCodex = New-FakeCodex
    $wt = New-TempDir
    New-Item -ItemType Directory -Force -Path (Join-Path $wt '.jj') | Out-Null   # colocated jj worktree marker
    $jjArgs = New-TempFile
    $r = Invoke-Runtime -RuntimeArgs @(
        'run', '--codex-cmd', $fakeCodex, '--worktree', $wt, '--sandbox', 'read-only',
        '--reasoning', 'medium', '--out-file', (New-TempFile), '--prompt-file', (New-TempFile)
    ) -EnvVars @{
        PATH = $fakeBin + [System.IO.Path]::PathSeparator + $env:PATH
        FAKE_JJ_ARGS_FILE = $jjArgs; FAKE_CODEX_OUT_CONTENT = 'review verdict'; FAKE_CODEX_EXIT = '0'
    }
    Assert-Equal 0 $r.ExitCode 'warmup(jj,read-only): runtime still exits 0 (codex ran normally after the warm-up)'
    Assert-True (Test-Path -LiteralPath $jjArgs) 'warmup(jj,read-only): a jj view warm-up ran out-of-sandbox before codex'
    $cap = Get-ArgsCaptured $jjArgs
    $rIdx = [array]::IndexOf($cap, '-R')
    Assert-True ($rIdx -ge 0 -and ($rIdx + 1) -lt $cap.Count -and $cap[$rIdx + 1] -eq $wt) 'warmup(jj,read-only): warm-up carries -R <worktree> (K-025 - never the runner cwd workspace)'
    Assert-True (($cap -contains 'log') -and ($cap -contains '-r') -and ($cap -contains '@')) 'warmup(jj,read-only): warm-up is a `log -r @` view refresh'
    foreach ($verb in @('describe', 'new', 'bookmark', 'commit', 'restore', 'abandon')) {
        Assert-True ($cap -notcontains $verb) "warmup(jj,read-only): warm-up is content-read-only (no mutating '$verb')"
    }
    $codexArgv = @($r.Json.codexArgv)
    Assert-True ($codexArgv -contains 'read-only') 'warmup(jj,read-only): codex is still invoked with --sandbox read-only'
    $addDirCount = @($codexArgv | Where-Object { $_ -eq '--add-dir' }).Count
    Assert-Equal 1 $addDirCount 'warmup(jj,read-only): the fix does NOT widen the read-only sandbox (still exactly one narrow --add-dir)'
    $addDirIdx = [array]::IndexOf($codexArgv, '--add-dir')
    Assert-True ($addDirIdx -ge 0 -and ([string]$codexArgv[$addDirIdx + 1]).Replace('\', '/').EndsWith('.work/codex-cache')) 'warmup(jj,read-only): the sole --add-dir is still the worktree-local codex-cache (no .jj exception added)'
}.Invoke()

# (b) git-only worktree (no `.jj/`): CONTRAST - the warm-up must NOT fire, so a git-only
#     review is byte-identical to before (no out-of-sandbox jj call at all).
{
    $fakeBin = New-FakeJjBin
    $fakeCodex = New-FakeCodex
    $wt = New-TempDir   # deliberately NO .jj/ subdir -> git-only worktree
    $jjArgs = New-TempFile
    $r = Invoke-Runtime -RuntimeArgs @(
        'run', '--codex-cmd', $fakeCodex, '--worktree', $wt, '--sandbox', 'read-only',
        '--reasoning', 'medium', '--out-file', (New-TempFile), '--prompt-file', (New-TempFile)
    ) -EnvVars @{
        PATH = $fakeBin + [System.IO.Path]::PathSeparator + $env:PATH
        FAKE_JJ_ARGS_FILE = $jjArgs; FAKE_CODEX_OUT_CONTENT = 'review verdict'; FAKE_CODEX_EXIT = '0'
    }
    Assert-Equal 0 $r.ExitCode 'warmup(git-only): runtime exits 0'
    Assert-True (-not (Test-Path -LiteralPath $jjArgs)) 'warmup(git-only): NO jj warm-up fires without a `.jj/` (git-only behaviour byte-identical)'
    $codexArgv = @($r.Json.codexArgv)
    Assert-True ($codexArgv -contains 'read-only') 'warmup(git-only): codex still invoked --sandbox read-only'
    Assert-True ($codexArgv -contains '--add-dir') 'warmup(git-only): read-only still keeps its narrow cache --add-dir'
}.Invoke()

# (c) jj worktree + workspace-write (coder): the warm-up is gated to the read-only
#     reviewer sandbox, so a coder run does NOT fire it - the coder path is untouched.
{
    $fakeBin = New-FakeJjBin
    $fakeCodex = New-FakeCodex
    $wt = New-TempDir
    New-Item -ItemType Directory -Force -Path (Join-Path $wt '.jj') | Out-Null
    $jjArgs = New-TempFile
    $r = Invoke-Runtime -RuntimeArgs @(
        'run', '--codex-cmd', $fakeCodex, '--worktree', $wt, '--sandbox', 'workspace-write',
        '--reasoning', 'medium', '--out-file', (New-TempFile), '--prompt-file', (New-TempFile)
    ) -EnvVars @{
        PATH = $fakeBin + [System.IO.Path]::PathSeparator + $env:PATH
        FAKE_JJ_ARGS_FILE = $jjArgs; FAKE_CODEX_OUT_CONTENT = 'done'; FAKE_CODEX_EXIT = '0'
    }
    Assert-Equal 0 $r.ExitCode 'warmup(jj,workspace-write): runtime exits 0'
    Assert-True (-not (Test-Path -LiteralPath $jjArgs)) 'warmup(jj,workspace-write): NO warm-up on a coder run (gated to read-only; coder path untouched)'
    $codexArgv = @($r.Json.codexArgv)
    Assert-True ($codexArgv -contains 'workspace-write') 'warmup(jj,workspace-write): codex still invoked --sandbox workspace-write'
    Assert-True ($codexArgv -notcontains '--add-dir') 'warmup(jj,workspace-write): workspace-write stays add-dir-free (single writable root)'
}.Invoke()

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
