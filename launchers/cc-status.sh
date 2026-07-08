#!/usr/bin/env bash
# Show the current orchestra overview (.work/status.md) and the tail of the run
# journal (.work/journal.md) in the current folder - without launching Claude Code.
# Does not dump whole files: only the last ~40 lines of each (the overview is usually
# shorter).
echo "=== .work/status.md (last 40 lines) ==="
if [ -f ".work/status.md" ]; then
  tail -n 40 ".work/status.md"
else
  echo "(no active overview - processor has not run yet or the queue is empty)"
fi
echo
echo "=== .work/journal.md (last 40 lines) ==="
if [ -f ".work/journal.md" ]; then
  tail -n 40 ".work/journal.md"
else
  echo "(journal is empty - no batch has completed yet)"
fi
