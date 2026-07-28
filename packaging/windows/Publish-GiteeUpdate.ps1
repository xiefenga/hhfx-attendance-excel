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

$chunkSize = 2000000
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

function Publish-RepositoryFile {
    param(
        [Parameter(Mandatory = $true)]
        [IO.FileInfo]$File,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,

        [AllowNull()]
        [string]$ExistingSha
    )

    $endpoint = Get-RepositoryContentEndpoint -RepositoryPath $RepositoryPath
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
                -Uri $endpoint `
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

$partsEndpoint = Get-RepositoryContentEndpoint -RepositoryPath $partsPath
$partsStatusCode = 0
$existingParts = Invoke-RestMethod `
    -Uri "${partsEndpoint}?access_token=$escapedToken&ref=$([Uri]::EscapeDataString($Branch))" `
    -Method Get `
    -SkipHttpErrorCheck `
    -StatusCodeVariable partsStatusCode
if ($partsStatusCode -eq 404) {
    $existingParts = @()
} elseif ($partsStatusCode -lt 200 -or $partsStatusCode -ge 300) {
    throw "Gitee update parts lookup failed with HTTP $partsStatusCode."
}

$existingPartShas = @{}
foreach ($existingPart in @($existingParts)) {
    if (
        $null -ne $existingPart -and
        $null -ne $existingPart.PSObject.Properties["name"] -and
        $null -ne $existingPart.PSObject.Properties["sha"]
    ) {
        $existingPartShas[[string]$existingPart.name] = [string]$existingPart.sha
    }
}
foreach ($partFile in $partFiles) {
    $repositoryPartPath = "$partsPath/$($partFile.Name)"
    Write-Host "Publishing $repositoryPartPath ($($partFile.Length) bytes)..."
    Publish-RepositoryFile `
        -File $partFile `
        -RepositoryPath $repositoryPartPath `
        -ExistingSha $existingPartShas[[string]$partFile.Name]
}

$manifestPath = "win32/x64/update.json"
$manifestFile = Join-Path $partsDirectory "update.json"
[IO.File]::WriteAllText(
    $manifestFile,
    "$manifestJson`n",
    [Text.UTF8Encoding]::new($false)
)

$manifestEndpoint = Get-RepositoryContentEndpoint -RepositoryPath $manifestPath
$manifestStatusCode = 0
$existingManifest = Invoke-RestMethod `
    -Uri "${manifestEndpoint}?access_token=$escapedToken&ref=$([Uri]::EscapeDataString($Branch))" `
    -Method Get `
    -SkipHttpErrorCheck `
    -StatusCodeVariable manifestStatusCode
if ($manifestStatusCode -eq 404) {
    $manifestSha = $null
} elseif ($manifestStatusCode -ge 200 -and $manifestStatusCode -lt 300) {
    $manifestSha = [string]$existingManifest.sha
} else {
    throw "Gitee update manifest lookup failed with HTTP $manifestStatusCode."
}
Publish-RepositoryFile `
    -File (Get-Item -LiteralPath $manifestFile) `
    -RepositoryPath $manifestPath `
    -ExistingSha $manifestSha

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
