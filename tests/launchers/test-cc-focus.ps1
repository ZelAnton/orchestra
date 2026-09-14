# ci:posix - hermetic focus protocol and Git fixtures, no provider account needed.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$python = Get-Command python3, python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $python) { throw 'Python 3.10+ is required for cc-focus regression tests.' }
$env:PYTHONDONTWRITEBYTECODE = '1'
& $python.Source (Join-Path $repo 'tests/test_cycle.py')
if ($LASTEXITCODE -ne 0) { throw "Cycle regression tests failed: $LASTEXITCODE" }
& $python.Source (Join-Path $repo 'tests/test_focus_terminal.py')
if ($LASTEXITCODE -ne 0) { throw "Focus terminal regression tests failed: $LASTEXITCODE" }
& $python.Source (Join-Path $repo 'tests/test_focus_status.py')
if ($LASTEXITCODE -ne 0) { throw "Focus status regression tests failed: $LASTEXITCODE" }
& $python.Source (Join-Path $repo 'tests/test_focus_project.py')
if ($LASTEXITCODE -ne 0) { throw "Focus project regression tests failed: $LASTEXITCODE" }
& (Join-Path $repo 'tools/focus-runtime.ps1') --help
if ($LASTEXITCODE -ne 0) { throw 'Cycle PowerShell help smoke failed.' }
