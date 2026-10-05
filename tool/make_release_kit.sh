#!/usr/bin/env bash
# Assemble the ApiWorkbench release kit (PPA source tree + snap kit) from the
# repo's canonical packaging metadata in linux/packaging/.
#
#   bash tool/make_release_kit.sh              # stage only (verifies payload)
#   bash tool/make_release_kit.sh --skip-build # reuse existing bundle
#   bash tool/make_release_kit.sh --upload     # stage + debuild -S + dput
#
# The version comes from pubspec.yaml (the part before '+'). A matching top
# entry must exist in linux/packaging/debian/changelog — this script refuses
# to re-upload an already-published version, since Launchpad rejects those.
#
# Regression guard: debian/source/options must ship in every kit. Without it
# dpkg-source silently strips *.so (the default ignore list), which is what
# broke 1.0.0 — the app installed but crashed on launch with
# "error while loading shared libraries: libflutter_linux_gtk.so".
set -euo pipefail

KEY=0D3EFC9C8CE20ADE3CE809AD3D8D857AAF4D50E6
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$REPO/linux/packaging"
BUNDLE="$REPO/build/linux/x64/release/bundle"
OUT="$REPO/dist/release-kit"

BOLD=$'\e[1m'; GRN=$'\e[32m'; RED=$'\e[31m'; RST=$'\e[0m'
say(){ echo "${BOLD}${GRN}>>> $*${RST}"; }
die(){ echo "${BOLD}${RED}XXX $*${RST}" >&2; exit 1; }

SKIP_BUILD=0; UPLOAD=0
for a in "$@"; do case "$a" in
  --skip-build) SKIP_BUILD=1 ;;
  --upload) UPLOAD=1 ;;
  *) die "unknown flag: $a" ;;
esac; done

VER=$(grep -oP '^version:\s*\K[0-9]+\.[0-9]+\.[0-9]+' "$REPO/pubspec.yaml") \
  || die "could not read version from pubspec.yaml"
say "Release version (pubspec.yaml): $VER"

CHVER=$(head -1 "$PKG/debian/changelog" | grep -oP '\(\K[^)]+') || true
[ "$CHVER" = "$VER" ] || die "debian/changelog top entry is '$CHVER', expected '$VER'.
Add an entry to $PKG/debian/changelog:

apiworkbench ($VER) noble; urgency=medium

  * <what changed>

 -- Dhivakar R <dhivakar1010@gmail.com>  $(date -R)"

[ -f "$PKG/debian/source/options" ] || die "linux/packaging/debian/source/options is missing — *.so files would be stripped from the source tarball"

if [ "$SKIP_BUILD" = 0 ]; then
  say "Building Flutter Linux release bundle..."
  (cd "$REPO" && flutter build linux --release) || die "flutter build failed"
fi
[ -f "$BUNDLE/lib/libflutter_linux_gtk.so" ] || die "bundle is missing lib/libflutter_linux_gtk.so ($BUNDLE)"

say "Assembling PPA source tree..."
PPA="$OUT/ppa/apiworkbench-$VER"
rm -rf "$OUT"
mkdir -p "$PPA/usr/lib/apiworkbench" "$PPA/usr/bin" \
         "$PPA/usr/share/applications" \
         "$PPA/usr/share/icons/hicolor/512x512/apps" \
         "$PPA/usr/share/icons/hicolor/256x256/apps"
cp -a "$PKG/debian" "$PPA/debian"
cp -a "$BUNDLE/." "$PPA/usr/lib/apiworkbench/"
cp "$PKG/apiworkbench.desktop" "$PPA/usr/share/applications/"
cp "$PKG/icons/apiworkbench-512.png" "$PPA/usr/share/icons/hicolor/512x512/apps/apiworkbench.png"
cp "$PKG/icons/apiworkbench-256.png" "$PPA/usr/share/icons/hicolor/256x256/apps/apiworkbench.png"

say "Assembling snap kit..."
SNAPKIT="$OUT/snap-kit"
mkdir -p "$SNAPKIT"
sed "s/^version: .*/version: '$VER'/" "$PKG/snap/snapcraft.yaml" > "$SNAPKIT/snapcraft.yaml"
cp -a "$PKG/snap/gui" "$SNAPKIT/snap/gui" 2>/dev/null || { mkdir -p "$SNAPKIT/snap"; cp -a "$PKG/snap/gui" "$SNAPKIT/snap/"; }
mkdir -p "$SNAPKIT/bundle"
cp -a "$BUNDLE/." "$SNAPKIT/bundle/"

for so in libflutter_linux_gtk.so libapp.so; do
  [ -f "$PPA/usr/lib/apiworkbench/lib/$so" ] || die "staging is missing $so"
done
say "Staged OK: $OUT (both .so files present)"

if [ "$UPLOAD" = 1 ]; then
  say "Building signed source package (GPG passphrase expected)..."
  (cd "$PPA" && debuild -S -sa -k"$KEY") || die "debuild failed"
  TARBALL="$OUT/ppa/apiworkbench_${VER}.tar.xz"
  tar tJf "$TARBALL" | grep -q 'libflutter_linux_gtk\.so$' \
    || die "SAFETY STOP: $TARBALL does not contain libflutter_linux_gtk.so — not uploading a broken package"
  say "Tarball verified (.so files included). Uploading..."
  (cd "$OUT/ppa" && dput ppa:dhiva-labs/apps "apiworkbench_${VER}_source.changes") \
    || die "dput failed"
  say "PPA upload done — watch for the Launchpad build email."
  say "Snap: cd $SNAPKIT && snapcraft && snapcraft upload --release=stable apiworkbench_${VER}_amd64.snap"
else
  say "Next: bash tool/make_release_kit.sh --skip-build --upload"
fi
