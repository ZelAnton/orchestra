# ci:posix - hermetic focus protocol and Git fixtures, no provider account needed.
. (Join-Path $PSScriptRoot 'focus-suites.ps1')
Invoke-FocusSuites @(
    @('tests/test_focus_report_accounting.py', 'Focus report accounting tests'),
    @('tests/test_focus_pairs.py', 'Focus paired review tests'),
    @('tests/test_focus_snapshot_archive.py', 'Focus snapshot archive tests'),
    @('tests/test_focus_pair_execution.py', 'Focus pair executor closure tests'),
    @('tests/test_focus_executor_accounting.py', 'Focus executor accounting tests')
)
