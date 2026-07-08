#!/usr/bin/env bash
# Raise the .work/PAUSE kill switch: ask a running processor to stop cleanly at its
# next phase/round boundary. The processor persists a consistent state, releases
# .work/orchestrator.lock and exits - no half-done worktree/merge is left behind. It
# only checks that the file EXISTS; any argument(s) are stored inside it as a
# human-readable reason (purely informational).
#
# This is NOT cc-resume: cc-resume RESUMES an interrupted session, whereas
# cc-pause/cc-unpause raise/clear a deliberate stop request. To continue after pausing,
# clear the switch with cc-unpause and start cc-processor (or cc-resume a live session);
# the processor picks up from where it stopped via its startup crash-recovery logic, no
# manual state fixup needed.
#
# Run from the project root (the folder that contains .work/).
mkdir -p ".work"
{
  echo "paused_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [ "$#" -gt 0 ] && echo "reason=$*"
} > ".work/PAUSE"
echo "Created .work/PAUSE - the processor will stop at its next phase/round boundary."
echo "Clear it with cc-unpause (then cc-processor / cc-resume) to continue."
