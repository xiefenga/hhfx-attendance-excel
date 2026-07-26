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

Write-Host "Verified release archive ($($actualFiles.Count) files):" -ForegroundColor Green
foreach ($file in $actualFiles) {
    Write-Host "  $file"
}
