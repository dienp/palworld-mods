[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$version = "1.19.1"
$expectedSha256 = "ee6d1853c835d4c0bf697e3dbe95967521231757ba9bf75d129c2e382c2de8a7"
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$installRoot = Join-Path $repositoryRoot "tools\palcalc"
$versionFile = Join-Path $installRoot ".palcalc-version"

if ((Test-Path -LiteralPath $versionFile) -and
    ((Get-Content -Raw -LiteralPath $versionFile).Trim() -eq $version)) {
    Write-Host "PalCalc $version is already installed."
    exit 0
}

$archivePath = Join-Path ([System.IO.Path]::GetTempPath()) "PalCalc-NoBundle-$version.zip"
$downloadUrl = "https://github.com/tylercamp/palcalc/releases/download/v$version/PalCalc-NoBundle.zip"

if (-not (Test-Path -LiteralPath $archivePath)) {
    Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath
}

$actualSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualSha256 -ne $expectedSha256) {
    throw "PalCalc archive checksum mismatch. Expected $expectedSha256, received $actualSha256."
}

$resolvedInstallRoot = [System.IO.Path]::GetFullPath($installRoot)
$resolvedToolsRoot = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot "tools"))
if (-not $resolvedInstallRoot.StartsWith($resolvedToolsRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to replace PalCalc outside the repository tools directory."
}

if (Test-Path -LiteralPath $resolvedInstallRoot) {
    Remove-Item -LiteralPath $resolvedInstallRoot -Recurse -Force
}

New-Item -ItemType Directory -Path $resolvedInstallRoot | Out-Null
Expand-Archive -LiteralPath $archivePath -DestinationPath $resolvedInstallRoot
Set-Content -LiteralPath $versionFile -Value $version -NoNewline

Write-Host "Installed PalCalc $version at $resolvedInstallRoot."
