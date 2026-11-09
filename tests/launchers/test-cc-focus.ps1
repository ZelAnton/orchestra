# ci:posix - hermetic focus protocol and Git fixtures, no provider account needed.
# The other focus modules run in the test-cc-focus-*.ps1 groups; see focus-suites.ps1.
. (Join-Path $PSScriptRoot 'focus-suites.ps1')
Invoke-FocusSuites @(
    @('tests/test_focus_instructions.py', 'Focus instruction style tests'),
    @('tests/test_cycle.py', 'Cycle regression tests')
)
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
& (Join-Path $repo 'tools/focus-runtime.ps1') --help
if ($LASTEXITCODE -ne 0) { throw 'Cycle PowerShell help smoke failed.' }
