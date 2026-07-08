@echo off
chcp 65001 >nul
rem Clear the .work\PAUSE kill switch created by cc-pause, so the processor may run
rem again. After clearing it, start the processor normally (cc-processor) or resume the
rem interrupted session (cc-resume); it continues from where it paused via its startup
rem crash-recovery logic - no manual state fixup is needed. This only removes the switch
rem file; it does not start anything.
rem
rem Run from the project root (the folder that contains .work\).
if exist ".work\PAUSE" (
  del /q ".work\PAUSE"
  echo Removed .work\PAUSE - the processor may run again ^(start cc-processor or resume with cc-resume^).
) else (
  echo .work\PAUSE does not exist - nothing to clear ^(not paused by this switch^).
)
