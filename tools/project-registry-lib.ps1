<#
.SYNOPSIS
    Shared project-registry primitives for project-registry.ps1 and inbox.ps1.

.DESCRIPTION
    Orchestra keeps one user-global registry at ~/.orchestra/projects.json so a
    configured repository can address another configured repository without scanning
    the filesystem. The registry contains trusted local roots and stable path-derived
    ids. All mutations use the shared CreateNew lock and atomic-write primitives from
    tools/common.ps1.

    This is a pure dot-sourced library. The sourcing tool must load common.ps1 first and
    set its own error-prefix/lock-name variables.
#>

function Test-OrchestraWindows {
    return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Windows)
}

function Get-OrchestraRegistryPath {
    param([string]$ExplicitPath = '')
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        return [System.IO.Path]::GetFullPath($ExplicitPath)
    }
    $fromEnv = [string][Environment]::GetEnvironmentVariable('ORCHESTRA_REGISTRY_PATH')
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
        return [System.IO.Path]::GetFullPath($fromEnv)
    }
    $profileHome = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($profileHome)) { $profileHome = [string]$HOME }
    if ([string]::IsNullOrWhiteSpace($profileHome)) { Fail 2 'cannot determine the user profile for the Orchestra project registry' }
    return (Join-Path (Join-Path $profileHome '.orchestra') 'projects.json')
}

function Resolve-OrchestraProjectRoot {
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        Fail 2 "project root is not an existing directory: $Root"
    }
    $resolved = (Resolve-Path -LiteralPath $Root).Path
    $full = [System.IO.Path]::GetFullPath($resolved)
    $trimmed = $full.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return $full }
    return $trimmed
}

function Normalize-OrchestraProjectRootPath {
    param([Parameter(Mandatory)][string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) { Fail 5 'project registry entry has an empty root' }
    $full = [System.IO.Path]::GetFullPath($Root)
    $trimmed = $full.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return $full }
    return $trimmed
}

function Get-OrchestraProjectId {
    param([Parameter(Mandatory)][string]$Root)
    $identity = if (Test-OrchestraWindows) { $Root.ToUpperInvariant() } else { $Root }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($identity)) }
    finally { $sha.Dispose() }
    $hex = -join ($hash | ForEach-Object { $_.ToString('x2') })
    return 'repo-' + $hex.Substring(0, 20)
}

function Get-OrchestraProjectName {
    param([Parameter(Mandatory)][string]$Root, [string]$Requested = '')
    $name = $Requested.Trim()
    if (-not $name) { $name = Split-Path -Leaf $Root }
    if (-not $name -or $name.Length -gt 120 -or $name -match '[\r\n]') {
        Fail 2 'project name must contain 1-120 characters and no line breaks'
    }
    return $name
}

function New-OrchestraRegistry {
    return [pscustomobject][ordered]@{
        schema     = 'orchestra/project-registry@1'
        generation = 0
        updated_at = $null
        projects   = @()
    }
}

function ConvertTo-OrchestraTimestampText {
    param($Value)
    if ($Value -is [datetime]) { return (Format-Utc ([datetime]$Value)) }
    if ($Value -is [datetimeoffset]) { return ([datetimeoffset]$Value).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
    return [string]$Value
}

function Read-OrchestraRegistry {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return (New-OrchestraRegistry) }
    try { $registry = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json }
    catch { Fail 5 "project registry is not valid JSON: $Path" }
    if ($null -eq $registry -or [string]$registry.schema -ne 'orchestra/project-registry@1') {
        Fail 5 "unsupported project registry schema in $Path"
    }
    if ($null -eq $registry.PSObject.Properties['projects']) { Fail 5 "project registry has no projects array: $Path" }
    $validated = [System.Collections.Generic.List[object]]::new()
    $seenIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($project in @($registry.projects)) {
        # Keep stale/moved entries visible in `list`; one missing repository must not make
        # the entire user registry unreadable. Commands that write to a project validate
        # its root and .inbox separately before touching it.
        $root = Normalize-OrchestraProjectRootPath ([string]$project.root)
        $expectedId = Get-OrchestraProjectId $root
        if ([string]$project.id -ne $expectedId) {
            Fail 5 "project registry entry id does not match its root: $([string]$project.id)"
        }
        if (-not $seenIds.Add($expectedId)) { Fail 5 "project registry contains a duplicate project id: $expectedId" }
        $validated.Add([pscustomobject][ordered]@{
            id                 = $expectedId
            name               = Get-OrchestraProjectName -Root $root -Requested ([string]$project.name)
            root               = $root
            registered_at      = ConvertTo-OrchestraTimestampText $project.registered_at
            last_configured_at = ConvertTo-OrchestraTimestampText $project.last_configured_at
        })
    }
    return [pscustomobject][ordered]@{
        schema      = 'orchestra/project-registry@1'
        generation  = if ($null -ne $registry.PSObject.Properties['generation']) { [int]$registry.generation } else { 0 }
        updated_at  = ConvertTo-OrchestraTimestampText $registry.updated_at
        projects    = @($validated.ToArray())
    }
}

function Write-OrchestraRegistry {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Registry)
    $Registry.projects = @($Registry.projects | Sort-Object name, id)
    Write-TextAtomic -Path $Path -Content ($Registry | ConvertTo-Json -Depth 8)
}

function Invoke-WithOrchestraRegistryLock {
    param([Parameter(Mandatory)][string]$RegistryPath, [Parameter(Mandatory)][scriptblock]$Body)
    $parent = Split-Path -Parent $RegistryPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Force -Path $parent
    }
    $lock = $RegistryPath + '.lock'
    Acquire-Lock -LockPath $lock -TimeoutMs 30000 -StaleMs 300000
    try { return (& $Body) }
    finally { Release-Lock -LockPath $lock }
}

function Ensure-OrchestraInbox {
    param([Parameter(Mandatory)][string]$Root)
    $inbox = Join-Path $Root '.inbox'
    if (-not (Test-Path -LiteralPath $inbox)) { $null = New-Item -ItemType Directory -Path $inbox }
    Assert-OrchestraPlainDirectory -Path $inbox -Label 'project inbox'
    $messages = Join-Path $inbox 'messages'
    if (-not (Test-Path -LiteralPath $messages)) { $null = New-Item -ItemType Directory -Path $messages }
    Assert-OrchestraPlainDirectory -Path $messages -Label 'project inbox messages'
    return $inbox
}

function Assert-OrchestraPlainDirectory {
    param([Parameter(Mandatory)][string]$Path, [string]$Label = 'directory')
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) { Fail 5 "$Label path is not a directory: $Path" }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail 5 "$Label path must not be a symlink or reparse point: $Path"
    }
}

function Register-OrchestraProject {
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)][string]$Root,
        [string]$Name = '',
        [switch]$EnsureInbox
    )
    $canonicalRoot = Resolve-OrchestraProjectRoot $Root
    $projectName = Get-OrchestraProjectName -Root $canonicalRoot -Requested $Name
    $id = Get-OrchestraProjectId $canonicalRoot
    if ($EnsureInbox) { $null = Ensure-OrchestraInbox $canonicalRoot }
    return Invoke-WithOrchestraRegistryLock -RegistryPath $RegistryPath -Body {
        $registry = Read-OrchestraRegistry $RegistryPath
        $now = Format-UtcNow
        $existing = @($registry.projects | Where-Object { [string]$_.id -eq $id }) | Select-Object -First 1
        if ($null -ne $existing) {
            $existing.name = $projectName
            $existing.root = $canonicalRoot
            $existing.last_configured_at = $now
            $project = $existing
        } else {
            $project = [pscustomobject][ordered]@{
                id                 = $id
                name               = $projectName
                root               = $canonicalRoot
                registered_at      = $now
                last_configured_at = $now
            }
            $registry.projects = @($registry.projects) + @($project)
        }
        $registry.generation = [int]$registry.generation + 1
        $registry.updated_at = $now
        Write-OrchestraRegistry -Path $RegistryPath -Registry $registry
        return $project
    }
}

function Resolve-OrchestraRegistryProject {
    param([Parameter(Mandatory)]$Registry, [Parameter(Mandatory)][string]$Selector)
    $projectMatches = @($Registry.projects | Where-Object {
        [string]$_.id -eq $Selector -or [string]::Equals([string]$_.name, $Selector, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($projectMatches.Count -eq 0) { Fail 4 "project is not registered: $Selector" }
    if ($projectMatches.Count -gt 1) {
        $ids = ($projectMatches | ForEach-Object { [string]$_.id }) -join ', '
        Fail 4 "project name is ambiguous; use one of these ids: $ids"
    }
    return $projectMatches[0]
}

function Get-OrchestraRegistryProjectByRoot {
    param([Parameter(Mandatory)]$Registry, [Parameter(Mandatory)][string]$Root)
    $canonicalRoot = Resolve-OrchestraProjectRoot $Root
    $id = Get-OrchestraProjectId $canonicalRoot
    $project = @($Registry.projects | Where-Object { [string]$_.id -eq $id }) | Select-Object -First 1
    if ($null -eq $project) { Fail 4 "current project is not registered; run cc-config from its root: $canonicalRoot" }
    return $project
}
