# Packages the Windows release build for the machine's architecture (x64 or
# arm64, or the one given with -Arch):
#
#   <OutDir>\ApiWorkbench-<version>-windows-<arch>.zip   the plain release build
#   <OutDir>\ApiWorkbench[-arm64].msix                   the Microsoft Store package
#
# Run `flutter build windows --release` first. The zip packs that build as it
# is (meme clips included). The Store package comes from
# tool\build_store_msix.ps1, which rebuilds without the clips, so the zip is
# made first.
#
#   pwsh tool\package_windows.ps1 -OutDir dist
param(
    [string]$OutDir = 'dist',
    [ValidateSet('x64', 'arm64')]
    [string]$Arch
)
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
if (-not $Arch) {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { $Arch = 'x64' }
        'ARM64' { $Arch = 'arm64' }
        default { throw "unsupported PROCESSOR_ARCHITECTURE '$env:PROCESSOR_ARCHITECTURE' (AMD64 or ARM64)" }
    }
}
$versionLine = Select-String -Path pubspec.yaml -Pattern '^version:\s*(\S+)' | Select-Object -First 1
$version = ($versionLine.Matches[0].Groups[1].Value -split '\+')[0]
$release = "build\windows\$Arch\runner\Release"
if (-not (Test-Path "$release\apiworkbench.exe")) {
    throw "$release\apiworkbench.exe is missing - run: flutter build windows --release"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$out = (Resolve-Path $OutDir).Path

$name = "ApiWorkbench-$version-windows-$Arch"
$stage = Join-Path ([IO.Path]::GetTempPath()) "apiworkbench-zip-$([guid]::NewGuid())"
try {
    New-Item -ItemType Directory -Path $stage | Out-Null
    Copy-Item -Recurse -Path $release -Destination (Join-Path $stage $name)
    $zip = Join-Path $out "$name.zip"
    if (Test-Path $zip) { Remove-Item $zip }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory(
        (Join-Path $stage $name), $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
} finally {
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
}
"Built $zip"

& (Join-Path $PSScriptRoot 'build_store_msix.ps1') -Arch $Arch -OutDir $out
