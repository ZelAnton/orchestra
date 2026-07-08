# Проверяет инварианты агентских .md-файлов репозитория Orchestra:
#   - YAML frontmatter начинается с самого первого байта файла (без предшествующих
#     пустых строк);
#   - файл хранится как UTF-8 без BOM;
#   - обязательные поля name/description присутствуют во frontmatter и непусты;
#   - поле name совпадает с именем файла без расширения;
#   - имя файла (и, соответственно, name) — в snake_case.
#
# Запуск: pwsh -File tools/validate-agents.ps1 (или powershell -File tools\validate-agents.ps1).
# Печатает перечень нарушений (файл — конкретное нарушение) и завершается кодом 1, если
# нарушения найдены; при их отсутствии — печатает краткое подтверждение и код 0.
#
# Список исключений ниже — те же самые не-агентские .md в корне репозитория, что и в
# /XF у launchers\cc-sync.cmd и в $excludeNames блока "agent-mirror freshness" у
# launchers\cc-doctor.cmd; при изменении списка не-агентских .md держите все три места
# синхронными.

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir

$excludeNames = @('coder.template.md', 'reviewer.template.md', 'config.example.md', 'AGENTS.md', 'knowledge.md', 'README.md')
$excludePatterns = @('*_PLAN.md', '*_ROADMAP.md', 'Orchestra_Review_*.md')

function Test-Excluded([string]$fileName) {
    if ($excludeNames -contains $fileName) { return $true }
    foreach ($pattern in $excludePatterns) {
        if ($fileName -like $pattern) { return $true }
    }
    return $false
}

# snake_case: строчные латинские буквы/цифры, слова разделены одиночным "_", без
# ведущего/конечного "_" и без пустых компонентов ("__").
$snakeCasePattern = '^[a-z][a-z0-9]*(_[a-z0-9]+)*$'

$agentFiles = Get-ChildItem -Path $repoRoot -File -Filter '*.md' |
    Where-Object { -not (Test-Excluded $_.Name) } |
    Sort-Object Name

if ($agentFiles.Count -eq 0) {
    Write-Host "Агентские .md файлы не найдены в $repoRoot"
    exit 1
}

$violations = @()

foreach ($file in $agentFiles) {
    $relPath = $file.Name
    $baseName = $file.BaseName
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)

    $hasBOM = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    if ($hasBOM) {
        $violations += "${relPath}: файл содержит UTF-8 BOM (должен быть UTF-8 без BOM)"
    }

    $text = [System.Text.Encoding]::UTF8.GetString($bytes)

    $fmMatch = [System.Text.RegularExpressions.Regex]::Match(
        $text,
        '\A---\r?\n(.*?)\r?\n---\r?\n',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)

    if (-not $fmMatch.Success) {
        $violations += "${relPath}: YAML frontmatter не начинается с первого байта файла (или отсутствует)"
        continue
    }

    $frontmatter = $fmMatch.Groups[1].Value
    $fields = @{}
    foreach ($line in ($frontmatter -split '\r?\n')) {
        $kv = [System.Text.RegularExpressions.Regex]::Match($line, '^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$')
        if ($kv.Success -and -not $fields.ContainsKey($kv.Groups[1].Value)) {
            $fields[$kv.Groups[1].Value] = $kv.Groups[2].Value.Trim()
        }
    }

    $name = $fields['name']
    $description = $fields['description']

    if ([string]::IsNullOrWhiteSpace($name)) {
        $violations += "${relPath}: поле 'name' отсутствует или пусто во frontmatter"
    }
    if ([string]::IsNullOrWhiteSpace($description)) {
        $violations += "${relPath}: поле 'description' отсутствует или пусто во frontmatter"
    }

    # -cne: сравнение обязано быть регистрозависимым (обычный -ne в PowerShell по
    # умолчанию не учитывает регистр и не заметил бы, например, "Name" vs "name").
    if (-not [string]::IsNullOrWhiteSpace($name) -and $name -cne $baseName) {
        $violations += "${relPath}: поле 'name' ('$name') не совпадает с именем файла ('$baseName')"
    }

    # -cnotmatch: сопоставление обязано быть регистрозависимым — обычный -notmatch в
    # PowerShell не учитывает регистр и пропустил бы, например, "BadCase" как snake_case.
    if ($baseName -cnotmatch $snakeCasePattern) {
        $violations += "${relPath}: имя файла '$baseName' не в snake_case"
    }
    if (-not [string]::IsNullOrWhiteSpace($name) -and $name -cnotmatch $snakeCasePattern) {
        $violations += "${relPath}: поле 'name' ('$name') не в snake_case"
    }
}

if ($violations.Count -gt 0) {
    Write-Host "Найдены нарушения инвариантов агентских файлов ($($violations.Count)):"
    foreach ($v in $violations) {
        Write-Host "  - $v"
    }
    exit 1
}

Write-Host "OK: проверено агентских файлов: $($agentFiles.Count), нарушений не найдено."
exit 0
