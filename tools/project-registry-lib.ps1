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
    if (-not $name -or $name.Length -gt 120 -or $name -match '[\x00-\x1f\x7f]') {
        Fail 2 'project name must contain 1-120 characters and no control characters'
    }
    return $name
}

function Normalize-OrchestraProductKey {
    param([Parameter(Mandatory)][string]$Value)
    $key = $Value.Trim()
    if ($key.Length -gt 240 -or $key -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}:[^\x00-\x1f\x7f:][^\x00-\x1f\x7f]{0,199}$') {
        Fail 2 "product identity must use ecosystem:name with no control characters: $Value"
    }
    $parts = $key.Split(':', 2)
    return ($parts[0].ToLowerInvariant() + ':' + $parts[1].Trim())
}

function Assert-OrchestraEvidenceText {
    param([Parameter(Mandatory)][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 500 -or $Value -match '[\x00-\x1f\x7f]') {
        Fail 2 'dependency evidence must contain 1-500 characters and no control characters'
    }
    return $Value.Trim()
}

function ConvertTo-OrchestraGraphGeneration {
    param($Value, [string]$Label = 'graph generation')
    [long]$parsed = 0
    if ($Value -is [string] -or -not [long]::TryParse(
            [string]$Value,
            [System.Globalization.NumberStyles]::Integer,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsed) -or $parsed -lt 0) {
        Fail 5 "$Label must be a non-negative JSON integer"
    }
    return $parsed
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
        $products = @()
        if ($null -ne $project.PSObject.Properties['products']) {
            $products = @($project.products | ForEach-Object { Normalize-OrchestraProductKey ([string]$_) } | Sort-Object -Unique)
        }
        if ($products.Count -gt 100) { Fail 5 "project registry entry has too many products: $expectedId" }
        $dependencies = [System.Collections.Generic.List[object]]::new()
        if ($null -ne $project.PSObject.Properties['dependencies']) {
            foreach ($dependency in @($project.dependencies)) {
                $upstreamId = [string]$dependency.upstream_id
                if ($upstreamId -notmatch '^repo-[a-f0-9]{20}$') { Fail 5 "project registry entry has an invalid upstream id: $expectedId" }
                $dependencyProducts = @()
                if ($null -ne $dependency.PSObject.Properties['products']) {
                    $dependencyProducts = @($dependency.products | ForEach-Object { Normalize-OrchestraProductKey ([string]$_) } | Sort-Object -Unique)
                }
                $evidence = @()
                if ($null -ne $dependency.PSObject.Properties['evidence']) {
                    $evidence = @($dependency.evidence | ForEach-Object { Assert-OrchestraEvidenceText ([string]$_) } | Sort-Object -Unique)
                }
                if ($dependencyProducts.Count -gt 100 -or $evidence.Count -gt 100) {
                    Fail 5 "project registry dependency metadata is too large: $expectedId -> $upstreamId"
                }
                $dependencies.Add([pscustomobject][ordered]@{
                    upstream_id = $upstreamId
                    products = $dependencyProducts
                    evidence = $evidence
                })
            }
        }
        if ($dependencies.Count -gt 100) { Fail 5 "project registry entry has too many dependencies: $expectedId" }
        $validated.Add([pscustomobject][ordered]@{
            id                 = $expectedId
            name               = Get-OrchestraProjectName -Root $root -Requested ([string]$project.name)
            root               = $root
            registered_at      = ConvertTo-OrchestraTimestampText $project.registered_at
            last_configured_at = ConvertTo-OrchestraTimestampText $project.last_configured_at
            products           = $products
            dependencies       = @($dependencies.ToArray() | Sort-Object upstream_id)
            graph_updated_at   = if ($null -ne $project.PSObject.Properties['graph_updated_at']) { ConvertTo-OrchestraTimestampText $project.graph_updated_at } else { '' }
            graph_generation   = if ($null -ne $project.PSObject.Properties['graph_generation']) { ConvertTo-OrchestraGraphGeneration $project.graph_generation 'project graph_generation' } else { 0 }
        })
    }
    foreach ($project in @($validated.ToArray())) {
        $seenUpstreams = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($dependency in @($project.dependencies)) {
            $upstreamId = [string]$dependency.upstream_id
            if ($upstreamId -eq [string]$project.id) { Fail 5 "project registry contains a self dependency: $upstreamId" }
            if (-not $seenIds.Contains($upstreamId)) { Fail 5 "project registry dependency targets an unknown project: $upstreamId" }
            if (-not $seenUpstreams.Add($upstreamId)) { Fail 5 "project registry contains a duplicate dependency: $($project.id) -> $upstreamId" }
        }
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
    $releases = Join-Path $inbox 'releases'
    if (-not (Test-Path -LiteralPath $releases)) { $null = New-Item -ItemType Directory -Path $releases }
    Assert-OrchestraPlainDirectory -Path $releases -Label 'project inbox releases'
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

function Assert-OrchestraPlainFile {
    param([Parameter(Mandatory)][string]$Path, [string]$Label = 'file')
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer) { Fail 5 "$Label path is not a file: $Path" }
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
    return Invoke-WithOrchestraRegistryLock -RegistryPath $RegistryPath -Body {
        # Serialize inbox initialization with registration as one user-global
        # transaction. Concurrent cc-config calls must not race two check/create pairs.
        if ($EnsureInbox) { $null = Ensure-OrchestraInbox $canonicalRoot }
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
                products           = @()
                dependencies       = @()
                graph_updated_at   = ''
                graph_generation   = 0
            }
            $registry.projects = @($registry.projects) + @($project)
        }
        $registry.generation = [int]$registry.generation + 1
        $registry.updated_at = $now
        Write-OrchestraRegistry -Path $RegistryPath -Registry $registry
        return $project
    }
}

function Unregister-OrchestraProject {
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)][string]$Selector,
        [switch]$DetachDependents
    )
    return Invoke-WithOrchestraRegistryLock -RegistryPath $RegistryPath -Body {
        $registry = Read-OrchestraRegistry $RegistryPath
        $project = Resolve-OrchestraRegistryProject -Registry $registry -Selector $Selector
        $dependents = @($registry.projects | Where-Object {
            @($_.dependencies | Where-Object { [string]$_.upstream_id -eq [string]$project.id }).Count -gt 0
        } | Sort-Object name, id)
        if ($dependents.Count -gt 0 -and -not $DetachDependents) {
            $names = @($dependents | ForEach-Object { "{0} ({1})" -f $_.name, $_.id }) -join ', '
            Fail 6 "cannot unregister $($project.id): it remains an upstream for $names; rerun with --detach-dependents after confirming those graph edges are obsolete"
        }

        $now = Format-UtcNow
        $detached = [System.Collections.Generic.List[object]]::new()
        foreach ($dependent in $dependents) {
            $dependent.dependencies = @($dependent.dependencies | Where-Object { [string]$_.upstream_id -ne [string]$project.id })
            $dependent.graph_generation = [long]$dependent.graph_generation + 1
            $dependent.graph_updated_at = $now
            $detached.Add([pscustomobject][ordered]@{ id = [string]$dependent.id; name = [string]$dependent.name })
        }
        $registry.projects = @($registry.projects | Where-Object { [string]$_.id -ne [string]$project.id })
        $registry.generation = [int]$registry.generation + 1
        $registry.updated_at = $now
        Write-OrchestraRegistry -Path $RegistryPath -Registry $registry
        return [pscustomobject][ordered]@{
            project = $project
            detached_dependents = @($detached.ToArray())
        }
    }
}

function Read-OrchestraGraphSnapshot {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Registry, [Parameter(Mandatory)][string]$ProjectId)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Fail 2 "dependency graph snapshot not found: $Path" }
    Assert-OrchestraPlainFile -Path $Path -Label 'dependency graph snapshot'
    try { $snapshot = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json }
    catch { Fail 5 "dependency graph snapshot is not valid JSON: $Path" }
    if ([string]$snapshot.schema -ne 'orchestra/project-graph-snapshot@1') {
        Fail 5 "unsupported dependency graph snapshot schema: $Path"
    }
    $baseGenerationProperty = $snapshot.PSObject.Properties['base_graph_generation']
    if ($null -eq $baseGenerationProperty) {
        Fail 5 "dependency graph snapshot requires 'base_graph_generation': $Path"
    }
    $baseGraphGeneration = ConvertTo-OrchestraGraphGeneration $baseGenerationProperty.Value 'base_graph_generation'
    foreach ($requiredArray in @('products', 'dependencies')) {
        $property = $snapshot.PSObject.Properties[$requiredArray]
        if ($null -eq $property -or $property.Value -isnot [System.Array]) {
            Fail 5 "dependency graph snapshot requires a JSON array '$requiredArray': $Path"
        }
    }
    $products = @($snapshot.products | ForEach-Object { Normalize-OrchestraProductKey ([string]$_) } | Sort-Object -Unique)
    if ($products.Count -gt 100) { Fail 2 'dependency graph snapshot has more than 100 products' }
    $dependencies = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in @($snapshot.dependencies)) {
        if ($null -eq $item -or $item -isnot [psobject]) {
            Fail 5 "dependency graph snapshot contains a non-object dependency: $Path"
        }
        foreach ($requiredProperty in @('upstream', 'products', 'evidence')) {
            $property = $item.PSObject.Properties[$requiredProperty]
            if ($null -eq $property) {
                Fail 5 "dependency graph entry requires '$requiredProperty': $Path"
            }
            if ($requiredProperty -ne 'upstream' -and $property.Value -isnot [System.Array]) {
                Fail 5 "dependency graph entry requires a JSON array '$requiredProperty': $Path"
            }
        }
        $selector = [string]$item.upstream
        if ([string]::IsNullOrWhiteSpace($selector)) { Fail 2 'dependency graph entry requires upstream project id or name' }
        $upstream = Resolve-OrchestraRegistryProject -Registry $Registry -Selector $selector
        if ([string]$upstream.id -eq $ProjectId) { Fail 2 'dependency graph cannot contain the current project as its own upstream' }
        if (-not $seen.Add([string]$upstream.id)) { Fail 2 "dependency graph contains a duplicate upstream: $selector" }
        $dependencyProducts = @($item.products | ForEach-Object { Normalize-OrchestraProductKey ([string]$_) } | Sort-Object -Unique)
        $evidence = @($item.evidence | ForEach-Object { Assert-OrchestraEvidenceText ([string]$_) } | Sort-Object -Unique)
        if ($dependencyProducts.Count -gt 100 -or $evidence.Count -gt 100) { Fail 2 "dependency graph metadata is too large: $selector" }
        $dependencies.Add([pscustomobject][ordered]@{
            upstream_id = [string]$upstream.id
            products = $dependencyProducts
            evidence = $evidence
        })
    }
    if ($dependencies.Count -gt 100) { Fail 2 'dependency graph snapshot has more than 100 upstream projects' }
    return [pscustomobject][ordered]@{
        schema = 'orchestra/project-graph-snapshot@1'
        base_graph_generation = $baseGraphGeneration
        products = $products
        dependencies = @($dependencies.ToArray() | Sort-Object upstream_id)
    }
}

function Sync-OrchestraProjectGraph {
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$SnapshotPath
    )
    $canonicalRoot = Resolve-OrchestraProjectRoot $Root
    return Invoke-WithOrchestraRegistryLock -RegistryPath $RegistryPath -Body {
        $registry = Read-OrchestraRegistry $RegistryPath
        $project = Get-OrchestraRegistryProjectByRoot -Registry $registry -Root $canonicalRoot
        $snapshot = Read-OrchestraGraphSnapshot -Path $SnapshotPath -Registry $registry -ProjectId ([string]$project.id)
        $currentCanonical = [pscustomobject][ordered]@{
            schema = 'orchestra/project-graph-snapshot@1'
            products = @($project.products)
            dependencies = @($project.dependencies)
        } | ConvertTo-Json -Depth 8 -Compress
        $nextCanonical = [pscustomobject][ordered]@{
            schema = 'orchestra/project-graph-snapshot@1'
            products = @($snapshot.products)
            dependencies = @($snapshot.dependencies)
        } | ConvertTo-Json -Depth 8 -Compress
        $changed = $currentCanonical -ne $nextCanonical
        if ($changed) {
            if ([long]$snapshot.base_graph_generation -ne [long]$project.graph_generation) {
                Fail 6 "dependency graph changed during audit (expected generation $($snapshot.base_graph_generation), current $($project.graph_generation)); rerun the refresh"
            }
            $project.products = @($snapshot.products)
            $project.dependencies = @($snapshot.dependencies)
            $project.graph_updated_at = Format-UtcNow
            $project.graph_generation = [long]$project.graph_generation + 1
            $registry.generation = [int]$registry.generation + 1
            $registry.updated_at = $project.graph_updated_at
            Write-OrchestraRegistry -Path $RegistryPath -Registry $registry
        }
        return [pscustomobject][ordered]@{
            changed = $changed
            project = $project
            products = @($project.products)
            dependencies = @($project.dependencies)
        }
    }
}

function Get-OrchestraProjectDependents {
    param([Parameter(Mandatory)]$Registry, [Parameter(Mandatory)][string]$UpstreamId, [string[]]$Products = @())
    $productSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($product in @($Products)) { [void]$productSet.Add((Normalize-OrchestraProductKey ([string]$product))) }
    return @($Registry.projects | Where-Object {
        $edge = @($_.dependencies | Where-Object { [string]$_.upstream_id -eq $UpstreamId }) | Select-Object -First 1
        if ($null -eq $edge) { return $false }
        if ($productSet.Count -eq 0 -or @($edge.products).Count -eq 0) { return $true }
        foreach ($edgeProduct in @($edge.products)) {
            if ($productSet.Contains((Normalize-OrchestraProductKey ([string]$edgeProduct)))) { return $true }
        }
        return $false
    } | Sort-Object name, id)
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
