@echo off
chcp 65001 >nul
rem Seed .work\config.md from the copyable block in config.example.md (the lines
rem between the "# >>> config.md seed start" / "# <<< config.md seed end" markers
rem inside its fenced code block) if no config exists yet - NOT the whole document
rem (headings/prose/tables are never copied). An existing .work\config.md is NEVER
rem overwritten.
if exist ".work\config.md" (
  echo .work\config.md already exists - leaving it unchanged.
  goto :eof
)
if not exist ".work" mkdir ".work"
rem Look for the template next to launchers\ first (repo checkout layout: this file
rem lives in launchers\, config.example.md one level up at the repo root), then fall
rem back to alongside this script (mirror layout in %USERPROFILE%\.claude\scripts,
rem where cc-sync.cmd also mirrors config.example.md flat next to the *.cmd files).
set "CC_CONFIG_TEMPLATE=%~dp0..\config.example.md"
if not exist "%CC_CONFIG_TEMPLATE%" set "CC_CONFIG_TEMPLATE=%~dp0config.example.md"
if not exist "%CC_CONFIG_TEMPLATE%" (
  echo Failed to create .work\config.md ^(config.example.md missing next to launchers?^).
  goto :eof
)
rem Prefer pwsh (defaults to UTF-8) but fall back to Windows PowerShell 5.1, which
rem needs an explicit UTF-8 encoding on both read and write: without it, a BOM-less
rem UTF-8 template with Cyrillic comments (e.g. the rolling-cohort notes in the seed
rem block) gets misread as ANSI and Set-Content re-encodes it as mojibake (same class
rem of bug as T-029). Reading via [System.IO.File]::ReadAllLines(...) with an explicit
rem UTF8 encoding and writing via [System.IO.File]::WriteAllLines(...) with a BOM-less
rem UTF8Encoding($false) - matching generate-coders.ps1's WriteAllText pattern - keeps
rem the output byte-identical and BOM-less regardless of which PowerShell runs this.
set "CC_PS_EXE=powershell"
where pwsh >nul 2>nul
if not errorlevel 1 set "CC_PS_EXE=pwsh"
%CC_PS_EXE% -NoProfile -Command "$ErrorActionPreference='Stop'; $c=[System.IO.File]::ReadAllLines('%CC_CONFIG_TEMPLATE%', [System.Text.Encoding]::UTF8); $s=($c | Select-String -Pattern '^# >>> config\.md seed start' | Select-Object -First 1).LineNumber; $e=($c | Select-String -Pattern '^# <<< config\.md seed end' | Select-Object -First 1).LineNumber; if (-not $s -or -not $e -or $e -le $s) { exit 1 }; [System.IO.File]::WriteAllLines('.work\config.md', $c[$s..($e-2)], (New-Object System.Text.UTF8Encoding($false)))"
if errorlevel 1 (
  echo Failed to create .work\config.md ^(seed markers not found in config.example.md?^).
) else (
  echo Created .work\config.md from config.example.md - edit it for this project.
)
