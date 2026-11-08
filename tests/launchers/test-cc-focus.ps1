# ci:posix - hermetic focus protocol and Git fixtures, no provider account needed.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$python = Get-Command python3, python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $python) { throw 'Python 3.10+ is required for cc-focus regression tests.' }
$env:PYTHONDONTWRITEBYTECODE = '1'
# Match focus-runtime.ps1 rather than the host's legacy Windows code page.
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
& $python.Source (Join-Path $repo 'tests/test_focus_instructions.py')
if ($LASTEXITCODE -ne 0) { throw "Focus instruction style tests failed: $LASTEXITCODE" }
& $python.Source (Join-Path $repo 'tests/test_cycle.py')
if ($LASTEXITCODE -ne 0) { throw "Cycle regression tests failed: $LASTEXITCODE" }
& $python.Source (Join-Path $repo 'tests/test_focus_finish_stage.py')
if ($LASTEXITCODE -ne 0) { throw "Focus stage pause tests failed: $LASTEXITCODE" }
& $python.Source (Join-Path $repo 'tests/test_focus_campaign.py')
if ($LASTEXITCODE -ne 0) { throw "Focus review campaign tests failed: $LASTEXITCODE" }
& $python.Source (Join-Path $repo 'tests/test_focus_diagnostics.py')
if ($LASTEXITCODE -ne 0) { throw "Focus diagnostic tests failed: $LASTEXITCODE" }
& $python.Source (Join-Path $repo 'tests/test_focus_refusals.py')
if ($LASTEXITCODE -ne 0) { throw "Focus refusal history tests failed: $LASTEXITCODE" }
& $python.Source (Join-Path $repo 'tests/test_focus_report_accounting.py')
if ($LASTEXITCODE -ne 0) { throw "Focus report accounting tests failed: $LASTEXITCODE" }
& $python.Source (Join-Path $repo 'tests/test_focus_pairs.py')
if ($LASTEXITCODE -ne 0) { throw "Focus paired review tests failed: $LASTEXITCODE" }
& $python.Source (Join-Path $repo 'tests/test_focus_snapshot_archive.py')
if ($LASTEXITCODE -ne 0) { throw "Focus snapshot archive tests failed: $LASTEXITCODE" }
& $python.Source (Join-Path $repo 'tests/test_focus_pair_execution.py')
if ($LASTEXITCODE -ne 0) { throw "Focus pair executor closure tests failed: $LASTEXITCODE" }
& $python.Source (Join-Path $repo 'tests/test_focus_executor_accounting.py')
if ($LASTEXITCODE -ne 0) { throw "Focus executor accounting tests failed: $LASTEXITCODE" }
& $python.Source (Join-Path $repo 'tests/test_focus_repair.py')
if ($LASTEXITCODE -ne 0) { throw "Focus repair gate tests failed: $LASTEXITCODE" }
& $python.Source (Join-Path $repo 'tests/test_focus_repair_evidence.py')
if ($LASTEXITCODE -ne 0) { throw "Focus repair evidence tests failed: $LASTEXITCODE" }
& $python.Source (Join-Path $repo 'tests/test_focus_review.py')
if ($LASTEXITCODE -ne 0) { throw "Focus final review tests failed: $LASTEXITCODE" }
& $python.Source (Join-Path $repo 'tests/test_focus_terminal.py')
if ($LASTEXITCODE -ne 0) { throw "Focus terminal regression tests failed: $LASTEXITCODE" }
& $python.Source (Join-Path $repo 'tests/test_focus_status.py')
if ($LASTEXITCODE -ne 0) { throw "Focus status regression tests failed: $LASTEXITCODE" }
& $python.Source (Join-Path $repo 'tests/test_focus_project.py')
if ($LASTEXITCODE -ne 0) { throw "Focus project regression tests failed: $LASTEXITCODE" }
& $python.Source (Join-Path $repo 'tests/test_focus_publication_recovery.py')
if ($LASTEXITCODE -ne 0) { throw "Focus publication recovery tests failed: $LASTEXITCODE" }
& $python.Source (Join-Path $repo 'tests/test_focus_publication_scope.py')
if ($LASTEXITCODE -ne 0) { throw "Focus publication scope tests failed: $LASTEXITCODE" }
& $python.Source (Join-Path $repo 'tests/test_focus_brief.py')
if ($LASTEXITCODE -ne 0) { throw "Focus project brief tests failed: $LASTEXITCODE" }
& $python.Source (Join-Path $repo 'tests/test_focus_parallel.py')
if ($LASTEXITCODE -ne 0) { throw "Focus parallel member tests failed: $LASTEXITCODE" }
& $python.Source (Join-Path $repo 'tests/test_focus_resolve.py')
if ($LASTEXITCODE -ne 0) { throw "Focus merge resolver tests failed: $LASTEXITCODE" }
& $python.Source (Join-Path $repo 'tests/test_focus_context_budget.py')
if ($LASTEXITCODE -ne 0) { throw "Focus context budget tests failed: $LASTEXITCODE" }
& (Join-Path $repo 'tools/focus-runtime.ps1') --help
if ($LASTEXITCODE -ne 0) { throw 'Cycle PowerShell help smoke failed.' }
