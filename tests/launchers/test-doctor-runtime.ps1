<#
  Fixture tests for tools/doctor-runtime.ps1 - the cross-platform doctor engine that
  launchers/cc-doctor.cmd and launchers/cc-doctor.sh delegate to (task T-090).

  These drive the runtime as a child pwsh process against a synthetic project tree and a
  throwaway home, so they never read the machine's real ~/.claude or ~/.codex, never
  touch a real .work/, and never depend on whatever CODEX_* the ambient shell has set
  (every scenario passes -ProjectRoot / -HomeDir and clears the relevant env vars).
  Because the runtime is a single pwsh script, running this same suite under pwsh on
  Windows and on Linux exercises byte-for-byte the same code path: the pass/fail result
  is the cross-platform equivalence proof for doctor (analogous to test-sync-runtime.ps1).

  Ports the behaviour coverage of the former test-cc-doctor.ps1 (which drove the inline
  .cmd program the runtime replaced) directly against the engine: exec-permission
  classification (routing off / routing on with no grant / settings allow-rule / session
  grant / deny-only / CI-fix-only / custom CODEX_CMD), effective CODEX_* + env fallback,
  fail-closed Codex key value validation, KB status (default, env fallback, config
  precedence over env), the queue/config audit, structured/legacy lock diagnostics in
  both checkout and mirror layouts, and the
  Windows sandbox profile block (OS-conditionally: the real classification on Windows, the
  N/A line on POSIX). The codex "binary present/version" line is not asserted (it depends
  on an external binary and carries no classification logic); the "NOT FOUND" branch is
  exercised via a deliberately bogus CODEX_CMD so the machine's real codex cannot leak in.

  Usage:
    pwsh -File tests/launchers/test-doctor-runtime.ps1
#>

# ci:posix - cross-platform; run-all.ps1 runs this under pwsh on Linux in CI too.
$ErrorActionPreference = 'Stop'

$script:Runtime = (Resolve-Path (Join-Path $PSScriptRoot '..\..\tools\doctor-runtime.ps1')).Path
$script:Failures = New-Object System.Collections.ArrayList
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:OnWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows)

$script:Pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)
if (-not $script:Pwsh) {
    Write-Host 'SKIP - pwsh not found on PATH; the cross-platform doctor runtime requires PowerShell 7.'
    exit 0
}

function New-Root {
    $r = Join-Path ([System.IO.Path]::GetTempPath()) ("orc-doctor-test-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $r | Out-Null
    return $r
}

function Write-File {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8)
}

# A fresh project (with .work/) + a fresh home. RepoRoot is pointed at the home (which
# has no agents/), so the agent-mirror freshness check deterministically reports the
# "not the Orchestra repo checkout" skip rather than diffing this repo's real agents/.
function New-Case {
    $proj = New-Root
    $homeRoot = New-Root
    New-Item -ItemType Directory -Force -Path (Join-Path $proj '.work') | Out-Null
    return [pscustomobject]@{ Proj = $proj; Home = $homeRoot }
}

# Cyrillic strings the queue-header format needs, built from code points (see the runtime
# header for why the source stays ASCII).
function ConvertFrom-CodePoints { param([int[]]$Codes) return (-join ($Codes | ForEach-Object { [char]$_ })) }
$script:StatusWord = ConvertFrom-CodePoints @(0x0441, 0x0442, 0x0430, 0x0442, 0x0443, 0x0441)
$script:NeNachata = ConvertFrom-CodePoints @(0x043D, 0x0435, 0x0020, 0x043D, 0x0430, 0x0447, 0x0430, 0x0442, 0x0430)
$script:EmDash = [char]0x2014

function Invoke-Doctor {
    param(
        [pscustomobject]$Case,
        [hashtable]$Env = @{},
        [string]$Runtime = $script:Runtime
    )
    # Env vars the runtime consults from the process environment (CODEX_CODER/
    # CODEX_REVIEWER env fallback, CC_CODEX_EXEC_GRANT session grant). Set them on the
    # parent so the spawned child inherits them, then restore. Unset ambient routing by
    # default so a machine with real CODEX_* set cannot make these scenarios flaky.
    $defaults = @{ CODEX_CODER = ''; CODEX_REVIEWER = ''; CC_CODEX_EXEC_GRANT = ''; KB = '' }
    foreach ($k in $Env.Keys) { $defaults[$k] = $Env[$k] }

    $saved = @{}
    foreach ($k in $defaults.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        Set-Item -Path "env:$k" -Value $defaults[$k]
    }
    try {
        $rtArgs = @('-NoProfile', '-File', $Runtime,
            '-ProjectRoot', $Case.Proj, '-HomeDir', $Case.Home, '-RepoRoot', $Case.Home)
        $outFile = [System.IO.Path]::GetTempFileName()
        $errFile = [System.IO.Path]::GetTempFileName()
        $p = Start-Process -FilePath $script:Pwsh.Source -ArgumentList $rtArgs -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $out = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
        $err = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $outFile, $errFile -ErrorAction SilentlyContinue
        $exit = if ($null -ne $p -and $null -ne $p.ExitCode) { [int]$p.ExitCode } else { -1 }
        $outStr = if ($null -eq $out) { '' } else { [string]$out }
        $errStr = if ($null -eq $err) { '' } else { [string]$err }
        return [pscustomobject]@{ ExitCode = $exit; Out = $outStr; Err = $errStr }
    }
    finally {
        foreach ($k in $saved.Keys) {
            if ($null -eq $saved[$k]) { Remove-Item -Path "env:$k" -ErrorAction SilentlyContinue }
            else { Set-Item -Path "env:$k" -Value $saved[$k] }
        }
    }
}

function Remove-Case { param([pscustomobject]$Case) Remove-Item -LiteralPath $Case.Proj, $Case.Home -Recurse -Force -ErrorAction SilentlyContinue }

function Assert-True { param([bool]$Cond, [string]$Msg) if (-not $Cond) { [void]$script:Failures.Add("FAIL - $Msg") } }
function Assert-Contains { param([string]$Hay, [string]$Needle, [string]$Msg) if ($Hay -notlike "*$Needle*") { [void]$script:Failures.Add("FAIL - ${Msg}: expected to find [$Needle]") } }
function Assert-NotContains { param([string]$Hay, [string]$Needle, [string]$Msg) if ($Hay -like "*$Needle*") { [void]$script:Failures.Add("FAIL - ${Msg}: did not expect [$Needle]") } }
function Set-Config { param([pscustomobject]$Case, [string]$Text) Write-File (Join-Path $Case.Proj '.work/config.md') $Text }
function Set-Settings { param([pscustomobject]$Case, [string]$Json) Write-File (Join-Path $Case.Proj '.claude/settings.local.json') $Json }

# =============================================================================
# 1) exec permission: routing off + no grant -> OK (not WARN)
# =============================================================================
$c = New-Case
Set-Config $c 'CODEX_MODEL: gpt-5-codex'
$r = Invoke-Doctor -Case $c
Assert-True ($r.ExitCode -eq 0) "routing-off exits 0 (got $($r.ExitCode); err=$($r.Err))"
Assert-Contains $r.Out 'OK   exec permission: not found, but not required' 'routing-off: OK not WARN'
Assert-NotContains $r.Out 'WARN exec permission' 'routing-off: must not WARN'
Remove-Case $c

# =============================================================================
# 2) exec permission: routing on (CODEX_CODER), no grant anywhere -> WARN
# =============================================================================
$c = New-Case
Set-Config $c 'CODEX_CODER: fast'
$r = Invoke-Doctor -Case $c
Assert-True ($r.ExitCode -eq 0) 'routing-on-no-grant exits 0'
Assert-Contains $r.Out 'WARN exec permission: NOT found' 'routing-on-no-grant: must WARN'
Assert-Contains $r.Out 'Bash(pwsh -File tools/codex-runtime.ps1 *)' 'routing-on-no-grant: WARN names the runtime-wrapper rule'
Assert-Contains $r.Out 'cc-config' 'routing-on-no-grant: WARN points at cc-config'
Remove-Case $c

# =============================================================================
# 3) exec permission: allow-rule present in settings.local.json -> OK
# =============================================================================
$c = New-Case
Set-Config $c 'CODEX_REVIEWER: fast+std'
Set-Settings $c '{"permissions":{"allow":["Bash(pwsh -File tools/codex-runtime.ps1 *)"]}}'
$r = Invoke-Doctor -Case $c
Assert-Contains $r.Out 'OK   exec permission: allow-rule for the codex runtime' 'allow-rule: OK'
Assert-NotContains $r.Out 'WARN exec permission' 'allow-rule: no WARN'
Remove-Case $c

# =============================================================================
# 3b) exec permission: only the MIRROR-form allow-rule present (T-114) -> OK too
# =============================================================================
$c = New-Case
Set-Config $c 'CODEX_REVIEWER: fast+std'
Set-Settings $c '{"permissions":{"allow":["Bash(pwsh -File ~/.claude/scripts/codex-runtime.ps1 *)"]}}'
$r = Invoke-Doctor -Case $c
Assert-Contains $r.Out 'OK   exec permission: allow-rule for the codex runtime' 'mirror-form allow-rule: OK'
Assert-NotContains $r.Out 'WARN exec permission' 'mirror-form allow-rule: no WARN'
Remove-Case $c

# =============================================================================
# 4) effective CODEX_*: env fallback for CODEX_CODER labelled "(env)"
# =============================================================================
$c = New-Case
$r = Invoke-Doctor -Case $c -Env @{ CODEX_CODER = 'fast' }
Assert-Contains $r.Out 'CODEX_CODER      = fast (env)' 'env fallback: CODEX_CODER read from env and labelled'
Remove-Case $c

# =============================================================================
# 5) Codex key value validation: all six valid -> OK line, CODEX_NETWORK printed
# =============================================================================
$c = New-Case
Set-Config $c (@(
    'CODEX_CODER: fast+std'
    'CODEX_REVIEWER: deep'
    'CODEX_CIFIX: on'
    'CODEX_REASONING: high'
    'CODEX_SANDBOX: read-only'
    'CODEX_NETWORK: off'
) -join "`n")
$r = Invoke-Doctor -Case $c
Assert-Contains $r.Out 'OK   Codex key values: all set values are within their allowed sets' 'all-valid: OK line'
Assert-NotContains $r.Out 'FAIL CODEX' 'all-valid: no FAIL'
Assert-True ([regex]::IsMatch($r.Out, 'CODEX_NETWORK\s+=\s+off')) 'all-valid: effective summary prints CODEX_NETWORK from config'
Remove-Case $c

# =============================================================================
# 6) Codex key value validation: an invalid value for each key -> FAIL
# =============================================================================
$badValues = [ordered]@{
    'CODEX_CODER'     = @{ Bad = 'fastest';            Allowed = 'off | fast | fast+std' }
    'CODEX_REVIEWER'  = @{ Bad = 'deeep';              Allowed = 'off | fast | fast+std | deep' }
    'CODEX_CIFIX'     = @{ Bad = 'yes';                Allowed = 'off | on' }
    'CODEX_REASONING' = @{ Bad = 'huge';               Allowed = 'auto | low | medium | high' }
    'CODEX_SANDBOX'   = @{ Bad = 'danger-full-access'; Allowed = 'read-only | workspace-write' }
    'CODEX_NETWORK'   = @{ Bad = 'enabled';            Allowed = 'on | off' }
}
foreach ($key in $badValues.Keys) {
    $c = New-Case
    $bad = $badValues[$key].Bad
    Set-Config $c ("{0}: {1}" -f $key, $bad)
    $r = Invoke-Doctor -Case $c
    Assert-Contains $r.Out ("FAIL {0}: invalid value '{1}'" -f $key, $bad) "invalid ${key}: FAIL names key and value"
    Assert-Contains $r.Out ("allowed: {0}" -f $badValues[$key].Allowed) "invalid ${key}: lists allowed set"
    Assert-NotContains $r.Out 'OK   Codex key values: all set values are within their allowed sets' "invalid ${key}: no all-valid OK (no silent default)"
    Remove-Case $c
}

# =============================================================================
# 7) exec permission: session grant covers the command -> OK, no WARN
# =============================================================================
$c = New-Case
Set-Config $c 'CODEX_CODER: fast'
$r = Invoke-Doctor -Case $c -Env @{ CC_CODEX_EXEC_GRANT = 'codex exec' }
Assert-Contains $r.Out 'OK   exec permission: session grant present' 'session-grant: OK'
Assert-NotContains $r.Out 'WARN exec permission' 'session-grant: no WARN'
Remove-Case $c

# =============================================================================
# 8) exec permission: runtime rule ONLY in permissions.deny -> stays WARN
# =============================================================================
$c = New-Case
Set-Config $c 'CODEX_CODER: fast'
Set-Settings $c '{"permissions":{"deny":["Bash(pwsh -File tools/codex-runtime.ps1 *)"],"allow":["Read(*)"]}}'
$r = Invoke-Doctor -Case $c
Assert-Contains $r.Out 'WARN exec permission: NOT found' 'deny-only: a deny match is not a grant'
Assert-NotContains $r.Out 'OK   exec permission: allow-rule' 'deny-only: no false allow-rule OK'
Remove-Case $c

# =============================================================================
# 9) exec permission: only CODEX_CIFIX on (CODER/REVIEWER off) -> gate stays active
# =============================================================================
$c = New-Case
Set-Config $c 'CODEX_CIFIX: on'
$r = Invoke-Doctor -Case $c
Assert-Contains $r.Out 'WARN exec permission: NOT found' 'ci-fix-only: gate active'
Assert-NotContains $r.Out 'not found, but not required' 'ci-fix-only: not treated as all-off'
Remove-Case $c

# =============================================================================
# 10) custom CODEX_CMD, only the historical codex exec anchor -> WARN (not OK)
# =============================================================================
$c = New-Case
Set-Config $c (@('CODEX_CODER: fast', 'CODEX_CMD: my-codex') -join "`n")
Set-Settings $c '{"permissions":{"allow":["Bash(codex exec *)"]}}'
$r = Invoke-Doctor -Case $c
Assert-Contains $r.Out 'WARN exec permission: NOT found' 'custom-cmd anchor-only: WARN'
Assert-NotContains $r.Out 'OK   exec permission: allow-rule' 'custom-cmd anchor-only: no false OK'
Remove-Case $c

# =============================================================================
# 11) custom CODEX_CMD WITH the runtime-wrapper rule -> OK (covers any CODEX_CMD)
# =============================================================================
$c = New-Case
Set-Config $c (@('CODEX_CODER: fast', 'CODEX_CMD: my-codex') -join "`n")
Set-Settings $c '{"permissions":{"allow":["Bash(pwsh -File tools/codex-runtime.ps1 *)"]}}'
$r = Invoke-Doctor -Case $c
Assert-Contains $r.Out 'OK   exec permission: allow-rule for the codex runtime' 'custom-cmd runtime-rule: OK'
Assert-NotContains $r.Out 'WARN exec permission' 'custom-cmd runtime-rule: no WARN'
Remove-Case $c

# =============================================================================
# 12) KB status + codex NOT FOUND (bogus CODEX_CMD) + knowledge counts
# =============================================================================
$c = New-Case
Set-Config $c (@('KB: on', 'CODEX_CMD: codex-such-binary-does-not-exist-xyz') -join "`n")
Write-File (Join-Path $c.Proj '.work/knowledge/pitfalls/p-01.md') "# pitfall`n"
$r = Invoke-Doctor -Case $c
Assert-Contains $r.Out 'codex binary : NOT FOUND (codex-such-binary-does-not-exist-xyz)' 'bogus cmd: NOT FOUND'
Assert-Contains $r.Out 'KB = on' 'KB: reflects config'
Assert-Contains $r.Out 'pitfalls      = 1 entries' 'KB: pitfalls count reflects the knowledge dir'
Remove-Case $c

# =============================================================================
# 12a) KB status: unset config and env -> default is now "on" (not "off")
# =============================================================================
$c = New-Case
$r = Invoke-Doctor -Case $c
Assert-Contains $r.Out 'KB = on (default)' 'KB: default is on when unset in both config and env'
Remove-Case $c

# =============================================================================
# 12b) KB status: env fallback labelled "(env)" when config.md does not set KB
# =============================================================================
$c = New-Case
$r = Invoke-Doctor -Case $c -Env @{ KB = 'off' }
Assert-Contains $r.Out 'KB = off (env)' 'KB: env fallback read and labelled'
Remove-Case $c

# =============================================================================
# 12c) KB status: config.md always wins over env
# =============================================================================
$c = New-Case
Set-Config $c 'KB: off'
$r = Invoke-Doctor -Case $c -Env @{ KB = 'on' }
Assert-Contains $r.Out 'KB = off' 'KB: config wins over env'
Assert-NotContains $r.Out 'KB = off (env)' 'KB: config value is not labelled as env-sourced'
Remove-Case $c

# =============================================================================
# 13) queue/config audit: valid Cyrillic header OK; unknown key FAIL; SMOKE OK
# =============================================================================
$c = New-Case
$hdr = "# Q`n`n### [T-001] Title " + $script:EmDash + " " + $script:StatusWord + ": " + $script:NeNachata + "`n"
Write-File (Join-Path $c.Proj '.work/Tasks_Queue.md') $hdr
Set-Config $c (@('SMOKE_CMD: pwsh -File tools/check-consistency.ps1', 'BOGUS_KEY: x') -join "`n")
$r = Invoke-Doctor -Case $c
Assert-Contains $r.Out 'OK   Tasks_Queue.md: 1 task header(s), format valid, IDs unique' 'queue: valid Cyrillic header recognized'
Assert-Contains $r.Out 'unknown/possibly mistyped key(s): BOGUS_KEY' 'config: unknown key flagged'
Assert-Contains $r.Out 'OK   SMOKE_CMD is configured' 'config: SMOKE_CMD detected'
Remove-Case $c

# =============================================================================
# 14) lock/worktree audit: no lock remains OK
# =============================================================================
$c = New-Case
$r = Invoke-Doctor -Case $c
Assert-Contains $r.Out 'OK   no orchestrator.lock' 'lock: none reported OK'
Assert-Contains $r.Out 'OK   agent-mirror freshness check skipped' 'mirror: skipped when not a checkout'
Remove-Case $c

# =============================================================================
# 15) structured active lease: checkout and mirror state-tx resolvers
# =============================================================================
$c = New-Case
$now = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
$lease = [ordered]@{
    schema = 'orchestra/lease@1'; owner_id = 'OWNER-A'; session_id = 'SESSION-A'
    role = 'processor'; root = $c.Proj; host = 'doctor-fixture-remote-host'; pid = $null
    pid_started = $null; acquired = $now; heartbeat = $now; ttl_seconds = 900; generation = 1
} | ConvertTo-Json -Compress
Write-File (Join-Path $c.Proj '.work/orchestrator.lock/lease.json') $lease

$r = Invoke-Doctor -Case $c
Assert-Contains $r.Out 'OK   orchestrator.lock: owner=OWNER-A role=processor heartbeat ' 'lock lease checkout: owner/role/heartbeat reported'
Assert-Contains $r.Out 's (live)' 'lock lease checkout: live status reported'
Assert-NotContains $r.Out 'WARN orchestrator.lock' 'lock lease checkout: healthy lease does not WARN'

$mirrorDir = Join-Path $c.Home '.claude/scripts'
New-Item -ItemType Directory -Force -Path $mirrorDir | Out-Null
Copy-Item -LiteralPath $script:Runtime -Destination (Join-Path $mirrorDir 'doctor-runtime.ps1')
Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $script:Runtime) 'state-tx.ps1') -Destination (Join-Path $mirrorDir 'state-tx.ps1')
$r = Invoke-Doctor -Case $c -Runtime (Join-Path $mirrorDir 'doctor-runtime.ps1')
Assert-Contains $r.Out 'OK   orchestrator.lock: owner=OWNER-A role=processor heartbeat ' 'lock lease mirror: owner/role/heartbeat reported'
Assert-Contains $r.Out 's (live)' 'lock lease mirror: live status reported'
Assert-NotContains $r.Out 'WARN orchestrator.lock' 'lock lease mirror: healthy lease does not WARN'
Remove-Case $c

# =============================================================================
# 16) legacy mkdir-lock: info-file heuristic remains the fallback
# =============================================================================
$c = New-Case
$started = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
Write-File (Join-Path $c.Proj '.work/orchestrator.lock/info') "host=legacy-host`nstarted=$started`n"
$r = Invoke-Doctor -Case $c
Assert-Contains $r.Out 'OK   orchestrator.lock present, age ' 'legacy lock: info-file age heuristic used'
Assert-Contains $r.Out 'host legacy-host) - looks like an active run' 'legacy lock: existing healthy output preserved'
Assert-NotContains $r.Out 'owner=' 'legacy lock: not misreported as a structured lease'
Remove-Case $c

# =============================================================================
# 17) Windows sandbox profile block: OS-conditional
# =============================================================================
if (-not $script:OnWindows) {
    # POSIX: the Windows-only concept is reported N/A, never silently dropped.
    $c = New-Case
    $r = Invoke-Doctor -Case $c
    Assert-Contains $r.Out 'N/A  windows sandbox profile: not applicable on this OS' 'posix: sandbox block reports N/A'
    Assert-NotContains $r.Out 'FAIL windows sandbox' 'posix: no Windows sandbox FAIL'
    Remove-Case $c
} else {
    # Windows: safe profile (unelevated + approval never) classifies OK.
    $c = New-Case
    Write-File (Join-Path $c.Home '.codex/config.toml') (@('approval_policy = "never"', '[windows]', 'sandbox = "unelevated"') -join "`n")
    $r = Invoke-Doctor -Case $c
    Assert-Contains $r.Out 'OK   windows sandbox profile: unelevated' 'windows: unelevated profile OK'
    Assert-Contains $r.Out 'OK   approval_policy: never' 'windows: approval_policy never OK'
    Assert-NotContains $r.Out 'FAIL windows sandbox' 'windows: safe profile does not FAIL'
    Remove-Case $c

    # Windows: missing config.toml -> cannot verify, WARN (not a crash, not silence).
    $c = New-Case
    $r = Invoke-Doctor -Case $c
    Assert-Contains $r.Out 'WARN windows sandbox profile:' 'windows: missing config WARNs'
    Assert-Contains $r.Out 'WARN approval_policy: not set' 'windows: missing config approval WARNs'
    Remove-Case $c

    # Windows: elevated profile with an unelevated launcher process is the dangerous
    # combination (this test process is normally unelevated); if it happens to be
    # elevated the runtime WARNs instead. Assert whichever branch applies.
    $c = New-Case
    Write-File (Join-Path $c.Home '.codex/config.toml') (@('[windows]', 'sandbox = "elevated"') -join "`n")
    $r = Invoke-Doctor -Case $c
    $wp = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Assert-Contains $r.Out 'WARN windows sandbox profile: elevated, and this process is currently elevated' 'windows: elevated+elevated WARNs'
    } else {
        Assert-Contains $r.Out 'FAIL windows sandbox profile: elevated, but this launcher process is NOT elevated' 'windows: elevated+unelevated FAILs'
        Assert-Contains $r.Out 'ENV_LIMIT/sandbox-init' 'windows: names the sandbox-init escalation'
    }
    Remove-Case $c
}

# =============================================================================
# Report
# =============================================================================
if ($script:Failures.Count -gt 0) {
    Write-Host "test-doctor-runtime: $($script:Failures.Count) failure(s):"
    foreach ($f in $script:Failures) { Write-Host "  $f" }
    exit 1
}
Write-Host 'OK - tools/doctor-runtime.ps1 behaves per contract (exec-permission classification, effective CODEX_*, key validation, KB, queue/config audit, checkout/mirror lease diagnostics, Windows sandbox block).'
exit 0
