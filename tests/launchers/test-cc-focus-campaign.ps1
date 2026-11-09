# ci:posix - hermetic focus protocol and Git fixtures, no provider account needed.
. (Join-Path $PSScriptRoot 'focus-suites.ps1')
Invoke-FocusSuites @(
    @('tests/test_focus_finish_stage.py', 'Focus stage pause tests'),
    @('tests/test_focus_campaign.py', 'Focus review campaign tests'),
    @('tests/test_focus_diagnostics.py', 'Focus diagnostic tests'),
    @('tests/test_focus_refusals.py', 'Focus refusal history tests')
)
