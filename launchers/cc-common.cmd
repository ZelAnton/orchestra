@echo off
rem Shared building blocks for launchers/*.cmd (T-037). This file is a small
rem "batch library" of callable subroutines, never meant to be run directly:
rem it is always invoked from another launcher via "call", with the desired
rem subroutine name as the first argument:
rem
rem   call "%~dp0cc-common.cmd" run <agent> "<prompt>"
rem   call "%~dp0cc-common.cmd" resolve_permission_mode
rem   call "%~dp0cc-common.cmd" resolve_provider
rem   call "%~dp0cc-common.cmd" sanitize
rem
rem "goto :%1" below jumps straight to the matching label; an unset/unknown
rem first argument is a caller bug, not something this file guards against.
goto :%1

:run
rem Runs "chcp 65001" then invokes claude with a fixed agent/prompt
rem combination - the pattern shared verbatim by cc-audit.cmd,
rem cc-enhance.cmd and cc-github.cmd before this task. %2=agent,
rem %3=prompt. ORCHESTRA_CLAUDE_PERMISSION_MODE selects the mode after strict
rem validation. The caller must pass the prompt as a
rem single already-quoted argument, exactly as those three launchers do -
rem none of their prompt texts contain a literal " or % that would need
rem further escaping. (Runtime user input DOES need that kind of escaping -
rem see :sanitize below, used only by the two launchers that accept a
rem command-line argument.)
setlocal
chcp 65001 >nul
call :resolve_permission_mode
if errorlevel 1 exit /b %ERRORLEVEL%
claude --agent %2 --permission-mode %CLAUDE_PERMISSION_MODE% %3
exit /b %errorlevel%

:resolve_permission_mode
rem Operator-owned opt-in for Claude launchers. Keep the committed agent
rem frontmatter on auto: a bypassPermissions parent takes precedence for every
rem spawned subagent, so changing installed role definitions is unnecessary. Delayed
rem expansion is intentional: the root-config value is untrusted command text until it
rem has matched one of the two literals, so percent-expanding it would let a quote plus
rem cmd metacharacters execute before the fail-closed branch.
setlocal EnableExtensions EnableDelayedExpansion
call :config_get ORCHESTRA_CLAUDE_PERMISSION_MODE
if errorlevel 1 exit /b %ERRORLEVEL%
set "CANDIDATE_CLAUDE_PERMISSION_MODE=!CC_CONFIG_VALUE!"
if not defined CANDIDATE_CLAUDE_PERMISSION_MODE set "CANDIDATE_CLAUDE_PERMISSION_MODE=auto"
if "!CANDIDATE_CLAUDE_PERMISSION_MODE!"=="auto" goto :permission_mode_auto
if "!CANDIDATE_CLAUDE_PERMISSION_MODE!"=="bypassPermissions" goto :permission_mode_bypass
endlocal
echo Invalid ORCHESTRA_CLAUDE_PERMISSION_MODE. Allowed: auto, bypassPermissions. 1>&2
set "CLAUDE_PERMISSION_MODE="
exit /b 2

:permission_mode_auto
endlocal
set "CLAUDE_PERMISSION_MODE=auto"
exit /b 0

:resolve_provider
setlocal EnableExtensions EnableDelayedExpansion
call :config_get ORCHESTRA_PROVIDER
if errorlevel 1 exit /b %ERRORLEVEL%
set "CANDIDATE_PROVIDER=!CC_CONFIG_VALUE!"
if not defined CANDIDATE_PROVIDER set "CANDIDATE_PROVIDER=claude"
if /I "!CANDIDATE_PROVIDER!"=="claude" (
  endlocal
  set "PROVIDER=claude"
  exit /b 0
)
if /I "!CANDIDATE_PROVIDER!"=="codex" (
  endlocal
  set "PROVIDER=codex"
  exit /b 0
)
endlocal
echo Invalid ORCHESTRA_PROVIDER. Allowed: claude, codex. 1>&2
set "PROVIDER="
exit /b 2

:config_get
set "CC_CONFIG_VALUE="
if not defined ORCHESTRA_HOME set "ORCHESTRA_HOME=%USERPROFILE%\.orchestra"
set "CC_CONFIG_RUNTIME=%~dp0..\tools\config-runtime.ps1"
if not exist "%CC_CONFIG_RUNTIME%" set "CC_CONFIG_RUNTIME=%ORCHESTRA_HOME%\scripts\config-runtime.ps1"
if not exist "%CC_CONFIG_RUNTIME%" (
  echo Orchestra config runtime is missing: %CC_CONFIG_RUNTIME% 1>&2
  exit /b 12
)
set "CC_CONFIG_PS=pwsh"
where pwsh >nul 2>nul
if errorlevel 1 set "CC_CONFIG_PS=powershell"
call :make_config_capture_dir
if errorlevel 1 exit /b %ERRORLEVEL%
set "CC_CONFIG_CAPTURE=%CC_CONFIG_CAPTURE_DIR%\value.tmp"
%CC_CONFIG_PS% -NoProfile -File "%CC_CONFIG_RUNTIME%" get --work "%CD%\.work" --key %1 > "%CC_CONFIG_CAPTURE%"
set "CC_CONFIG_RC=%ERRORLEVEL%"
if exist "%CC_CONFIG_CAPTURE%" (
  for /f "usebackq delims=" %%V in ("%CC_CONFIG_CAPTURE%") do set "CC_CONFIG_VALUE=%%V"
  del /q "%CC_CONFIG_CAPTURE%" >nul 2>nul
)
rmdir "%CC_CONFIG_CAPTURE_DIR%" >nul 2>nul
if not "%CC_CONFIG_RC%"=="0" exit /b %CC_CONFIG_RC%
exit /b 0

:make_config_capture_dir
setlocal EnableExtensions EnableDelayedExpansion
set /a CC_CONFIG_CAPTURE_ATTEMPTS=0
:config_capture_retry
set /a CC_CONFIG_CAPTURE_ATTEMPTS+=1
set "CC_CONFIG_CAPTURE_CANDIDATE=%TEMP%\orchestra-config-!RANDOM!-!RANDOM!"
mkdir "!CC_CONFIG_CAPTURE_CANDIDATE!" >nul 2>nul
if not errorlevel 1 (
  for %%D in ("!CC_CONFIG_CAPTURE_CANDIDATE!") do endlocal & set "CC_CONFIG_CAPTURE_DIR=%%~D" & exit /b 0
)
if !CC_CONFIG_CAPTURE_ATTEMPTS! LSS 32 goto :config_capture_retry
endlocal
echo Failed to allocate an isolated Orchestra config capture directory. 1>&2
exit /b 12

:permission_mode_bypass
endlocal
set "CLAUDE_PERMISSION_MODE=bypassPermissions"
exit /b 0

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
