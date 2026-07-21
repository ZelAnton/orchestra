<#
.SYNOPSIS
    SHA-bound pre-publication verification profile runner (T-270).

.DESCRIPTION
    Reads VERIFICATION_MODE / VERIFICATION_COMMANDS from .work/config.md, with SMOKE_CMD
    as a backward-compatible one-command profile. `run` executes every configured command
    through tools/supervisor.ps1 and atomically records an exact-command, exact-head verdict.
    `check` is the crash-recovery gate: only a terminal pass/exempt verdict for the current
    profile fingerprint and requested VCS head is reusable. A missing profile blocks
    executable changes; an operator-owned `VERIFICATION_MODE: disabled` or a mechanically
    detected docs-only diff is recorded as an explicit exemption, never as "not checked".

.EXAMPLE
    pwsh -File tools/verification.ps1 profile --work .work --json
    pwsh -File tools/verification.ps1 run --work .work --root .work/worktrees/_integration --vcs git --base <sha> --head <sha>
    pwsh -File tools/verification.ps1 check --work .work --root .work/worktrees/_integration --vcs git --head <sha>
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { $null = $_ }

. (Join-Path $PSScriptRoot 'common.ps1')
$script:ErrPrefix = 'VERERR'
$parsed = Parse-CliArgs $args -BoolFlags @('json')
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
function Read-Config {
    param([string]$Work)
    $values = @{}
    $path = Join-Path $Work 'config.md'
    if (-not (Test-Path -LiteralPath $path)) { return $values }
    foreach ($raw in (Get-Content -LiteralPath $path -Encoding utf8)) {
        if ($raw -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*?)\s*$') {
            $key = $Matches[1]; $value = $Matches[2]
            if (-not $value.StartsWith('[')) { $value = ($value -replace '\s+#.*$', '').Trim() }
            $values[$key] = $value
        }
    }
    return $values
}
function Get-Profile {
    param([string]$Work)
    $cfg = Read-Config $Work
    $mode = if ($cfg.ContainsKey('VERIFICATION_MODE') -and $cfg['VERIFICATION_MODE']) { [string]$cfg['VERIFICATION_MODE'] } else { 'auto' }
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
    $canonical = [ordered]@{ mode = $mode; source = $source; commands = @($commands) }
    $fingerprint = Get-Sha256Text ($canonical | ConvertTo-Json -Compress -Depth 5)
    return [pscustomobject]@{ mode = $mode; state = $state; source = $source; commands = @($commands); fingerprint = $fingerprint }
}
function Get-CurrentHead {
    param([string]$Root, [string]$Vcs)
    if ($Vcs -eq 'jj') {
        $out = @(& jj -R $Root log -r '@' --no-graph -T 'commit_id' 2>&1)
    } elseif ($Vcs -eq 'git') {
        $out = @(& git -C $Root rev-parse HEAD 2>&1)
    } else { Fail 2 "--vcs must be git or jj (got '$Vcs')" }
    if ($LASTEXITCODE -ne 0) { Fail 2 "cannot resolve current $Vcs head under '$Root': $($out -join ' ')" }
    return ([string]($out | Select-Object -Last 1)).Trim()
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
        schema = 'orchestra/verification@1'; verdict = $Verdict; verified_head = $Head; base = $Base
        profile_fingerprint = $VerificationProfile.fingerprint; profile_state = $VerificationProfile.state; profile_source = $VerificationProfile.source
        commands = @($Runs); exemption = $Exemption; updated_at = (Format-UtcNow)
    }
}
function Emit { param($Value) if ($opts.ContainsKey('json')) { $Value | ConvertTo-Json -Compress -Depth 12 } else { Write-Output ("verification {0} head={1} source={2}" -f $Value.verdict,$Value.verified_head,$Value.profile_source) } }

function Invoke-ProfileCommand {
    $verificationProfile = Get-Profile (Get-RequiredOption 'work')
    if ($opts.ContainsKey('json')) { $verificationProfile | ConvertTo-Json -Compress -Depth 8 } else { Write-Output ("verification-profile state={0} mode={1} source={2} commands={3}" -f $verificationProfile.state,$verificationProfile.mode,$verificationProfile.source,$verificationProfile.commands.Count) }
}
function Invoke-RunCommand {
    $work = Get-RequiredOption 'work'; $root = Get-RequiredOption 'root'; $vcs = Get-RequiredOption 'vcs'; $expectedHead = Get-RequiredOption 'head'; $base = Get-Opt 'base'
    $resultFile = Get-Opt 'result-file' (Join-Path $work 'verification.json')
    $deadline = Get-Opt 'deadline-sec' '1800'; $maxBytes = Get-Opt 'output-max-bytes' '1048576'
    $head = Get-CurrentHead $root $vcs
    if ($head -ne $expectedHead) { Fail 3 "verification head mismatch: expected '$expectedHead', current '$head'" }
    $verificationProfile = Get-Profile $work
    $paths = @(Get-ChangedPathList $root $vcs $base $head)
    $docsOnly = Test-DocsOnly $paths
    if ($verificationProfile.state -eq 'disabled') {
        $record = ConvertTo-VerificationRecord $verificationProfile $head $base 'exempt' 'operator-disabled' @(); Write-JsonAtomic $resultFile $record; Emit $record; return
    }
    if ($docsOnly) {
        $record = ConvertTo-VerificationRecord $verificationProfile $head $base 'exempt' 'docs-only' @(); Write-JsonAtomic $resultFile $record; Emit $record; return
    }
    if ($verificationProfile.state -ne 'configured') {
        $record = ConvertTo-VerificationRecord $verificationProfile $head $base 'blocked' 'missing-profile' @(); Write-JsonAtomic $resultFile $record; Emit $record; exit 4
    }
    $runs = [System.Collections.Generic.List[object]]::new()
    $record = ConvertTo-VerificationRecord $verificationProfile $head $base 'running' '' @(); Write-JsonAtomic $resultFile $record
    $supervisor = Join-Path $PSScriptRoot 'supervisor.ps1'
    $i = 0
    foreach ($cmd in $verificationProfile.commands) {
        $i++
        $prefix = Join-Path $work ("verification-command-{0}" -f $i)
        $supervisorResult = "$prefix.json"; $stdoutFile = "$prefix.out.txt"; $stderrFile = "$prefix.err.txt"
        $null = & pwsh -NoProfile -File $supervisor run --shell-command $cmd --working-directory $root --deadline-sec $deadline --output-max-bytes $maxBytes --result-file $supervisorResult --stdout-file $stdoutFile --stderr-file $stderrFile --work $work --task-id _integration --role merger --label verification --process-diagnostics 2>&1
        $rc = $LASTEXITCODE
        $reason = 'missing-result'
        if (Test-Path -LiteralPath $supervisorResult) { try { $reason = [string]((Get-Content -LiteralPath $supervisorResult -Raw) | ConvertFrom-Json).reason } catch { $reason = 'invalid-result' } }
        $runs.Add([ordered]@{ command = $cmd; reason = $reason; exit_code = $rc; result_file = $supervisorResult; stdout_file = $stdoutFile; stderr_file = $stderrFile })
        $verdict = if ($rc -eq 0 -and $reason -eq 'ok') { 'running' } else { 'failed' }
        $record = ConvertTo-VerificationRecord $verificationProfile $head $base $verdict '' @($runs); Write-JsonAtomic $resultFile $record
        if ($verdict -eq 'failed') { Emit $record; exit 5 }
    }
    $record = ConvertTo-VerificationRecord $verificationProfile $head $base 'pass' '' @($runs); Write-JsonAtomic $resultFile $record; Emit $record
}
function Invoke-CheckCommand {
    $work = Get-RequiredOption 'work'; $root = Get-RequiredOption 'root'; $vcs = Get-RequiredOption 'vcs'; $expectedHead = Get-RequiredOption 'head'
    $resultFile = Get-Opt 'result-file' (Join-Path $work 'verification.json')
    $head = Get-CurrentHead $root $vcs
    if ($head -ne $expectedHead) { Fail 3 "verification head mismatch: expected '$expectedHead', current '$head'" }
    if (-not (Test-Path -LiteralPath $resultFile)) { Fail 4 "verification evidence missing: $resultFile" }
    try { $record = (Get-Content -LiteralPath $resultFile -Raw) | ConvertFrom-Json } catch { Fail 4 "verification evidence unreadable: $resultFile" }
    $verificationProfile = Get-Profile $work
    if ([string]$record.verified_head -ne $head) { Fail 4 "verification evidence is stale: recorded head '$($record.verified_head)', current '$head'" }
    if ([string]$record.profile_fingerprint -ne $verificationProfile.fingerprint) { Fail 4 'verification evidence is stale: profile changed since the run' }
    if ([string]$record.verdict -notin @('pass', 'exempt')) { Fail 4 "verification evidence is not terminal green (verdict '$($record.verdict)')" }
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
