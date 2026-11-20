# ci:posix - hermetic focus protocol and Git fixtures, no provider account needed.
# The accounting modules have their own group, because on Windows they alone need about half of the file limit of run-all.ps1.
. (Join-Path $PSScriptRoot 'focus-suites.ps1')
Invoke-FocusSuites @(
    @('tests/test_focus_report_accounting.py', 'Focus report accounting tests'),
    @('tests/test_focus_executor_accounting.py', 'Focus executor accounting tests')
)
