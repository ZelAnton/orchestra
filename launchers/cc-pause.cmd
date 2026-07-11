@echo off
chcp 65001 >nul
rem Raise the .work\PAUSE kill switch: ask a running processor to stop cleanly at its
rem next phase/round boundary. The processor persists a consistent state, releases
rem .work\orchestrator.lock and exits - no half-done worktree/merge is left behind. It
rem only checks that the file EXISTS; any argument(s) are stored inside it as a
rem human-readable reason (purely informational).
rem
rem This is NOT cc-resume: cc-resume RESUMES an interrupted session, whereas
rem cc-pause/cc-unpause raise/clear a deliberate stop request. To continue after pausing,
rem clear the switch with cc-unpause and start cc-processor (or cc-resume a live session);
rem the processor picks up from where it stopped via its startup crash-recovery logic.
rem
rem Run from the project root (the folder that contains .work\).
rem
rem The optional reason argument is captured into ARGS BEFORE
rem "setlocal EnableDelayedExpansion" (so a literal "!" survives) and later written via
rem delayed expansion (!ARGS!), whose value is not re-parsed for redirection/pipe
rem metacharacters. NOTE: the capture is "set ARGS=%*" WITHOUT quotes around the target,
rem unlike cc-queue.cmd's "set "ARGS=%*"". If the reason is quoted and contains & | < >
rem (e.g. "freeze & audit"), those quotes protect the metacharacters during tokenization;
rem wrapping the SET in its own quotes would instead collide with the user's quotes,
rem unquote the metacharacters, and hijack this line - which would stop .work\PAUSE from
rem being created at all (the kill switch silently failing is worse than a cosmetic glitch).
set ARGS=%*
setlocal EnableDelayedExpansion
if not exist ".work" mkdir ".work"
rem UTC ISO-8601 timestamp (informational). PowerShell keeps it portable and locale-safe.
set "CC_PAUSE_TS="
for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')"`) do set "CC_PAUSE_TS=%%i"
rem Redirection-first form (> "file" echo ...) avoids a trailing space on the line and
rem creates/truncates the switch file fresh.
> ".work\PAUSE" echo paused_at=!CC_PAUSE_TS!
if not "%~1"=="" (
  >> ".work\PAUSE" echo reason=!ARGS!
)
echo Created .work\PAUSE - the processor will stop at its next phase/round boundary.
echo Clear it with cc-unpause ^(then cc-processor / cc-resume^) to continue.
endlocal
