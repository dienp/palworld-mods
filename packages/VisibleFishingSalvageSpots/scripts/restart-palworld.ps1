[CmdletBinding()]
param(
    [switch]$SkipDeploy,
    [string]$GamePath = $env:PALWORLD_GAME_PATH
)

$ErrorActionPreference = 'Stop'

$gameRoot = $GamePath
if (-not $gameRoot) {
    throw 'Pass -GamePath or set PALWORLD_GAME_PATH.'
}
$modsDirectory = Join-Path $gameRoot 'Pal\Content\Paks\~mods'
$projectRoot = Split-Path -Parent $PSScriptRoot
$distDirectory = Join-Path $projectRoot 'dist'
$processNames = @('Palworld', 'Palworld-Win64-Shipping')

Write-Host 'Stopping Palworld...'
Get-Process -Name $processNames -ErrorAction SilentlyContinue |
    Stop-Process -Force

$shutdownDeadline = [DateTime]::UtcNow.AddSeconds(15)
do {
    $runningProcesses = Get-Process -Name $processNames -ErrorAction SilentlyContinue
    if (-not $runningProcesses) {
        break
    }

    Start-Sleep -Milliseconds 250
} while ([DateTime]::UtcNow -lt $shutdownDeadline)

if ($runningProcesses) {
    throw 'Palworld did not stop within 15 seconds.'
}

if (-not $SkipDeploy) {
    $latestPak = Get-ChildItem -LiteralPath $distDirectory -File -Filter 'VisibleFishingSalvageSpots_*_P.pak' |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if (-not $latestPak) {
        throw "No development pak was found in $distDirectory"
    }

    New-Item -ItemType Directory -Force -Path $modsDirectory | Out-Null

    Get-ChildItem -LiteralPath $modsDirectory -File -Filter 'VisibleFishingSalvageSpots_*_P.pak' |
        Where-Object FullName -ne (Join-Path $modsDirectory $latestPak.Name) |
        Remove-Item -Force

    $installedPak = Join-Path $modsDirectory $latestPak.Name
    Copy-Item -LiteralPath $latestPak.FullName -Destination $installedPak -Force

    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $latestPak.FullName).Hash
    $installedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $installedPak).Hash
    if ($sourceHash -ne $installedHash) {
        throw 'The deployed pak failed SHA-256 verification.'
    }

    Write-Host "Deployed $($latestPak.Name)"
    Write-Host "SHA-256 $installedHash"
}

Write-Host 'Launching Palworld through Steam...'
Start-Process 'steam://rungameid/1623730'
