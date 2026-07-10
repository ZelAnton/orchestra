<#
.SYNOPSIS
    The executable policy/config boundary for Orchestra: schema-driven validation and
    migration of .work/config.md + .work/constraints.md, and the runtime guard that turns
    the policy into a technical precondition for destructive file/VCS operations.

.DESCRIPTION
    Companion of tools/state-tx.ps1 / tools/queue-tx.ps1, built on the single schema source
    tools/policy-schema.ps1 (dot-sourced). Where those two are the transactional interfaces
    for the control plane and the queue, this is the interface that makes the *policy* an
    executed boundary instead of prose the roles are trusted to have honoured:

      schema           - print the versioned schema (config keys + policy sections) as JSON.

      validate-config  - fail-closed validation of .work/config.md against the schema: an
                         unknown key, a duplicated key, or a value outside its type/enum/range
                         is an ERROR (exit 3), never a silently-substituted default. An empty
                         value = "unset -> documented default" and is fine.

      validate-policy  - structural validation of .work/constraints.md (known section
                         headings present, denylist globs parseable). Exit 4 on a structural
                         problem; a missing file degrades to OK (policy simply not in force).

      migrate          - bring an existing .work/config.md up to the current schema WITHOUT
                         losing any user value or comment (append-only): every original line
                         is preserved verbatim, schema keys entirely absent are appended as
                         commented defaults, and an unknown/duplicated/invalid active key
                         stops the migration with a precise error (exit 5) rather than being
                         defaulted away.

      guard-path       - the destructive-operation runtime guard. Canonicalizes the target
                         path (real on-disk location, following symlinks/junctions), verifies
                         it is at/under the root allowed for the operation object, rejects a
                         '..' escape / a link routed outside / a substituted worktree or task
                         directory, and checks the task/batch id shape and (optionally) the
                         VCS relationship. Exit 6 on rejection.

      check-paths      - reconcile the ACTUAL changed paths (e.g. `git diff --name-only`)
                         against the denylist AFTER an executor returns and before commit /
                         merge / publication. Exit 7 with the offending path(s) if any hit
                         the denylist; an empty/absent denylist degrades to OK.

      check-publish    - the allowed-branch / allowed-remote / push-merge policy as a
                         technical precondition instead of a trusted text report. Exit 8 if
                         the target branch/remote is not permitted or push is policy-blocked.

    Degradation without errors: a missing .work/constraints.md, or an empty section, means
    "no constraint" - the corresponding check returns OK, exactly as the roles behaved before
    the policy was executable.

.NOTES
    Exit codes:
      0   success / check passed
      2   usage / argument error
      3   config validation failure (unknown / duplicate / invalid key)
      4   policy (constraints) structural validation failure
      5   migration refused (unknown / duplicate / invalid field)
      6   path guard rejection (escape / link / substitution / bad id / VCS mismatch)
      7   denylist hit (a changed path is on the denylist)
      8   publish-target rejection (branch/remote not allowed, or push policy-blocked)

    Runs under PowerShell 7. All emitted text is ASCII/UTF-8 (no BOM).

.EXAMPLE
    pwsh -File tools/policy.ps1 validate-config --file .work/config.md
    pwsh -File tools/policy.ps1 migrate --file .work/config.md --out .work/config.migrated.md
    pwsh -File tools/policy.ps1 guard-path --root /abs --work /abs/.work --object worktree --task T-045 --path /abs/.work/worktrees/T-045
    pwsh -File tools/policy.ps1 check-paths --root /abs --work /abs/.work --paths-from changed.txt
    pwsh -File tools/policy.ps1 check-publish --work /abs/.work --branch main --remote origin
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

. (Join-Path $PSScriptRoot 'policy-schema.ps1')

# --------------------------------------------------------------------------
# Argument parsing:  <command> [--key value | --flag] ...  (repeatable keys collect)
# --------------------------------------------------------------------------
$Command = if ($args.Count -ge 1) { [string]$args[0] } else { '' }
$BoolFlags = @('json', 'quiet')
$RepeatKeys = @('path')
$opts = @{}
for ($i = 1; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    if ($a -like '--*') {
        $key = $a.Substring(2)
        if ($BoolFlags -contains $key) { $opts[$key] = $true; continue }
        $i++
        $val = if ($i -lt $args.Count) { [string]$args[$i] } else { '' }
        if ($RepeatKeys -contains $key) {
            if (-not $opts.ContainsKey($key)) { $opts[$key] = [System.Collections.Generic.List[string]]::new() }
            $opts[$key].Add($val)
        } else { $opts[$key] = $val }
    }
}

function Fail { param([int]$Code, [string]$Message) throw ('PLCERR|' + $Code + '|' + $Message) }
function Opt { param([string]$Name, $Default = $null) if ($opts.ContainsKey($Name)) { return $opts[$Name] } else { return $Default } }
function Require-Opt {
    param([string]$Name)
    if (-not $opts.ContainsKey($Name) -or [string]::IsNullOrEmpty([string]$opts[$Name])) { Fail 2 "missing required option --$Name" }
    return [string]$opts[$Name]
}
function Read-Lines {
    param([string]$Path)
    # $null => file absent; @() => file present but empty (distinct: an empty config.md is
    # still a valid, migratable file, not a "not found"). @(...) coerces Get-Content's $null
    # (empty file) to an empty array; the leading comma stops the pipeline from unwrapping it.
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return , @(Get-Content -LiteralPath $Path -Encoding utf8)
}

# Resolve the config/constraints path from --file, else --work/<name>.
function Resolve-TargetFile {
    param([string]$Name)   # 'config.md' | 'constraints.md'
    if ($opts.ContainsKey('file') -and -not [string]::IsNullOrEmpty([string]$opts['file'])) { return [string]$opts['file'] }
    if ($opts.ContainsKey('work') -and -not [string]::IsNullOrEmpty([string]$opts['work'])) { return (Join-Path ([string]$opts['work']) $Name) }
    Fail 2 "provide --file <path> or --work <.work dir>"
}

# ==========================================================================
# schema
# ==========================================================================
function Cmd-Schema {
    Write-Output ((Get-OrchestraSchema) | ConvertTo-Json -Depth 6)
}

# ==========================================================================
# validate-config  (fail-closed)
# ==========================================================================
function Get-ConfigFindings {
    param([string[]]$Lines)
    $findings = [System.Collections.Generic.List[string]]::new()
    $entries = ConvertFrom-ConfigText $Lines
    $seen = @{}
    foreach ($e in $entries) {
        if ($e.Kind -eq 'junk') {
            $findings.Add("line $($e.Line): not a 'KEY: value' setting, comment or blank line: '$($e.Raw.Trim())'")
            continue
        }
        if ($e.Kind -ne 'key') { continue }
        $desc = Get-SchemaConfigKey $e.Key
        if (-not $desc) {
            $findings.Add("line $($e.Line): unknown key '$($e.Key)' (not in the schema; possible typo)")
            continue
        }
        if ($seen.ContainsKey($e.Key)) {
            $findings.Add("line $($e.Line): duplicate key '$($e.Key)' (first set at line $($seen[$e.Key]))")
            continue
        }
        $seen[$e.Key] = $e.Line
        $r = Test-ConfigValue $desc $e.Value
        if (-not $r.Ok) {
            $findings.Add("line $($e.Line): key '$($e.Key)': $($r.Reason)")
        }
    }
    return , $findings.ToArray()
}

function Cmd-ValidateConfig {
    $file = Resolve-TargetFile 'config.md'
    $lines = Read-Lines $file
    if ($null -eq $lines) {
        Write-Output "OK   $file not found - defaults apply (nothing to validate)"
        return
    }
    $findings = Get-ConfigFindings $lines
    if ($findings.Count -eq 0) {
        Write-Output "OK   ${file}: all set keys are known and within their type/enum/range"
        return
    }
    Write-Output "FAIL ${file}: $($findings.Count) config problem(s) (no silent default is substituted):"
    foreach ($f in $findings) { Write-Output "  - $f" }
    Fail 3 "config validation failed ($($findings.Count) problem(s))"
}

# ==========================================================================
# validate-policy  (structural)
# ==========================================================================
function Cmd-ValidatePolicy {
    $file = Resolve-TargetFile 'constraints.md'
    $lines = Read-Lines $file
    if ($null -eq $lines) {
        Write-Output "OK   $file not found - policy not in force (degradation without errors)"
        return
    }
    $findings = [System.Collections.Generic.List[string]]::new()
    $headings = @($lines | Where-Object { $_ -match '^##\s+' } | ForEach-Object { ($_ -replace '^##\s+', '').Trim() })
    foreach ($sec in (Get-SchemaPolicySections)) {
        if ($sec.heading -notin $headings) {
            $findings.Add("missing policy section heading '## $($sec.heading)'")
        }
    }
    # Denylist globs must be parseable into a regex (a malformed glob would silently never
    # match, which for a security denylist is worse than an error).
    $deny = Get-PolicyActiveBullets $lines 'Запрещённые пути (denylist)'
    foreach ($g in $deny) {
        # a bullet may be a comma-separated list of globs (e.g. "`a`, `b`")
        foreach ($tok in (Split-DenyBullet $g)) {
            try { [void][regex]::new((Convert-GlobToRegex $tok)) }
            catch { $findings.Add("denylist glob '$tok' is not a valid pattern") }
        }
    }
    if ($findings.Count -eq 0) {
        Write-Output "OK   ${file}: structure valid ($($deny.Count) active denylist entr$(if ($deny.Count -eq 1) {'y'} else {'ies'}))"
        return
    }
    Write-Output "FAIL ${file}: $($findings.Count) policy structure problem(s):"
    foreach ($f in $findings) { Write-Output "  - $f" }
    Fail 4 "policy validation failed ($($findings.Count) problem(s))"
}

# A denylist bullet can carry one or more `glob`-quoted patterns (and/or a bare token).
function Split-DenyBullet {
    param([string]$Bullet)
    $toks = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($Bullet, '`([^`]+)`')) { $toks.Add($m.Groups[1].Value.Trim()) }
    if ($toks.Count -eq 0) {
        $t = ($Bullet -replace '\(.*?\)', '').Trim().Trim(',').Trim()
        if ($t) { $toks.Add($t) }
    }
    return , $toks.ToArray()
}

function Get-ActiveDenyGlobs {
    param([string[]]$Lines)
    $globs = [System.Collections.Generic.List[string]]::new()
    foreach ($b in (Get-PolicyActiveBullets $Lines 'Запрещённые пути (denylist)')) {
        foreach ($t in (Split-DenyBullet $b)) { $globs.Add($t) }
    }
    return , $globs.ToArray()
}

# ==========================================================================
# migrate  (append-only; never loses a value/comment)
# ==========================================================================
function Cmd-Migrate {
    $file = Resolve-TargetFile 'config.md'
    $lines = Read-Lines $file
    if ($null -eq $lines) { Fail 5 "cannot migrate: $file not found" }

    # Fail-closed on unknown/duplicate/invalid active fields (do NOT silently default).
    $findings = Get-ConfigFindings $lines
    if ($findings.Count -gt 0) {
        Write-Output "FAIL migration refused: $($findings.Count) problem(s) in $file (fix them - no field is silently defaulted):"
        foreach ($f in $findings) { Write-Output "  - $f" }
        Fail 5 "migration refused ($($findings.Count) problem(s))"
    }

    $entries = ConvertFrom-ConfigText $lines
    # Which schema keys already appear anywhere (active OR commented-out) - so we do not
    # re-append a default the user has deliberately kept commented.
    $present = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($e in $entries) { if ($e.Kind -eq 'key') { [void]$present.Add($e.Key) } }
    foreach ($k in (Get-SchemaConfigKeys)) {
        if ([regex]::IsMatch(($lines -join "`n"), "(?m)^\s*#?\s*$([regex]::Escape($k.name))\s*:")) { [void]$present.Add($k.name) }
    }

    $added = [System.Collections.Generic.List[string]]::new()
    $sb = [System.Collections.Generic.List[string]]::new()
    foreach ($raw in $lines) { $sb.Add($raw) }   # preserve everything verbatim
    $missing = @(Get-SchemaConfigKeys | Where-Object { -not $present.Contains($_.name) })
    if ($missing.Count -gt 0) {
        if ($sb.Count -gt 0 -and $sb[$sb.Count - 1].Trim() -ne '') { $sb.Add('') }
        $sb.Add('# --- keys added by policy.ps1 migrate (schema ' + (Get-OrchestraSchema).version + '); documented defaults, commented out ---')
        foreach ($k in $missing) {
            $sb.Add('# ' + $k.name + ': ' + $k.default)
            $added.Add($k.name)
        }
    }

    $outText = ($sb -join "`n")
    if ($opts.ContainsKey('out') -and -not [string]::IsNullOrEmpty([string]$opts['out'])) {
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText([string]$opts['out'], $outText + "`n", $enc)
        Write-Output "OK   migrated $file -> $([string]$opts['out']) (preserved all values/comments; added $($added.Count) missing default(s))"
    } else {
        Write-Output $outText
    }
    if ($added.Count -gt 0 -and -not [bool](Opt 'quiet' $false)) {
        [Console]::Error.WriteLine("policy: added missing default(s) as comments: $($added -join ', ')")
    }
}

# ==========================================================================
# guard-path  (destructive-operation runtime guard)
# ==========================================================================
function Cmd-GuardPath {
    $root = Require-Opt 'root'
    $work = [string](Opt 'work' (Join-Path $root '.work'))
    $object = Require-Opt 'object'
    $target = Require-Opt 'path'
    $task = [string](Opt 'task' '')
    $batch = [string](Opt 'batch' '')

    if (Test-HasDotDotSegment $target) {
        Fail 6 "path '$target' contains a '..' segment (parent-directory traversal is not allowed for a $object operation)"
    }
    if ($batch -and -not (Test-BatchId $batch)) { Fail 6 "malformed --batch '$batch' (expected B-YYYYMMDDTHHMMSSZ)" }

    $worktreesRoot = Join-Path $work 'worktrees'
    $tasksRoot = Join-Path $work 'tasks'

    switch ($object) {
        'worktree' {
            if (-not $task) { Fail 2 "--object worktree requires --task" }
            if (-not (Test-TaskId $task)) { Fail 6 "malformed --task '$task'" }
            $expected = Join-Path $worktreesRoot $task
            Assert-LeafAndContainment $target $expected $worktreesRoot $work $object
            Assert-VcsWorktree $root $target
        }
        'integration' {
            $expected = Join-Path $worktreesRoot '_integration'
            Assert-LeafAndContainment $target $expected $worktreesRoot $work $object
            Assert-VcsWorktree $root $target
        }
        'task-dir' {
            if (-not $task) { Fail 2 "--object task-dir requires --task" }
            if (-not (Test-TaskId $task)) { Fail 6 "malformed --task '$task'" }
            $expected = Join-Path $tasksRoot $task
            Assert-LeafAndContainment $target $expected $tasksRoot $work $object
        }
        'work-file' {
            if (-not (Test-PathAtOrUnder $target $work)) {
                Fail 6 "path '$target' resolves outside the .work root '$work' (real: '$(Get-RealFsPath $target)')"
            }
        }
        'main-tree' {
            if (-not (Test-PathAtOrUnder $target $root)) {
                Fail 6 "path '$target' resolves outside the project root '$root' (real: '$(Get-RealFsPath $target)')"
            }
            if (Test-PathAtOrUnder $target $work) {
                Fail 6 "path '$target' is under .work; a main-tree destructive op must target the working copy, not runtime state"
            }
        }
        default { Fail 2 "unknown --object '$object' (valid: worktree, integration, task-dir, work-file, main-tree)" }
    }
    Write-Output "ok $object path=$(Get-RealFsPath $target)"
}

function Assert-LeafAndContainment {
    param([string]$Target, [string]$Expected, [string]$AllowedRoot, [string]$WorkRoot, [string]$Object)
    # 1. Leaf equality on the LITERAL (normalized, links NOT followed) path blocks
    #    substituting a sibling worktree/task dir (e.g. T-002 for the addressed T-045).
    $litTarget = ([System.IO.Path]::GetFullPath($Target)).TrimEnd('\', '/')
    $litExpected = ([System.IO.Path]::GetFullPath($Expected)).TrimEnd('\', '/')
    $cmp = Get-PathComparer
    if (-not [string]::Equals($litTarget, $litExpected, $cmp)) {
        Fail 6 "path '$Target' is not the addressed $Object directory '$Expected' - refusing a substituted target"
    }
    # 2. REAL-path containment under .work catches a symlink/junction ANYWHERE on the chain
    #    (including the allowed subdir itself being replaced by a link) that routes the real
    #    location out of .work. This is the check the literal-leaf equality cannot make: both
    #    sides resolve through the same rogue link and look equal, but the REAL target has
    #    left .work.
    if (-not (Test-PathAtOrUnder $Target $WorkRoot)) {
        Fail 6 "path '$Target' resolves outside .work (real '$(Get-RealFsPath $Target)') - a symlink/junction escape is refused"
    }
    if (-not (Test-PathAtOrUnder $Target $AllowedRoot)) {
        Fail 6 "path '$Target' resolves outside the allowed root '$AllowedRoot' - a symlink/junction escape is refused"
    }
}

# Optional VCS-relationship check: when git is available and the worktree already exists,
# confirm the target is a registered worktree of THIS repo (not an arbitrary directory
# masquerading as one). A not-yet-created worktree, or no git, degrades to a pass (there is
# nothing to substitute yet) - the path containment above is the primary guard.
function Assert-VcsWorktree {
    param([string]$Root, [string]$Target)
    $expect = [string](Opt 'expect-vcs' '')
    if ($expect -eq '' -or $expect -eq 'none') { return }
    if ($expect -ne 'git') { return }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $real = Get-RealFsPath $Target
    if (-not (Test-Path -LiteralPath $real)) { return }   # not created yet - nothing registered to verify
    $listed = $null
    try { $listed = & git -C $Root worktree list --porcelain 2>$null } catch { return }
    if (-not $listed) { return }
    $paths = @($listed | Where-Object { $_ -like 'worktree *' } | ForEach-Object { Get-RealFsPath ($_ -replace '^worktree ', '') })
    $cmp = Get-PathComparer
    $ok = $false
    foreach ($p in $paths) { if ([string]::Equals($p, $real, $cmp)) { $ok = $true; break } }
    if (-not $ok) {
        Fail 6 "path '$Target' exists but is not a registered git worktree of '$Root' - refusing (possible worktree substitution)"
    }
}

# ==========================================================================
# check-paths  (actual changed paths vs denylist)
# ==========================================================================
function Get-ChangedPaths {
    $list = [System.Collections.Generic.List[string]]::new()
    if ($opts.ContainsKey('paths-from') -and -not [string]::IsNullOrEmpty([string]$opts['paths-from'])) {
        $pf = [string]$opts['paths-from']
        if (-not (Test-Path -LiteralPath $pf)) { Fail 2 "--paths-from file not found: $pf" }
        foreach ($ln in (Get-Content -LiteralPath $pf -Encoding utf8)) {
            $t = $ln.Trim()
            if ($t -eq '') { continue }
            # a rename in `git diff --name-status -M` prints "old => new" / "{a => b}" forms;
            # split so BOTH sides are checked against the denylist.
            foreach ($side in (Split-RenamePath $t)) { $list.Add($side) }
        }
    }
    if ($opts.ContainsKey('path')) { foreach ($p in $opts['path']) { if ($p) { $list.Add($p) } } }
    return , $list.ToArray()
}

function Split-RenamePath {
    param([string]$Line)
    if ($Line -match '=>') {
        $m = [regex]::Match($Line, '^(.*)\{(.*?)\s*=>\s*(.*?)\}(.*)$')
        if ($m.Success) {
            $pre = $m.Groups[1].Value; $post = $m.Groups[4].Value
            return , @(($pre + $m.Groups[2].Value + $post), ($pre + $m.Groups[3].Value + $post))
        }
        $parts = $Line -split '\s*=>\s*'
        if ($parts.Count -eq 2) { return , @($parts[0].Trim(), $parts[1].Trim()) }
    }
    return , @($Line)
}

function Cmd-CheckPaths {
    $policyFile = Resolve-PolicyFileOrNull
    $globs = @()
    if ($policyFile) {
        $lines = Read-Lines $policyFile
        if ($null -ne $lines) { $globs = Get-ActiveDenyGlobs $lines }
    }
    $changed = Get-ChangedPaths
    if ($changed.Count -eq 0) { Fail 2 "no changed paths given (use --paths-from <file> or --path <p>)" }
    if ($globs.Count -eq 0) {
        Write-Output "OK   denylist empty or not in force - $($changed.Count) changed path(s) allowed"
        return
    }
    $hits = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $changed) {
        foreach ($g in $globs) {
            if (Test-GlobMatch $p $g) { $hits.Add("$p matches denylist glob '$g'"); break }
        }
    }
    if ($hits.Count -eq 0) {
        Write-Output "OK   $($changed.Count) changed path(s), none on the denylist ($($globs.Count) glob(s))"
        return
    }
    Write-Output "DENY $($hits.Count) changed path(s) hit the denylist (must not reach the integration result):"
    foreach ($h in $hits) { Write-Output "  - $h" }
    Fail 7 "denylist hit ($($hits.Count) path(s))"
}

function Resolve-PolicyFileOrNull {
    if ($opts.ContainsKey('policy') -and -not [string]::IsNullOrEmpty([string]$opts['policy'])) { return [string]$opts['policy'] }
    if ($opts.ContainsKey('work') -and -not [string]::IsNullOrEmpty([string]$opts['work'])) {
        $p = Join-Path ([string]$opts['work']) 'constraints.md'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

# ==========================================================================
# check-publish  (allowed branch/remote + push policy as a precondition)
# ==========================================================================
function Cmd-CheckPublish {
    $branch = [string](Opt 'branch' '')
    $remote = [string](Opt 'remote' '')
    $policyFile = Resolve-PolicyFileOrNull
    if (-not $policyFile) {
        Write-Output "OK   no .work/constraints.md - publish target unrestricted by policy (config PUSH governs)"
        return
    }
    $lines = Read-Lines $policyFile
    if ($null -eq $lines) { Write-Output "OK   policy file empty - publish target unrestricted"; return }

    $rejects = [System.Collections.Generic.List[string]]::new()
    $allowedBranches = Get-PublishTargets $lines 'Ветки публикации'
    $allowedRemotes = Get-PublishTargets $lines 'Remotes'

    if ($branch -and $allowedBranches.Count -gt 0) {
        $cmp = Get-PathComparer
        $ok = $false; foreach ($b in $allowedBranches) { if ([string]::Equals($b, $branch, $cmp)) { $ok = $true } }
        if (-not $ok) { $rejects.Add("branch '$branch' is not in the allowed publish branches: $($allowedBranches -join ', ')") }
    }
    if ($remote -and $allowedRemotes.Count -gt 0) {
        $cmp = Get-PathComparer
        $ok = $false; foreach ($r in $allowedRemotes) { if ([string]::Equals($r, $remote, $cmp)) { $ok = $true } }
        if (-not $ok) { $rejects.Add("remote '$remote' is not in the allowed remotes: $($allowedRemotes -join ', ')") }
    }

    # push/merge policy: an active bullet demanding manual confirmation blocks the push.
    $pushBlocked = $false
    foreach ($b in (Get-PolicyActiveBullets $lines 'Push/merge policy')) {
        if ($b -match '(?i)(ручного подтверждения|manual|требует подтвержд)') { $pushBlocked = $true }
    }

    if ($rejects.Count -gt 0) {
        Write-Output "DENY publish target rejected by policy:"
        foreach ($r in $rejects) { Write-Output "  - $r" }
        Fail 8 "publish target rejected ($($rejects.Count) reason(s))"
    }
    if ($pushBlocked) {
        Write-Output "BLOCK push requires manual confirmation per .work/constraints.md - ff-merge locally, do not push"
        Fail 8 "push policy-blocked (manual confirmation required)"
    }
    Write-Output "OK   publish target permitted by policy (branch='$branch' remote='$remote')"
}

# Parse an allowed-target list like "- Ветки публикации: `main`" (value may be bare or
# `code`-quoted, comma-separated). Only the ACTIVE bullets of the branches/remotes section
# are read; placeholders were already dropped by Get-PolicyActiveBullets.
function Get-PublishTargets {
    param([string[]]$Lines, [string]$Label)
    $vals = [System.Collections.Generic.List[string]]::new()
    foreach ($b in (Get-PolicyActiveBullets $Lines 'Разрешённые ветки и remotes')) {
        $m = [regex]::Match($b, "^$([regex]::Escape($Label))\s*:\s*(.+)$")
        if (-not $m.Success) { continue }
        $rest = $m.Groups[1].Value
        $codeToks = [regex]::Matches($rest, '`([^`]+)`')
        if ($codeToks.Count -gt 0) {
            foreach ($t in $codeToks) { $vals.Add($t.Groups[1].Value.Trim()) }
        } else {
            foreach ($t in ($rest -split ',')) {
                $tt = ($t -replace '\(.*?\)', '').Trim()
                if ($tt -and $tt -notmatch '^\(') { $vals.Add($tt) }
            }
        }
    }
    return , $vals.ToArray()
}

# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------
try {
    switch ($Command) {
        'schema'          { Cmd-Schema }
        'validate-config' { Cmd-ValidateConfig }
        'validate-policy' { Cmd-ValidatePolicy }
        'migrate'         { Cmd-Migrate }
        'guard-path'      { Cmd-GuardPath }
        'check-paths'     { Cmd-CheckPaths }
        'check-publish'   { Cmd-CheckPublish }
        default {
            Fail 2 "unknown command '$Command'. Valid: schema, validate-config, validate-policy, migrate, guard-path, check-paths, check-publish"
        }
    }
} catch {
    $m = [string]$_.Exception.Message
    if ($m -like 'PLCERR|*') {
        $parts = $m -split '\|', 3
        [Console]::Error.WriteLine("policy: $($parts[2])")
        exit ([int]$parts[1])
    }
    [Console]::Error.WriteLine("policy: $m")
    if ($env:POLICY_DEBUG) { [Console]::Error.WriteLine($_.ScriptStackTrace) }
    exit 1
}
