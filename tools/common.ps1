<#
.SYNOPSIS
    The shared infrastructure primitives for Orchestra's tools/*.ps1 CLI tools (task T-240).

.DESCRIPTION
    The transaction/observability tools (queue-tx, state-tx, outbox, policy, redaction,
    supervisor, harness, and the codex-runtime quoting fallback) had each grown its OWN
    copy of the same low-level infrastructure: the `<command> [--key value | --flag]`
    argument parser, the `Fail`/`Opt`/`Require-Opt` coded-error helpers with the shared
    `XXXERR|code|msg` throw convention and the top-level catch dispatcher that decodes it,
    the crash-safe `Read-TextOrEmpty` / `Write-TextAtomic` (temp+rename) IO, the
    `Maybe-Fault` crash-injection hook, the `Acquire-Lock`/`Release-Lock` CreateNew file
    lock, the UTC time helpers (`Format-Utc`/`Format-UtcNow`/`Parse-Utc`), and the
    CommandLineToArgvW-correct `ConvertTo-Win32Arg` quoter. Because the copies were
    hand-kept, they had already drifted (different `$BoolFlags` sets, duplicated
    `ConvertTo-Win32Arg` in supervisor and codex-runtime, per-tool `Parse-Utc`/`Format-Utc`
    variants), so a fix to a shared primitive had to be applied N times with a real risk of
    missing a copy.

    This file is the single canonical home for those primitives. It follows the existing
    dot-sourced-library precedent (tools/policy-schema.ps1, tools/proc-tree.ps1): it is a
    pure LIBRARY that only declares default configuration variables and defines functions,
    performing NO top-level action, so a tool loads it with `. (Join-Path $PSScriptRoot
    'common.ps1')` and keeps its own autonomous CLI contract and exit codes.

    Per-tool identity is supplied by three `$script:`-scoped configuration variables the
    sourcing tool sets right after the dot-source (safe defaults below keep an unset tool
    strict-mode-clean):

      $script:ErrPrefix  - the coded-error tag `Fail` throws and the catch dispatcher
                           decodes (e.g. 'QTXERR' for queue-tx).
      $script:FaultEnv   - the environment variable `Maybe-Fault` reads for crash injection
                           (e.g. 'QUEUE_TX_FAULT').
      $script:LockName   - the human label used in the `Acquire-Lock` failure message
                           (e.g. 'queue' -> "could not acquire queue lock at ...").

    `Fail`/`Opt`/`Require-Opt` read the sourcing tool's `$opts` hashtable through the shared
    dot-source scope (dot-sourcing adds these functions to the tool's own script scope, so a
    bare `$opts` / a `$script:ErrPrefix` reference resolves to the tool's variable).

.NOTES
    Runs under PowerShell 7 (pwsh). No top-level side effects, so it is safe to dot-source
    (including transitively, e.g. tools/codex-preflight.ps1 -> tools/codex-runtime.ps1).
    A tool that needs a DIFFERENT behaviour for a specific primitive (e.g. policy.ps1's
    whole-second `Format-Utc`, or supervisor.ps1's UTF8-explicit writers) keeps that variant
    LOCAL, defined AFTER this dot-source so the local definition wins, with a comment stating
    why. codex-runtime.ps1 uses a direct-exit `Fail` (no catch dispatcher), so it defines its
    own `Fail`/`Opt`/`Require-Opt` after this dot-source and takes ONLY `ConvertTo-Win32Arg`
    from here.
#>

# --------------------------------------------------------------------------
# Per-tool configuration defaults. A sourcing tool overrides these right after the
# dot-source; the safe defaults keep any function that reads them strict-mode-clean
# even for a tool that does not use that particular primitive.
# --------------------------------------------------------------------------
$script:ErrPrefix = 'ERR'
$script:FaultEnv  = 'ORCHESTRA_COMMON_FAULT'
$script:LockName  = 'resource'

# --------------------------------------------------------------------------
# Argument parsing:  <command> [--key value | --flag] ...
# A key listed in -BoolFlags is a valueless flag; a key listed in -RepeatKeys collects
# repeated occurrences into a List[string]; any other key takes the next token as its value
# (or '' at end of input). Returns { Command; Opts } - Opts is a hashtable the caller keeps
# as its own $opts.
# --------------------------------------------------------------------------
function Parse-CliArgs {
    param([string[]]$Argv = @(), [string[]]$BoolFlags = @(), [string[]]$RepeatKeys = @())
    $command = if ($Argv.Count -ge 1) { [string]$Argv[0] } else { '' }
    $o = @{}
    for ($i = 1; $i -lt $Argv.Count; $i++) {
        $a = [string]$Argv[$i]
        if ($a -like '--*') {
            $key = $a.Substring(2)
            if ($BoolFlags -contains $key) { $o[$key] = $true; continue }
            $i++
            $val = if ($i -lt $Argv.Count) { [string]$Argv[$i] } else { '' }
            if ($RepeatKeys -contains $key) {
                if (-not $o.ContainsKey($key)) { $o[$key] = [System.Collections.Generic.List[string]]::new() }
                $o[$key].Add($val)
            } else {
                $o[$key] = $val
            }
        }
    }
    return [pscustomobject]@{ Command = $command; Opts = $o }
}

# --------------------------------------------------------------------------
# Fail throws a coded terminating error instead of calling `exit`, so that any
# `finally { Release-Lock }` still runs before the process leaves. The top-level catch
# dispatcher (Resolve-CatchExit) decodes the `<prefix>|code|msg` shape back into an exit
# code. Opt / Require-Opt read the sourcing tool's $opts (shared dot-source scope).
# --------------------------------------------------------------------------
function Fail {
    param([int]$Code, [string]$Message)
    throw ($script:ErrPrefix + '|' + $Code + '|' + $Message)
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

# --------------------------------------------------------------------------
# Top-level catch dispatcher: decode a `<Prefix>|code|msg` coded error into the tool's
# exit code (and message on stderr); an unexpected error becomes exit 1 with the raw
# message, plus a ScriptStackTrace when the tool's *_DEBUG env var is set. Called once
# from each tool's outermost catch as `exit (Resolve-CatchExit $_ <prefix> <label> <dbg>)`.
# --------------------------------------------------------------------------
function Resolve-CatchExit {
    param(
        [Parameter(Mandatory)] $ErrorRecord,
        [Parameter(Mandatory)][string] $Prefix,
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)][string] $DebugEnv
    )
    $m = [string]$ErrorRecord.Exception.Message
    if ($m -like ($Prefix + '|*')) {
        $parts = $m -split '\|', 3
        [Console]::Error.WriteLine("${Label}: $($parts[2])")
        return [int]$parts[1]
    }
    [Console]::Error.WriteLine("${Label}: $m")
    if ([Environment]::GetEnvironmentVariable($DebugEnv)) { [Console]::Error.WriteLine($ErrorRecord.ScriptStackTrace) }
    return 1
}

# --------------------------------------------------------------------------
# Crash-safe IO.
# --------------------------------------------------------------------------
function Read-TextOrEmpty {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) { return [System.IO.File]::ReadAllText($Path) }
    return ''
}
# Crash-injection hook: a stage matching the tool's *_FAULT env var throws, so the
# crash-matrix harness can interrupt a transaction at a named point.
function Maybe-Fault {
    param([string]$Stage)
    $v = [Environment]::GetEnvironmentVariable($script:FaultEnv)
    if ($v -and $v -eq $Stage) { throw "injected fault at stage '$Stage'" }
}
function Write-TextAtomic {
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($false)  # no BOM for .work/*.md/.json
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    # Fixed temp name (not PID-suffixed): queue/state/outbox writes are serialized by their
    # lock and any inbox targets are already unique, so a crashed transaction's leftover temp
    # is simply overwritten by the retry instead of accumulating.
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $Content, $enc)
    Maybe-Fault 'before-rename'
    Move-Item -LiteralPath $tmp -Destination $Path -Force
    Maybe-Fault 'after-rename'
}

# --------------------------------------------------------------------------
# Lock: an exclusive lock FILE created with FileMode.CreateNew, which is the atomic
# "create, failing if it already exists" primitive. (New-Item -ItemType Directory is NOT
# atomic - it is a check-then-create over the idempotent Directory.CreateDirectory, so
# concurrent callers can all "succeed" and enter the critical section together. CreateNew
# fails the losers with an IOException, giving true mutual exclusion.) A crashed holder
# leaves the file behind; a lock older than $StaleMs is treated as abandoned and broken.
# --------------------------------------------------------------------------
function Acquire-Lock {
    param([string]$LockPath, [int]$TimeoutMs = 30000, [int]$StaleMs = 60000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ($true) {
        try {
            $fs = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try { $b = [System.Text.Encoding]::ASCII.GetBytes("$PID"); $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
            return
        } catch {
            if (Test-Path -LiteralPath $LockPath) {
                try {
                    $age = ([DateTime]::UtcNow - (Get-Item -LiteralPath $LockPath).CreationTimeUtc).TotalMilliseconds
                    if ($age -gt $StaleMs) { Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue; continue }
                } catch { }
            }
            if ([DateTime]::UtcNow -gt $deadline) { Fail 7 "could not acquire $($script:LockName) lock at $LockPath (held by another writer)" }
            Start-Sleep -Milliseconds 50
        }
    }
}
function Release-Lock {
    param([string]$LockPath)
    Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------------
# Time helpers (UTC, round-trippable ISO 8601, millisecond precision).
# Format-Utc formats a supplied [datetime]; Format-UtcNow is the nullary "now" convenience.
# Parse-Utc uses DateTimeOffset with AssumeUniversal so a trailing 'Z' / explicit offset is
# honoured and an offset-less string is read as UTC (never as local): DateTime.Parse +
# ToUniversalTime would misread a 'Z' string as local on hosts whose UTC offset is non-zero.
# (policy.ps1 keeps a whole-second Format-Utc variant locally, by design - see its comment.)
# --------------------------------------------------------------------------
function Format-Utc { param([datetime]$D) return $D.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
function Format-UtcNow { return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
function Parse-Utc {
    param([string]$S)
    return [System.DateTimeOffset]::Parse($S, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
}

# --------------------------------------------------------------------------
# CommandLineToArgvW-correct quoting for the Windows PowerShell 5.1 fallback (where
# ProcessStartInfo.ArgumentList is unavailable). Follows the standard MSVC /
# CommandLineToArgvW backslash-and-quote rules so each element round-trips to exactly one
# argument. Shared by tools/supervisor.ps1 and tools/codex-runtime.ps1.
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
