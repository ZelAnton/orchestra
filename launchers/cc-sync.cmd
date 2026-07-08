@echo off
rem If this copy of cc-sync.cmd lives in the actual repo checkout - generate-coders.cmd
rem sits two levels up next to coder.template.md - regenerate coder.md, coder_fast.md
rem and coder_deep.md before mirroring, so sync always ships what the template
rem currently says instead of a possibly stale on-disk copy. generate-coders.cmd
rem always overwrites the three files, so this also self-heals drift: a manual edit
rem to one variant, or a template edit without a manual regen run.
rem This is skipped when running from the ~/.claude/scripts mirror instead - only
rem launchers\*.cmd get mirrored there, not the repo-root generator or template -
rem in that case there is no source template to regenerate from anyway.
rem NOTE: comments inside the parenthesized blocks below must avoid unescaped
rem parentheses - cmd treats a stray ) inside rem text as closing the block early.
rem NOTE: this whole step runs before "chcp 65001" further down - generate-coders.cmd
rem has its own Cyrillic rem comments, and calling it while codepage 65001 is already
rem active corrupts cmd's line parsing (garbled bytes get executed as bogus
rem commands); running it under the default codepage first avoids that entirely.
if exist "%~dp0..\generate-coders.cmd" (
  call "%~dp0..\generate-coders.cmd"
  rem Detect whether that regeneration actually changed anything, i.e. whether the
  rem committed coder*.md files were stale or drifted before this run. This check
  rem is informational only: the files on disk are already correct after the call
  rem above, so we deliberately keep going into the robocopy mirror below instead
  rem of aborting the sync - the drift is fixed, it just was not committed yet.
  if exist "%~dp0..\.git" (
    git -C "%~dp0.." diff --exit-code -- coder.md coder_fast.md coder_deep.md >nul 2>nul
    if errorlevel 1 (
      echo Warning: coder.md/coder_fast.md/coder_deep.md differed from coder.template.md
      echo and were regenerated. Commit the changes to those files.
    )
  )
)

chcp 65001 >nul

rem Validate agent .md invariants (frontmatter starts at byte 0, UTF-8 without BOM,
rem required name/description fields, name matches filename, snake_case) before
rem mirroring, so a broken agent file is flagged loudly instead of being silently
rem copied into the mirror where it would fail at load time. Skipped when running
rem from the ~/.claude/scripts mirror instead - only launchers\*.cmd get mirrored
rem there, so tools\validate-agents.ps1 has nothing to check against in that copy.
rem Non-fatal by design, matching the coder-drift warning above: a violation is
rem printed clearly but does not abort the sync.
rem NOTE: uses "if errorlevel N", not "if %ERRORLEVEL%==N" - inside a parenthesized
rem block cmd pre-expands %ERRORLEVEL% once at parse time (before "where pwsh" runs),
rem so that form would always see a stale value here; "if errorlevel N" is a live
rem check and works correctly at any nesting depth (same reasoning as the existing
rem "if errorlevel 1" checks elsewhere in this file).
if exist "%~dp0..\tools\validate-agents.ps1" (
  where pwsh >nul 2>nul
  if errorlevel 1 (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\validate-agents.ps1"
  ) else (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\validate-agents.ps1"
  )
  if errorlevel 1 (
    echo Warning: agent .md files violate invariants ^(see list above^). Fix before relying on the mirror.
  )
)

rem Sync agent definitions from this folder (%~dp0..) into the mirror
rem %USERPROFILE%\.claude\agents\, which is where "claude --agent" actually loads them.
rem Without this step, edits to the .md files here do NOT take effect at runtime.
rem
rem Copies top-level *.md only (no recursion, so launchers\ is skipped) and does NOT
rem purge (other agents already in the mirror are preserved). Excluded:
rem   coder.template.md      - "name: {{NAME}}" frontmatter would register a broken agent
rem   config.example.md      - not an agent; mirrored separately below, next to the
rem                            launchers in scripts\, so cc-config.cmd can find it there
rem   AGENTS.md/knowledge.md/*_PLAN.md/*_ROADMAP.md - repository docs, not agents
rem   Orchestra_Review_*.md  - dated review reports, not agents
robocopy "%~dp0.." "%USERPROFILE%\.claude\agents" *.md /XF coder.template.md config.example.md AGENTS.md knowledge.md "*_PLAN.md" "*_ROADMAP.md" "Orchestra_Review_*.md" /NJH /NJS /NDL /NFL
rem robocopy exit codes 0-7 mean success; 8+ is a real error.
if errorlevel 8 (
  echo Sync failed: robocopy returned an error code.
) else (
  echo Synced agent definitions -^> "%USERPROFILE%\.claude\agents"
)

rem Also mirror the launchers themselves (this folder's *.cmd) into
rem %USERPROFILE%\.claude\scripts, which is where they're invoked from on PATH.
robocopy "%~dp0." "%USERPROFILE%\.claude\scripts" *.cmd /NJH /NJS /NDL /NFL
if errorlevel 8 (
  echo Sync failed: robocopy returned an error code.
) else (
  echo Synced launcher scripts -^> "%USERPROFILE%\.claude\scripts"
)

rem Also mirror config.example.md next to the launchers in scripts\, so that
rem cc-config.cmd (run from the mirror, off PATH) can find its template via %~dp0.
robocopy "%~dp0.." "%USERPROFILE%\.claude\scripts" config.example.md /NJH /NJS /NDL /NFL
if errorlevel 8 (
  echo Sync failed: robocopy returned an error code.
) else (
  echo Synced config.example.md -^> "%USERPROFILE%\.claude\scripts"
)
