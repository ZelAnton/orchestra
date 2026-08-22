<#
.SYNOPSIS
    Reads the effective Orchestra configuration without consulting OS settings.

.DESCRIPTION
    Project settings are resolved from <project>/.work/config.md, then
    ~/.orchestra/root-config.md, then the caller's supplied default. Root-only
    provider and machine settings are always read from root-config.md.
#>

[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0)]
    [ValidateSet('get')]
    [string]$Action = 'get',
    [string]$Work = (Join-Path (Get-Location).Path '.work'),
    [Parameter(Mandatory)][string]$Key,
    [AllowEmptyString()][string]$Default = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

if ($Action -ne 'get') { throw "unsupported config action: $Action" }
$value = Get-OrchestraConfigValue -Work $Work -Key $Key -Default $Default
[Console]::Out.WriteLine($value)
