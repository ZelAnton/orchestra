<#
.SYNOPSIS
    Guards the codex-runtime path-resolution contract "checkout vs mirror" and
    the literal-tilde requirement of the mirror form (task T-119).

.DESCRIPTION
    The Codex adapters (agents/coder_codex.md, agents/reviewer_codex.md) resolve
    the runtime wrapper `codex-runtime.ps1` to one of two literal command forms
    (task T-114):

      - checkout: `pwsh -File tools/codex-runtime.ps1 ...`   (relative path, no tilde)
      - mirror  : `pwsh -File ~/.claude/scripts/codex-runtime.ps1 ...`  (leading tilde)

    Each form has its own permanent allow-rule seeded by cc-config so the classifier
    lets the adapters run autonomously. T-119's live failure was that the mirror form
    was handed to pwsh with an UNEXPANDED literal tilde ("The argument
    '~/.claude/scripts/codex-runtime.ps1' is not recognized as the name of a script
    file"): the shell only tilde-expands a `~` that is a literal first character of a
    word in the command TEXT, never a `~` delivered through a shell variable or any
    other expansion. Routing the resolved mirror path through a `$CODEX_RT` variable
    therefore silently defeated tilde-expansion.

    The end-to-end run cannot be exercised in CI (no real codex, and the mirror lives
    outside the repo), so this script asserts the *contract* those prose specs and the
    cc-config seeds mandate, as a static guard (same style as
    tools/check-codex-sandbox-guard.ps1). It checks:

      1. Allow-rule agreement. Both canonical runtime allow-rules (checkout form and
         mirror form) are present byte-identical in launchers/cc-config.sh,
         launchers/cc-config.cmd and config.example.md (rule and actual command must
         not drift - a T-119 criterion).
      2. Rule <-> command agreement. The exact command each allow-rule authorizes
         (the rule with the `Bash(` prefix and ` *)` glob suffix stripped) appears
         literally in BOTH adapters - so the documented command is the one the rule
         grants, tilde included.
      3. No shell-variable-for-mirror anti-pattern. Neither adapter assigns the
         mirror tilde path to a `CODEX_RT` shell variable (`CODEX_RT=~...`) - the exact
         construct that made the tilde arrive unexpanded.
      4. Tilde-expansion caveat documented. The canonical caveat sentence is present
         (whitespace-insensitive) in both adapters, knowledge.md and
         docs/queue_contract.md, so the four docs agree on the resolved method.
      5. Behavioural proof (only when `bash` is on PATH; self-skips otherwise). A
         literal `~` at word start expands, while a `~` delivered via a shell variable
         does NOT - the exact OS semantics the fix relies on.

    On any violation prints one line per finding as "<source> - <check> - <detail>"
    and exits 1. A structural problem (a required file or a rule string cannot be
    located, i.e. the format changed) exits 2 so it is never mistaken for "contract
    satisfied". Nothing to report -> a short summary and exit 0. Runs identically
    under pwsh on Windows and Linux.

.EXAMPLE
    pwsh -File tools/check-codex-runtime-path-guard.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$AgentsDir = Join-Path $RepoRoot 'agents'

$CoderCodex = Join-Path $AgentsDir 'coder_codex.md'
$ReviewerCodex = Join-Path $AgentsDir 'reviewer_codex.md'
$KnowledgeFile = Join-Path $RepoRoot 'knowledge.md'
$QueueContractFile = Join-Path $RepoRoot 'docs/queue_contract.md'
$ConfigFile = Join-Path $RepoRoot 'config.example.md'
$CcConfigSh = Join-Path $RepoRoot 'launchers/cc-config.sh'
$CcConfigCmd = Join-Path $RepoRoot 'launchers/cc-config.cmd'

$required = [ordered]@{
    'agents/coder_codex.md'    = $CoderCodex
    'agents/reviewer_codex.md' = $ReviewerCodex
    'knowledge.md'             = $KnowledgeFile
    'docs/queue_contract.md'   = $QueueContractFile
    'config.example.md'        = $ConfigFile
    'launchers/cc-config.sh'   = $CcConfigSh
    'launchers/cc-config.cmd'  = $CcConfigCmd
}
foreach ($ref in $required.Keys) {
    if (-not (Test-Path -LiteralPath $required[$ref])) {
        Write-Error "Required file not found: $($required[$ref])"
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
function Fail-Structural {
    param([string]$Message)
    Write-Error $Message
    exit 2
}

# Read every guarded file once (UTF-8, joined with LF for whole-file substring checks).
$text = @{}
foreach ($ref in $required.Keys) {
    $text[$ref] = (Get-Content -LiteralPath $required[$ref] -Encoding utf8) -join "`n"
}

# The two canonical runtime-wrapper allow-rules (single source of truth: cc-config).
# Keep byte-identical to launchers/cc-config.{sh,cmd} $CODEX_ALLOW_RULES / $rules.
$AllowRules = [ordered]@{
    'checkout' = 'Bash(pwsh -File tools/codex-runtime.ps1 *)'
    'mirror'   = 'Bash(pwsh -File ~/.claude/scripts/codex-runtime.ps1 *)'
}

# --- 1. Allow-rule agreement across the three sources of truth -----------------
$ruleSources = [ordered]@{
    'launchers/cc-config.sh'  = $text['launchers/cc-config.sh']
    'launchers/cc-config.cmd' = $text['launchers/cc-config.cmd']
    'config.example.md'       = $text['config.example.md']
}
foreach ($form in $AllowRules.Keys) {
    $rule = $AllowRules[$form]
    # Structural: the rule must be locatable in at least one source; if it is nowhere,
    # the canonical form itself has changed and this guard can no longer be trusted.
    $anywhere = $false
    foreach ($ref in $ruleSources.Keys) { if ($ruleSources[$ref].Contains($rule)) { $anywhere = $true } }
    if (-not $anywhere) {
        Fail-Structural "Canonical $form allow-rule '$rule' is not present in any of cc-config.sh / cc-config.cmd / config.example.md - the allow-rule format may have changed."
    }
    foreach ($ref in $ruleSources.Keys) {
        if (-not $ruleSources[$ref].Contains($rule)) {
            Add-Finding -FileRef $ref -Check 'allow-rule-agreement' `
                -Detail "missing the canonical $form runtime allow-rule '$rule' (it must be byte-identical across cc-config.sh, cc-config.cmd and config.example.md)"
        }
    }
}

# --- 2. Rule <-> command agreement: the command each rule authorizes is documented -
# Strip the `Bash(` prefix and the ` *)` glob suffix to recover the exact command.
$adapters = [ordered]@{
    'agents/coder_codex.md'    = $text['agents/coder_codex.md']
    'agents/reviewer_codex.md' = $text['agents/reviewer_codex.md']
}
foreach ($form in $AllowRules.Keys) {
    $rule = $AllowRules[$form]
    if ($rule -notmatch '^Bash\((?<cmd>.+?)\s\*\)$') {
        Fail-Structural "Canonical $form allow-rule '$rule' does not match the expected 'Bash(<command> *)' shape."
    }
    $cmd = $Matches['cmd']   # e.g. 'pwsh -File ~/.claude/scripts/codex-runtime.ps1'
    foreach ($ref in $adapters.Keys) {
        if (-not $adapters[$ref].Contains($cmd)) {
            Add-Finding -FileRef $ref -Check 'rule-command-agreement' `
                -Detail "does not document the literal $form command '$cmd' that its allow-rule grants (the documented command and the allow-rule must be the same literal string, tilde included)"
        }
    }
}

# --- 3. No shell-variable-for-mirror anti-pattern in the adapters --------------
# CODEX_RT=~... (optionally quoted) is the exact construct that delivered the tilde
# through a variable, leaving it unexpanded (T-119). It must not reappear.
foreach ($ref in $adapters.Keys) {
    if ($adapters[$ref] -match 'CODEX_RT\s*=\s*["'']?~') {
        Add-Finding -FileRef $ref -Check 'no-tilde-in-variable' `
            -Detail "assigns the mirror tilde path to a CODEX_RT shell variable ('CODEX_RT=~...'); a tilde delivered via a variable is NOT expanded by the shell - write the literal tilde path directly in the command text instead (T-119)"
    }
}

# --- 4. Canonical tilde-expansion caveat present in the four contract docs -----
$CaveatCanonical = 'тильда раскрывается shell только как литерал в начале слова текста команды, не через переменную или подстановку'
$caveatDocs = @('agents/coder_codex.md', 'agents/reviewer_codex.md', 'knowledge.md', 'docs/queue_contract.md')
foreach ($ref in $caveatDocs) {
    $normalized = ($text[$ref] -replace '\s+', ' ')
    if (-not $normalized.Contains($CaveatCanonical)) {
        Add-Finding -FileRef $ref -Check 'tilde-caveat' `
            -Detail "does not carry the canonical tilde-expansion caveat sentence '$CaveatCanonical' (the four contract docs must agree on the resolved method)"
    }
}

# --- 5. Behavioural proof of the tilde semantics (self-skips without bash) ------
$bash = Get-Command bash -ErrorAction SilentlyContinue
if ($null -ne $bash) {
    try {
        # Literal `~` at word start -> shell expands it (must NOT stay '~...').
        $literal = (& $bash.Source -c 'printf %s ~/__t119_tilde_probe__' 2>$null)
        # `~` delivered via a shell variable -> shell does NOT expand it (stays '~...').
        $viaVar = (& $bash.Source -c 'v="~/__t119_tilde_probe__"; printf %s $v' 2>$null)
        if ($literal -like '~*') {
            Add-Finding -FileRef 'bash (behavioural)' -Check 'tilde-literal-expands' `
                -Detail "a literal '~' at word start did not expand (got '$literal') - the mirror form's premise (literal tilde in the command text expands) does not hold on this platform"
        }
        if ($viaVar -notlike '~*') {
            Add-Finding -FileRef 'bash (behavioural)' -Check 'tilde-via-variable-stays-literal' `
                -Detail "a '~' delivered via a shell variable unexpectedly expanded (got '$viaVar') - contradicts the documented shell semantics the fix rests on"
        }
    }
    catch {
        Write-Host "NOTE - behavioural bash probe could not run ($($_.Exception.Message)); static contract checks still apply."
    }
}
else {
    Write-Host "NOTE - 'bash' not on PATH; skipped the behavioural tilde-expansion probe (static contract checks still apply)."
}

# --- Report -------------------------------------------------------------------
if ($findings.Count -eq 0) {
    Write-Host "OK - codex-runtime path contract holds: checkout/mirror allow-rules agree across cc-config.{sh,cmd} and config.example.md, both adapters document the literal command each rule grants (no CODEX_RT=~ variable), and the tilde-expansion caveat is consistent across the four contract docs."
    exit 0
}

Write-Host "Found $($findings.Count) codex-runtime path contract violation(s):`n"
foreach ($f in $findings) {
    Write-Host $f
}
exit 1
