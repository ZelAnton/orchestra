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
# cc-doctor.cmd's single powershell -Command line embeds one Cyrillic
# section-header phrase ("== База знаний (KB; .work\knowledge) ==") deep
# inside an otherwise very long, all-ASCII one-liner. Unlike the drift
# described above (which CRLF normalization fixes because it resyncs at
# every line break), this phrase sits mid-line with no line break to resync
# on; the same read corruption there does not just print a stray line, it
# corrupts that one embedded string badly enough that PowerShell's own
# parser fails on the *entire* -Command argument (a single parse pass over
# the whole string), so nothing in the script runs at all. Verified this is
# not fixed by CRLF normalization, a UTF-8 BOM, or pre-setting the real
# console codepage before spawning cmd.exe - it reproduces regardless.
# Since this phrase is a cosmetic section header with no bearing on the
# logic under test (config-key parsing, codex detection, KB entry counts),
# the sandboxed test copy substitutes an ASCII paraphrase for it so the rest
# of the script - identical otherwise - can actually run under automated
# invocation. This never touches the real launcher file.
#
# The match is done by regex against the surrounding ASCII (`== ... (KB;
# .work\knowledge) ==`) rather than by embedding the Cyrillic phrase as a
# literal in this file's own source: Windows PowerShell 5.1 reads .ps1 files
# without a BOM using the legacy system ANSI code page, not UTF-8, so a
# literal non-ASCII string typed directly into this UTF-8-without-BOM file
# would itself be misread as soon as this file is loaded - the same class of
# encoding pitfall this whole workaround exists to route around, just one
# layer up (in the test harness' own source instead of the launcher's).
$script:LauncherContentFixups = @{
    'cc-doctor.cmd' = @(
        , @('== \S+ \S+ \(KB; \.work\\knowledge\) ==', '== KB status (.work\knowledge) ==')
    )
    # cc-status.cmd embeds a Cyrillic parenthetical message inside each of its
    # two "else { Write-Host '(...)' }" branches (shown when status.md /
    # journal.md is absent). Same class of issue as cc-doctor.cmd above;
    # neither message's exact wording is asserted by the tests, so both
    # occurrences are replaced uniformly with an ASCII placeholder.
    'cc-status.cmd' = @(
        , @("Write-Host '\([^)]*\)'", "Write-Host '(no data yet)'")
    )
}

function Install-Launcher {
    param(
        [Parameter(Mandatory)] $Paths,
        [Parameter(Mandatory)] [string[]] $Names
    )
    foreach ($n in $Names) {
        $src = Join-Path $script:LaunchersDir $n
        if (-not (Test-Path -LiteralPath $src)) {
            throw "Launcher not found: $src"
        }
        $text = Get-Content -LiteralPath $src -Raw
        if ($script:LauncherContentFixups.ContainsKey($n)) {
            foreach ($pair in $script:LauncherContentFixups[$n]) {
                $text = [regex]::Replace($text, $pair[0], [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $pair[1] })
            }
        }
        $text = $text -replace "`r`n", "`n"
        $text = $text -replace "`n", "`r`n"
        $dest = Join-Path $Paths.Scripts $n
        [System.IO.File]::WriteAllText($dest, $text, (New-Object System.Text.UTF8Encoding($false)))
    }
}

function Install-ConfigExample {
    param([Parameter(Mandatory)] $Paths)
    Copy-Item -LiteralPath $script:ConfigExamplePath -Destination (Join-Path $Paths.Scripts 'config.example.md') -Force
}

# Shared PowerShell helper dropped into the sandbox bin\ dir. It writes each
# received positional argument to $env:FAKE_ARGS_FILE (one per line, in
# order) and exits with $env:FAKE_EXIT_CODE (default 0).
$script:CaptureArgsScript = @'
$dest = $env:FAKE_ARGS_FILE
if ($dest) {
    if ($args.Count -gt 0) {
        $args | Set-Content -LiteralPath $dest -Encoding utf8
    } else {
        Set-Content -LiteralPath $dest -Value @() -Encoding utf8
    }
}
$code = 0
if ($env:FAKE_EXIT_CODE) { $code = [int]$env:FAKE_EXIT_CODE }
exit $code
'@

function Install-FakeClaude {
    param([Parameter(Mandatory)] $Paths)
    Set-Content -LiteralPath (Join-Path $Paths.Bin 'capture-args.ps1') -Value $script:CaptureArgsScript -Encoding utf8
    $stub = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0capture-args.ps1`" %*`r`n"
    Set-Content -LiteralPath (Join-Path $Paths.Bin 'claude.cmd') -Value $stub -Encoding ascii -NoNewline
}

function Install-FakeCodex {
    param(
        [Parameter(Mandatory)] $Paths,
        [string] $Version = 'codex-fake 0.0.0-test'
    )
    Set-Content -LiteralPath (Join-Path $Paths.Bin 'capture-args.ps1') -Value $script:CaptureArgsScript -Encoding utf8 -Force
    $stub = @"
@echo off
if "%~1"=="--version" (
  echo $Version
  exit /b 0
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0capture-args.ps1" %*
"@
    Set-Content -LiteralPath (Join-Path $Paths.Bin 'codex.cmd') -Value $stub -Encoding ascii
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
    try {
        if ($MinimalPath) {
            $sysRoot = $env:SystemRoot
            $env:PATH = "$($Paths.Bin);$sysRoot\System32;$sysRoot;$sysRoot\System32\WindowsPowerShell\v1.0\"
        } else {
            $env:PATH = "$($Paths.Bin);$originalPath"
        }
        foreach ($k in $EnvVars.Keys) {
            $setEnvVars[$k] = [Environment]::GetEnvironmentVariable($k)
            Set-Item -Path "env:$k" -Value $EnvVars[$k]
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
    if (-not $m.Success) {
        throw "Could not find --permission-mode in $LauncherName"
    }
    return $m.Groups[1].Value
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
