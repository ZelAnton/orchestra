#!/usr/bin/env bash
# Show the tail of the run journal (.work/journal.md) - last ~40 lines - without
# launching Claude Code. If there is no journal yet, says so.
if [ -f ".work/journal.md" ]; then
  tail -n 40 ".work/journal.md"
else
  echo "(no journal yet - no batch has completed)"
fi
