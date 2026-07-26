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
    throw "此脚本只能在 Windows 上运行。"
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
    throw "没有找到公钥证书：$CertificatePath"
}

if (-not $InstallerPath) {
    $installers = @(
        Get-ChildItem -LiteralPath $PSScriptRoot -Filter "*Setup.exe" -File
    )
    if ($installers.Count -ne 1) {
        throw "安装目录中必须有且仅有一个“*Setup.exe”文件，当前找到 $($installers.Count) 个。"
    }
    $InstallerPath = $installers[0].FullName
}

if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
    throw "没有找到安装程序：$InstallerPath"
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
    throw "证书不包含代码签名用途，拒绝安装。"
}

if (Test-Path -LiteralPath $ExpectedThumbprintPath -PathType Leaf) {
    $expectedThumbprint = (
        Get-Content -LiteralPath $ExpectedThumbprintPath -Raw
    ).Trim().Replace(" ", "").ToUpperInvariant()
    if ($expectedThumbprint -ne $certificate.Thumbprint) {
        throw "证书指纹与安装包清单不一致，拒绝安装。"
    }
}

Write-Host "正在安装内部代码签名证书……"
Import-Certificate `
    -FilePath $CertificatePath `
    -CertStoreLocation "Cert:\LocalMachine\Root" | Out-Null
Import-Certificate `
    -FilePath $CertificatePath `
    -CertStoreLocation "Cert:\LocalMachine\TrustedPublisher" | Out-Null

$signature = Get-AuthenticodeSignature -LiteralPath $InstallerPath
if ($signature.Status -ne "Valid") {
    throw "安装程序签名无效，状态为 $($signature.Status)，拒绝运行。"
}
if (
    $null -eq $signature.SignerCertificate -or
    $signature.SignerCertificate.Thumbprint -ne $certificate.Thumbprint
) {
    throw "安装程序不是由预期证书签名，拒绝运行。"
}

Write-Host "证书和安装程序签名校验通过，正在启动安装……" -ForegroundColor Green
$installer = Start-Process -FilePath $InstallerPath -Wait -PassThru
if ($installer.ExitCode -ne 0) {
    throw "安装程序退出码为 $($installer.ExitCode)。"
}

Write-Host "Attendance Ledger 安装完成。" -ForegroundColor Green
