$ErrorActionPreference = "Stop"

$skillRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

$required = @(
    "SKILL.md",
    "agents\openai.yaml",
    "scripts\inspect-palworld-pak.ps1",
    "references\tool-selection.md"
)

foreach ($path in $required) {
    $absolutePath = Join-Path $skillRoot $path
    if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
        throw "Missing skill file: $path"
    }
}

$tokens = $null
$parserErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $skillRoot "scripts\inspect-palworld-pak.ps1"),
    [ref]$tokens,
    [ref]$parserErrors
)
if ($parserErrors.Count -gt 0) {
    throw ($parserErrors | ForEach-Object Message) -join [Environment]::NewLine
}

Write-Output "Validated inspect-palworld-pak skill files and PowerShell syntax."
