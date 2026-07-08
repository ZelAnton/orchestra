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
rem quote in ARGS with a single quote, in place, then writes the result back
rem to ARGS in the caller's environment.
rem
rem Contract with the caller: the caller must already have a variable named
rem ARGS set to the raw "%*" it received, captured as its OWN first
rem executable step, BEFORE the caller's own "setlocal EnableDelayedExpansion"
rem - capturing %* only here, after delayed expansion is already active in
rem the caller, would be too late: any literal "!" in the argument would
rem already have been eaten by delayed expansion at capture time. That
rem capture step cannot be moved into this shared file, since it has to run
rem while the CALLER's own %* (its own positional parameters) is in scope.
rem
rem The "endlocal & set VAR=value" on the line below is the standard cmd.exe
rem idiom for returning a value out of a setlocal block: the right-hand side
rem is expanded once, before either half of the line runs, so it still sees
rem the sanitized value computed inside this block, and "set" after endlocal
rem then writes it into the caller's environment (a plain "call" to another
rem .cmd file does not create its own environment scope by itself - only
rem "setlocal" does - so this executes in whatever scope was already active
rem when the caller issued "call cc-common.cmd sanitize").
setlocal EnableDelayedExpansion
set "SANITIZED=!ARGS:"='!"
endlocal & set "ARGS=%SANITIZED%"
exit /b 0
