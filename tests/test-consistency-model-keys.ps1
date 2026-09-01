# ci:posix
<#
.SYNOPSIS
    Fixture for the Class 4 role-model consistency checks of
    tools/check-consistency.ps1.

.DESCRIPTION
    Three parts of the config contract exist twice on purpose: the schema source
    tools/policy-schema.ps1 owns them, and tools/doctor-runtime.ps1 carries local copies
    ($claudeModelAllowed - allowed models per tier, $claudeModelFrontmatter - the model a
    role falls back to when its key is unset) so cc-doctor keeps working when its engine is
    mirrored standalone into ~/.claude/scripts. Class 4 machine-guarantees they cannot
    drift.

    This test copies the repository into a disposable root, runs the real validator once
    unmodified (must stay clean), then drifts ONLY a doctor copy - per scenario: one
    allowed value dropped plus one key removed, one fallback model changed - and runs the
    same entry point again. Every drift must be
    reported with a non-zero exit code, naming both ends of the contract. Driving the
    production entry point (not a test-only mode) also proves the checks are wired into
    the main flow. No repository file is modified.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
. (Join-Path $PSScriptRoot '..\tools\common.ps1')

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$CheckerRelPath = 'tools/check-consistency.ps1'
$DoctorRelPath = 'tools/doctor-runtime.ps1'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Failures = [System.Collections.Generic.List[string]]::new()
$TempRoots = [System.Collections.Generic.List[string]]::new()

# Reuse the interpreter that runs this test instead of assuming `pwsh` is on PATH: a
# silent skip would hide the gate rather than prove it.
$PwshExe = Get-PowerShellHostExecutable

$SkipTopLevel = @('.git', '.jj', '.work', 'node_modules', 'target')

function New-RepoFixture {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('orchestra-modelkeys-' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($root)
    $TempRoots.Add($root)
    foreach ($entry in @(Get-ChildItem -LiteralPath $RepoRoot -Force)) {
        if ($SkipTopLevel -contains $entry.Name) { continue }
        Copy-Item -LiteralPath $entry.FullName -Destination $root -Recurse -Force
    }
    return $root
}

function Invoke-Checker {
    param([Parameter(Mandatory)][string]$Root)
    $lines = @(& $PwshExe -NoProfile -File (Join-Path $Root $CheckerRelPath) 2>&1 |
            ForEach-Object { $_.ToString().TrimEnd() })
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Lines    = $lines
        Output   = ($lines -join "`n")
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { $Failures.Add("FAIL - ${Message}: expected [$Expected], got [$Actual]") }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { $Failures.Add("FAIL - $Message") }
}

try {
    $root = New-RepoFixture
    $clean = Invoke-Checker -Root $root
    Assert-Equal 0 $clean.ExitCode "an unmodified checkout copy stays clean; output=$($clean.Output)"
    Assert-True (-not $clean.Output.Contains('cc-doctor-claude-models')) `
        'an unmodified checkout copy produces no role-model finding'

    # Drift the doctor copy only: drop one allowed value from one key, delete another key.
    $doctorPath = Join-Path $root $DoctorRelPath
    $doctor = [System.IO.File]::ReadAllText($doctorPath)
    $narrowed = "'CLAUDE_REVIEWER_MODEL'     = @('sonnet', 'opus')"
    $original = "'CLAUDE_REVIEWER_MODEL'     = @('haiku', 'sonnet', 'opus', 'fable')"
    if (-not $doctor.Contains($original)) {
        throw "Fixture anchor not found in $DoctorRelPath : $original"
    }
    $doctor = $doctor.Replace($original, $narrowed)
    $removed = "    'CLAUDE_CODER_DEEP_MODEL'   = @('haiku', 'sonnet', 'opus', 'fable')`n"
    if (-not $doctor.Contains($removed)) {
        # Tolerate CRLF checkouts of the runtime source.
        $removed = $removed.Replace("`n", "`r`n")
        if (-not $doctor.Contains($removed)) {
            throw "Fixture anchor not found in $DoctorRelPath : CLAUDE_CODER_DEEP_MODEL row"
        }
    }
    $doctor = $doctor.Replace($removed, '')
    [System.IO.File]::WriteAllText($doctorPath, $doctor, $Utf8NoBom)

    $drifted = Invoke-Checker -Root $root
    $found = @($drifted.Lines | Where-Object { $_ -match ' - cc-doctor-claude-models - ' })
    Assert-Equal 1 $drifted.ExitCode 'a drifted cc-doctor role-model copy fails the validator'
    Assert-Equal 2 $found.Count `
        "one finding per drifted key; findings=$($found -join ' // ')"
    Assert-Equal 1 @($found | Where-Object { $_ -match "'CLAUDE_REVIEWER_MODEL' allowed set is " }).Count `
        "a narrowed allowed set is reported; findings=$($found -join ' // ')"
    Assert-Equal 1 @($found | Where-Object { $_ -match "'CLAUDE_CODER_DEEP_MODEL' is a schema config key but missing" }).Count `
        "a key missing from the doctor copy is reported; findings=$($found -join ' // ')"
    Assert-Equal 2 @($found | Where-Object { $_ -match '^tools/doctor-runtime\.ps1 - ' }).Count `
        "findings keep the '<file> - <check> - <detail>' shape; findings=$($found -join ' // ')"

    # The second doctor copy - the model a role falls back to when its key is unset - is
    # guarded at both ends: against the schema default and against the role's own
    # frontmatter. A single drifted entry must therefore report both.
    $root2 = New-RepoFixture
    $doctor2Path = Join-Path $root2 $DoctorRelPath
    $doctor2 = [System.IO.File]::ReadAllText($doctor2Path)
    $fmOriginal = "'CLAUDE_CODER_MODEL'        = 'sonnet'"
    $fmDrifted = "'CLAUDE_CODER_MODEL'        = 'haiku'"
    if (-not $doctor2.Contains($fmOriginal)) {
        throw "Fixture anchor not found in $DoctorRelPath : $fmOriginal"
    }
    [System.IO.File]::WriteAllText($doctor2Path, $doctor2.Replace($fmOriginal, $fmDrifted), $Utf8NoBom)

    $drifted2 = Invoke-Checker -Root $root2
    $found2 = @($drifted2.Lines | Where-Object { $_ -match ' - cc-doctor-claude-model-defaults - ' })
    Assert-Equal 1 $drifted2.ExitCode 'a drifted cc-doctor fallback-model copy fails the validator'
    Assert-Equal 2 $found2.Count `
        "a drifted fallback model is reported against both ends; findings=$($found2 -join ' // ')"
    Assert-Equal 1 @($found2 | Where-Object { $_ -match "tools/policy-schema\.ps1 defaults it to 'sonnet'" }).Count `
        "the schema default is named; findings=$($found2 -join ' // ')"
    Assert-Equal 1 @($found2 | Where-Object { $_ -match "agents/coder\.md runs on 'sonnet'" }).Count `
        "the role frontmatter is named; findings=$($found2 -join ' // ')"

}
finally {
    foreach ($dir in $TempRoots) {
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($Failures.Count -gt 0) {
    Write-Host "FAILED - $($Failures.Count) assertion(s):"
    foreach ($failure in $Failures) { Write-Host "  $failure" }
    exit 1
}

Write-Host 'OK - consistency Class 4 reports every drift between the cc-doctor role-model copies, tools/policy-schema.ps1 and the role frontmatter.'
exit 0
