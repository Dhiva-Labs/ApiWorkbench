#!/usr/bin/env bash
# Builds the Google Play app bundle (dist/play/ApiWorkbench-<version>.aab).
#
#   tool/build_play_aab.sh
#
# Like the Microsoft Store build (tool/build_store_msix.ps1), the Play build
# leaves out the third-party meme clips (assets/sounds/meme/), whose rights
# belong to others. The GitHub APK, Linux, snap and deb builds keep them.
#
# 1. pubspec.yaml is copied aside and the `- assets/sounds/meme/` asset line is
#    removed, so the clips are not bundled at all.
# 2. `flutter build appbundle --dart-define=CHAOS_MEME_SOUNDS=false` builds the
#    bundle; kChaosMemeSounds then defaults Chaos Mode to the synthesized
#    sounds and hides the clips from the sound picker.
# 3. The bundle is checked for leftover clips and for the upload key's
#    signature, and the original pubspec.yaml is put back in every case.
#
# Needs android/key.properties pointing at the upload keystore; without it
# Gradle signs with the debug key and Play rejects the upload, so this script
# refuses to start. On a network with broken IPv6, run it with
# JAVA_TOOL_OPTIONS=-Djava.net.preferIPv4Stack=true.
set -euo pipefail

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ"

KEYPROPS="android/key.properties"
[ -f "$KEYPROPS" ] ||
  { echo "Missing $KEYPROPS - the Play bundle must be signed with the upload key."; exit 1; }
STOREFILE="$(sed -n 's/^storeFile=//p' "$KEYPROPS")"
[ -f "$STOREFILE" ] ||
  { echo "Upload keystore $STOREFILE (from $KEYPROPS) not found."; exit 1; }

PUBSPEC="pubspec.yaml"
BACKUP="$PUBSPEC.play-backup"
MEME_LINE='^[[:space:]]*- assets/sounds/meme/[[:space:]]*$'
grep -q "$MEME_LINE" "$PUBSPEC" ||
  { echo 'pubspec.yaml has no "- assets/sounds/meme/" asset line; update this script.'; exit 1; }

VERSION="$(sed -n 's/^version: *//p' "$PUBSPEC")"
NAME="${VERSION%%+*}"

cp "$PUBSPEC" "$BACKUP"
trap 'mv -f "$BACKUP" "$PUBSPEC"' EXIT
grep -v "$MEME_LINE" "$BACKUP" > "$PUBSPEC"

flutter build appbundle --release --dart-define=CHAOS_MEME_SOUNDS=false

AAB="build/app/outputs/bundle/release/app-release.aab"
if unzip -l "$AAB" | grep -q 'assets/sounds/meme/'; then
  echo "Meme clips are still in the bundle:"
  unzip -l "$AAB" | grep 'assets/sounds/meme/'
  exit 1
fi

# The bundle must carry the upload key's certificate, not the debug one.
SIGNER="$(keytool -printcert -jarfile "$AAB" | sed -n 's/^Owner: //p' | head -1)"
case "$SIGNER" in
  *"Android Debug"* | "")
    echo "The bundle is not signed with the upload key (signer: ${SIGNER:-none})."
    exit 1 ;;
esac

mkdir -p dist/play
OUT="dist/play/ApiWorkbench-$NAME.aab"
cp "$AAB" "$OUT"
# Play matches the upload key by fingerprint, not by name (the Dhiva Labs
# keys all share one subject), so print the SHA1 it will compare against.
SHA1="$(keytool -printcert -jarfile "$AAB" | sed -n 's/^[[:space:]]*SHA1: //p' | head -1)"
echo
echo "Signed by: $SIGNER"
echo "SHA1:      $SHA1"
echo "Version:   $VERSION"
ls -l "$OUT"
