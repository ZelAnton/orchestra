<#
  Fixture tests for tools/sync-runtime.ps1 - the cross-platform sync engine that
  launchers/cc-sync.cmd and launchers/cc-sync.sh delegate to (task T-090).

  These drive the runtime as a child pwsh process against a synthetic repo tree and
  a throwaway destination root, so they never touch the real ~/.claude mirror or this
  repository's working copy. Because the runtime is a single pwsh script, running this
  same suite under pwsh on Windows and on Linux exercises byte-for-byte the same code
  path: the pass/fail result is the cross-platform equivalence proof for sync.

  Covered:
    - a clean mirror publishes agents, launchers, config templates and the WHOLE
      tools/*.ps1 runner folder (except cc-sync's own engine) + a manifest (T-115);
    - stale pruning removes only files recorded in the manifest (a removed agent AND a
      removed runner), never foreign files;
    - a mid-publish failure rolls the mirror back to its exact prior state (no partial
      apply) and leaves the manifest untouched;
    - an empty-directory husk at a destination is healed into the mirrored file;
    - a journal left by a crashed run is recovered (rolled back) on the next run.
    - manifest and recovery-journal paths cannot escape their managed root.

  Usage:
    pwsh -File tests/launchers/test-sync-runtime.ps1
#>

# ci:posix - cross-platform; run-all.ps1 runs this under pwsh on Linux in CI too.
$ErrorActionPreference = 'Stop'

$script:Runtime = (Resolve-Path (Join-Path $PSScriptRoot '..\..\tools\sync-runtime.ps1')).Path
$script:Failures = New-Object System.Collections.ArrayList
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)

$script:Pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)
if (-not $script:Pwsh) {
    Write-Host 'SKIP - pwsh not found on PATH; the cross-platform sync runtime requires PowerShell 7.'
    exit 0
}

function New-Root {
    $r = Join-Path ([System.IO.Path]::GetTempPath()) ("orc-sync-test-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $r | Out-Null
    return $r
}

function Write-File {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8)
}

function New-SyntheticRepo {
    # A minimal but realistic checkout: agents/ (with the two excluded templates),
    # launchers/ (.cmd and .sh), and both config templates. No generate-coders.ps1
    # or tools/validate-agents.ps1, so regen/validate no-op (also -SkipRegen/-SkipValidate).
    $repo = New-Root
    Write-File (Join-Path $repo 'agents\coder.template.md') "name: {{NAME}}`n"
    Write-File (Join-Path $repo 'agents\reviewer.template.md') "name: {{NAME}}`n"
    Write-File (Join-Path $repo 'agents\coder.md') "coder-v1`n"
    Write-File (Join-Path $repo 'agents\reviewer.md') "reviewer-v1`n"
    Write-File (Join-Path $repo 'agents\processor.md') "processor-v1`n"
    Write-File (Join-Path $repo 'codex\processor.md') "codex-processor-v1`n"
    Write-File (Join-Path $repo 'codex\agents\orchestra_coder.toml') "name = 'orchestra_coder'`n"
    Write-File (Join-Path $repo 'codex\agents\orchestra_reviewer.toml') "name = 'orchestra_reviewer'`n"
    Write-File (Join-Path $repo 'launchers\cc-sync.cmd') "@echo off`n"
    Write-File (Join-Path $repo 'launchers\cc-doctor.cmd') "@echo off`n"
    Write-File (Join-Path $repo 'launchers\cc-sync.sh') "#!/usr/bin/env bash`n"
    # tools/*.ps1: sync mirrors the WHOLE folder into scripts/ (task T-115), except its own
    # sync-runtime.ps1 engine, so EVERY runner resolves from a mirror-only project. The
    # launcher engines the thin cc-doctor wrappers / codex adapters delegate to
    # (doctor-runtime.ps1, codex-runtime.ps1 - T-114) plus the transactional/orchestration
    # runners the agents call directly (state-tx.ps1, queue-tx.ps1, ...) must all travel with
    # the mirror; sync-runtime.ps1 is present here to prove it is the sole EXCLUSION.
    Write-File (Join-Path $repo 'tools\doctor-runtime.ps1') "doctor-rt-v1`n"
    Write-File (Join-Path $repo 'tools\codex-runtime.ps1') "codex-rt-v1`n"
    Write-File (Join-Path $repo 'tools\state-tx.ps1') "state-tx-v1`n"
    Write-File (Join-Path $repo 'tools\queue-tx.ps1') "queue-tx-v1`n"
    Write-File (Join-Path $repo 'tools\verification.ps1') "verification-v1`n"
    Write-File (Join-Path $repo 'tools\sync-runtime.ps1') "sync-rt-SELF`n"
    Write-File (Join-Path $repo 'config.example.md') "config-v1`n"
    Write-File (Join-Path $repo 'constraints.example.md') "constraints-v1`n"
    return $repo
}

function Invoke-Sync {
    param([string]$Repo, [string]$Dest, [string]$Glob = '*.cmd')
    $rtArgs = @('-NoProfile', '-File', $script:Runtime,
        '-RepoRoot', $Repo, '-DestinationRoot', $Dest,
        '-LauncherGlob', $Glob, '-SkipRegen', '-SkipValidate', '-Quiet')
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $p = Start-Process -FilePath $script:Pwsh.Source -ArgumentList $rtArgs -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $out = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
    $err = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $outFile, $errFile -ErrorAction SilentlyContinue
    $exit = if ($null -ne $p -and $null -ne $p.ExitCode) { [int]$p.ExitCode } else { -1 }
    return [pscustomobject]@{
        ExitCode = $exit
        Out      = [string]([string]$out)
        Err      = if ($null -eq $err) { '' } else { [string]$err }
    }
}

function Assert-True { param([bool]$Cond, [string]$Msg) if (-not $Cond) { [void]$script:Failures.Add("FAIL - $Msg") } }
function Assert-FileText {
    param([string]$Path, [string]$Expected, [string]$Msg)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { [void]$script:Failures.Add("FAIL - ${Msg}: file missing ($Path)"); return }
    $actual = [System.IO.File]::ReadAllText($Path)
    if ($actual -ne $Expected) { [void]$script:Failures.Add("FAIL - ${Msg}: content [$actual] != [$Expected]") }
}

# =============================================================================
# 1) Clean mirror: agents (minus templates) + launchers + templates + manifest
# =============================================================================
$repo = New-SyntheticRepo
$dest = New-Root
$r = Invoke-Sync -Repo $repo -Dest $dest
Assert-True ($r.ExitCode -eq 0) "clean sync exits 0 (got $($r.ExitCode); err=$($r.Err.Trim()))"
Assert-FileText (Join-Path $dest 'agents\coder.md') "coder-v1`n" 'clean: coder.md mirrored'
Assert-FileText (Join-Path $dest 'agents\processor.md') "processor-v1`n" 'clean: processor.md mirrored'
Assert-True (-not (Test-Path (Join-Path $dest 'agents\coder.template.md'))) 'clean: coder.template.md excluded'
Assert-True (-not (Test-Path (Join-Path $dest 'agents\reviewer.template.md'))) 'clean: reviewer.template.md excluded'
Assert-FileText (Join-Path $dest 'scripts\cc-sync.cmd') "@echo off`n" 'clean: cc-sync.cmd mirrored'
Assert-True (-not (Test-Path (Join-Path $dest 'scripts\cc-sync.sh'))) 'clean: .sh not mirrored when glob is *.cmd'
Assert-FileText (Join-Path $dest 'scripts\config.example.md') "config-v1`n" 'clean: config.example.md mirrored'
Assert-FileText (Join-Path $dest 'scripts\constraints.example.md') "constraints-v1`n" 'clean: constraints.example.md mirrored'
Assert-FileText (Join-Path $dest 'scripts\codex-processor.md') "codex-processor-v1`n" 'clean: Codex root processor prompt mirrored beside runtimes'
Assert-FileText (Join-Path $dest 'scripts\doctor-runtime.ps1') "doctor-rt-v1`n" 'clean: doctor-runtime.ps1 mirrored next to the launchers (so cc-doctor runs from the mirror)'
Assert-FileText (Join-Path $dest 'scripts\codex-runtime.ps1') "codex-rt-v1`n" 'clean: codex-runtime.ps1 mirrored next to the launchers (so coder_codex/reviewer_codex resolve it from the mirror - T-114)'
# T-115: the WHOLE tools/*.ps1 folder is mirrored, not a curated allowlist, so the
# transactional/orchestration runners the agents call directly travel with the mirror too.
Assert-FileText (Join-Path $dest 'scripts\state-tx.ps1') "state-tx-v1`n" 'clean: state-tx.ps1 mirrored (whole tools/ folder - T-115)'
Assert-FileText (Join-Path $dest 'scripts\queue-tx.ps1') "queue-tx-v1`n" 'clean: queue-tx.ps1 mirrored (whole tools/ folder - T-115)'
Assert-FileText (Join-Path $dest 'scripts\verification.ps1') "verification-v1`n" 'clean: verification.ps1 mirrored for SHA-bound pre-push gates (T-270)'
# ...but cc-sync's own engine is the sole exclusion (dead weight in a mirror).
Assert-True (-not (Test-Path (Join-Path $dest 'scripts\sync-runtime.ps1'))) 'clean: sync-runtime.ps1 NOT mirrored (cc-sync engine is the sole tools/*.ps1 exclusion)'
$codexDest = Join-Path $dest '.codex'
Assert-FileText (Join-Path $codexDest 'agents\orchestra_coder.toml') "name = 'orchestra_coder'`n" 'clean: generated Codex coder role installed under isolated CODEX_HOME'
Assert-FileText (Join-Path $codexDest 'agents\orchestra_reviewer.toml') "name = 'orchestra_reviewer'`n" 'clean: generated Codex reviewer role installed under isolated CODEX_HOME'
$codexManifest = Join-Path $codexDest '.orchestra-agent-sync-manifest.json'
Assert-True (Test-Path -LiteralPath $codexManifest) 'clean: Codex role manifest written'
$manifestPath = Join-Path $dest '.orchestra-sync-manifest.json'
Assert-True (Test-Path -LiteralPath $manifestPath) 'clean: manifest written'
if (Test-Path -LiteralPath $manifestPath) {
    $mf = [System.IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    Assert-True (@($mf.managed) -contains 'agents/coder.md') 'clean: manifest lists agents/coder.md'
    Assert-True (@($mf.managed) -contains 'scripts/config.example.md') 'clean: manifest lists scripts/config.example.md'
    Assert-True (@($mf.managed) -contains 'scripts/doctor-runtime.ps1') 'clean: manifest lists scripts/doctor-runtime.ps1'
    Assert-True (@($mf.managed) -contains 'scripts/codex-runtime.ps1') 'clean: manifest lists scripts/codex-runtime.ps1'
    Assert-True (@($mf.managed) -contains 'scripts/state-tx.ps1') 'clean: manifest lists scripts/state-tx.ps1 (T-115)'
    Assert-True (@($mf.managed) -contains 'scripts/verification.ps1') 'clean: manifest lists scripts/verification.ps1 (T-270)'
    Assert-True (@($mf.managed) -contains 'scripts/codex-processor.md') 'clean: manifest lists Codex processor prompt'
    Assert-True (-not (@($mf.managed) -contains 'scripts/sync-runtime.ps1')) 'clean: manifest excludes cc-sync own engine'
    Assert-True (-not (@($mf.managed) -contains 'agents/coder.template.md')) 'clean: manifest excludes template'
}

# =============================================================================
# 2) Stale pruning removes only managed files; foreign files are untouched
# =============================================================================
# Add a foreign agent the tool never wrote, then drop a source agent AND a source runner
# and re-sync. The runner drop proves manifest-based pruning still removes a tools/*.ps1
# that stopped existing in the source (T-115 criterion), exactly like a removed agent.
Write-File (Join-Path $dest 'agents\custom_local.md') "mine`n"
Write-File (Join-Path $codexDest 'agents\custom_local.toml') "name = 'mine'`n"
Remove-Item -LiteralPath (Join-Path $repo 'agents\reviewer.md') -Force
Remove-Item -LiteralPath (Join-Path $repo 'tools\queue-tx.ps1') -Force
Remove-Item -LiteralPath (Join-Path $repo 'codex\agents\orchestra_reviewer.toml') -Force
$r2 = Invoke-Sync -Repo $repo -Dest $dest
Assert-True ($r2.ExitCode -eq 0) "prune sync exits 0 (got $($r2.ExitCode); err=$($r2.Err.Trim()))"
Assert-True (-not (Test-Path (Join-Path $dest 'agents\reviewer.md'))) 'prune: removed source agent pruned from mirror'
Assert-True (-not (Test-Path (Join-Path $dest 'scripts\queue-tx.ps1'))) 'prune: removed source runner pruned from mirror (T-115)'
Assert-FileText (Join-Path $dest 'scripts\state-tx.ps1') "state-tx-v1`n" 'prune: still-sourced runner kept'
Assert-FileText (Join-Path $dest 'agents\custom_local.md') "mine`n" 'prune: foreign file untouched'
Assert-FileText (Join-Path $dest 'agents\coder.md') "coder-v1`n" 'prune: still-sourced agent kept'
Assert-True (-not (Test-Path (Join-Path $codexDest 'agents\orchestra_reviewer.toml'))) 'prune: removed generated Codex role pruned from its own manifest'
Assert-FileText (Join-Path $codexDest 'agents\custom_local.toml') "name = 'mine'`n" 'prune: foreign Codex custom agent untouched'

# =============================================================================
# 3) Mid-publish failure rolls back to the exact prior state
# =============================================================================
$repoR = New-SyntheticRepo
$destR = New-Root
$r0 = Invoke-Sync -Repo $repoR -Dest $destR
Assert-True ($r0.ExitCode -eq 0) 'rollback: initial clean sync exits 0'
$manifestR = Join-Path $destR '.orchestra-sync-manifest.json'
$manifestBefore = [System.IO.File]::ReadAllText($manifestR)
# Change a source agent so a successful re-sync WOULD overwrite its mirrored copy...
Write-File (Join-Path $repoR 'agents\coder.md') "coder-CHANGED`n"
# ...then poison the LAST destination (constraints.example.md) with a NON-empty
# directory, which the runtime must refuse and roll back.
$poison = Join-Path $destR 'scripts\constraints.example.md'
Remove-Item -LiteralPath $poison -Force
New-Item -ItemType Directory -Force -Path $poison | Out-Null
Write-File (Join-Path $poison 'do-not-delete.txt') "real data`n"
$r3 = Invoke-Sync -Repo $repoR -Dest $destR
Assert-True ($r3.ExitCode -eq 1) "rollback: poisoned sync exits 1 (got $($r3.ExitCode))"
Assert-FileText (Join-Path $destR 'agents\coder.md') "coder-v1`n" 'rollback: mirrored agent restored to prior content (no partial apply)'
Assert-True (Test-Path (Join-Path $poison 'do-not-delete.txt')) 'rollback: non-empty blocking dir left intact'
$manifestAfter = [System.IO.File]::ReadAllText($manifestR)
Assert-True ($manifestBefore -eq $manifestAfter) 'rollback: manifest unchanged after a rolled-back sync'
Assert-True (-not (Test-Path (Join-Path $destR '.orchestra-sync-tx'))) 'rollback: transaction workspace cleaned up'

# =============================================================================
# 4) Empty-directory husk at a destination is healed into the file
# =============================================================================
$repoH = New-SyntheticRepo
$destH = New-Root
$null = Invoke-Sync -Repo $repoH -Dest $destH
$husk = Join-Path $destH 'agents\coder.md'
Remove-Item -LiteralPath $husk -Force
New-Item -ItemType Directory -Force -Path $husk | Out-Null   # empty directory husk
$r4 = Invoke-Sync -Repo $repoH -Dest $destH
Assert-True ($r4.ExitCode -eq 0) "heal: sync over an empty-dir husk exits 0 (got $($r4.ExitCode); err=$($r4.Err.Trim()))"
Assert-FileText $husk "coder-v1`n" 'heal: empty-dir husk healed back into the file'

# =============================================================================
# 5) A journal left by a crashed run is recovered on the next run
# =============================================================================
$repoC = New-SyntheticRepo
$destC = New-Root
New-Item -ItemType Directory -Force -Path $destC | Out-Null
# Simulate a crash after a run created a file it had not committed to the manifest:
# a leftover journal says that file was 'created' (undo = remove).
$ghost = Join-Path $destC 'agents\ghost.md'
Write-File $ghost "leftover`n"
$txDir = Join-Path $destC '.orchestra-sync-tx'
New-Item -ItemType Directory -Force -Path $txDir | Out-Null
$entry = @{ dest = $ghost; undo = 'remove'; backup = $null } | ConvertTo-Json -Compress
Set-Content -LiteralPath (Join-Path $txDir 'journal.jsonl') -Value $entry -Encoding utf8
$r5 = Invoke-Sync -Repo $repoC -Dest $destC
Assert-True ($r5.ExitCode -eq 0) "recovery: sync after a crashed run exits 0 (got $($r5.ExitCode); err=$($r5.Err.Trim()))"
Assert-True (-not (Test-Path $ghost)) 'recovery: journal-recorded partial file rolled back on startup'
Assert-True (-not (Test-Path $txDir)) 'recovery: leftover transaction workspace cleared'

# =============================================================================
# 6) Corrupted manifest/journal paths cannot escape the managed root
# =============================================================================
$repoS = New-SyntheticRepo
$destS = New-Root
$null = Invoke-Sync -Repo $repoS -Dest $destS
$outside = Join-Path (Split-Path -Parent $destS) ('outside-' + [Guid]::NewGuid().ToString('N') + '.txt')
Write-File $outside "must-survive`n"
$manifestS = Join-Path $destS '.orchestra-sync-manifest.json'
$mfS = [System.IO.File]::ReadAllText($manifestS) | ConvertFrom-Json
$mfS.managed = @($mfS.managed) + ('../' + (Split-Path -Leaf $outside))
[System.IO.File]::WriteAllText($manifestS, ($mfS | ConvertTo-Json -Depth 5), $script:Utf8)
$r6 = Invoke-Sync -Repo $repoS -Dest $destS
Assert-True ($r6.ExitCode -eq 0) "path guard: unsafe manifest entry is ignored without breaking safe sync (got $($r6.ExitCode))"
Assert-FileText $outside "must-survive`n" 'path guard: manifest traversal cannot prune outside file'

$txS = Join-Path $destS '.orchestra-sync-tx'
New-Item -ItemType Directory -Force -Path $txS | Out-Null
$unsafeEntry = @{ dest = $outside; undo = 'remove'; backup = $null } | ConvertTo-Json -Compress
Set-Content -LiteralPath (Join-Path $txS 'journal.jsonl') -Value $unsafeEntry -Encoding utf8
$r7 = Invoke-Sync -Repo $repoS -Dest $destS
Assert-True ($r7.ExitCode -eq 0) "path guard: unsafe recovery entry is ignored without breaking safe sync (got $($r7.ExitCode))"
Assert-FileText $outside "must-survive`n" 'path guard: journal traversal cannot remove outside file'

# =============================================================================
# 7) Get-ManagedPairs/Get-CodexManagedPairs never join a literal backslash into
#    a Join-Path string argument (regression: `Join-Path $Repo 'codex\processor.md'`
#    is only a valid separator on Windows; under pwsh on POSIX - this file is
#    tagged ci:posix and run-all.ps1 runs it there too in CI - the backslash is
#    just a literal filename character, so Test-Path silently fails to find the
#    REAL codex/processor.md and codex/agents/*.toml on disk, giving a silent
#    "Synced 0 ..." with no Codex prompt/agent mirrored - the class of bug the
#    existing scenarios above never caught).
# =============================================================================
# 7a) Static check on the ACTUAL script text (T-284 KB pitfall K-041: assert
#     against the real functions, not a hand-rolled reimplementation), and
#     deterministic on ANY host OS since it never depends on which directory
#     separator the test process itself happens to run under.
$runtimeText = Get-Content -LiteralPath $script:Runtime -Raw
$mppMatch = [regex]::Match($runtimeText, '(?s)function Get-ManagedPairs\b.*?\n\}\r?\n')
$cmppMatch = [regex]::Match($runtimeText, '(?s)function Get-CodexManagedPairs\b.*?\n\}\r?\n')
Assert-True $mppMatch.Success 'posix-path: Get-ManagedPairs function body located for inspection'
Assert-True $cmppMatch.Success 'posix-path: Get-CodexManagedPairs function body located for inspection'
$literalBackslashInJoin = "(?m)Join-Path\s+[^\r\n]*'[^']*\\[^']*'"
if ($mppMatch.Success) {
    Assert-True (-not [regex]::IsMatch($mppMatch.Value, $literalBackslashInJoin)) 'posix-path: Get-ManagedPairs builds no Join-Path with a literal backslash inside a string argument (codex\processor.md regression)'
}
if ($cmppMatch.Success) {
    Assert-True (-not [regex]::IsMatch($cmppMatch.Value, $literalBackslashInJoin)) 'posix-path: Get-CodexManagedPairs builds no Join-Path with a literal backslash inside a string argument (codex\agents regression)'
}

# 7b) Dynamic check: dot-source ONLY the real function definitions (everything
#     before the "# Main" execution block, which calls exit and would otherwise
#     terminate this test process) and drive Get-ManagedPairs/Get-CodexManagedPairs
#     directly against a synthetic $Repo, verifying - via a DirectorySeparatorChar-
#     agnostic Split-Path decomposition, not a literal-backslash string scan - that
#     the Codex prompt/agent pairs resolve to the correct leaf/parent names.
#     NOTE (R-01, verified empirically against a real pwsh 7.4.6 on Linux): this
#     dynamic check alone does NOT distinguish old vs. new Get-ManagedPairs /
#     Get-CodexManagedPairs behavior on POSIX, because pwsh's Join-Path cmdlet
#     normalizes an embedded literal backslash in a ChildPath string argument to
#     '/' on that platform - so the pre-fix `Join-Path $Repo 'codex\processor.md'`
#     already resolved correctly there too, and this assertion block passes
#     unchanged on both the old and the new code. It is kept because it still
#     documents and guards the expected resolved Source paths going forward, but
#     the actual behavioral regression guard for this bug class is the static
#     text-pattern check 7a above (which does fail against the pre-fix source).
#     If a POSIX host/pwsh build exists where Join-Path does NOT normalize the
#     backslash, this block would also fail there pre-fix; none such was found
#     during T-284 verification.
$repoP = New-SyntheticRepo
try {
    $lines = Get-Content -LiteralPath $script:Runtime
    $mainLineIdx = (($lines | Select-String -Pattern '^# Main$' | Select-Object -First 1).LineNumber)
    Assert-True ($null -ne $mainLineIdx) 'posix-path: located "# Main" marker to isolate function definitions'
    if ($null -ne $mainLineIdx) {
        # Drop the "# ====" banner line(s) immediately preceding "# Main" too.
        $cut = $mainLineIdx - 1
        while ($cut -gt 0 -and $lines[$cut - 1] -match '^#\s*=+\s*$') { $cut-- }
        $funcOnlyText = ($lines[0..($cut - 1)] -join "`n") + "`n"
        $tmpFuncScript = Join-Path ([System.IO.Path]::GetTempPath()) ("orc-sync-funcs-" + [Guid]::NewGuid().ToString('N') + '.ps1')
        [System.IO.File]::WriteAllText($tmpFuncScript, $funcOnlyText, $script:Utf8)
        try {
            . $tmpFuncScript
            $destP = Join-Path $repoP 'dest-unused'
            $pairs = Get-ManagedPairs -Repo $repoP -Dest $destP -Glob '*.cmd'
            $codexPromptPair = @($pairs | Where-Object { $_.Kind -eq 'codex_prompt' })
            Assert-True ($codexPromptPair.Count -eq 1) 'posix-path: Get-ManagedPairs finds exactly one codex_prompt pair'
            if ($codexPromptPair.Count -eq 1) {
                $src = $codexPromptPair[0].Source
                Assert-True ((Split-Path -Leaf $src) -eq 'processor.md') "posix-path: codex prompt Source leaf is processor.md (got $src)"
                Assert-True ((Split-Path -Leaf (Split-Path -Parent $src)) -eq 'codex') "posix-path: codex prompt Source parent leaf is codex (got $src)"
                Assert-True (Test-Path -LiteralPath $src -PathType Leaf) "posix-path: codex prompt Source resolves to the real file on this host ($src)"
            }
            $codexPairs = @(Get-CodexManagedPairs -Repo $repoP -Dest (Join-Path $destP '.codex'))
            Assert-True ($codexPairs.Count -eq 2) 'posix-path: Get-CodexManagedPairs finds both synthetic Codex custom agents'
            foreach ($cp in $codexPairs) {
                Assert-True ((Split-Path -Leaf (Split-Path -Parent $cp.Source)) -eq 'agents') "posix-path: codex agent Source parent leaf is agents (got $($cp.Source))"
                Assert-True (Test-Path -LiteralPath $cp.Source -PathType Leaf) "posix-path: codex agent Source resolves to the real file on this host ($($cp.Source))"
            }
        } finally {
            Remove-Item -LiteralPath $tmpFuncScript -Force -ErrorAction SilentlyContinue
        }
    }
} finally {
    Remove-Item -LiteralPath $repoP -Recurse -Force -ErrorAction SilentlyContinue
}

# =============================================================================
# Report + cleanup
# =============================================================================
foreach ($d in @($repo, $dest, $repoR, $destR, $repoH, $destH, $repoC, $destC, $repoS, $destS)) {
    Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath $outside -Force -ErrorAction SilentlyContinue

if ($script:Failures.Count -gt 0) {
    Write-Host "test-sync-runtime: $($script:Failures.Count) failure(s):"
    foreach ($f in $script:Failures) { Write-Host "  $f" }
    exit 1
}
Write-Host 'OK - tools/sync-runtime.ps1 behaves per contract (clean mirror, stale pruning, rollback, dir-heal, crash recovery).'
exit 0
