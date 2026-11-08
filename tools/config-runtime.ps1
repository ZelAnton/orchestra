<#
.SYNOPSIS
    Reads effective Orchestra settings and manages the editable project config.

.DESCRIPTION
    Project settings are resolved from <project>/.work/config.md, then
    ~/.orchestra/root-config.md, then the caller's supplied default. Root-only
    provider and machine settings are always read from root-config.md.

    The seed-project action creates an inactive project configuration from the marked
    block in config.example.md. Every project key remains commented, carries Default,
    Values and Effect help, and receives a generated Root config comment showing the
    current user-global value (or that it is not set). The template is checked against
    policy-schema.ps1 before it is written, so a missing key or incomplete help block
    fails closed.

    The edit-project action opens .work/config.md in an operator-selected console editor.
    VISUAL wins over EDITOR; otherwise a platform-appropriate console editor is discovered.
    The editor inherits the terminal and the action waits for it to exit.
#>

[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0)]
    [ValidateSet('get', 'seed-project', 'edit-project')]
    [string]$Action = 'get',
    [string]$Work = (Join-Path (Get-Location).Path '.work'),
    [string]$Key = '',
    [AllowEmptyString()][string]$Default = '',
    [string]$Template = '',
    [string]$Output = '',
    [string]$RootConfig = '',
    [string]$Config = '',
    [string]$Editor = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

function Get-ProjectSeed {
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$RootConfigPath
    )

    $schemaPath = Resolve-OrchestraSharedScript -Name 'policy-schema.ps1'
    . $schemaPath
    $schemaKeys = @(Get-SchemaConfigKeys)
    $lines = @([System.IO.File]::ReadAllLines($TemplatePath, [System.Text.Encoding]::UTF8))
    $startIndexes = @(for ($i = 0; $i -lt $lines.Count; $i++) {
            if ([string]$lines[$i] -match '^# >>> config\.md seed start') { $i }
        })
    $endIndexes = @(for ($i = 0; $i -lt $lines.Count; $i++) {
            if ([string]$lines[$i] -match '^# <<< config\.md seed end') { $i }
        })
    if ($startIndexes.Count -ne 1 -or $endIndexes.Count -ne 1 -or
        $endIndexes[0] -le ($startIndexes[0] + 1)) {
        throw 'config.example.md must contain exactly one non-empty config.md seed start/end block'
    }

    $seed = @($lines[($startIndexes[0] + 1)..($endIndexes[0] - 1)])
    $active = @($seed | Where-Object { [string]$_ -match '^\s*[A-Z][A-Z0-9_]*\s*:' })
    if ($active.Count -gt 0) {
        throw "config.md seed contains active settings; every project key must be commented: $($active[0])"
    }

    $headers = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $seed.Count; $i++) {
        $match = [regex]::Match([string]$seed[$i], '^# ([A-Z][A-Z0-9_]+):\s*(.*?)\s*$')
        if ($match.Success) {
            $headers.Add([pscustomobject]@{
                    Name = $match.Groups[1].Value
                    Example = $match.Groups[2].Value
                    Index = $i
                })
        }
    }

    $expectedNames = @($schemaKeys | ForEach-Object { [string]$_.name })
    $actualNames = @($headers | ForEach-Object { [string]$_.Name })
    if (($actualNames -join "`n") -cne ($expectedNames -join "`n")) {
        throw ('config.md seed key order/content differs from policy schema; expected [{0}], found [{1}]' -f
            ($expectedNames -join ', '), ($actualNames -join ', '))
    }

    for ($i = 0; $i -lt $headers.Count; $i++) {
        $from = $headers[$i].Index + 1
        $to = if ($i + 1 -lt $headers.Count) { $headers[$i + 1].Index - 1 } else { $seed.Count - 1 }
        $help = if ($from -le $to) { @($seed[$from..$to]) } else { @() }
        $descriptor = $schemaKeys[$i]
        $defaultLine = @($help | Where-Object { [string]$_ -match '^#\s{3}Default:\s*(.*?)\s*$' })
        $valuesLine = @($help | Where-Object { [string]$_ -match '^#\s{3}Values:\s*\S' })
        $effectLine = @($help | Where-Object { [string]$_ -match '^#\s{3}Effect:\s*\S' })
        if ($defaultLine.Count -ne 1 -or $valuesLine.Count -ne 1 -or $effectLine.Count -ne 1) {
            throw "config.md seed help for $($headers[$i].Name) must contain one non-empty Default, Values and Effect line"
        }
        $documentedDefault = ([regex]::Match([string]$defaultLine[0], '^#\s{3}Default:\s*(.*?)\s*$')).Groups[1].Value
        if ($documentedDefault -cne [string]$descriptor.default) {
            throw "config.md seed default for $($headers[$i].Name) is '$documentedDefault'; schema default is '$($descriptor.default)'"
        }
    }

    $rendered = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $seed) {
        $rendered.Add([string]$line)
        $match = [regex]::Match([string]$line, '^# ([A-Z][A-Z0-9_]+):')
        if ($match.Success) {
            $rootValue = Get-OrchestraConfigValueFromFile -Path $RootConfigPath -Key $match.Groups[1].Value
            if ([string]::IsNullOrWhiteSpace($rootValue)) {
                $rendered.Add('#   Root config: not set')
            } else {
                $rendered.Add('#   Root config: ' + $rootValue)
            }
        }
    }
    return @($rendered)
}

function Write-ProjectSeed {
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$RootConfigPath
    )

    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
        throw "config template is not a regular file: $TemplatePath"
    }
    if (Test-Path -LiteralPath $OutputPath) {
        throw "refusing to overwrite existing project config: $OutputPath"
    }
    $parent = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetFullPath($parent))
    }
    $seed = @(Get-ProjectSeed -TemplatePath $TemplatePath -RootConfigPath $RootConfigPath)
    $encoding = [System.Text.UTF8Encoding]::new($false)
    $newline = [Environment]::NewLine
    $text = ($seed -join $newline) + $newline
    $tempPath = $OutputPath + '.tmp.' + [guid]::NewGuid().ToString('N')
    try {
        [System.IO.File]::WriteAllText($tempPath, $text, $encoding)
        [System.IO.File]::Move($tempPath, $OutputPath)
    } finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Resolve-ConfigEditor {
    param([string]$RequestedEditor)

    $requested = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($RequestedEditor)) {
        $requested.Add($RequestedEditor.Trim())
    } else {
        foreach ($name in @('VISUAL', 'EDITOR')) {
            $value = [Environment]::GetEnvironmentVariable($name)
            if (-not [string]::IsNullOrWhiteSpace($value)) { $requested.Add($value.Trim()) }
        }
    }

    $onWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    $candidates = if ($requested.Count -gt 0) {
        @($requested)
    } elseif ($onWindows) {
        @('nvim.exe', 'vim.exe', 'nano.exe')
    } else {
        @('nano', 'nvim', 'vim', 'vi')
    }
    foreach ($candidate in $candidates) {
        $command = @(Get-Command $candidate -CommandType Application, ExternalScript -ErrorAction SilentlyContinue) |
            Select-Object -First 1
        if ($command) { return [string]$command.Source }
    }

    if ($requested.Count -gt 0) {
        throw "configured editor '$($requested[0])' was not found; VISUAL/EDITOR must name an executable without arguments"
    }
    throw 'no text editor found; set VISUAL or EDITOR to a console editor executable'
}

function Invoke-ConfigEditor {
    param([Parameter(Mandatory)][string]$ConfigPath, [string]$RequestedEditor)

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "project config is not a regular file: $ConfigPath"
    }
    $resolvedConfig = [System.IO.Path]::GetFullPath($ConfigPath)
    $resolvedEditor = Resolve-ConfigEditor -RequestedEditor $RequestedEditor
    [Console]::Out.WriteLine("Opening $resolvedConfig with $resolvedEditor ...")
    $global:LASTEXITCODE = 0
    & $resolvedEditor $resolvedConfig
    $editorExit = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($editorExit -ne 0) {
        [Console]::Error.WriteLine("Editor exited with code ${editorExit}: $resolvedEditor")
        exit $editorExit
    }
}

switch ($Action) {
    'get' {
        if ([string]::IsNullOrWhiteSpace($Key)) { throw 'get requires -Key' }
        $value = Get-OrchestraConfigValue -Work $Work -Key $Key -Default $Default
        [Console]::Out.WriteLine($value)
    }
    'seed-project' {
        if ([string]::IsNullOrWhiteSpace($Template) -or [string]::IsNullOrWhiteSpace($Output)) {
            [Console]::Error.WriteLine('seed-project requires -Template and -Output')
            exit 2
        }
        if ([string]::IsNullOrWhiteSpace($RootConfig)) { $RootConfig = Get-OrchestraRootConfigPath }
        try {
            Write-ProjectSeed -TemplatePath $Template -OutputPath $Output -RootConfigPath $RootConfig
        } catch {
            [Console]::Error.WriteLine('Failed to seed project config: ' + $_.Exception.Message)
            exit 2
        }
    }
    'edit-project' {
        if ([string]::IsNullOrWhiteSpace($Config)) { $Config = Join-Path $Work 'config.md' }
        try {
            Invoke-ConfigEditor -ConfigPath $Config -RequestedEditor $Editor
        } catch {
            [Console]::Error.WriteLine('Failed to open project config: ' + $_.Exception.Message)
            exit 4
        }
    }
}
