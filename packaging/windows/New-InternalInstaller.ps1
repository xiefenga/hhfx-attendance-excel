[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ArchivePath,
    [Parameter(Mandatory)]
    [string]$CertificatePath,
    [Parameter(Mandatory)]
    [string]$CertificatePassword,
    [string]$OutputPath = (
        Join-Path (Get-Location) "Attendance Ledger Installer.exe"
    ),
    [string]$SourcePath = (
        Join-Path $PSScriptRoot "AttendanceLedgerInstaller.cs"
    ),
    [string]$IconPath = (
        Join-Path $PSScriptRoot "../../assets/icons/attendance-ledger.ico"
    )
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($env:OS -ne "Windows_NT") {
    throw "This script can only run on Windows."
}

$resolvedArchivePath = [IO.Path]::GetFullPath($ArchivePath)
$resolvedCertificatePath = [IO.Path]::GetFullPath($CertificatePath)
$resolvedSourcePath = [IO.Path]::GetFullPath($SourcePath)
$resolvedIconPath = [IO.Path]::GetFullPath($IconPath)
$resolvedOutputPath = [IO.Path]::GetFullPath($OutputPath)
foreach ($requiredPath in @(
    $resolvedArchivePath,
    $resolvedCertificatePath,
    $resolvedSourcePath,
    $resolvedIconPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required installer input not found: $requiredPath"
    }
}
if (Test-Path -LiteralPath $resolvedOutputPath) {
    throw "Installer output already exists: $resolvedOutputPath"
}

$compilerCandidates = @(
    (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
    (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
)
$compilerPath = @(
    $compilerCandidates |
        Where-Object {
            Test-Path -LiteralPath $_ -PathType Leaf
        }
)[0]
if ([string]::IsNullOrWhiteSpace($compilerPath)) {
    throw "Unable to locate the .NET Framework C# compiler."
}

$outputDirectory = Split-Path -Parent $resolvedOutputPath
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$compilerArguments = @(
    "/nologo",
    "/target:winexe",
    "/platform:x64",
    "/optimize+",
    "/out:$resolvedOutputPath",
    "/win32icon:$resolvedIconPath",
    "/resource:$resolvedArchivePath,AttendanceLedgerBundle.zip",
    "/reference:System.IO.Compression.dll",
    "/reference:System.IO.Compression.FileSystem.dll",
    "/reference:System.Windows.Forms.dll",
    $resolvedSourcePath
)

try {
    & $compilerPath @compilerArguments
    if ($LASTEXITCODE -ne 0) {
        throw "C# compiler exited with code $LASTEXITCODE."
    }
    if (-not (Test-Path -LiteralPath $resolvedOutputPath -PathType Leaf)) {
        throw "C# compiler did not create the installer executable."
    }

    $securePassword = ConvertTo-SecureString `
        $CertificatePassword `
        -AsPlainText `
        -Force
    $certificate = Get-PfxCertificate `
        -FilePath $resolvedCertificatePath `
        -Password $securePassword
    if (-not $certificate.HasPrivateKey) {
        throw "The supplied PFX does not contain a private key."
    }
    $signature = Set-AuthenticodeSignature `
        -FilePath $resolvedOutputPath `
        -Certificate $certificate `
        -HashAlgorithm SHA256
    if (
        $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Thumbprint -ne $certificate.Thumbprint
    ) {
        throw "The generated installer was not signed by the expected certificate."
    }
    if ($signature.Status.ToString() -notin @(
        "Valid",
        "NotTrusted",
        "UnknownError"
    )) {
        throw "Generated installer signature status: $($signature.Status)."
    }
}
catch {
    if (Test-Path -LiteralPath $resolvedOutputPath -PathType Leaf) {
        Remove-Item -LiteralPath $resolvedOutputPath -Force
    }
    throw
}

Write-Host "Single-file Windows installer created:" -ForegroundColor Green
Write-Host "  $resolvedOutputPath"
