<#
.SYNOPSIS
    Single-sourced whole-process-TREE termination primitive (task T-256).

.DESCRIPTION
    `Stop-ProcessTree` terminates a spawned child process AND every descendant it
    created, so a call that itself spawned helper workers leaves nothing behind. It
    is dot-sourced by every Orchestra tool that captures a child process
    (tools/supervisor.ps1 on cancel/timeout; tools/codex-runtime.ps1 on EVERY
    `Invoke-Captured` exit path) so there is exactly ONE hardened implementation, not
    a per-call copy that could drift (the reflection-based Kill(bool) overload
    detection and the Windows PowerShell 5.1 taskkill fallback both live here once).

    Two mechanisms, in order of preference:

      * .NET 5+ (pwsh 7): `Process.Kill($true)` terminates the entire tree atomically.
        The overload is probed by reflection (`GetType().GetMethod('Kill',[bool])`) -
        NOT by `Get-Member`/`.Definition`, whose bogus match under StrictMode silently
        skipped the fast path before it was hardened (KB K-024, T-227).
      * Windows PowerShell 5.1 (no Kill(bool) overload): `taskkill /PID <id> /T /F`
        reaches children by the PPID tree; a bare `Kill()` backstop covers the root.

    Reaping an ALREADY-EXITED root. This intentionally does NOT skip a root whose own
    process has already exited: on Windows a child's parent-PID field is not rewritten
    when the parent dies, so a descendant the root spawned can outlive it, and
    `Kill($true)` walks a live snapshot that still reaches that orphaned subtree. This
    is exactly what lets a normally-exited `codex exec` that leaked a descendant
    (e.g. one that inherited the runtime's redirected stdout/stderr pipe and would
    otherwise wedge the host forever, T-256) still be fully cleaned up. Callers pass
    the live `[System.Diagnostics.Process]` object they started and still hold, so the
    root PID cannot be reused out from under the kill (PID-reuse safety, KB K-024) -
    never call this with a bare re-looked-up PID.

.NOTES
    Runs under PowerShell 7 (pwsh) and Windows PowerShell 5.1. Pure library: it only
    defines a function and has no top-level side effects, so it is safe to dot-source
    from any host without disturbing the caller's argument parsing or dispatch.
#>

# --------------------------------------------------------------------------
# Terminate the whole child process TREE (so a call that itself spawned workers
# leaves nothing behind on cancel/timeout, or after a normal exit that leaked a
# descendant). See the file header for the exited-root and PID-reuse rationale.
# --------------------------------------------------------------------------
function Stop-ProcessTree {
    param($Proc)
    if ($null -eq $Proc) { return }
    $killedTree = $false
    try {
        # .NET 5+ (pwsh): Kill(true) terminates the entire process tree atomically, and
        # still reaches an orphaned subtree even if the root itself has already exited.
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
        $onWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
        if ($onWindows) {
            try { & taskkill /PID $Proc.Id /T /F 2>$null | Out-Null } catch { }
        }
        try { if (-not $Proc.HasExited) { $Proc.Kill() } } catch { }
    }
    try { $Proc.WaitForExit(5000) | Out-Null } catch { }
}
