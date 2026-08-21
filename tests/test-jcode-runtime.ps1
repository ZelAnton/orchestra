# ci:posix
<#
.SYNOPSIS
    Gate for the jcode leaf-engine contract: fail-closed engine routing, the pinned role
    tool profiles, and the snapshot/guard-tree isolation pair.

.DESCRIPTION
    The jcode adapters (agents/coder_jcode.md, agents/reviewer_jcode.md) rest on three
    guarantees that are invisible at review time and silent when broken, so each is
    exercised here against the REAL entry points, never a test-only mode:

      1. Engine routing (tools/policy.ps1 check-engine-routing). CODEX_* and JCODE_*
         range over the same executor tiers. Orchestra refuses an overlapping
         configuration instead of applying precedence, because precedence would leave
         the effective engine invisible. Also covered: the deep tier may not be routed
         to jcode without an explicit deep model, since `jcode run` has no
         reasoning-effort flag to carry that depth.

      2. Role tool profiles (tools/jcode-runtime.ps1 build-argv). The reviewer profile
         is the reviewer's ONLY containment - jcode is unsandboxed, so a reviewer that
         ever gained `bash` or a write tool could mutate the tree under review. The
         profile is asserted by content, not merely by name.

      3. Isolation detection (snapshot + guard-tree) over a disposable git fixture:
         legitimate target edits, a revision created inside the target, rewrites of an
         already-dirty main-checkout file, and writes to a known sibling worktree. A
         guard that accepted a protected-tree write would leave coder_jcode without its
         advertised compensating control.

    Everything is hermetic: fixtures live under the OS temp dir and no jcode binary,
    model provider or network is involved. Nothing in this repository is modified.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$PolicyTool = Join-Path $RepoRoot 'tools/policy.ps1'
$JcodeTool = Join-Path $RepoRoot 'tools/jcode-runtime.ps1'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Failures = [System.Collections.Generic.List[string]]::new()
$TempRoots = [System.Collections.Generic.List[string]]::new()

# Reuse the interpreter running this test rather than assuming `pwsh` is on PATH: a
# silent skip would hide the gate instead of proving it.
$PwshExe = (Get-Process -Id $PID).Path
if ([string]::IsNullOrWhiteSpace($PwshExe)) { $PwshExe = 'pwsh' }

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ("$Expected" -ne "$Actual") {
        $Failures.Add("$Message (expected '$Expected', got '$Actual')")
    }
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { $Failures.Add($Message) }
}

function New-TempDir {
    param([string]$Prefix)
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefix + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($dir)
    $TempRoots.Add($dir)
    return $dir
}

function Invoke-Tool {
    # Runs one repo entry point and captures its exit code plus merged output.
    param([string]$Tool, [string[]]$ToolArgs, [hashtable]$EnvOverride = @{})
    $saved = @{}
    # Routing keys deliberately support OS-environment fallback. Clear the complete
    # relation for every fixture before applying this case's overrides; otherwise a
    # developer's real CODEX_REVIEWER/JCODE_* setting can create a phantom conflict and
    # make this supposedly hermetic suite host-dependent.
    $isolatedKeys = @(
        'CODEX_CODER', 'CODEX_REVIEWER', 'JCODE_CODER', 'JCODE_REVIEWER',
        'JCODE_CODER_DEEP_MODEL', 'JCODE_REVIEWER_DEEP_MODEL'
    )
    foreach ($k in $isolatedKeys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, $null)
    }
    foreach ($k in $EnvOverride.Keys) {
        if (-not $saved.ContainsKey($k)) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
        [Environment]::SetEnvironmentVariable($k, [string]$EnvOverride[$k])
    }
    try {
        $out = & $PwshExe @('-NoProfile', '-File', $Tool) @ToolArgs 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = (@($out) -join "`n") }
    } finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
}

function New-WorkFixture {
    param([string]$ConfigBody)
    $root = New-TempDir 'orchestra-jcode-work-'
    $work = Join-Path $root '.work'
    [void][System.IO.Directory]::CreateDirectory($work)
    [System.IO.File]::WriteAllText((Join-Path $work 'config.md'), $ConfigBody, $Utf8NoBom)
    return $work
}

function Invoke-Git {
    param([string]$Dir, [string[]]$GitArgs)
    $output = @(& git @('-C', $Dir) @GitArgs 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git fixture command failed: git -C '$Dir' $($GitArgs -join ' ')`n$($output -join "`n")"
    }
}

try {
    # ======================================================================
    # 1. Engine routing is fail-closed on tier overlap
    # ======================================================================

    $emptyWork = New-WorkFixture "# no engine keys set`n"

    $clean = Invoke-Tool -Tool $PolicyTool -ToolArgs @('check-engine-routing', '--work', $emptyWork)
    Assert-Equal 0 $clean.ExitCode 'an all-off routing configuration is coherent'
    Assert-True ($clean.Text -match 'OK\s+engine routing coherent') 'the coherent case reports OK'

    $codexOnly = Invoke-Tool -Tool $PolicyTool -ToolArgs @('check-engine-routing', '--work', $emptyWork) `
        -EnvOverride @{ CODEX_CODER = 'fast+std' }
    Assert-Equal 0 $codexOnly.ExitCode 'one engine owning a side is coherent'

    # The core rule: same tier claimed twice -> refuse, do NOT pick a winner.
    $overlap = Invoke-Tool -Tool $PolicyTool -ToolArgs @('check-engine-routing', '--work', $emptyWork) `
        -EnvOverride @{ CODEX_CODER = 'fast+std'; JCODE_CODER = 'fast' }
    Assert-Equal 3 $overlap.ExitCode 'overlapping coder tiers fail the routing gate closed'
    Assert-True ($overlap.Text -match 'both claim tier\(s\): fast') 'the conflict names the exact overlapping tier'
    Assert-True ($overlap.Text -notmatch 'wins') 'the gate refuses rather than applying precedence'

    # Reviewer `deep` is cumulative: it owns fast/std in full mode and deep in augment
    # mode. Treating it as deep-only would let two engines silently own fast/std.
    $deepOverlap = Invoke-Tool -Tool $PolicyTool -ToolArgs @('check-engine-routing', '--work', $emptyWork) `
        -EnvOverride @{
            CODEX_REVIEWER = 'fast+std'
            JCODE_REVIEWER = 'deep'
            JCODE_REVIEWER_DEEP_MODEL = 'claude-opus-4-6'
        }
    Assert-Equal 3 $deepOverlap.ExitCode 'reviewer deep overlaps fast/std claims and fails closed'
    Assert-True ($deepOverlap.Text -match 'both claim tier\(s\): fast, std') `
        'the cumulative reviewer-deep conflict names fast and std'

    # Overlap is computed per side: codex on the coder side and jcode on the reviewer
    # side is a legitimate split and must stay allowed.
    $split = Invoke-Tool -Tool $PolicyTool -ToolArgs @('check-engine-routing', '--work', $emptyWork) `
        -EnvOverride @{ CODEX_CODER = 'all'; JCODE_REVIEWER = 'fast+std' }
    Assert-Equal 0 $split.ExitCode 'different engines on the coder and reviewer sides do not conflict'

    # Deep routed to jcode without an explicit deep model: jcode has no --effort flag,
    # so the depth would silently vanish.
    $deepNoModel = Invoke-Tool -Tool $PolicyTool -ToolArgs @('check-engine-routing', '--work', $emptyWork) `
        -EnvOverride @{ JCODE_REVIEWER = 'all' }
    Assert-Equal 3 $deepNoModel.ExitCode 'deep-tier jcode without a deep model fails closed'
    Assert-True ($deepNoModel.Text -match 'JCODE_REVIEWER_DEEP_MODEL is unset') 'the missing deep-model key is named'

    $deepWithModel = Invoke-Tool -Tool $PolicyTool -ToolArgs @('check-engine-routing', '--work', $emptyWork) `
        -EnvOverride @{ JCODE_REVIEWER = 'all'; JCODE_REVIEWER_DEEP_MODEL = 'claude-opus-4-6' }
    Assert-Equal 0 $deepWithModel.ExitCode 'naming the deep model satisfies the deep-tier rule'

    # config.md must outrank the environment, per the documented resolution order.
    $cfgWork = New-WorkFixture "JCODE_CODER: off`n"
    $cfgWins = Invoke-Tool -Tool $PolicyTool -ToolArgs @('check-engine-routing', '--work', $cfgWork) `
        -EnvOverride @{ CODEX_CODER = 'fast'; JCODE_CODER = 'fast' }
    Assert-Equal 0 $cfgWins.ExitCode 'config.md JCODE_CODER=off overrides a conflicting environment value'

    # ======================================================================
    # 2. Role tool profiles are pinned
    # ======================================================================

    $probeDir = New-TempDir 'orchestra-jcode-argv-'

    $coderArgv = Invoke-Tool -Tool $JcodeTool -ToolArgs @(
        'build-argv', '--worktree', $probeDir, '--role', 'coder', '--prompt', 'implement X')
    Assert-Equal 0 $coderArgv.ExitCode 'build-argv succeeds for the coder role'
    Assert-True ($coderArgv.Text -match '"bash"|bash') 'the coder profile keeps a shell for SMOKE_CMD'
    Assert-True ($coderArgv.Text -match '"--quiet"') 'runs are quiet so the adapter parses a report, not a progress log'
    Assert-True ($coderArgv.Text -match '"--no-update"') 'a leaf run cannot trigger an executable update'
    Assert-True ($coderArgv.Text -match '"--no-selfdev"') 'repository auto-detection cannot switch a leaf run into self-development mode'
    Assert-True ($coderArgv.Text -match '"-C"') 'the working directory is pinned to the worktree'

    $reviewerArgv = Invoke-Tool -Tool $JcodeTool -ToolArgs @(
        'build-argv', '--worktree', $probeDir, '--role', 'reviewer', '--prompt', 'review X')
    Assert-Equal 0 $reviewerArgv.ExitCode 'build-argv succeeds for the reviewer role'
    $reviewerTools = ''
    if ($reviewerArgv.Text -match '"--tools",\s*"([^"]+)"') { $reviewerTools = $Matches[1] }
    Assert-Equal 'read,ls,agentgrep' $reviewerTools 'the reviewer profile is exactly the read-only trio'
    foreach ($forbidden in @('bash', 'write', 'edit', 'multiedit', 'apply_patch')) {
        Assert-True (($reviewerTools -split ',') -notcontains $forbidden) `
            "the reviewer profile must never expose '$forbidden' - it is the only thing making review read-only"
    }

    $badRole = Invoke-Tool -Tool $JcodeTool -ToolArgs @(
        'build-argv', '--worktree', $probeDir, '--role', 'anything', '--prompt', 'x')
    Assert-Equal 2 $badRole.ExitCode 'an unknown role is rejected rather than defaulted'

    # A prompt may legitimately begin with '--' (a task description or a review finding
    # quoting a flag). Without an end-of-options separator jcode's parser rejects the whole
    # invocation, so the separator must sit immediately before the positional message.
    $dashPrompt = Invoke-Tool -Tool $JcodeTool -ToolArgs @(
        'build-argv', '--worktree', $probeDir, '--role', 'coder', '--prompt', '--fix the --flag handling')
    Assert-Equal 0 $dashPrompt.ExitCode 'a prompt starting with -- still builds an argv'
    Assert-True ($dashPrompt.Text -match '"--",\s*"--fix the --flag handling"') `
        'the end-of-options separator precedes the positional prompt'

    # ======================================================================
    # 3. Isolation detection over a real git fixture
    # ======================================================================

    $gitRoot = New-TempDir 'orchestra-jcode-git-'
    $repo = Join-Path $gitRoot 'repo'
    $wt = Join-Path $gitRoot 'wt'
    $sibling = Join-Path $repo '.work/worktrees/sibling'
    [void][System.IO.Directory]::CreateDirectory($repo)
    Invoke-Git -Dir $repo -GitArgs @('init', '-q', '.')
    Invoke-Git -Dir $repo -GitArgs @('config', 'user.email', 'test@example.invalid')
    Invoke-Git -Dir $repo -GitArgs @('config', 'user.name', 'Orchestra Test')
    [System.IO.File]::WriteAllText((Join-Path $repo 'a.txt'), "base`n", $Utf8NoBom)
    # Real consuming repositories ignore Orchestra's local control plane. Pin that
    # invariant in the fixture instead of accidentally inheriting a developer's global
    # excludes file; clean CI runners deliberately have no such user-level convention.
    [System.IO.File]::WriteAllText((Join-Path $repo '.gitignore'), ".work/`n", $Utf8NoBom)
    Invoke-Git -Dir $repo -GitArgs @('add', '-A')
    Invoke-Git -Dir $repo -GitArgs @('commit', '-qm', 'init')
    Invoke-Git -Dir $repo -GitArgs @('worktree', 'add', '-q', $wt, '-b', 'task', 'HEAD')
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $sibling))
    Invoke-Git -Dir $repo -GitArgs @('worktree', 'add', '-q', $sibling, '-b', 'sibling', 'HEAD')

    $snapFile = Join-Path $gitRoot 'before.json'
    $snap = Invoke-Tool -Tool $JcodeTool -ToolArgs @(
        'snapshot', '--worktree', $wt, '--repo-root', $repo, '--vcs', 'git', '--out', $snapFile)
    Assert-Equal 0 $snap.ExitCode 'snapshot captures the pre-run fingerprint'
    Assert-True (Test-Path -LiteralPath $snapFile) 'snapshot writes its output file'

    # (a) Legitimate work: edits confined to the worktree.
    [System.IO.File]::WriteAllText((Join-Path $wt 'a.txt'), "worktree edit`n", $Utf8NoBom)
    $guardClean = Invoke-Tool -Tool $JcodeTool -ToolArgs @(
        'guard-tree', '--worktree', $wt, '--repo-root', $repo, '--vcs', 'git', '--before', $snapFile)
    Assert-Equal 0 $guardClean.ExitCode 'edits confined to the worktree pass the isolation guard'
    Assert-True ($guardClean.Text -match '"ok":\s*true') 'the clean case reports ok=true'

    # (b) Escape: something outside the worktree was modified.
    [System.IO.File]::WriteAllText((Join-Path $repo 'a.txt'), "escaped write`n", $Utf8NoBom)
    $guardEscape = Invoke-Tool -Tool $JcodeTool -ToolArgs @(
        'guard-tree', '--worktree', $wt, '--repo-root', $repo, '--vcs', 'git', '--before', $snapFile)
    Assert-Equal 3 $guardEscape.ExitCode 'a write outside the worktree is a hard failure'
    Assert-True ($guardEscape.Text -match 'outside its worktree') 'the escape is named in the violation'

    # .work is ignored by consuming repositories, so a plain Git diff/status digest
    # cannot see a write to the queue or a task descriptor in the protected main
    # checkout. The control-plane fingerprint must close that blind spot.
    $controlSnapFile = Join-Path $gitRoot 'control-before.json'
    $controlSnap = Invoke-Tool -Tool $JcodeTool -ToolArgs @(
        'snapshot', '--worktree', $wt, '--repo-root', $repo, '--vcs', 'git', '--out', $controlSnapFile)
    Assert-Equal 0 $controlSnap.ExitCode 'snapshot fingerprints the ignored main control plane'
    [System.IO.File]::WriteAllText((Join-Path $repo '.work/Tasks_Queue.md'), "escaped queue write`n", $Utf8NoBom)
    $guardControl = Invoke-Tool -Tool $JcodeTool -ToolArgs @(
        'guard-tree', '--worktree', $wt, '--repo-root', $repo, '--vcs', 'git', '--before', $controlSnapFile)
    Assert-Equal 3 $guardControl.ExitCode 'a write to the ignored main control plane is a hard failure'
    Assert-True ($guardControl.Text -match 'control-plane') 'the ignored control-plane escape is named in the violation'
    Remove-Item -LiteralPath (Join-Path $repo '.work/Tasks_Queue.md') -Force

    # A path-only status digest would miss this second write because a.txt was already
    # dirty when the snapshot was captured. The guard must fingerprint diff content.
    $dirtySnapFile = Join-Path $gitRoot 'dirty-before.json'
    $dirtySnap = Invoke-Tool -Tool $JcodeTool -ToolArgs @(
        'snapshot', '--worktree', $wt, '--repo-root', $repo, '--vcs', 'git', '--out', $dirtySnapFile)
    Assert-Equal 0 $dirtySnap.ExitCode 'snapshot accepts and fingerprints a pre-existing dirty main checkout'
    [System.IO.File]::WriteAllText((Join-Path $repo 'a.txt'), "escaped rewrite`n", $Utf8NoBom)
    $guardDirtyRewrite = Invoke-Tool -Tool $JcodeTool -ToolArgs @(
        'guard-tree', '--worktree', $wt, '--repo-root', $repo, '--vcs', 'git', '--before', $dirtySnapFile)
    Assert-Equal 3 $guardDirtyRewrite.ExitCode 'a rewrite of an already-dirty protected file is detected'
    Invoke-Git -Dir $repo -GitArgs @('checkout', '-q', '--', 'a.txt')

    # .work is ignored in consuming repositories, so the main-checkout digest cannot
    # see another task's worktree. Siblings are fingerprinted separately.
    $siblingSnapFile = Join-Path $gitRoot 'sibling-before.json'
    $siblingSnap = Invoke-Tool -Tool $JcodeTool -ToolArgs @(
        'snapshot', '--worktree', $wt, '--repo-root', $repo, '--vcs', 'git', '--out', $siblingSnapFile)
    Assert-Equal 0 $siblingSnap.ExitCode 'snapshot fingerprints known sibling Orchestra worktrees'
    [System.IO.File]::WriteAllText((Join-Path $sibling 'a.txt'), "sibling escape`n", $Utf8NoBom)
    $guardSibling = Invoke-Tool -Tool $JcodeTool -ToolArgs @(
        'guard-tree', '--worktree', $wt, '--repo-root', $repo, '--vcs', 'git', '--before', $siblingSnapFile)
    Assert-Equal 3 $guardSibling.ExitCode 'a write into a sibling Orchestra worktree is a hard failure'
    Assert-True ($guardSibling.Text -match 'sibling worktree') 'the sibling boundary is named in the violation'
    Invoke-Git -Dir $sibling -GitArgs @('checkout', '-q', '--', 'a.txt')

    # (c) Forbidden revision: leaf agents never commit; the processor owns all VCS writes.
    Invoke-Git -Dir $wt -GitArgs @('add', '-A')
    Invoke-Git -Dir $wt -GitArgs @('commit', '-qm', 'forbidden leaf commit')
    $guardCommit = Invoke-Tool -Tool $JcodeTool -ToolArgs @(
        'guard-tree', '--worktree', $wt, '--repo-root', $repo, '--vcs', 'git', '--before', $snapFile)
    Assert-Equal 3 $guardCommit.ExitCode 'a revision created by the leaf run is a hard failure'
    Assert-True ($guardCommit.Text -match 'worktree head moved') 'the created revision is named in the violation'

    # (d) Missing evidence is a failure, not a pass. If the pre-image cannot be read, the
    # guard would have nothing to compare and would silently wave the run through - so
    # snapshot refuses to produce an unverifiable baseline in the first place.
    $notARepo = New-TempDir 'orchestra-jcode-norepo-'
    $snapBad = Invoke-Tool -Tool $JcodeTool -ToolArgs @(
        'snapshot', '--worktree', $notARepo, '--repo-root', $notARepo, '--vcs', 'git', '--out', (Join-Path $notARepo 'b.json'))
    Assert-Equal 3 $snapBad.ExitCode 'snapshot fails closed when the tree state cannot be read'
    Assert-True ($snapBad.Text -match 'unverifiable run') 'the unverifiable baseline is named as the reason'

    # prepare-review must refuse to drop artefacts inside the worktree: a stray patch
    # file there would read as an uncommitted change in the branch under review.
    $insideOut = Invoke-Tool -Tool $JcodeTool -ToolArgs @(
        'prepare-review', '--worktree', $wt, '--vcs', 'git', '--out-dir', (Join-Path $wt 'review'))
    Assert-Equal 2 $insideOut.ExitCode 'prepare-review refuses an out-dir inside the worktree'
}
finally {
    foreach ($dir in $TempRoots) {
        if (Test-Path -LiteralPath $dir) {
            # A git worktree keeps the parent repo's admin files open on Windows; a
            # best-effort recursive delete is enough for a disposable temp fixture.
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($Failures.Count -gt 0) {
    Write-Host "FAILED - $($Failures.Count) assertion(s):"
    foreach ($failure in $Failures) { Write-Host "  $failure" }
    exit 1
}

Write-Host 'OK - jcode routing fails closed, role tool profiles are pinned, and guard-tree detects protected-tree isolation breaches.'
exit 0
