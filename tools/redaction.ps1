<#
.SYNOPSIS
    The reusable input-boundary + secret-redaction pipeline for Orchestra (task T-087).

.DESCRIPTION
    A single, role-independent tool that turns untrusted external text (issue/PR bodies,
    source-queue text, CI logs, third-party tool output) into a shape that is safe to (a)
    persist into a runtime artifact (status.md, journal.md, events.jsonl, knowledge/*) and
    (b) hand to the next role, WITHOUT letting that external content leak a secret or seize
    authority/routing from the receiving role. It is the executable half of the trust /
    provenance / redaction contract normatively described in docs/queue_contract.md, §18.

    Two things it does, both deterministic and offline (no network, never opens a URL):

      1. Normalization + redaction (`redact`): fold the input to a bounded, control-char-free,
         UTF-8 text, detect binary payloads, and replace every recognized secret / credential /
         authorization header / URL credential / PII match with a stable, NON-reversible
         fingerprint marker `[redacted:<category>:<fp8>]`. The marker keeps the diagnostic
         context (what kind of value, and a stable per-value id so the same secret is
         recognizably the same across artifacts) but cannot be turned back into the value.

      2. Bounded external-data block (`wrap`): emit the normalized+redacted body inside a
         delimited, provenance-headed, injection-neutralized block. Every body line is quoted
         with a `| ` prefix so no line can open a Markdown fence, a heading, or forge the block
         delimiter; URLs are defanged (`http`->`hxxp`) so the source stays traceable but is
         never auto-opened. The header records source, trust level, byte size and a sha256
         fingerprint of the RAW input, so the exact source snapshot is traceable without being
         stored verbatim. External content carried this way is DATA, never instructions: it
         cannot change the authority, route, or rules of the role that receives it.

    What it deliberately does NOT do: it never edits source code or a diff (the contract runs
    it over logs / reports / artifacts, not over the code under review), and it never needs a
    key or network. The default rule set is high-precision (named token/credential/PII shapes)
    so it does not clobber ordinary text such as git SHAs; project-specific patterns are read
    from the optional `.work/constraints.md` (section "## Redaction patterns", one regex per
    `-` bullet) and degrade to none when the file or section is absent.

    Full unredacted sensitive output is a separate, human-gated concern: it is only ever
    allowed in an explicitly configured local protected mode, and any bypass of redaction
    requires the human gate T-095. This tool has no bypass switch of its own by design; the
    protected-mode / bypass integration point is described (not implemented) in
    docs/queue_contract.md, §18 and config.example.md.

.NOTES
    Exit codes:
      0   success
      2   usage / argument error
      3   input read failure (missing --file, unreadable path)

    Runs under PowerShell 7 and Windows PowerShell 5.1. All emitted text is UTF-8 without BOM.

.EXAMPLE
    pwsh -File tools/redaction.ps1 redact --file ci.log
    pwsh -File tools/redaction.ps1 redact --file ci.log --json
    Get-Content issue.md -Raw | pwsh -File tools/redaction.ps1 wrap --source "github-issue#12" --trust external
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# --------------------------------------------------------------------------
# Argument parsing:  <command> [--key value | --flag] ...
# --------------------------------------------------------------------------
$Command = if ($args.Count -ge 1) { [string]$args[0] } else { '' }
$BoolFlags = @('json', 'defang', 'no-defang', 'stdin')
$opts = @{}
for ($i = 1; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    if ($a -like '--*') {
        $key = $a.Substring(2)
        if ($BoolFlags -contains $key) { $opts[$key] = $true; continue }
        $i++
        $val = if ($i -lt $args.Count) { [string]$args[$i] } else { '' }
        $opts[$key] = $val
    }
}

function Fail { param([int]$Code, [string]$Message) throw ('RDCERR|' + $Code + '|' + $Message) }
function Opt { param([string]$Name, $Default = $null) if ($opts.ContainsKey($Name)) { return $opts[$Name] } else { return $Default } }

$script:DefaultMaxBytes = 65536

# --------------------------------------------------------------------------
# Input: raw bytes from --file or stdin (raw bytes so NUL / binary survive).
# --------------------------------------------------------------------------
function Read-InputBytes {
    if ($opts.ContainsKey('file') -and -not [string]::IsNullOrEmpty([string]$opts['file'])) {
        $p = [string]$opts['file']
        if (-not (Test-Path -LiteralPath $p)) { Fail 3 "input file not found: $p" }
        try { return [System.IO.File]::ReadAllBytes($p) } catch { Fail 3 "cannot read input file: $p ($($_.Exception.Message))" }
    }
    # stdin (raw)
    try {
        $stdin = [Console]::OpenStandardInput()
        $ms = New-Object System.IO.MemoryStream
        $stdin.CopyTo($ms)
        return $ms.ToArray()
    } catch {
        return [byte[]]@()
    }
}

# --------------------------------------------------------------------------
# Fingerprint: first 8 hex chars of sha256(category ':' value). Deterministic and
# stable (same value+category -> same id, so one secret is recognizable across
# artifacts) but not reversible.
# --------------------------------------------------------------------------
function Get-Fingerprint {
    param([string]$Value, [string]$Category)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Category + ':' + $Value))
    } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant().Substring(0, 8)
}

function Get-RawFingerprint {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($Bytes) } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant().Substring(0, 8)
}

# --------------------------------------------------------------------------
# Binary detection over raw bytes: a NUL byte, or a high ratio of C0 control bytes
# (excluding tab/LF/CR) plus DEL, means "not text we should redact line-by-line".
# --------------------------------------------------------------------------
function Test-Binary {
    param([byte[]]$Bytes)
    if ($Bytes.Length -eq 0) { return $false }
    $suspicious = 0
    foreach ($b in $Bytes) {
        if ($b -eq 0) { return $true }
        if (($b -lt 0x09) -or ($b -eq 0x0B) -or ($b -eq 0x0C) -or ($b -ge 0x0E -and $b -lt 0x20) -or ($b -eq 0x7F)) {
            $suspicious++
        }
    }
    return (($suspicious / $Bytes.Length) -gt 0.30)
}

# --------------------------------------------------------------------------
# Redaction rules (ordered, broadest-structural first so a whole credential line is
# claimed once). Each rule: Name, Pattern, and an optional Group (a named capture
# group that is the sensitive part; when absent the whole match is replaced).
# Group-based rules keep the surrounding structure (e.g. the "Authorization:" header
# name, the URL scheme/host) and redact only the secret.
#
# Re-matching is prevented structurally, not by fragile lookaheads: every inserted
# marker is held as an opaque private-use placeholder (see Invoke-Pipeline) until all
# rules have run, and any marker already present in the input is swapped to a
# placeholder BEFORE the rules run. So no rule can ever match inside a marker, within
# a single pass or across repeated invocations (redaction is idempotent).
# --------------------------------------------------------------------------
function Get-RedactionRules {
    param([string]$ConstraintsPath)
    $rules = New-Object System.Collections.Generic.List[object]

    function New-Rule { param([string]$Name, [string]$Pattern, [string]$Group = $null)
        [pscustomobject]@{ Name = $Name; Regex = [regex]$Pattern; Group = $Group } }

    # 1. PEM private key block (whole).
    $rules.Add((New-Rule 'private-key' '(?s)-----BEGIN[^\n-]*PRIVATE KEY-----.*?-----END[^\n-]*PRIVATE KEY-----'))
    # 2. Authorization / Proxy-Authorization header line -> redact the whole credential value.
    $rules.Add((New-Rule 'authorization-header' '(?im)^(?<pre>[ \t]*(?:proxy-)?authorization[ \t]*:[ \t]*)(?<val>.+?)[ \t]*$' 'val'))
    # 3. URL credentials scheme://user:pass@host -> redact the user:pass part only.
    $rules.Add((New-Rule 'url-credentials' '(?<pre>[A-Za-z][A-Za-z0-9+.\-]*://)(?<val>[^\s/:@]+:[^\s/@]+)@' 'val'))
    # 4. JSON Web Token (whole).
    $rules.Add((New-Rule 'jwt' '\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\b'))
    # 5. GitHub tokens (whole).
    $rules.Add((New-Rule 'github-token' '\b(?:gh[posur]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b'))
    # 6. Slack tokens (whole).
    $rules.Add((New-Rule 'slack-token' '\bxox[baprs]-[A-Za-z0-9-]{10,}\b'))
    # 7. Google API key (whole).
    $rules.Add((New-Rule 'google-api-key' '\bAIza[0-9A-Za-z_\-]{35}\b'))
    # 8. AWS access key id (whole).
    $rules.Add((New-Rule 'aws-access-key' '\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ANVA|AIPA)[A-Z0-9]{16}\b'))
    # 9. Inline bearer token (outside a header line) -> redact the token.
    $rules.Add((New-Rule 'bearer-token' '(?i)\b(?<pre>bearer[ \t]+)(?<val>[A-Za-z0-9._~+/\-]{8,}={0,2})' 'val'))
    # 10. Sensitive key=value / key: value assignment -> redact the value. The key may be a
    #     larger identifier that embeds a sensitive word joined by _/-/. (e.g.
    #     AWS_SECRET_ACCESS_KEY, DB_PASSWORD, my-api-key), so match the sensitive word inside
    #     an identifier token rather than requiring a bare \b word.
    $rules.Add((New-Rule 'assignment-secret' '(?i)(?<pre>(?<![A-Za-z0-9])[A-Za-z0-9_.\-]*(?:passwords?|passwd|pwd|secret|token|apikey|api[_-]?key|access[_-]?key|access[_-]?token|client[_-]?secret|auth[_-]?token|credentials?|private[_-]?key)[A-Za-z0-9_.\-]*[ \t]*[:=][ \t]*)(?<q>["'']?)(?<val>[^\s"''][^\s"'']{3,})\k<q>' 'val'))
    # 11. Email address (PII, whole).
    $rules.Add((New-Rule 'email' '\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b'))

    # 12+. Project-specific patterns from .work/constraints.md ("## Redaction patterns").
    if ($ConstraintsPath -and (Test-Path -LiteralPath $ConstraintsPath)) {
        $n = 0
        $inSec = $false
        foreach ($line in (Get-Content -LiteralPath $ConstraintsPath -Encoding utf8)) {
            if ($line -match '^##\s+Redaction patterns') { $inSec = $true; continue }
            if ($inSec -and $line -match '^##\s') { break }
            if ($inSec -and $line -match '^\s*-\s+`?([^`]+?)`?\s*$') {
                $pat = $Matches[1].Trim()
                if ($pat) {
                    try {
                        $probe = [regex]$pat
                        $n++
                        $rules.Add((New-Rule ("project-$n") $pat))
                    } catch {
                        # a malformed project pattern must not silently disable redaction of the
                        # rest; skip just this one.
                    }
                }
            }
        }
    }

    return $rules
}

# Apply one rule to text. Each match's sensitive substring is replaced by an opaque
# placeholder (reserved in $State) that carries the final marker; the placeholder is
# substituted back only after every rule has run, so a marker can never be re-scanned.
function Invoke-Rule {
    param([string]$Text, [object]$Rule, $State)
    $name = $Rule.Name
    $group = $Rule.Group
    $evaluator = {
        param($m)
        if ($group) {
            $g = $m.Groups[$group]
            # already-redacted value (contains an opaque placeholder) -> leave untouched.
            if ($g.Value.IndexOf($script:PhOpen) -ge 0) { return $m.Value }
            $ph = Reserve-Marker $State $g.Value $name
            $start = $g.Index - $m.Index
            return $m.Value.Substring(0, $start) + $ph + $m.Value.Substring($start + $g.Length)
        } else {
            if ($m.Value.IndexOf($script:PhOpen) -ge 0) { return $m.Value }
            return (Reserve-Marker $State $m.Value $name)
        }
    }
    return $Rule.Regex.Replace($Text, [System.Text.RegularExpressions.MatchEvaluator]$evaluator)
}

# Placeholder machinery: reserve a marker, get an opaque token bounded by private-use
# characters (U+E000/U+E001) that no rule and no control-char strip can touch.
$script:PhOpen = [char]0xE000
$script:PhClose = [char]0xE001

function New-RedactionState {
    return [pscustomobject]@{ Markers = [System.Collections.Generic.List[string]]::new() }
}
function Reserve-Marker {
    param($State, [string]$Value, [string]$Category)
    return (Reserve-Literal $State "[redacted:$Category`:$(Get-Fingerprint $Value $Category)]")
}
# Reserve an exact literal (used to protect a marker already present in the input so a
# repeated pass restores it verbatim instead of re-fingerprinting it).
function Reserve-Literal {
    param($State, [string]$Literal)
    $idx = $State.Markers.Count
    $State.Markers.Add($Literal)
    return ($script:PhOpen.ToString() + $idx + $script:PhClose.ToString())
}
function Restore-Markers {
    param($State, [string]$Text)
    for ($i = 0; $i -lt $State.Markers.Count; $i++) {
        $Text = $Text.Replace($script:PhOpen.ToString() + $i + $script:PhClose.ToString(), $State.Markers[$i])
    }
    return $Text
}

# --------------------------------------------------------------------------
# Core pipeline: raw bytes -> normalized + redacted text + a structured report.
# --------------------------------------------------------------------------
function Invoke-Pipeline {
    param(
        [byte[]]$Bytes,
        [int]$MaxBytes,
        [string]$ConstraintsPath,
        [switch]$Defang
    )
    # Empty input ($null / zero-length) is a normal, valid case (empty issue/PR body,
    # empty CI log, empty event reason). Read-InputBytes returns byte[0] for it, but an
    # empty array collapses to $null when captured through the output stream and binds the
    # [byte[]] parameter as $null, so under StrictMode $Bytes.Length would throw. Normalize
    # to a real empty array so the whole pipeline degrades to a safe empty result (rc=0).
    if ($null -eq $Bytes) { $Bytes = [byte[]]::new(0) }
    $report = [ordered]@{
        input_bytes           = $Bytes.Length
        binary                = $false
        truncated             = $false
        control_chars_removed = 0
        defanged              = [bool]$Defang
        categories            = [ordered]@{}
        fingerprints          = @()
        total_redactions      = 0
        raw_sha256            = (Get-RawFingerprint $Bytes)
        output                = ''
        output_lines          = 0
    }

    # 1. binary payloads are not redacted line-by-line: replace with a placeholder.
    if (Test-Binary $Bytes) {
        $report.binary = $true
        $report.output = "[binary content omitted: bytes=$($Bytes.Length) sha256=$($report.raw_sha256)]"
        $report.output_lines = 1
        return $report
    }

    # 2. size cap (on bytes), then decode UTF-8.
    $work = $Bytes
    if ($MaxBytes -gt 0 -and $Bytes.Length -gt $MaxBytes) {
        $report.truncated = $true
        $work = New-Object 'byte[]' $MaxBytes
        [System.Array]::Copy($Bytes, $work, $MaxBytes)
    }
    $text = [System.Text.Encoding]::UTF8.GetString($work)

    # 3. normalize line endings to LF and strip C0 control chars (except tab/LF).
    $text = $text -replace "`r`n", "`n" -replace "`r", "`n"
    $before = $text.Length
    $text = [regex]::Replace($text, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '')
    $report.control_chars_removed = $before - $text.Length

    # 4. redaction. First protect any marker already present in the input (so a second
    #    pass is idempotent), then run every rule; both only insert opaque placeholders.
    $state = New-RedactionState
    $text = [regex]::Replace($text, '\[redacted:[a-z0-9-]+:[0-9a-f]{8}\]', {
            param($m) Reserve-Literal $state $m.Value })
    foreach ($rule in (Get-RedactionRules $ConstraintsPath)) {
        $text = Invoke-Rule $text $rule $state
    }

    # 5. optional URL defang (so a source URL stays readable/traceable but is not auto-opened).
    if ($Defang) {
        $text = [regex]::Replace($text, '(?i)\b(http|ftp)(s?)://', 'hxxp$2://')
    }

    if ($report.truncated) {
        $text = $text + "`n[truncated: original_bytes=$($Bytes.Length) kept_bytes=$MaxBytes sha256=$($report.raw_sha256)]"
    }

    # 6. substitute the opaque placeholders back to their final markers, then derive the
    #    report from what is actually visible in the output (authoritative, no double count).
    $text = Restore-Markers $state $text
    $counts = [ordered]@{}
    $fingerprints = [System.Collections.Generic.List[string]]::new()
    foreach ($mk in [regex]::Matches($text, '\[redacted:(?<cat>[a-z0-9-]+):(?<fp>[0-9a-f]{8})\]')) {
        $cat = $mk.Groups['cat'].Value
        if ($counts.Contains($cat)) { $counts[$cat] = $counts[$cat] + 1 } else { $counts[$cat] = 1 }
        $fingerprints.Add("$cat`:$($mk.Groups['fp'].Value)")
    }
    $ordered = [ordered]@{}
    foreach ($k in ($counts.Keys | Sort-Object)) { $ordered[$k] = $counts[$k] }
    $report.categories = $ordered
    $report.fingerprints = @($fingerprints)
    $report.total_redactions = ($fingerprints.Count)
    $report.output = $text
    $report.output_lines = ($text -split "`n").Count
    return $report
}

function Resolve-MaxBytes {
    $mb = Opt 'max-bytes' $null
    if ($null -eq $mb -or [string]::IsNullOrEmpty([string]$mb)) { return $script:DefaultMaxBytes }
    $n = 0
    if (-not [int]::TryParse([string]$mb, [ref]$n) -or $n -lt 0) { Fail 2 "--max-bytes must be a non-negative integer" }
    return $n
}

function Resolve-ConstraintsPath {
    if ($opts.ContainsKey('constraints') -and -not [string]::IsNullOrEmpty([string]$opts['constraints'])) {
        return [string]$opts['constraints']
    }
    if ($opts.ContainsKey('work') -and -not [string]::IsNullOrEmpty([string]$opts['work'])) {
        return (Join-Path ([string]$opts['work']) 'constraints.md')
    }
    return $null
}

function Report-ToJson {
    param($Report)
    # emit a stable, compact JSON object (categories/fingerprints/flags + output text).
    return ($Report | ConvertTo-Json -Depth 6)
}

# ==========================================================================
# redact
# ==========================================================================
function Cmd-Redact {
    $bytes = Read-InputBytes
    $defang = ($opts.ContainsKey('defang')) -and (-not $opts.ContainsKey('no-defang'))
    $report = Invoke-Pipeline -Bytes $bytes -MaxBytes (Resolve-MaxBytes) -ConstraintsPath (Resolve-ConstraintsPath) -Defang:$defang
    if ($opts.ContainsKey('json')) {
        $report['command'] = 'redact'
        Write-Output (Report-ToJson $report)
    } else {
        [Console]::Out.Write($report.output)
    }
}

# ==========================================================================
# wrap  (bounded external-data block: provenance header + neutralized body)
# ==========================================================================
function Cmd-Wrap {
    $bytes = Read-InputBytes
    $source = [string](Opt 'source' 'unknown')
    $trust = [string](Opt 'trust' 'external')
    # external content is always defanged and neutralized regardless of --no-defang.
    $report = Invoke-Pipeline -Bytes $bytes -MaxBytes (Resolve-MaxBytes) -ConstraintsPath (Resolve-ConstraintsPath) -Defang
    $body = $report.output

    # neutralize: quote every body line with "| " so no line can open a Markdown fence /
    # heading or forge the block delimiter; the body is DATA, not instructions.
    $lines = $body -split "`n"
    $quoted = ($lines | ForEach-Object { '| ' + $_ }) -join "`n"

    $flags = New-Object System.Collections.Generic.List[string]
    if ($report.binary) { $flags.Add('binary') }
    if ($report.truncated) { $flags.Add('truncated') }
    if ($report.control_chars_removed -gt 0) { $flags.Add('control-stripped') }
    $flags.Add('defanged')
    if ($report.total_redactions -gt 0) { $flags.Add('redacted') }
    $flagStr = ($flags -join ',')

    $srcEsc = ($source -replace '"', "'") -replace '[\r\n]', ' '
    $trustEsc = ($trust -replace '"', "'") -replace '[\r\n]', ' '

    $header = "<<< orchestra:external-data source=`"$srcEsc`" trust=`"$trustEsc`" bytes=$($report.input_bytes) sha256=$($report.raw_sha256) redactions=$($report.total_redactions) normalized=`"$flagStr`" >>>"
    $footer = '<<< orchestra:end-external-data >>>'
    $block = $header + "`n" + $quoted + "`n" + $footer

    if ($opts.ContainsKey('json')) {
        $out = [ordered]@{
            command          = 'wrap'
            source           = $source
            trust            = $trust
            input_bytes      = $report.input_bytes
            binary           = $report.binary
            truncated        = $report.truncated
            defanged         = $true
            categories       = $report.categories
            fingerprints     = $report.fingerprints
            total_redactions = $report.total_redactions
            raw_sha256       = $report.raw_sha256
            normalized       = $flagStr
            block            = $block
        }
        Write-Output ($out | ConvertTo-Json -Depth 6)
    } else {
        [Console]::Out.Write($block)
    }
}

# ==========================================================================
# version
# ==========================================================================
function Cmd-Version {
    Write-Output 'orchestra-redaction 1'
}

# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------
try {
    switch ($Command) {
        'redact'  { Cmd-Redact }
        'wrap'    { Cmd-Wrap }
        'version' { Cmd-Version }
        default {
            Fail 2 "unknown command '$Command'. Valid: redact, wrap, version"
        }
    }
} catch {
    $m = [string]$_.Exception.Message
    if ($m -like 'RDCERR|*') {
        $parts = $m -split '\|', 3
        [Console]::Error.WriteLine("redaction: $($parts[2])")
        exit ([int]$parts[1])
    }
    [Console]::Error.WriteLine("redaction: $m")
    if ($env:REDACTION_DEBUG) { [Console]::Error.WriteLine($_.ScriptStackTrace) }
    exit 1
}
