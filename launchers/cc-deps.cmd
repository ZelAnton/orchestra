@echo off
rem Reconcile the current repository's published products and direct registered-project
rem dependencies into the user-global Orchestra project graph.
call "%~dp0cc-common.cmd" run dependency_curator auto "Per your system prompt, refresh this repository's dependency graph now. MODE=refresh. CALLER=manual. ROOT=current repository root. WORK=.work. BASE=current committed trunk tip."
