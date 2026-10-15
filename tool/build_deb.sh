#!/usr/bin/env bash
# Build the Debian package from the release bundle.
# Usage: tool/build_deb.sh [version]   (defaults to the version in pubspec.yaml)
#
# The architecture (amd64 or arm64) is the one of the machine running the
# script, because it packages the bundle that `flutter build linux` made there.
set -euo pipefail

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(grep '^version:' "$PROJ/pubspec.yaml" | sed 's/version: *//; s/+.*//')}"
DEB_ARCH="$(dpkg --print-architecture)"
case "$DEB_ARCH" in
  amd64) FLUTTER_ARCH=x64 ;;
  arm64) FLUTTER_ARCH=arm64 ;;
  *)
    echo "error: unsupported architecture '$DEB_ARCH' (amd64 or arm64)" >&2
    exit 1
    ;;
esac
PKG="apiworkbench_${VERSION}_${DEB_ARCH}"
ROOT="$PROJ/dist/deb/$PKG"
BUNDLE="$PROJ/build/linux/$FLUTTER_ARCH/release/bundle"
ICONS="$PROJ/linux/packaging/icons"

[ -f "$BUNDLE/lib/libflutter_linux_gtk.so" ] ||
  { echo "Release bundle missing - run: flutter build linux --release"; exit 1; }

rm -rf "$ROOT"
mkdir -p "$ROOT/DEBIAN" "$ROOT/usr/lib/apiworkbench" "$ROOT/usr/bin" \
         "$ROOT/usr/share/applications" \
         "$ROOT/usr/share/icons/hicolor/256x256/apps" \
         "$ROOT/usr/share/icons/hicolor/512x512/apps"

cp -r "$BUNDLE/." "$ROOT/usr/lib/apiworkbench/"
ln -s ../lib/apiworkbench/apiworkbench "$ROOT/usr/bin/apiworkbench"
cp "$PROJ/linux/packaging/apiworkbench.desktop" "$ROOT/usr/share/applications/"
cp "$ICONS/apiworkbench-256.png" "$ROOT/usr/share/icons/hicolor/256x256/apps/apiworkbench.png"
cp "$ICONS/apiworkbench-512.png" "$ROOT/usr/share/icons/hicolor/512x512/apps/apiworkbench.png"

cat > "$ROOT/DEBIAN/control" <<CONTROL
Package: apiworkbench
Version: $VERSION
Section: devel
Priority: optional
Architecture: ${DEB_ARCH}
Installed-Size: $(du -sk "$ROOT/usr" | cut -f1)
Depends: libgtk-3-0, libglib2.0-0
Maintainer: Dhivakar <dhivakar1010@gmail.com>
Description: Cross-platform API client for building and testing HTTP requests
 Postman-style workbench with request collections and folders,
 environments and collection variables, Postman import, response
 assertions and captures, a collection runner, and load testing with
 call logs and HTML/CSV/JSON reports.
CONTROL

dpkg-deb --build --root-owner-group "$ROOT" "$PROJ/dist/$PKG.deb"
(cd "$PROJ/dist" && sha256sum "$PKG.deb" > "$PKG.deb.sha256")
echo "Built $PROJ/dist/$PKG.deb"
