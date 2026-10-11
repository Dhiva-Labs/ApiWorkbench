# Builds the Microsoft Store package (build\windows\x64\runner\Release\ApiWorkbench.msix).
#
#   powershell -ExecutionPolicy Bypass -File tool\build_store_msix.ps1
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
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

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

  $assets = 'build\windows\x64\runner\Release\data\flutter_assets'
  $leaks = @(Get-ChildItem $assets -Recurse -File | Where-Object { $_.Name -like 'meme_*' })
  if ($leaks.Count -gt 0) {
    throw "Meme clips are still in the bundle: $($leaks.FullName -join ', ')"
  }

  dart run msix:create --store --build-windows false
  if ($LASTEXITCODE -ne 0) { throw "msix:create failed ($LASTEXITCODE)" }
} finally {
  Move-Item $backup $pubspec -Force
}

Get-ChildItem build\windows\x64\runner\Release -Filter *.msix |
  Format-Table Name, Length, LastWriteTime
