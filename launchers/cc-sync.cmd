@echo off
rem Detect whether this script is running from an actual repo checkout or from its
rem own mirror at %USERPROFILE%\.claude\scripts (where cc-sync.cmd copies itself so
rem launchers can be invoked from PATH; see the robocopy step further down). Only
rem launchers\*.cmd get mirrored there - the repo-root generator and the agents\
rem templates do NOT exist in the mirror layout. Every step below that only makes
rem sense against a checkout (regenerating agents, and the three robocopy blocks
rem that mirror repo content out to ~/.claude) is gated on this one flag instead of
rem each step silently degrading on its own when run from the mirror: without the
rem gate, "%~dp0.." from the mirror resolves to ~/.claude itself, so those robocopy
rem calls either copy the mirror onto itself (self-copy no-op) or look for a source
rem file that plainly is not there - and still print "Synced ... -^>..." as if real
rem work had happened.
set "IS_REPO_CHECKOUT="
if exist "%~dp0..\generate-coders.cmd" set "IS_REPO_CHECKOUT=1"
if exist "%~dp0..\agents\coder.template.md" set "IS_REPO_CHECKOUT=1"

rem If this copy of cc-sync.cmd lives in the actual repo checkout - generate-coders.cmd
rem sits one level up in the repo root and resolves the templates under agents\
rem (agents\coder.template.md/agents\reviewer.template.md) - regenerate the
rem agents\coder.md/coder_fast.md/coder_deep.md and agents\reviewer.md/reviewer_std.md
rem variants before mirroring, so sync always ships what the templates currently say
rem instead of a possibly stale on-disk copy. generate-coders.cmd always overwrites those
rem files, so this also self-heals drift: a manual edit to one variant, or a template edit
rem without a manual regen run.
rem This is skipped when running from the ~/.claude/scripts mirror instead - only
rem launchers\*.cmd get mirrored there, not the repo-root generator or the templates -
rem in that case there is no source template to regenerate from anyway.
rem NOTE: comments inside the parenthesized blocks below must avoid unescaped
rem parentheses - cmd treats a stray ) inside rem text as closing the block early.
rem NOTE: this whole step runs before "chcp 65001" further down - generate-coders.cmd
rem has its own Cyrillic rem comments, and calling it while codepage 65001 is already
rem active corrupts cmd's line parsing (garbled bytes get executed as bogus
rem commands); running it under the default codepage first avoids that entirely.
if defined IS_REPO_CHECKOUT (
  if exist "%~dp0..\generate-coders.cmd" (
    call "%~dp0..\generate-coders.cmd"
    rem Abort before the robocopy mirroring below if regeneration itself failed - do not
    rem mirror possibly stale or partially written coder*.md files. This is distinct from
    rem the informational drift check right below: that one covers a successful
    rem regeneration whose output differs from what is committed - T-011, intentionally
    rem non-fatal - this one covers the regeneration command itself failing to run.
    rem NOTE: uses "if errorlevel N", not "if %ERRORLEVEL%==N" - inside a parenthesized
    rem block cmd pre-expands %ERRORLEVEL% once at parse time, so that form would always
    rem see a stale value here; "if errorlevel N" is a live check (same reasoning as the
    rem existing "if errorlevel 1" checks elsewhere in this file).
    if errorlevel 1 (
      echo Error: generate-coders.cmd failed. Aborting sync before mirroring agents.
      exit /b 1
    )
    rem Detect whether that regeneration actually changed anything, i.e. whether the
    rem committed coder*.md files were stale or drifted before this run. This check
    rem is informational only: the files on disk are already correct after the call
    rem above, so we deliberately keep going into the robocopy mirror below instead
    rem of aborting the sync - the drift is fixed, it just was not committed yet.
    if exist "%~dp0..\.git" (
      git -C "%~dp0.." diff --exit-code -- agents/coder.md agents/coder_fast.md agents/coder_deep.md agents/reviewer.md agents/reviewer_std.md >nul 2>nul
      if errorlevel 1 (
        echo Warning: generated agent files differed from their templates and were
        echo regenerated. Commit the changes to coder*.md / reviewer*.md.
      )
    )
  )
) else (
  echo Skipping agent regeneration - not running from a repository checkout ^(mirror detected^); run cc-sync from the repo checkout instead.
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

rem The three robocopy steps below all mirror content out of the repo checkout into
rem %USERPROFILE%\.claude\, so they only make sense when this script is actually
rem running from a checkout - IS_REPO_CHECKOUT, detected at the top of this file.
rem Run from the ~/.claude\scripts mirror instead, "%~dp0.." resolves to ~/.claude
rem itself: the agents and launchers robocopy calls would copy the mirror onto
rem itself - source == destination, a self-copy no-op - and the config.example.md
rem call would look for a source file that is not there - all three would still
rem exit 0-7 and print "Synced ... -^>..." as if real work had happened, which is
rem exactly the silent-no-op-reported-as-success bug this gate exists to prevent.
rem
rem Sync agent definitions from the agents\ folder - %~dp0..\agents - into the mirror
rem %USERPROFILE%\.claude\agents\, which is where "claude --agent" actually loads them.
rem Without this step, edits to the .md files there do NOT take effect at runtime.
rem
rem Copies top-level *.md from agents\ only - no recursion - and does NOT purge - other
rem agents already in the mirror are preserved. Repository documentation - AGENTS.md,
rem knowledge.md, README.md, config.example.md, plans\ - lives in the repo root, NOT in
rem agents\, so the old growing documentation-exclusion list is gone. The only remaining
rem exclusions are the two generator templates, which sit in agents\ next to the real
rem agents but are not themselves loadable agents:
rem   coder.template.md      - "name: {{NAME}}" frontmatter would register a broken agent
rem   reviewer.template.md   - same: placeholder "name: {{NAME}}" frontmatter, not an agent
rem
rem Also mirrors the launchers themselves - this folder's *.cmd - into
rem %USERPROFILE%\.claude\scripts, which is where they're invoked from on PATH.
rem
rem Also mirrors config.example.md next to the launchers in scripts\, so that
rem cc-config.cmd - run from the mirror, off PATH - can find its template via %~dp0.
rem
rem NOTE: unlike the generate-coders block above, none of the rem lines above this
rem point are inside the parenthesized block below - the earlier NOTE about stray
rem parentheses closing a block early only applies to comments INSIDE a block, so
rem the descriptive comments were deliberately kept above "if defined (" here and
rem parenthetical asides were rewritten with "-" instead of literal "(" ")".
if defined IS_REPO_CHECKOUT (
  robocopy "%~dp0..\agents" "%USERPROFILE%\.claude\agents" *.md /XF coder.template.md reviewer.template.md /NJH /NJS /NDL /NFL
  rem robocopy exit codes 0-7 mean success; 8+ is a real error.
  if errorlevel 8 (
    echo Sync failed: robocopy returned an error code.
  ) else (
    echo Synced agent definitions -^> "%USERPROFILE%\.claude\agents"
  )

  robocopy "%~dp0." "%USERPROFILE%\.claude\scripts" *.cmd /NJH /NJS /NDL /NFL
  if errorlevel 8 (
    echo Sync failed: robocopy returned an error code.
  ) else (
    echo Synced launcher scripts -^> "%USERPROFILE%\.claude\scripts"
  )

  robocopy "%~dp0.." "%USERPROFILE%\.claude\scripts" config.example.md /NJH /NJS /NDL /NFL
  if errorlevel 8 (
    echo Sync failed: robocopy returned an error code.
  ) else (
    echo Synced config.example.md -^> "%USERPROFILE%\.claude\scripts"
  )
) else (
  echo Skipping agent/launcher/config mirroring - not running from a repository checkout ^(mirror detected^); run cc-sync from the repo checkout instead.
)
