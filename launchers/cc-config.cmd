@echo off
chcp 65001 >nul
rem Seed .work\config.md and .work\constraints.md from the repo templates if they do not
rem exist yet. An existing target file is NEVER overwritten (same guarantee for both).
rem  - config.md: only the copyable block between the "# >>> config.md seed start" /
rem    "# <<< config.md seed end" markers inside config.example.md's fenced code block
rem    (headings/prose/tables are never copied).
rem  - constraints.md: the WHOLE constraints.example.md (the entire document IS the policy
rem    content - there is no seed block to slice, unlike config.md).
rem Templates are looked up next to launchers\ first (repo checkout layout: this file lives
rem in launchers\, the *.example.md one level up at the repo root), then alongside this
rem script (mirror layout in %USERPROFILE%\.claude\scripts, where cc-sync.cmd mirrors the
rem templates flat next to the *.cmd files).
if not exist ".work" mkdir ".work"
setlocal
rem Prefer pwsh (defaults to UTF-8) but fall back to Windows PowerShell 5.1, which needs an
rem explicit UTF-8 encoding on both read and write: without it, a BOM-less UTF-8 template
rem with Cyrillic comments gets misread as ANSI and re-encoded as mojibake (same class of
rem bug as T-029). Reading via [System.IO.File]::ReadAllLines/ReadAllText with an explicit
rem UTF8 encoding and writing via WriteAllLines/WriteAllText with a BOM-less
rem UTF8Encoding($false) - matching generate-coders.ps1's WriteAllText pattern - keeps the
rem output byte-identical and BOM-less regardless of which PowerShell runs this.
set "CC_PS_EXE=powershell"
where pwsh >nul 2>nul
if not errorlevel 1 set "CC_PS_EXE=pwsh"

if exist ".work\config.md" (
  echo .work\config.md already exists - leaving it unchanged.
) else call :seed_config

if exist ".work\constraints.md" (
  echo .work\constraints.md already exists - leaving it unchanged.
) else call :seed_constraints

endlocal
goto :eof

:seed_config
set "CC_CONFIG_TEMPLATE=%~dp0..\config.example.md"
if not exist "%CC_CONFIG_TEMPLATE%" set "CC_CONFIG_TEMPLATE=%~dp0config.example.md"
if not exist "%CC_CONFIG_TEMPLATE%" (
  echo Failed to create .work\config.md ^(config.example.md missing next to launchers?^).
  goto :eof
)
%CC_PS_EXE% -NoProfile -Command "$ErrorActionPreference='Stop'; $c=[System.IO.File]::ReadAllLines('%CC_CONFIG_TEMPLATE%', [System.Text.Encoding]::UTF8); $s=($c | Select-String -Pattern '^# >>> config\.md seed start' | Select-Object -First 1).LineNumber; $e=($c | Select-String -Pattern '^# <<< config\.md seed end' | Select-Object -First 1).LineNumber; if (-not $s -or -not $e -or $e -le $s) { exit 1 }; [System.IO.File]::WriteAllLines('.work\config.md', $c[$s..($e-2)], (New-Object System.Text.UTF8Encoding($false)))"
if errorlevel 1 (
  echo Failed to create .work\config.md ^(seed markers not found in config.example.md?^).
) else (
  echo Created .work\config.md from config.example.md - edit it for this project.
)
goto :eof

:seed_constraints
set "CC_CONSTRAINTS_TEMPLATE=%~dp0..\constraints.example.md"
if not exist "%CC_CONSTRAINTS_TEMPLATE%" set "CC_CONSTRAINTS_TEMPLATE=%~dp0constraints.example.md"
if not exist "%CC_CONSTRAINTS_TEMPLATE%" (
  echo Failed to create .work\constraints.md ^(constraints.example.md missing next to launchers?^).
  goto :eof
)
%CC_PS_EXE% -NoProfile -Command "$ErrorActionPreference='Stop'; $t=[System.IO.File]::ReadAllText('%CC_CONSTRAINTS_TEMPLATE%', [System.Text.Encoding]::UTF8); [System.IO.File]::WriteAllText('.work\constraints.md', $t, (New-Object System.Text.UTF8Encoding($false)))"
if errorlevel 1 (
  echo Failed to create .work\constraints.md.
) else (
  echo Created .work\constraints.md from constraints.example.md - edit it for this project.
)
goto :eof
