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
$escapedBranch = [Uri]::EscapeDataString($Branch)
$manifestPath = "win32/x64/update.json"
$publishedManifestUrl = (
    "https://gitee.com/$Owner/$Repository/raw/$Branch/$manifestPath"
)

function Get-ObjectProperty {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }
    if (
        $InputObject -is [Collections.IDictionary] -and
        $InputObject.Contains($Name)
    ) {
        return $InputObject[$Name]
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Get-RepositoryContentEndpoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath
    )

    $escapedPath = ($RepositoryPath -split "/" | ForEach-Object {
        [Uri]::EscapeDataString($_)
    }) -join "/"
    return "$apiBase/contents/$escapedPath"
}

function Get-RepositoryFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath
    )

    $statusCode = 0
    $result = Invoke-RestMethod `
        -Uri "$(Get-RepositoryContentEndpoint -RepositoryPath $RepositoryPath)?access_token=$escapedToken&ref=$escapedBranch" `
        -Method Get `
        -SkipHttpErrorCheck `
        -StatusCodeVariable statusCode
    if ($statusCode -eq 404) {
        return $null
    }
    if ($statusCode -lt 200 -or $statusCode -ge 300) {
        throw "Gitee repository file lookup failed with HTTP $statusCode."
    }
    return $result
}

function Publish-RepositoryFile {
    param(
        [Parameter(Mandatory = $true)]
        [IO.FileInfo]$File,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,

        [AllowNull()]
        [string]$ExistingSha
    )

    $body = @{
        access_token = $accessToken
        content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($File.FullName))
        message = "chore(release): 发布 v$Version $RepositoryPath"
        branch = $Branch
    }
    $method = "Post"
    if (-not [string]::IsNullOrWhiteSpace($ExistingSha)) {
        $body.sha = $ExistingSha
        $method = "Put"
    }

    for ($attempt = 1; $attempt -le 3; $attempt += 1) {
        try {
            Invoke-RestMethod `
                -Uri (Get-RepositoryContentEndpoint -RepositoryPath $RepositoryPath) `
                -Method $method `
                -TimeoutSec 180 `
                -ContentType "application/x-www-form-urlencoded" `
                -Body $body | Out-Null
            return
        } catch {
            if ($attempt -eq 3) {
                throw
            }
            Write-Warning (
                "Publishing $RepositoryPath failed on attempt $attempt; retrying."
            )
            Start-Sleep -Seconds 3
        }
    }
}

function Get-ReleaseByTag {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tag
    )

    $statusCode = 0
    $escapedTag = [Uri]::EscapeDataString($Tag)
    $result = Invoke-RestMethod `
        -Uri "$apiBase/releases/tags/${escapedTag}?access_token=$escapedToken" `
        -Method Get `
        -SkipHttpErrorCheck `
        -StatusCodeVariable statusCode
    if ($statusCode -eq 404) {
        return $null
    }
    if ($statusCode -lt 200 -or $statusCode -ge 300) {
        throw "Gitee release lookup failed with HTTP $statusCode."
    }
    return $result
}

function Get-OrCreateRelease {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tag
    )

    $release = Get-ReleaseByTag -Tag $Tag
    if ($null -ne $release) {
        return $release
    }
    return Invoke-RestMethod `
        -Uri "$apiBase/releases" `
        -Method Post `
        -TimeoutSec 180 `
        -ContentType "application/x-www-form-urlencoded" `
        -Body @{
            access_token = $accessToken
            tag_name = $Tag
            target_commitish = $Branch
            name = "Attendance Ledger $Tag"
            body = "Attendance Ledger Windows x64 分片自动更新制品。"
            prerelease = "false"
        }
}

function Get-ReleaseAssets {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ReleaseId
    )

    return @(
        Invoke-RestMethod `
            -Uri "$apiBase/releases/$ReleaseId/attach_files?access_token=$escapedToken&per_page=100" `
            -Method Get `
            -TimeoutSec 180
    )
}

function Clear-ReleaseAssets {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ReleaseId
    )

    foreach ($asset in @(Get-ReleaseAssets -ReleaseId $ReleaseId)) {
        $assetId = Get-ObjectProperty -InputObject $asset -Name "id"
        if ($null -ne $assetId) {
            $deleteStatusCode = 0
            Invoke-RestMethod `
                -Uri "$apiBase/releases/$ReleaseId/attach_files/${assetId}?access_token=$escapedToken" `
                -Method Delete `
                -SkipHttpErrorCheck `
                -StatusCodeVariable deleteStatusCode `
                -TimeoutSec 180 | Out-Null
            if (
                $deleteStatusCode -ne 404 -and
                ($deleteStatusCode -lt 200 -or $deleteStatusCode -ge 300)
            ) {
                throw (
                    "Deleting Gitee release attachment $assetId failed " +
                    "with HTTP $deleteStatusCode."
                )
            }
        }
    }
}

function Publish-ReleaseAsset {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ReleaseId,

        [Parameter(Mandatory = $true)]
        [IO.FileInfo]$File
    )

    $endpoint = "$apiBase/releases/$ReleaseId/attach_files"
    for ($attempt = 1; $attempt -le 3; $attempt += 1) {
        try {
            return Invoke-RestMethod `
                -Uri $endpoint `
                -Method Post `
                -TimeoutSec 900 `
                -Form @{
                    access_token = $accessToken
                    file = $File
                }
        } catch {
            if ($attempt -eq 3) {
                throw
            }
            Write-Warning (
                "Uploading $($File.Name) failed on attempt $attempt; retrying."
            )
            Start-Sleep -Seconds 5
        }
    }
}

function Remove-OtherReleases {
    param(
        [Parameter(Mandatory = $true)]
        [int]$CurrentReleaseId
    )

    $releases = [Collections.Generic.List[object]]::new()
    $page = 1
    while ($true) {
        $pageItems = @(
            Invoke-RestMethod `
                -Uri "$apiBase/releases?access_token=$escapedToken&page=$page&per_page=100&direction=desc" `
                -Method Get `
                -TimeoutSec 180
        )
        foreach ($pageItem in $pageItems) {
            $releases.Add($pageItem)
        }
        if ($pageItems.Count -lt 100) {
            break
        }
        $page += 1
    }

    foreach ($release in $releases) {
        $releaseId = [int](Get-ObjectProperty -InputObject $release -Name "id")
        if ($releaseId -eq $CurrentReleaseId) {
            continue
        }
        $tagName = [string](Get-ObjectProperty -InputObject $release -Name "tag_name")
        Write-Host "Deleting old Gitee release $tagName (id=$releaseId)..."
        $deleteStatusCode = 0
        Invoke-RestMethod `
            -Uri "$apiBase/releases/${releaseId}?access_token=$escapedToken" `
            -Method Delete `
            -SkipHttpErrorCheck `
            -StatusCodeVariable deleteStatusCode `
            -TimeoutSec 180 | Out-Null
        if ($deleteStatusCode -eq 404) {
            Write-Host "Old Gitee release $tagName is already absent."
        } elseif ($deleteStatusCode -lt 200 -or $deleteStatusCode -ge 300) {
            throw "Deleting Gitee release $tagName failed with HTTP $deleteStatusCode."
        }
    }
}

function Assert-ManifestMatches {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Actual,

        [Parameter(Mandatory = $true)]
        [object]$Expected
    )

    foreach ($name in @("version", "sha256", "size")) {
        $actualValue = Get-ObjectProperty -InputObject $Actual -Name $name
        $expectedValue = Get-ObjectProperty -InputObject $Expected -Name $name
        if ([string]$actualValue -ne [string]$expectedValue) {
            throw "Published update manifest has an unexpected $name."
        }
    }
    $actualParts = @((Get-ObjectProperty -InputObject $Actual -Name "parts"))
    $expectedParts = @((Get-ObjectProperty -InputObject $Expected -Name "parts"))
    if ($actualParts.Count -ne $expectedParts.Count) {
        throw "Published update manifest has an unexpected part count."
    }
    for ($index = 0; $index -lt $expectedParts.Count; $index += 1) {
        foreach ($name in @("url", "size")) {
            $actualValue = Get-ObjectProperty -InputObject $actualParts[$index] -Name $name
            $expectedValue = Get-ObjectProperty -InputObject $expectedParts[$index] -Name $name
            if ([string]$actualValue -ne [string]$expectedValue) {
                throw "Published update manifest part $($index + 1) has an unexpected $name."
            }
        }
    }
}

$publishedManifestStatusCode = 0
$publishedManifest = Invoke-RestMethod `
    -Uri $publishedManifestUrl `
    -Method Get `
    -SkipHttpErrorCheck `
    -StatusCodeVariable publishedManifestStatusCode
if ($publishedManifestStatusCode -eq 404) {
    $publishedManifest = $null
} elseif (
    $publishedManifestStatusCode -lt 200 -or
    $publishedManifestStatusCode -ge 300
) {
    throw "Gitee update manifest lookup failed with HTTP $publishedManifestStatusCode."
}

$publishToRelease = (
    (Get-ObjectProperty `
        -InputObject $publishedManifest `
        -Name "release_assets_supported") -eq $true
)
if ($publishToRelease) {
    Write-Host "Publishing update parts as Gitee Release attachments."
} else {
    Write-Host (
        "Publishing one compatibility bridge through repository files. " +
        "Later versions will use Gitee Release attachments."
    )
}

$partsDirectory = Join-Path $env:RUNNER_TEMP "attendance-ledger-update-v$Version"
New-Item -ItemType Directory -Path $partsDirectory -Force | Out-Null
Get-ChildItem -LiteralPath $partsDirectory -File | Remove-Item -Force

$chunkSize = if ($publishToRelease) { 20MB } else { 2000000 }
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
        $partName = "part{0:D3}" -f $partNumber
        $partPath = Join-Path $partsDirectory $partName
        [IO.File]::WriteAllBytes($partPath, $buffer)
        $partFiles.Add((Get-Item -LiteralPath $partPath))
        $partNumber += 1
    }
} finally {
    $inputStream.Dispose()
}

$installerManifest = [ordered]@{
    version = $Version
    sha256 = (
        Get-FileHash -LiteralPath $setupFile.FullName -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    size = [long]$setupFile.Length
    parts = @()
}
$tag = "v$Version"
$release = $null

if ($publishToRelease) {
    $release = Get-OrCreateRelease -Tag $tag
    $releaseId = [int](Get-ObjectProperty -InputObject $release -Name "id")
    Clear-ReleaseAssets -ReleaseId $releaseId

    $publishedParts = @()
    foreach ($partFile in $partFiles) {
        Write-Host "Uploading $($partFile.Name) ($($partFile.Length) bytes)..."
        $asset = Publish-ReleaseAsset -ReleaseId $releaseId -File $partFile
        $downloadUrl = [string](
            Get-ObjectProperty -InputObject $asset -Name "browser_download_url"
        )
        if ([string]::IsNullOrWhiteSpace($downloadUrl)) {
            throw "Gitee did not return a download URL for $($partFile.Name)."
        }
        $publishedParts += [ordered]@{
            url = $downloadUrl
            size = [long]$partFile.Length
        }
    }
    $installerManifest["parts"] = $publishedParts

    $assets = @(Get-ReleaseAssets -ReleaseId $releaseId)
    if ($assets.Count -ne $partFiles.Count) {
        throw "Gitee release attachment count verification failed."
    }
    foreach ($partFile in $partFiles) {
        $matchingAssets = @(
            $assets | Where-Object {
                (Get-ObjectProperty -InputObject $_ -Name "name") -eq $partFile.Name
            }
        )
        if (
            $matchingAssets.Count -ne 1 -or
            [long](Get-ObjectProperty `
                -InputObject $matchingAssets[0] `
                -Name "size") -ne $partFile.Length
        ) {
            throw "Gitee release attachment verification failed for $($partFile.Name)."
        }
    }
} else {
    $partsPath = "win32/x64/parts"
    $rawPartsBaseUrl = (
        "https://gitee.com/$Owner/$Repository/raw/$Branch/$partsPath"
    )
    $existingParts = @{}
    $partsStatusCode = 0
    $partsResponse = Invoke-RestMethod `
        -Uri "$(Get-RepositoryContentEndpoint -RepositoryPath $partsPath)?access_token=$escapedToken&ref=$escapedBranch" `
        -Method Get `
        -SkipHttpErrorCheck `
        -StatusCodeVariable partsStatusCode
    if ($partsStatusCode -ge 200 -and $partsStatusCode -lt 300) {
        foreach ($part in @($partsResponse)) {
            $partName = [string](Get-ObjectProperty -InputObject $part -Name "name")
            $partSha = [string](Get-ObjectProperty -InputObject $part -Name "sha")
            if (
                -not [string]::IsNullOrWhiteSpace($partName) -and
                -not [string]::IsNullOrWhiteSpace($partSha)
            ) {
                $existingParts[$partName] = $partSha
            }
        }
    } elseif ($partsStatusCode -ne 404) {
        throw "Gitee update parts lookup failed with HTTP $partsStatusCode."
    }

    $publishedParts = @()
    foreach ($partFile in $partFiles) {
        $repositoryPartPath = "$partsPath/$($partFile.Name)"
        Write-Host "Publishing $repositoryPartPath ($($partFile.Length) bytes)..."
        Publish-RepositoryFile `
            -File $partFile `
            -RepositoryPath $repositoryPartPath `
            -ExistingSha $existingParts[$partFile.Name]
        $publishedParts += [ordered]@{
            url = "$rawPartsBaseUrl/$([Uri]::EscapeDataString($partFile.Name))"
            size = [long]$partFile.Length
        }
    }
    $installerManifest["parts"] = $publishedParts
}

if ($publishToRelease) {
    foreach ($name in @("version", "sha256", "size", "parts")) {
        if ($null -eq (Get-ObjectProperty -InputObject $publishedManifest -Name $name)) {
            throw "The compatibility bridge manifest is missing $name."
        }
    }
    $manifest = [ordered]@{
        version = [string](Get-ObjectProperty `
            -InputObject $publishedManifest `
            -Name "version")
        sha256 = [string](Get-ObjectProperty `
            -InputObject $publishedManifest `
            -Name "sha256")
        size = [long](Get-ObjectProperty `
            -InputObject $publishedManifest `
            -Name "size")
        parts = @((Get-ObjectProperty `
            -InputObject $publishedManifest `
            -Name "parts"))
        release_assets_supported = $true
        release = $installerManifest
    }
} else {
    $manifest = [ordered]@{
        version = $installerManifest["version"]
        sha256 = $installerManifest["sha256"]
        size = $installerManifest["size"]
        parts = $installerManifest["parts"]
        release_assets_supported = $true
    }
}

$manifestFile = Join-Path $partsDirectory "update.json"
$manifestJson = $manifest | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText(
    $manifestFile,
    "$manifestJson`n",
    [Text.UTF8Encoding]::new($false)
)

$existingManifestFile = Get-RepositoryFile -RepositoryPath $manifestPath
$manifestSha = if ($null -eq $existingManifestFile) {
    $null
} else {
    [string](Get-ObjectProperty -InputObject $existingManifestFile -Name "sha")
}
Publish-RepositoryFile `
    -File (Get-Item -LiteralPath $manifestFile) `
    -RepositoryPath $manifestPath `
    -ExistingSha $manifestSha

$verifiedManifestFile = Get-RepositoryFile -RepositoryPath $manifestPath
if ($null -eq $verifiedManifestFile) {
    throw "Published update manifest could not be read back from Gitee."
}
$encodedContent = [string](
    Get-ObjectProperty -InputObject $verifiedManifestFile -Name "content"
)
$verifiedManifestJson = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String(($encodedContent -replace "\s", ""))
)
$verifiedManifest = $verifiedManifestJson | ConvertFrom-Json
$verifiedEffectiveManifest = if ($publishToRelease) {
    Get-ObjectProperty -InputObject $verifiedManifest -Name "release"
} else {
    $verifiedManifest
}
Assert-ManifestMatches `
    -Actual $verifiedEffectiveManifest `
    -Expected $installerManifest

if ($null -eq $release) {
    $release = Get-OrCreateRelease -Tag $tag
}
$currentReleaseId = [int](Get-ObjectProperty -InputObject $release -Name "id")
Remove-OtherReleases -CurrentReleaseId $currentReleaseId

Write-Host "Published Attendance Ledger v$Version update to Gitee."
Write-Host "Manifest: $publishedManifestUrl"
Write-Host "Only Gitee release $tag is retained."
