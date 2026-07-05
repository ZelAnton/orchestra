# Генерирует coder.md, coder_fast.md, coder_deep.md из общего coder.template.md.
# Запускать после правки шаблона — три файла будут перезаписаны целиком.
# Тела всех трёх файлов идентичны; различаются только фронтматтер-поля ниже.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$templatePath = Join-Path $root "coder.template.md"
$template = Get-Content -Raw -Encoding UTF8 $templatePath

$variants = @(
    @{
        File = "coder_fast.md"
        Name = "coder_fast"
        Model = "sonnet"
        Effort = "medium"
        Description = "Быстрый листовой исполнитель простых задач низкой ответственности (sonnet/medium). Пишет код по уже спланированной задаче в .work/tasks/<T-ID>/task.md и самопроверяется; по запросу processor устраняет переданные ему находки ревью (R- по задаче или F- интеграционные) либо чинит точечный CI-фикс. Не гоняет ревью, не коммитит, не трогает очередь — цикл ревью, коммит, слияние и учёт ведёт processor. Один из трёх уровней исполнителей: coder_fast (простые) / coder (стандартные) / coder_deep (сложные, ответственные)."
    },
    @{
        File = "coder.md"
        Name = "coder"
        Model = "sonnet"
        Effort = "high"
        Description = "Стандартный листовой исполнитель (sonnet/high). Пишет код по уже спланированной задаче в .work/tasks/<T-ID>/task.md и самопроверяется; по запросу processor устраняет переданные ему находки ревью (R- по задаче или F- интеграционные) либо чинит точечный CI-фикс. Не гоняет ревью, не коммитит, не трогает очередь — цикл ревью, коммит, слияние и учёт ведёт processor. Один из трёх уровней исполнителей: coder_fast (простые) / coder (стандартные) / coder_deep (сложные, ответственные)."
    },
    @{
        File = "coder_deep.md"
        Name = "coder_deep"
        Model = "opus"
        Effort = "xhigh"
        Description = "Листовой исполнитель сложных, архитектурных и высокоответственных задач (opus/xhigh). Пишет код по уже спланированной задаче в .work/tasks/<T-ID>/task.md и самопроверяется; по запросу processor устраняет переданные ему находки ревью (R- по задаче или F- интеграционные) либо чинит точечный CI-фикс. Не гоняет ревью, не коммитит, не трогает очередь — цикл ревью, коммит, слияние и учёт ведёт processor. Один из трёх уровней исполнителей: coder_fast (простые) / coder (стандартные) / coder_deep (сложные, ответственные)."
    }
)

foreach ($v in $variants) {
    $out = $template
    $out = $out.Replace('{{NAME}}', $v.Name)
    $out = $out.Replace('{{MODEL}}', $v.Model)
    $out = $out.Replace('{{EFFORT}}', $v.Effort)
    $out = $out.Replace('{{DESCRIPTION}}', $v.Description)
    $outPath = Join-Path $root $v.File
    # Пишем UTF-8 БЕЗ BOM явно: Set-Content -Encoding UTF8 в Windows PowerShell 5.1
    # добавляет BOM, а BOM перед `---` frontmatter ломает парсинг агента.
    [System.IO.File]::WriteAllText($outPath, $out, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Сгенерирован: $($v.File)"
}
