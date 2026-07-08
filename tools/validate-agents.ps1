# Проверяет инварианты агентских .md-файлов репозитория Orchestra:
#   - YAML frontmatter начинается с самого первого байта файла (без предшествующих
#     пустых строк);
#   - файл хранится как UTF-8 без BOM;
#   - обязательные поля name/description присутствуют во frontmatter и непусты;
#   - поле name совпадает с именем файла без расширения;
#   - имя файла (и, соответственно, name) — в snake_case;
#   - поле permissionMode присутствует и равно строго "auto" (не "acceptEdits"/
#     "bypassPermissions" — это защита от прошлой реальной регрессии, см. AGENTS.md);
#   - поле model присутствует (конкретное значение не проверяется).
#
# Запуск: pwsh -File tools/validate-agents.ps1 (или powershell -File tools\validate-agents.ps1).
# Печатает перечень нарушений (файл — конкретное нарушение) и завершается кодом 1, если
# нарушения найдены; при их отсутствии — печатает краткое подтверждение и код 0.
#
# Проверяется каталог agents/ (агентские определения; документация — AGENTS.md,
# knowledge.md, README.md, config.example.md, plans\ — живёт в корне и здесь не
# сканируется). Единственное исключение внутри agents/ — два шаблона генератора
# (coder.template.md, reviewer.template.md): их frontmatter содержит плейсхолдер
# "name: {{NAME}}", поэтому под инварианты настоящих агентов они не подпадают. Тот же
# сокращённый набор исключений используют /XF у launchers\cc-sync.cmd(.sh) и блок
# "agent-mirror freshness" у launchers\cc-doctor.cmd(.sh); держите все места синхронными.

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
$agentsDir = Join-Path $repoRoot 'agents'

$excludeNames = @('coder.template.md', 'reviewer.template.md')

function Test-Excluded([string]$fileName) {
    return ($excludeNames -contains $fileName)
}

# snake_case: строчные латинские буквы/цифры, слова разделены одиночным "_", без
# ведущего/конечного "_" и без пустых компонентов ("__").
$snakeCasePattern = '^[a-z][a-z0-9]*(_[a-z0-9]+)*$'

$agentFiles = Get-ChildItem -Path $agentsDir -File -Filter '*.md' -ErrorAction SilentlyContinue |
    Where-Object { -not (Test-Excluded $_.Name) } |
    Sort-Object Name

if ($agentFiles.Count -eq 0) {
    Write-Host "Агентские .md файлы не найдены в $agentsDir"
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
    $model = $fields['model']
    $permissionMode = $fields['permissionMode']

    if ([string]::IsNullOrWhiteSpace($name)) {
        $violations += "${relPath}: поле 'name' отсутствует или пусто во frontmatter"
    }
    if ([string]::IsNullOrWhiteSpace($description)) {
        $violations += "${relPath}: поле 'description' отсутствует или пусто во frontmatter"
    }
    if ([string]::IsNullOrWhiteSpace($model)) {
        $violations += "${relPath}: поле 'model' отсутствует или пусто во frontmatter"
    }

    # -cne: сравнение обязано быть регистрозависимым — permissionMode должен быть
    # именно "auto", а не, например, "Auto" или "AUTO".
    if ([string]::IsNullOrWhiteSpace($permissionMode)) {
        $violations += "${relPath}: поле 'permissionMode' отсутствует или пусто во frontmatter (ожидается 'auto')"
    } elseif ($permissionMode -cne 'auto') {
        $violations += "${relPath}: поле 'permissionMode' ('$permissionMode') должно быть строго 'auto' (не 'acceptEdits'/'bypassPermissions')"
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
