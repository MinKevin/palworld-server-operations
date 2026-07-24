[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("User", "Admin")]
    [string]$Edition,
    [Parameter(Mandatory = $true)]
    [string]$ExePath,
    [string]$RepositoryRoot
)

$ErrorActionPreference = "Stop"

if (-not $RepositoryRoot) {
    $RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
}
$manifestSource = Join-Path $PSScriptRoot "build-input-manifest.ps1"
if (-not (Test-Path -LiteralPath $manifestSource -PathType Leaf)) {
    throw "Windows build-input manifest helper is missing: $manifestSource"
}
. $manifestSource

$resolvedExe = [IO.Path]::GetFullPath($ExePath)
if (-not (Test-Path -LiteralPath $resolvedExe -PathType Leaf)) {
    throw "Windows executable is missing: $resolvedExe"
}

$assemblyBytes = [IO.File]::ReadAllBytes($resolvedExe)
$assembly = [Reflection.Assembly]::Load($assemblyBytes)
$stream = $assembly.GetManifestResourceStream($script:PalworldBuildInputResourceName)
if ($null -eq $stream) {
    throw "Embedded build-input manifest is missing from $resolvedExe"
}
try {
    $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true)
    try {
        $embedded = $reader.ReadToEnd() | ConvertFrom-Json
    }
    finally {
        $reader.Dispose()
    }
}
finally {
    $stream.Dispose()
}

$expected = Get-PalworldWindowsBuildInputManifest `
    -Edition $Edition -RepositoryRoot $RepositoryRoot
if ([int]$embedded.format_version -ne [int]$expected.format_version) {
    throw "Build-input manifest format mismatch in $resolvedExe"
}
if ([string]$embedded.edition -cne [string]$expected.edition) {
    throw "Build-input manifest edition mismatch in $resolvedExe (expected $($expected.edition), embedded $($embedded.edition))"
}

$embeddedInputs = @($embedded.inputs)
$expectedInputs = @($expected.inputs)
if ($embeddedInputs.Count -ne $expectedInputs.Count) {
    throw "Build-input set mismatch in $resolvedExe (expected $($expectedInputs.Count) files, embedded $($embeddedInputs.Count))"
}
for ($index = 0; $index -lt $expectedInputs.Count; $index++) {
    $actual = $embeddedInputs[$index]
    $wanted = $expectedInputs[$index]
    if ([string]$actual.path -cne [string]$wanted.path) {
        throw "Build-input path mismatch in $resolvedExe at index $index (expected $($wanted.path), embedded $($actual.path))"
    }
    if ([string]$actual.mode -cne [string]$wanted.mode -or
        [long]$actual.size -ne [long]$wanted.size -or
        [string]$actual.sha256 -cne [string]$wanted.sha256) {
        throw "Stale Windows executable: $resolvedExe was not built from current input $($wanted.path)"
    }
}
if ([string]$embedded.fingerprint -cne [string]$expected.fingerprint) {
    throw "Stale Windows executable: $resolvedExe has build-input fingerprint $($embedded.fingerprint), expected $($expected.fingerprint)"
}

Write-Output "Verified $Edition build inputs: $resolvedExe"
Write-Output "Build input fingerprint: $($expected.fingerprint)"
