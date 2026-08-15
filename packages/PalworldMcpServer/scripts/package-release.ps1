[CmdletBinding()]
param(
    [string]$Version = "0.9.6"
)

$ErrorActionPreference = "Stop"

$packageRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$repositoryRoot = (Resolve-Path (Join-Path $packageRoot "..\..")).Path
$projectPath = Join-Path $packageRoot "src\PalworldMcpServer\PalworldMcpServer.csproj"
$distRoot = Join-Path $packageRoot "dist"
$artifactName = "palworld-mcp-server-v$Version-win-x64"
$stagingRoot = Join-Path $distRoot $artifactName
$archivePath = Join-Path $distRoot "$artifactName.zip"
$checksumPath = Join-Path $distRoot "SHA256SUMS.txt"

$resolvedDistRoot = [System.IO.Path]::GetFullPath($distRoot)
$resolvedPackageRoot = [System.IO.Path]::GetFullPath($packageRoot)
if (-not $resolvedDistRoot.StartsWith(
    $resolvedPackageRoot + [System.IO.Path]::DirectorySeparatorChar,
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    throw "Refusing to replace a dist directory outside the MCP package."
}

if (-not (Test-Path -LiteralPath $resolvedDistRoot)) {
    New-Item -ItemType Directory -Path $resolvedDistRoot -Force | Out-Null
}

$resolvedStagingRoot = [System.IO.Path]::GetFullPath($stagingRoot)
if (-not $resolvedStagingRoot.StartsWith(
    $resolvedDistRoot + [System.IO.Path]::DirectorySeparatorChar,
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    throw "Refusing to replace a staging directory outside the package dist directory."
}

if (Test-Path -LiteralPath $resolvedStagingRoot) {
    Remove-Item -LiteralPath $resolvedStagingRoot -Recurse -Force
}
foreach ($generatedFile in @($archivePath, $checksumPath, (Join-Path $distRoot "artifact-manifest.json"))) {
    if (Test-Path -LiteralPath $generatedFile) {
        Remove-Item -LiteralPath $generatedFile -Force
    }
}
New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

dotnet publish $projectPath `
    --configuration Release `
    --runtime win-x64 `
    --self-contained true `
    -p:Version=$Version `
    -p:PublishSingleFile=true `
    --output $stagingRoot
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE."
}

$executablePath = Join-Path $stagingRoot "palworld-mcp-server.exe"
if (-not (Test-Path -LiteralPath $executablePath)) {
    throw "Published executable was not created at $executablePath."
}

Get-ChildItem -LiteralPath $stagingRoot -Filter "*.pdb" -File |
    Remove-Item -Force

Copy-Item -LiteralPath (Join-Path $packageRoot "palworld-mcp.local.example.json") `
    -Destination (Join-Path $stagingRoot "palworld-mcp.local.example.json")
Copy-Item -LiteralPath (Join-Path $packageRoot "README.md") `
    -Destination (Join-Path $stagingRoot "README.md")
Copy-Item -LiteralPath (Join-Path $repositoryRoot "LICENSE") `
    -Destination (Join-Path $stagingRoot "LICENSE")
Copy-Item -LiteralPath (Join-Path $packageRoot "THIRD-PARTY-NOTICES.md") `
    -Destination (Join-Path $stagingRoot "THIRD-PARTY-NOTICES.md")

$bridgeSource = Join-Path $repositoryRoot `
    "packages\PalworldCompanionBridge\package\PalworldCompanionBridge"
$bridgeDestination = Join-Path $stagingRoot `
    "ue4ss-mod\PalworldCompanionBridge"
if (-not (Test-Path -LiteralPath $bridgeSource)) {
    throw "The Palworld Companion Bridge payload was not found at $bridgeSource."
}
New-Item -ItemType Directory -Path (Split-Path $bridgeDestination) -Force |
    Out-Null
Copy-Item -LiteralPath $bridgeSource -Destination $bridgeDestination -Recurse

Compress-Archive -LiteralPath $stagingRoot -DestinationPath $archivePath -CompressionLevel Optimal

$archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
"$archiveHash  $([System.IO.Path]::GetFileName($archivePath))" |
    Set-Content -LiteralPath $checksumPath -Encoding ascii

$manifest = [ordered]@{
    name = "palworld-mcp-server"
    version = $Version
    runtime = "win-x64"
    minimumWindowsVersion = "10.0.17763.0"
    selfContained = $true
    palCalcVersion = "1.19.1"
    companionBridgeVersion = "0.1.0-dev.115"
    executable = "palworld-mcp-server.exe"
    sha256 = $archiveHash
}
$manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $distRoot "artifact-manifest.json")

Write-Host "Created $archivePath"
Write-Host "SHA-256 $archiveHash"
