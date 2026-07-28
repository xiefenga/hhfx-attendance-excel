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
$releaseFile = Join-Path $resolvedArtifactsDirectory "RELEASES"
$fullPackages = @(
    Get-ChildItem -LiteralPath $resolvedArtifactsDirectory -File -Filter "*-full.nupkg"
)
$setupFiles = @(
    Get-ChildItem -LiteralPath $resolvedArtifactsDirectory -File -Filter "*Setup.exe"
)
if (-not (Test-Path -LiteralPath $releaseFile -PathType Leaf)) {
    throw "Squirrel RELEASES file not found: $releaseFile"
}
if ($fullPackages.Count -ne 1) {
    throw "Expected exactly one full Squirrel package, found $($fullPackages.Count)."
}
if ($setupFiles.Count -ne 1) {
    throw "Expected exactly one Squirrel setup executable, found $($setupFiles.Count)."
}

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
            body = "Attendance Ledger Windows x64 自动更新制品。"
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
        if ($asset.name -eq $File.Name) {
            Invoke-RestMethod `
                -Uri "$assetsEndpoint/$($asset.id)?access_token=$escapedToken" `
                -Method Delete | Out-Null
        }
    }

    return Invoke-RestMethod `
        -Uri $assetsEndpoint `
        -Method Post `
        -Form @{
            access_token = $accessToken
            file = $File
        }
}

$packageAsset = Publish-ReleaseAsset -File $fullPackages[0]
Publish-ReleaseAsset -File $setupFiles[0] | Out-Null

$releaseLines = @(
    Get-Content -LiteralPath $releaseFile |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
if ($releaseLines.Count -ne 1) {
    throw "Expected one entry in RELEASES, found $($releaseLines.Count)."
}
$releaseMatch = [regex]::Match(
    $releaseLines[0],
    "^(?<sha>\S+)\s+\S+\s+(?<size>\d+)$"
)
if (-not $releaseMatch.Success) {
    throw "Unexpected RELEASES entry: $($releaseLines[0])"
}

$publishedRelease = (
    "$($releaseMatch.Groups['sha'].Value) " +
    "$($packageAsset.browser_download_url) " +
    "$($releaseMatch.Groups['size'].Value)"
)
[IO.File]::WriteAllText(
    $releaseFile,
    "$publishedRelease`n",
    [Text.UTF8Encoding]::new($false)
)
Publish-ReleaseAsset -File (Get-Item -LiteralPath $releaseFile) | Out-Null

$manifestPath = "win32/x64/RELEASES"
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
    content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($releaseFile))
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
Write-Host "Feed: https://gitee.com/$Owner/$Repository/raw/$Branch/win32/x64"
