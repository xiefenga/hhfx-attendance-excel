[CmdletBinding()]
param(
    [string]$Subject = "CN=Attendance Ledger Internal",
    [string]$OutputDirectory = (
        Join-Path ([Environment]::GetFolderPath("MyDocuments")) "AttendanceLedgerSigning"
    ),
    [ValidateRange(1, 10)]
    [int]$ValidYears = 5
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($env:OS -ne "Windows_NT") {
    throw "This script can only run on Windows."
}

$resolvedOutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$pfxPath = Join-Path $resolvedOutputDirectory "attendance-ledger-signing.pfx"
$cerPath = Join-Path $resolvedOutputDirectory "attendance-ledger.cer"
$thumbprintPath = Join-Path $resolvedOutputDirectory "attendance-ledger.cer.thumbprint.txt"

New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
foreach ($path in @($pfxPath, $cerPath, $thumbprintPath)) {
    if (Test-Path -LiteralPath $path) {
        throw "A target file already exists. Move it or choose another output directory: $path"
    }
}

$pfxPassword = Read-Host "Set the PFX password (input is hidden)" -AsSecureString
$certificate = New-SelfSignedCertificate `
    -Type Custom `
    -Subject $Subject `
    -FriendlyName "Attendance Ledger Internal Code Signing" `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -KeyAlgorithm RSA `
    -KeyLength 3072 `
    -HashAlgorithm SHA256 `
    -KeyExportPolicy Exportable `
    -KeyUsage DigitalSignature `
    -NotAfter (Get-Date).AddYears($ValidYears) `
    -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3")

try {
    Export-PfxCertificate `
        -Cert $certificate `
        -FilePath $pfxPath `
        -Password $pfxPassword `
        -ChainOption EndEntityCertOnly | Out-Null
    Export-Certificate -Cert $certificate -FilePath $cerPath -Type CERT | Out-Null
    Set-Content -LiteralPath $thumbprintPath -Value $certificate.Thumbprint -Encoding Ascii
    Import-Certificate `
        -FilePath $cerPath `
        -CertStoreLocation "Cert:\CurrentUser\Root" | Out-Null
    Import-Certificate `
        -FilePath $cerPath `
        -CertStoreLocation "Cert:\CurrentUser\TrustedPublisher" | Out-Null
}
catch {
    foreach ($path in @($pfxPath, $cerPath, $thumbprintPath)) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    throw
}

Write-Host ""
Write-Host "Internal code-signing certificate created:" -ForegroundColor Green
Write-Host "  Private PFX (build only; never distribute): $pfxPath"
Write-Host "  Public certificate (safe to distribute):   $cerPath"
Write-Host "  Certificate thumbprint:                    $($certificate.Thumbprint)"
Write-Host "  Build-machine trust: CurrentUser Root and TrustedPublisher"
Write-Host ""
Write-Host "Store the PFX password in a password manager and back up the PFX securely."
Write-Host "Run this command to copy the PFX as Base64 for GitHub Actions Secrets:"
Write-Host "[Convert]::ToBase64String([IO.File]::ReadAllBytes('$pfxPath')) | Set-Clipboard"
