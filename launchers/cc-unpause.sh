#!/usr/bin/env bash
# Clear the .work/PAUSE kill switch created by cc-pause, so the processor may run again.
# After clearing it, start the processor normally (cc-processor) or resume the
# interrupted session (cc-resume); it continues from where it paused via its startup
# crash-recovery logic - no manual state fixup is needed. This only removes the switch
# file; it does not start anything.
#
# Run from the project root (the folder that contains .work/).
if [ -e ".work/PAUSE" ]; then
  rm -f ".work/PAUSE"
  echo "Removed .work/PAUSE - the processor may run again (start cc-processor or resume with cc-resume)."
else
  echo ".work/PAUSE does not exist - nothing to clear (not paused by this switch)."
fi
