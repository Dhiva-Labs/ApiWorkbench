#!/usr/bin/env bash
# Pack the Linux release bundle as ApiWorkbench-<version>-linux-<arch>.tar.gz.
# Usage: tool/build_tarball.sh [out-dir]   (default: dist)
#
# The architecture (x64 or arm64) is the one of the machine running the
# script, because it packages the bundle that `flutter build linux` made there.
set -euo pipefail

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-$PROJ/dist}"

case "$(uname -m)" in
  x86_64) ARCH=x64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *)
    echo "error: unsupported machine '$(uname -m)' (x86_64 or aarch64)" >&2
    exit 1
    ;;
esac

RELEASE_DIR="$PROJ/build/linux/$ARCH/release"
[ -f "$RELEASE_DIR/bundle/lib/libflutter_linux_gtk.so" ] ||
  { echo "Release bundle missing - run: flutter build linux --release"; exit 1; }

VERSION="$(grep '^version:' "$PROJ/pubspec.yaml" | sed 's/version: *//; s/+.*//')"
NAME="ApiWorkbench-${VERSION}-linux-${ARCH}"

mkdir -p "$OUT_DIR"
tar -czf "$OUT_DIR/$NAME.tar.gz" --owner=0 --group=0 --sort=name \
  --transform "s,^bundle,$NAME," -C "$RELEASE_DIR" bundle
echo "Built $OUT_DIR/$NAME.tar.gz"
