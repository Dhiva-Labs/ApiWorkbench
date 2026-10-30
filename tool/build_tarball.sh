#!/usr/bin/env bash
# Pack the Linux release bundle as ApiWorkbench-<version>-linux-<arch>.tar.gz.
# Usage: tool/build_tarball.sh [out-dir]   (default: dist)
#
# The architecture (x64 or arm64) is the one of the machine running the
# script, because it packages the bundle that `flutter build linux` made there.
# The command-line runner (tool/build_cli.sh, built here when missing) is added
# next to the app as apiworkbench-cli.
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
CLI="$PROJ/build/cli/$ARCH"
[ -f "$RELEASE_DIR/bundle/lib/libflutter_linux_gtk.so" ] ||
  { echo "Release bundle missing - run: flutter build linux --release"; exit 1; }
[ -x "$CLI/bin/apiworkbench-cli" ] || "$PROJ/tool/build_cli.sh" "$CLI"
# shellcheck source=tool/cli_bundle.sh
. "$PROJ/tool/cli_bundle.sh"

VERSION="$(grep '^version:' "$PROJ/pubspec.yaml" | sed 's/version: *//; s/+.*//')"
NAME="ApiWorkbench-${VERSION}-linux-${ARCH}"

# Pack a copy of the bundle, so the build folder stays as Flutter made it.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -a "$RELEASE_DIR/bundle" "$STAGE/bundle"
install_cli "$CLI" "$STAGE/bundle"

mkdir -p "$OUT_DIR"
tar -czf "$OUT_DIR/$NAME.tar.gz" --owner=0 --group=0 --sort=name \
  --transform "s,^bundle,$NAME," -C "$STAGE" bundle
echo "Built $OUT_DIR/$NAME.tar.gz"
