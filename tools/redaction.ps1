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

      1. Normalization + redaction (`redact`): fold the input to a control-char-free, UTF-8
         text, detect binary payloads, and replace every recognized secret / credential /
         authorization header / URL credential / PII match with a stable, NON-reversible
         fingerprint marker `[redacted:<category>:<fp8>]`. The marker keeps the diagnostic
         context (what kind of value, and a stable per-value id so the same secret is
         recognizably the same across artifacts) but cannot be turned back into the value.
         The `--max-bytes` size bound is applied LAST, to the already-redacted text, never to
         the raw input: cutting raw bytes first would slice a secret that straddles the cut
         into a head no rule can match any more, and that head would then survive verbatim
         (T-317). See Get-BoundedRedactedText.

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

    Cost: the rules scan the WHOLE input by design (T-317) - `--max-bytes` bounds what is
    emitted, not how much is examined - so redacting a multi-megabyte log costs seconds. A
    caller that must bound the work bounds the INPUT it passes (tools/supervisor.ps1 already
    caps a captured stream via --output-max-bytes); it must never be bounded by cutting bytes
    ahead of the rules, which is exactly the leak this ordering exists to prevent.

.EXAMPLE
    pwsh -File tools/redaction.ps1 redact --file ci.log
    pwsh -File tools/redaction.ps1 redact --file ci.log --json
    Get-Content issue.md -Raw | pwsh -File tools/redaction.ps1 wrap --source "github-issue#12" --trust external
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# Shared infrastructure primitives (arg-parse, Fail/Opt + catch dispatcher; T-240).
# Dot-sourced like tools/policy-schema.ps1.
. (Join-Path $PSScriptRoot 'common.ps1')
$script:ErrPrefix = 'RDCERR'  # coded-error tag decoded by the catch dispatcher

# --------------------------------------------------------------------------
# Argument parsing:  <command> [--key value | --flag] ...
# --------------------------------------------------------------------------
$parsed = Parse-CliArgs $args -BoolFlags @('json', 'defang', 'no-defang', 'stdin')
$Command = $parsed.Command
$opts = $parsed.Opts

$script:DefaultMaxBytes = 65536
# How far back from the byte budget the truncation cut may search for a clean break
# (line break, else space/tab). Bounded twice - by this absolute cap and by a quarter of the
# budget - so a cosmetic break can never eat a meaningful share of a small budget, and the
# visible output stays ~MaxBytes even for text with no whitespace at all. See
# Get-BoundedRedactedText.
$script:BreakLookback = 256

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
#
# The hasher is created once and reused: this runs once per match, and since the size bound
# moved after redaction (T-317) the rules see the whole input, so a big log means many more
# calls here - creating and disposing an SHA256 instance per match was measurably the most
# expensive part of the pipeline. The script is single-threaded, and ComputeHash resets the
# instance state per call, so reuse changes nothing about the emitted value.
# --------------------------------------------------------------------------
$script:Sha256 = $null
function Get-Sha256 {
    if ($null -eq $script:Sha256) { $script:Sha256 = [System.Security.Cryptography.SHA256]::Create() }
    return $script:Sha256
}

function Get-Fingerprint {
    param([string]$Value, [string]$Category)
    $hash = (Get-Sha256).ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Category + ':' + $Value))
    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant().Substring(0, 8)
}

function Get-RawFingerprint {
    param([byte[]]$Bytes)
    $hash = (Get-Sha256).ComputeHash($Bytes)
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
# Substitute every reserved placeholder back to its marker in ONE pass over the text. A
# per-marker String.Replace loop would be O(markers x text) - fine while the text was pre-cut
# to --max-bytes, but the size bound now runs after redaction (T-317), so the text scanned
# here is the whole input and a log with many matches (e.g. thousands of e-mail addresses)
# would make that loop quadratic.
function Restore-Markers {
    param($State, [string]$Text)
    if ($State.Markers.Count -eq 0) { return $Text }
    $pattern = [regex]::Escape([string]$script:PhOpen) + '([0-9]+)' + [regex]::Escape([string]$script:PhClose)
    return [regex]::Replace($Text, $pattern, {
            param($m)
            $idx = [int]$m.Groups[1].Value
            if ($idx -ge 0 -and $idx -lt $State.Markers.Count) { return $State.Markers[$idx] }
            return $m.Value
        })
}

# Is $Text (which starts at an unclosed '[') the beginning of a `[redacted:<cat>:<fp8>]`
# marker, i.e. a marker the cut has split? Only such a fragment is dropped; an unclosed
# bracket in ordinary log text (`[ERROR`, `[2026-07-25`) is left alone.
function Test-MarkerHead {
    param([string]$Text)
    $head = '[redacted:'
    if ($Text.Length -lt $head.Length) { return $head.StartsWith($Text, [System.StringComparison]::Ordinal) }
    return ($Text -cmatch '^\[redacted:[a-z0-9-]*(:[0-9a-f]{0,8})?$')
}

# --------------------------------------------------------------------------
# Size bound, applied to the ALREADY-REDACTED text (T-317).
#
# The bound must never be applied to the raw input before the rules have run. A secret that
# straddles a raw-byte cut loses exactly the tail its rule needs in order to match
# (`github-token` wants 20+ chars after the prefix, `aws-access-key` exactly 16, `jwt` three
# segments, ...), so the cut head stops matching any rule and survives VERBATIM in the
# artifact - a partial secret leak in the one place this tool exists to prevent one, and the
# closer the cut sits to the end of the token the more of the secret leaks. Redacting first
# makes the cut harmless: by this point every recognized secret is already an opaque
# `[redacted:...]` marker, so a cut can only split ordinary text or a marker, never expose
# secret material.
#
# Bounding the WORK (how much text the rules have to scan) is therefore deliberately NOT this
# function's job and belongs to the caller (tools/supervisor.ps1, for instance, caps a
# captured stream before it is ever handed here): any pre-redaction byte cut re-opens the leak
# described above, so the pipeline always scans everything it was given and bounds only what
# it emits.
#
# The cut itself is still made carefully, now purely for readability:
#   * always on a UTF-8 character boundary, surrogate pairs included (a raw byte slice decodes
#     a split multibyte char as U+FFFD);
#   * preferably at the nearest line break, else at the nearest space/tab, within a bounded
#     lookback - so the visible tail is not half a word and, since no marker contains
#     whitespace, never half a marker;
#   * otherwise exactly at the character boundary, with a half marker dropped explicitly.
#
# Returns the kept text (WITHOUT the `[truncated: ...]` note, which the caller appends), a
# Truncated flag, and the kept / total UTF-8 byte counts of the redacted text.
# --------------------------------------------------------------------------
function Get-BoundedRedactedText {
    param([string]$Text, [int]$MaxBytes)
    if ($null -eq $Text) { $Text = '' }
    $enc = [System.Text.Encoding]::UTF8
    $total = $enc.GetByteCount($Text)
    if ($MaxBytes -le 0 -or $total -le $MaxBytes) {
        return [pscustomobject]@{ Text = $Text; Truncated = $false; KeptBytes = $total; TotalBytes = $total }
    }

    # Longest character prefix that fits the byte budget: the encoder converts as many WHOLE
    # characters as fit into a MaxBytes-sized buffer and reports how many it consumed, so a
    # multibyte character (or a surrogate pair) is never split.
    $chars = $Text.ToCharArray()
    $buffer = New-Object 'byte[]' $MaxBytes
    $charsUsed = 0
    $bytesUsed = 0
    $completed = $false
    $enc.GetEncoder().Convert($chars, 0, $chars.Length, $buffer, 0, $buffer.Length, $true,
        [ref]$charsUsed, [ref]$bytesUsed, [ref]$completed)
    $cut = $charsUsed
    if ($cut -gt $chars.Length) { $cut = $chars.Length }
    if ($cut -lt 0) { $cut = 0 }
    # Defensive: never end on a lone high surrogate (a flushed encoder emits its fallback
    # rather than consuming one, but the kept text must be well-formed regardless).
    if ($cut -gt 0 -and [char]::IsHighSurrogate($chars[$cut - 1])) { $cut-- }

    # Prefer a clean break (line break first, then space/tab) within the bounded lookback. The
    # lookback is also capped at a quarter of the budget so a cosmetic break never throws away
    # a meaningful share of a small --max-bytes.
    $lookback = [Math]::Min($script:BreakLookback, [int][Math]::Ceiling($cut / 4))
    $lookbackStart = [Math]::Max(0, $cut - $lookback)
    $breakAt = -1
    for ($i = $cut; $i -ge $lookbackStart; $i--) {
        if ($i -lt $chars.Length -and $chars[$i] -eq "`n") { $breakAt = $i; break }
    }
    if ($breakAt -lt 0) {
        for ($i = $cut; $i -ge $lookbackStart; $i--) {
            if ($i -lt $chars.Length -and ($chars[$i] -eq ' ' -or $chars[$i] -eq "`t")) { $breakAt = $i; break }
        }
    }
    if ($breakAt -ge 0) { $cut = $breakAt }

    $kept = $Text.Substring(0, $cut)
    # Never end on half a marker (cosmetic only - a marker's text is a category plus a hash,
    # so a fragment of it carries no secret material, but a dangling `[redac` is noise).
    $open = $kept.LastIndexOf('[')
    if ($open -ge 0 -and $kept.IndexOf(']', $open) -lt 0 -and (Test-MarkerHead $kept.Substring($open))) {
        $kept = $kept.Substring(0, $open)
    }

    return [pscustomobject]@{ Text = $kept; Truncated = $true; KeptBytes = $enc.GetByteCount($kept); TotalBytes = $total }
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

    # 2. decode the WHOLE input as UTF-8. The size bound is deliberately NOT applied here: it
    #    runs in step 7, over the redacted text, so that a secret straddling the cut is matched
    #    (and replaced) as a whole before anything is dropped (T-317).
    $text = [System.Text.Encoding]::UTF8.GetString($Bytes)

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

    # 6. substitute the opaque placeholders back to their final markers. This happens BEFORE
    #    the size bound so the bound measures, and cuts, exactly the text that is emitted.
    $text = Restore-Markers $state $text

    # 7. size bound, applied to the redacted text; the drop is still recorded in the report and
    #    in a visible note (which, like before, is appended beyond the budget so it can never
    #    be the part that gets cut). `redacted_bytes` is what step 4/5 produced, `kept_bytes`
    #    what is actually shown, so the two numbers stay comparable.
    $bounded = Get-BoundedRedactedText -Text $text -MaxBytes $MaxBytes
    if ($bounded.Truncated) {
        $report.truncated = $true
        $text = $bounded.Text + "`n[truncated: original_bytes=$($Bytes.Length) redacted_bytes=$($bounded.TotalBytes) kept_bytes=$($bounded.KeptBytes) sha256=$($report.raw_sha256)]"
    }

    # 8. derive the report from what is actually visible in the output (authoritative, no
    #    double count).
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
    exit (Resolve-CatchExit $_ 'RDCERR' 'redaction' 'REDACTION_DEBUG')
}
