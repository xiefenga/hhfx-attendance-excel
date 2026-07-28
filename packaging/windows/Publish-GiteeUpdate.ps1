param(
    [Parameter(Mandatory = $true)]
    [string]$ArtifactsDirectory,

    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$Owner = "xf_wwx",

    [string]$Repository = "attendance-ledger-updates",

    [string]$Branch = "master"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$accessToken = $env:GITEE_TOKEN
if ([string]::IsNullOrWhiteSpace($accessToken)) {
    throw "GITEE_TOKEN is required."
}

$resolvedArtifactsDirectory = (Resolve-Path -LiteralPath $ArtifactsDirectory).Path
$setupFiles = @(
    Get-ChildItem -LiteralPath $resolvedArtifactsDirectory -File -Filter "*Setup.exe"
)
if ($setupFiles.Count -ne 1) {
    throw "Expected exactly one Squirrel setup executable, found $($setupFiles.Count)."
}
$setupFile = $setupFiles[0]

$apiBase = "https://gitee.com/api/v5/repos/$Owner/$Repository"
$escapedToken = [Uri]::EscapeDataString($accessToken)

$partsDirectory = Join-Path $env:RUNNER_TEMP "attendance-ledger-update-v$Version"
New-Item -ItemType Directory -Path $partsDirectory -Force | Out-Null
Get-ChildItem -LiteralPath $partsDirectory -File | Remove-Item -Force

$chunkSize = 20000000
$inputStream = [IO.File]::OpenRead($setupFile.FullName)
$partFiles = [Collections.Generic.List[IO.FileInfo]]::new()
try {
    $partNumber = 1
    while ($inputStream.Position -lt $inputStream.Length) {
        $remaining = $inputStream.Length - $inputStream.Position
        $bytesToRead = [int][Math]::Min($chunkSize, $remaining)
        $buffer = [byte[]]::new($bytesToRead)
        $offset = 0
        while ($offset -lt $bytesToRead) {
            $read = $inputStream.Read($buffer, $offset, $bytesToRead - $offset)
            if ($read -eq 0) {
                throw "Unexpected end of installer while creating update parts."
            }
            $offset += $read
        }
        $partName = "Attendance-Ledger-$Version-Setup.exe.part{0:D3}" -f $partNumber
        $partPath = Join-Path $partsDirectory $partName
        [IO.File]::WriteAllBytes($partPath, $buffer)
        $partFiles.Add((Get-Item -LiteralPath $partPath))
        $partNumber += 1
    }
} finally {
    $inputStream.Dispose()
}

$partsPath = "win32/x64/parts"
$rawPartsBaseUrl = "https://gitee.com/$Owner/$Repository/raw/$Branch/$partsPath"
$publishedParts = @()
foreach ($partFile in $partFiles) {
    $publishedParts += @{
        url = "$rawPartsBaseUrl/$([Uri]::EscapeDataString($partFile.Name))"
        size = [long]$partFile.Length
    }
}

$manifest = @{
    version = $Version
    sha256 = (Get-FileHash -LiteralPath $setupFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    size = [long]$setupFile.Length
    parts = $publishedParts
}
$manifestJson = $manifest | ConvertTo-Json -Depth 4

$checkoutDirectory = Join-Path $env:RUNNER_TEMP "attendance-ledger-gitee-v$Version"
if (Test-Path -LiteralPath $checkoutDirectory) {
    Remove-Item -LiteralPath $checkoutDirectory -Recurse -Force
}
$remoteUrl = "https://${Owner}:${escapedToken}@gitee.com/$Owner/$Repository.git"
$env:GIT_TERMINAL_PROMPT = "0"
& git clone --depth 1 --branch $Branch $remoteUrl $checkoutDirectory
if ($LASTEXITCODE -ne 0) {
    throw "Failed to clone the Gitee update repository."
}

$targetPartsDirectory = Join-Path $checkoutDirectory $partsPath
if (Test-Path -LiteralPath $targetPartsDirectory) {
    Remove-Item -LiteralPath $targetPartsDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $targetPartsDirectory -Force | Out-Null
foreach ($partFile in $partFiles) {
    Copy-Item -LiteralPath $partFile.FullName -Destination $targetPartsDirectory
}

$manifestPath = "win32/x64/update.json"
$manifestFile = Join-Path $checkoutDirectory $manifestPath
[IO.File]::WriteAllText(
    $manifestFile,
    "$manifestJson`n",
    [Text.UTF8Encoding]::new($false)
)

& git -C $checkoutDirectory config user.name "Attendance Ledger Release"
if ($LASTEXITCODE -ne 0) {
    throw "Failed to configure the Gitee release Git user."
}
& git -C $checkoutDirectory config user.email "release@attendance-ledger.local"
if ($LASTEXITCODE -ne 0) {
    throw "Failed to configure the Gitee release Git email."
}
& git -C $checkoutDirectory add --all
if ($LASTEXITCODE -ne 0) {
    throw "Failed to stage the Gitee update files."
}
& git -C $checkoutDirectory commit -m "chore(release): 发布 v$Version Windows 更新"
if ($LASTEXITCODE -ne 0) {
    throw "Failed to commit the Gitee update files."
}
& git -C $checkoutDirectory push origin $Branch
if ($LASTEXITCODE -ne 0) {
    throw "Failed to push the Gitee update files."
}

$escapedTag = [Uri]::EscapeDataString("v$Version")
$releaseStatusCode = 0
$release = Invoke-RestMethod `
    -Uri "$apiBase/releases/tags/${escapedTag}?access_token=$escapedToken" `
    -Method Get `
    -SkipHttpErrorCheck `
    -StatusCodeVariable releaseStatusCode
if ($releaseStatusCode -eq 404) {
    $release = Invoke-RestMethod `
        -Uri "$apiBase/releases" `
        -Method Post `
        -ContentType "application/x-www-form-urlencoded" `
        -Body @{
            access_token = $accessToken
            tag_name = "v$Version"
            target_commitish = $Branch
            name = "Attendance Ledger v$Version"
            body = "Attendance Ledger Windows x64 分片自动更新制品。"
            prerelease = "false"
        }
} elseif ($releaseStatusCode -lt 200 -or $releaseStatusCode -ge 300) {
    throw "Gitee release lookup failed with HTTP $releaseStatusCode."
}
if ($null -eq $release.id) {
    throw "Gitee release creation returned an invalid response."
}

Write-Host "Published Attendance Ledger v$Version update to Gitee."
Write-Host "Manifest: https://gitee.com/$Owner/$Repository/raw/$Branch/$manifestPath"
