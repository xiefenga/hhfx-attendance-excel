[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$InstallerPath,
    [Parameter(Mandatory)]
    [string]$CertificatePath,
    [string]$OutputDirectory = (Join-Path (Get-Location) "attendance-ledger-internal-release")
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
if ($signature.Status -ne "Valid") {
    throw "The installer signature status is $($signature.Status)."
}
if (
    $null -eq $signature.SignerCertificate -or
    $signature.SignerCertificate.Thumbprint -ne $certificate.Thumbprint
) {
    throw "The installer signature does not match the supplied public certificate."
}

$resolvedOutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null

$scriptDirectory = $PSScriptRoot
Copy-Item -LiteralPath $InstallerPath -Destination $resolvedOutputDirectory -Force
Copy-Item `
    -LiteralPath $CertificatePath `
    -Destination (Join-Path $resolvedOutputDirectory "attendance-ledger.cer") `
    -Force
Copy-Item `
    -LiteralPath (Join-Path $scriptDirectory "Install-AttendanceLedger.ps1") `
    -Destination $resolvedOutputDirectory `
    -Force
Copy-Item `
    -LiteralPath (Join-Path $scriptDirectory "Install Attendance Ledger.cmd") `
    -Destination $resolvedOutputDirectory `
    -Force
Set-Content `
    -LiteralPath (Join-Path $resolvedOutputDirectory "attendance-ledger.cer.thumbprint.txt") `
    -Value $certificate.Thumbprint `
    -Encoding Ascii

Write-Host "Internal release bundle created: $resolvedOutputDirectory" -ForegroundColor Green
Write-Host "Distribute the entire directory. Never include the private PFX."
