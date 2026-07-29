[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Info", "List", "Search", "Get", "HashList")]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [string]$PakPath,

    [string]$RepakPath,
    [string]$Pattern,
    [switch]$Literal,
    [int]$Limit = 0,
    [string]$Entry,
    [string]$OutputDirectory,
    [switch]$IncludeCompanions,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Resolve-Repak {
    param([string]$ExplicitPath)

    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $candidates.Add($ExplicitPath)
    }

    $repositoryRoot = [System.IO.Path]::GetFullPath(
        (Join-Path $PSScriptRoot "..\..\..")
    )
    $candidates.Add((Join-Path $repositoryRoot "tools\repak\repak.exe"))

    $command = Get-Command "repak.exe" -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        $candidates.Add($command.Source)
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "repak.exe was not found. Install the pinned portable build described in references/tool-selection.md or pass -RepakPath."
}

function Assert-NoQuote {
    param(
        [string]$Value,
        [string]$Label
    )

    if ($Value.Contains('"')) {
        throw "$Label may not contain a double quote."
    }
}

function Invoke-RepakText {
    param(
        [string]$Executable,
        [string[]]$Arguments
    )

    $output = & $Executable @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "repak failed with exit code $LASTEXITCODE`: $($output -join [Environment]::NewLine)"
    }
    return @($output | ForEach-Object { $_.ToString() })
}

function Select-Matches {
    param(
        [string[]]$Entries,
        [string]$SearchPattern,
        [bool]$UseLiteral,
        [int]$Maximum
    )

    $selected = $Entries
    if (-not [string]::IsNullOrWhiteSpace($SearchPattern)) {
        if ($UseLiteral) {
            $selected = $selected | Where-Object {
                $_.IndexOf(
                    $SearchPattern,
                    [System.StringComparison]::OrdinalIgnoreCase
                ) -ge 0
            }
        }
        else {
            $selected = $selected | Where-Object { $_ -match $SearchPattern }
        }
    }

    if ($Maximum -gt 0) {
        return @($selected | Select-Object -First $Maximum)
    }
    return @($selected)
}

function Invoke-RepakGet {
    param(
        [string]$Executable,
        [string]$Archive,
        [string]$InternalPath,
        [string]$Destination
    )

    Assert-NoQuote -Value $Executable -Label "repak path"
    Assert-NoQuote -Value $Archive -Label "PAK path"
    Assert-NoQuote -Value $InternalPath -Label "entry path"

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.Arguments = 'get "' + $Archive + '" "' + $InternalPath + '"'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "Unable to start repak."
    }

    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null

    $stream = [System.IO.File]::Open(
        $Destination,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    try {
        $process.StandardOutput.BaseStream.CopyTo($stream)
    }
    finally {
        $stream.Dispose()
    }

    $errorText = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw "repak get failed for '$InternalPath': $errorText"
    }
}

$pak = (Resolve-Path -LiteralPath $PakPath).Path
if ([System.IO.Path]::GetExtension($pak) -ne ".pak") {
    throw "PakPath must identify a .pak file."
}

$repak = Resolve-Repak -ExplicitPath $RepakPath

if ($Mode -eq "Info") {
    Invoke-RepakText -Executable $repak -Arguments @("info", $pak)
    exit 0
}

if ($Mode -eq "List" -or $Mode -eq "Search") {
    if ($Mode -eq "Search" -and [string]::IsNullOrWhiteSpace($Pattern)) {
        throw "Search mode requires -Pattern."
    }

    $entries = Invoke-RepakText -Executable $repak -Arguments @("list", $pak)
    $matches = Select-Matches `
        -Entries $entries `
        -SearchPattern $Pattern `
        -UseLiteral $Literal.IsPresent `
        -Maximum $Limit

    $matches
    $matchSummary = "Matched {0} of {1} archive entries." -f @(
        $matches.Count,
        $entries.Count
    )
    [Console]::Error.WriteLine($matchSummary)
    exit 0
}

if ($Mode -eq "HashList") {
    Invoke-RepakText -Executable $repak -Arguments @("hash-list", $pak)
    exit 0
}

if ([string]::IsNullOrWhiteSpace($Entry)) {
    throw "Get mode requires -Entry."
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    throw "Get mode requires -OutputDirectory."
}
if ([System.IO.Path]::IsPathRooted($Entry) -or $Entry.Contains("..")) {
    throw "Entry must be a normalized archive-relative path."
}

$allEntries = Invoke-RepakText -Executable $repak -Arguments @("list", $pak)
$entrySet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
foreach ($archiveEntry in $allEntries) {
    [void]$entrySet.Add($archiveEntry)
}
if (-not $entrySet.Contains($Entry)) {
    throw "Archive entry not found: $Entry"
}

$requestedEntries = [System.Collections.Generic.List[string]]::new()
$requestedEntries.Add($Entry)
if ($IncludeCompanions -and
    [System.IO.Path]::GetExtension($Entry) -eq ".uasset") {
    $base = $Entry.Substring(0, $Entry.Length - ".uasset".Length)
    foreach ($extension in @(".uexp", ".ubulk", ".uptnl")) {
        $companion = $base + $extension
        if ($entrySet.Contains($companion)) {
            $requestedEntries.Add($companion)
        }
    }
}

$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

foreach ($archiveEntry in $requestedEntries) {
    $relativePath = $archiveEntry.Replace(
        "/",
        [System.IO.Path]::DirectorySeparatorChar
    )
    $destination = [System.IO.Path]::GetFullPath(
        (Join-Path $outputRoot $relativePath)
    )
    $requiredPrefix = $outputRoot.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $destination.StartsWith(
        $requiredPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Resolved output escaped OutputDirectory: $destination"
    }

    if (Test-Path -LiteralPath $destination) {
        if (-not $Force) {
            throw "Output already exists; pass -Force to replace it: $destination"
        }
        Remove-Item -LiteralPath $destination -Force
    }

    Invoke-RepakGet `
        -Executable $repak `
        -Archive $pak `
        -InternalPath $archiveEntry `
        -Destination $destination

    $hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    [pscustomobject]@{
        Entry = $archiveEntry
        Output = $destination
        Bytes = (Get-Item -LiteralPath $destination).Length
        SHA256 = $hash
    }
}
