#!/usr/bin/env bash
# Compile the command-line runner, apiworkbench-cli.
# Usage: tool/build_cli.sh [out-dir]   (default: build/cli/<x64|arm64>)
#
# Result:
#   <out-dir>/bin/apiworkbench-cli   the executable
#   <out-dir>/lib/                   native libraries it loads, when it has any
#
# The tools used are the Dart SDK that comes with Flutter ($DART, default
# `dart` on PATH). `dart build cli` is tried first: it also builds Dart native
# assets (build hooks), which `dart compile exe` refuses to do, and some of
# the app's packages have hooks. `dart compile exe` is the fallback for an SDK
# without `dart build`. The binary finds its libraries at ../lib relative to
# itself, so keep bin/ and lib/ together (tool/cli_bundle.sh does that for the
# packages).
set -euo pipefail

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -m)" in
  x86_64) ARCH=x64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *)
    echo "error: unsupported machine '$(uname -m)' (x86_64 or aarch64)" >&2
    exit 1
    ;;
esac
OUT="${1:-$PROJ/build/cli/$ARCH}"
DART="${DART:-dart}"
ENTRY=bin/apiworkbench_cli.dart

cd "$PROJ"
# Dart reads the package list that `flutter pub get` writes.
[ -f .dart_tool/package_config.json ] || flutter pub get

STAGE="$OUT.building"
rm -rf "$OUT" "$STAGE"
mkdir -p "$STAGE/bin"

if "$DART" build cli --help > /dev/null 2>&1; then
  echo "Building apiworkbench-cli with 'dart build cli'"
  "$DART" build cli -t "$ENTRY" -o "$STAGE/dart-build"
  cp "$STAGE/dart-build/bundle/bin/apiworkbench_cli" "$STAGE/bin/apiworkbench-cli"
  if [ -d "$STAGE/dart-build/bundle/lib" ]; then
    cp -a "$STAGE/dart-build/bundle/lib" "$STAGE/lib"
  fi
  rm -rf "$STAGE/dart-build"
else
  echo "Building apiworkbench-cli with 'dart compile exe'"
  "$DART" compile exe "$ENTRY" -o "$STAGE/bin/apiworkbench-cli"
fi
chmod +x "$STAGE/bin/apiworkbench-cli"
mv "$STAGE" "$OUT"

"$OUT/bin/apiworkbench-cli" --version
echo "Built $OUT/bin/apiworkbench-cli"
