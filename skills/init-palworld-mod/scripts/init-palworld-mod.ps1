[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectPath,

    [Parameter(Mandatory = $true)]
    [string]$ModName,

    [ValidateSet('Paks', 'LogicMods', 'Lua', 'PalSchema')]
    [string]$ModType = 'Paks',

    [string]$PackageName,
    [string]$Author = 'Unknown',
    [int]$MinRevision = 0,
    [string]$GamePath = '',
    [string]$RepakPath = '',
    [ValidateSet('Development', 'Production')]
    [string]$BuildMode = 'Development',
    [switch]$DisableDebugNotifications,
    [switch]$DisableDebugConsole,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$debugEnabled = $BuildMode -eq 'Development'
$debugNotifications = $debugEnabled -and -not $DisableDebugNotifications
$debugConsole = $debugEnabled -and -not $DisableDebugConsole

function ConvertTo-PackageName {
    param([string]$Value)
    $normalized = -join ($Value.ToCharArray() | Where-Object { [char]::IsLetterOrDigit($_) })
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw 'PackageName must contain at least one alphanumeric character.'
    }
    return $normalized
}

$resolvedProject = [System.IO.Path]::GetFullPath($ProjectPath)
$resolvedRoot = [System.IO.Path]::GetPathRoot($resolvedProject)
if ($resolvedProject -eq $resolvedRoot) {
    throw "Refusing to initialize a filesystem root: $resolvedProject"
}

if ([string]::IsNullOrWhiteSpace($PackageName)) {
    $PackageName = ConvertTo-PackageName -Value $ModName
} elseif ($PackageName -notmatch '^[A-Za-z0-9]+$') {
    throw 'PackageName may contain only ASCII letters and digits.'
}

if (Test-Path -LiteralPath $resolvedProject) {
    $existing = @(Get-ChildItem -Force -LiteralPath $resolvedProject)
    if ($existing.Count -gt 0 -and -not $Force) {
        throw "Project directory is not empty. Choose another path or explicitly authorize -Force: $resolvedProject"
    }
} else {
    New-Item -ItemType Directory -Path $resolvedProject | Out-Null
}

$directories = @(
    'docs',
    'src',
    'work\original',
    'work\staging',
    'dist',
    "package\$PackageName"
)

$typeFolder = switch ($ModType) {
    'Paks' { 'Paks' }
    'LogicMods' { 'LogicMods' }
    'Lua' { 'Scripts' }
    'PalSchema' { 'PalSchema' }
}
$directories += "package\$PackageName\$typeFolder"

foreach ($relative in $directories) {
    New-Item -ItemType Directory -Force -Path (Join-Path $resolvedProject $relative) | Out-Null
}

$projectConfig = [ordered]@{
    SchemaVersion = 1
    ModName = $ModName
    PackageName = $PackageName
    ModType = $ModType
    GamePath = $GamePath
    RepakPath = $RepakPath
    StagingPath = 'work/staging'
    DistPath = 'dist'
    WorkshopItemId = $null
    Diagnostics = [ordered]@{
        Enabled = $debugEnabled
        Notifications = $debugNotifications
        Console = $debugConsole
    }
}
$projectConfig | ConvertTo-Json -Depth 5 |
    Set-Content -Encoding utf8 -LiteralPath (Join-Path $resolvedProject 'mod-project.json')

$installType = if ($ModType -eq 'Lua') { 'Lua' } else { $ModType }
$target = "./$typeFolder/"
$info = [ordered]@{
    ModName = $ModName
    PackageName = $PackageName
    Thumbnail = 'thumbnail.png'
    Version = '0.1.0-dev.1'
    DebugMode = $debugEnabled
    MinRevision = $MinRevision
    Author = $Author
    Dependencies = @()
    Tags = @()
    InstallRule = @(
        [ordered]@{
            Type = $installType
            Targets = @($target)
        }
    )
}
$info | ConvertTo-Json -Depth 10 |
    Set-Content -Encoding utf8 -LiteralPath (Join-Path $resolvedProject "package\$PackageName\Info.json")

if ($ModType -eq 'Lua') {
    $debugEnabledLiteral = $debugEnabled.ToString().ToLowerInvariant()
    $debugNotificationsLiteral = $debugNotifications.ToString().ToLowerInvariant()
    $debugConsoleLiteral = $debugConsole.ToString().ToLowerInvariant()
    $luaEntryPoint = @"
local MOD_NAME = "$PackageName"

local CONFIG = {
    -- Keep diagnostics in source. Disable debug_enabled for production.
    debug_enabled = $debugEnabledLiteral,
    debug_notifications = $debugNotificationsLiteral,
    debug_console = $debugConsoleLiteral,
}

local function debug_log(message)
    if not CONFIG.debug_enabled then
        return
    end

    local text = "[" .. MOD_NAME .. "] " .. tostring(message)
    if CONFIG.debug_console then
        print(text .. "\n")
    end

    if CONFIG.debug_notifications then
        pcall(function()
            local manager = FindFirstOf("PalLogManager")
            if manager ~= nil then
                manager:AddLog(1, FText(text), {})
            end
        end)
    end
end

debug_log("development diagnostics enabled")
"@
    Set-Content -Encoding utf8 -LiteralPath (
        Join-Path $resolvedProject "package\$PackageName\Scripts\main.lua"
    ) -Value $luaEntryPoint
}

$gitignore = @'
tools/
work/original/
work/staging/
dist/*
!dist/.gitkeep
*.pak.disabled
'@
Set-Content -Encoding utf8 -LiteralPath (Join-Path $resolvedProject '.gitignore') -Value $gitignore

$testing = @"
# Testing

- Game revision:
- Build version: 0.1.0-dev.1
- Build mode: $BuildMode
- Loader DebugMode: $debugEnabled
- Runtime debug notifications: $debugNotifications
- Runtime debug console: $debugConsole
- Source archive hash:
- Installed archive hash:
- Expected observable result:
- Actual result:
- Screenshot/log:
"@
Set-Content -Encoding utf8 -LiteralPath (Join-Path $resolvedProject 'docs\testing.md') -Value $testing

$research = @"
# Research

## Goal

$ModName

## Candidate assets or hooks

## Dependencies

## Compatibility notes
"@
Set-Content -Encoding utf8 -LiteralPath (Join-Path $resolvedProject 'docs\research.md') -Value $research

New-Item -ItemType File -Force -Path (Join-Path $resolvedProject 'dist\.gitkeep') | Out-Null

[pscustomobject]@{
    ProjectPath = $resolvedProject
    ModName = $ModName
    PackageName = $PackageName
    ModType = $ModType
    PackagePath = (Join-Path $resolvedProject "package\$PackageName")
} | Format-List
