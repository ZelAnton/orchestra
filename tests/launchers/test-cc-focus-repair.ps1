# ci:posix - hermetic focus protocol and Git fixtures, no provider account needed.
. (Join-Path $PSScriptRoot 'focus-suites.ps1')
Invoke-FocusSuites @(
    @('tests/test_focus_repair.py', 'Focus repair gate tests'),
    @('tests/test_focus_repair_evidence.py', 'Focus repair evidence tests'),
    @('tests/test_focus_review.py', 'Focus final review tests'),
    @('tests/test_focus_terminal.py', 'Focus terminal regression tests'),
    @('tests/test_focus_status.py', 'Focus status regression tests')
)
