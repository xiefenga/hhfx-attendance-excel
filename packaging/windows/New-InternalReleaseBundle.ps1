[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$InstallerPath,
    [Parameter(Mandatory)]
    [string]$CertificatePath,
    [string]$ArchivePath = (
        Join-Path (Get-Location) "Attendance-Ledger-Windows-x64.zip"
    ),
    [string]$PayloadDirectoryName = "Attendance Ledger Files",
    [string]$ApplicationVersion = "",
    [switch]$AllowUntrustedSelfSigned
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

foreach ($path in @($InstallerPath, $CertificatePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "File not found: $path"
    }
}

$certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
    [IO.Path]::GetFullPath($CertificatePath)
)
$signature = Get-AuthenticodeSignature -LiteralPath $InstallerPath
$isSelfSigned = $certificate.Subject -eq $certificate.Issuer
$untrustedStatuses = @("NotTrusted", "UnknownError")
$statusIsAllowed = $signature.Status -eq "Valid" -or (
    $AllowUntrustedSelfSigned -and
    $isSelfSigned -and
    $signature.Status.ToString() -in $untrustedStatuses
)
if (
    $null -eq $signature.SignerCertificate -or
    $signature.SignerCertificate.Thumbprint -ne $certificate.Thumbprint
) {
    throw "The installer signature does not match the supplied public certificate."
}
if (-not $statusIsAllowed) {
    throw "The installer signature status is $($signature.Status): $($signature.StatusMessage)"
}

if (
    [string]::IsNullOrWhiteSpace($PayloadDirectoryName) -or
    [IO.Path]::IsPathRooted($PayloadDirectoryName) -or
    $PayloadDirectoryName.Contains([IO.Path]::DirectorySeparatorChar.ToString()) -or
    $PayloadDirectoryName.Contains([IO.Path]::AltDirectorySeparatorChar.ToString())
) {
    throw "PayloadDirectoryName must be a single, non-empty directory name."
}

$resolvedArchivePath = [IO.Path]::GetFullPath($ArchivePath)
if (Test-Path -LiteralPath $resolvedArchivePath) {
    throw "Archive target already exists: $resolvedArchivePath"
}

$scriptDirectory = $PSScriptRoot
if (-not $ApplicationVersion) {
    $packageJsonPath = [IO.Path]::GetFullPath(
        (Join-Path $scriptDirectory "../../package.json")
    )
    if (-not (Test-Path -LiteralPath $packageJsonPath -PathType Leaf)) {
        throw "Unable to find package.json for application version: $packageJsonPath"
    }
    $packageJson = Get-Content -LiteralPath $packageJsonPath -Raw | ConvertFrom-Json
    $ApplicationVersion = [string]$packageJson.version
}
[Version]$parsedApplicationVersion = $null
if (
    [string]::IsNullOrWhiteSpace($ApplicationVersion) -or
    -not [Version]::TryParse($ApplicationVersion, [ref]$parsedApplicationVersion)
) {
    throw "ApplicationVersion must be a numeric version such as 0.1.4."
}

$archiveDirectory = Split-Path -Parent $resolvedArchivePath
New-Item -ItemType Directory -Path $archiveDirectory -Force | Out-Null

$stagingRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    ("attendance-ledger-release-" + [Guid]::NewGuid().ToString("N"))
$payloadDirectory = Join-Path $stagingRoot $PayloadDirectoryName

$entryPointPath = Join-Path $scriptDirectory "Install Attendance Ledger.cmd"
$installerScriptPath = Join-Path $scriptDirectory "Install-AttendanceLedger.ps1"
foreach ($path in @($entryPointPath, $installerScriptPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "File not found: $path"
    }
}

try {
    New-Item -ItemType Directory -Path $payloadDirectory -Force | Out-Null

    Copy-Item -LiteralPath $InstallerPath -Destination $payloadDirectory
    Copy-Item `
        -LiteralPath $CertificatePath `
        -Destination (Join-Path $payloadDirectory "attendance-ledger.cer")
    Copy-Item -LiteralPath $installerScriptPath -Destination $payloadDirectory
    Copy-Item -LiteralPath $entryPointPath -Destination $payloadDirectory
    Copy-Item -LiteralPath $entryPointPath -Destination $stagingRoot
    Set-Content `
        -LiteralPath (Join-Path $payloadDirectory "attendance-ledger.cer.thumbprint.txt") `
        -Value $certificate.Thumbprint `
        -Encoding Ascii
    Set-Content `
        -LiteralPath (Join-Path $payloadDirectory "attendance-ledger.version.txt") `
        -Value $parsedApplicationVersion.ToString() `
        -Encoding Ascii

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $stagingRoot,
        $resolvedArchivePath,
        [IO.Compression.CompressionLevel]::Optimal,
        $false
    )

    & (Join-Path $scriptDirectory "Test-InternalReleaseArchive.ps1") `
        -ArchivePath $resolvedArchivePath `
        -InstallerFileName ([IO.Path]::GetFileName($InstallerPath)) `
        -PayloadDirectoryName $PayloadDirectoryName
}
catch {
    if (Test-Path -LiteralPath $resolvedArchivePath -PathType Leaf) {
        Remove-Item -LiteralPath $resolvedArchivePath -Force
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $stagingRoot -PathType Container) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}

Write-Host "Internal release ZIP created: $resolvedArchivePath" -ForegroundColor Green
Write-Host "Distribute this ZIP only. It contains no private PFX."
