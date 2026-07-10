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

      check-gate       - the publish CI gate (T-095) as a fail-closed decision instead of a
                         trusted "verify manually" note. Given the EXACT pushed --sha and the
                         observed check runs, it binds only to that SHA, requires the WHOLE
                         set of required checks (from policy) to be green, and treats an
                         absent / not-yet-complete / cancelled / red / past-deadline result as
                         NOT ready (never a silent pass). Exit 9 = fail-closed (red or timed
                         out); exit 10 = still pending within the deadline (keep waiting a
                         backoff); exit 0 = ready (or no required checks configured).

      approval-request / approval-approve / approval-reject / approval-status
                       - the one-time human-approval gate (T-095) for the categories that
                         cannot be reduced to a mechanical check (mandatory human review,
                         force-lock, policy bypass). `approval-request` persists an artifact
                         (subject task/batch, reason, diff fingerprint, policy snapshot,
                         deadline, one-time id) idempotently - a resume of the SAME request
                         (same subject+fingerprint+policy) reuses it, never a duplicate.
                         approve/reject consume the id EXACTLY once (a spent id is refused).
                         `approval-status` is the consumer: it re-derives the CURRENT
                         fingerprint/policy and reports `approved` only when a fresh approve is
                         still valid; a decision goes stale (exit 11) once the affected code or
                         constraints.md/policy-schema changes, and no answer by the deadline is
                         a fail-closed rejection (exit 11), never a default approval. Exit 12 =
                         pending (awaiting the operator).

    Degradation without errors: a missing .work/constraints.md, or an empty section, means
    "no constraint" - the corresponding check returns OK, exactly as the roles behaved before
    the policy was executable.

.NOTES
    Exit codes:
      0   success / check passed / gate ready / approval granted
      2   usage / argument error
      3   config validation failure (unknown / duplicate / invalid key)
      4   policy (constraints) structural validation failure
      5   migration refused (unknown / duplicate / invalid field)
      6   path guard rejection (escape / link / substitution / bad id / VCS mismatch)
      7   denylist hit (a changed path is on the denylist)
      8   publish-target rejection (branch/remote not allowed, or push policy-blocked)
      9   publish gate fail-closed: a required check is red/cancelled, or the required set is
          still incomplete at the deadline (outage) - do NOT publish/archive
      10  publish gate: required checks still pending WITHIN the deadline - keep waiting a backoff
      11  approval not granted: rejected, expired (no answer by deadline), or stale (affected
          code/policy changed since issuance) - fail-closed, do NOT proceed
      12  approval pending: a fresh request is awaiting the operator's decision

    Runs under PowerShell 7. All emitted text is ASCII/UTF-8 (no BOM).

.EXAMPLE
    pwsh -File tools/policy.ps1 validate-config --file .work/config.md
    pwsh -File tools/policy.ps1 migrate --file .work/config.md --out .work/config.migrated.md
    pwsh -File tools/policy.ps1 guard-path --root /abs --work /abs/.work --object worktree --task T-045 --path /abs/.work/worktrees/T-045
    pwsh -File tools/policy.ps1 check-paths --root /abs --work /abs/.work --paths-from changed.txt
    pwsh -File tools/policy.ps1 check-publish --work /abs/.work --branch main --remote origin
    pwsh -File tools/policy.ps1 check-gate --work /abs/.work --sha <fullsha> --checks-from runs.jsonl --elapsed-sec 120 --json
    pwsh -File tools/policy.ps1 approval-request --work /abs/.work --task T-045 --reason policy-bypass --paths-from changed.txt --json
    pwsh -File tools/policy.ps1 approval-approve --work /abs/.work --id <apr-id> --by operator
    pwsh -File tools/policy.ps1 approval-status  --work /abs/.work --id <apr-id> --paths-from changed.txt --json
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
# Human-readable status line - suppressed under --json so a machine consumer gets ONLY the
# JSON object on stdout (the JSON emitters below print the machine form when --json is set).
function Say { param([string]$Message) if (-not [bool](Opt 'json' $false)) { Write-Output $Message } }
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

# ==========================================================================
# check-gate  (publish CI gate: fail-closed, SHA-bound, whole-set)
# ==========================================================================

# Read an int config value from .work/config.md (or --config), falling back to the schema
# default when the key is unset/absent/invalid. Deadline/backoff are OPERATIONAL tuning, so
# they live in config.md (like CALL_DEADLINE_SEC), while WHICH checks are required is a
# security decision that lives in constraints.md.
function Get-ConfigInt {
    param([string]$Name, [int]$SchemaDefault)
    $file = ''
    if ($opts.ContainsKey('config') -and -not [string]::IsNullOrEmpty([string]$opts['config'])) { $file = [string]$opts['config'] }
    elseif ($opts.ContainsKey('work') -and -not [string]::IsNullOrEmpty([string]$opts['work'])) { $file = Join-Path ([string]$opts['work']) 'config.md' }
    if ($file -and (Test-Path -LiteralPath $file)) {
        foreach ($e in (ConvertFrom-ConfigText (Read-Lines $file))) {
            if ($e.Kind -eq 'key' -and $e.Key -eq $Name -and $e.Value -match '^-?\d+$') { return [int]$e.Value }
        }
    }
    return $SchemaDefault
}

# Safe JSON property probe under StrictMode.
function JProp { param($Obj, [string]$Name) if ($null -ne $Obj -and $null -ne $Obj.PSObject.Properties[$Name]) { return [string]$Obj.$Name } else { return '' } }

# Parse the observed check runs from --checks-from <file> (a JSON array, or one JSON object
# per line) and/or --checks-json <json>. Each record: name, head_sha, status, conclusion,
# run_id (all optional but name is required to be useful).
function Get-ObservedChecks {
    $recs = [System.Collections.Generic.List[object]]::new()
    $texts = [System.Collections.Generic.List[string]]::new()
    if ($opts.ContainsKey('checks-json') -and -not [string]::IsNullOrEmpty([string]$opts['checks-json'])) {
        $texts.Add([string]$opts['checks-json'])
    }
    if ($opts.ContainsKey('checks-from') -and -not [string]::IsNullOrEmpty([string]$opts['checks-from'])) {
        $cf = [string]$opts['checks-from']
        if (-not (Test-Path -LiteralPath $cf)) { Fail 2 "--checks-from file not found: $cf" }
        $raw = (Get-Content -LiteralPath $cf -Encoding utf8 -Raw)
        $whole = $null
        try { $whole = $raw | ConvertFrom-Json } catch { $whole = $null }
        if ($null -ne $whole) {
            foreach ($o in @($whole)) { $recs.Add($o) }
        } else {
            foreach ($ln in ($raw -split "`n")) {
                $t = $ln.Trim(); if ($t -eq '') { continue }
                $texts.Add($t)
            }
        }
    }
    foreach ($t in $texts) {
        $o = $null
        try { $o = $t | ConvertFrom-Json } catch { Fail 2 "check record is not valid JSON: $t" }
        foreach ($e in @($o)) { $recs.Add($e) }
    }
    return , $recs.ToArray()
}

function Cmd-CheckGate {
    $sha = Require-Opt 'sha'
    $elapsed = 0
    if ($opts.ContainsKey('elapsed-sec')) { if ([string]$opts['elapsed-sec'] -notmatch '^\d+$') { Fail 2 "--elapsed-sec must be a non-negative integer" }; $elapsed = [int]$opts['elapsed-sec'] }
    $deadline = if ($opts.ContainsKey('deadline-sec') -and [string]$opts['deadline-sec'] -match '^\d+$') { [int]$opts['deadline-sec'] } else { Get-ConfigInt 'PUBLISH_CI_DEADLINE_SEC' 1800 }
    $backoff  = if ($opts.ContainsKey('backoff-sec') -and [string]$opts['backoff-sec'] -match '^\d+$') { [int]$opts['backoff-sec'] } else { Get-ConfigInt 'PUBLISH_CI_BACKOFF_SEC' 30 }

    $required = @()
    $policyFile = Resolve-PolicyFileOrNull
    if ($policyFile) { $lines = Read-Lines $policyFile; if ($null -ne $lines) { $required = Get-RequiredCiChecks $lines } }

    if ($required.Count -eq 0) {
        Write-Gate 'no-required-checks' $sha @() @() @() @() $deadline $backoff $elapsed 0
        Say "OK   no required CI checks configured in policy - publish CI gate degrades to CI_WATCH default (nothing to enforce)"
        return
    }

    # Bind to the EXACT pushed SHA: a check record counts only when its head_sha equals --sha
    # (a record without a head_sha cannot be confirmed bound and is ignored). This is the
    # guard against "first run wins" - a run for another commit never satisfies the gate.
    $observed = Get-ObservedChecks
    $cmp = Get-PathComparer
    $byName = @{}
    foreach ($rec in $observed) {
        $rsha = JProp $rec 'head_sha'
        if ($rsha -eq '' -or -not [string]::Equals($rsha, $sha, $cmp)) { continue }
        $name = JProp $rec 'name'
        if ($name -eq '') { continue }
        if (-not $byName.ContainsKey($name)) { $byName[$name] = [System.Collections.Generic.List[object]]::new() }
        $byName[$name].Add($rec)
    }

    $green = [System.Collections.Generic.List[string]]::new()
    $red = [System.Collections.Generic.List[string]]::new()
    $pending = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $required) {
        if (-not $byName.ContainsKey($name)) { $missing.Add($name); continue }
        # Latest run wins (rerun of a failed check): pick the max run_id when present, else the
        # last record in input order.
        $recsForName = $byName[$name]
        $pick = $recsForName[$recsForName.Count - 1]
        $best = -1
        foreach ($rec in $recsForName) {
            $rid = JProp $rec 'run_id'
            if ($rid -match '^\d+$' -and [int]$rid -ge $best) { $best = [int]$rid; $pick = $rec }
        }
        $cls = Get-CiCheckClass (JProp $pick 'status') (JProp $pick 'conclusion')
        switch ($cls) {
            'green'   { $green.Add($name) }
            'red'     { $red.Add($name) }
            default   { $pending.Add($name) }
        }
    }

    $incomplete = $pending.Count + $missing.Count
    if ($red.Count -gt 0) {
        Write-Gate 'failed' $sha $green $red $pending $missing $deadline $backoff $elapsed 0
        Say "DENY publish CI gate fail-closed: required check(s) not green: $(( $red.ToArray() ) -join ', ')"
        Fail 9 "publish gate: $($red.Count) required check(s) red/cancelled at sha $sha"
    }
    if ($incomplete -eq 0) {
        Write-Gate 'ready' $sha $green $red $pending $missing $deadline $backoff $elapsed 0
        Say "OK   publish CI gate: all $($required.Count) required check(s) green at sha $sha"
        return
    }
    if ($elapsed -ge $deadline) {
        Write-Gate 'timeout' $sha $green $red $pending $missing $deadline $backoff $elapsed 0
        Say "DENY publish CI gate fail-closed: $incomplete required check(s) still not green after deadline ${deadline}s (missing: $(( $missing.ToArray() ) -join ', '); pending: $(( $pending.ToArray() ) -join ', '))"
        Fail 9 "publish gate: required CI incomplete at deadline (${elapsed}s >= ${deadline}s)"
    }
    Write-Gate 'wait' $sha $green $red $pending $missing $deadline $backoff $elapsed $backoff
    Say "WAIT publish CI gate: $incomplete required check(s) not green yet (elapsed ${elapsed}s < deadline ${deadline}s); retry after ${backoff}s"
    Fail 10 "publish gate: required CI still pending within the deadline"
}

function Write-Gate {
    param([string]$Verdict, [string]$Sha, $Green, $Red, $Pending, $Missing, [int]$Deadline, [int]$Backoff, [int]$Elapsed, [int]$NextBackoff)
    if (-not [bool](Opt 'json' $false)) { return }
    $out = [ordered]@{
        verdict         = $Verdict
        sha             = $Sha
        green           = @($Green)
        red             = @($Red)
        pending         = @($Pending)
        missing         = @($Missing)
        deadline_sec    = $Deadline
        backoff_sec     = $Backoff
        elapsed_sec     = $Elapsed
        next_backoff_sec = $NextBackoff
        remaining_sec   = [Math]::Max(0, $Deadline - $Elapsed)
    }
    Write-Output ($out | ConvertTo-Json -Depth 6 -Compress)
}

# ==========================================================================
# approval-*  (one-time human-approval gate: request / approve / reject / status)
# ==========================================================================
function Get-ApprovalDir {
    $work = ''
    if ($opts.ContainsKey('dir') -and -not [string]::IsNullOrEmpty([string]$opts['dir'])) { return [string]$opts['dir'] }
    if ($opts.ContainsKey('work') -and -not [string]::IsNullOrEmpty([string]$opts['work'])) { $work = [string]$opts['work'] }
    else { Fail 2 "provide --work <.work dir> or --dir <approvals dir>" }
    return (Join-Path $work 'approvals')
}
function Write-JsonAtomic {
    param([string]$Path, $Obj)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    $enc = New-Object System.Text.UTF8Encoding($false)
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, (($Obj | ConvertTo-Json -Depth 8) + "`n"), $enc)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Read-ApprovalById {
    param([string]$Id)
    $p = Join-Path (Get-ApprovalDir) ($Id + '.json')
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return ((Get-Content -LiteralPath $p -Raw -Encoding utf8) | ConvertFrom-Json) } catch { Fail 3 "approval artifact $p is unreadable" }
}

# Subject key + deterministic one-time id. A resume with the SAME subject+reason+fingerprint+
# policy recomputes the SAME id, so the request is never duplicated; ANY change to the
# affected paths (fingerprint) or the policy snapshot yields a DIFFERENT id - i.e. the old
# decision no longer applies to the new change set (staleness by construction).
function Get-ApprovalSubject {
    $t = [string](Opt 'task' '')
    $b = [string](Opt 'batch' '')
    if ($t -eq '' -and $b -eq '') { Fail 2 "approval needs --task <T-ID> and/or --batch <B-ID>" }
    if ($t -and -not (Test-TaskId $t)) { Fail 2 "malformed --task '$t'" }
    if ($b -and -not (Test-BatchId $b)) { Fail 2 "malformed --batch '$b'" }
    return "task:$t|batch:$b"
}
function Resolve-Fingerprint {
    if ($opts.ContainsKey('fingerprint') -and -not [string]::IsNullOrEmpty([string]$opts['fingerprint'])) { return [string]$opts['fingerprint'] }
    $changed = Get-ChangedPaths
    if ($changed.Count -eq 0) { Fail 2 "approval needs --fingerprint <hex> or --paths-from/--path (the affected change set)" }
    return (Get-DiffFingerprint $changed)
}
function Resolve-PolicyHash {
    if ($opts.ContainsKey('policy-hash') -and -not [string]::IsNullOrEmpty([string]$opts['policy-hash'])) { return [string]$opts['policy-hash'] }
    $policyFile = Resolve-PolicyFileOrNull
    $text = $null
    if ($policyFile -and (Test-Path -LiteralPath $policyFile)) { $text = (Get-Content -LiteralPath $policyFile -Raw -Encoding utf8) }
    return (Get-PolicySnapshotHash $text)
}
function Get-ApprovalNow {
    if ($opts.ContainsKey('now') -and -not [string]::IsNullOrEmpty([string]$opts['now'])) {
        try { return [System.DateTimeOffset]::Parse([string]$opts['now'], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime } catch { Fail 2 "--now '$($opts['now'])' is not a parseable UTC time" }
    }
    return [DateTime]::UtcNow
}
function Format-Utc { param([datetime]$T) return $T.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

function Cmd-ApprovalRequest {
    $subject = Get-ApprovalSubject
    $reason = [string](Opt 'reason' '')
    if ($reason -eq '') { Fail 2 "approval-request needs --reason <category> (e.g. human-review, force-lock, policy-bypass)" }
    $fp = Resolve-Fingerprint
    $ph = Resolve-PolicyHash
    $id = 'apr-' + (Get-Sha256Hex "$subject|$reason|$fp|$ph").Substring(0, 32)

    $existing = Read-ApprovalById $id
    if ($null -ne $existing) {
        # Idempotent: the SAME request already exists (open OR decided). Never recreate it -
        # a resume of the same gate reuses the same one-time id and its decision, if any.
        Emit-Approval $existing 'existing'
        return
    }
    $now = Get-ApprovalNow
    $deadlineSec = if ($opts.ContainsKey('deadline-sec') -and [string]$opts['deadline-sec'] -match '^\d+$') { [int]$opts['deadline-sec'] } else { Get-ConfigInt 'APPROVAL_DEADLINE_SEC' 86400 }
    $rec = [ordered]@{
        schema      = 'orchestra/approval@1'
        id          = $id
        subject     = $subject
        task        = [string](Opt 'task' '')
        batch       = [string](Opt 'batch' '')
        reason      = $reason
        fingerprint = $fp
        policy_hash = $ph
        created_at  = (Format-Utc $now)
        deadline    = (Format-Utc ($now.AddSeconds($deadlineSec)))
        decision    = ''
        decided_by  = ''
        decided_at  = ''
        note        = ''
    }
    Write-JsonAtomic (Join-Path (Get-ApprovalDir) ($id + '.json')) $rec
    Emit-Approval ([pscustomobject]$rec) 'created'
}

function Cmd-ApprovalDecide {
    param([string]$Decision)
    $id = Require-Opt 'id'
    $by = Require-Opt 'by'
    $rec = Read-ApprovalById $id
    if ($null -eq $rec) { Fail 2 "no approval request with id '$id'" }
    $prior = JProp $rec 'decision'
    if ($prior -ne '') {
        Fail 11 "approval id '$id' is already $prior by '$(JProp $rec 'decided_by')' at $(JProp $rec 'decided_at') - a one-time id cannot be decided twice"
    }
    $now = Get-ApprovalNow
    $deadline = JProp $rec 'deadline'
    if ($deadline -ne '') {
        try { $dl = [System.DateTimeOffset]::Parse($deadline, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime } catch { $dl = [DateTime]::MaxValue }
        if ($now -gt $dl) { Fail 11 "approval id '$id' expired at $deadline (no answer by the deadline is a fail-closed rejection); issue a fresh request" }
    }
    $rec.decision = $Decision
    $rec.decided_by = $by
    $rec.decided_at = (Format-Utc $now)
    $rec.note = [string](Opt 'note' '')
    Write-JsonAtomic (Join-Path (Get-ApprovalDir) ($id + '.json')) $rec
    Emit-Approval $rec "decided-$Decision"
    if ($Decision -eq 'reject') { Fail 11 "approval id '$id' rejected by '$by'" }
}

function Cmd-ApprovalStatus {
    # Locate the request: by --id, or re-derive the deterministic id from the CURRENT
    # subject/reason/fingerprint/policy (the natural resume path - the same inputs rebuild the
    # same id). Then judge freshness against the CURRENT fingerprint/policy and the clock.
    $curFp = ''
    $curPh = ''
    $id = [string](Opt 'id' '')
    if ($id -eq '') {
        $subject = Get-ApprovalSubject
        $reason = [string](Opt 'reason' '')
        if ($reason -eq '') { Fail 2 "approval-status needs --id, or --task/--batch + --reason (+ fingerprint) to locate the request" }
        $curFp = Resolve-Fingerprint
        $curPh = Resolve-PolicyHash
        $id = 'apr-' + (Get-Sha256Hex "$subject|$reason|$curFp|$curPh").Substring(0, 32)
    }
    $rec = Read-ApprovalById $id
    if ($null -eq $rec) {
        Write-ApprovalStatus 'none' $id $null $false $false
        Say "NONE no approval request '$id' on file - one must be requested (fail-closed: not approved)"
        Fail 11 "no approval request '$id'"
    }
    # Freshness: recompute current fingerprint/policy when the inputs are available, else fall
    # back to explicit --fingerprint/--policy-hash; when neither is given, freshness is unknown
    # and treated conservatively as fresh==true only if it matches the stored values trivially.
    if ($curFp -eq '') { if ($opts.ContainsKey('fingerprint') -or $opts.ContainsKey('paths-from') -or $opts.ContainsKey('path')) { $curFp = Resolve-Fingerprint } }
    if ($curPh -eq '') { if ($opts.ContainsKey('policy-hash') -or $opts.ContainsKey('policy') -or $opts.ContainsKey('work')) { $curPh = Resolve-PolicyHash } }
    $storedFp = JProp $rec 'fingerprint'
    $storedPh = JProp $rec 'policy_hash'
    $fpFresh = ($curFp -eq '' -or [string]::Equals($curFp, $storedFp, [System.StringComparison]::OrdinalIgnoreCase))
    $phFresh = ($curPh -eq '' -or [string]::Equals($curPh, $storedPh, [System.StringComparison]::OrdinalIgnoreCase))
    $fresh = ($fpFresh -and $phFresh)
    $decision = JProp $rec 'decision'
    $now = Get-ApprovalNow
    $deadline = JProp $rec 'deadline'
    $pastDeadline = $false
    if ($deadline -ne '') { try { $pastDeadline = ($now -gt [System.DateTimeOffset]::Parse($deadline, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime) } catch { } }

    if ($decision -eq 'approve') {
        if (-not $fresh) {
            Write-ApprovalStatus 'expired-stale' $id $rec $fresh $pastDeadline
            Say "STALE approval '$id' granted but the affected code/policy changed since issuance - decision expired (fail-closed); re-request"
            Fail 11 "approval '$id' is stale (affected code/policy changed after approval)"
        }
        Write-ApprovalStatus 'approved' $id $rec $fresh $pastDeadline
        Say "OK   approval '$id' granted by '$(JProp $rec 'decided_by')' and still valid (fingerprint+policy unchanged)"
        return
    }
    if ($decision -eq 'reject') {
        Write-ApprovalStatus 'rejected' $id $rec $fresh $pastDeadline
        Say "DENY approval '$id' was rejected by '$(JProp $rec 'decided_by')' (terminal)"
        Fail 11 "approval '$id' rejected"
    }
    # undecided (open)
    if (-not $fresh) {
        Write-ApprovalStatus 'superseded' $id $rec $fresh $pastDeadline
        Say "STALE open approval '$id' is against an outdated change set/policy - re-request against the current one"
        Fail 11 "open approval '$id' superseded (affected code/policy changed)"
    }
    if ($pastDeadline) {
        Write-ApprovalStatus 'expired-timeout' $id $rec $fresh $pastDeadline
        Say "DENY approval '$id' received no decision by its deadline $deadline (fail-closed: treated as rejection)"
        Fail 11 "approval '$id' expired without a decision (fail-closed rejection)"
    }
    Write-ApprovalStatus 'pending' $id $rec $fresh $pastDeadline
    Say "WAIT approval '$id' is pending the operator's decision (deadline $deadline)"
    Fail 12 "approval '$id' pending"
}

function Emit-Approval {
    param($Rec, [string]$State)
    if ([bool](Opt 'json' $false)) {
        $out = [ordered]@{
            state       = $State
            id          = JProp $Rec 'id'
            subject     = JProp $Rec 'subject'
            reason      = JProp $Rec 'reason'
            fingerprint = JProp $Rec 'fingerprint'
            policy_hash = JProp $Rec 'policy_hash'
            created_at  = JProp $Rec 'created_at'
            deadline    = JProp $Rec 'deadline'
            decision    = JProp $Rec 'decision'
            decided_by  = JProp $Rec 'decided_by'
        }
        Write-Output ($out | ConvertTo-Json -Depth 6 -Compress)
    } else {
        Write-Output "approval $State id=$(JProp $Rec 'id') subject=$(JProp $Rec 'subject') reason=$(JProp $Rec 'reason') decision=$(JProp $Rec 'decision')"
    }
}
function Write-ApprovalStatus {
    param([string]$Verdict, [string]$Id, $Rec, [bool]$Fresh, [bool]$PastDeadline)
    if (-not [bool](Opt 'json' $false)) { return }
    $out = [ordered]@{
        verdict       = $Verdict
        id            = $Id
        fresh         = $Fresh
        past_deadline = $PastDeadline
        subject       = if ($Rec) { JProp $Rec 'subject' } else { '' }
        reason        = if ($Rec) { JProp $Rec 'reason' } else { '' }
        decision      = if ($Rec) { JProp $Rec 'decision' } else { '' }
        decided_by    = if ($Rec) { JProp $Rec 'decided_by' } else { '' }
        deadline      = if ($Rec) { JProp $Rec 'deadline' } else { '' }
    }
    Write-Output ($out | ConvertTo-Json -Depth 6 -Compress)
}

# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------
try {
    switch ($Command) {
        'schema'           { Cmd-Schema }
        'validate-config'  { Cmd-ValidateConfig }
        'validate-policy'  { Cmd-ValidatePolicy }
        'migrate'          { Cmd-Migrate }
        'guard-path'       { Cmd-GuardPath }
        'check-paths'      { Cmd-CheckPaths }
        'check-publish'    { Cmd-CheckPublish }
        'check-gate'       { Cmd-CheckGate }
        'approval-request' { Cmd-ApprovalRequest }
        'approval-approve' { Cmd-ApprovalDecide 'approve' }
        'approval-reject'  { Cmd-ApprovalDecide 'reject' }
        'approval-status'  { Cmd-ApprovalStatus }
        default {
            Fail 2 "unknown command '$Command'. Valid: schema, validate-config, validate-policy, migrate, guard-path, check-paths, check-publish, check-gate, approval-request, approval-approve, approval-reject, approval-status"
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
