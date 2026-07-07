@echo off
chcp 65001 >nul
rem Sync agent definitions from this folder (%~dp0..) into the mirror
rem %USERPROFILE%\.claude\agents\, which is where "claude --agent" actually loads them.
rem Without this step, edits to the .md files here do NOT take effect at runtime.
rem
rem Copies top-level *.md only (no recursion, so launchers\ is skipped) and does NOT
rem purge (other agents already in the mirror are preserved). Excluded:
rem   coder.template.md      - "name: {{NAME}}" frontmatter would register a broken agent
rem   config.example.md      - documentation, not an agent
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
