<#
.SYNOPSIS
    Single-sourced whole-process-TREE termination primitive (task T-256).

.DESCRIPTION
    `Stop-ProcessTree` terminates a spawned child process AND every descendant it
    created, so a call that itself spawned helper workers leaves nothing behind. It
    is dot-sourced by every Orchestra tool that captures a child process
    (tools/supervisor.ps1 and tools/codex-runtime.ps1 on EVERY captured-call exit path)
    so there is exactly ONE hardened implementation, not
    a per-call copy that could drift (the reflection-based Kill(bool) overload
    detection and the Windows PowerShell 5.1 taskkill fallback both live here once).

    Two complementary mechanisms:

      * The TREE walk (all platforms).
          - .NET 5+ (pwsh 7): `Process.Kill($true)` terminates the entire tree. The
            overload is probed by reflection (`GetType().GetMethod('Kill',[bool])`) -
            NOT by `Get-Member`/`.Definition`, whose bogus match under StrictMode silently
            skipped the fast path before it was hardened (KB K-024, T-227).
          - Windows PowerShell 5.1 (no Kill(bool) overload): `taskkill /PID <id> /T /F`
            reaches children by the PPID tree; a bare `Kill()` backstop covers the root.
        The walk is keyed on each process's CURRENT parent PID at call time.

      * The process-GROUP reap (POSIX only, ADDITIVE - T-256 Linux/macOS fix).
        The tree walk above is correct on Windows even for an ALREADY-EXITED root: there a
        child's parent-PID field is not rewritten when the parent dies, so an orphaned
        subtree the root spawned is still reachable from the root PID. On Linux/macOS this
        does NOT hold - when an intermediate process exits, the kernel REPARENTS its
        orphaned children (to the nearest subreaper / PID 1), rewriting their parent PID. A
        walk from the already-exited root then never reaches a grandchild that was
        reparented away. That is exactly the leak(success)/leak(error) case: a fast-exiting
        `codex` leaves behind a helper that inherited the runtime's redirected stdout/stderr
        pipe; by the time Stop-ProcessTree runs, `codex` is gone and the helper has been
        reparented, so Kill($true) misses it and the helper wedges the host on that still-open
        pipe forever. A process's process-GROUP id, however, survives reparenting (the kernel
        rewrites the parent, never the pgid, unless the process itself calls setpgid/setsid).
        So when the captured child was launched into its OWN fresh process group at spawn
        (via `setsid`, which makes pgid == the child's own pid), the whole subtree can be
        reaped by SIGKILL to that group even after reparenting. Callers OPT IN by passing the
        captured pgid as -PosixProcessGroupId; without it (e.g. tools/supervisor.ps1, whose
        timeout/cancel kill hits a STILL-LIVE child whose descendants have not been reparented
        yet) the group reap is simply skipped and behaviour is exactly as before.

    Reaping an ALREADY-EXITED root. Stop-ProcessTree intentionally does NOT skip a root
    whose own process has already exited. Callers pass the live
    `[System.Diagnostics.Process]` object they started and still hold, so the root PID
    cannot be reused out from under the kill (PID-reuse safety, KB K-024) - never call this
    with a bare re-looked-up PID.

.NOTES
    Runs under PowerShell 7 (pwsh) and Windows PowerShell 5.1. Pure library: it only
    defines functions and has no top-level side effects, so it is safe to dot-source from
    any host without disturbing the caller's argument parsing or dispatch.
#>

# Cached host probes (StrictMode-safe: initialized before first read). setsid/kill are
# located once per host and reused; a $null result means "not available - fall back / skip".
$script:SetsidLauncher = $null
$script:SetsidProbed   = $false
$script:KillBinary     = $null
$script:KillProbed     = $false

function Test-OnWindows {
    return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
}

# --------------------------------------------------------------------------
# Locate `setsid` once (POSIX only). A spawn site uses it to launch a captured child into
# its OWN new session / process group (pgid == the child's pid), so a helper the child
# leaks stays reapable-by-group even after the child exits and the helper is reparented.
# Optional/defensive: returns $null on Windows or when setsid is absent, and the caller then
# spawns plainly (no group reap) exactly as before. Plain `setsid` execs the target in place
# (it forks only when the calling process is already a group leader, which a .NET-spawned
# child is not), so the process the caller Start()s keeps its pid and reports the target's
# own exit code.
# --------------------------------------------------------------------------
function Resolve-SetsidLauncher {
    if ($script:SetsidProbed) { return $script:SetsidLauncher }
    $script:SetsidProbed = $true
    if (Test-OnWindows) { return $null }
    try {
        $cmd = @(Get-Command 'setsid' -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
        if ($cmd -and $cmd.Source) { $script:SetsidLauncher = [string]$cmd.Source }
    } catch { $script:SetsidLauncher = $null }
    return $script:SetsidLauncher
}

# --------------------------------------------------------------------------
# The runtime host's OWN process group id (POSIX), read from /proc/self/stat. Used only as a
# safety guard so the group reap can never signal the caller's own group. The comm field
# (2nd) can itself contain spaces/parens, so parse the fields AFTER the last ')': they are
# state, ppid, pgrp, ... - pgrp is the 3rd. Returns -1 when it cannot be determined (e.g. no
# /proc on macOS); the caller's structural invariant (the pgid is a freshly-allocated child
# pid, never the host's live group-leader pid) already makes a host-group hit impossible, so
# -1 just disables the extra guard.
# --------------------------------------------------------------------------
function Get-PosixHostProcessGroupId {
    try {
        $stat = '/proc/self/stat'
        if (-not (Test-Path -LiteralPath $stat)) { return -1 }
        $raw = [System.IO.File]::ReadAllText($stat)
        $rp = $raw.LastIndexOf(')')
        if ($rp -lt 0) { return -1 }
        $fields = @(($raw.Substring($rp + 1).Trim()) -split '\s+')
        if ($fields.Count -ge 3) { return [int]$fields[2] }
        return -1
    } catch { return -1 }
}

# --------------------------------------------------------------------------
# SIGKILL an entire POSIX process group by pgid. Primary path is the libc `killpg` syscall
# (unambiguous, no CLI arg-parsing quirks, and NOT the PowerShell `kill`->Stop-Process alias);
# a `/bin/kill -s KILL -- -<pgid>` external fallback covers a host where Add-Type / P-Invoke is
# unavailable (`--` ends option parsing so the negative operand is taken as a process-group
# target, since kill(2) treats a pid < -1 as "process group |pid|"). Both are no-throw and
# best-effort: an empty / already-gone group just yields ESRCH.
# --------------------------------------------------------------------------
function Resolve-KillBinary {
    if ($script:KillProbed) { return $script:KillBinary }
    $script:KillProbed = $true
    try {
        $cmd = @(Get-Command 'kill' -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
        if ($cmd -and $cmd.Source) { $script:KillBinary = [string]$cmd.Source }
    } catch { $script:KillBinary = $null }
    return $script:KillBinary
}
function Send-PosixGroupKill {
    param([int]$Pgid)
    if ($Pgid -le 1) { return }
    $done = $false
    try {
        if (-not ('Orchestra.PosixNative' -as [type])) {
            Add-Type -Namespace 'Orchestra' -Name 'PosixNative' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("libc", SetLastError = true)]
public static extern int killpg(int pgrp, int sig);
'@ -ErrorAction Stop
        }
        # SIGKILL == 9 on Linux and macOS. killpg takes the POSITIVE group id.
        [void][Orchestra.PosixNative]::killpg($Pgid, 9)
        $done = $true
    } catch { $done = $false }
    if (-not $done) {
        $killBin = Resolve-KillBinary
        if ($killBin) {
            try { & $killBin '-s' 'KILL' '--' "-$Pgid" 2>$null | Out-Null } catch { }
        }
    }
}

# --------------------------------------------------------------------------
# Terminate the whole child process TREE (so a call that itself spawned workers leaves
# nothing behind on any exit, including normal success/error). See
# the file header for the exited-root, reparenting and PID-reuse rationale.
#
#   -PosixProcessGroupId : optional. When > 1 (and off Windows) ALSO SIGKILL this whole POSIX
#       process group AFTER the tree walk, to reap a reparented descendant the walk cannot
#       reach. Pass the pgid captured at spawn (== the child's pid when it was launched via
#       setsid). 0/unset preserves the pre-T-256 behaviour, so callers that spawn plainly
#       (tools/supervisor.ps1) are unaffected.
# --------------------------------------------------------------------------
function Stop-ProcessTree {
    param(
        $Proc,
        [int]$PosixProcessGroupId = 0
    )
    if ($null -eq $Proc) { return }
    $onWindows = Test-OnWindows
    $killedTree = $false
    try {
        # .NET 5+ (pwsh): Kill(true) terminates the process tree by walking each process's
        # CURRENT parent PID. On Windows this still reaches an orphaned subtree even after the
        # root exited; on POSIX a reparented descendant is instead reaped by the group step below.
        $treeKill = $Proc.GetType().GetMethod('Kill', [type[]]@([bool]))
        if ($null -ne $treeKill) {
            $Proc.Kill($true)
            $killedTree = $true
        }
    } catch {
        # fall through to the taskkill / bare-Kill fallback below.
        $killedTree = $false
    }
    if (-not $killedTree) {
        # Windows PowerShell 5.1 has no tree overload: use taskkill /T /F to reach children.
        if ($onWindows) {
            try { & taskkill /PID $Proc.Id /T /F 2>$null | Out-Null } catch { }
        }
        try { if (-not $Proc.HasExited) { $Proc.Kill() } } catch { }
    }
    # POSIX belt-and-suspenders (T-256): reap a REPARENTED descendant the ppid tree-walk
    # missed, by SIGKILLing the child's whole process group. Guarded: only when a pgid was
    # captured (> 1), only off Windows, and NEVER the host's own group. The pgid is a freshly
    # allocated child pid, so it can never equal the host's group id (that group leader is still
    # alive, holding its pid) - the host-group comparison is defence in depth on top of that.
    if ($PosixProcessGroupId -gt 1 -and -not $onWindows) {
        if ($PosixProcessGroupId -ne (Get-PosixHostProcessGroupId)) {
            Send-PosixGroupKill $PosixProcessGroupId
        }
    }
    try { $Proc.WaitForExit(5000) | Out-Null } catch { }
}
