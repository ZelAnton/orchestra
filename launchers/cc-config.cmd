@echo off
chcp 65001 >nul
rem Seed .work\config.md and .work\constraints.md from the repo templates if they do not
rem exist yet, and seed the Claude Code allow-rules for autonomous Codex (the runtime
rem wrapper the adapters actually run, in both its layout forms -
rem `pwsh -File tools/codex-runtime.ps1` from a repo checkout or
rem `pwsh -File ~/.claude/scripts/codex-runtime.ps1` from a cc-sync mirror - plus the
rem historical `codex exec` anchor) into .claude\settings.local.json. An existing target
rem file is NEVER overwritten wholesale (same guarantee for all three). Finally, register
rem the canonical project root in the user-global Orchestra registry and create
rem .inbox\messages for cross-project communication.
rem  - config.md: only the copyable block between the "# >>> config.md seed start" /
rem    "# <<< config.md seed end" markers inside config.example.md's fenced code block
rem    (headings/prose/tables are never copied).
rem  - constraints.md: the WHOLE constraints.example.md (the entire document IS the policy
rem    content - there is no seed block to slice, unlike config.md).
rem  - .claude\settings.local.json: ensures the canonical Codex allow-list
rem    (permissions.allow) is present. If the file does not exist it is created with the
rem    list. If it exists but is missing a canonical rule, that rule is MERGED into the
rem    existing permissions.allow array (task T-078): only the missing canonical rule is
rem    ADDED - every other key, existing allow entry, deny-list, hook, etc. is preserved,
rem    and an already-present rule (idempotency substring pre-check) leaves the file byte-
rem    for-byte untouched. The merge is add-only: it never rewrites or drops existing
rem    content, and it writes atomically (temp file + File.Replace) so a mid-write failure
rem    cannot corrupt the operator's file. T-058 had removed the prior auto-merge fearing
rem    it would silently widen an operator-owned permissions file; T-078 restores it
rem    narrowly (add-only, operator-run) - running this launcher IS the operator granting
rem    the permission, the same consent that already justifies creating the file from
rem    scratch. Degenerate cases (invalid JSON, unexpected shape, file not writable) fall
rem    back to printing the exact rule to add by hand - never a silent no-op. This is the
rem    ONLY sanctioned point where the rule is written - the orchestrator and its subagents
rem    never write it.
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

call :register_project
set "CC_CONFIG_RC=%errorlevel%"
endlocal & exit /b %CC_CONFIG_RC%

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
rem Canonical Codex allow-list (single source of truth; keep byte-identical to
rem launchers\cc-config.sh's $CODEX_ALLOW_RULES and to the hint text printed by
rem launchers\cc-doctor.cmd/.sh; documented in config.example.md under
rem "Codex-агенты" / "Разрешение на запуск codex"). THREE rules (task F-05, extended by
rem T-114):
rem Bash(pwsh -File tools/codex-runtime.ps1 *) - the command Bash ACTUALLY runs since
rem T-075 when the adapters run from a repo checkout (the adapters drive codex through
rem the runtime wrapper; the child `codex exec` is spawned by the runtime past the Bash
rem permission gate, so THIS rule is the one that authorizes the real call, and it covers
rem every runtime subcommand and every CODEX_CMD);
rem Bash(pwsh -File ~/.claude/scripts/codex-runtime.ps1 *) - the same command in its OTHER
rem literal form (task T-114): when the adapters run in a target project that only has the
rem cc-sync mirror (no tools/ checkout of its own), they resolve the runtime to its mirrored
rem copy at ~/.claude/scripts/codex-runtime.ps1 instead. The tilde is kept literal (never
rem expanded by the adapters before the Bash call), so this stays a fixed, machine-independent
rem string both forms need their own allow-rule for;
rem plus Bash(codex exec *) as the historical anchor (harmless, does not itself authorize
rem the runtime command).
rem If .claude\settings.local.json does not exist yet, create it with this list. If it
rem already exists but is missing a canonical rule, MERGE that rule into the existing
rem permissions.allow array (task T-078 restored this narrowly - add-only - after T-058
rem removed the prior auto-merge): parse the JSON, add only the missing rule(s), and write
rem the result back atomically (temp file + [System.IO.File]::Replace) so every other key,
rem existing allow entry, deny-list and hook is preserved and a mid-write failure cannot
rem corrupt the file. The idempotency pre-check is a substring search over the raw text
rem (same check as before): if the rule is already present the file is left byte-for-byte
rem unchanged. Degenerate cases - the file is not valid JSON, permissions/allow is not the
rem expected shape, or the file is not writable - fall back to printing the exact rule to
rem add by hand (never a silent no-op). BOM-less UTF-8 output, matching the other seed
rem routines. Only the operator (by running this launcher) ever writes this rule; the
rem orchestrator/subagents never do.
%CC_PS_EXE% -NoProfile -Command "$ErrorActionPreference='Stop'; $p='.claude\settings.local.json'; $rules=@('Bash(pwsh -File tools/codex-runtime.ps1 *)','Bash(pwsh -File ~/.claude/scripts/codex-runtime.ps1 *)','Bash(codex exec *)'); $enc=New-Object System.Text.UTF8Encoding($false); if (Test-Path $p) { $raw=[System.IO.File]::ReadAllText($p,[System.Text.Encoding]::UTF8); $missing=@($rules | Where-Object { -not $raw.Contains($_) }); function Report($m){ Write-Host $m; foreach ($x in $missing) { Write-Host ('  - '+$x) }; exit 0 }; if ($missing.Count -eq 0) { Write-Host 'OK   .claude\settings.local.json already grants autonomous codex - left unchanged.'; exit 0 }; try { $j=$raw | ConvertFrom-Json } catch { $j=$null }; if ($null -eq $j) { Report '.claude\settings.local.json exists but is not valid JSON - cannot merge automatically; add the allow-rule(s) by hand to permissions.allow:' }; $pp=$j.PSObject.Properties['permissions']; if ($pp -and $null -ne $pp.Value -and -not ($pp.Value -is [PSCustomObject])) { Report '.claude\settings.local.json exists but its permissions is not a JSON object - cannot merge automatically; add the allow-rule(s) by hand to permissions.allow:' }; if (-not $pp -or $null -eq $pp.Value) { if ($pp) { $j.permissions=[PSCustomObject]@{} } else { $j | Add-Member -NotePropertyName permissions -NotePropertyValue ([PSCustomObject]@{}) } }; $perm=$j.permissions; $ap=$perm.PSObject.Properties['allow']; if ($ap -and $null -ne $ap.Value -and -not ($ap.Value -is [System.Array])) { Report '.claude\settings.local.json exists but its permissions.allow is not a JSON array - cannot merge automatically; add the allow-rule(s) by hand to permissions.allow:' }; if (-not $ap -or $null -eq $ap.Value) { if ($ap) { $perm.allow=@() } else { $perm | Add-Member -NotePropertyName allow -NotePropertyValue @() } }; $perm.allow=@($perm.allow)+$missing; $json=$j | ConvertTo-Json -Depth 20; $tmp=$p+'.tmp'; try { [System.IO.File]::WriteAllText($tmp,$json,$enc); [System.IO.File]::Replace($tmp,$p,[NullString]::Value) } catch { if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }; Report '.claude\settings.local.json could not be written (read-only or locked?) - cannot merge automatically; add the allow-rule(s) by hand to permissions.allow:' }; Write-Host ('Merged allow-rule(s) into .claude\settings.local.json permissions.allow: '+($missing -join ', ')+' (lets coder_codex/reviewer_codex run codex autonomously via the runtime wrapper).'); exit 0 }; if (-not (Test-Path '.claude')) { New-Item -ItemType Directory -Path '.claude' -Force | Out-Null }; $o=[PSCustomObject]@{ permissions = [PSCustomObject]@{ allow = @($rules) } }; $json=$o | ConvertTo-Json -Depth 20; [System.IO.File]::WriteAllText($p, $json, $enc); Write-Host ('Created .claude\settings.local.json with allow-rule(s): '+($rules -join ', ')+' (lets coder_codex/reviewer_codex run codex autonomously via the runtime wrapper).')"
goto :eof

:register_project
rem Register this repository in the user-global Orchestra registry and initialize its
rem cross-project inbox. Resolve the runtime from the source checkout first, then from
rem the flat cc-sync mirror. Registration is a required cc-config outcome: unlike the
rem older best-effort template diagnostics, a missing/broken registry runtime returns a
rem non-zero exit so the operator cannot believe the project is addressable when it is not.
set "CC_PROJECT_REGISTRY=%~dp0..\tools\project-registry.ps1"
if not exist "%CC_PROJECT_REGISTRY%" set "CC_PROJECT_REGISTRY=%~dp0project-registry.ps1"
if not exist "%CC_PROJECT_REGISTRY%" (
  echo Failed to register project ^(project-registry.ps1 not found next to the launcher or in the cc-sync mirror - run cc-sync^).
  exit /b 2
)
%CC_PS_EXE% -NoProfile -File "%CC_PROJECT_REGISTRY%" register --root "%CD%" --ensure-inbox
set "CC_REGISTER_RC=%errorlevel%"
if not "%CC_REGISTER_RC%"=="0" echo Failed to register project or initialize .inbox ^(project-registry exit %CC_REGISTER_RC%^).
exit /b %CC_REGISTER_RC%
