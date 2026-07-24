$script:PalworldBuildInputManifestVersion = 1
$script:PalworldBuildInputResourceName = "PalworldServerOperations.BuildInputs.json"

function Get-PalworldSha256Hex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}

function Get-PalworldCanonicalBuildInput {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $extension = [IO.Path]::GetExtension($RelativePath).ToLowerInvariant()
    $leafName = [IO.Path]::GetFileName($RelativePath)
    $textExtensions = @(".cs", ".env", ".json", ".md", ".ps1", ".py", ".sh", ".txt")
    $textLeafNames = @("Dockerfile", "LICENSE", "manager", "pal", "test")
    if ($extension -in $textExtensions -or $leafName -in $textLeafNames) {
        $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        $text = $text.Replace("`r`n", "`n").Replace("`r", "`n")
        return [pscustomobject]@{
            mode = "text-utf8-lf"
            bytes = [Text.Encoding]::UTF8.GetBytes($text)
        }
    }
    return [pscustomobject]@{
        mode = "binary"
        bytes = [IO.File]::ReadAllBytes($Path)
    }
}

function Get-PalworldWindowsBuildInputManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("User", "Admin")]
        [string]$Edition,
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $root = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $rootPrefix = $root + [IO.Path]::DirectorySeparatorChar
    $paths = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    function Add-BuildInput {
        param([Parameter(Mandatory = $true)][string]$RelativePath)

        $normalizedRelativePath = $RelativePath.Replace("/", [IO.Path]::DirectorySeparatorChar)
        $absolutePath = [IO.Path]::GetFullPath((Join-Path $root $normalizedRelativePath))
        if (-not $absolutePath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Windows build input escapes the repository: $RelativePath"
        }
        if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
            throw "Windows build input is missing: $RelativePath"
        }
        [void]$paths.Add($absolutePath)
    }

    foreach ($relativePath in @(
        "LICENSE",
        "tools/windows-client/assets/palworld-server-operations.ico",
        "tools/windows-client/build-exe.ps1",
        "tools/windows-client/build-input-manifest.ps1",
        "tools/windows-client/palworld-rest-client.ps1",
        "tools/windows-client/source/PalworldServerOperationsLauncher.cs"
    )) {
        Add-BuildInput $relativePath
    }

    if ($Edition -eq "Admin") {
        foreach ($relativePath in @(
            "tools/windows-ssh-manager/palworld-ssh-management.ps1",
            "tools/windows-ssh-manager/vendor/packages.lock.json",
            "tools/windows-ssh-manager/vendor/THIRD_PARTY.txt",
            "tools/windows-ssh-manager/generated/manifest.json"
        )) {
            Add-BuildInput $relativePath
        }

        $vendorDirectory = Join-Path $root "tools/windows-ssh-manager/vendor"
        foreach ($assembly in Get-ChildItem -LiteralPath $vendorDirectory -Filter *.dll -File) {
            Add-BuildInput $assembly.FullName.Substring($rootPrefix.Length)
        }

        $payloadManifestPath = Join-Path $root "tools/windows-ssh-manager/generated/manifest.json"
        $payloadManifest = Get-Content -Raw -LiteralPath $payloadManifestPath | ConvertFrom-Json
        if ([int]$payloadManifest.version -ne 2) {
            throw "SSH payload manifest version 2 is required."
        }
        foreach ($payloadName in @("setup", "test", "manage")) {
            $record = $payloadManifest.payloads.$payloadName
            if ($null -eq $record -or [string]::IsNullOrWhiteSpace([string]$record.file)) {
                throw "SSH payload manifest entry is invalid: $payloadName"
            }
            Add-BuildInput ("tools/windows-ssh-manager/generated/" + [string]$record.file)
            foreach ($source in @($record.sources)) {
                if ([string]::IsNullOrWhiteSpace([string]$source.path)) {
                    throw "SSH payload source entry is invalid: $payloadName"
                }
                Add-BuildInput ([string]$source.path)
            }
        }
    }

    $records = @()
    foreach ($absolutePath in @($paths) | Sort-Object { $_.Substring($rootPrefix.Length) }) {
        $relativePath = $absolutePath.Substring($rootPrefix.Length).Replace("\", "/")
        $canonicalInput = Get-PalworldCanonicalBuildInput `
            -Path $absolutePath -RelativePath $relativePath
        $records += [ordered]@{
            path = $relativePath
            mode = [string]$canonicalInput.mode
            size = [long]$canonicalInput.bytes.Length
            sha256 = Get-PalworldSha256Hex -Bytes $canonicalInput.bytes
        }
    }

    $canonical = New-Object Text.StringBuilder
    [void]$canonical.Append("palworld-windows-build-inputs-v1`n")
    [void]$canonical.Append("edition=$($Edition.ToLowerInvariant())`n")
    foreach ($record in $records) {
        [void]$canonical.Append([string]$record.path)
        [void]$canonical.Append([char]0)
        [void]$canonical.Append([string]$record.mode)
        [void]$canonical.Append([char]0)
        [void]$canonical.Append(([long]$record.size).ToString([Globalization.CultureInfo]::InvariantCulture))
        [void]$canonical.Append([char]0)
        [void]$canonical.Append([string]$record.sha256)
        [void]$canonical.Append("`n")
    }
    $fingerprint = Get-PalworldSha256Hex -Bytes ([Text.Encoding]::UTF8.GetBytes($canonical.ToString()))

    return [ordered]@{
        format_version = $script:PalworldBuildInputManifestVersion
        edition = $Edition.ToLowerInvariant()
        fingerprint = $fingerprint
        inputs = $records
    }
}

function Write-PalworldWindowsBuildInputManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("User", "Admin")]
        [string]$Edition,
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,
        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $manifest = Get-PalworldWindowsBuildInputManifest `
        -Edition $Edition -RepositoryRoot $RepositoryRoot
    $json = $manifest | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText(
        [IO.Path]::GetFullPath($Destination),
        $json + "`n",
        (New-Object Text.UTF8Encoding($false))
    )
    return $manifest
}
