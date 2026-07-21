<# Hermetic tests for tools/verification.ps1 (T-270). #>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$Tool = Join-Path $PSScriptRoot '..\tools\verification.ps1'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Failures = [System.Collections.Generic.List[string]]::new()
$Dirs = [System.Collections.Generic.List[string]]::new()
function Write-Utf8 { param([string]$Path,[string]$Text) $d=Split-Path -Parent $Path; if($d -and -not(Test-Path $d)){[void][IO.Directory]::CreateDirectory($d)}; [IO.File]::WriteAllText($Path,$Text,$Utf8) }
function Assert-Eq { param($Expected,$Actual,[string]$Message) if($Expected -ne $Actual){$Failures.Add("FAIL - ${Message}: expected [$Expected], got [$Actual]")} }
function Assert-Contains { param([string]$Text,[string]$Needle,[string]$Message) if(-not $Text.Contains($Needle)){$Failures.Add("FAIL - $Message (missing [$Needle] in [$Text])")} }
function Invoke-Tool { param([string[]]$ToolArgs) $o=@(& pwsh -NoProfile -File $Tool @ToolArgs 2>&1 | ForEach-Object {$_.ToString()}); [pscustomobject]@{Exit=$LASTEXITCODE;Out=($o -join "`n")} }
function New-Repo {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('orchestra-verification-'+[guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($root); $Dirs.Add($root)
    & git -C $root init -q; & git -C $root config user.email fixture@example.invalid; & git -C $root config user.name Fixture
    Write-Utf8 (Join-Path $root 'src.txt') "base`n"; & git -C $root add src.txt; & git -C $root commit -q -m base
    [void][IO.Directory]::CreateDirectory((Join-Path $root '.work'))
    return $root
}
function Head { param([string]$Root) return (& git -C $Root rev-parse HEAD).Trim() }
function Commit-Code { param([string]$Root,[string]$Text) Write-Utf8 (Join-Path $Root 'src.txt') $Text; & git -C $Root add src.txt; & git -C $Root commit -q -m code; return (Head $Root) }
function Commit-Docs { param([string]$Root) Write-Utf8 (Join-Path $Root 'docs/guide.md') "docs`n"; & git -C $Root add docs/guide.md; & git -C $Root commit -q -m docs; return (Head $Root) }

try {
    # Missing profile blocks an executable change.
    $r=New-Repo; $base=Head $r; $head=Commit-Code $r "code`n"
    $x=Invoke-Tool @('run','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--base',$base,'--head',$head,'--json')
    Assert-Eq 4 $x.Exit 'missing profile blocks executable diff'; Assert-Contains $x.Out '"verdict":"blocked"' 'missing profile writes blocked verdict'

    # Multiple commands are preserved and all succeed; check reuses the exact-head evidence.
    Write-Utf8 (Join-Path $r '.work/config.md') 'VERIFICATION_COMMANDS: ["git --version", "git status --short"]'
    $x=Invoke-Tool @('run','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--base',$base,'--head',$head,'--json')
    Assert-Eq 0 $x.Exit 'multiple successful commands pass'; Assert-Contains $x.Out '"verdict":"pass"' 'multiple-command run emits pass'
    try { $jsonOutput = $x.Out | ConvertFrom-Json; Assert-Eq 'pass' $jsonOutput.verdict '--json emits exactly one parseable verdict object' } catch { $Failures.Add("FAIL - --json output is not a single JSON object: $($x.Out)") }
    $evidence=(Get-Content (Join-Path $r '.work/verification.json') -Raw | ConvertFrom-Json); Assert-Eq 2 @($evidence.commands).Count 'evidence preserves both commands'
    $x=Invoke-Tool @('check','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--head',$head,'--json'); Assert-Eq 0 $x.Exit 'current-head pass evidence is reusable on resume'

    # A later failing command makes the whole profile fail.
    Write-Utf8 (Join-Path $r '.work/config.md') 'VERIFICATION_COMMANDS: ["git --version", "pwsh -NoProfile -Command ''exit 9''"]'
    $x=Invoke-Tool @('run','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--base',$base,'--head',$head,'--json')
    Assert-Eq 5 $x.Exit 'failure of one verification command fails profile'; Assert-Contains $x.Out '"verdict":"failed"' 'failed command writes failed verdict'

    # Strict docs-only detection exempts missing profiles without pretending commands ran.
    $d=New-Repo; $dbase=Head $d; $dhead=Commit-Docs $d
    $x=Invoke-Tool @('run','--work',(Join-Path $d '.work'),'--root',$d,'--vcs','git','--base',$dbase,'--head',$dhead,'--json')
    Assert-Eq 0 $x.Exit 'docs-only diff is exempt'; Assert-Contains $x.Out '"exemption":"docs-only"' 'docs-only exemption is explicit'

    # Operator-owned disable is explicit and survives check.
    Write-Utf8 (Join-Path $r '.work/config.md') 'VERIFICATION_MODE: disabled'
    $x=Invoke-Tool @('run','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--base',$base,'--head',$head,'--json')
    Assert-Eq 0 $x.Exit 'operator-disabled profile is exempt'; Assert-Contains $x.Out '"exemption":"operator-disabled"' 'operator-disabled exemption is explicit'

    # Crash recovery never accepts running evidence or evidence from an old head/profile.
    $record=Get-Content (Join-Path $r '.work/verification.json') -Raw | ConvertFrom-Json; $record.verdict='running'; Write-Utf8 (Join-Path $r '.work/verification.json') ($record | ConvertTo-Json -Depth 12)
    $x=Invoke-Tool @('check','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--head',$head); Assert-Eq 4 $x.Exit 'running crash residue is not reusable'
    Write-Utf8 (Join-Path $r '.work/config.md') 'VERIFICATION_COMMANDS: ["git --version"]'; $x=Invoke-Tool @('run','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--base',$base,'--head',$head); Assert-Eq 0 $x.Exit 'fresh profile reruns after crash residue'
    $newHead=Commit-Code $r "new head`n"; $x=Invoke-Tool @('check','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--head',$newHead); Assert-Eq 4 $x.Exit 'evidence from old head is rejected'
}
finally { foreach($d in $Dirs){if(Test-Path $d){Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue}} }
if($Failures.Count){Write-Host "FAILED - $($Failures.Count) assertion(s):"; $Failures|ForEach-Object{Write-Host "  $_"}; exit 1}
Write-Host 'OK - verification profiles cover missing, multiple, failed, docs-only, disabled, and crash-recovery cases.'
