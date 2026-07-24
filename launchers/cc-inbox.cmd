@echo off
rem Run the intelligent cross-project inbox curator on demand in the current repository.
rem The role critically reviews incoming messages, creates justified local queue tasks,
rem reconciles completed work, and sends registry-routed replies. Background polling is
rem deliberately absent; processor also invokes the same role at safe cohort boundaries.
call "%~dp0cc-common.cmd" run inbox_curator auto "Per your system prompt, process this repository's cross-project inbox now. MODE=all. queue_write_mode=auto. ROOT=current repository root."
