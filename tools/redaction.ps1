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
         The `--max-bytes` size bound is never applied to the raw input ahead of the rules:
         cutting raw bytes first slices a secret that straddles the cut into a head no rule
         can match any more, and that head then survives verbatim (T-317). Instead the rules
         are handed the budget PLUS a fixed overlap - so a secret that starts just before the
         budget is still seen whole - and the budget is applied afterwards, in SOURCE-offset
         terms, to the already-redacted text: the overlap only ever feeds matching, never
         output. That closes the leak while keeping the work bounded by the budget instead of
         by the (untrusted, unbounded) input. See Get-ScanWindow, Get-SourceBoundedText and
         Get-BoundedRedactedText.

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

    Cost: bounded by `--max-bytes`, NOT by the size of the input. The rules only ever scan the
    leading `--max-bytes + 8192` bytes (Get-ScanWindow), so an untrusted multi-megabyte log
    cannot turn the two backtracking-prone rules (assignment-secret, private-key) into an
    externally driven DoS; whatever lies past that window is only read, hashed and
    binary-sniffed (linear passes). `--max-bytes 0` is an explicit opt-in to scanning
    everything, for a caller that knows its input is already bounded.

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
# Raw bytes handed to the rules BEYOND the --max-bytes budget (T-317 / R-01).
#
# The rules must see the whole of a secret that starts just before the budget, otherwise its
# head survives verbatim (T-317) - but they must not be turned loose on an unbounded untrusted
# input either: `assignment-secret` and `private-key` backtrack polynomially, so "scan
# everything" is an externally driven DoS on a tool that stands on the path of issue/PR bodies
# and CI logs. So the scan window is `--max-bytes + this overlap`, and everything the overlap
# contributes is dropped again before anything is emitted: the overlap feeds MATCHING only.
#
# 8 KiB is comfortably larger than any single-line credential shape the rules recognize (JWT,
# bearer/assignment value, header line) and than a PEM block up to RSA-8192. A token that still
# runs past the window is not emitted either - see Get-SafeHeadChars and the unterminated-PEM
# guard in Invoke-Pipeline - so the overlap size is a completeness/cost trade-off, never the
# difference between a leak and no leak.
$script:ScanOverlap = 8192
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
# Largest length <= $Length that does not end in the middle of a UTF-8 sequence: walk back over
# continuation bytes (10xxxxxx) to the lead byte and keep it only if its whole sequence fits.
# Used to cut the scan window without handing the decoder half a character.
# --------------------------------------------------------------------------
function Get-Utf8SafeLength {
    param([byte[]]$Bytes, [int]$Length)
    if ($Length -le 0) { return 0 }
    if ($Length -ge $Bytes.Length) { return $Bytes.Length }
    $i = $Length - 1
    $steps = 0
    while ($i -ge 0 -and $steps -lt 3 -and (($Bytes[$i] -band 0xC0) -eq 0x80)) { $i--; $steps++ }
    if ($i -lt 0) { return $Length }
    $lead = $Bytes[$i]
    if (($lead -band 0x80) -eq 0x00) { $need = 1 }
    elseif (($lead -band 0xE0) -eq 0xC0) { $need = 2 }
    elseif (($lead -band 0xF0) -eq 0xE0) { $need = 3 }
    elseif (($lead -band 0xF8) -eq 0xF0) { $need = 4 }
    else { return $Length }  # stray continuation byte: not a sequence we can complete anyway
    if (($i + $need) -le $Length) { return $Length }
    return $i
}

# --------------------------------------------------------------------------
# The bounded scan window (T-317 / R-01): the leading `MaxBytes + ScanOverlap` bytes of the raw
# input, cut on a UTF-8 character boundary. This is the ONLY place the amount of work the rules
# do is bounded, and it is deliberately wider than the emitted budget so a secret straddling the
# budget is still matched whole. `MaxBytes = 0` means "no budget" - an explicit caller opt-in to
# scanning everything.
#
# Returns the window bytes and whether anything was left out of them.
# --------------------------------------------------------------------------
function Get-ScanWindow {
    param([byte[]]$Bytes, [int]$MaxBytes)
    if ($MaxBytes -le 0) { return [pscustomobject]@{ Bytes = $Bytes; Cut = $false } }
    $limit = if ($MaxBytes -lt ([int]::MaxValue - $script:ScanOverlap)) { $MaxBytes + $script:ScanOverlap } else { [int]::MaxValue }
    if ($Bytes.Length -le $limit) { return [pscustomobject]@{ Bytes = $Bytes; Cut = $false } }
    $len = Get-Utf8SafeLength $Bytes $limit
    $window = New-Object 'byte[]' $len
    [System.Array]::Copy($Bytes, 0, $window, 0, $len)
    return [pscustomobject]@{ Bytes = $window; Cut = $true }
}

# --------------------------------------------------------------------------
# Longest prefix of $Text, in CHARS, whose UTF-8 encoding fits $MaxBytes: the encoder converts
# as many WHOLE characters as fit into a MaxBytes-sized buffer and reports how many it consumed,
# so a multibyte character (or a surrogate pair) is never split.
# --------------------------------------------------------------------------
function Get-Utf8CharPrefixLength {
    param([string]$Text, [int]$MaxBytes)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    if ($MaxBytes -le 0) { return $Text.Length }
    $enc = [System.Text.Encoding]::UTF8
    if ($enc.GetByteCount($Text) -le $MaxBytes) { return $Text.Length }
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
    # Defensive: never end on a lone high surrogate (a flushed encoder emits its fallback rather
    # than consuming one, but the kept text must be well-formed regardless).
    if ($cut -gt 0 -and [char]::IsHighSurrogate($chars[$cut - 1])) { $cut-- }
    return $cut
}

# --------------------------------------------------------------------------
# Fingerprint: first 8 hex chars of sha256(category ':' value). Deterministic and
# stable (same value+category -> same id, so one secret is recognizable across
# artifacts) but not reversible.
#
# The hasher is created once and reused: this runs once per match, and the rules now run over
# the whole scan window rather than over a pre-cut --max-bytes slice (T-317), so a match-dense
# window means many more calls here - creating and disposing an SHA256 instance per match was
# measurably the most expensive part of the pipeline. The script is single-threaded, and
# ComputeHash resets the instance state per call, so reuse changes nothing about the value.
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

# Each reserved marker also records how many SOURCE characters it replaced, so the size budget
# can later be measured against the pre-redaction text (Get-SourceBoundedText): a marker is
# shorter or longer than the value it stands for, and the budget must bound how much of the
# INPUT is emitted, not how much marker text a match happened to produce.
function New-RedactionState {
    return [pscustomobject]@{
        Markers       = [System.Collections.Generic.List[string]]::new()
        SourceLengths = [System.Collections.Generic.List[int]]::new()
    }
}
function Reserve-Marker {
    param($State, [string]$Value, [string]$Category)
    return (Reserve-Literal $State "[redacted:$Category`:$(Get-Fingerprint $Value $Category)]" $Value.Length)
}
# Reserve an exact literal (used to protect a marker already present in the input so a
# repeated pass restores it verbatim instead of re-fingerprinting it).
function Reserve-Literal {
    param($State, [string]$Literal, [int]$SourceLength = -1)
    if ($SourceLength -lt 0) { $SourceLength = $Literal.Length }
    $idx = $State.Markers.Count
    $State.Markers.Add($Literal)
    $State.SourceLengths.Add($SourceLength)
    return ($script:PhOpen.ToString() + $idx + $script:PhClose.ToString())
}
# Substitute every reserved placeholder back to its marker in ONE pass over the text. A
# per-marker String.Replace loop would be O(markers x text) - fine while the text was pre-cut
# to --max-bytes, but the text handled here is the whole scan window (T-317), and a match-dense
# window (e.g. thousands of e-mail addresses) would make that loop quadratic.
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

# --------------------------------------------------------------------------
# Size budget in SOURCE terms (T-317 / R-01), applied to the redacted text while it is still in
# placeholder form. Keeps everything that came from the first $HeadChars characters of the
# scanned (normalized) text and drops the rest, so the overlap the rules were given can never
# reach the output.
#
# The one deliberate exception is a placeholder that STARTS inside the budget: it is emitted
# whole even when the secret it replaced runs past the budget. That is precisely the T-317 fix -
# the straddling secret leaves an opaque `[redacted:...]` marker instead of a verbatim head -
# and it is bounded (a marker is ~30 chars), so it cannot inflate the output.
#
# Walking the placeholder form is what makes the accounting exact: the text is, by construction,
# literal source characters plus placeholders, and every placeholder knows how many source
# characters it replaced, so no rule ordering or replacement-length effect can shift the budget.
#
# Returns the kept text and whether anything was dropped.
# --------------------------------------------------------------------------
function Get-SourceBoundedText {
    param($State, [string]$Text, [int]$HeadChars)
    if ($HeadChars -lt 0) { return [pscustomobject]@{ Text = $Text; Dropped = $false } }
    $rx = [regex]([regex]::Escape([string]$script:PhOpen) + '([0-9]+)' + [regex]::Escape([string]$script:PhClose))
    $sb = New-Object System.Text.StringBuilder
    $src = 0   # source characters consumed so far
    $pos = 0   # position in $Text
    foreach ($m in $rx.Matches($Text)) {
        $runLen = $m.Index - $pos
        if (($src + $runLen) -ge $HeadChars) {
            [void]$sb.Append($Text.Substring($pos, $HeadChars - $src))
            return [pscustomobject]@{ Text = $sb.ToString(); Dropped = $true }
        }
        [void]$sb.Append($Text.Substring($pos, $runLen))
        $src += $runLen
        $pos = $m.Index + $m.Length
        [void]$sb.Append($m.Value)
        $idx = [int]$m.Groups[1].Value
        if ($idx -ge 0 -and $idx -lt $State.SourceLengths.Count) { $src += $State.SourceLengths[$idx] }
        if ($src -ge $HeadChars) {
            return [pscustomobject]@{ Text = $sb.ToString(); Dropped = ($pos -lt $Text.Length) }
        }
    }
    $runLen = $Text.Length - $pos
    if (($src + $runLen) -gt $HeadChars) {
        [void]$sb.Append($Text.Substring($pos, $HeadChars - $src))
        return [pscustomobject]@{ Text = $sb.ToString(); Dropped = $true }
    }
    [void]$sb.Append($Text.Substring($pos, $runLen))
    return [pscustomobject]@{ Text = $sb.ToString(); Dropped = $false }
}

# --------------------------------------------------------------------------
# Budget adjustment for the case where the SCAN WINDOW itself was cut (i.e. the input is longer
# than budget + overlap). The token that spans the budget may then run past the end of the
# window, where no rule could see it whole - and a rule that cannot match leaves its head
# verbatim, which is the T-317 leak one window further out.
#
# Every whitespace-delimited rule (all of them except the line-anchored authorization header,
# which claims the rest of its line even when the line is cut, and the multi-line PEM block,
# guarded separately in Invoke-Pipeline) is safe as soon as SOME whitespace follows the budget
# inside the window: the token that spans the budget then ended inside the window, so the rules
# saw all of it. If the overlap holds no whitespace at all, that token is unterminated - back
# the budget off to the whitespace before it, dropping the partial token instead of emitting a
# head that may be the start of a secret.
# --------------------------------------------------------------------------
function Get-SafeHeadChars {
    param([string]$Text, [int]$HeadChars)
    if ($HeadChars -le 0 -or $HeadChars -ge $Text.Length) { return $HeadChars }
    $ws = [char[]]@(' ', "`t", "`n")
    if ($Text.IndexOfAny($ws, $HeadChars) -ge 0) { return $HeadChars }
    $back = $Text.LastIndexOfAny($ws, $HeadChars - 1)
    if ($back -lt 0) { return 0 }
    return $back
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
# Bounding the WORK is a separate concern, handled upstream by the scan window (Get-ScanWindow)
# and by the source-offset budget (Get-SourceBoundedText); by the time this runs, the text is
# already redacted and already source-bounded, and this last pass only enforces the byte budget
# on the emitted form - a marker can be longer than the value it replaced, so the redacted text
# can still exceed the budget even though its source did not.
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

    # Longest character prefix that fits the byte budget (never splits a multibyte character
    # or a surrogate pair).
    $chars = $Text.ToCharArray()
    $cut = Get-Utf8CharPrefixLength $Text $MaxBytes

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
        scanned_bytes         = $Bytes.Length
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

    # 2. bounded scan window: the rules get the size budget PLUS an overlap, and decode only
    #    that (T-317 / R-01). Wider than the budget, so a secret starting just before the budget
    #    is still matched whole; bounded, so an untrusted multi-megabyte input cannot dictate
    #    how much work the backtracking-prone rules do. What the overlap contributes is dropped
    #    again in step 5 - it feeds matching only, never output.
    $window = Get-ScanWindow -Bytes $Bytes -MaxBytes $MaxBytes
    $report.scanned_bytes = $window.Bytes.Length
    $text = [System.Text.Encoding]::UTF8.GetString($window.Bytes)

    # 3. normalize line endings to LF and strip C0 control chars (except tab/LF).
    $text = $text -replace "`r`n", "`n" -replace "`r", "`n"
    $before = $text.Length
    $text = [regex]::Replace($text, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '')
    $report.control_chars_removed = $before - $text.Length

    # 3b. the budget in characters of this normalized window: everything from this source offset
    #     on is dropped in step 5. When the window itself was cut, the budget additionally backs
    #     off a token the window may have severed (Get-SafeHeadChars).
    $headChars = -1
    if ($MaxBytes -gt 0) {
        $headChars = Get-Utf8CharPrefixLength $text $MaxBytes
        if ($window.Cut) { $headChars = Get-SafeHeadChars $text $headChars }
    }

    # 4. redaction. First protect any marker already present in the input (so a second
    #    pass is idempotent), then run every rule; both only insert opaque placeholders.
    $state = New-RedactionState
    $text = [regex]::Replace($text, '\[redacted:[a-z0-9-]+:[0-9a-f]{8}\]', {
            param($m) Reserve-Literal $state $m.Value })
    foreach ($rule in (Get-RedactionRules $ConstraintsPath)) {
        $text = Invoke-Rule $text $rule $state
    }

    # 5. drop everything past the budget, measured in SOURCE characters and while the text is
    #    still in placeholder form. A secret straddling the budget is by now a marker that
    #    starts inside it and is kept whole (that is the T-317 fix); nothing the overlap
    #    contributed can reach the output.
    $sourceBounded = Get-SourceBoundedText $state $text $headChars
    $text = $sourceBounded.Text
    $dropped = $sourceBounded.Dropped

    # 5b. a PEM block whose END never arrived inside the window could not be matched as a whole,
    #     so its body would survive verbatim right up to the budget. A block that DID close
    #     inside the window is already an opaque placeholder here, so a surviving literal BEGIN
    #     header means exactly that unfinished case: drop from the header on. Only when the
    #     window is the reason it is unfinished - an unterminated header in a fully scanned input
    #     is left alone, as before.
    if ($window.Cut) {
        $pem = [regex]::Match($text, '-----BEGIN[^\n-]*PRIVATE KEY-----')
        if ($pem.Success) {
            $text = $text.Substring(0, $pem.Index)
            $dropped = $true
        }
    }

    # 6. optional URL defang (so a source URL stays readable/traceable but is not auto-opened).
    if ($Defang) {
        $text = [regex]::Replace($text, '(?i)\b(http|ftp)(s?)://', 'hxxp$2://')
    }

    # 7. substitute the opaque placeholders back to their final markers. This happens BEFORE
    #    the byte bound so the bound measures, and cuts, exactly the text that is emitted.
    $text = Restore-Markers $state $text

    # 8. byte bound on the emitted form: the source is already bounded, but a marker can be
    #    longer than the value it replaced, so the redacted text can still exceed the budget.
    #    Cutting here is harmless - everything is already redacted. Any drop (window, budget or
    #    this last cut) is recorded in the report and in a visible note, which is appended
    #    beyond the budget so it can never be the part that gets cut. `scanned_bytes` is how
    #    much of the input the rules examined, `kept_bytes` what is actually shown.
    $bounded = Get-BoundedRedactedText -Text $text -MaxBytes $MaxBytes
    $text = $bounded.Text
    if ($bounded.Truncated -or $dropped -or $window.Cut) {
        $report.truncated = $true
        $text = $text + "`n[truncated: original_bytes=$($Bytes.Length) scanned_bytes=$($report.scanned_bytes) kept_bytes=$($bounded.KeptBytes) sha256=$($report.raw_sha256)]"
    }

    # 9. derive the report from what is actually visible in the output (authoritative, no
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
