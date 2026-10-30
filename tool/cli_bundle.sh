# Sourced by build_deb.sh, build_tarball.sh and the snap build.
#
# install_cli <cli-dir> <app-dir>: adds apiworkbench-cli, as built by
# tool/build_cli.sh into <cli-dir>, to the app's bundle folder <app-dir> as
# <app-dir>/apiworkbench-cli.
#
# The binary loads native libraries from ../lib relative to its real path. With
# none, it is simply copied. With some, it goes to <app-dir>/bin and the
# libraries join <app-dir>/lib (the Flutter bundle's own lib folder), and
# <app-dir>/apiworkbench-cli is a link to bin/apiworkbench-cli.
install_cli() {
  local src="$1" dest="$2"
  [ -x "$src/bin/apiworkbench-cli" ] || {
    echo "error: $src/bin/apiworkbench-cli is missing - run: tool/build_cli.sh" >&2
    return 1
  }
  if [ -n "$(ls -A "$src/lib" 2> /dev/null)" ]; then
    mkdir -p "$dest/bin" "$dest/lib"
    cp "$src/bin/apiworkbench-cli" "$dest/bin/apiworkbench-cli"
    cp -a "$src/lib/." "$dest/lib/"
    ln -sf bin/apiworkbench-cli "$dest/apiworkbench-cli"
  else
    cp "$src/bin/apiworkbench-cli" "$dest/apiworkbench-cli"
  fi
}
