@echo off
rem Shared building blocks for launchers/*.cmd (T-037). This file is a small
rem "batch library" of callable subroutines, never meant to be run directly:
rem it is always invoked from another launcher via "call", with the desired
rem subroutine name as the first argument:
rem
rem   call "%~dp0cc-common.cmd" run <agent> <permission-mode> "<prompt>"
rem   call "%~dp0cc-common.cmd" sanitize
rem
rem "goto :%1" below jumps straight to the matching label; an unset/unknown
rem first argument is a caller bug, not something this file guards against.
goto :%1

:run
rem Runs "chcp 65001" then invokes claude with a fixed agent/permission-mode/
rem prompt combination - the pattern shared verbatim by cc-audit.cmd,
rem cc-enhance.cmd and cc-github.cmd before this task. %2=agent,
rem %3=permission-mode, %4=prompt. The caller must pass the prompt as a
rem single already-quoted argument, exactly as those three launchers do -
rem none of their prompt texts contain a literal " or % that would need
rem further escaping. (Runtime user input DOES need that kind of escaping -
rem see :sanitize below, used only by the two launchers that accept a
rem command-line argument.)
chcp 65001 >nul
claude --agent %2 --permission-mode %3 %4
exit /b %errorlevel%

:sanitize
rem Shared tail end of the ARGS-sanitization block duplicated (before this
rem task) in cc-queue.cmd and cc-thinker.cmd: replaces every embedded double
rem quote in ARGS with a single quote, in place, in the CALLER's own ARGS
rem variable.
rem
rem Contract with the caller: the caller must already have (a) a variable
rem named ARGS set to the raw "%*" it received, captured as its OWN first
rem executable step, BEFORE the caller's own "setlocal EnableDelayedExpansion"
rem - capturing %* only here, after delayed expansion is already active in
rem the caller, would be too late: any literal "!" in the argument would
rem already have been eaten by delayed expansion at capture time. That
rem capture step cannot be moved into this shared file, since it has to run
rem while the CALLER's own %* (its own positional parameters) is in scope.
rem And (b) delayed expansion already enabled (the caller's own "setlocal
rem EnableDelayedExpansion", issued after the ARGS capture above) - this
rem label relies on that being active already and deliberately does NOT
rem open its own setlocal here.
rem
rem A plain "call" to another .cmd file does not create its own environment
rem scope by itself - only "setlocal" does - so the line below runs directly
rem in whatever scope the caller had active when it issued "call
rem cc-common.cmd sanitize", and writes ARGS right back into that same scope.
rem This must NOT be split into "compute into a temp var, then endlocal &
rem set ARGS=%TEMP%" (as an earlier version of this file did): that pattern
rem returns a value out of a setlocal block by letting "%TEMP%" percent-
rem expand while the block's own delayed expansion is still active for
rem parsing that line, and cmd.exe then runs a SECOND, delayed-expansion
rem pass over the resulting text - so any literal "!" that made it into the
rem sanitized value (a very plausible character in a task description, e.g.
rem "fix bug ASAP!") gets silently eaten as a (usually undefined, empty)
rem !variable! reference instead of surviving as a literal character.
rem Assigning directly with "!ARGS:"='!" below performs the substring
rem replacement and the assignment in the exact same single delayed-
rem expansion pass that produced the replacement text, so there is no
rem second pass left to mis-parse any "!" the resulting value contains.
set "ARGS=!ARGS:"='!"
exit /b 0
