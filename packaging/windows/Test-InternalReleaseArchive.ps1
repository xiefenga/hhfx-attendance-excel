[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ArchivePath,
    [string]$InstallerFileName = "Attendance Ledger Setup.exe",
    [string]$PayloadDirectoryName = "Attendance Ledger Files"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$resolvedArchivePath = [IO.Path]::GetFullPath($ArchivePath)
if (-not (Test-Path -LiteralPath $resolvedArchivePath -PathType Leaf)) {
    throw "Release archive not found: $resolvedArchivePath"
}

$expectedFiles = @(
    "Install Attendance Ledger.cmd"
    "$PayloadDirectoryName/$InstallerFileName"
    "$PayloadDirectoryName/Install Attendance Ledger.cmd"
    "$PayloadDirectoryName/Install-AttendanceLedger.ps1"
    "$PayloadDirectoryName/attendance-ledger.cer"
    "$PayloadDirectoryName/attendance-ledger.cer.thumbprint.txt"
    "$PayloadDirectoryName/attendance-ledger.version.txt"
)

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($resolvedArchivePath)
try {
    $actualFiles = @(
        $archive.Entries |
            Where-Object { -not $_.FullName.EndsWith("/") } |
            ForEach-Object { $_.FullName.Replace("\", "/") } |
            Sort-Object
    )
    $versionEntryPath = "$PayloadDirectoryName/attendance-ledger.version.txt"
    $versionEntry = $archive.GetEntry($versionEntryPath)
    $applicationVersionText = ""
    if ($null -ne $versionEntry) {
        $reader = [IO.StreamReader]::new($versionEntry.Open())
        try {
            $applicationVersionText = $reader.ReadToEnd().Trim()
        }
        finally {
            $reader.Dispose()
        }
    }
}
finally {
    $archive.Dispose()
}

$expectedFiles = @($expectedFiles | Sort-Object)
$differences = @(Compare-Object -ReferenceObject $expectedFiles -DifferenceObject $actualFiles)
if ($actualFiles.Count -ne $expectedFiles.Count -or $differences.Count -ne 0) {
    $expectedListing = $expectedFiles -join [Environment]::NewLine
    $actualListing = $actualFiles -join [Environment]::NewLine
    throw @"
Unexpected release archive layout.
Expected $($expectedFiles.Count) files:
$expectedListing

Actual $($actualFiles.Count) files:
$actualListing
"@
}

[Version]$applicationVersion = $null
if (
    -not [Version]::TryParse(
        $applicationVersionText,
        [ref]$applicationVersion
    )
) {
    throw "Invalid application version in release archive: $applicationVersionText"
}

Write-Host "Verified release archive ($($actualFiles.Count) files):" -ForegroundColor Green
Write-Host "Application version: $applicationVersion"
foreach ($file in $actualFiles) {
    Write-Host "  $file"
}
