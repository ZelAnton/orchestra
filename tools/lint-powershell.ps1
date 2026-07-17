[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$settingsPath = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'

if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    Write-Error "PSScriptAnalyzer settings file is missing: $settingsPath"
    exit 2
}

$analyzerModule = Get-Module -ListAvailable -Name PSScriptAnalyzer |
    Sort-Object Version -Descending |
    Select-Object -First 1
if ($null -eq $analyzerModule) {
    Write-Error 'PSScriptAnalyzer is required. Install it with: Install-Module PSScriptAnalyzer -Scope CurrentUser'
    exit 2
}

Import-Module -Name $analyzerModule.Path -ErrorAction Stop

$sourceFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'tools') -Filter '*.ps1' -File
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'tests') -Filter '*.ps1' -File -Recurse
    Get-ChildItem -LiteralPath $repoRoot -Filter 'generate-*.ps1' -File
) | Sort-Object FullName -Unique

if ($sourceFiles.Count -eq 0) {
    Write-Error 'No PowerShell source files were found in tools/, tests/, or the root generators.'
    exit 2
}

$findings = @(
    foreach ($sourceFile in $sourceFiles) {
        Invoke-ScriptAnalyzer -Path $sourceFile.FullName -Settings $settingsPath -ErrorAction Stop
    }
)

if ($findings.Count -gt 0) {
    $findings |
        Sort-Object ScriptPath, Line, Column, RuleName |
        Format-Table Severity, RuleName, ScriptName, Line, Column, Message -AutoSize |
        Out-Host
}

# Warning findings stay visible for incremental cleanup but are non-blocking. The gate fails
# on Error and ParseError findings, so existing warning debt cannot hide broken scripts.
$errorFindings = @(
    $findings | Where-Object { [string]$_.Severity -in @('Error', 'ParseError') }
)
$warningFindings = @($findings | Where-Object { [string]$_.Severity -eq 'Warning' })

Write-Host ("PSScriptAnalyzer checked {0} file(s): {1} error(s), {2} warning(s)." -f $sourceFiles.Count, $errorFindings.Count, $warningFindings.Count)

if ($errorFindings.Count -gt 0) {
    exit 1
}

exit 0
