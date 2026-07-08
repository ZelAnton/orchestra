@echo off
chcp 65001 >nul
rem Launch the "thinker" analytical partner in the current folder (Claude Code, auto mode).
rem No fixed task: describe problems/ideas/goals in the chat and think together; thinker
rem analyzes the project with you and turns agreed work into tasks in .work\Tasks_Queue.md.
rem Optional: pass an opening topic as an argument.
rem
rem The argument is made robust against quotes/%% the same way as in cc-queue.cmd:
rem   1) %* is captured into ARGS BEFORE setlocal EnableDelayedExpansion — otherwise
rem      literal "!" characters in the argument would be eaten by delayed expansion
rem      already at capture time;
rem   2) the argument is substituted into the claude prompt via !ARGS! (delayed
rem      expansion), not a second direct use of %* on this line;
rem   3) double quotes inside ARGS are replaced with single quotes (shared step,
rem      cc-common.cmd:sanitize, the same one cc-queue.cmd uses) — otherwise a
rem      quote in the argument would break out of the prompt's quoting and claude
rem      would receive several unrelated positional arguments instead of one prompt.
rem Known limitation of cmd.exe that cannot be fixed from inside a .cmd file: if the
rem argument contains "%NAME%" matching an actually defined environment variable
rem (e.g. "%PATH%"), cmd substitutes its value — this happens while binding %* to
rem the batch file, before the first line of script code runs.
setlocal
set "ARGS=%*"
setlocal EnableDelayedExpansion
call "%~dp0cc-common.cmd" sanitize
if "%~1"=="" (
  rem Без предопределённого промпта: агент запускается и ждёт указания задачи в чате.
  claude --agent thinker --permission-mode auto
) else (
  claude --agent thinker --permission-mode auto "Per your system prompt: act as the analytical thinking partner for this project. Opening topic: !ARGS!"
)
