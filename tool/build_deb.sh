#!/usr/bin/env bash
# Build the Debian package from the release bundle.
# Usage: tool/build_deb.sh [version]   (defaults to the version in pubspec.yaml)
set -euo pipefail

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(grep '^version:' "$PROJ/pubspec.yaml" | sed 's/version: *//; s/+.*//')}"
PKG="apiworkbench_${VERSION}_amd64"
ROOT="$PROJ/dist/deb/$PKG"
BUNDLE="$PROJ/build/linux/x64/release/bundle"
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
Architecture: amd64
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
