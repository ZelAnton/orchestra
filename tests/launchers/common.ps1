<#
  Shared test harness for tests/launchers/*.ps1.

  Dot-source this file from each test-*.ps1. Every test-*.ps1 runs as its own
  child PowerShell process (see run-all.ps1), so state set up here (env vars,
  PATH, current directory) never leaks between tests - no manual cleanup
  between assertions is required within a single test file either, since the
  whole process exits after one test file finishes.

  Design notes:
  - Tests never touch the real .work/ of this repository or mutate the
    worktree: every test builds a fresh temporary sandbox with its own
    "project" directory (acts as the launcher's current directory / target
    project root) and its own "scripts" directory (a flat mirror of the
    launcher(s) under test, matching the real ~/.claude/scripts layout that
    cc-sync.cmd produces - this also lets cc-config.cmd find config.example.md
    via its documented flat-mirror fallback path).
  - Fake `claude` / `codex` executables are placed in a sandbox-local "bin"
    directory that is prepended to PATH for the duration of a single launcher
    invocation. The fake `claude.cmd` forwards its raw argument list to a
    PowerShell script via "%*", which reconstructs the exact argv (including
    multi-word quoted arguments) the same way the real `claude` binary would
    have received it, and writes one argument per line to a capture file for
    later comparison.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:LaunchersDir = Join-Path $script:RepoRoot 'launchers'
$script:ConfigExamplePath = Join-Path $script:RepoRoot 'config.example.md'

function New-Sandbox {
    $root = Join-Path $env:TEMP ("orc-launcher-test-" + [Guid]::NewGuid().ToString('N'))
    $paths = [ordered]@{
        Root    = $root
        Project = Join-Path $root 'project'
        Scripts = Join-Path $root 'scripts'
        Bin     = Join-Path $root 'bin'
    }
    New-Item -ItemType Directory -Force -Path $paths.Project | Out-Null
    New-Item -ItemType Directory -Force -Path $paths.Scripts | Out-Null
    New-Item -ItemType Directory -Force -Path $paths.Bin | Out-Null
    return $paths
}

function Remove-Sandbox {
    param([Parameter(Mandatory)] $Paths)
    Remove-Item -LiteralPath $Paths.Root -Recurse -Force -ErrorAction SilentlyContinue
}

# Copies launcher(s) from the real launchers/ directory into the sandbox
# scripts\ dir, normalizing LF-only line endings to CRLF along the way.
#
# This is a test-harness-local workaround, not a change to the real files:
# the launchers in this repository are committed with LF-only line endings,
# and cmd.exe's "chcp 65001" UTF-8 batch-file reader has a genuine,
# reproducible bug on this platform where LF-only line endings combined with
# enough non-ASCII (Cyrillic comment) bytes cause its internal read-ahead
# buffer to drift out of alignment - this silently corrupts and can even
# skip/mangle later, purely-ASCII command lines (observed turning the literal
# "claude" invocation into "aude" further down cc-processor.cmd, for
# example), whenever the process's own stdio is not a live interactive
# console - i.e. exactly the situation any automated/redirected invocation
# (this test harness, or a CI runner) is in. It does not depend on whether
# output is actually captured/redirected by the caller. CRLF line endings
# make cmd.exe's reader keep its byte accounting in sync and eliminate the
# corruption entirely (verified directly against these launchers); the
# content and semantics of every line are unchanged; only the CR bytes are
# added. The corruption is invisible in normal interactive terminal use,
# which is presumably why it has gone unnoticed so far.
# cc-status.cmd embeds a Cyrillic parenthetical message mid-line inside each of its two
# "else { Write-Host '(...)' }" branches (shown when status.md / journal.md is absent).
# Unlike the drift the CRLF normalization above fixes (which resyncs at every line
# break), that phrase sits mid-line with no line break to resync on; the same cmd.exe
# read corruption there corrupts that one embedded string badly enough that PowerShell's
# own parser fails on the *entire* -Command argument, so nothing runs. Neither message's
# exact wording is asserted by the tests, so both occurrences are replaced uniformly with
# an ASCII placeholder in the sandboxed copy only (never the real launcher).
#
# (Historically cc-doctor.cmd needed the same treatment for its embedded Cyrillic KB
# header; since task T-090 cc-doctor.cmd is a thin wrapper with no embedded non-ASCII, so
# it no longer needs a fixup and its logic is covered directly by test-doctor-runtime.ps1.)
#
# The match is done by regex against the surrounding ASCII rather than by embedding the
# Cyrillic phrase as a literal in this file's own source: Windows PowerShell 5.1 reads
# .ps1 files without a BOM using the legacy system ANSI code page, not UTF-8, so a literal
# non-ASCII string typed directly into this UTF-8-without-BOM file would itself be misread
# as soon as this file is loaded - the same class of encoding pitfall this whole
# workaround exists to route around, just one layer up (in the test harness' own source
# instead of the launcher's).
$script:LauncherContentFixups = @{
    'cc-status.cmd' = @(
        , @("Write-Host '\([^)]*\)'", "Write-Host '(no data yet)'")
    )
}

function Install-Launcher {
    param(
        [Parameter(Mandatory)] $Paths,
        [Parameter(Mandatory)] [string[]] $Names
    )
    # Names requested by the caller are installed breadth-first, but any
    # sibling launchers\*.cmd file that an installed launcher itself invokes
    # via `call "%~dp0<name>.cmd" ...` (e.g. cc-queue.cmd/cc-thinker.cmd/
    # cc-audit.cmd/cc-enhance.cmd/cc-github.cmd calling into the shared
    # launchers\cc-common.cmd helper, T-037) is discovered from that
    # launcher's own source and installed automatically too - otherwise an
    # isolated sandbox test would fail on a missing helper file the moment
    # the launcher under test tries to "call" it, even though the test only
    # asked to install itself. This keeps test-*.ps1 files from having to
    # know about a launcher's internal helper dependencies.
    $installed = New-Object 'System.Collections.Generic.HashSet[string]'
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    foreach ($n in $Names) { $queue.Enqueue($n) }
    while ($queue.Count -gt 0) {
        $n = $queue.Dequeue()
        if (-not $installed.Add($n)) { continue }
        $src = Join-Path $script:LaunchersDir $n
        if (-not (Test-Path -LiteralPath $src)) {
            throw "Launcher not found: $src"
        }
        # -Encoding UTF8 is required here: launchers/*.cmd are saved as UTF-8
        # without BOM (adding a BOM to .cmd batch files is unsafe - cmd.exe
        # does not reliably skip it), and Get-Content -Raw without an
        # explicit encoding falls back to the system ANSI codepage under
        # Windows PowerShell 5.1 when no BOM is present, corrupting the
        # non-ASCII characters embedded in some launchers (mirrors the exact
        # defect this test suite's own .ps1 sources were fixed against - see
        # T-029).
        $text = Get-Content -LiteralPath $src -Raw -Encoding UTF8
        if ($script:LauncherContentFixups.ContainsKey($n)) {
            foreach ($pair in $script:LauncherContentFixups[$n]) {
                $text = [regex]::Replace($text, $pair[0], [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $pair[1] })
            }
        }
        $normalized = $text -replace "`r`n", "`n"
        $normalized = $normalized -replace "`n", "`r`n"
        $dest = Join-Path $Paths.Scripts $n
        [System.IO.File]::WriteAllText($dest, $normalized, (New-Object System.Text.UTF8Encoding($false)))

        # cc-processor/cc-resume resolve the ProcessKit adapter from either the checkout
        # tools/ directory or the flat cc-sync mirror. Launcher fixtures model the latter,
        # so install that runtime dependency beside the launcher as cc-sync does.
        if ($n -in @('cc-processor.cmd', 'cc-resume.cmd')) {
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'tools/processkit-runtime.ps1') `
                -Destination (Join-Path $Paths.Scripts 'processkit-runtime.ps1') -Force
        }

        foreach ($m in [regex]::Matches($text, 'call\s+"%~dp0([A-Za-z0-9_.-]+\.cmd)"')) {
            $dep = $m.Groups[1].Value
            if (-not $installed.Contains($dep)) { $queue.Enqueue($dep) }
        }
    }
}

function Install-ConfigExample {
    param([Parameter(Mandatory)] $Paths)
    Copy-Item -LiteralPath $script:ConfigExamplePath -Destination (Join-Path $Paths.Scripts 'config.example.md') -Force
}

# Shared PowerShell helper dropped into the sandbox bin\ dir. It writes each
# received positional argument to $env:FAKE_ARGS_FILE (one per line, in
# order) and exits with $env:FAKE_EXIT_CODE (default 0). When $env:FAKE_ENV_FILE
# is set it additionally records the CC_CODEX_EXEC_GRANT environment variable the
# fake `claude` process inherited (as "CC_CODEX_EXEC_GRANT=<value>", empty if
# unset) so tests can assert that the launcher exported the session-grant signal
# into claude's environment (task T-071). Guarded by FAKE_ENV_FILE so existing
# tests that do not set it are unaffected.
$script:CaptureArgsScript = @'
$dest = $env:FAKE_ARGS_FILE
if ($dest) {
    if ($args.Count -gt 0) {
        $args | Set-Content -LiteralPath $dest -Encoding utf8
    } else {
        Set-Content -LiteralPath $dest -Value @() -Encoding utf8
    }
}
$envDest = $env:FAKE_ENV_FILE
if ($envDest) {
    Set-Content -LiteralPath $envDest -Value @(
        ("CC_CODEX_EXEC_GRANT=" + $env:CC_CODEX_EXEC_GRANT),
        ("MSBUILDDISABLENODEREUSE=" + $env:MSBUILDDISABLENODEREUSE),
        ("DOTNET_CLI_USE_MSBUILD_SERVER=" + $env:DOTNET_CLI_USE_MSBUILD_SERVER),
        ("BASH_DEFAULT_TIMEOUT_MS=" + $env:BASH_DEFAULT_TIMEOUT_MS),
        ("BASH_MAX_TIMEOUT_MS=" + $env:BASH_MAX_TIMEOUT_MS)
    ) -Encoding utf8
}
$code = 0
if ($env:FAKE_EXIT_CODE) { $code = [int]$env:FAKE_EXIT_CODE }
exit $code
'@

function Install-FakeClaude {
    param([Parameter(Mandatory)] $Paths)
    Set-Content -LiteralPath (Join-Path $Paths.Bin 'capture-args.ps1') -Value $script:CaptureArgsScript -Encoding utf8
    # "setlocal DisableDelayedExpansion" right after "@echo off" is required
    # here, not optional flourish: the real `claude` this stub replaces is a
    # standalone .exe, so cmd.exe always spawns it as a genuinely separate
    # process, immune to whatever delayed-expansion state the launcher that
    # invoked it happened to have active. This stub, being a .cmd file
    # itself, does not get that same isolation "for free" - a launcher like
    # cc-queue.cmd/cc-thinker.cmd invokes `claude ...` (this stub) without
    # "call" while its own "setlocal EnableDelayedExpansion" is still active,
    # and cmd.exe transfers straight into this file's code within that same
    # interpreter/scope (no "call" means no new scope, and unlike a real
    # .exe, no new process boundary either) - so the "%*" below would
    # otherwise be parsed with delayed expansion still (unwantedly) enabled,
    # inflicting a second, spurious delayed-expansion pass over the already
    # percent-expanded text and silently eating any literal "!" the launcher
    # forwarded (see launchers/cc-common.cmd:sanitize and its test coverage
    # for the argument-content half of this same "!" class of bug - this is
    # the test-harness half, needed so that coverage can actually observe a
    # correct result instead of an artifact of the stub itself).
    $stub = "@echo off`r`nsetlocal DisableDelayedExpansion`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0capture-args.ps1`" %*`r`n"
    Set-Content -LiteralPath (Join-Path $Paths.Bin 'claude.cmd') -Value $stub -Encoding ascii -NoNewline
}

function Install-FakeCodex {
    param(
        [Parameter(Mandatory)] $Paths,
        [string] $Version = 'codex-fake 0.0.0-test'
    )
    Set-Content -LiteralPath (Join-Path $Paths.Bin 'capture-args.ps1') -Value $script:CaptureArgsScript -Encoding utf8 -Force
    # See the matching comment in Install-FakeClaude above for why this stub
    # needs its own "setlocal DisableDelayedExpansion" too.
    $stub = @"
@echo off
setlocal DisableDelayedExpansion
if "%~1"=="--version" (
  echo $Version
  exit /b 0
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0capture-args.ps1" %*
"@
    Set-Content -LiteralPath (Join-Path $Paths.Bin 'codex.cmd') -Value $stub -Encoding ascii
}

# Drops a fake tools/state-tx.ps1 into the sandbox scripts\ dir (the flat cc-sync mirror layout
# next to the launcher), so a launcher's `--force-lock` resolves it as the mirror runner and runs
# it via pwsh. The fake records the argv it was invoked with to $env:FAKE_STATE_TX_ARGS (one per
# line, like the fake claude) and, like the real `state-tx release --force`, removes
# .work\orchestrator.lock relative to the launcher's current directory. Lets a launcher test assert
# the force-takeover takes the single transactional `state-tx release --force` path instead of a
# raw directory removal.
$script:FakeStateTxScript = @'
$dest = $env:FAKE_STATE_TX_ARGS
if ($dest) {
    if ($args.Count -gt 0) {
        $args | Set-Content -LiteralPath $dest -Encoding utf8
    } else {
        Set-Content -LiteralPath $dest -Value @() -Encoding utf8
    }
}
Remove-Item -LiteralPath '.work\orchestrator.lock' -Recurse -Force -ErrorAction SilentlyContinue
Write-Output 'released'
exit 0
'@

function Install-FakeStateTx {
    param([Parameter(Mandatory)] $Paths)
    Set-Content -LiteralPath (Join-Path $Paths.Scripts 'state-tx.ps1') -Value $script:FakeStateTxScript -Encoding utf8
}

function Install-FakeProcessKitRuntime {
    param([Parameter(Mandatory)] $Paths)
    @'
if ($env:FAKE_PROCESSKIT_RUNTIME_ARGS) {
    $args | Set-Content -LiteralPath $env:FAKE_PROCESSKIT_RUNTIME_ARGS -Encoding utf8
}
$code = if ($env:FAKE_PROCESSKIT_RUNTIME_EXIT) { [int]$env:FAKE_PROCESSKIT_RUNTIME_EXIT } else { 0 }
exit $code
'@ | Set-Content -LiteralPath (Join-Path $Paths.Scripts 'processkit-runtime.ps1') -Encoding utf8
}

function Get-CapturedArgs {
    param([Parameter(Mandatory)] [string] $CaptureFile)
    if (-not (Test-Path -LiteralPath $CaptureFile)) {
        return @()
    }
    $content = @(Get-Content -LiteralPath $CaptureFile -Encoding utf8)
    if ($content.Count -eq 1 -and $content[0] -eq '') {
        return @()
    }
    return $content
}

# Runs a launcher .cmd (already installed into $Paths.Scripts by
# Install-Launcher) from $Paths.Project as the current directory, with
# $Paths.Bin prepended to PATH so the fake claude/codex stubs are found first.
function Invoke-Launcher {
    param(
        [Parameter(Mandatory)] $Paths,
        [Parameter(Mandatory)] [string] $Name,
        [string[]] $LauncherArgs = @(),
        [hashtable] $EnvVars = @{},
        # When set, PATH is NOT inherited from the current environment (only
        # $Paths.Bin plus the minimal Windows/PowerShell system directories
        # needed for cmd.exe/powershell.exe themselves to run). Use this for
        # scenarios that need to assert the *absence* of a real executable
        # (e.g. codex) on PATH - a plain prepend of $Paths.Bin is not enough
        # when that real executable happens to already be installed and on
        # PATH in the environment the tests run in.
        [switch] $MinimalPath
    )
    $cmdPath = Join-Path $Paths.Scripts $Name
    if (-not (Test-Path -LiteralPath $cmdPath)) {
        throw "Launcher not installed in sandbox: $cmdPath"
    }

    $originalPath = $env:PATH
    $originalLocation = Get-Location
    $setEnvVars = @{}
    $effectiveEnvVars = @{ CC_PROCESSKIT_CLI = 'off'; CC_PROCESSKIT_PYTHON = '' }
    foreach ($k in $EnvVars.Keys) { $effectiveEnvVars[$k] = $EnvVars[$k] }
    try {
        if ($MinimalPath) {
            $sysRoot = $env:SystemRoot
            $env:PATH = "$($Paths.Bin);$sysRoot\System32;$sysRoot;$sysRoot\System32\WindowsPowerShell\v1.0\"
        } else {
            $env:PATH = "$($Paths.Bin);$originalPath"
        }
        foreach ($k in $effectiveEnvVars.Keys) {
            $setEnvVars[$k] = [Environment]::GetEnvironmentVariable($k)
            Set-Item -Path "env:$k" -Value $effectiveEnvVars[$k]
        }
        Set-Location -LiteralPath $Paths.Project
        # Several launchers run "chcp 65001" followed by a Cyrillic "rem"
        # comment; under output redirection cmd.exe has a known harmless
        # glitch there that emits a stray "... is not recognized" line to
        # stderr without affecting real execution (exit code / later
        # commands are unaffected - verified against the shipped launchers).
        # With $ErrorActionPreference='Stop' (set globally by this file),
        # PowerShell would otherwise turn that captured stderr line into a
        # terminating NativeCommandError and abort the test. Relax it for the
        # duration of the native call only.
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = & $cmdPath @LauncherArgs 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $prevEap
        }
        return [pscustomobject]@{
            ExitCode = $exitCode
            Output   = $output
        }
    }
    finally {
        Set-Location -LiteralPath $originalLocation
        $env:PATH = $originalPath
        foreach ($k in $setEnvVars.Keys) {
            if ($null -eq $setEnvVars[$k]) {
                Remove-Item -Path "env:$k" -ErrorAction SilentlyContinue
            } else {
                Set-Item -Path "env:$k" -Value $setEnvVars[$k]
            }
        }
    }
}

# Extracts the literal value that currently follows "--permission-mode" in a
# real launcher's source file. Tests must use this instead of hardcoding a
# literal (e.g. "auto") so they stay correct across changes to that flag's
# value (see task T-018 / T-007 note) while still verifying the launcher
# actually forwards whatever value its source currently specifies.
function Get-ExpectedPermissionMode {
    param([Parameter(Mandatory)] [string] $LauncherName)
    $src = Get-Content -LiteralPath (Join-Path $script:LaunchersDir $LauncherName) -Raw
    $m = [regex]::Match($src, '--permission-mode\s+(\S+)')
    if ($m.Success) {
        return $m.Groups[1].Value
    }
    # Some launchers (cc-audit.cmd, cc-enhance.cmd, cc-github.cmd, T-037) do
    # not invoke claude directly - they forward to the shared
    # launchers\cc-common.cmd ":run" helper as
    #   call "%~dp0cc-common.cmd" run <agent> <permission-mode> "<prompt>"
    # where the literal "--permission-mode" flag itself lives in
    # cc-common.cmd, not in the launcher's own source. In that case the
    # permission-mode value is the second whitespace-separated token after
    # "run" (the first is the agent name).
    $m = [regex]::Match($src, 'cc-common\.cmd"\s+run\s+\S+\s+(\S+)\s')
    if ($m.Success) {
        return $m.Groups[1].Value
    }
    throw "Could not find --permission-mode in $LauncherName"
}

# Reads the CC_CODEX_EXEC_GRANT value a launcher's source sets (cmd: `set
# "CC_CODEX_EXEC_GRANT=..."`, sh: `export CC_CODEX_EXEC_GRANT="..."`), so the
# session-grant tests verify the launcher forwards whatever value its source
# currently specifies instead of hardcoding a literal (mirrors
# Get-ExpectedPermissionMode). Returns $null if the launcher sets no such var.
function Get-ExpectedGrant {
    param([Parameter(Mandatory)] [string] $LauncherName)
    $src = Get-Content -LiteralPath (Join-Path $script:LaunchersDir $LauncherName) -Raw
    $m = [regex]::Match($src, 'CC_CODEX_EXEC_GRANT=(?:")?([^"\r\n]*?)(?:")?\s*[\r\n]')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $null
}

# Reads back the "CC_CODEX_EXEC_GRANT=<value>" line the fake claude recorded into
# $FAKE_ENV_FILE (see $script:CaptureArgsScript), returning just the <value>.
function Get-CapturedGrant {
    param([Parameter(Mandatory)] [string] $EnvFile)
    if (-not (Test-Path -LiteralPath $EnvFile)) { return $null }
    $line = (Get-Content -LiteralPath $EnvFile -Encoding utf8 | Select-Object -First 1)
    if ($null -eq $line) { return '' }
    return ($line -replace '^CC_CODEX_EXEC_GRANT=', '')
}

function Get-CapturedEnvValue {
    param([Parameter(Mandatory)] [string] $EnvFile, [Parameter(Mandatory)] [string] $Name)
    if (-not (Test-Path -LiteralPath $EnvFile)) { return $null }
    $prefix = $Name + '='
    $line = Get-Content -LiteralPath $EnvFile -Encoding utf8 | Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) } | Select-Object -First 1
    if ($null -eq $line) { return $null }
    return $line.Substring($prefix.Length)
}

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Message = '')
    if ($Expected -ne $Actual) {
        throw "Assertion failed: ${Message}: expected [$Expected], got [$Actual]"
    }
}

function Assert-ArrayEqual {
    param([object[]] $Expected, [object[]] $Actual, [string] $Message = '')
    $exp = @($Expected)
    $act = @($Actual)
    $ok = $exp.Count -eq $act.Count
    if ($ok) {
        for ($i = 0; $i -lt $exp.Count; $i++) {
            if ($exp[$i] -ne $act[$i]) { $ok = $false; break }
        }
    }
    if (-not $ok) {
        $expStr = ($exp | ForEach-Object { "[$_]" }) -join ' '
        $actStr = ($act | ForEach-Object { "[$_]" }) -join ' '
        throw "Assertion failed: ${Message}: expected ($expStr), got ($actStr)"
    }
}

function Assert-Contains {
    param([string] $Haystack, [string] $Needle, [string] $Message = '')
    if ($Haystack -notlike "*$Needle*") {
        throw "Assertion failed: ${Message}: expected to find [$Needle] in [$Haystack]"
    }
}

function Assert-FileExists {
    param([string] $Path, [string] $Message = '')
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Assertion failed: ${Message}: file does not exist: $Path"
    }
}

function Assert-NoFileExists {
    param([string] $Path, [string] $Message = '')
    if (Test-Path -LiteralPath $Path) {
        throw "Assertion failed: ${Message}: file unexpectedly exists: $Path"
    }
}

# Runs $Body (a scriptblock containing one test's logic) and converts any
# thrown error into a clean "FAIL" report on stdout plus a non-zero exit code,
# or reports "OK" and exits 0 on success. Every test-*.ps1 should end with a
# single call to this function.
function Invoke-Test {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [scriptblock] $Body
    )
    try {
        & $Body
        Write-Host "OK   $Name"
        exit 0
    }
    catch {
        Write-Host "FAIL $Name"
        Write-Host ($_ | Out-String)
        exit 1
    }
}
