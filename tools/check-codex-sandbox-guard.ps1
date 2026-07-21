<#
.SYNOPSIS
    Verifies the Codex sandbox fail-closed contract in the Codex adapter specs
    (task T-069): the codex exec invocation must pin a fail-closed approval
    policy, and a sandbox-initialization failure must escalate instead of
    running the command outside the sandbox.

.DESCRIPTION
    The Codex adapters (agents/coder_codex.md, agents/reviewer_codex.md) drive an
    external `codex exec` binary that is not present in CI, so the guarantee that
    codex never writes outside its worktree cannot be exercised end-to-end here.
    What CAN be machine-checked - and what actually enforces the guarantee - is the
    invocation *contract* those prose specs mandate. This script asserts it as a
    static contract test (the same style as tools/check-consistency.ps1):

      1. Argv construction. The single fenced `codex exec ...` invocation block in
         each adapter must pass `--sandbox` AND the Orchestra-pinned fail-closed
         approval policy `-c approval_policy=never`, and must NOT pin any fail-open
         policy value (on-failure / on-request / untrusted) that would let codex
         escalate a sandbox failure to unsandboxed execution.

      2. Sandbox-spawn error scenario. Each adapter (and the docs config.example.md
         and knowledge.md) must document the sandbox-init failure signature
         (`CreateProcessAsUserW failed: 5`) and the `sandbox-init` ENV_LIMIT class,
         and each adapter must reference the escalation sentinel class
         `ENV_LIMIT/sandbox-init` - i.e. escalate (before any edits) rather than
         fall back to running outside the sandbox.

    On any violation, prints one line per finding in the form
    "<file> - <check> - <detail>" and exits non-zero. With nothing to report,
    prints a short summary and exits 0. A structural problem (a required file or
    the invocation block is missing, e.g. the spec format changed) exits 2 so it
    is never mistaken for "contract satisfied".

.EXAMPLE
    pwsh -File tools/check-codex-sandbox-guard.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$AgentsDir = Join-Path $RepoRoot 'agents'

$CoderCodex = Join-Path $AgentsDir 'coder_codex.md'
$ReviewerCodex = Join-Path $AgentsDir 'reviewer_codex.md'
$ConfigFile = Join-Path $RepoRoot 'config.example.md'
$KnowledgeFile = Join-Path $RepoRoot 'knowledge.md'
$RuntimeFile = Join-Path $RepoRoot 'tools/codex-runtime.ps1'
$PreflightFile = Join-Path $RepoRoot 'tools/codex-preflight.ps1'
$ProcessorFile = Join-Path $AgentsDir 'processor.md'
$CuratorFile = Join-Path $AgentsDir 'knowledge_curator.md'

foreach ($required in @($CoderCodex, $ReviewerCodex, $ConfigFile, $KnowledgeFile, $RuntimeFile, $PreflightFile, $ProcessorFile, $CuratorFile)) {
    if (-not (Test-Path -LiteralPath $required)) {
        Write-Error "Required file not found: $required"
        exit 2
    }
}

$findings = [System.Collections.Generic.List[string]]::new()
function Add-Finding {
    param(
        [Parameter(Mandatory)][string]$FileRef,
        [Parameter(Mandatory)][string]$Check,
        [Parameter(Mandatory)][string]$Detail
    )
    $findings.Add("$FileRef - $Check - $Detail")
}

# The Orchestra-pinned fail-closed approval override (T-069). Every codex exec call
# must carry it; no fail-open policy value may be pinned instead.
$FailClosedOverride = '-c approval_policy=never'
$FailOpenValues = @('on-failure', 'on-request', 'untrusted')

# --- Extract the fenced `codex exec` invocation block from an adapter spec -----
# Returns the block body (without the ``` fences), or $null if not found.
function Get-CodexInvocationBlock {
    # NB: no [Parameter(Mandatory)] on this [string[]] - a mandatory string array
    # rejects arrays containing blank lines ("empty string" binding error), and the
    # spec files are full of blank lines. The caller always supplies it.
    param([string[]]$Lines)

    $inFence = $false
    $buffer = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $Lines) {
        if ($line -match '^\s*```') {
            if ($inFence) {
                # closing fence: if this block launched codex exec, return it
                $body = $buffer -join "`n"
                if ($body -match '(?m)^\s*codex exec\b') { return $body }
                $inFence = $false
                $buffer.Clear()
            }
            else {
                $inFence = $true
                $buffer.Clear()
            }
            continue
        }
        if ($inFence) { [void]$buffer.Add($line) }
    }
    return $null
}

# --- Per-adapter contract: argv construction + sandbox-init scenario ----------

$adapters = [ordered]@{
    'agents/coder_codex.md'    = $CoderCodex
    'agents/reviewer_codex.md' = $ReviewerCodex
}

foreach ($ref in $adapters.Keys) {
    $path = $adapters[$ref]
    $lines = Get-Content -LiteralPath $path -Encoding utf8
    $text = $lines -join "`n"

    # 1. Argv construction, scoped to the actual `codex exec` invocation block.
    $block = Get-CodexInvocationBlock -Lines $lines
    if ($null -eq $block) {
        Write-Error "$ref - could not find a fenced 'codex exec' invocation block (spec format may have changed)"
        exit 2
    }
    if ($block -notmatch '--sandbox') {
        Add-Finding -FileRef $ref -Check 'argv-sandbox' `
            -Detail "the codex exec invocation block does not pass --sandbox"
    }
    if ($block -notmatch [regex]::Escape($FailClosedOverride)) {
        Add-Finding -FileRef $ref -Check 'argv-approval-policy' `
            -Detail "the codex exec invocation block does not pin the fail-closed override '$FailClosedOverride'"
    }
    foreach ($bad in $FailOpenValues) {
        if ($block -match ('approval_policy=' + [regex]::Escape($bad))) {
            Add-Finding -FileRef $ref -Check 'argv-approval-policy' `
                -Detail "the codex exec invocation block pins a fail-open approval policy 'approval_policy=$bad'"
        }
    }

    # 2. Sandbox-spawn error scenario documented + fail-closed escalation.
    if ($text -notmatch 'CreateProcessAsUserW failed: 5') {
        Add-Finding -FileRef $ref -Check 'sandbox-init-signature' `
            -Detail "does not document the sandbox-init failure signature 'CreateProcessAsUserW failed: 5'"
    }
    if ($text -notmatch 'sandbox-init') {
        Add-Finding -FileRef $ref -Check 'sandbox-init-class' `
            -Detail "does not reference the 'sandbox-init' ENV_LIMIT class"
    }
    if ($text -notmatch 'ENV_LIMIT/sandbox-init') {
        Add-Finding -FileRef $ref -Check 'sandbox-init-escalation' `
            -Detail "does not reference the escalation sentinel class 'ENV_LIMIT/sandbox-init'"
    }
}

# --- Doc sync: config.example.md + knowledge.md describe the fail-closed guard --

$docs = [ordered]@{
    'config.example.md' = $ConfigFile
    'knowledge.md'      = $KnowledgeFile
}

foreach ($ref in $docs.Keys) {
    $text = (Get-Content -LiteralPath $docs[$ref] -Encoding utf8) -join "`n"
    if ($text -notmatch 'approval_policy=never') {
        Add-Finding -FileRef $ref -Check 'doc-approval-policy' `
            -Detail "does not describe the fail-closed override 'approval_policy=never'"
    }
    if ($text -notmatch 'sandbox-init') {
        Add-Finding -FileRef $ref -Check 'doc-sandbox-init' `
            -Detail "does not describe the 'sandbox-init' fail-closed class"
    }
    if ($text -notmatch 'CreateProcessAsUserW failed: 5') {
        Add-Finding -FileRef $ref -Check 'doc-sandbox-init' `
            -Detail "does not document the sandbox-init failure signature 'CreateProcessAsUserW failed: 5'"
    }
}

# --- Worktree-specific Windows split-root regression --------------------------
$worktreeSignature = 'cannot enforce split writable root sets directly'
$runtimeText = Get-Content -LiteralPath $RuntimeFile -Raw -Encoding utf8
$preflightText = Get-Content -LiteralPath $PreflightFile -Raw -Encoding utf8
$processorText = Get-Content -LiteralPath $ProcessorFile -Raw -Encoding utf8
$curatorText = Get-Content -LiteralPath $CuratorFile -Raw -Encoding utf8

if ($runtimeText -notmatch 'sandbox-init-worktree' -or $runtimeText -notmatch [regex]::Escape($worktreeSignature)) {
    Add-Finding -FileRef 'tools/codex-runtime.ps1' -Check 'worktree-sandbox-class' `
        -Detail 'does not classify the exact unelevated split writable-root refusal separately'
}
if ($runtimeText -notmatch 'if \(\$Sandbox -eq ''read-only''\)[\s\S]{0,300}--add-dir') {
    Add-Finding -FileRef 'tools/codex-runtime.ps1' -Check 'worktree-single-root' `
        -Detail '--add-dir is not visibly restricted to read-only; workspace-write must remain a single writable root'
}
if ($runtimeText -notmatch 'WorkingDirectory') {
    Add-Finding -FileRef 'tools/codex-runtime.ps1' -Check 'worktree-cwd' `
        -Detail 'does not mechanically pin the Codex child working directory to the task worktree'
}
if ($preflightText -notmatch "PfOpt 'workspace'" -or $preflightText -notmatch 'downgrade-worktree' -or $preflightText -notmatch 'WorkingDirectory \$Workspace') {
    Add-Finding -FileRef 'tools/codex-preflight.ps1' -Check 'exact-worktree-preflight' `
        -Detail 'does not probe the exact task worktree and return the scoped downgrade decision'
}
foreach ($requiredText in @('--workspace', 'worktree_codex_route=canary', 'sandbox-init-worktree')) {
    if ($processorText -notmatch [regex]::Escape($requiredText)) {
        Add-Finding -FileRef 'agents/processor.md' -Check 'worktree-routing' `
            -Detail "missing worktree-specific routing marker '$requiredText'"
    }
}
foreach ($requiredText in @('INDEX — производный каталог', 'runtime:codex-worktree', 'два успешных canary')) {
    if ($curatorText -notmatch [regex]::Escape($requiredText)) {
        Add-Finding -FileRef 'agents/knowledge_curator.md' -Check 'worktree-pitfall-retention' `
            -Detail "missing durable KB rule '$requiredText'"
    }
}

# --- Report -------------------------------------------------------------------

if ($findings.Count -eq 0) {
    Write-Host "OK - Codex sandbox fail-closed contract holds (approval_policy=never pinned in both adapters; sandbox-init escalation documented in adapters and docs)."
    exit 0
}

Write-Host "Found $($findings.Count) Codex sandbox fail-closed contract violation(s):`n"
foreach ($f in $findings) {
    Write-Host $f
}
exit 1
