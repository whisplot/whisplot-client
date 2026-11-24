[CmdletBinding()]
param(
    [string]$Flutter = 'flutter',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../artifacts')
)

$ErrorActionPreference = 'Stop'
if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne
    [Runtime.InteropServices.Architecture]::X64) {
    throw 'This script packages builds made on an x64 Windows host.'
}
$app = Join-Path $PSScriptRoot '../apps/mobile'
$versionLine = Get-Content -LiteralPath (Join-Path $app 'pubspec.yaml') |
    Select-String '^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$'
if (!$versionLine) {
    throw 'Could not read the application version and build number.'
}
$version = $versionLine.Matches[0].Groups[1].Value
$build = $versionLine.Matches[0].Groups[2].Value

$destination = New-Item -ItemType Directory -Path $OutputDirectory -Force
$archive = Join-Path $destination.FullName "Whisplot-$version-build$build-windows-x64.zip"
if (Test-Path -LiteralPath $archive) {
    throw "Package already exists at $archive."
}

Push-Location -LiteralPath $app
try {
    & $Flutter build windows --release
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter Windows build failed with exit code $LASTEXITCODE."
    }

    $release = 'build/windows/x64/runner/Release'
    foreach ($file in 'Whisplot.exe', 'flutter_windows.dll', 'data/app.so', 'data/icudtl.dat') {
        if (!(Test-Path -LiteralPath (Join-Path $release $file) -PathType Leaf)) {
            throw "The Windows build is missing $file."
        }
    }
    $payload = Get-ChildItem -LiteralPath $release |
        Where-Object { $_.Extension -notin '.pdb', '.lib', '.exp' }
    Compress-Archive -LiteralPath $payload.FullName -DestinationPath $archive
    $sha256 = Get-FileHash -LiteralPath $archive -Algorithm SHA256
    "$($sha256.Hash.ToLowerInvariant())  $(Split-Path -Leaf $archive)" |
        Set-Content -LiteralPath "$archive.sha256" -Encoding ascii
    Get-Item -LiteralPath $archive
} finally {
    Pop-Location
}
