<#
.SYNOPSIS
    User-global registry of repositories configured for Orchestra.

.EXAMPLE
    pwsh -File tools/project-registry.ps1 register --root . --ensure-inbox
    pwsh -File tools/project-registry.ps1 list --json
    pwsh -File tools/project-registry.ps1 resolve --project repo-0123456789abcdef0123 --json
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'project-registry-lib.ps1')
$script:ErrPrefix = 'PRJERR'
$script:FaultEnv = 'PROJECT_REGISTRY_FAULT'
$script:LockName = 'project-registry'

$parsed = Parse-CliArgs $args -BoolFlags @('json', 'ensure-inbox')
$Command = $parsed.Command
$opts = $parsed.Opts

function Write-ProjectResult {
    param($Project, [string]$RegistryPath)
    if ([bool](Opt 'json' $false)) {
        [pscustomobject][ordered]@{ registry = $RegistryPath; project = $Project } | ConvertTo-Json -Depth 8
    } else {
        Write-Output "registered id=$($Project.id) name=$($Project.name) root=$($Project.root)"
        Write-Output "registry=$RegistryPath"
    }
}

try {
    $registryPath = Get-OrchestraRegistryPath ([string](Opt 'registry' ''))
    switch ($Command) {
        'register' {
            $root = Require-Opt 'root'
            $project = Register-OrchestraProject -RegistryPath $registryPath -Root $root `
                -Name ([string](Opt 'name' '')) -EnsureInbox:([bool](Opt 'ensure-inbox' $false))
            Write-ProjectResult -Project $project -RegistryPath $registryPath
        }
        'list' {
            $registry = Read-OrchestraRegistry $registryPath
            if ([bool](Opt 'json' $false)) { $registry | ConvertTo-Json -Depth 8 }
            else {
                Write-Output "registry=$registryPath generation=$($registry.generation) projects=$(@($registry.projects).Count)"
                foreach ($project in @($registry.projects)) { Write-Output "$($project.id)  $($project.name)  $($project.root)" }
            }
        }
        'resolve' {
            $selector = Require-Opt 'project'
            $registry = Read-OrchestraRegistry $registryPath
            $project = Resolve-OrchestraRegistryProject -Registry $registry -Selector $selector
            if ([bool](Opt 'json' $false)) { $project | ConvertTo-Json -Depth 5 }
            else { Write-Output "$($project.id)  $($project.name)  $($project.root)" }
        }
        'path' { Write-Output $registryPath }
        default { Fail 2 "unknown command '$Command' (expected register, list, resolve, or path)" }
    }
    exit 0
} catch {
    exit (Resolve-CatchExit $_ 'PRJERR' 'project-registry' 'PROJECT_REGISTRY_DEBUG')
}
