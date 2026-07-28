[CmdletBinding()]
param(
    [string]$CertificatePath = "",
    [string]$InstallerPath = "",
    [string]$ExpectedThumbprintPath = "",
    [string]$VersionPath = "",
    [switch]$InstallCertificateOnly,
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
if (-not $VersionPath) {
    $VersionPath = Join-Path $scriptDirectory "attendance-ledger.version.txt"
}

$CertificatePath = [IO.Path]::GetFullPath($CertificatePath)
$InstallerPath = [IO.Path]::GetFullPath($InstallerPath)
$ExpectedThumbprintPath = [IO.Path]::GetFullPath($ExpectedThumbprintPath)
$VersionPath = [IO.Path]::GetFullPath($VersionPath)

foreach ($requiredPath in @(
    $CertificatePath,
    $InstallerPath,
    $ExpectedThumbprintPath,
    $VersionPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required release file not found: $requiredPath"
    }
}

function ConvertTo-ApplicationVersion {
    param(
        [Parameter(Mandatory)]
        [string]$Value,
        [Parameter(Mandatory)]
        [string]$Source
    )

    [Version]$parsedVersion = $null
    if (
        [string]::IsNullOrWhiteSpace($Value) -or
        -not [Version]::TryParse($Value.Trim(), [ref]$parsedVersion)
    ) {
        throw "Invalid application version in ${Source}: $Value"
    }
    return $parsedVersion
}

function Get-InstalledApplicationVersion {
    $versions = [System.Collections.Generic.List[System.Version]]::new()
    $uninstallRoot = "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall"
    if (Test-Path -LiteralPath $uninstallRoot) {
        foreach ($entry in Get-ChildItem -LiteralPath $uninstallRoot) {
            $properties = Get-ItemProperty `
                -LiteralPath $entry.PSPath `
                -ErrorAction SilentlyContinue
            if ($null -eq $properties) {
                continue
            }
            $displayNameProperty = $properties.PSObject.Properties["DisplayName"]
            $displayVersionProperty = $properties.PSObject.Properties["DisplayVersion"]
            $displayName = if ($null -eq $displayNameProperty) {
                ""
            }
            else {
                [string]$displayNameProperty.Value
            }
            if (
                $entry.PSChildName -ne "attendance_ledger" -and
                $displayName -ne "Attendance Ledger"
            ) {
                continue
            }
            [Version]$registryVersion = $null
            if (
                $null -ne $displayVersionProperty -and
                [Version]::TryParse(
                    ([string]$displayVersionProperty.Value).Trim(),
                    [ref]$registryVersion
                )
            ) {
                $versions.Add($registryVersion)
            }
        }
    }

    $applicationRoot = Join-Path $env:LOCALAPPDATA "attendance_ledger"
    if (Test-Path -LiteralPath $applicationRoot -PathType Container) {
        foreach (
            $directory in Get-ChildItem `
                -LiteralPath $applicationRoot `
                -Directory `
                -Filter "app-*"
        ) {
            [Version]$directoryVersion = $null
            if (
                [Version]::TryParse(
                    $directory.Name.Substring(4),
                    [ref]$directoryVersion
                )
            ) {
                $versions.Add($directoryVersion)
            }
        }
    }

    if ($versions.Count -eq 0) {
        return $null
    }
    return @($versions | Sort-Object -Descending)[0]
}

$targetVersion = ConvertTo-ApplicationVersion `
    -Value (Get-Content -LiteralPath $VersionPath -Raw) `
    -Source $VersionPath

if ($ValidatePathsOnly) {
    Write-Host "Installation bundle paths are valid:" -ForegroundColor Green
    Write-Host "  Certificate: $CertificatePath"
    Write-Host "  Thumbprint:  $ExpectedThumbprintPath"
    Write-Host "  Installer:   $InstallerPath"
    Write-Host "  Version:     $targetVersion"
    return
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

$signature = Get-AuthenticodeSignature -LiteralPath $InstallerPath
if (
    $signature.Status.ToString() -notin @(
        "Valid",
        "NotTrusted",
        "UnknownError"
    )
) {
    throw "The installer signature status is $($signature.Status). Installation stopped."
}
if (
    $null -eq $signature.SignerCertificate -or
    $signature.SignerCertificate.Thumbprint -ne $certificate.Thumbprint
) {
    throw "The installer was not signed by the expected certificate. Installation stopped."
}

$installedVersion = Get-InstalledApplicationVersion
if ($null -ne $installedVersion) {
    if ($targetVersion -lt $installedVersion) {
        throw "Downgrade is not supported. Installed version: $installedVersion; package version: $targetVersion."
    }
    if ($targetVersion -eq $installedVersion) {
        Write-Host "Attendance Ledger $targetVersion is already installed. No update is required." -ForegroundColor Green
        return
    }
}

$rootCertificatePath = "Cert:\LocalMachine\Root\$($certificate.Thumbprint)"
$publisherCertificatePath = "Cert:\LocalMachine\TrustedPublisher\$($certificate.Thumbprint)"
$rootCertificateInstalled = Test-Path -LiteralPath $rootCertificatePath
$publisherCertificateInstalled = Test-Path -LiteralPath $publisherCertificatePath
$certificateInstallRequired = (
    -not $rootCertificateInstalled -or
    -not $publisherCertificateInstalled
)

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
$isAdministrator = $currentPrincipal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if ($certificateInstallRequired -and -not $isAdministrator) {
    Write-Host "The signing certificate is not trusted yet. Administrator approval is required once."
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
        "`"$ExpectedThumbprintPath`"",
        "-VersionPath",
        "`"$VersionPath`"",
        "-InstallCertificateOnly"
    )
    $elevated = Start-Process `
        -FilePath "powershell.exe" `
        -Verb RunAs `
        -ArgumentList $arguments `
        -Wait `
        -PassThru
    if ($elevated.ExitCode -ne 0) {
        exit $elevated.ExitCode
    }
    $rootCertificateInstalled = Test-Path -LiteralPath $rootCertificatePath
    $publisherCertificateInstalled = Test-Path -LiteralPath $publisherCertificatePath
    if (-not $rootCertificateInstalled -or -not $publisherCertificateInstalled) {
        throw "The signing certificate was not installed into both required certificate stores."
    }
}

if (-not $rootCertificateInstalled) {
    Write-Host "Installing the internal code-signing certificate into Trusted Root..."
    Import-Certificate `
        -FilePath $CertificatePath `
        -CertStoreLocation "Cert:\LocalMachine\Root" | Out-Null
}
if (-not $publisherCertificateInstalled) {
    Write-Host "Installing the internal code-signing certificate into Trusted Publishers..."
    Import-Certificate `
        -FilePath $CertificatePath `
        -CertStoreLocation "Cert:\LocalMachine\TrustedPublisher" | Out-Null
}

$trustedSignature = Get-AuthenticodeSignature -LiteralPath $InstallerPath
if ($trustedSignature.Status -ne "Valid") {
    throw "The trusted installer signature status is $($trustedSignature.Status). Installation stopped."
}
if (
    $null -eq $trustedSignature.SignerCertificate -or
    $trustedSignature.SignerCertificate.Thumbprint -ne $certificate.Thumbprint
) {
    throw "The trusted installer was not signed by the expected certificate. Installation stopped."
}

if ($InstallCertificateOnly) {
    Write-Host "The internal code-signing certificate is trusted." -ForegroundColor Green
    return
}

if ($null -eq $installedVersion) {
    Write-Host "Certificate and installer signature verified. Installing Attendance Ledger $targetVersion..." -ForegroundColor Green
}
else {
    Write-Host "Certificate and installer signature verified. Updating Attendance Ledger $installedVersion to $targetVersion..." -ForegroundColor Green
}
$installer = Start-Process -FilePath $InstallerPath -Wait -PassThru
if ($installer.ExitCode -ne 0) {
    throw "The installer exited with code $($installer.ExitCode)."
}

Write-Host "Attendance Ledger $targetVersion installation completed." -ForegroundColor Green
