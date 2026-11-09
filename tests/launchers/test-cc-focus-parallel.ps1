# ci:posix - hermetic focus protocol and Git fixtures, no provider account needed.
. (Join-Path $PSScriptRoot 'focus-suites.ps1')
Invoke-FocusSuites @(
    @('tests/test_focus_parallel.py', 'Focus parallel member tests'),
    @('tests/test_focus_context_budget.py', 'Focus context budget tests')
)
