[CmdletBinding()]
param(
    [string]$CertificatePath = (Join-Path $PSScriptRoot "attendance-ledger.cer"),
    [string]$InstallerPath = "",
    [string]$ExpectedThumbprintPath = (
        Join-Path $PSScriptRoot "attendance-ledger.cer.thumbprint.txt"
    )
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($env:OS -ne "Windows_NT") {
    throw "This script can only run on Windows."
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
        "`"$PSCommandPath`""
    )
    $elevated = Start-Process `
        -FilePath "powershell.exe" `
        -Verb RunAs `
        -ArgumentList $arguments `
        -Wait `
        -PassThru
    exit $elevated.ExitCode
}

if (-not (Test-Path -LiteralPath $CertificatePath -PathType Leaf)) {
    throw "Public certificate not found: $CertificatePath"
}

if (-not $InstallerPath) {
    $installers = @(
        Get-ChildItem -LiteralPath $PSScriptRoot -Filter "*Setup.exe" -File
    )
    if ($installers.Count -ne 1) {
        throw "The release directory must contain exactly one *Setup.exe file; found $($installers.Count)."
    }
    $InstallerPath = $installers[0].FullName
}

if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
    throw "Installer not found: $InstallerPath"
}

$certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
    [IO.Path]::GetFullPath($CertificatePath)
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

if (Test-Path -LiteralPath $ExpectedThumbprintPath -PathType Leaf) {
    $expectedThumbprint = (
        Get-Content -LiteralPath $ExpectedThumbprintPath -Raw
    ).Trim().Replace(" ", "").ToUpperInvariant()
    if ($expectedThumbprint -ne $certificate.Thumbprint) {
        throw "The certificate thumbprint does not match the release manifest. Installation stopped."
    }
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
