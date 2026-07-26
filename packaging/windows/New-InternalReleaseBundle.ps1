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
        throw "没有找到文件：$path"
    }
}

$certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
    [IO.Path]::GetFullPath($CertificatePath)
)
$signature = Get-AuthenticodeSignature -LiteralPath $InstallerPath
if ($signature.Status -ne "Valid") {
    throw "安装程序签名无效，状态为 $($signature.Status)。"
}
if (
    $null -eq $signature.SignerCertificate -or
    $signature.SignerCertificate.Thumbprint -ne $certificate.Thumbprint
) {
    throw "安装程序签名证书与提供的公钥证书不一致。"
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

Write-Host "内部安装包已整理完成：$resolvedOutputDirectory" -ForegroundColor Green
Write-Host "请分发整个目录，不要放入 PFX 私钥。"
