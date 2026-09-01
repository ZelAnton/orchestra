<#
.SYNOPSIS
    The shared infrastructure primitives for Orchestra's tools/*.ps1 CLI tools (task T-240).

.DESCRIPTION
    The transaction/observability tools (queue-tx, state-tx, outbox, policy, redaction,
    supervisor, harness, and the codex-runtime quoting fallback) had each grown its OWN
    copy of the same low-level infrastructure: the `<command> [--key value | --flag]`
    argument parser, the `Fail`/`Opt`/`Require-Opt` coded-error helpers with the shared
    `XXXERR|code|msg` throw convention and the top-level catch dispatcher that decodes it,
    the shared `.work/config.md` `KEY: value` line parser, the crash-safe
    `Read-TextOrEmpty` / `Write-TextAtomic` (temp+rename) IO, the
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

# Shared installed state lives outside the Claude/Codex provider homes. ORCHESTRA_HOME is
# a path/layout override for portable installations and tests, not a configuration source.
# User settings are read only from root-config.md and the consuming project's config.md.
function Get-OrchestraHome {
    $configured = [Environment]::GetEnvironmentVariable('ORCHESTRA_HOME')
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        return [System.IO.Path]::GetFullPath($configured.Trim())
    }
    $profile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($profile)) { $profile = [string]$HOME }
    if ([string]::IsNullOrWhiteSpace($profile)) { throw 'cannot determine the user profile for Orchestra home' }
    return [System.IO.Path]::GetFullPath((Join-Path $profile '.orchestra'))
}

function Get-OrchestraRootConfigPath {
    param([string]$OrchestraHome = '')
    $orchestraHomePath = if ([string]::IsNullOrWhiteSpace($OrchestraHome)) { Get-OrchestraHome } else { [System.IO.Path]::GetFullPath($OrchestraHome.Trim()) }
    return (Join-Path $orchestraHomePath 'root-config.md')
}

function Resolve-OrchestraSharedScript {
    param([Parameter(Mandatory)][string]$Name)
    $local = Join-Path $PSScriptRoot $Name
    if (Test-Path -LiteralPath $local -PathType Leaf) { return $local }
    $shared = Join-Path (Join-Path (Get-OrchestraHome) 'scripts') $Name
    if (Test-Path -LiteralPath $shared -PathType Leaf) { return $shared }
    throw "shared Orchestra script not found: $Name"
}

# Resolve a reusable PowerShell console executable for child processes. On framework-
# dependent installs such as `dotnet tool install --global PowerShell`, the current
# process executable is `dotnet`, not `pwsh`; reusing MainModule.FileName would therefore
# launch `dotnet -NoProfile ...` and fail before the child script starts. Prefer the
# console apphost shipped in PSHOME, then the matching PATH application. The native
# current process is only a safe fallback when it is already an actual PowerShell host.
function Get-PowerShellHostExecutable {
    $onWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Windows)
    $coreEdition = [string]$PSVersionTable.PSEdition -eq 'Core'
    $names = if ($coreEdition) {
        if ($onWindows) { @('pwsh.exe', 'pwsh') } else { @('pwsh') }
    } else {
        @('powershell.exe')
    }

    foreach ($name in $names) {
        $candidate = Join-Path $PSHOME $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }
    foreach ($name in $names) {
        $command = @(Get-Command $name -CommandType Application -ErrorAction SilentlyContinue) |
            Select-Object -First 1
        if ($command -and $command.Source) { return [string]$command.Source }
    }

    $processPath = ''
    try { $processPath = [string][Environment]::ProcessPath } catch { }
    if ([string]::IsNullOrWhiteSpace($processPath)) {
        $processPath = [string]([System.Diagnostics.Process]::GetCurrentProcess()).MainModule.FileName
    }
    $processName = [System.IO.Path]::GetFileName($processPath)
    if (@($names | Where-Object {
            [string]::Equals($_, $processName, [System.StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0) {
        return $processPath
    }
    throw "cannot resolve a reusable PowerShell host executable (current process: $processName)"
}

# --------------------------------------------------------------------------
# .work/config.md line parsing.
#
# A Markdown inline comment begins at a `#` that starts the value or is preceded by
# whitespace. A hash inside a token is data (`make check#fast`). A value whose first
# non-whitespace character is `[` is kept whole because VERIFICATION_COMMANDS is a JSON
# array and its string elements may contain whitespace followed by `#`; inline comments
# are deliberately unsupported for that JSON form.
#
# Returns $null for anything other than an active `KEY: value` line. Callers retain their
# own first/last-match and domain-validation policies while sharing the exact extraction
# semantics.
# --------------------------------------------------------------------------
function ConvertFrom-OrchestraConfigLine {
    param([AllowEmptyString()][string]$Line)
    if ($null -eq $Line) { return $null }

    $match = [regex]::Match($Line, '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$')
    if (-not $match.Success) { return $null }

    $rest = $match.Groups[2].Value
    $comment = ''
    if (-not $rest.TrimStart().StartsWith('[')) {
        $commentMatch = [regex]::Match($rest, '(?<!\S)#')
        if ($commentMatch.Success) {
            $comment = $rest.Substring($commentMatch.Index)
            $rest = $rest.Substring(0, $commentMatch.Index)
        }
    }

    return [pscustomobject]@{
        Key     = $match.Groups[1].Value
        Value   = $rest.Trim()
        Comment = $comment
    }
}

# Root-only settings are machine/provider policy and must not be supplied by a project.
# Every other key follows the project-local override -> root-config -> schema default order.
$script:OrchestraRootOnlyKeys = @(
    'ORCHESTRA_PROVIDER', 'ORCHESTRA_CLAUDE_PERMISSION_MODE', 'ORCHESTRA_AUTO_APPROVE',
    'ORCHESTRA_CODEX_MODEL', 'ORCHESTRA_CODEX_REASONING', 'ORCHESTRA_CODEX_SANDBOX',
    'ORCHESTRA_CODEX_MAX_THREADS', 'CODEX_HOME', 'CC_PROCESSKIT_CLI',
    'CC_PROCESSKIT_PYTHON', 'ORCHESTRA_REGISTRY_PATH', 'BASH_DEFAULT_TIMEOUT_MS',
    'BASH_MAX_TIMEOUT_MS'
)

function Get-OrchestraConfigValueFromFile {
    param([string]$Path, [Parameter(Mandatory)][string]$Key)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $entry = ConvertFrom-OrchestraConfigLine -Line ([string]$line)
        if ($null -ne $entry -and [string]::Equals($entry.Key, $Key, [System.StringComparison]::OrdinalIgnoreCase) -and -not [string]::IsNullOrWhiteSpace($entry.Value)) {
            return [string]$entry.Value
        }
    }
    return ''
}

function Get-OrchestraConfigValue {
    param(
        [string]$Work = '',
        [Parameter(Mandatory)][string]$Key,
        [AllowEmptyString()][string]$Default = '',
        [string]$OrchestraHome = ''
    )
    $root = Get-OrchestraRootConfigPath -OrchestraHome $OrchestraHome
    $rootOnly = @($script:OrchestraRootOnlyKeys | Where-Object { $_ -ieq $Key }).Count -gt 0
    if (-not $rootOnly -and -not [string]::IsNullOrWhiteSpace($Work)) {
        $local = Get-OrchestraConfigValueFromFile -Path (Join-Path $Work 'config.md') -Key $Key
        if (-not [string]::IsNullOrWhiteSpace($local)) { return $local }
    }
    $global = Get-OrchestraConfigValueFromFile -Path $root -Key $Key
    if (-not [string]::IsNullOrWhiteSpace($global)) { return $global }
    return $Default
}

# --------------------------------------------------------------------------
# Argument parsing:  <command> [--key value | --flag] ...
# A key listed in -BoolFlags is a valueless flag; a key listed in -RepeatKeys collects
# repeated occurrences into a List[string]. Every other key takes one following value; a
# terminal key keeps the historical empty-string value because Windows PowerShell 5.1 drops
# an explicit trailing `''` while forwarding native argv. When -AllowedKeys is supplied, it
# is the command-specific option allowlist. Positional tokens, an empty `--`, a value omitted
# before the next option, unknown allowlisted options and duplicate non-repeatable keys are
# deterministic usage errors. Returns { Command; Opts } - Opts is a hashtable the caller
# keeps as its own $opts.
# --------------------------------------------------------------------------
function Parse-CliArgs {
    param(
        [string[]]$Argv = @(),
        [string[]]$BoolFlags = @(),
        [string[]]$RepeatKeys = @(),
        [AllowNull()][string[]]$AllowedKeys = $null
    )
    $command = if ($Argv.Count -ge 1) { [string]$Argv[0] } else { '' }
    $o = @{}
    for ($i = 1; $i -lt $Argv.Count; $i++) {
        $a = [string]$Argv[$i]
        if (-not $a.StartsWith('--', [System.StringComparison]::Ordinal)) {
            Fail 2 "unexpected argument '$a'"
        }
        $key = $a.Substring(2)
        if ([string]::IsNullOrEmpty($key)) { Fail 2 "empty option '--'" }
        if ($null -ne $AllowedKeys -and $AllowedKeys -notcontains $key) {
            Fail 2 "unknown option --$key"
        }
        if ($o.ContainsKey($key) -and $RepeatKeys -notcontains $key) {
            Fail 2 "option --$key may not be repeated"
        }
        if ($BoolFlags -contains $key) {
            $o[$key] = $true
            continue
        }
        $i++
        if ($i -lt $Argv.Count -and ([string]$Argv[$i]).StartsWith('--', [System.StringComparison]::Ordinal)) {
            Fail 2 "missing value for --$key"
        }
        $val = if ($i -lt $Argv.Count) { [string]$Argv[$i] } else { '' }
        if ($RepeatKeys -contains $key) {
            if (-not $o.ContainsKey($key)) { $o[$key] = [System.Collections.Generic.List[string]]::new() }
            $o[$key].Add($val)
        } else {
            $o[$key] = $val
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
function Parse-IntOpt {
    param([string]$Name, [int]$Default, [int]$Min = 0)
    $raw = [string](Opt $Name "$Default")
    if ([string]::IsNullOrEmpty($raw)) { return $Default }
    if ($raw -notmatch '^-?\d+$') { Fail 2 "--$Name must be an integer (got '$raw')" }
    $n = 0
    if (-not [int]::TryParse($raw, [System.Globalization.NumberStyles]::Integer,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
        Fail 2 "--$Name must be an integer in the Int32 range (got '$raw')"
    }
    if ($n -lt $Min) { Fail 2 "--$Name must be >= $Min (got $n)" }
    return $n
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
#
# Read-LockSnapshot captures the (creation-time, recorded-PID) identity of the lock file on
# disk right now, or $null if the file is gone / momentarily unreadable (e.g. read during the
# holder's create->write window). The recorded PID is the ASCII text the holder wrote; it is
# compared Ordinal (never through Get-PathComparer - that helper is for PATHS only, K-033).
# --------------------------------------------------------------------------
function Read-LockSnapshot {
    param([string]$LockPath)
    try {
        $fi = [System.IO.FileInfo]::new($LockPath)
        $fi.Refresh()
        if (-not $fi.Exists) { return $null }
        $creationUtc = $fi.CreationTimeUtc
        # ASCII to match the holder's Encoding.ASCII.GetBytes("$PID") write; a fresh file
        # still open by its creator throws a sharing violation -> caught below -> $null.
        $content = [System.IO.File]::ReadAllText($LockPath, [System.Text.Encoding]::ASCII)
        return [pscustomobject]@{
            CreationTicks = $creationUtc.Ticks
            AgeMs         = ([DateTime]::UtcNow - $creationUtc).TotalMilliseconds
            Content       = $content
        }
    } catch {
        return $null
    }
}
# Decides whether a stale lock may be broken, given the snapshot that DECIDED it was stale and
# a CONFIRM snapshot re-read immediately before removal. Break only if BOTH snapshots still
# describe the SAME abandoned lock: it was genuinely old (Decided) AND its identity did not
# change in the gap - same creation stamp AND same recorded PID. If a new holder released and
# recreated the lock between the two reads, its creation stamp differs (or, under NTFS
# tunneling, the stamp can be preserved but the recorded PID differs), so we refuse to delete
# the stranger's fresh lock. Residual break-path risk: PID reuse AND creation-time tunneling
# AND identical content coinciding inside the sub-millisecond confirm->Remove window.
# Release-Lock independently checks the recorded PID before removal, so a stale former holder
# cannot remove a lock that has already been recreated by a different live process.
function Test-StaleLockBreakable {
    param($Decided, $Confirm, [int]$StaleMs)
    if ($null -eq $Decided -or $null -eq $Confirm) { return $false }
    if ($Decided.AgeMs -le $StaleMs) { return $false }                       # not (yet) stale
    if ($Confirm.CreationTicks -ne $Decided.CreationTicks) { return $false } # recreated (new stamp)
    if (-not [string]::Equals([string]$Confirm.Content, [string]$Decided.Content, [System.StringComparison]::Ordinal)) {
        return $false                                                        # recreated by a different holder
    }
    return $true
}
# $StaleMs default is deliberately generous (5 min): a legitimate .work transaction - e.g.
# queue-tx Cmd-InboxDrain re-running Validate-Graph per record (quadratic I/O as the queue
# grows) or outbox Cmd-Append re-reading a large events.jsonl under the lock - must NEVER be
# mistaken for an abandoned holder and have its live lock broken (that is the lost-update this
# guards against). Recovery from a genuinely crashed holder is still bounded: a caller that
# opts into a TimeoutMs above this threshold breaks the abandoned lock once it ages past it.
function Acquire-Lock {
    param([string]$LockPath, [int]$TimeoutMs = 30000, [int]$StaleMs = 300000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    $missingLockFailures = 0
    $accessDeniedRetryDeadline = $null
    while ($true) {
        try {
            $fs = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try { $b = [System.Text.Encoding]::ASCII.GetBytes("$PID"); $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
            return
        } catch {
            $failure = $_
            $exception = $failure.Exception
            # PowerShell can wrap the same File.Open IOException in either one
            # MethodInvocationException or an additional RuntimeException layer under
            # concurrent invocation. Classify by the base exception so an ordinary
            # CreateNew loser is never leaked as a raw "file already exists" failure.
            $baseException = $exception.GetBaseException()
            $isIoFailure = ($baseException -is [System.IO.IOException])
            # Test-Path happens after the atomic CreateNew failure. A fast owner can release
            # in that gap, and several consecutive handoffs can therefore all observe an
            # absent path. Preserve the OS evidence that CreateNew itself lost to an existing
            # file: EEXIST (17) on POSIX, ERROR_FILE_EXISTS (80) / ERROR_ALREADY_EXISTS (183)
            # on Windows. Other absent-path I/O errors still surface after one retry.
            $nativeCode = ([int]$baseException.HResult -band 0xFFFF)
            $isCreateCollision = $isIoFailure -and ($nativeCode -in @(17, 80, 183))
            # Windows can report CREATE_NEW against a DeleteOnClose entry that is still
            # delete-pending as UnauthorizedAccessException / ERROR_ACCESS_DENIED (5), not
            # IOException / ERROR_FILE_EXISTS. That state is transient but code 5 is also
            # used for real ACL/directory denial, so it must not enter the full lock timeout.
            # Give only this exact shape a short handoff grace period; if it persists, rethrow
            # the original access error rather than misreporting "held by another writer".
            $isDeletePendingCandidate = `
                ($baseException -is [System.UnauthorizedAccessException]) -and ($nativeCode -eq 5)
            $lockExists = [bool](Test-Path -LiteralPath $LockPath -ErrorAction SilentlyContinue)
            # Only CreateNew's expected "file already exists" IOException is contention.
            # A loser can observe the holder release between Open and Test-Path; its native
            # collision code remains authoritative even when the path has already vanished.
            # For any other absent-file IOException, allow one short retry before surfacing
            # the persistent path/I/O failure instead of spinning for the full lock timeout.
            if ($isDeletePendingCandidate) {
                $now = [DateTime]::UtcNow
                if ($null -eq $accessDeniedRetryDeadline) {
                    $accessDeniedRetryDeadline = $now.AddMilliseconds(250)
                }
                if ($now -lt $deadline -and $now -lt $accessDeniedRetryDeadline) {
                    Start-Sleep -Milliseconds 10
                    continue
                }
                throw $failure
            }
            $accessDeniedRetryDeadline = $null
            if (-not $isIoFailure) { throw $failure }
            if (-not $lockExists) {
                if ($isCreateCollision) {
                    $missingLockFailures = 0
                    if ([DateTime]::UtcNow -gt $deadline) { Fail 7 "could not acquire $($script:LockName) lock at $LockPath (held by another writer)" }
                    Start-Sleep -Milliseconds 10
                    continue
                }
                $missingLockFailures++
                if ($missingLockFailures -ge 2) { throw $failure }
                Start-Sleep -Milliseconds 10
                continue
            }
            $missingLockFailures = 0
            if ($lockExists) {
                $decided = Read-LockSnapshot $LockPath
                if ($null -ne $decided -and $decided.AgeMs -gt $StaleMs) {
                    # Re-read the lock's identity immediately before deleting it, so a lock a
                    # new holder recreated in the age-check->Remove gap is not destroyed (TOCTOU).
                    $confirm = Read-LockSnapshot $LockPath
                    if (Test-StaleLockBreakable -Decided $decided -Confirm $confirm -StaleMs $StaleMs) {
                        Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
                        continue
                    }
                }
            }
            if ([DateTime]::UtcNow -gt $deadline) { Fail 7 "could not acquire $($script:LockName) lock at $LockPath (held by another writer)" }
            Start-Sleep -Milliseconds 50
        }
    }
}
# Test-only contention handshake shared by tools whose integration tests must prove that a
# real caller reached Acquire-Lock while another process owns the target lock. The signal
# environment variable name is explicit so production tools retain their established,
# tool-specific contracts without copying this probe/signal/cleanup sequence.
#
# A successful CreateNew probe owns a temporary lock file opened with DeleteOnClose. Disposing
# that exclusive handle atomically deletes the exact file object it created; there is no
# Dispose->path-based Remove window in which a replacement PID-bearing lock could be unlinked.
# Acquire-Lock then creates the real lock. An IOException is signalled only when the target
# still exists after the failed CreateNew attempt, matching Acquire-Lock's contention
# classification. Windows ERROR_ACCESS_DENIED during delete-pending handoff is ambiguous, so
# the probe emits no signal and delegates to Acquire-Lock's narrowly bounded classification;
# other I/O failures and release races likewise produce no false handshake.
function Acquire-LockWithTestSignal {
    param(
        [Parameter(Mandatory)][string]$LockPath,
        [Parameter(Mandatory)][string]$TestSignalEnvName,
        [int]$TimeoutMs = 30000,
        [int]$StaleMs = 300000
    )

    $waitSignal = [Environment]::GetEnvironmentVariable($TestSignalEnvName)
    if ($waitSignal) {
        $probe = $null
        try {
            $probe = [System.IO.FileStream]::new(
                $LockPath,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None,
                1,
                [System.IO.FileOptions]::DeleteOnClose
            )
        } catch {
            $probeFailure = $_
            $probeBaseException = $probeFailure.Exception.GetBaseException()
            $probeNativeCode = ([int]$probeBaseException.HResult -band 0xFFFF)
            $probeIsIoFailure = ($probeBaseException -is [System.IO.IOException])
            $probeIsDeletePendingCandidate = `
                ($probeBaseException -is [System.UnauthorizedAccessException]) -and ($probeNativeCode -eq 5)
            if (-not $probeIsIoFailure -and -not $probeIsDeletePendingCandidate) {
                throw $probeFailure
            }
            if ($probeIsIoFailure -and (Test-Path -LiteralPath $LockPath -ErrorAction SilentlyContinue)) {
                $signalDir = Split-Path -Parent $waitSignal
                if ($signalDir -and -not (Test-Path -LiteralPath $signalDir)) {
                    [void][System.IO.Directory]::CreateDirectory($signalDir)
                }
                [System.IO.File]::WriteAllText(
                    $waitSignal,
                    'contended',
                    (New-Object System.Text.UTF8Encoding($false))
                )
            }
        } finally {
            if ($null -ne $probe) {
                $probe.Dispose()
            }
        }
    }

    Acquire-Lock -LockPath $LockPath -TimeoutMs $TimeoutMs -StaleMs $StaleMs
}
function Release-Lock {
    param([string]$LockPath)

    # A contending Acquire-Lock repeatedly opens the lock for a snapshot read. On Windows
    # that short-lived reader does not share delete access, so a single best-effort
    # Remove-Item can lose the race and silently leave this process's PID-bearing lock
    # behind. Retry that transient sharing violation for a bounded interval, re-checking
    # ownership before every attempt so a lock recreated by another writer is never removed.
    $deadline = [DateTime]::UtcNow.AddMilliseconds(1000)
    while ($true) {
        $snapshot = Read-LockSnapshot $LockPath
        if ($null -eq $snapshot) {
            if (-not (Test-Path -LiteralPath $LockPath -ErrorAction SilentlyContinue)) { return }
        } elseif (-not [string]::Equals([string]$snapshot.Content, [string]$PID, [System.StringComparison]::Ordinal)) {
            Write-Warning "refusing to release $($script:LockName) lock at $LockPath because it is owned by PID '$($snapshot.Content)', not this process ($PID)"
            return
        } else {
            try {
                [System.IO.File]::Delete($LockPath)
                return
            } catch [System.IO.IOException] {
                # A concurrent snapshot reader can transiently deny delete access.
            } catch [System.UnauthorizedAccessException] {
                # Treat a transient access denial like the equivalent Windows sharing race.
            }
        }

        if ([DateTime]::UtcNow -gt $deadline) {
            Write-Warning "could not release $($script:LockName) lock at $LockPath after bounded retries"
            return
        }
        Start-Sleep -Milliseconds 10
    }
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
