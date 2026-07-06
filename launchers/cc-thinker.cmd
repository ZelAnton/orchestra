@echo off
chcp 65001 >nul
rem Launch the "thinker" analytical partner in the current folder (Claude Code, auto mode).
rem No fixed task: describe problems/ideas/goals in the chat and think together; thinker
rem analyzes the project with you and turns agreed work into tasks in .work\Tasks_Queue.md.
rem Optional: pass an opening topic as an argument.
if "%~1"=="" (
  claude --agent thinker --permission-mode auto "Per your system prompt: act as the analytical thinking partner for this project. Greet me briefly, then ask what I want to explore or build. Analyze it with me and, once we agree on concrete work, enqueue it into .work/Tasks_Queue.md per your instructions."
) else (
  claude --agent thinker --permission-mode auto "Per your system prompt: act as the analytical thinking partner for this project. Opening topic: %*"
)
