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

function Get-ApplicationState {
    $applicationRoot = Join-Path $env:LOCALAPPDATA "attendance_ledger"
    $uninstallPath = "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall\attendance_ledger"
    $versions = [System.Collections.Generic.List[System.Version]]::new()
    $versionDirectories = @{}

    if (Test-Path -LiteralPath $uninstallPath) {
        $displayVersion = (
            Get-ItemProperty -LiteralPath $uninstallPath -ErrorAction SilentlyContinue
        ).DisplayVersion
        [Version]$registryVersion = $null
        if (
            $null -ne $displayVersion -and
            [Version]::TryParse(
                ([string]$displayVersion).Trim(),
                [ref]$registryVersion
            )
        ) {
            $versions.Add($registryVersion)
        }
    }

    if (Test-Path -LiteralPath $applicationRoot -PathType Container) {
        foreach (
            $directory in Get-ChildItem `
                -LiteralPath $applicationRoot `
                -Directory `
                -Filter "app-*" `
                -ErrorAction SilentlyContinue
        ) {
            [Version]$directoryVersion = $null
            if (
                [Version]::TryParse(
                    $directory.Name.Substring(4),
                    [ref]$directoryVersion
                )
            ) {
                $versions.Add($directoryVersion)
                $versionDirectories[$directoryVersion.ToString()] = $directory.FullName
            }
        }
    }

    $hasResidue = (
        (Test-Path -LiteralPath $applicationRoot) -or
        (Test-Path -LiteralPath $uninstallPath)
    )
    if ($versions.Count -eq 0) {
        return [pscustomobject]@{
            Version = $null
            IsComplete = $false
            HasResidue = $hasResidue
            MissingPaths = @()
        }
    }

    [Version]$installedVersion = @($versions | Sort-Object -Descending)[0]
    $versionKey = $installedVersion.ToString()
    $versionDirectory = $versionDirectories[$versionKey]
    $requiredPaths = @((Join-Path $applicationRoot "Update.exe"))
    if ($null -eq $versionDirectory) {
        $requiredPaths += Join-Path $applicationRoot "app-$versionKey"
    }
    else {
        $requiredPaths += @(
            (Join-Path $versionDirectory "attendance-ledger.exe"),
            (Join-Path $versionDirectory "resources\app.asar"),
            (Join-Path $versionDirectory "resources\attendance-worker\attendance-worker.exe")
        )
    }
    $missingPaths = @(
        $requiredPaths |
            Where-Object {
                -not (Test-Path -LiteralPath $_ -PathType Leaf)
            }
    )

    return [pscustomobject]@{
        Version = $installedVersion
        IsComplete = $missingPaths.Count -eq 0
        HasResidue = $hasResidue
        MissingPaths = $missingPaths
    }
}

function Stop-ApplicationProcesses {
    $applicationRoot = Join-Path $env:LOCALAPPDATA "attendance_ledger"
    $processNames = @(
        "attendance-ledger",
        "attendance-worker",
        "Attendance Ledger Setup",
        "Update"
    )
    foreach (
        $process in Get-Process `
            -Name $processNames `
            -ErrorAction SilentlyContinue
    ) {
        if ($process.Name -eq "Update") {
            try {
                if (
                    -not ([string]$process.Path).StartsWith(
                        "$applicationRoot\",
                        [StringComparison]::OrdinalIgnoreCase
                    )
                ) {
                    continue
                }
            }
            catch {
                continue
            }
        }
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 500
}

function Remove-PathWithRetry {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    for ($attempt = 1; $attempt -le 4; $attempt += 1) {
        if (-not (Test-Path -LiteralPath $Path)) {
            return
        }
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force
            return
        }
        catch {
            if ($attempt -eq 4) {
                throw
            }
            Stop-ApplicationProcesses
        }
    }
}

function Clear-ApplicationInstallation {
    $applicationRoot = Join-Path $env:LOCALAPPDATA "attendance_ledger"
    $uninstallPath = "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall\attendance_ledger"
    Stop-ApplicationProcesses
    Remove-PathWithRetry -Path $applicationRoot
    Remove-Item `
        -LiteralPath $uninstallPath `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue

    foreach ($shortcutPath in @(
        (Join-Path ([Environment]::GetFolderPath("Desktop")) "Attendance Ledger.lnk"),
        (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Attendance Ledger.lnk")
    )) {
        Remove-Item `
            -LiteralPath $shortcutPath `
            -Force `
            -ErrorAction SilentlyContinue
    }

    Remove-PathWithRetry `
        -Path (Join-Path $env:LOCALAPPDATA "SquirrelTemp")
    foreach (
        $lockPath in Get-ChildItem `
            -LiteralPath $env:LOCALAPPDATA `
            -Filter "Temp.squirrel-lock-*" `
            -Force `
            -ErrorAction SilentlyContinue
    ) {
        Remove-PathWithRetry -Path $lockPath.FullName
    }
}

function Ensure-ApplicationShortcut {
    param(
        [Parameter(Mandatory)]
        [Version]$Version
    )

    $desktopShortcut = Join-Path `
        ([Environment]::GetFolderPath("Desktop")) `
        "Attendance Ledger.lnk"
    if (Test-Path -LiteralPath $desktopShortcut -PathType Leaf) {
        return
    }

    $applicationRoot = Join-Path $env:LOCALAPPDATA "attendance_ledger"
    $updatePath = Join-Path $applicationRoot "Update.exe"
    & $updatePath "--createShortcut=attendance-ledger.exe"
    if (Test-Path -LiteralPath $desktopShortcut -PathType Leaf) {
        return
    }

    $executablePath = Join-Path `
        $applicationRoot `
        "app-$($Version.ToString())\attendance-ledger.exe"
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($desktopShortcut)
        $shortcut.TargetPath = $executablePath
        $shortcut.WorkingDirectory = Split-Path -Parent $executablePath
        $shortcut.IconLocation = "$executablePath,0"
        $shortcut.Save()
    }
    catch {
        Write-Warning "The application is installed, but its desktop shortcut could not be created."
    }
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

$installedState = Get-ApplicationState
if ($null -ne $installedState.Version -and $installedState.IsComplete) {
    if ($targetVersion -le $installedState.Version) {
        Ensure-ApplicationShortcut -Version $installedState.Version
        Write-Host "Attendance Ledger $($installedState.Version) is already installed and verified." -ForegroundColor Green
        return
    }
}

$cleanFirst = $installedState.HasResidue -and -not $installedState.IsComplete
$maximumAttempts = 2
$installationCompleted = $false
$lastInstallerExitCode = $null
$lastInstallerError = ""
$lastState = $installedState

for ($attempt = 1; $attempt -le $maximumAttempts; $attempt += 1) {
    if ($cleanFirst -or $attempt -gt 1) {
        Write-Host "Cleaning incomplete installation state..."
        Clear-ApplicationInstallation
    }
    else {
        Stop-ApplicationProcesses
    }

    try {
        $installer = Start-Process `
            -FilePath $InstallerPath `
            -ArgumentList "--silent" `
            -Wait `
            -PassThru
        $lastInstallerExitCode = $installer.ExitCode
        $lastInstallerError = ""
    }
    catch {
        $lastInstallerExitCode = $null
        $lastInstallerError = $_.Exception.Message
    }

    if ($lastInstallerExitCode -eq 0) {
        for ($check = 0; $check -lt 20; $check += 1) {
            $lastState = Get-ApplicationState
            if (
                $lastState.Version -eq $targetVersion -and
                $lastState.IsComplete
            ) {
                $installationCompleted = $true
                break
            }
            Start-Sleep -Milliseconds 500
        }
    }
    if ($installationCompleted) {
        break
    }
    if ($attempt -lt $maximumAttempts) {
        Write-Warning "Installation was incomplete. A clean installation will be retried once."
    }
}

if (-not $installationCompleted) {
    if (-not [string]::IsNullOrWhiteSpace($lastInstallerError)) {
        Write-Host "Installer start error: $lastInstallerError" -ForegroundColor Yellow
    }
    elseif ($null -ne $lastInstallerExitCode) {
        Write-Host "Installer exit code: $lastInstallerExitCode" -ForegroundColor Yellow
    }
    foreach ($missingPath in $lastState.MissingPaths) {
        Write-Host "Missing: $missingPath" -ForegroundColor Yellow
    }
    throw "Installation failed twice. Check %LOCALAPPDATA%\SquirrelTemp\SquirrelSetup.log and Windows Security protection history."
}

Ensure-ApplicationShortcut -Version $targetVersion
Write-Host "Attendance Ledger $targetVersion installation completed and verified." -ForegroundColor Green
