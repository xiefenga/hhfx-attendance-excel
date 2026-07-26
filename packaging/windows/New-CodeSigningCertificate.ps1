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
    throw "此脚本只能在 Windows 上运行。"
}

$resolvedOutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$pfxPath = Join-Path $resolvedOutputDirectory "attendance-ledger-signing.pfx"
$cerPath = Join-Path $resolvedOutputDirectory "attendance-ledger.cer"
$thumbprintPath = Join-Path $resolvedOutputDirectory "attendance-ledger.cer.thumbprint.txt"

New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
foreach ($path in @($pfxPath, $cerPath, $thumbprintPath)) {
    if (Test-Path -LiteralPath $path) {
        throw "目标文件已经存在，请先移动旧文件或指定新的输出目录：$path"
    }
}

$pfxPassword = Read-Host "请设置 PFX 私钥密码（输入内容不会显示）" -AsSecureString
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
Write-Host "内部代码签名证书已生成：" -ForegroundColor Green
Write-Host "  私钥（仅用于构建，禁止分发）：$pfxPath"
Write-Host "  公钥（随安装包分发）：      $cerPath"
Write-Host "  证书指纹：                  $($certificate.Thumbprint)"
Write-Host "  构建电脑信任：              已加入当前用户的 Root 和 TrustedPublisher"
Write-Host ""
Write-Host "请把 PFX 密码保存到密码管理器，并妥善备份 PFX。"
Write-Host "上传 GitHub Secrets 前，可执行以下命令把 PFX 的 Base64 内容复制到剪贴板："
Write-Host "[Convert]::ToBase64String([IO.File]::ReadAllBytes('$pfxPath')) | Set-Clipboard"
