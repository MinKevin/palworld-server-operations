[CmdletBinding()]
param(
    [ValidateSet("All", "User", "Admin")]
    [string]$Edition = "All",
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$clientScript = Join-Path $PSScriptRoot "palworld-rest-client.ps1"
$launcherSource = Join-Path $PSScriptRoot "source\PalworldServerOperationsLauncher.cs"
$iconPath = Join-Path $PSScriptRoot "assets\palworld-server-operations.ico"
$buildInputManifestSource = Join-Path $PSScriptRoot "build-input-manifest.ps1"
$buildInputVerifier = Join-Path $PSScriptRoot "verify-exe-build-inputs.ps1"
$projectLicense = Join-Path $repositoryRoot "LICENSE"
$sshRoot = Join-Path $repositoryRoot "tools\windows-ssh-manager"
$sshModule = Join-Path $sshRoot "palworld-ssh-management.ps1"
$sshVendor = Join-Path $sshRoot "vendor"
$sshPayloads = Join-Path $sshRoot "generated"
$compilerCandidates = @(
    (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
    (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
)
$compiler = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if (-not $compiler) { throw ".NET Framework C# compiler was not found." }
foreach ($required in @(
    $clientScript,
    $launcherSource,
    $iconPath,
    $buildInputManifestSource,
    $buildInputVerifier,
    $projectLicense
)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Build input is missing: $required" }
}
. $buildInputManifestSource

function Copy-Utf8BomPowerShellResource {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $content = [IO.File]::ReadAllText($Source, [Text.Encoding]::UTF8)
    $utf8Bom = New-Object Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($Destination, $content, $utf8Bom)
}

function Assert-PalworldSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label is missing: $Path"
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Expected.ToLowerInvariant()) {
        throw "$Label SHA-256 mismatch: $Path (expected $Expected, actual $actual)"
    }
}

function Assert-PalworldAdminBundleInputs {
    $lockPath = Join-Path $sshVendor "packages.lock.json"
    $noticePath = Join-Path $sshVendor "THIRD_PARTY.txt"
    $manifestPath = Join-Path $sshPayloads "manifest.json"
    foreach ($required in @($lockPath, $noticePath, $manifestPath)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Admin dependency metadata is missing: $required"
        }
    }

    $lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
    $expectedAssemblies = @{}
    foreach ($package in @($lock.packages)) {
        if (-not [string]$package.authors -or -not [string]$package.copyright -or
            @($package.legal_documents).Count -eq 0) {
            throw "Incomplete package legal metadata: $($package.id) $($package.version)"
        }
        foreach ($assembly in @($package.assemblies)) {
            $name = [string]$assembly.file
            $hash = [string]$assembly.sha256
            if ($expectedAssemblies.ContainsKey($name) -and $expectedAssemblies[$name] -ne $hash) {
                throw "Conflicting locked hashes for SSH runtime assembly: $name"
            }
            $expectedAssemblies[$name] = $hash
        }
    }
    $actualAssemblies = @(
        Get-ChildItem -LiteralPath $sshVendor -Filter *.dll -File | Sort-Object Name
    )
    if ($actualAssemblies.Count -ne $expectedAssemblies.Count) {
        throw "SSH runtime DLL set does not match packages.lock.json."
    }
    foreach ($assembly in $actualAssemblies) {
        if (-not $expectedAssemblies.ContainsKey($assembly.Name)) {
            throw "Unpinned SSH runtime DLL is present: $($assembly.Name)"
        }
        Assert-PalworldSha256 `
            -Path $assembly.FullName `
            -Expected ([string]$expectedAssemblies[$assembly.Name]) `
            -Label "SSH runtime assembly"
    }
    $notice = [IO.File]::ReadAllText($noticePath, [Text.Encoding]::UTF8)
    foreach ($package in @($lock.packages)) {
        if (-not $notice.Contains([string]$package.copyright)) {
            throw "THIRD_PARTY.txt omits package copyright: $($package.id)"
        }
        foreach ($document in @($package.legal_documents)) {
            if (-not $notice.Contains([string]$document.sha256)) {
                throw "THIRD_PARTY.txt omits a locked legal document: $($package.id)"
            }
        }
    }

    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    if ([int]$manifest.version -ne 2) {
        throw "SSH payload manifest version 2 is required. Rebuild the payloads."
    }
    foreach ($payloadName in @("setup", "test", "manage")) {
        $record = $manifest.payloads.$payloadName
        if ($null -eq $record -or [string]$record.file -ne "$payloadName.tar.gz") {
            throw "SSH payload manifest entry is invalid: $payloadName"
        }
        $payloadPath = Join-Path $sshPayloads ([string]$record.file)
        Assert-PalworldSha256 `
            -Path $payloadPath -Expected ([string]$record.sha256) -Label "SSH payload"
        if ((Get-Item -LiteralPath $payloadPath).Length -ne [long]$record.size) {
            throw "SSH payload size mismatch: $payloadPath"
        }
        if (@($record.entries).Count -ne @($record.sources).Count) {
            throw "SSH payload source manifest is incomplete: $payloadName"
        }
        foreach ($source in @($record.sources)) {
            $sourcePath = Join-Path $repositoryRoot ([string]$source.path)
            Assert-PalworldSha256 `
                -Path $sourcePath -Expected ([string]$source.sha256) -Label "SSH payload source"
        }
    }
}

function Build-ClientEdition {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("User", "Admin")][string]$Name,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $resolvedOutput = [IO.Path]::GetFullPath($Destination)
    $outputDirectory = Split-Path -Parent $resolvedOutput
    if (-not (Test-Path -LiteralPath $outputDirectory)) {
        [void](New-Item -ItemType Directory -Path $outputDirectory -Force)
    }
    $temporaryOutput = "$resolvedOutput.building"
    $temporaryResourceDirectory = Join-Path `
        ([IO.Path]::GetTempPath()) `
        ("palworld-windows-build-" + [Guid]::NewGuid().ToString("N"))
    Remove-Item -LiteralPath $temporaryOutput -Force -ErrorAction SilentlyContinue
    [void](New-Item -ItemType Directory -Path $temporaryResourceDirectory)
    $clientResource = Join-Path $temporaryResourceDirectory "PalworldServerOperations.Client.ps1"
    $buildInputResource = Join-Path $temporaryResourceDirectory "PalworldServerOperations.BuildInputs.json"
    Copy-Utf8BomPowerShellResource -Source $clientScript -Destination $clientResource

    $arguments = @(
        "/nologo",
        "/utf8output",
        "/target:winexe",
        "/platform:anycpu",
        "/optimize+",
        "/debug-",
        "/reference:System.dll",
        "/reference:System.Windows.Forms.dll",
        "/win32icon:$iconPath",
        "/out:$temporaryOutput",
        "/resource:$clientResource,PalworldServerOperations.Client.ps1",
        "/resource:$iconPath,PalworldServerOperations.Icon.ico",
        "/resource:$projectLicense,PalworldServerOperations.License.txt"
    )
    if ($Name -eq "Admin") {
        Assert-PalworldAdminBundleInputs
        foreach ($required in @(
            $sshModule,
            (Join-Path $sshVendor "Renci.SshNet.dll"),
            (Join-Path $sshVendor "THIRD_PARTY.txt"),
            (Join-Path $sshPayloads "setup.tar.gz"),
            (Join-Path $sshPayloads "test.tar.gz"),
            (Join-Path $sshPayloads "manage.tar.gz")
        )) {
            if (-not (Test-Path -LiteralPath $required)) {
                throw "Admin SSH build input is missing: $required"
            }
        }
        $sshModuleResource = Join-Path $temporaryResourceDirectory "PalworldServerOperations.SshModule.ps1"
        Copy-Utf8BomPowerShellResource -Source $sshModule -Destination $sshModuleResource
        $arguments += "/define:ADMIN"
        $arguments += "/resource:$sshModuleResource,PalworldServerOperations.SshModule.ps1"
        $arguments += "/resource:$(Join-Path $sshVendor 'THIRD_PARTY.txt'),PalworldServerOperations.ThirdParty.txt"
        foreach ($assembly in Get-ChildItem -LiteralPath $sshVendor -Filter *.dll | Sort-Object Name) {
            $arguments += "/resource:$($assembly.FullName),PalworldServerOperations.SshRuntime.$($assembly.Name)"
        }
        foreach ($payloadName in @("setup", "test", "manage")) {
            $payload = Join-Path $sshPayloads "$payloadName.tar.gz"
            $arguments += "/resource:$payload,PalworldServerOperations.SshPayload.$payloadName.tar.gz"
        }
    }
    $buildManifest = Write-PalworldWindowsBuildInputManifest `
        -Edition $Name `
        -RepositoryRoot $repositoryRoot `
        -Destination $buildInputResource
    $arguments += "/resource:$buildInputResource,$script:PalworldBuildInputResourceName"
    $arguments += $launcherSource

    try {
        & $compiler @arguments
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temporaryOutput)) {
            throw "$Name EXE compilation failed with exit code $LASTEXITCODE."
        }
        & $buildInputVerifier `
            -Edition $Name `
            -ExePath $temporaryOutput `
            -RepositoryRoot $repositoryRoot
        $copied = $false
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            try {
                Copy-Item -LiteralPath $temporaryOutput -Destination $resolvedOutput -Force
                $copied = $true
                break
            }
            catch [IO.IOException] {
                if ($attempt -eq 10) {
                    throw "Close the running Palworld $Name client and build again: $resolvedOutput"
                }
                Start-Sleep -Milliseconds 250
            }
        }
        if (-not $copied) { throw "EXE output could not be replaced: $resolvedOutput" }
    }
    finally {
        Remove-Item -LiteralPath $temporaryOutput -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $temporaryResourceDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    $file = Get-Item -LiteralPath $resolvedOutput
    $hash = Get-FileHash -LiteralPath $resolvedOutput -Algorithm SHA256
    Write-Output "Built ${Name}: $($file.FullName)"
    Write-Output "Size: $($file.Length) bytes"
    Write-Output "SHA256: $($hash.Hash)"
    Write-Output "Build inputs: $($buildManifest.fingerprint)"
}

if ($OutputPath) {
    $singleEdition = if ($Edition -eq "All") { "User" } else { $Edition }
    Build-ClientEdition -Name $singleEdition -Destination $OutputPath
    return
}

if ($Edition -in @("All", "User")) {
    Build-ClientEdition `
        -Name "User" `
        -Destination (Join-Path $repositoryRoot "windows\Palworld Server Operations - Client.exe")
}
if ($Edition -in @("All", "Admin")) {
    Build-ClientEdition `
        -Name "Admin" `
        -Destination (Join-Path $repositoryRoot "windows\Palworld Server Operations - Admin.exe")
}
