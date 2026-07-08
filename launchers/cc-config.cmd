@echo off
chcp 65001 >nul
rem Seed .work\config.md and .work\constraints.md from the repo templates if they do not
rem exist yet, and seed a Claude Code allow-rule for autonomous `codex exec` into
rem .claude\settings.local.json. An existing target file is NEVER overwritten wholesale
rem (same guarantee for all three).
rem  - config.md: only the copyable block between the "# >>> config.md seed start" /
rem    "# <<< config.md seed end" markers inside config.example.md's fenced code block
rem    (headings/prose/tables are never copied).
rem  - constraints.md: the WHOLE constraints.example.md (the entire document IS the policy
rem    content - there is no seed block to slice, unlike config.md).
rem  - .claude\settings.local.json: merges (never replaces) an allow-rule
rem    "Bash(codex exec *)" into permissions.allow so coder_codex/reviewer_codex are not
rem    blocked by Claude Code's auto-mode permission classifier. Idempotent (no duplicate
rem    on re-run). This is the ONLY sanctioned point where the rule is written - the
rem    orchestrator and its subagents never write it; seeding it here means the operator
rem    running this launcher is the one granting the permission.
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

call :seed_codex_permission

endlocal
goto :eof

:seed_config
set "CC_CONFIG_TEMPLATE=%~dp0..\config.example.md"
if not exist "%CC_CONFIG_TEMPLATE%" set "CC_CONFIG_TEMPLATE=%~dp0config.example.md"
rem Distinguish three causes so the diagnostic is never misleading (task T-056):
rem  (a) the template is truly absent;
rem  (b) the template PATH exists but is a directory, not a file - cmd.exe "exist" does not
rem      tell files from directories, so without this check the code would fall through to
rem      the PowerShell call, which throws deep inside [System.IO.File]::ReadAllLines and
rem      leaks a raw .NET stack trace, and then wrongly blames missing seed markers;
rem  (c) the template is a real file - defer to PowerShell, which distinguishes markers-not
rem      -found from a read/write error via distinct exit codes below.
if not exist "%CC_CONFIG_TEMPLATE%" (
  echo Failed to create .work\config.md ^(config.example.md not found next to launchers or in the mirror - run cc-sync, or check your checkout^).
  goto :eof
)
if exist "%CC_CONFIG_TEMPLATE%\" (
  echo Failed to create .work\config.md ^(config.example.md exists but is a directory, not a file - the ~/.claude/scripts mirror is corrupted; run cc-sync from the repo checkout to repair it^).
  goto :eof
)
rem Wrap the PowerShell body in try/catch so a .NET exception - unreadable file, locked
rem .work, etc. - never leaks its ParentContainsErrorRecordException trace to stderr on top
rem of this script's own diagnostic. Exit codes: 0 created; 2 seed markers not found; 3 an
rem exception was caught; any other non-zero is an unexpected PowerShell failure. Residual
rem stderr is discarded ^(2^>nul^) so only the cmd-side message below is ever shown.
%CC_PS_EXE% -NoProfile -Command "try { $ErrorActionPreference='Stop'; $c=[System.IO.File]::ReadAllLines('%CC_CONFIG_TEMPLATE%', [System.Text.Encoding]::UTF8); $s=($c | Select-String -Pattern '^# >>> config\.md seed start' | Select-Object -First 1).LineNumber; $e=($c | Select-String -Pattern '^# <<< config\.md seed end' | Select-Object -First 1).LineNumber; if (-not $s -or -not $e -or $e -le $s) { exit 2 }; [System.IO.File]::WriteAllLines('.work\config.md', $c[$s..($e-2)], (New-Object System.Text.UTF8Encoding($false))); exit 0 } catch { exit 3 }" 2>nul
if errorlevel 3 (
  echo Failed to create .work\config.md ^(reading config.example.md or writing .work\config.md raised an error - is the template unreadable or .work not writable?^).
) else if errorlevel 2 (
  echo Failed to create .work\config.md ^(config.example.md is a file but has no "config.md seed start/end" block to copy^).
) else if errorlevel 1 (
  echo Failed to create .work\config.md ^(unexpected PowerShell error^).
) else (
  echo Created .work\config.md from config.example.md - edit it for this project.
)
goto :eof

:seed_constraints
set "CC_CONSTRAINTS_TEMPLATE=%~dp0..\constraints.example.md"
if not exist "%CC_CONSTRAINTS_TEMPLATE%" set "CC_CONSTRAINTS_TEMPLATE=%~dp0constraints.example.md"
rem Same three-cause distinction as :seed_config (task T-056): (a) template absent;
rem (b) template PATH is a directory, not a file; (c) template is a real file - defer to
rem PowerShell. constraints.md copies the WHOLE file, so there is no seed-marker case - the
rem PowerShell body returns 0 on success or 3 on a caught exception.
if not exist "%CC_CONSTRAINTS_TEMPLATE%" (
  echo Failed to create .work\constraints.md ^(constraints.example.md not found next to launchers or in the mirror - run cc-sync, or check your checkout^).
  goto :eof
)
if exist "%CC_CONSTRAINTS_TEMPLATE%\" (
  echo Failed to create .work\constraints.md ^(constraints.example.md exists but is a directory, not a file - the ~/.claude/scripts mirror is corrupted; run cc-sync from the repo checkout to repair it^).
  goto :eof
)
%CC_PS_EXE% -NoProfile -Command "try { $ErrorActionPreference='Stop'; $t=[System.IO.File]::ReadAllText('%CC_CONSTRAINTS_TEMPLATE%', [System.Text.Encoding]::UTF8); [System.IO.File]::WriteAllText('.work\constraints.md', $t, (New-Object System.Text.UTF8Encoding($false))); exit 0 } catch { exit 3 }" 2>nul
if errorlevel 3 (
  echo Failed to create .work\constraints.md ^(reading constraints.example.md or writing .work\constraints.md raised an error - is the template unreadable or .work not writable?^).
) else if errorlevel 1 (
  echo Failed to create .work\constraints.md ^(unexpected PowerShell error^).
) else (
  echo Created .work\constraints.md from constraints.example.md - edit it for this project.
)
goto :eof

:seed_codex_permission
rem Merge (never wholesale-overwrite) an allow-rule for autonomous `codex exec` into
rem .claude\settings.local.json. Idempotent: if any allow entry already matches
rem "codex exec", the file is left unchanged. If the file exists but is not valid JSON,
rem it is left untouched and the operator is told to add the rule by hand. BOM-less UTF-8
rem output, matching the other seed routines. Only the operator (by running this
rem launcher) ever writes this rule; the orchestrator/subagents never do.
%CC_PS_EXE% -NoProfile -Command "$ErrorActionPreference='Stop'; $p='.claude\settings.local.json'; $rule='Bash(codex exec *)'; if (-not (Test-Path '.claude')) { New-Item -ItemType Directory -Path '.claude' -Force | Out-Null }; if (Test-Path $p) { $raw=[System.IO.File]::ReadAllText($p,[System.Text.Encoding]::UTF8); try { $o=$raw | ConvertFrom-Json } catch { Write-Host 'SKIP .claude\settings.local.json is not valid JSON - add this allow-rule by hand: Bash(codex exec *)'; exit 0 }; if ($null -eq $o) { $o=[PSCustomObject]@{} } } else { $o=[PSCustomObject]@{} }; if (-not $o.PSObject.Properties['permissions']) { $o | Add-Member -NotePropertyName permissions -NotePropertyValue ([PSCustomObject]@{}) }; if (-not $o.permissions.PSObject.Properties['allow']) { $o.permissions | Add-Member -NotePropertyName allow -NotePropertyValue @() }; $a=@($o.permissions.allow); foreach ($e in $a) { if (($e -is [string]) -and ($e -match 'codex\s+exec')) { Write-Host 'OK   .claude\settings.local.json already allows codex exec - unchanged.'; exit 0 } }; $a=@($a) + $rule; $o.permissions.allow=$a; $json=$o | ConvertTo-Json -Depth 20; [System.IO.File]::WriteAllText($p, $json, (New-Object System.Text.UTF8Encoding($false))); Write-Host 'Added allow-rule Bash(codex exec *) to .claude\settings.local.json (lets coder_codex/reviewer_codex run codex exec autonomously).'"
goto :eof
