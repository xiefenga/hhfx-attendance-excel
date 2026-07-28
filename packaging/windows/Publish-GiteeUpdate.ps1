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
$escapedTag = [Uri]::EscapeDataString("v$Version")

$releaseStatusCode = 0
$release = Invoke-RestMethod `
    -Uri "$apiBase/releases/tags/${escapedTag}?access_token=$escapedToken" `
    -Method Get `
    -SkipHttpErrorCheck `
    -StatusCodeVariable releaseStatusCode
if ($releaseStatusCode -eq 404) {
    $release = $null
} elseif ($releaseStatusCode -lt 200 -or $releaseStatusCode -ge 300) {
    throw "Gitee release lookup failed with HTTP $releaseStatusCode."
}

if ($null -eq $release) {
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
}

$releaseId = [int]$release.id
$assetsEndpoint = "$apiBase/releases/$releaseId/attach_files"

function Publish-ReleaseAsset {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    $existingAssets = @(
        Invoke-RestMethod `
            -Uri "${assetsEndpoint}?access_token=$escapedToken&per_page=100" `
            -Method Get
    )
    foreach ($asset in $existingAssets) {
        if (
            $null -ne $asset -and
            $null -ne $asset.PSObject.Properties["name"] -and
            $asset.name -eq $File.Name
        ) {
            Invoke-RestMethod `
                -Uri "$assetsEndpoint/$($asset.id)?access_token=$escapedToken" `
                -Method Delete | Out-Null
        }
    }

    $uploadEndpoint = "${assetsEndpoint}?access_token=$escapedToken"
    $curlArguments = @(
        "--silent",
        "--show-error",
        "--fail-with-body",
        "--location",
        "--connect-timeout", "30",
        "--max-time", "600",
        "--retry", "2",
        "--retry-delay", "5",
        "--retry-all-errors",
        "--form", "file=@$($File.FullName)",
        $uploadEndpoint
    )
    $responseLines = & curl.exe @curlArguments
    if ($LASTEXITCODE -ne 0) {
        throw "curl.exe failed to upload $($File.Name) with exit code $LASTEXITCODE."
    }
    return ($responseLines -join "`n") | ConvertFrom-Json
}

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

$publishedParts = @()
foreach ($partFile in $partFiles) {
    Write-Host "Uploading $($partFile.Name) ($($partFile.Length) bytes)..."
    $partAsset = Publish-ReleaseAsset -File $partFile
    $publishedParts += @{
        url = [string]$partAsset.browser_download_url
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
$manifestFile = Join-Path $partsDirectory "update.json"
[IO.File]::WriteAllText(
    $manifestFile,
    "$manifestJson`n",
    [Text.UTF8Encoding]::new($false)
)

$manifestPath = "win32/x64/update.json"
$escapedManifestPath = ($manifestPath -split "/" | ForEach-Object {
    [Uri]::EscapeDataString($_)
}) -join "/"
$manifestEndpoint = "$apiBase/contents/$escapedManifestPath"
$manifestStatusCode = 0
$existingManifest = Invoke-RestMethod `
    -Uri "${manifestEndpoint}?access_token=$escapedToken&ref=$([Uri]::EscapeDataString($Branch))" `
    -Method Get `
    -SkipHttpErrorCheck `
    -StatusCodeVariable manifestStatusCode
if ($manifestStatusCode -eq 404) {
    $existingManifest = $null
} elseif ($manifestStatusCode -lt 200 -or $manifestStatusCode -ge 300) {
    throw "Gitee update manifest lookup failed with HTTP $manifestStatusCode."
}

$manifestBody = @{
    access_token = $accessToken
    content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($manifestFile))
    message = "chore(release): 发布 v$Version Windows 更新清单"
    branch = $Branch
}
if ($null -eq $existingManifest) {
    Invoke-RestMethod `
        -Uri $manifestEndpoint `
        -Method Post `
        -ContentType "application/x-www-form-urlencoded" `
        -Body $manifestBody | Out-Null
} else {
    $manifestBody.sha = [string]$existingManifest.sha
    Invoke-RestMethod `
        -Uri $manifestEndpoint `
        -Method Put `
        -ContentType "application/x-www-form-urlencoded" `
        -Body $manifestBody | Out-Null
}

Write-Host "Published Attendance Ledger v$Version update to Gitee."
Write-Host "Manifest: https://gitee.com/$Owner/$Repository/raw/$Branch/$manifestPath"
