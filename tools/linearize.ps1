<#
.SYNOPSIS
    Publish-time history linearizer (T-282): re-expresses a reviewed integration tip as a
    merge-free linear chain whose published tree is BYTE-IDENTICAL to the reviewed tip, for
    projects whose trunk branch protection forbids merge commits ("require linear history").

.DESCRIPTION
    Orchestra's integration is non-linear BY DESIGN: `merger` lands each ready task branch
    into the integration branch with a MERGE commit (git `merge --no-ff`, jj `jj new
    "task/<T-ID>" @`). Those merge commits are load-bearing - each one is the isolated
    per-task landing boundary that Phase 4.3 uses to quarantine exactly one build-breaking
    task (`git revert -m 1 <SHA>` / the jj re-anchor equivalent). Publishing with
    `merge --ff-only` fast-forwards the trunk onto that tip, carrying the merge commits into
    the trunk verbatim - which a "require linear history" trunk rejects.

    This runner automates, deterministically and in one place, the manual pre-push
    linearization such projects otherwise do by hand every publish (observed on a consuming
    project, its KB K-042). It is invoked by processor Phase 5.3 ONLY when the opt-in config
    key PUBLISH_LINEAR_HISTORY is true, AFTER integration review and BEFORE the ff-merge -
    so the merge topology Phase 4.3 depends on is untouched (it ran earlier), and the default
    (key off / absent) path is byte-for-byte the previous behaviour.

    WHY THIS DESIGN (evaluated against the recommendation and alternatives):
      * A documented-only recipe leaves the risky, repeated step (rewriting history that
        reaches the trunk, byte-identical trees, re-verification against the right tip) to a
        human every publish - exactly the error-prone toil the recommendation targets. A
        pre-push hook hides that rewrite from the pipeline's own SHA-bound verification and
        approval gates. Making `merger` linear-by-default (or a second linear code path)
        destroys the cheap per-task Phase-4.3 rollback for every project. So: opt-in,
        publish-time, in a REPRODUCIBLE runner (this file) that the harness exercises on real
        git AND jj fixtures - not freehand agent prose on the single most sensitive core path.

    HOW BYTE-IDENTITY IS GUARANTEED (the hard correctness requirement):
      The reviewed tip may embed MANUAL conflict resolutions (merger's `conflict-resolved`).
      Re-MERGING task-by-task would not reproduce those resolutions and would break byte
      identity. Instead each linear commit REUSES the integration's OWN cumulative tree at the
      corresponding spine step (git `commit-tree <tree>`; jj `jj new` + `jj restore --from`),
      so the final linear tip's tree is the reviewed tip's tree, byte-for-byte, and every
      intermediate commit is a single-parent (linear) commit carrying that step's real delta.

    SPINE IDENTIFICATION (topology- and backend-uniform): git's first parent is the
    integration spine but jj's `jj new "task" @` puts the task at parent[0] and the spine at
    parent[1] (and the harness octopus differs again), so first-parent is NOT portable. This
    runner instead walks HEAD->BASE choosing, at each commit, the single parent that is NOT a
    known merged task tip (`--task-refs`). That rule is identical for git's `--no-ff` chain,
    jj's real merge chain, F-fix commits (single parent), and even a collapsed octopus, and it
    fails closed (never guesses) if the spine is ambiguous - e.g. a task ref was not supplied.

    Three fail-closed self-checks run before any ref is moved and are reported in the JSON:
      tree_identical  - the linear tip's tree equals the reviewed tip's tree (byte-identical);
      linear          - no merge commit remains in BASE..<linear tip>;
      ff (ancestry)   - BASE is still an ancestor of the linear tip (the ff-publish still holds).
    Any failure exits non-zero WITHOUT repointing the integration ref, so a bad linearization
    can never be published.

.NOTES
    Runs under PowerShell 7 (pwsh). Read-only w.r.t. the trunk: it only creates new commit
    objects and (with --ref) repoints the integration branch/bookmark; the ff into the trunk
    remains processor's job. It does not push. For git it uses pure plumbing (commit-tree /
    update-ref) and never touches a working tree; for jj it drives the given workspace's @.

    Exit codes:
      0  ok (linearized, or nothing to do when HEAD == BASE)
      2  usage / argument error
      5  a VCS command failed
      6  a fail-closed self-check failed (NOT byte-identical / not linear / not ff-able)

.EXAMPLE
    pwsh -File tools/linearize.ps1 linearize --root .work/worktrees/_integration --vcs git \
        --base <main sha> --head <integration tip sha> \
        --task-refs task/T-101,task/T-102 --ref integration/B-20260722T000000Z --json
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { $null = $_ }

. (Join-Path $PSScriptRoot 'common.ps1')
$script:ErrPrefix = 'LINERR'
$parsed = Parse-CliArgs $args -BoolFlags @('json')
$Command = $parsed.Command
$opts = $parsed.Opts
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)

function Get-Opt { param([string]$Name, [string]$Default = '') if ($opts.ContainsKey($Name)) { return [string]$opts[$Name] } return $Default }
function Get-RequiredOption { param([string]$Name) $v = Get-Opt $Name; if ([string]::IsNullOrWhiteSpace($v)) { Fail 2 "missing --$Name" }; return $v }

# Run an external binary, never through a shell; capture stdout/stderr/exit.
function Invoke-Proc {
    param([string]$File, [string[]]$ProcArgs, [string]$WorkDir = '')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8
    $psi.StandardErrorEncoding = $script:Utf8
    if ($WorkDir) { $psi.WorkingDirectory = $WorkDir }
    foreach ($a in $ProcArgs) { $psi.ArgumentList.Add([string]$a) }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outT = $proc.StandardOutput.ReadToEndAsync()
    $errT = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Out = $outT.Result; Err = $errT.Result }
}

# Parse a comma-separated --task-refs value into a de-duplicated list of refs.
function Get-TaskRefs {
    $raw = Get-Opt 'task-refs'
    return @($raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Walk the integration spine HEAD -> BASE. At each commit the spine parent is the single
# parent that is NOT a known merged task tip; the task tip(s) are the merged-in branches.
# $GetParents returns the parent commit ids of a commit; $TaskSet holds the task tip ids.
# Returns the spine commits oldest->newest (excluding BASE). Fails closed on ambiguity.
function Get-Spine {
    param([string]$HeadId, [string]$BaseId, [hashtable]$TaskSet, [scriptblock]$GetParents)
    $spine = [System.Collections.Generic.List[string]]::new()
    $cur = $HeadId
    $guard = 0
    while ($cur -ne $BaseId) {
        $guard++
        if ($guard -gt 100000) { Fail 5 "spine walk from $HeadId did not reach BASE $BaseId within 100000 steps (unexpected topology)" }
        $spine.Insert(0, $cur)
        $parents = @(& $GetParents $cur)
        if ($parents.Count -eq 0) { Fail 5 "reached root commit $cur before BASE $BaseId; BASE is not an ancestor along the integration spine" }
        $nonTask = @($parents | Where-Object { -not $TaskSet.ContainsKey($_) })
        if ($nonTask.Count -eq 0) {
            Fail 5 "commit $cur has only task-branch parents; cannot identify the integration-spine parent - pass the full set of merged task tips via --task-refs"
        }
        if ($nonTask.Count -gt 1) {
            Fail 5 "commit $cur has multiple non-task parents ($($nonTask -join ', ')); the integration spine is ambiguous - a merged task tip is likely missing from --task-refs"
        }
        $cur = $nonTask[0]
    }
    return , $spine.ToArray()
}

# ============================================================================
# git backend (pure plumbing: commit-tree / update-ref; no working tree touched).
# ============================================================================
function Invoke-LinearizeGit {
    param([string]$Root, [string]$Base, [string]$Head, [string[]]$TaskRefs, [string]$Ref)
    function GitRaw { param([string[]]$A) return (Invoke-Proc 'git' (@('-C', $Root) + $A)) }
    function GitOut { param([string[]]$A) $r = GitRaw $A; if ($r.ExitCode -ne 0) { Fail 5 "git $($A -join ' ') failed: $(([string]$r.Err).Trim())" }; return ([string]$r.Out).Trim() }

    # Fail closed with a clean diagnostic if --root is not a git repo (e.g. wrong --vcs passed).
    if ((Invoke-Proc 'git' @('-C', $Root, 'rev-parse', '--git-dir')).ExitCode -ne 0) { Fail 5 "--root is not a git repository: $Root" }
    $baseId = GitOut @('rev-parse', '--verify', "$Base^{commit}")
    $headId = GitOut @('rev-parse', '--verify', "$Head^{commit}")

    $taskSet = @{}
    foreach ($t in $TaskRefs) { $taskSet[(GitOut @('rev-parse', '--verify', "$t^{commit}"))] = $true }

    $getParents = {
        param([string]$C)
        $line = GitOut @('rev-list', '--parents', '-n', '1', $C)
        $ids = @($line -split '\s+' | Where-Object { $_ })
        return @($ids | Select-Object -Skip 1)
    }
    $spine = Get-Spine $headId $baseId $taskSet $getParents

    $prev = $baseId
    foreach ($s in @($spine)) {
        $tree = GitOut @('rev-parse', "$s^{tree}")
        $msg = ([string]((GitRaw @('log', '-1', '--format=%B', $s)).Out)).TrimEnd("`r", "`n")
        if ([string]::IsNullOrWhiteSpace($msg)) { $msg = 'Linearized integration step' }
        $r = GitRaw @('commit-tree', $tree, '-p', $prev, '-m', $msg)
        if ($r.ExitCode -ne 0) { Fail 5 "git commit-tree for spine commit $s failed: $(([string]$r.Err).Trim())" }
        $prev = ([string]$r.Out).Trim()
    }
    $newTip = $prev

    $treeHead = GitOut @('rev-parse', "$headId^{tree}")
    $treeNew = GitOut @('rev-parse', "$newTip^{tree}")
    $treeIdentical = ($treeHead -eq $treeNew)
    $merges = (GitRaw @('rev-list', '--min-parents=2', "$baseId..$newTip")).Out
    $linear = [string]::IsNullOrWhiteSpace([string]$merges)
    $ffOk = ((GitRaw @('merge-base', '--is-ancestor', $baseId, $newTip)).ExitCode -eq 0)

    Assert-Checks -TreeIdentical $treeIdentical -Linear $linear -FfOk $ffOk -TreeNew $treeNew -TreeHead $treeHead -NewTip $newTip -BaseId $baseId

    if ($Ref) {
        $u = GitRaw @('update-ref', "refs/heads/$Ref", $newTip)
        if ($u.ExitCode -ne 0) { Fail 5 "git update-ref refs/heads/$Ref -> $newTip failed: $(([string]$u.Err).Trim())" }
    }
    return [ordered]@{
        vcs = 'git'; base = $baseId; head = $headId; linear_tip = $newTip; tree = $treeNew
        commits = @($spine).Count; linear = $true; tree_identical = $true; ref = $Ref
    }
}

# ============================================================================
# jj backend (drives the workspace @; reuses the integration's own trees).
# ============================================================================
function Invoke-LinearizeJj {
    param([string]$Root, [string]$Base, [string]$Head, [string[]]$TaskRefs, [string]$Ref)
    function JjRaw { param([string[]]$A) return (Invoke-Proc 'jj' (@('-R', $Root) + $A) $Root) }
    function JjOut { param([string[]]$A) $r = JjRaw $A; if ($r.ExitCode -ne 0) { Fail 5 "jj $($A -join ' ') failed: $(([string]$r.Err).Trim())" }; return ([string]$r.Out).Trim() }
    function JjCommitId { param([string]$Rev) return (JjOut @('log', '-r', $Rev, '--no-graph', '-T', 'commit_id')) }

    # Fail closed with a clean diagnostic if --root is not a jj repo (e.g. wrong --vcs passed).
    if ((Invoke-Proc 'jj' @('-R', $Root, 'root') $Root).ExitCode -ne 0) { Fail 5 "--root is not a jj repository: $Root" }
    $baseId = JjCommitId $Base
    $headId = JjCommitId $Head
    if ($baseId -match "`n" -or $headId -match "`n") { Fail 5 "--base/--head must resolve to a single revision (got multiple)" }

    $taskSet = @{}
    foreach ($t in $TaskRefs) { $taskSet[(JjCommitId $t)] = $true }

    $getParents = {
        param([string]$C)
        $line = JjOut @('log', '-r', $C, '--no-graph', '-T', 'parents.map(|p| p.commit_id() ++ " ")')
        return @($line -split '\s+' | Where-Object { $_ })
    }
    $spine = Get-Spine $headId $baseId $taskSet $getParents

    $prev = $baseId
    foreach ($s in @($spine)) {
        $msg = JjOut @('log', '-r', $s, '--no-graph', '-T', 'description')
        if ([string]::IsNullOrWhiteSpace($msg)) { $msg = 'Linearized integration step' }
        JjOut @('new', $prev, '-m', $msg) | Out-Null          # @ := empty child of $prev
        JjOut @('restore', '--from', $s) | Out-Null           # @ tree := tree($s) (all paths, --to @)
        $prev = JjCommitId '@'                                 # content edit reissues @'s commit id
    }
    $newTip = $prev

    # Byte-identity: an empty diff between the linear tip and the reviewed tip means equal trees.
    $treeIdentical = [string]::IsNullOrWhiteSpace((JjOut @('diff', '--from', $newTip, '--to', $headId, '--summary')))
    # Linearity: no merge commit (merges() revset) survives in BASE..<linear tip>.
    $linear = [string]::IsNullOrWhiteSpace((JjOut @('log', '-r', "($baseId..$newTip) & merges()", '--no-graph', '-T', 'commit_id ++ "\n"')))
    # ff: BASE is an ancestor of the linear tip.
    $ffOk = -not [string]::IsNullOrWhiteSpace((JjOut @('log', '-r', "$baseId & ::$newTip", '--no-graph', '-T', 'commit_id')))

    Assert-Checks -TreeIdentical $treeIdentical -Linear $linear -FfOk $ffOk -TreeNew $newTip -TreeHead $headId -NewTip $newTip -BaseId $baseId

    if ($Ref) {
        # A sideways move (the linear tip is not a descendant of the merge tip) -> --allow-backwards.
        JjOut @('bookmark', 'set', $Ref, '-r', $newTip, '--allow-backwards') | Out-Null
    }
    return [ordered]@{
        vcs = 'jj'; base = $baseId; head = $headId; linear_tip = $newTip; tree = ''
        commits = @($spine).Count; linear = $true; tree_identical = $true; ref = $Ref
    }
}

# The three fail-closed gates, shared by both backends. Throws (never returns) on any failure
# so a bad linearization is never published; the ref is repointed only after these pass.
function Assert-Checks {
    param([bool]$TreeIdentical, [bool]$Linear, [bool]$FfOk, [string]$TreeNew, [string]$TreeHead, [string]$NewTip, [string]$BaseId)
    if (-not $TreeIdentical) { Fail 6 "linearized tip tree ($TreeNew) is NOT byte-identical to the reviewed tip tree ($TreeHead) - refusing to publish" }
    if (-not $Linear) { Fail 6 "linearized history is not linear (a merge commit survives in $BaseId..$NewTip) - refusing to publish" }
    if (-not $FfOk) { Fail 6 "BASE ($BaseId) is not an ancestor of the linearized tip ($NewTip) - the ff-publish would not hold" }
}

function Invoke-Linearize {
    $root = Get-RequiredOption 'root'
    $vcs = Get-RequiredOption 'vcs'
    if ($vcs -notin @('git', 'jj')) { Fail 2 "--vcs must be git or jj (got '$vcs')" }
    if (-not (Test-Path -LiteralPath $root)) { Fail 2 "--root does not exist: $root" }
    $base = Get-RequiredOption 'base'
    $head = Get-RequiredOption 'head'
    $ref = Get-Opt 'ref'
    $taskRefs = Get-TaskRefs

    $result = if ($vcs -eq 'git') {
        Invoke-LinearizeGit -Root $root -Base $base -Head $head -TaskRefs $taskRefs -Ref $ref
    } else {
        Invoke-LinearizeJj -Root $root -Base $base -Head $head -TaskRefs $taskRefs -Ref $ref
    }

    if ([bool](Opt 'json' $false)) {
        Write-Output (([pscustomobject]$result) | ConvertTo-Json -Compress -Depth 6)
    } else {
        Write-Output ("linearize vcs={0} linear_tip={1} commits={2} tree_identical={3} linear={4}" -f $result.vcs, $result.linear_tip, $result.commits, $result.tree_identical, $result.linear)
    }
}

try {
    switch ($Command) {
        'linearize' { Invoke-Linearize }
        'version' { Write-Output 'orchestra-linearize 1' }
        default { Fail 2 "unknown command '$Command'. Valid: linearize, version" }
    }
} catch {
    exit (Resolve-CatchExit $_ 'LINERR' 'linearize' 'LINEARIZE_DEBUG')
}
