@echo off
rem Перегенерировать coder.md/coder_fast.md/coder_deep.md из coder.template.md.
rem Запускать из этой же папки после правки шаблона.
rem Предпочитаем pwsh (PowerShell 7); откат на powershell (5.1), если pwsh нет.
rem Генератор пишет UTF-8 без BOM явно ([IO.File]::WriteAllText) в обоих случаях.
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0generate-coders.ps1"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0generate-coders.ps1"
)
