[CmdletBinding()]
param(
    [string]$CertificatePath = "",
    [string]$InstallerPath = "",
    [string]$ExpectedThumbprintPath = "",
    [switch]$ValidatePathsOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($env:OS -ne "Windows_NT") {
    throw "This script can only run on Windows."
}

$scriptDirectory = Split-Path -Parent $PSCommandPath
if ([string]::IsNullOrWhiteSpace($scriptDirectory)) {
    throw "Unable to resolve the installation script directory."
}

if (-not $CertificatePath) {
    $CertificatePath = Join-Path $scriptDirectory "attendance-ledger.cer"
}
if (-not $ExpectedThumbprintPath) {
    $ExpectedThumbprintPath = Join-Path `
        $scriptDirectory `
        "attendance-ledger.cer.thumbprint.txt"
}
if (-not $InstallerPath) {
    $installers = @(
        Get-ChildItem -LiteralPath $scriptDirectory -Filter "*Setup.exe" -File
    )
    if ($installers.Count -ne 1) {
        throw "The release directory must contain exactly one *Setup.exe file; found $($installers.Count)."
    }
    $InstallerPath = $installers[0].FullName
}

$CertificatePath = [IO.Path]::GetFullPath($CertificatePath)
$InstallerPath = [IO.Path]::GetFullPath($InstallerPath)
$ExpectedThumbprintPath = [IO.Path]::GetFullPath($ExpectedThumbprintPath)

foreach ($requiredPath in @(
    $CertificatePath,
    $InstallerPath,
    $ExpectedThumbprintPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required release file not found: $requiredPath"
    }
}

if ($ValidatePathsOnly) {
    Write-Host "Installation bundle paths are valid:" -ForegroundColor Green
    Write-Host "  Certificate: $CertificatePath"
    Write-Host "  Thumbprint:  $ExpectedThumbprintPath"
    Write-Host "  Installer:   $InstallerPath"
    return
}

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
$isAdministrator = $currentPrincipal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdministrator) {
    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "`"$PSCommandPath`"",
        "-CertificatePath",
        "`"$CertificatePath`"",
        "-InstallerPath",
        "`"$InstallerPath`"",
        "-ExpectedThumbprintPath",
        "`"$ExpectedThumbprintPath`""
    )
    $elevated = Start-Process `
        -FilePath "powershell.exe" `
        -Verb RunAs `
        -ArgumentList $arguments `
        -Wait `
        -PassThru
    exit $elevated.ExitCode
}

$certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
    $CertificatePath
)
$codeSigningOid = "1.3.6.1.5.5.7.3.3"
$hasCodeSigningUsage = $false
foreach ($extension in $certificate.Extensions) {
    if ($extension.Oid.Value -ne "2.5.29.37") {
        continue
    }
    $enhancedKeyUsage = [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]$extension
    foreach ($usage in $enhancedKeyUsage.EnhancedKeyUsages) {
        if ($usage.Value -eq $codeSigningOid) {
            $hasCodeSigningUsage = $true
        }
    }
}
if (-not $hasCodeSigningUsage) {
    throw "The certificate does not permit code signing. Installation stopped."
}

$expectedThumbprint = (
    Get-Content -LiteralPath $ExpectedThumbprintPath -Raw
).Trim().Replace(" ", "").ToUpperInvariant()
if ($expectedThumbprint -ne $certificate.Thumbprint) {
    throw "The certificate thumbprint does not match the release manifest. Installation stopped."
}

Write-Host "Installing the internal code-signing certificate..."
Import-Certificate `
    -FilePath $CertificatePath `
    -CertStoreLocation "Cert:\LocalMachine\Root" | Out-Null
Import-Certificate `
    -FilePath $CertificatePath `
    -CertStoreLocation "Cert:\LocalMachine\TrustedPublisher" | Out-Null

$signature = Get-AuthenticodeSignature -LiteralPath $InstallerPath
if ($signature.Status -ne "Valid") {
    throw "The installer signature status is $($signature.Status). Installation stopped."
}
if (
    $null -eq $signature.SignerCertificate -or
    $signature.SignerCertificate.Thumbprint -ne $certificate.Thumbprint
) {
    throw "The installer was not signed by the expected certificate. Installation stopped."
}

Write-Host "Certificate and installer signature verified. Starting setup..." -ForegroundColor Green
$installer = Start-Process -FilePath $InstallerPath -Wait -PassThru
if ($installer.ExitCode -ne 0) {
    throw "The installer exited with code $($installer.ExitCode)."
}

Write-Host "Attendance Ledger installation completed." -ForegroundColor Green
