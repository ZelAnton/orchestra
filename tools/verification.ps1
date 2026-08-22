<#
.SYNOPSIS
    SHA-bound pre-publication verification profile runner (T-270).

.DESCRIPTION
    Reads VERIFICATION_MODE / VERIFICATION_COMMANDS from .work/config.md, with SMOKE_CMD
    as a backward-compatible one-command profile. `run` executes every configured command
    through tools/supervisor.ps1 and atomically records an exact-command, exact-head verdict.
    `check` is the crash-recovery/publish gate: only a terminal pass/exempt verdict for the
    current profile fingerprint, environment and requested VCS head is accepted.
    `check --require-pass` is the stricter expensive-command reuse gate: exemptions and any
    non-terminal/non-green supervisor result are rejected. VERIFICATION_MODE defaults to
    `disabled` when unset (unconfigured projects are exempt as `operator-disabled`, not
    silently skipped and not blocked); set `VERIFICATION_MODE: auto` or `required` to opt
    into the stricter "missing profile blocks executable changes" behavior. A mechanically
    detected docs-only diff is always recorded as an explicit `exempt/docs-only`, never as
    "not checked".

.EXAMPLE
    pwsh -File tools/verification.ps1 profile --work .work --json
    pwsh -File tools/verification.ps1 run --work .work --root .work/worktrees/_integration --vcs git --base <sha> --head <sha>
    pwsh -File tools/verification.ps1 check --work .work --root .work/worktrees/_integration --vcs git --head <sha>
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { $null = $_ }

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'processkit-runtime.ps1')
$script:ErrPrefix = 'VERERR'
$script:LockName = 'verification-run'
$parsed = Parse-CliArgs $args -BoolFlags @('json', 'require-pass')
$Command = $parsed.Command
$opts = $parsed.Opts
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)

function Get-Opt { param([string]$Name, [string]$Default = '') if ($opts.ContainsKey($Name)) { return [string]$opts[$Name] } return $Default }
function Get-RequiredOption { param([string]$Name) $v = Get-Opt $Name; if ([string]::IsNullOrWhiteSpace($v)) { Fail 2 "missing --$Name" }; return $v }
function Write-JsonAtomic {
    param([string]$Path, $Value)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, ($Value | ConvertTo-Json -Depth 12), $script:Utf8)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Get-Sha256Text {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bytes = $script:Utf8.GetBytes($Text); $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    return -join ($hash | ForEach-Object { $_.ToString('x2') })
}
function Get-Sha256File {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try { $hash = $sha.ComputeHash($stream) } finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
    return -join ($hash | ForEach-Object { $_.ToString('x2') })
}
function Get-RecordProp {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) {
        $value = $Object[$Name]
        if ($value -is [System.Array]) {
            Write-Output -NoEnumerate $value
        } else {
            return $value
        }
        return
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    if ($property.Value -is [System.Array]) {
        Write-Output -NoEnumerate $property.Value
    } else {
        return $property.Value
    }
}
function Test-JsonObject {
    param($Value)
    return ($null -ne $Value -and $Value.GetType() -eq [System.Management.Automation.PSCustomObject])
}
function Test-JsonArray {
    param($Value)
    return ($null -ne $Value -and $Value -is [System.Array])
}
function Test-JsonString {
    param($Value)
    return ($null -ne $Value -and $Value.GetType() -eq [string])
}
function Test-JsonIntegerInRange {
    param($Value, [decimal]$Minimum, [decimal]$Maximum)
    if ($null -eq $Value) { return $false }
    $integralTypes = @(
        [sbyte], [byte], [int16], [uint16],
        [int32], [uint32], [int64], [uint64]
    )
    if ($integralTypes -notcontains $Value.GetType()) { return $false }
    $number = [decimal]$Value
    return ($number -ge $Minimum -and $number -le $Maximum)
}
function Test-TerminalSupervisorRecord {
    param($Record, [string]$SurvivorsProperty)
    if (-not (Test-JsonObject $Record)) { return $false }
    $reason = Get-RecordProp $Record 'reason'
    $exitCode = Get-RecordProp $Record 'exit_code'
    $survivors = Get-RecordProp $Record $SurvivorsProperty
    $cleanupAttempted = Get-RecordProp $Record 'cleanup_attempted'
    return (
        (Test-JsonString $reason) -and $reason -ceq 'ok' -and
        (Test-JsonIntegerInRange $exitCode ([int]::MinValue) ([int]::MaxValue)) -and
            [decimal]$exitCode -eq 0 -and
        (Test-JsonIntegerInRange $survivors 0 ([int]::MaxValue)) -and
            [decimal]$survivors -eq 0 -and
        $null -ne $cleanupAttempted -and $cleanupAttempted.GetType() -eq [bool] -and
            $cleanupAttempted -eq $true
    )
}
function Test-VerificationEnvironmentRecord {
    param($Record, $Expected)
    if (-not (Test-JsonObject $Record)) { return $false }
    $stringFields = @(
        'os', 'os_description', 'process_architecture', 'powershell_edition',
        'powershell_version', 'powershell_host', 'execution_mode',
        'processkit_kind', 'processkit_version', 'supervisor_sha256'
    )
    foreach ($field in $stringFields) {
        $actualValue = Get-RecordProp $Record $field
        $expectedValue = Get-RecordProp $Expected $field
        if (-not (Test-JsonString $actualValue) -or
            -not (Test-JsonString $expectedValue) -or
            $actualValue -cne $expectedValue) {
            return $false
        }
    }
    $actualSchema = Get-RecordProp $Record 'processkit_schema'
    $expectedSchema = Get-RecordProp $Expected 'processkit_schema'
    return (
        (Test-JsonIntegerInRange $actualSchema 0 ([int]::MaxValue)) -and
        (Test-JsonIntegerInRange $expectedSchema 0 ([int]::MaxValue)) -and
        [decimal]$actualSchema -eq [decimal]$expectedSchema
    )
}
function Get-EnvironmentProfile {
    $backend = Resolve-OrchestraProcessKitBackend
    $platform = if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Windows)) { 'windows' }
        elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
            [System.Runtime.InteropServices.OSPlatform]::Linux)) { 'linux' }
        elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
            [System.Runtime.InteropServices.OSPlatform]::OSX)) { 'macos' }
        else { 'unknown' }
    $containment = if ($backend.Kind -eq 'cli') { 'processkit-cli' }
        elseif ($backend.Kind -eq 'python') { 'processkit-python' }
        elseif ($platform -ne 'windows' -and
            (Get-Command setsid -CommandType Application -ErrorAction SilentlyContinue)) {
            'process-group'
        } else { 'pid-tree' }
    $hostPath = ([System.Diagnostics.Process]::GetCurrentProcess()).MainModule.FileName
    $safe = [ordered]@{
        os = $platform
        os_description = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
        process_architecture = [string][System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
        powershell_edition = [string]$PSVersionTable.PSEdition
        powershell_version = [string]$PSVersionTable.PSVersion
        powershell_host = [System.IO.Path]::GetFileName($hostPath)
        execution_mode = $containment
        processkit_kind = [string]$backend.Kind
        processkit_version = [string]$backend.Version
        processkit_schema = [int]$backend.SchemaVersion
        supervisor_sha256 = Get-Sha256File (Join-Path $PSScriptRoot 'supervisor.ps1')
    }
    $fingerprint = Get-Sha256Text ($safe | ConvertTo-Json -Compress -Depth 5)
    return [pscustomobject]@{ values = $safe; fingerprint = $fingerprint }
}
function Read-Config {
    param([string]$Work)
    $values = @{}
    $path = Join-Path $Work 'config.md'
    if (Test-Path -LiteralPath $path) {
        foreach ($raw in (Get-Content -LiteralPath $path -Encoding utf8)) {
            $entry = ConvertFrom-OrchestraConfigLine -Line ([string]$raw)
            if ($null -ne $entry -and -not [string]::IsNullOrWhiteSpace($entry.Value)) { $values[$entry.Key] = $entry.Value }
        }
    }
    foreach ($key in @('VERIFICATION_MODE', 'VERIFICATION_COMMANDS', 'SMOKE_CMD')) {
        if (-not $values.ContainsKey($key)) {
            $value = Get-OrchestraConfigValue -Work $Work -Key $key -Default ''
            if (-not [string]::IsNullOrWhiteSpace($value)) { $values[$key] = $value }
        }
    }
    return $values
}
function Get-Profile {
    param([string]$Work)
    $cfg = Read-Config $Work
    # VERIFICATION_MODE is unset for the overwhelming majority of projects that never
    # opted into this gate. Track whether it was written explicitly: an explicit
    # `auto`/`required` still enforces the strict "missing profile blocks" behavior
    # below, but when the key is absent entirely we fall back to 'auto' for the
    # purpose of still honoring a configured VERIFICATION_COMMANDS/SMOKE_CMD (that is
    # an unambiguous signal of intent to verify), and only turn a resulting "nothing
    # configured" state into a disabled/exempt default a few lines down.
    $modeExplicit = $cfg.ContainsKey('VERIFICATION_MODE') -and $cfg['VERIFICATION_MODE']
    $mode = if ($modeExplicit) { [string]$cfg['VERIFICATION_MODE'] } else { 'auto' }
    if ($mode -notin @('auto', 'required', 'disabled')) { Fail 2 "VERIFICATION_MODE must be auto|required|disabled (got '$mode')" }
    $commands = @()
    $source = 'none'
    if ($cfg.ContainsKey('VERIFICATION_COMMANDS') -and $cfg['VERIFICATION_COMMANDS']) {
        try { $decoded = $cfg['VERIFICATION_COMMANDS'] | ConvertFrom-Json } catch { Fail 2 'VERIFICATION_COMMANDS must be a JSON array of non-empty strings' }
        if ($decoded -isnot [array]) { $decoded = @($decoded) }
        $commands = @($decoded | ForEach-Object { [string]$_ })
        if ($commands.Count -eq 0 -or @($commands | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) { Fail 2 'VERIFICATION_COMMANDS must be a non-empty JSON array of non-empty strings' }
        $source = 'VERIFICATION_COMMANDS'
    } elseif ($cfg.ContainsKey('SMOKE_CMD') -and -not [string]::IsNullOrWhiteSpace([string]$cfg['SMOKE_CMD'])) {
        $commands = @([string]$cfg['SMOKE_CMD'])
        $source = 'SMOKE_CMD'
    }
    $state = if ($mode -eq 'disabled') { 'disabled' } elseif ($commands.Count -gt 0) { 'configured' } else { 'missing' }
    if ($mode -eq 'required' -and $commands.Count -eq 0) { $state = 'missing' }
    # An explicit `VERIFICATION_MODE: disabled` is a deliberate operator override and
    # always wins as exempt/operator-disabled, even over a mechanically detected
    # docs-only diff (the caller checks this flag before deciding exemption order).
    $explicitDisabled = ($state -eq 'disabled' -and $modeExplicit)
    if ($state -eq 'missing' -and -not $modeExplicit) {
        # Nothing at all is configured (no VERIFICATION_MODE, no VERIFICATION_COMMANDS,
        # no SMOKE_CMD): default to disabled/exempt rather than blocking publication.
        # Writing `VERIFICATION_MODE: auto` or `required` explicitly opts back into the
        # strict "missing profile blocks executable changes" behavior. Unlike an
        # explicit disable, this implicit default yields priority to a mechanically
        # detected docs-only diff (see $explicitDisabled above).
        $state = 'disabled'
        $mode = 'disabled'
    }
    $environment = Get-EnvironmentProfile
    $canonical = [ordered]@{
        mode = $mode
        source = $source
        commands = @($commands)
        environment_fingerprint = $environment.fingerprint
    }
    $fingerprint = Get-Sha256Text ($canonical | ConvertTo-Json -Compress -Depth 5)
    return [pscustomobject]@{
        mode = $mode
        state = $state
        source = $source
        commands = @($commands)
        fingerprint = $fingerprint
        explicitDisabled = $explicitDisabled
        environment = $environment.values
        environmentFingerprint = $environment.fingerprint
    }
}
function Resolve-VerificationHead {
    param([string]$Root, [string]$Vcs, [string]$Revision = '')
    if ($Vcs -eq 'jj') {
        $selector = if ($Revision) { $Revision } else { '@' }
        $out = @(& jj -R $Root log -r $selector --no-graph -T 'commit_id ++ "\n"' 2>&1)
    } elseif ($Vcs -eq 'git') {
        $selector = if ($Revision) { "$Revision^{commit}" } else { 'HEAD' }
        $out = @(& git -C $Root rev-parse $selector 2>&1)
    } else { Fail 2 "--vcs must be git or jj (got '$Vcs')" }
    if ($LASTEXITCODE -ne 0) { Fail 2 "cannot resolve $Vcs revision '$selector' under '$Root': $($out -join ' ')" }
    $ids = @($out | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($ids.Count -ne 1 -or [string]$ids[0] -cnotmatch '^[0-9a-f]{40,64}$') {
        Fail 2 "revision '$selector' must resolve to exactly one full commit id"
    }
    return [string]$ids[0]
}
function Get-ChangedPathList {
    param([string]$Root, [string]$Vcs, [string]$Base, [string]$Head)
    if (-not $Base) { return @() }
    if ($Vcs -eq 'jj') { $out = @(& jj -R $Root diff --from $Base --to $Head --name-only 2>&1) }
    else { $out = @(& git -C $Root diff --name-only $Base $Head 2>&1) }
    if ($LASTEXITCODE -ne 0) { Fail 2 "cannot determine changed paths for verification: $($out -join ' ')" }
    return @($out | ForEach-Object { ([string]$_).Trim().Replace('\', '/') } | Where-Object { $_ })
}
function Test-DocsOnly {
    param([string[]]$Paths)
    if ($Paths.Count -eq 0) { return $false }
    foreach ($path in $Paths) {
        if ($path -match '(^|/)docs/' -or $path -match '(^|/)(README|CHANGELOG|CONTRIBUTING|LICENSE|AGENTS|CLAUDE)(\.[^/]+)?$' -or $path -match '\.md$') { continue }
        return $false
    }
    return $true
}
function ConvertTo-VerificationRecord {
    param($VerificationProfile, [string]$Head, [string]$Base, [string]$Verdict, [string]$Exemption, [object[]]$Runs)
    return [ordered]@{
        schema = 'orchestra/verification@2'; verdict = $Verdict; verified_head = $Head; base = $Base
        profile_fingerprint = $VerificationProfile.fingerprint; profile_state = $VerificationProfile.state; profile_source = $VerificationProfile.source
        environment_fingerprint = $VerificationProfile.environmentFingerprint
        environment = $VerificationProfile.environment
        commands = @($Runs); exemption = $Exemption; updated_at = (Format-UtcNow)
    }
}
function Emit { param($Value) if ($opts.ContainsKey('json')) { $Value | ConvertTo-Json -Compress -Depth 12 } else { Write-Output ("verification {0} head={1} source={2}" -f $Value.verdict,$Value.verified_head,$Value.profile_source) } }

function Invoke-ProfileCommand {
    $verificationProfile = Get-Profile (Get-RequiredOption 'work')
    if ($opts.ContainsKey('json')) { $verificationProfile | ConvertTo-Json -Compress -Depth 8 } else { Write-Output ("verification-profile state={0} mode={1} source={2} commands={3}" -f $verificationProfile.state,$verificationProfile.mode,$verificationProfile.source,$verificationProfile.commands.Count) }
}
function Invoke-RunCommand {
    $work = Get-RequiredOption 'work'; $configRoot = Get-Opt 'config-root' $work
    $root = Get-RequiredOption 'root'; $vcs = Get-RequiredOption 'vcs'; $expectedHead = Get-RequiredOption 'head'; $base = Get-Opt 'base'; $revision = Get-Opt 'revision'
    $resultFile = Get-Opt 'result-file' (Join-Path $work 'verification.json')
    $deadlineSec = Parse-IntOpt 'deadline-sec' 1800 0; $deadline = [string]$deadlineSec
    $maxBytes = Get-Opt 'output-max-bytes' '1048576'
    $head = Resolve-VerificationHead $root $vcs $revision
    if ($head -ne $expectedHead) { Fail 3 "verification head mismatch: expected '$expectedHead', current '$head'" }
    $verificationProfile = Get-Profile $configRoot
    $resultFull = [System.IO.Path]::GetFullPath($resultFile)
    $resultParent = Split-Path -Parent $resultFull
    if ($resultParent -and -not (Test-Path -LiteralPath $resultParent)) {
        [void][System.IO.Directory]::CreateDirectory($resultParent)
    }
    $runLock = "$resultFull.run.lock"
    $commandCount = [math]::Max(1, @($verificationProfile.commands).Count)
    $staleSec = if ($deadlineSec -gt 0) {
        ([long]$deadlineSec * $commandCount) + 300L
    } else {
        86400L
    }
    $staleMs = [int][math]::Min([long][int]::MaxValue, ($staleSec * 1000L))
    try {
        Acquire-Lock -LockPath $runLock -TimeoutMs 1000 -StaleMs $staleMs
    } catch {
        $message = [string]$_.Exception.Message
        if ($message.StartsWith("$($script:ErrPrefix)|7|", [System.StringComparison]::Ordinal)) {
            Fail 2 'verification run already active for the requested --result-file'
        }
        throw
    }
    try {
        $paths = @(Get-ChangedPathList $root $vcs $base $head)
        $docsOnly = Test-DocsOnly $paths
        # An explicit `VERIFICATION_MODE: disabled` is a deliberate operator override and
        # always wins, unconditionally, over a mechanically detected docs-only diff. The
        # implicit "nothing configured at all" default (see Get-Profile) instead yields
        # priority to the more specific docs-only exemption when both apply.
        if ($verificationProfile.state -eq 'disabled' -and $verificationProfile.explicitDisabled) {
            $record = ConvertTo-VerificationRecord $verificationProfile $head $base 'exempt' 'operator-disabled' @(); Write-JsonAtomic $resultFile $record; Emit $record; return
        }
        if ($docsOnly) {
            $record = ConvertTo-VerificationRecord $verificationProfile $head $base 'exempt' 'docs-only' @(); Write-JsonAtomic $resultFile $record; Emit $record; return
        }
        if ($verificationProfile.state -eq 'disabled') {
            $record = ConvertTo-VerificationRecord $verificationProfile $head $base 'exempt' 'operator-disabled' @(); Write-JsonAtomic $resultFile $record; Emit $record; return
        }
        if ($verificationProfile.state -ne 'configured') {
            $record = ConvertTo-VerificationRecord $verificationProfile $head $base 'blocked' 'missing-profile' @(); Write-JsonAtomic $resultFile $record; Emit $record; exit 4
        }
        $runs = [System.Collections.Generic.List[object]]::new()
        $record = ConvertTo-VerificationRecord $verificationProfile $head $base 'running' '' @(); Write-JsonAtomic $resultFile $record
        $supervisor = Join-Path $PSScriptRoot 'supervisor.ps1'
        $psExe = ([System.Diagnostics.Process]::GetCurrentProcess()).MainModule.FileName
        $artifactParent = Join-Path (Split-Path -Parent $resultFull) '.verification-artifacts'
        [void][System.IO.Directory]::CreateDirectory($artifactParent)
        $safeResultName = ([System.IO.Path]::GetFileName($resultFull) -replace '[^A-Za-z0-9_.-]', '_')
        $invocationId = [guid]::NewGuid().ToString('N')
        $artifactRoot = Join-Path $artifactParent "$safeResultName-$invocationId"
        [void][System.IO.Directory]::CreateDirectory($artifactRoot)
        $i = 0
        foreach ($cmd in $verificationProfile.commands) {
            $i++
            $prefix = Join-Path $artifactRoot ("command-{0}" -f $i)
            $supervisorResult = "$prefix.json"; $stdoutFile = "$prefix.out.txt"; $stderrFile = "$prefix.err.txt"
            $null = & $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $supervisor run --shell-command $cmd --working-directory $root --deadline-sec $deadline --output-max-bytes $maxBytes --result-file $supervisorResult --stdout-file $stdoutFile --stderr-file $stderrFile --work $work --task-id _integration --role merger --label verification --process-diagnostics 2>&1
            $rc = $LASTEXITCODE
            $supervisorRecord = $null
            $reason = 'missing-result'
            if (Test-Path -LiteralPath $supervisorResult) {
                try {
                    $rawSupervisorRecord = Get-Content -LiteralPath $supervisorResult -Raw
                    if ([string]::IsNullOrWhiteSpace($rawSupervisorRecord) -or
                        -not $rawSupervisorRecord.TrimStart().StartsWith('{')) {
                        throw 'supervisor result body must be one JSON object'
                    }
                    $supervisorRecord = ConvertFrom-Json -InputObject $rawSupervisorRecord
                    if (-not (Test-JsonObject $supervisorRecord)) {
                        throw 'supervisor result body must be one JSON object'
                    }
                    $rawReason = Get-RecordProp $supervisorRecord 'reason'
                    if (Test-JsonString $rawReason) { $reason = $rawReason }
                    else { $reason = 'invalid-result' }
                } catch { $reason = 'invalid-result' }
            }
            $childExit = Get-RecordProp $supervisorRecord 'exit_code'
            $survivors = Get-RecordProp $supervisorRecord 'survivor_count_after_cleanup'
            $cleanupAttempted = Get-RecordProp $supervisorRecord 'cleanup_attempted'
            $terminalGreen = (
                $rc -eq 0 -and
                (Test-TerminalSupervisorRecord $supervisorRecord 'survivor_count_after_cleanup')
            )
            $runs.Add([ordered]@{
                command = $cmd
                reason = $reason
                exit_code = $childExit
                survivors = $survivors
                cleanup_attempted = $cleanupAttempted
            })
            $verdict = if ($terminalGreen) { 'running' } else { 'failed' }
            $record = ConvertTo-VerificationRecord $verificationProfile $head $base $verdict '' @($runs); Write-JsonAtomic $resultFile $record
            if ($verdict -eq 'failed') { Emit $record; exit 5 }
        }
        $record = ConvertTo-VerificationRecord $verificationProfile $head $base 'pass' '' @($runs); Write-JsonAtomic $resultFile $record; Emit $record
    } finally {
        Release-Lock -LockPath $runLock
    }
}
function Invoke-CheckCommand {
    $work = Get-RequiredOption 'work'; $configRoot = Get-Opt 'config-root' $work
    $root = Get-RequiredOption 'root'; $vcs = Get-RequiredOption 'vcs'; $expectedHead = Get-RequiredOption 'head'; $revision = Get-Opt 'revision'
    $resultFile = Get-Opt 'result-file' (Join-Path $work 'verification.json')
    $head = Resolve-VerificationHead $root $vcs $revision
    if ($head -ne $expectedHead) { Fail 3 "verification head mismatch: expected '$expectedHead', current '$head'" }
    if (-not (Test-Path -LiteralPath $resultFile)) { Fail 4 "verification evidence missing: $resultFile" }
    $rawEvidence = Get-Content -LiteralPath $resultFile -Raw
    if ([string]::IsNullOrWhiteSpace($rawEvidence) -or -not $rawEvidence.TrimStart().StartsWith('{')) {
        Fail 4 'verification evidence body must be one JSON object'
    }
    $dateKindSupported = (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')
    try {
        if ($dateKindSupported) { $record = $rawEvidence | ConvertFrom-Json -DateKind String }
        else { $record = $rawEvidence | ConvertFrom-Json }
    } catch { Fail 4 "verification evidence unreadable: $resultFile" }
    if (-not (Test-JsonObject $record)) { Fail 4 'verification evidence body must be one JSON object' }
    $verificationProfile = Get-Profile $configRoot
    $requiredStringFields = @(
        'schema', 'verdict', 'verified_head', 'base', 'profile_fingerprint',
        'profile_state', 'profile_source', 'environment_fingerprint',
        'exemption'
    )
    foreach ($field in $requiredStringFields) {
        if (-not (Test-JsonString (Get-RecordProp $record $field))) {
            Fail 4 "verification evidence field '$field' must be a JSON string scalar"
        }
    }
    $updatedAt = Get-RecordProp $record 'updated_at'
    $updatedAtIsStringScalar = Test-JsonString $updatedAt
    $updatedAtIsLegacyParsedString = (
        -not $dateKindSupported -and $null -ne $updatedAt -and
        $updatedAt.GetType() -in @([datetime], [datetimeoffset]))
    if (-not $updatedAtIsStringScalar -and -not $updatedAtIsLegacyParsedString) {
        Fail 4 "verification evidence field 'updated_at' must be a JSON string scalar"
    }
    $schema = Get-RecordProp $record 'schema'
    if ($schema -cne 'orchestra/verification@2') {
        Fail 4 'verification evidence schema is obsolete or unsupported'
    }
    $recordedHead = Get-RecordProp $record 'verified_head'
    $base = Get-RecordProp $record 'base'
    $profileFingerprint = Get-RecordProp $record 'profile_fingerprint'
    $environmentFingerprint = Get-RecordProp $record 'environment_fingerprint'
    if ($recordedHead -cnotmatch '^[0-9a-f]{40,64}$' -or $recordedHead -cne $head) {
        Fail 4 "verification evidence is stale: recorded head '$recordedHead', current '$head'"
    }
    if ($base -ne '' -and $base -cnotmatch '^[0-9a-f]{40,64}$') {
        Fail 4 'verification evidence base must be empty or one full commit id'
    }
    if ($profileFingerprint -cnotmatch '^[0-9a-f]{64}$' -or
        $profileFingerprint -cne $verificationProfile.fingerprint) {
        Fail 4 'verification evidence is stale: profile changed since the run'
    }
    if ($environmentFingerprint -cnotmatch '^[0-9a-f]{64}$' -or
        $environmentFingerprint -cne $verificationProfile.environmentFingerprint) {
        Fail 4 'verification evidence is stale: execution environment changed since the run'
    }
    if ((Get-RecordProp $record 'profile_state') -cne $verificationProfile.state -or
        (Get-RecordProp $record 'profile_source') -cne $verificationProfile.source) {
        Fail 4 'verification evidence profile body differs from the current profile'
    }
    if ($updatedAtIsStringScalar -and [string]::IsNullOrWhiteSpace($updatedAt)) {
        Fail 4 'verification evidence updated_at must be a non-empty JSON string'
    }
    $environmentRecord = Get-RecordProp $record 'environment'
    if (-not (Test-VerificationEnvironmentRecord $environmentRecord $verificationProfile.environment)) {
        Fail 4 'verification evidence environment body is malformed or stale'
    }
    $commandsValue = Get-RecordProp $record 'commands'
    if (-not (Test-JsonArray $commandsValue)) {
        Fail 4 'verification evidence commands must be a JSON array'
    }
    $verdict = Get-RecordProp $record 'verdict'
    $exemption = Get-RecordProp $record 'exemption'
    if ($opts.ContainsKey('require-pass') -and $verdict -ne 'pass') {
        Fail 4 "verification evidence is not reusable command evidence (verdict '$verdict')"
    }
    if ($verdict -notin @('pass', 'exempt')) {
        Fail 4 "verification evidence is not terminal green (verdict '$verdict')"
    }
    if ($verdict -eq 'pass') {
        if ($exemption -cne '') { Fail 4 'verification pass evidence must not carry an exemption' }
        $runs = $commandsValue
        if ($runs.Count -ne $verificationProfile.commands.Count) {
            Fail 4 'verification evidence command set is incomplete'
        }
        for ($i = 0; $i -lt $verificationProfile.commands.Count; $i++) {
            $run = $runs[$i]
            if (-not (Test-JsonObject $run)) {
                Fail 4 "verification evidence command $($i + 1) body must be one JSON object"
            }
            $recordedCommand = Get-RecordProp $run 'command'
            if (-not (Test-JsonString $recordedCommand) -or
                $recordedCommand -cne [string]$verificationProfile.commands[$i]) {
                Fail 4 "verification evidence command $($i + 1) differs from the current ordered profile"
            }
            if (-not (Test-TerminalSupervisorRecord $run 'survivors')) {
                Fail 4 "verification evidence command $($i + 1) is not terminal green"
            }
        }
    } else {
        if ($exemption -notin @('docs-only', 'operator-disabled')) {
            Fail 4 "verification exempt evidence has unsupported exemption '$exemption'"
        }
        if ($commandsValue.Count -ne 0) {
            Fail 4 'verification exempt evidence must not contain command results'
        }
    }
    Emit $record
}

try {
    switch ($Command) {
        'profile' { Invoke-ProfileCommand }
        'run' { Invoke-RunCommand }
        'check' { Invoke-CheckCommand }
        default { Fail 2 "unknown command '$Command'. Valid: profile, run, check" }
    }
} catch { exit (Resolve-CatchExit -ErrorRecord $_ -Prefix $script:ErrPrefix -Label 'verification' -DebugEnv 'VERIFICATION_DEBUG') }
