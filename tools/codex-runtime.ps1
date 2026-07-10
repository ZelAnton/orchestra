<#
.SYNOPSIS
    Testable, cross-platform runtime for the Codex adapters (task T-075).

.DESCRIPTION
    The two Codex adapters (agents/coder_codex.md, agents/reviewer_codex.md) drive an
    external `codex exec` binary. Historically every mechanical step of that protocol
    - assembling the argv, sending the prompt, capturing stdout/stderr/RC, guarding
    the diff size, classifying known sandbox failures, forbidding VCS commits, cleaning
    up only the call's own working copy, and mapping a failure to an escalation sentinel
    - lived only as long prose instructions in those two Markdown role files, executed
    non-deterministically by an LLM and never unit-tested. This script pulls that
    mechanical part into one executable runtime the adapters call through a short,
    stable contract, so the same behaviour is exercised deterministically in CI with a
    fake `codex` stub (see tests/test-codex-runtime.ps1). The role files keep only the
    judgement work (choosing context, evaluating substantive results).

    It is a single pwsh script - run the same way on Windows and POSIX, by the model of
    tools/queue-tx.ps1 - dispatched as:

        pwsh -File tools/codex-runtime.ps1 <command> [--key value | --flag] ...

    Commands (each prints a single JSON object to stdout unless noted):

      build-argv        Build the safe `codex exec` argv as an array (never a
                        shell-concatenated string). Validates --sandbox / --reasoning
                        against their allowed sets (fail-closed, exit 2 on an invalid
                        value). This is the single normalized invocation form shared by
                        both adapters (T-057/T-060/T-061), plus the CODEX_NETWORK
                        overrides (T-063) and the pinned fail-closed approval policy
                        `-c approval_policy=never` (T-069).
      run               build-argv + spawn codex with the prompt on stdin, capturing
                        stdout / stderr / RC separately, then classify the outcome. The
                        structured result (argv, exit code, capture-file paths, failure
                        class, sentinel) is written as JSON.
      classify          Classify codex output/RC into a failure class (the ENV_LIMIT
                        table from T-062/T-067, extensible) - envLimit / broker /
                        recoverable flags included.
      check-diff        Oversized-diff guard: count unified-diff lines and report whether
                        they exceed the threshold (default 4000, T-074's DIFF_TOO_LARGE).
      validate-reviewer Validate a reviewer_codex pass output (RECHECK + NEW sections)
                        against the requested R-IDs - the "clean pass" contract (T-074).
      broker-validate   Validate a NEED_NET / dependency-broker command against the
                        canonical allowlist (T-063), rejecting shell metacharacters and
                        non-allowlisted tool/subcommand pairs.
      guard-commit      No-commit guard: compare the worktree HEAD against a pre-run
                        commit id; optionally soft-reset (git) so the processor still
                        commits the leftover working-tree changes. Never --hard, never
                        touches a path outside the given worktree.
      cleanup           Discard the call's own working-copy changes after a failure so a
                        Claude fallback starts clean. In a main-tree call (Phase 5.4)
                        never runs `git clean -fd` (that would delete the untracked
                        .work/); only tracked files are reverted.
      map-sentinel      Map a failure kind/class/detail to the exact escalation sentinel
                        line the processor recognizes (`ЭСКАЛАЦИЯ codex: ...`).

    Exit codes:
      0  success
      2  usage / argument error / invalid config value (fail-closed)
      3  a guard tripped in a way the caller asked to be signalled (e.g. --fail-on-over
         for check-diff, or an unresolvable codex binary for run)

.NOTES
    Runs under PowerShell 7 (pwsh) and Windows PowerShell 5.1. Process spawning uses
    ProcessStartInfo.ArgumentList when available (pwsh) and a CommandLineToArgvW-correct
    quoter otherwise (5.1), so the argv is never assembled by naive string concatenation
    and is immune to shell-metacharacter injection. All files are read/written UTF-8
    without BOM, matching the .work/*.md convention.

.EXAMPLE
    pwsh -File tools/codex-runtime.ps1 build-argv --worktree /abs/wt --sandbox workspace-write --reasoning medium --network on --out-file /abs/.work/tasks/T-1/codex_out.md

.EXAMPLE
    pwsh -File tools/codex-runtime.ps1 run --worktree /abs/wt --sandbox read-only --reasoning medium --out-file out.md --stderr-file err.txt --prompt-file prompt.txt --result-file result.json
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Emit UTF-8 on stdout regardless of the host console code page, so the Cyrillic
# escalation sentinels (`ЭСКАЛАЦИЯ codex: ...`) and any non-ASCII JSON survive
# capture/redirection intact. Guarded: a redirected/closed stdout may reject the
# assignment on some hosts.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

# --------------------------------------------------------------------------
# Argument parsing:  <command> [--key value | --flag] ...
# (same shape as tools/queue-tx.ps1)
# --------------------------------------------------------------------------
$Command = if ($args.Count -ge 1) { [string]$args[0] } else { '' }
$BoolFlags = @('json', 'skip-git', 'fail-on-over', 'reset', 'main-tree')
$opts = @{}
for ($i = 1; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    if ($a -like '--*') {
        $key = $a.Substring(2)
        if ($BoolFlags -contains $key) { $opts[$key] = $true; continue }
        $i++
        if ($i -lt $args.Count) { $opts[$key] = [string]$args[$i] } else { $opts[$key] = '' }
    }
}

function Fail {
    param([int]$Code, [string]$Message)
    [Console]::Error.WriteLine("codex-runtime: $Message")
    exit $Code
}
function Opt {
    param([string]$Name, $Default = $null)
    if ($opts.ContainsKey($Name)) { return $opts[$Name] } else { return $Default }
}
function Require-Opt {
    param([string]$Name)
    if (-not $opts.ContainsKey($Name) -or [string]::IsNullOrEmpty([string]$opts[$Name])) {
        Fail 2 "missing required option --$Name"
    }
    return [string]$opts[$Name]
}
function Read-TextOrEmpty {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) { return [System.IO.File]::ReadAllText($Path) }
    return ''
}
function Write-TextNoBom {
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($false)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}
function Emit-Json {
    param($Object)
    Write-Output ($Object | ConvertTo-Json -Depth 12)
}

# --------------------------------------------------------------------------
# Allowed value sets (fail-closed). Single source of truth for these is the
# "Допустимые значения Codex-ключей" table in config.example.md; this runtime
# re-validates before it can build an argv so an invalid value can never reach
# the actual codex exec call.
# --------------------------------------------------------------------------
$AllowedSandbox = @('read-only', 'workspace-write')
$AllowedReasoning = @('low', 'medium', 'high')
$AllowedNetwork = @('on', 'off')

# The Orchestra-pinned fail-closed approval policy (T-069): every codex exec call
# carries it so a sandbox-init failure returns an error instead of silently running
# the command unsandboxed. Pinned as a literal here - never lowered.
$ApprovalPolicyOverride = 'approval_policy=never'

# --------------------------------------------------------------------------
# Failure classification table (T-062 / T-067), extensible. Order matters:
# the more specific / definitive signatures are checked before the generic
# ones (tls-schannel before network, etc.). `CreateProcessAsUserW failed: 2`
# is deliberately NOT a signature - it is the ambiguous file-not-found case
# (recoverable, an absolute-path retry works), never sandbox-init/tool-missing.
# --------------------------------------------------------------------------
$FailureClasses = @(
    [pscustomobject]@{ Class = 'sandbox-init';   EnvLimit = $true; Broker = $false; Signatures = @('CreateProcessAsUserW failed: 5') }
    [pscustomobject]@{ Class = 'tls-schannel';   EnvLimit = $true; Broker = $true;  Signatures = @('SEC_E_NO_CREDENTIALS', 'schannel: AcquireCredentialsHandle failed') }
    [pscustomobject]@{ Class = 'vcs-write';      EnvLimit = $true; Broker = $false; Signatures = @('index.lock: Permission denied', 'Unable to create') }
    [pscustomobject]@{ Class = 'profile-denied'; EnvLimit = $true; Broker = $false; Signatures = @('.config/git/ignore', '.ssh/config') }
    [pscustomobject]@{ Class = 'tool-missing';   EnvLimit = $true; Broker = $false; Signatures = @('was not found; run without arguments to install from the Microsoft Store', 'App execution alias') }
    [pscustomobject]@{ Class = 'network';        EnvLimit = $true; Broker = $true;  Signatures = @('Failed to connect', 'Could not resolve host', 'error sending request', 'dns error', 'Connection refused', 'Network is unreachable') }
)

function Get-FailureClass {
    param([string]$Text, [int]$RC)
    $t = if ($null -eq $Text) { '' } else { [string]$Text }
    foreach ($fc in $FailureClasses) {
        foreach ($sig in $fc.Signatures) {
            if ($t.IndexOf($sig, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return [pscustomobject]@{
                    class       = $fc.Class
                    envLimit    = $fc.EnvLimit
                    broker      = $fc.Broker
                    recoverable = $false
                    signature   = $sig
                }
            }
        }
    }
    # No env-limit signature. Distinguish a clean run from an ordinary
    # (content-level, retry-eligible) failure by RC.
    if ($RC -ne 0) {
        return [pscustomobject]@{ class = 'ordinary'; envLimit = $false; broker = $false; recoverable = $true; signature = $null }
    }
    return [pscustomobject]@{ class = 'none'; envLimit = $false; broker = $false; recoverable = $false; signature = $null }
}

# --------------------------------------------------------------------------
# Safe argv construction. Returns a [string[]] beginning with the two literal
# tokens `codex`, `exec` (the normalized invocation form, T-057/T-060/T-061),
# assembled purely as array elements - no string concatenation, no
# Invoke-Expression, so a value containing spaces/quotes/`;`/`&&` can only ever
# be one argv element, never break out into the shell.
# --------------------------------------------------------------------------
function Build-CodexArgv {
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$Sandbox,
        [Parameter(Mandatory)][string]$Reasoning,
        [string]$Model = '',
        [string]$Network = 'off',
        [string]$OutFile = '',
        [bool]$SkipGit = $false
    )
    if ($AllowedSandbox -notcontains $Sandbox) {
        Fail 2 "invalid --sandbox '$Sandbox' (allowed: $($AllowedSandbox -join ' | '))"
    }
    if ($AllowedReasoning -notcontains $Reasoning) {
        Fail 2 "invalid --reasoning '$Reasoning' (allowed: $($AllowedReasoning -join ' | '))"
    }
    if ($AllowedNetwork -notcontains $Network) {
        Fail 2 "invalid --network '$Network' (allowed: $($AllowedNetwork -join ' | '))"
    }

    $argv = [System.Collections.Generic.List[string]]::new()
    [void]$argv.Add('codex'); [void]$argv.Add('exec')
    [void]$argv.Add('-C');    [void]$argv.Add($Worktree)
    [void]$argv.Add('--sandbox'); [void]$argv.Add($Sandbox)
    # Fail-closed approval policy (T-069): pinned literal on EVERY call.
    [void]$argv.Add('-c'); [void]$argv.Add($ApprovalPolicyOverride)
    if ($SkipGit) { [void]$argv.Add('--skip-git-repo-check') }
    if ($Model) { [void]$argv.Add('-m'); [void]$argv.Add($Model) }
    if ($Network -eq 'on') {
        # T-063 network overrides: open outbound network in the workspace-write
        # sandbox and route git through the openssl TLS backend. Passed as
        # discrete `-c key=value` argv pairs (no spaces inside the value), so no
        # shell quoting is involved.
        [void]$argv.Add('-c'); [void]$argv.Add('sandbox_workspace_write.network_access=true')
        [void]$argv.Add('-c'); [void]$argv.Add('shell_environment_policy.set={GIT_CONFIG_COUNT="1",GIT_CONFIG_KEY_0="http.sslBackend",GIT_CONFIG_VALUE_0="openssl"}')
    }
    [void]$argv.Add('-c'); [void]$argv.Add("model_reasoning_effort=$Reasoning")
    if ($OutFile) { [void]$argv.Add('-o'); [void]$argv.Add($OutFile) }
    # The prompt is delivered on stdin; `-` marks stdin as the prompt source.
    [void]$argv.Add('-')
    return , $argv.ToArray()
}

# --------------------------------------------------------------------------
# CommandLineToArgvW-correct quoting for the Windows PowerShell 5.1 fallback
# (ProcessStartInfo.ArgumentList is not available there). Follows the standard
# MSVC / CommandLineToArgvW backslash-and-quote rules so each element round-trips
# to exactly one argument.
# --------------------------------------------------------------------------
function ConvertTo-Win32Arg {
    param([string]$Arg)
    if ($Arg.Length -gt 0 -and $Arg -notmatch '[ \t\n\v"]') { return $Arg }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    for ($i = 0; $i -lt $Arg.Length; $i++) {
        $backslashes = 0
        while ($i -lt $Arg.Length -and $Arg[$i] -eq '\') { $backslashes++; $i++ }
        if ($i -eq $Arg.Length) {
            # Trailing backslashes: double them so they do not escape the closing quote.
            [void]$sb.Append('\' * ($backslashes * 2))
            break
        } elseif ($Arg[$i] -eq '"') {
            [void]$sb.Append('\' * ($backslashes * 2 + 1))
            [void]$sb.Append('"')
        } else {
            [void]$sb.Append('\' * $backslashes)
            [void]$sb.Append($Arg[$i])
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}
function ConvertTo-Win32CommandLine {
    param([string[]]$Argv)
    return (($Argv | ForEach-Object { ConvertTo-Win32Arg $_ }) -join ' ')
}

# --------------------------------------------------------------------------
# Resolve the codex command target into a directly-spawnable executable plus any
# interpreter prefix args. A real codex on Windows/POSIX is a native binary (or
# extensionless), spawned directly. A `.ps1` wrapper is run through the current
# PowerShell host; a `.cmd`/`.bat` shim through the command processor. This lets
# the runtime drive both a real codex and a PATH-stubbed fake without a shell.
# --------------------------------------------------------------------------
function Resolve-CodexTarget {
    param([Parameter(Mandatory)][string]$CodexCmd)
    $cmd = Get-Command $CodexCmd -ErrorAction SilentlyContinue
    if (-not $cmd) {
        # Maybe an explicit path that Get-Command did not resolve as a command.
        if (Test-Path -LiteralPath $CodexCmd) {
            $source = (Resolve-Path -LiteralPath $CodexCmd).Path
        } else {
            return $null
        }
    } else {
        $source = if ($cmd.Source) { $cmd.Source } else { $cmd.Name }
    }
    $ext = [System.IO.Path]::GetExtension($source).ToLowerInvariant()
    switch ($ext) {
        '.ps1' {
            $psHost = (Get-Command pwsh -ErrorAction SilentlyContinue)
            if (-not $psHost) { $psHost = Get-Command powershell -ErrorAction SilentlyContinue }
            if (-not $psHost) { return $null }
            return [pscustomobject]@{ File = $psHost.Source; Prefix = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $source) }
        }
        { $_ -eq '.cmd' -or $_ -eq '.bat' } {
            $comspec = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
            return [pscustomobject]@{ File = $comspec; Prefix = @('/d', '/s', '/c', $source) }
        }
        default {
            return [pscustomobject]@{ File = $source; Prefix = @() }
        }
    }
}

# --------------------------------------------------------------------------
# Spawn a process, write $StdinText to its stdin, and capture stdout / stderr /
# exit code separately, with an optional timeout. Uses async stream reads so a
# large stdout/stderr cannot deadlock against the stdin write.
# --------------------------------------------------------------------------
function Invoke-Captured {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$StdinText = '',
        [int]$TimeoutSec = 0
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    # UTF-8 on every captured stream where the host exposes the property (.NET
    # Core / pwsh); Windows PowerShell 5.1 lacks the *Encoding setters and falls
    # back to the console default.
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    foreach ($prop in @('StandardOutputEncoding', 'StandardErrorEncoding', 'StandardInputEncoding')) {
        if ($psi | Get-Member -Name $prop -MemberType Property -ErrorAction SilentlyContinue) {
            try { $psi.$prop = $utf8 } catch { }
        }
    }

    $hasArgList = [bool]($psi | Get-Member -Name 'ArgumentList' -MemberType Property -ErrorAction SilentlyContinue)
    if ($hasArgList) {
        foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    } else {
        $psi.Arguments = ConvertTo-Win32CommandLine $Arguments
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()

    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    try {
        $proc.StandardInput.Write($StdinText)
        $proc.StandardInput.Close()
    } catch {
        # Process may have exited before consuming stdin - not fatal.
    }

    $timedOut = $false
    if ($TimeoutSec -gt 0) {
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            $timedOut = $true
            try { $proc.Kill() } catch { }
            try { $proc.WaitForExit(5000) | Out-Null } catch { }
        }
    } else {
        $proc.WaitForExit()
    }

    $stdout = ''
    $stderr = ''
    try { $stdout = $outTask.GetAwaiter().GetResult() } catch { }
    try { $stderr = $errTask.GetAwaiter().GetResult() } catch { }
    $rc = if ($timedOut) { 124 } else { $proc.ExitCode }
    $proc.Dispose()

    return [pscustomobject]@{ StdOut = $stdout; StdErr = $stderr; ExitCode = $rc; TimedOut = $timedOut }
}

# --------------------------------------------------------------------------
# Reviewer "clean pass" validation (T-074). Mirrors the reference algorithm in
# tests/test-reviewer-codex-gate.ps1: a pass is clean iff RC=0 AND the RECHECK
# section answers exactly the requested R-IDs AND the NEW section is a
# non-contradictory list-or-none.
# --------------------------------------------------------------------------
function Test-RecheckSectionValid {
    param([string[]]$Lines, [string[]]$RequestedIds)
    if ($RequestedIds.Count -eq 0) { return $true }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($line in $Lines) {
        if ($line -match '^RECHECK\s+(\S+):\s+(resolved|reopen\s+—\s+.+)$') {
            $id = $Matches[1]
            if ($RequestedIds -notcontains $id) { return $false }
            if (-not $seen.Add($id)) { return $false }
        } elseif ($line -match '^RECHECK\b') {
            return $false
        }
    }
    foreach ($id in $RequestedIds) { if (-not $seen.Contains($id)) { return $false } }
    return $true
}
function Test-NewSectionValid {
    param([string[]]$Lines)
    $hasNone = $false; $hasItem = $false
    foreach ($line in $Lines) {
        if ($line -eq 'NEW: none') { $hasNone = $true }
        elseif ($line -match '^NEW\s*\|') {
            $parts = $line -split '\|'
            $nonEmptyTail = @($parts[1..($parts.Count - 1)] | Where-Object { $_.Trim() -ne '' })
            if ($parts.Count -eq 5 -and $nonEmptyTail.Count -eq 4) { $hasItem = $true }
            else { return $false }
        }
    }
    if ($hasNone -and $hasItem) { return $false }
    if (-not $hasNone -and -not $hasItem) { return $false }
    return $true
}

# --------------------------------------------------------------------------
# Dependency-broker allowlist (T-063). Canonical, extensible table of the ONLY
# network commands the coder_codex broker may run. A NEED_NET request is
# validated against it: reject shell metacharacters, then require the
# tool+subcommand pair to be allowlisted and the remaining args to be canonical.
# --------------------------------------------------------------------------
$BrokerAllowlist = @(
    [pscustomobject]@{ Tool = 'cargo'; Sub = 'update';  ArgPattern = '^(-p\s+\S+)?$' }
    [pscustomobject]@{ Tool = 'cargo'; Sub = 'fetch';   ArgPattern = '^$' }
    [pscustomobject]@{ Tool = 'npm';   Sub = 'install'; ArgPattern = '^$' }
    [pscustomobject]@{ Tool = 'npm';   Sub = 'ci';      ArgPattern = '^$' }
    [pscustomobject]@{ Tool = 'pip';   Sub = 'install'; ArgPattern = '^-r\s+\S+$' }
    [pscustomobject]@{ Tool = 'pip';   Sub = 'download';ArgPattern = '^\S.*$' }
    [pscustomobject]@{ Tool = 'uv';    Sub = 'lock';    ArgPattern = '^$' }
    [pscustomobject]@{ Tool = 'uv';    Sub = 'sync';    ArgPattern = '^$' }
)
function Test-BrokerCommand {
    param([string]$CommandText)
    $c = ($CommandText -replace '^\s+', '') -replace '\s+$', ''
    # Reject any shell metacharacter outright.
    if ($c -match '[;&|`<>]' -or $c -match '\$\(' -or $c -match "[\r\n]") {
        return [pscustomobject]@{ allowed = $false; canonical = $null; reason = 'shell metacharacter in command' }
    }
    $tokens = @($c -split '\s+' | Where-Object { $_ -ne '' })
    if ($tokens.Count -lt 2) {
        return [pscustomobject]@{ allowed = $false; canonical = $null; reason = 'not a <tool> <subcommand> command' }
    }
    $tool = $tokens[0]; $sub = $tokens[1]
    $rest = if ($tokens.Count -gt 2) { ($tokens[2..($tokens.Count - 1)] -join ' ') } else { '' }
    foreach ($entry in $BrokerAllowlist) {
        if ($entry.Tool -eq $tool -and $entry.Sub -eq $sub) {
            if ($rest -match $entry.ArgPattern) {
                return [pscustomobject]@{ allowed = $true; canonical = ($c -replace '\s+', ' '); reason = $null }
            }
            return [pscustomobject]@{ allowed = $false; canonical = $null; reason = "non-canonical args for '$tool $sub': '$rest'" }
        }
    }
    return [pscustomobject]@{ allowed = $false; canonical = $null; reason = "'$tool $sub' is not in the broker allowlist" }
}

# --------------------------------------------------------------------------
# Escalation sentinel mapping. The processor recognizes the escalation by the
# fixed prefix `ЭСКАЛАЦИЯ codex: CODEX_UNAVAILABLE|CODEX_FAILED`; an env-limit
# class only refines the CODEX_FAILED detail as `ENV_LIMIT/<class>: <detail>`.
# --------------------------------------------------------------------------
function Get-Sentinel {
    param([string]$Kind, [string]$Class = '', [string]$Detail = '')
    $prefix = 'ЭСКАЛАЦИЯ codex:'
    switch ($Kind) {
        'unavailable' {
            $s = "$prefix CODEX_UNAVAILABLE"
            if ($Detail) { $s += " — $Detail" }
            return $s
        }
        'failed' {
            if ($Class -and $Class -ne 'none' -and $Class -ne 'ordinary') {
                $body = "ENV_LIMIT/$Class"
                if ($Detail) { $body += ": $Detail" }
                return "$prefix CODEX_FAILED — $body"
            }
            $s = "$prefix CODEX_FAILED"
            if ($Detail) { $s += " — $Detail" }
            return $s
        }
        default { Fail 2 "invalid --kind '$Kind' (allowed: unavailable | failed)" }
    }
}

# --------------------------------------------------------------------------
# VCS helpers (read-only unless --reset, and even then only soft, only in the
# given worktree).
# --------------------------------------------------------------------------
function Get-Head {
    param([string]$Worktree, [string]$Vcs)
    try {
        if ($Vcs -eq 'jj') {
            $r = & jj --no-pager log -r '@' --no-graph -T 'commit_id' 2>$null
            return ([string]$r).Trim()
        }
        $r = & git -C $Worktree rev-parse HEAD 2>$null
        return ([string]$r).Trim()
    } catch { return '' }
}

# ==========================================================================
# Commands
# ==========================================================================

function Cmd-BuildArgv {
    $argv = Build-CodexArgv `
        -Worktree (Require-Opt 'worktree') `
        -Sandbox (Require-Opt 'sandbox') `
        -Reasoning (Require-Opt 'reasoning') `
        -Model ([string](Opt 'model' '')) `
        -Network ([string](Opt 'network' 'off')) `
        -OutFile ([string](Opt 'out-file' '')) `
        -SkipGit ([bool](Opt 'skip-git' $false))
    Emit-Json ([pscustomobject]@{ argv = $argv; approvalPolicy = $ApprovalPolicyOverride })
}

function Cmd-Classify {
    $rc = [int]([string](Opt 'rc' '0'))
    $text = ''
    if ($opts.ContainsKey('text')) { $text = [string]$opts['text'] }
    else {
        $text = (Read-TextOrEmpty ([string](Opt 'out-file' ''))) + "`n" + (Read-TextOrEmpty ([string](Opt 'stderr-file' '')))
        if ([string]::IsNullOrWhiteSpace($text) -and -not $opts.ContainsKey('out-file') -and -not $opts.ContainsKey('stderr-file')) {
            $text = [Console]::In.ReadToEnd()
        }
    }
    Emit-Json (Get-FailureClass -Text $text -RC $rc)
}

function Cmd-CheckDiff {
    $max = [int]([string](Opt 'max-lines' '4000'))
    $text = ''
    if ($opts.ContainsKey('diff-file')) { $text = Read-TextOrEmpty ([string]$opts['diff-file']) }
    else { $text = [Console]::In.ReadToEnd() }
    $normalized = ($text -replace "`r`n", "`n") -replace "`r", "`n"
    $trimmed = $normalized.TrimEnd("`n")
    $lines = if ($trimmed.Length -eq 0) { 0 } else { ($trimmed -split "`n").Count }
    $over = $lines -gt $max
    Emit-Json ([pscustomobject]@{ lines = $lines; threshold = $max; overLimit = $over })
    if ($over -and [bool](Opt 'fail-on-over' $false)) { exit 3 }
}

function Cmd-ValidateReviewer {
    $rc = [int]([string](Opt 'rc' '0'))
    $requested = @()
    $rawIds = [string](Opt 'requested-ids' '')
    if ($rawIds) { $requested = @($rawIds -split '[,\s]+' | Where-Object { $_ -ne '' }) }
    $text = ''
    if ($opts.ContainsKey('out-file')) { $text = Read-TextOrEmpty ([string]$opts['out-file']) }
    else { $text = [Console]::In.ReadToEnd() }
    $lines = @((($text -replace "`r`n", "`n") -replace "`r", "`n") -split "`n" | ForEach-Object { $_.Trim() })
    $recheckValid = Test-RecheckSectionValid -Lines $lines -RequestedIds $requested
    $newValid = Test-NewSectionValid -Lines $lines
    $clean = ($rc -eq 0) -and $recheckValid -and $newValid
    $reason = $null
    if (-not $clean) {
        if ($rc -ne 0) { $reason = "rc=$rc" }
        elseif (-not $recheckValid) { $reason = 'RECHECK section invalid/incomplete' }
        elseif (-not $newValid) { $reason = 'NEW section invalid/contradictory' }
    }
    Emit-Json ([pscustomobject]@{ clean = $clean; recheckValid = $recheckValid; newValid = $newValid; reason = $reason })
}

function Cmd-BrokerValidate {
    $cmdText = Require-Opt 'command'
    Emit-Json (Test-BrokerCommand -CommandText $cmdText)
}

function Cmd-MapSentinel {
    Write-Output (Get-Sentinel -Kind (Require-Opt 'kind') -Class ([string](Opt 'class' '')) -Detail ([string](Opt 'detail' '')))
}

function Cmd-GuardCommit {
    $wt = Require-Opt 'worktree'
    $vcs = [string](Opt 'vcs' 'git')
    $pre = [string](Opt 'pre' '')
    $post = Get-Head -Worktree $wt -Vcs $vcs
    $committed = ($pre -ne '') -and ($post -ne '') -and ($pre -ne $post)
    $action = 'none'
    if ($committed -and [bool](Opt 'reset' $false)) {
        if ($vcs -eq 'jj') {
            # A moved jj commit_id must not be rewritten (unattached risk) - just report.
            $action = 'jj-drift'
        } else {
            & git -C $wt reset --soft $pre 2>$null | Out-Null
            $action = 'soft-reset'
        }
    }
    Emit-Json ([pscustomobject]@{ pre = $pre; post = $post; committed = $committed; action = $action })
}

function Cmd-Cleanup {
    $wt = Require-Opt 'worktree'
    $vcs = [string](Opt 'vcs' 'git')
    $mainTree = [bool](Opt 'main-tree' $false)
    $actions = New-Object System.Collections.Generic.List[string]
    if ($vcs -eq 'jj') {
        & jj restore 2>$null | Out-Null
        [void]$actions.Add('jj-restore')
    } else {
        & git -C $wt checkout -- . 2>$null | Out-Null
        [void]$actions.Add('git-checkout')
        if ($mainTree) {
            # Phase 5.4 main tree: NEVER `git clean -fd` (it would wipe the
            # untracked, gitignored .work/). Remove only codex-created untracked
            # files, by name, and never anything under .work/.
            $porcelain = @(& git -C $wt status --porcelain 2>$null)
            foreach ($line in $porcelain) {
                if ($line -match '^\?\?\s+(.+)$') {
                    $rel = $Matches[1].Trim('"')
                    if ($rel -match '(^|[\\/])\.work([\\/]|$)') { continue }
                    $full = Join-Path $wt $rel
                    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue }
                }
            }
            [void]$actions.Add('remove-untracked-except-work')
        } else {
            & git -C $wt clean -fd 2>$null | Out-Null
            [void]$actions.Add('git-clean')
        }
    }
    Emit-Json ([pscustomobject]@{ worktree = $wt; vcs = $vcs; mainTree = $mainTree; actions = @($actions.ToArray()) })
}

function Cmd-Run {
    $codexCmd = [string](Opt 'codex-cmd' 'codex')
    $target = Resolve-CodexTarget -CodexCmd $codexCmd
    if ($null -eq $target) {
        Emit-Json ([pscustomobject]@{
                ok       = $false
                stage    = 'resolve'
                sentinel = (Get-Sentinel -Kind 'unavailable' -Detail "codex command not found: $codexCmd")
            })
        exit 3
    }
    $argv = Build-CodexArgv `
        -Worktree (Require-Opt 'worktree') `
        -Sandbox (Require-Opt 'sandbox') `
        -Reasoning (Require-Opt 'reasoning') `
        -Model ([string](Opt 'model' '')) `
        -Network ([string](Opt 'network' 'off')) `
        -OutFile ([string](Opt 'out-file' '')) `
        -SkipGit ([bool](Opt 'skip-git' $false))

    $prompt = ''
    if ($opts.ContainsKey('prompt-file')) { $prompt = Read-TextOrEmpty ([string]$opts['prompt-file']) }
    else { $prompt = [Console]::In.ReadToEnd() }

    $timeout = [int]([string](Opt 'timeout-sec' '0'))
    # argv[0] is the literal `codex`; the rest are the exec arguments. We spawn
    # the resolved target (real binary, or interpreter+script for a wrapper) and
    # append everything after argv[0] as the process arguments.
    $spawnArgs = @($target.Prefix) + @($argv[1..($argv.Count - 1)])
    $res = Invoke-Captured -FilePath $target.File -Arguments $spawnArgs -StdinText $prompt -TimeoutSec $timeout

    $stdoutFile = [string](Opt 'stdout-file' '')
    $stderrFile = [string](Opt 'stderr-file' '')
    if ($stdoutFile) { Write-TextNoBom $stdoutFile $res.StdOut }
    if ($stderrFile) { Write-TextNoBom $stderrFile $res.StdErr }

    # Classify against the -o out-file (codex's final message) plus captured
    # stdout/stderr - the same surface the adapter used to eyeball.
    $classifyText = (Read-TextOrEmpty ([string](Opt 'out-file' ''))) + "`n" + $res.StdOut + "`n" + $res.StdErr
    $fc = Get-FailureClass -Text $classifyText -RC $res.ExitCode

    $sentinel = $null
    if ($res.TimedOut) {
        $sentinel = Get-Sentinel -Kind 'failed' -Detail "codex exec timed out after ${timeout}s"
    } elseif ($fc.envLimit) {
        $sentinel = Get-Sentinel -Kind 'failed' -Class $fc.class -Detail 'environment limit'
    }

    $result = [pscustomobject]@{
        ok           = ($res.ExitCode -eq 0 -and -not $res.TimedOut)
        stage        = 'run'
        codexArgv    = $argv
        exitCode     = $res.ExitCode
        timedOut     = $res.TimedOut
        stdoutFile   = $stdoutFile
        stderrFile   = $stderrFile
        outFile      = [string](Opt 'out-file' '')
        failureClass = $fc.class
        envLimit     = $fc.envLimit
        broker       = $fc.broker
        sentinel     = $sentinel
    }
    $resultFile = [string](Opt 'result-file' '')
    if ($resultFile) { Write-TextNoBom $resultFile ($result | ConvertTo-Json -Depth 12) }
    Emit-Json $result
}

# ==========================================================================
# Dispatch
# ==========================================================================
switch ($Command) {
    'build-argv'        { Cmd-BuildArgv }
    'run'               { Cmd-Run }
    'classify'          { Cmd-Classify }
    'check-diff'        { Cmd-CheckDiff }
    'validate-reviewer' { Cmd-ValidateReviewer }
    'broker-validate'   { Cmd-BrokerValidate }
    'guard-commit'      { Cmd-GuardCommit }
    'cleanup'           { Cmd-Cleanup }
    'map-sentinel'      { Cmd-MapSentinel }
    default {
        Fail 2 "unknown command '$Command'. Valid: build-argv, run, classify, check-diff, validate-reviewer, broker-validate, guard-commit, cleanup, map-sentinel"
    }
}
