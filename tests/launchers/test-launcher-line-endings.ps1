# ci:posix - byte-level source invariant; no Windows command processor required.
$ErrorActionPreference = 'Stop'

$launchers = Join-Path $PSScriptRoot '..\..\launchers'
$failures = New-Object System.Collections.Generic.List[string]
$strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)

foreach ($file in Get-ChildItem -LiteralPath $launchers -Filter '*.cmd' -File | Sort-Object Name) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $failures.Add("$($file.Name): UTF-8 BOM is forbidden")
    }
    try {
        [void]$strictUtf8.GetString($bytes)
    } catch {
        $failures.Add("$($file.Name): invalid UTF-8")
    }

    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 0x0A -and ($i -eq 0 -or $bytes[$i - 1] -ne 0x0D)) {
            $failures.Add("$($file.Name): bare LF at byte $i")
            break
        }
        if ($bytes[$i] -eq 0x0D -and ($i + 1 -ge $bytes.Length -or $bytes[$i + 1] -ne 0x0A)) {
            $failures.Add("$($file.Name): bare CR at byte $i")
            break
        }
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { [Console]::Error.WriteLine("FAIL - $_") }
    exit 1
}

Write-Host 'OK - all Windows launchers are UTF-8 without BOM and use CRLF exclusively.'
exit 0
