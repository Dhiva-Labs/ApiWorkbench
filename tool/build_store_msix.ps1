# Builds the Microsoft Store package (build\windows\x64\runner\Release\ApiWorkbench.msix).
#
#   powershell -ExecutionPolicy Bypass -File tool\build_store_msix.ps1
#   pwsh tool\build_store_msix.ps1 -Arch arm64 -OutDir dist
#
# -Arch is x64 or arm64 and defaults to the machine's own architecture. The
# x64 package keeps its name (ApiWorkbench.msix) and place; the arm64 package
# is ApiWorkbench-arm64.msix in build\windows\arm64\runner\Release. -OutDir
# writes the package there instead.
#
# The Store build leaves out the third-party meme clips (assets/sounds/meme/),
# whose rights belong to others. Every other build (Linux, snap, deb, Android,
# a plain `flutter build windows`) keeps them.
#
# 1. pubspec.yaml is copied aside and the `- assets/sounds/meme/` asset line is
#    removed, so the clips are not bundled at all.
# 2. `flutter build windows --dart-define=CHAOS_MEME_SOUNDS=false` builds the
#    app; kChaosMemeSounds then defaults Chaos Mode to the synthesized sounds
#    and hides the clips from the sound picker.
# 3. The bundle is checked for leftovers, `dart run msix:create --store`
#    packs it, and the original pubspec.yaml is put back in every case.
param(
  [ValidateSet('x64', 'arm64')]
  [string]$Arch,
  [string]$OutDir
)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

if (-not $Arch) {
  switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { $Arch = 'x64' }
    'ARM64' { $Arch = 'arm64' }
    default { throw "unsupported PROCESSOR_ARCHITECTURE '$env:PROCESSOR_ARCHITECTURE' (AMD64 or ARM64)" }
  }
}
$release = "build\windows\$Arch\runner\Release"

$pubspec = Join-Path (Get-Location) 'pubspec.yaml'
$backup = "$pubspec.store-backup"
$utf8 = New-Object System.Text.UTF8Encoding $false
$original = [IO.File]::ReadAllText($pubspec)
$memeLine = '(?m)^[ \t]*- assets/sounds/meme/[ \t]*\r?\n'
if ($original -notmatch $memeLine) {
  throw 'pubspec.yaml has no "- assets/sounds/meme/" asset line; update this script.'
}

Copy-Item $pubspec $backup -Force
try {
  [IO.File]::WriteAllText($pubspec, ($original -replace $memeLine, ''), $utf8)

  flutter build windows --release --dart-define=CHAOS_MEME_SOUNDS=false
  if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed ($LASTEXITCODE)" }

  $assets = "$release\data\flutter_assets"
  $leaks = @(Get-ChildItem $assets -Recurse -File | Where-Object { $_.Name -like 'meme_*' })
  if ($leaks.Count -gt 0) {
    throw "Meme clips are still in the bundle: $($leaks.FullName -join ', ')"
  }

  # msix:create assumes x64 on every host, so the architecture is explicit.
  $msixArgs = @('--store', '--build-windows', 'false', '--architecture', $Arch)
  if ($Arch -ne 'x64') { $msixArgs += @('--output-name', "ApiWorkbench-$Arch") }
  if ($OutDir) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $msixArgs += @('--output-path', (Resolve-Path $OutDir).Path)
  }
  dart run msix:create @msixArgs
  if ($LASTEXITCODE -ne 0) { throw "msix:create failed ($LASTEXITCODE)" }
} finally {
  Move-Item $backup $pubspec -Force
}

Get-ChildItem $(if ($OutDir) { $OutDir } else { $release }) -Filter *.msix |
  Format-Table Name, Length, LastWriteTime
