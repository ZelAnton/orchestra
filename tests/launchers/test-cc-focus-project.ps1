# ci:posix - hermetic focus protocol and Git fixtures, no provider account needed.
. (Join-Path $PSScriptRoot 'focus-suites.ps1')
Invoke-FocusSuites @(
    @('tests/test_focus_project.py', 'Focus project regression tests'),
    @('tests/test_focus_publication_recovery.py', 'Focus publication recovery tests'),
    @('tests/test_focus_publication_scope.py', 'Focus publication scope tests'),
    @('tests/test_focus_brief.py', 'Focus project brief tests')
)
