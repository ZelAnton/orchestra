@echo off
chcp 65001 >nul
rem Launch the "thinker" analytical partner in the current folder.
rem
rem Provider selection:
rem   codex|claude                 explicit provider for this run
rem   --provider codex|claude      equivalent long form
rem   ORCHESTRA_PROVIDER           default when no explicit provider is present
rem   claude                       compatibility default
rem
rem Any remaining arguments form the optional opening topic. The Claude path keeps
rem the established quote/%%/! sanitization contract. The Codex path forwards the
rem original argv to codex-role-runtime.ps1, which consumes the provider token and
rem opens the normal interactive Codex TUI.
setlocal
set "LAUNCHER_DIR=%~dp0"
for %%I in (.) do set "PROJECT_ROOT=%%~fI"
set "ARGS=%*"
set "PROVIDER=%ORCHESTRA_PROVIDER%"
if not defined PROVIDER set "PROVIDER=claude"
set "PROVIDER_TOKEN_COUNT=0"

if /I "%~1"=="claude" (
  set "PROVIDER=claude"
  set "PROVIDER_TOKEN_COUNT=1"
)
if /I "%~1"=="codex" (
  set "PROVIDER=codex"
  set "PROVIDER_TOKEN_COUNT=1"
)
if /I "%~1"=="--provider" (
  if "%~2"=="" (
    echo Flag --provider requires a value.
    exit /b 2
  )
  set "PROVIDER=%~2"
  set "PROVIDER_TOKEN_COUNT=2"
)

if /I "%PROVIDER%"=="codex" goto :run_codex
if /I not "%PROVIDER%"=="claude" (
  echo Invalid provider "%PROVIDER%". Allowed: claude, codex.
  exit /b 2
)

rem Strip an explicit provider prefix before preserving the historical free-form topic
rem behavior. ARGS was captured before delayed expansion, so literal ! remains intact.
set "HAS_TOPIC=1"
if "%PROVIDER_TOKEN_COUNT%"=="0" if "%~1"=="" set "HAS_TOPIC="
if "%PROVIDER_TOKEN_COUNT%"=="1" if "%~2"=="" set "HAS_TOPIC="
if "%PROVIDER_TOKEN_COUNT%"=="2" if "%~3"=="" set "HAS_TOPIC="
if not defined HAS_TOPIC goto :run_claude_bare
setlocal EnableDelayedExpansion
if "!PROVIDER_TOKEN_COUNT!"=="1" (
  if "%~2"=="" (set "ARGS=") else set "ARGS=!ARGS:* =!"
)
if "!PROVIDER_TOKEN_COUNT!"=="2" (
  if "%~3"=="" (
    set "ARGS="
  ) else (
    set "ARGS=!ARGS:* =!"
    set "ARGS=!ARGS:* =!"
  )
)
call "%~dp0cc-common.cmd" sanitize
if defined ARGS (
  claude --agent thinker --permission-mode auto "Per your system prompt: act as the analytical thinking partner for this project. Opening topic: !ARGS!"
)
exit /b %ERRORLEVEL%

:run_claude_bare
claude --agent thinker --permission-mode auto
exit /b %ERRORLEVEL%

:run_codex
set "CODEX_ROLE_RUNTIME=%LAUNCHER_DIR%..\tools\codex-role-runtime.ps1"
if exist "%CODEX_ROLE_RUNTIME%" goto :codex_runtime_found
set "CODEX_ROLE_RUNTIME=%LAUNCHER_DIR%codex-role-runtime.ps1"
if exist "%CODEX_ROLE_RUNTIME%" goto :codex_runtime_found
echo Codex role runtime not found. Run cc-sync from the Orchestra checkout.
exit /b 12
:codex_runtime_found
setlocal EnableDelayedExpansion
if "!PROVIDER_TOKEN_COUNT!"=="1" (
  if "%~2"=="" (set "ARGS=") else set "ARGS=!ARGS:* =!"
)
if "!PROVIDER_TOKEN_COUNT!"=="2" (
  if "%~3"=="" (
    set "ARGS="
  ) else (
    set "ARGS=!ARGS:* =!"
    set "ARGS=!ARGS:* =!"
  )
)
set "ORCHESTRA_CODEX_ROLE_TOPIC=!ARGS!"
pwsh -NoProfile -File "%CODEX_ROLE_RUNTIME%" -Role thinker -Root "%PROJECT_ROOT%" -RequestedProvider codex
exit /b %ERRORLEVEL%
