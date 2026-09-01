<# Hermetic tests for tools/verification.ps1 (T-270). #>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
. (Join-Path $PSScriptRoot '..\tools\common.ps1')

$Tool = Join-Path $PSScriptRoot '..\tools\verification.ps1'
$PsExe = Get-PowerShellHostExecutable
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Failures = [System.Collections.Generic.List[string]]::new()
$Dirs = [System.Collections.Generic.List[string]]::new()
function Write-Utf8 { param([string]$Path,[string]$Text) $d=Split-Path -Parent $Path; if($d -and -not(Test-Path $d)){[void][IO.Directory]::CreateDirectory($d)}; [IO.File]::WriteAllText($Path,$Text,$Utf8) }
function Write-Json { param([string]$Path,$Value) Write-Utf8 $Path ($Value | ConvertTo-Json -Depth 16) }
function Assert-Eq { param($Expected,$Actual,[string]$Message) if($Expected -ne $Actual){$Failures.Add("FAIL - ${Message}: expected [$Expected], got [$Actual]")} }
function Assert-True { param([bool]$Condition,[string]$Message) if(-not $Condition){$Failures.Add("FAIL - $Message")} }
function Assert-Contains { param([string]$Text,[string]$Needle,[string]$Message) if(-not $Text.Contains($Needle)){$Failures.Add("FAIL - $Message (missing [$Needle] in [$Text])")} }
function Invoke-Tool { param([string[]]$ToolArgs) $o=@(& $PsExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Tool @ToolArgs 2>&1 | ForEach-Object {$_.ToString()}); [pscustomobject]@{Exit=$LASTEXITCODE;Out=($o -join "`n")} }
function Invoke-ToolHost {
    param([string]$Executable,[string]$ToolPath,[string[]]$ToolArgs)
    $o=@(& $Executable -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ToolPath @ToolArgs 2>&1 | ForEach-Object {$_.ToString()})
    [pscustomobject]@{Exit=$LASTEXITCODE;Out=($o -join "`n")}
}
function New-Repo {
    # jj 0.38 writes 128-character operation object names. Keep the Windows fixture
    # root short enough that .jj/repo/op_store/operations/<object> stays below MAX_PATH.
    $suffix=[guid]::NewGuid().ToString('N').Substring(0,12)
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ov-'+$suffix); [void][IO.Directory]::CreateDirectory($root); $Dirs.Add($root)
    & git -C $root init -q; & git -C $root config user.email fixture@example.invalid; & git -C $root config user.name Fixture
    Write-Utf8 (Join-Path $root 'src.txt') "base`n"; & git -C $root add src.txt; & git -C $root commit -q -m base
    [void][IO.Directory]::CreateDirectory((Join-Path $root '.work'))
    return $root
}
function Head { param([string]$Root) return (& git -C $Root rev-parse HEAD).Trim() }
function Commit-Code { param([string]$Root,[string]$Text) Write-Utf8 (Join-Path $Root 'src.txt') $Text; & git -C $Root add src.txt; & git -C $Root commit -q -m code; return (Head $Root) }
function Commit-Docs { param([string]$Root) Write-Utf8 (Join-Path $Root 'docs/guide.md') "docs`n"; & git -C $Root add docs/guide.md; & git -C $Root commit -q -m docs; return (Head $Root) }

try {
    # VERIFICATION_MODE defaults to disabled: an unconfigured project is exempt by
    # default, never blocked, when the key is absent entirely.
    $r=New-Repo; $base=Head $r; $head=Commit-Code $r "code`n"
    $x=Invoke-Tool @('run','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--base',$base,'--head',$head,'--json')
    Assert-Eq 0 $x.Exit 'unconfigured profile defaults to disabled, not blocked'; Assert-Contains $x.Out '"verdict":"exempt"' 'default-disabled profile writes exempt verdict'
    Assert-Contains $x.Out '"exemption":"operator-disabled"' 'default-disabled profile reuses the operator-disabled exemption label'

    # Explicitly opting into VERIFICATION_MODE: auto restores the strict "missing
    # profile blocks executable changes" behavior for projects that want it.
    Write-Utf8 (Join-Path $r '.work/config.md') 'VERIFICATION_MODE: auto'
    $x=Invoke-Tool @('run','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--base',$base,'--head',$head,'--json')
    Assert-Eq 4 $x.Exit 'explicit auto with no commands still blocks executable diff'; Assert-Contains $x.Out '"verdict":"blocked"' 'explicit auto missing profile writes blocked verdict'

    # Multiple commands are preserved and all succeed; check reuses the exact-head
    # evidence. VERIFICATION_MODE is unset here (Write-Utf8 replaces the whole file),
    # which regression-guards that configuring commands alone still auto-opts a
    # project in even though VERIFICATION_MODE itself defaults to disabled.
    Write-Utf8 (Join-Path $r '.work/config.md') 'VERIFICATION_COMMANDS: ["git --version", "git status --short"]'
    $x=Invoke-Tool @('run','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--base',$base,'--head',$head,'--json')
    Assert-Eq 0 $x.Exit 'multiple successful commands pass'; Assert-Contains $x.Out '"verdict":"pass"' 'multiple-command run emits pass'
    try { $jsonOutput = $x.Out | ConvertFrom-Json; Assert-Eq 'pass' $jsonOutput.verdict '--json emits exactly one parseable verdict object' } catch { $Failures.Add("FAIL - --json output is not a single JSON object: $($x.Out)") }
    $evidence=(Get-Content (Join-Path $r '.work/verification.json') -Raw | ConvertFrom-Json); Assert-Eq 2 @($evidence.commands).Count 'evidence preserves both commands'
    $x=Invoke-Tool @('check','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--head',$head,'--json'); Assert-Eq 0 $x.Exit "current-head pass evidence is reusable on resume (tool: $($x.Out))"
    $x=Invoke-Tool @('check','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--head',$head,'--require-pass','--json'); Assert-Eq 0 $x.Exit "require-pass accepts exact terminal-green evidence (tool: $($x.Out))"
    Assert-Eq 'orchestra/verification@2' $evidence.schema 'evidence uses strict terminal-result schema'
    Assert-True ($null -ne $evidence.environment_fingerprint) 'evidence records stable environment fingerprint'
    Assert-Eq 0 @($evidence.commands | Where-Object { $_.reason -ne 'ok' -or $_.exit_code -ne 0 -or $_.survivors -ne 0 -or $_.cleanup_attempted -ne $true }).Count 'every recorded command is terminal green'
    $evidenceText=Get-Content (Join-Path $r '.work/verification.json') -Raw
    if($evidenceText.Contains($r)){$Failures.Add('FAIL - evidence must not record absolute fixture/user paths')}
    if($evidenceText -match 'stdout_file|stderr_file|result_file'){$Failures.Add('FAIL - evidence must not record stdout/stderr/result paths')}

    # `check --require-pass` validates the evidence body, not just its top-level verdict.
    # Every stale/fail-open mutation requires a fresh run before the next case.
    $evidencePath=Join-Path $r '.work/verification.json'
    $record=Get-Content $evidencePath -Raw|ConvertFrom-Json; $record.commands[0].command='git status --short'; Write-Json $evidencePath $record
    $x=Invoke-Tool @('check','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--head',$head,'--require-pass'); Assert-Eq 4 $x.Exit 'changed/reordered command body is rejected'
    $x=Invoke-Tool @('run','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--base',$base,'--head',$head); Assert-Eq 0 $x.Exit 'fresh run restores command evidence'
    $record=Get-Content $evidencePath -Raw|ConvertFrom-Json; $record.environment_fingerprint='tampered'; Write-Json $evidencePath $record
    $x=Invoke-Tool @('check','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--head',$head,'--require-pass'); Assert-Eq 4 $x.Exit 'changed environment fingerprint is rejected'
    $x=Invoke-Tool @('run','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--base',$base,'--head',$head); Assert-Eq 0 $x.Exit 'fresh run restores environment evidence'
    foreach($badVerdict in @('running','failed','blocked')){
        $record=Get-Content $evidencePath -Raw|ConvertFrom-Json; $record.verdict=$badVerdict; Write-Json $evidencePath $record
        $x=Invoke-Tool @('check','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--head',$head,'--require-pass'); Assert-Eq 4 $x.Exit "$badVerdict evidence is rejected"
        $x=Invoke-Tool @('run','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--base',$base,'--head',$head); Assert-Eq 0 $x.Exit "fresh run restores after $badVerdict"
    }
    $record=Get-Content $evidencePath -Raw|ConvertFrom-Json; $record.commands[0].exit_code=7; Write-Json $evidencePath $record
    $x=Invoke-Tool @('check','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--head',$head,'--require-pass'); Assert-Eq 4 $x.Exit 'nonzero child exit is rejected despite pass verdict'
    $x=Invoke-Tool @('run','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--base',$base,'--head',$head); Assert-Eq 0 $x.Exit 'fresh run restores after nonzero exit'
    $record=Get-Content $evidencePath -Raw|ConvertFrom-Json; $record.commands[0].PSObject.Properties.Remove('reason'); Write-Json $evidencePath $record
    $x=Invoke-Tool @('check','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--head',$head,'--require-pass'); Assert-Eq 4 $x.Exit 'missing terminal command result is rejected'
    $x=Invoke-Tool @('run','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--base',$base,'--head',$head); Assert-Eq 0 $x.Exit 'fresh run restores missing result'
    $record=Get-Content $evidencePath -Raw|ConvertFrom-Json; $record.commands[0].survivors=1; Write-Json $evidencePath $record
    $x=Invoke-Tool @('check','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--head',$head,'--require-pass'); Assert-Eq 4 $x.Exit 'survivors greater than zero are rejected'
    $x=Invoke-Tool @('run','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--base',$base,'--head',$head); Assert-Eq 0 $x.Exit 'fresh run restores after survivor evidence'

    # Schema v2 is type-strict. JSON strings, nulls, objects and one-element arrays
    # must never be accepted through PowerShell scalar coercion.
    $strictEvidence = Get-Content $evidencePath -Raw
    $malformedCases = @(
        [pscustomobject]@{ Name='string exit_code'; Mutate={param($e) $e.commands[0].exit_code='0'} },
        [pscustomobject]@{ Name='string survivors'; Mutate={param($e) $e.commands[0].survivors='0'} },
        [pscustomobject]@{ Name='floating exit_code'; Mutate={param($e) $e.commands[0].exit_code=[double]0.0} },
        [pscustomobject]@{ Name='floating survivors'; Mutate={param($e) $e.commands[0].survivors=[double]0.0} },
        [pscustomobject]@{ Name='string cleanup_attempted'; Mutate={param($e) $e.commands[0].cleanup_attempted='true'} },
        [pscustomobject]@{ Name='numeric cleanup_attempted'; Mutate={param($e) $e.commands[0].cleanup_attempted=1} },
        [pscustomobject]@{ Name='null cleanup_attempted'; Mutate={param($e) $e.commands[0].cleanup_attempted=$null} },
        [pscustomobject]@{ Name='one-element exit_code array'; Mutate={param($e) $e.commands[0].exit_code=[object[]]@(0)} },
        [pscustomobject]@{ Name='survivors object'; Mutate={param($e) $e.commands[0].survivors=[pscustomobject]@{value=0}} },
        [pscustomobject]@{ Name='reason object'; Mutate={param($e) $e.commands[0].reason=[pscustomobject]@{value='ok'}} },
        [pscustomobject]@{ Name='one-element command array'; Mutate={param($e) $e.commands[0].command=[object[]]@([string]$e.commands[0].command)} },
        [pscustomobject]@{ Name='one-element verdict array'; Mutate={param($e) $e.verdict=[object[]]@('pass')} },
        [pscustomobject]@{ Name='null verified_head'; Mutate={param($e) $e.verified_head=$null} },
        [pscustomobject]@{ Name='one-element base array'; Mutate={param($e) $e.base=[object[]]@([string]$e.base)} },
        [pscustomobject]@{ Name='schema object'; Mutate={param($e) $e.schema=[pscustomobject]@{value='orchestra/verification@2'}} },
        [pscustomobject]@{ Name='null updated_at'; Mutate={param($e) $e.updated_at=$null} },
        [pscustomobject]@{ Name='missing profile_source'; Mutate={param($e) $e.PSObject.Properties.Remove('profile_source')} },
        [pscustomobject]@{ Name='commands object'; Mutate={param($e) $e.commands=[pscustomobject]@{value=$e.commands[0]}} },
        [pscustomobject]@{ Name='environment scalar array'; Mutate={param($e) $e.environment.os=[object[]]@([string]$e.environment.os)} },
        [pscustomobject]@{ Name='string environment integer'; Mutate={param($e) $e.environment.processkit_schema=[string]$e.environment.processkit_schema} }
    )
    foreach($case in $malformedCases){
        $bad=$strictEvidence|ConvertFrom-Json
        & $case.Mutate $bad
        Write-Json $evidencePath $bad
        $x=Invoke-Tool @('check','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--head',$head,'--require-pass')
        Assert-Eq 4 $x.Exit "$($case.Name) evidence is rejected without scalar coercion"
    }
    Write-Utf8 $evidencePath "[$strictEvidence]"
    $x=Invoke-Tool @('check','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--head',$head,'--require-pass')
    Assert-Eq 4 $x.Exit 'one-element root object array is rejected without coercion'
    Write-Utf8 $evidencePath $strictEvidence
    $x=Invoke-Tool @('check','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--head',$head,'--require-pass')
    Assert-Eq 0 $x.Exit 'pristine strict schema v2 evidence remains reusable'

    # The command accepted from config is the command executed and recorded. A hash inside
    # the final token is data; only the later whitespace-delimited hash begins a comment.
    # BASH_ENV supplies a hermetic `make` function whose success requires the exact target.
    $bashEnv=Join-Path $r 'verification-bash-env.sh'
    Write-Utf8 $bashEnv "make() { [ `"`$#`" -eq 1 ] && [ `"`$1`" = 'check#fast' ]; }`n"
    $savedBashEnv=$env:BASH_ENV
    try {
        $env:BASH_ENV=$bashEnv.Replace('\','/')
        Write-Utf8 (Join-Path $r '.work/config.md') 'SMOKE_CMD: make check#fast # operator note'
        $x=Invoke-Tool @('run','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--base',$base,'--head',$head,'--json')
        Assert-Eq 0 $x.Exit 'SMOKE_CMD: make check#fast executes the exact in-token-hash target'
        $hashEvidence=(Get-Content (Join-Path $r '.work/verification.json') -Raw | ConvertFrom-Json)
        Assert-Eq 'make check#fast' ([string]$hashEvidence.commands[0].command) 'verification records the exact parsed command without its inline comment'
    } finally {
        if ($null -eq $savedBashEnv) { Remove-Item Env:BASH_ENV -ErrorAction SilentlyContinue } else { $env:BASH_ENV=$savedBashEnv }
    }

    # The supervisor inherits the executable of the current PowerShell host. Put a
    # failing `pwsh` first on PATH: the old hardcoded spawn would hit this shadow,
    # whereas Windows PowerShell 5.1 or PowerShell 7 can both launch their own host.
    $shadowBin=Join-Path ([IO.Path]::GetTempPath()) ('orchestra-verification-shadow-'+[guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($shadowBin); $Dirs.Add($shadowBin)
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        Write-Utf8 (Join-Path $shadowBin 'pwsh.cmd') "@echo off`r`nexit /b 91`r`n"
    } else {
        $shadowPwsh=Join-Path $shadowBin 'pwsh'
        Write-Utf8 $shadowPwsh "#!/bin/sh`nexit 91`n"
        & chmod +x $shadowPwsh
    }
    $savedPath=$env:PATH
    try {
        $env:PATH=$shadowBin+[IO.Path]::PathSeparator+$savedPath
        $null=& pwsh 2>&1
        Assert-Eq 91 $LASTEXITCODE 'test fixture shadows pwsh on PATH'
        Write-Utf8 (Join-Path $r '.work/config.md') 'VERIFICATION_COMMANDS: ["git --version"]'
        $x=Invoke-Tool @('run','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--base',$base,'--head',$head,'--json')
        Assert-Eq 0 $x.Exit 'run resolves the current PowerShell host instead of pwsh from PATH'; Assert-Contains $x.Out '"verdict":"pass"' 'current-host supervisor run passes'
    } finally {
        $env:PATH=$savedPath
    }

    # Exercise the production supervisor-result ingestion path with a hermetic
    # copied tool and fake supervisor. PowerShell 7 unwraps a one-element root
    # array through pipeline output while Windows PowerShell preserves it, so run
    # the same malformed/pristine contract under both hosts when available.
    $fakeToolRoot=Join-Path ([IO.Path]::GetTempPath()) ('orchestra-verification-fake-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($fakeToolRoot); $Dirs.Add($fakeToolRoot)
    $fakeTools=Join-Path $fakeToolRoot 'tools'; [void][IO.Directory]::CreateDirectory($fakeTools)
    foreach($toolName in @('verification.ps1','common.ps1','processkit-runtime.ps1')){
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "..\tools\$toolName") -Destination $fakeTools
    }
    $fakeVerification=Join-Path $fakeTools 'verification.ps1'
    Write-Utf8 (Join-Path $fakeTools 'supervisor.ps1') @'
$result=''
$stdout=''
$stderr=''
for($i=0;$i-lt$args.Count;$i++){
    if($args[$i]-eq'--result-file'){$result=$args[++$i]}
    elseif($args[$i]-eq'--stdout-file'){$stdout=$args[++$i]}
    elseif($args[$i]-eq'--stderr-file'){$stderr=$args[++$i]}
}
[IO.File]::WriteAllText($stdout,'')
[IO.File]::WriteAllText($stderr,'')
[IO.File]::WriteAllText($result,[string]$env:ORCHESTRA_VERIFICATION_FAKE_RESULT)
exit 0
'@
    $verificationHosts=@(
        [pscustomobject]@{
            Name='pwsh'
            Executable=[string](@(Get-Command pwsh -CommandType Application -ErrorAction Stop)|Select-Object -First 1).Source
        }
    )
    if([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT){
        $windowsPowerShell=@(Get-Command powershell.exe -CommandType Application -ErrorAction SilentlyContinue)|Select-Object -First 1
        if($windowsPowerShell){
            $verificationHosts+= [pscustomobject]@{
                Name='windows-powershell'
                Executable=[string]$windowsPowerShell.Source
            }
        }
    }
    $fakeRunCases=@(
        [pscustomobject]@{
            Name='singleton-root-array'
            Json='[{"reason":"ok","exit_code":0,"duration_ms":1,"cleanup_attempted":true,"survivor_count_after_cleanup":0}]'
        },
        [pscustomobject]@{
            Name='concatenated-roots'
            Json='{"reason":"ok","exit_code":0,"duration_ms":1,"cleanup_attempted":true,"survivor_count_after_cleanup":0}{"reason":"ok","exit_code":0,"duration_ms":1,"cleanup_attempted":true,"survivor_count_after_cleanup":0}'
        }
    )
    try {
        Write-Utf8 (Join-Path $r '.work/config.md') 'VERIFICATION_COMMANDS: ["git --version"]'
        foreach($hostCase in $verificationHosts){
            foreach($fakeCase in $fakeRunCases){
                $env:ORCHESTRA_VERIFICATION_FAKE_RESULT=$fakeCase.Json
                $fakeEvidencePath=Join-Path $r ".work/fake-$($hostCase.Name)-$($fakeCase.Name).json"
                $x=Invoke-ToolHost $hostCase.Executable $fakeVerification @(
                    'run','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git',
                    '--base',$base,'--head',$head,'--result-file',$fakeEvidencePath,'--json')
                Assert-Eq 5 $x.Exit "$($hostCase.Name) run rejects $($fakeCase.Name)"
                $fakeEvidence=Get-Content $fakeEvidencePath -Raw|ConvertFrom-Json
                Assert-Eq 'failed' $fakeEvidence.verdict "$($hostCase.Name) $($fakeCase.Name) is failed, never pass"
                Assert-Eq 1 @($fakeEvidence.commands).Count "$($hostCase.Name) $($fakeCase.Name) preserves command result"
                Assert-True (-not (@($fakeEvidence.commands)[0].cleanup_attempted -eq $true)) "$($hostCase.Name) $($fakeCase.Name) is not normalized to terminal green"
            }
            $env:ORCHESTRA_VERIFICATION_FAKE_RESULT='{"reason":"ok","exit_code":0,"duration_ms":1,"cleanup_attempted":true,"survivor_count_after_cleanup":0}'
            $fakeEvidencePath=Join-Path $r ".work/fake-$($hostCase.Name)-pristine.json"
            $x=Invoke-ToolHost $hostCase.Executable $fakeVerification @(
                'run','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git',
                '--base',$base,'--head',$head,'--result-file',$fakeEvidencePath,'--json')
            Assert-Eq 0 $x.Exit "$($hostCase.Name) run accepts pristine supervisor object"
            $fakeEvidence=Get-Content $fakeEvidencePath -Raw|ConvertFrom-Json
            Assert-Eq 'pass' $fakeEvidence.verdict "$($hostCase.Name) pristine supervisor object remains pass"
            Assert-Eq 0 @($fakeEvidence.commands)[0].survivors "$($hostCase.Name) pristine evidence records zero survivors"
            Assert-Eq $true @($fakeEvidence.commands)[0].cleanup_attempted "$($hostCase.Name) pristine evidence records cleanup"
        }
    } finally {
        Remove-Item Env:ORCHESTRA_VERIFICATION_FAKE_RESULT -ErrorAction SilentlyContinue
    }

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
    $x=Invoke-Tool @('check','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--head',$head,'--require-pass')
    Assert-Eq 4 $x.Exit 'exempt evidence is never reusable as an expensive command result'

    # Crash recovery never accepts running evidence or evidence from an old head/profile.
    $record=Get-Content (Join-Path $r '.work/verification.json') -Raw | ConvertFrom-Json; $record.verdict='running'; Write-Utf8 (Join-Path $r '.work/verification.json') ($record | ConvertTo-Json -Depth 12)
    $x=Invoke-Tool @('check','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--head',$head); Assert-Eq 4 $x.Exit 'running crash residue is not reusable'
    Write-Utf8 (Join-Path $r '.work/config.md') 'VERIFICATION_COMMANDS: ["git --version"]'; $x=Invoke-Tool @('run','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--base',$base,'--head',$head); Assert-Eq 0 $x.Exit 'fresh profile reruns after crash residue'
    $newHead=Commit-Code $r "new head`n"; $x=Invoke-Tool @('check','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--head',$newHead); Assert-Eq 4 $x.Exit 'evidence from old head is rejected'

    # Parallel runs share the coordination --work but use separate config roots and
    # result-file-bound invocation artifact roots. Distinct command output must never
    # cross between them.
    $configA=Join-Path $r '.work/config-a'; $configB=Join-Path $r '.work/config-b'
    [void][IO.Directory]::CreateDirectory($configA); [void][IO.Directory]::CreateDirectory($configB)
    Write-Utf8 (Join-Path $configA 'config.md') 'VERIFICATION_COMMANDS: ["printf A; sleep 1"]'
    Write-Utf8 (Join-Path $configB 'config.md') 'VERIFICATION_COMMANDS: ["printf B; sleep 1"]'
    $resultA=Join-Path $r '.work/result-a.json'; $resultB=Join-Path $r '.work/result-b.json'
    $procs=@()
    foreach($case in @(@($configA,$resultA,'a'),@($configB,$resultB,'b'))){
        $outerOut=Join-Path $r ".work/concurrent-$($case[2]).out"
        $outerErr=Join-Path $r ".work/concurrent-$($case[2]).err"
        $toolArgs=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$Tool,
            'run','--work',(Join-Path $r '.work'),'--config-root',$case[0],
            '--root',$r,'--vcs','git','--base',$base,'--head',$newHead,
            '--result-file',$case[1])
        $procs+=Start-Process -FilePath $PsExe -ArgumentList $toolArgs -NoNewWindow -PassThru `
            -RedirectStandardOutput $outerOut -RedirectStandardError $outerErr
    }
    $procs|Wait-Process -Timeout 120
    foreach($p in $procs){$p.Refresh();Assert-Eq 0 $p.ExitCode 'parallel verification run exits green';$p.Dispose()}
    $artifactParent=Join-Path $r '.work/.verification-artifacts'
    $artifactA=@(Get-ChildItem -LiteralPath $artifactParent -Directory -Filter 'result-a.json-*')
    $artifactB=@(Get-ChildItem -LiteralPath $artifactParent -Directory -Filter 'result-b.json-*')
    Assert-Eq 1 $artifactA.Count 'result A owns one unique invocation artifact root'
    Assert-Eq 1 $artifactB.Count 'result B owns one unique invocation artifact root'
    if($artifactA.Count -eq 1){Assert-Eq 'A' ((Get-Content (Join-Path $artifactA[0].FullName 'command-1.out.txt') -Raw).TrimEnd()) 'artifact A output is isolated'}
    if($artifactB.Count -eq 1){Assert-Eq 'B' ((Get-Content (Join-Path $artifactB[0].FullName 'command-1.out.txt') -Raw).TrimEnd()) 'artifact B output is isolated'}

    # A wrapper can stop waiting while the first verification process is still alive.
    # The shared logical result path must reject a duplicate runner before it creates a
    # second invocation artifact or child process.
    Write-Utf8 (Join-Path $r '.work/config.md') 'VERIFICATION_COMMANDS: ["sleep 4"]'
    $stableResult=Join-Path $r '.work/stable-logical-run.json'
    $stableOut=Join-Path $r '.work/stable-logical-run.out'
    $stableErr=Join-Path $r '.work/stable-logical-run.err'
    $stableArgs=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$Tool,
        'run','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git','--base',$base,
        '--head',$newHead,'--deadline-sec','30','--result-file',$stableResult)
    $firstStable=Start-Process -FilePath $PsExe -ArgumentList $stableArgs -NoNewWindow -PassThru `
        -RedirectStandardOutput $stableOut -RedirectStandardError $stableErr
    $stableLock="$stableResult.run.lock"
    $wait=[Diagnostics.Stopwatch]::StartNew()
    while($wait.Elapsed.TotalSeconds-lt 10-and(-not(Test-Path $stableLock))){Start-Sleep -Milliseconds 50}
    Assert-True (Test-Path $stableLock) 'first verification run exposes its stable result lock'
    $x=Invoke-Tool @('run','--work',(Join-Path $r '.work'),'--root',$r,'--vcs','git',
        '--base',$base,'--head',$newHead,'--deadline-sec','30','--result-file',$stableResult)
    Assert-Eq 2 $x.Exit 'duplicate verification run for the same result-file is rejected'
    Assert-Contains $x.Out 'verification run already active' 'duplicate verification run reports the active logical invocation'
    $firstStable|Wait-Process -Timeout 30
    $firstStable.Refresh(); Assert-Eq 0 $firstStable.ExitCode 'original verification run completes normally'
    $firstStable.Dispose()
    Assert-True (-not(Test-Path $stableLock)) 'terminal verification run releases its stable result lock'
    $stableArtifacts=@(Get-ChildItem -LiteralPath $artifactParent -Directory -Filter 'stable-logical-run.json-*')
    Assert-Eq 1 $stableArtifacts.Count 'duplicate verification run creates no second invocation artifact root'

    # Jujutsu reviewers verify the sealed bookmark, not the empty WIP workspace @.
    if(Get-Command jj -ErrorAction SilentlyContinue){
        $j=New-Repo
        $jjInitOutput=@(& jj git init --colocate $j 2>&1|ForEach-Object{$_.ToString()})
        if($LASTEXITCODE-ne 0){throw "jj fixture init failed for [$j]: $($jjInitOutput-join ' | ')"}
        & jj -R $j bookmark create task-fixture -r '@-' 2>&1|Out-Null
        $sealed=(& jj -R $j log -r task-fixture --no-graph -T 'commit_id').Trim()
        $wip=(& jj -R $j log -r '@' --no-graph -T 'commit_id').Trim()
        $jbase=(& jj -R $j log -r 'task-fixture-' --no-graph -T 'commit_id').Trim()
        Assert-True ($sealed -ne $wip) 'jj fixture has sealed parent bookmark and distinct empty WIP child'
        Write-Utf8 (Join-Path $j '.work/config.md') 'VERIFICATION_COMMANDS: ["git --version"]'
        $je=Join-Path $j '.work/sealed.json'
        $x=Invoke-Tool @('run','--work',(Join-Path $j '.work'),'--root',$j,'--vcs','jj',
            '--revision','task-fixture','--base',$jbase,'--head',$sealed,'--result-file',$je)
        Assert-Eq 0 $x.Exit 'jj run verifies sealed bookmark while workspace @ is WIP child'
        $x=Invoke-Tool @('check','--work',(Join-Path $j '.work'),'--root',$j,'--vcs','jj',
            '--revision','task-fixture','--head',$sealed,'--result-file',$je,'--require-pass')
        Assert-Eq 0 $x.Exit 'jj check reuses sealed bookmark evidence'
        $x=Invoke-Tool @('check','--work',(Join-Path $j '.work'),'--root',$j,'--vcs','jj',
            '--revision','task-fixture','--head',$wip,'--result-file',$je,'--require-pass')
        Assert-Eq 3 $x.Exit 'jj sealed bookmark rejects neighboring WIP revision'
        $x=Invoke-Tool @('check','--work',(Join-Path $j '.work'),'--root',$j,'--vcs','jj',
            '--revision','task-fixture|@','--head',$sealed,'--result-file',$je,'--require-pass')
        Assert-Eq 2 $x.Exit 'jj revision selector must resolve exactly one commit'
    } else {
        Write-Host 'SKIP - jj executable unavailable; sealed-bookmark regression not run.'
    }
}
finally { foreach($d in $Dirs){if(Test-Path $d){Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue}} }
if($Failures.Count){Write-Host "FAILED - $($Failures.Count) assertion(s):"; $Failures|ForEach-Object{Write-Host "  $_"}; exit 1}
Write-Host 'OK - verification profiles cover missing, multiple, failed, docs-only, disabled, and crash-recovery cases.'
exit 0
