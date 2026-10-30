# Compiles the command-line runner, apiworkbench-cli.exe, for the machine's
# architecture (x64 or arm64, or the one given with -Arch).
#
#   pwsh tool\build_cli.ps1 [-OutDir build\cli\<arch>]
#
# Result:
#   <OutDir>\bin\apiworkbench-cli.exe   the executable
#   <OutDir>\lib\                       native libraries it loads, if it has any
#
# `dart build cli` is tried first: it also builds Dart native assets (build
# hooks), which `dart compile exe` refuses to do, and some of the app's
# packages have hooks. `dart compile exe` is the fallback for an SDK without
# `dart build`. The exe finds its libraries at ..\lib relative to itself, so
# keep bin\ and lib\ together. Uses the `dart` on PATH (the Flutter SDK's).
param(
    [string]$OutDir,
    [ValidateSet('x64', 'arm64')]
    [string]$Arch
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-Location (Join-Path $PSScriptRoot '..')
if (-not $Arch) {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { $Arch = 'x64' }
        'ARM64' { $Arch = 'arm64' }
        default { throw "unsupported PROCESSOR_ARCHITECTURE '$env:PROCESSOR_ARCHITECTURE' (AMD64 or ARM64)" }
    }
}
if (-not $OutDir) { $OutDir = "build\cli\$Arch" }
$entry = 'bin\apiworkbench_cli.dart'

# Dart reads the package list that `flutter pub get` writes.
if (-not (Test-Path '.dart_tool\package_config.json')) { flutter pub get }

$out = if ([IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path (Get-Location).Path $OutDir }
$stage = "$out.building"
Remove-Item -Recurse -Force $out, $stage -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'bin') | Out-Null

# `dart build` is missing from older SDKs: ask for its help to find out.
$hasBuild = $true
try { dart build cli --help *> $null } catch { $hasBuild = $false }
if ($LASTEXITCODE -ne 0) { $hasBuild = $false }
$global:LASTEXITCODE = 0

if ($hasBuild) {
    'Building apiworkbench-cli with ''dart build cli'''
    $tmp = Join-Path $stage 'dart-build'
    dart build cli -t $entry -o $tmp
    if ($LASTEXITCODE -ne 0) { throw "dart build cli failed ($LASTEXITCODE)" }
    Copy-Item (Join-Path $tmp 'bundle\bin\apiworkbench_cli.exe') (Join-Path $stage 'bin\apiworkbench-cli.exe')
    $libs = Join-Path $tmp 'bundle\lib'
    if ((Test-Path $libs) -and (Get-ChildItem $libs -Recurse -File | Select-Object -First 1)) {
        Copy-Item -Recurse $libs (Join-Path $stage 'lib')
    }
    Remove-Item -Recurse -Force $tmp
} else {
    'Building apiworkbench-cli with ''dart compile exe'''
    dart compile exe $entry -o (Join-Path $stage 'bin\apiworkbench-cli.exe')
    if ($LASTEXITCODE -ne 0) { throw "dart compile exe failed ($LASTEXITCODE)" }
}
Move-Item $stage $out

& (Join-Path $out 'bin\apiworkbench-cli.exe') --version
if ($LASTEXITCODE -ne 0) { throw "apiworkbench-cli.exe --version failed ($LASTEXITCODE)" }
"Built $out\bin\apiworkbench-cli.exe"
