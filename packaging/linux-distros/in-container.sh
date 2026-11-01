#!/usr/bin/env bash
# Runs inside a distribution container started by verify.sh.
# MODE: rpm (Fedora) | rpm-suse (openSUSE) | pacman (Arch) | appimage (Fedora)
# FILE: the package to install, under /pkgs.
set -euo pipefail
# shellcheck source=/dev/null
. /linux-distros/distro.conf

# Display and GL stack for the GUI smoke test, per distribution.
case "$MODE" in
  rpm|appimage)
    dnf -y -q install file findutils which procps-ng \
      xorg-x11-server-Xvfb xorg-x11-xauth mesa-dri-drivers dbus-daemon xdotool
    ;;
  rpm-suse)
    zypper -n -q --gpg-auto-import-keys refresh
    zypper -n -q install file findutils which procps \
      xvfb-run Mesa-dri dbus-1 xdotool
    ;;
  pacman)
    pacman -Syu --noconfirm --needed -q file findutils which procps-ng \
      xorg-server-xvfb xorg-xauth mesa dbus xdotool
    ;;
esac

case "$MODE" in
  rpm)      dnf -y install "$FILE"; files() { rpm -ql "$NAME"; } ;;
  rpm-suse) zypper -n install --allow-unsigned-rpm "$FILE"; files() { rpm -ql "$NAME"; } ;;
  pacman)   pacman -U --noconfirm "$FILE"; files() { pacman -Qlq "$NAME"; } ;;
  appimage)
    # The libraries an AppImage expects from the host: GTK 3 and friends.
    dnf -y -q install gtk3
    cp "$FILE" /tmp/app.AppImage
    chmod +x /tmp/app.AppImage
    (cd /tmp && /tmp/app.AppImage --appimage-extract > /dev/null)
    files() { find /tmp/squashfs-root -type f; }
    ;;
  *) echo "unknown MODE $MODE" >&2; exit 2 ;;
esac

# Every ELF file the package installed must find all of its libraries. The
# package's own library directories go on LD_LIBRARY_PATH, as the app's
# RPATH/$ORIGIN would supply them at run time, so only libraries missing
# from the distribution are reported.
mapfile -t elfs < <(files | while IFS= read -r f; do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  [ "$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ] && echo "$f"
done)
libdirs="$(for f in "${elfs[@]}"; do case "$f" in *.so|*.so.*) dirname "$f" ;; esac; done | sort -u | paste -sd:)"
missing=0
for f in "${elfs[@]}"; do
  if LD_LIBRARY_PATH="$libdirs" ldd "$f" 2>&1 | grep 'not found' > /dev/null; then
    echo "missing libraries for $f:"
    LD_LIBRARY_PATH="$libdirs" ldd "$f" | grep 'not found'
    missing=1
  fi
done
echo "${#elfs[@]} ELF files checked with ldd"
[ "$missing" = 0 ] || exit 1

# Smoke test. CLI tools: SMOKE_CMD must exit 0. GUI apps: GUI_CMD must
# still be running after SMOKE_SECONDS under Xvfb, with no loader errors.
if [ "$MODE" = appimage ]; then
  export APPIMAGE_EXTRACT_AND_RUN=1
  cmd_prefix=/tmp/app.AppImage
else
  cmd_prefix=
fi
# A GUI AppImage starts the GUI whatever its arguments, so SMOKE_CMD (the
# command-line runner) is checked in the packages only.
if [ -n "${SMOKE_CMD:-}" ] && { [ -z "$cmd_prefix" ] || [ -z "${GUI_CMD:-}" ]; }; then
  if [ -n "$cmd_prefix" ]; then
    # SMOKE_CMD's first word is the installed command; the AppImage replaces it.
    read -r -a words <<< "$SMOKE_CMD"
    "$cmd_prefix" "${words[@]:1}"
  else
    bash -c "$SMOKE_CMD"
  fi
fi
if [ -n "${GUI_CMD:-}" ]; then
  if [ -n "$cmd_prefix" ]; then gui=("$cmd_prefix"); else read -r -a gui <<< "$GUI_CMD"; fi
  # Optional, from distro.conf: SMOKE_WINDOW, a window title (xdotool
  # --name regex) the app must show; SMOKE_DATA_PATH, a glob under
  # $XDG_DATA_HOME that Dart start-up creates, proof the AOT code ran.
  cat > /tmp/smoke.sh <<'EOS'
log=/tmp/smoke.log
"$@" > "$log" 2>&1 &
pid=$!
secs="${SMOKE_SECONDS:-20}"
ok=0
for i in $(seq 1 90); do
  kill -0 "$pid" 2> /dev/null || break
  seen=1
  if [ -n "${SMOKE_WINDOW:-}" ] && ! xdotool search --name "$SMOKE_WINDOW" > /dev/null 2>&1; then seen=0; fi
  if [ -n "${SMOKE_DATA_PATH:-}" ] && ! compgen -G "$XDG_DATA_HOME/$SMOKE_DATA_PATH" > /dev/null; then seen=0; fi
  if [ "$seen" = 1 ] && [ "$i" -ge "$secs" ]; then ok=1; break; fi
  sleep 1
done
if [ "$ok" = 1 ] && kill -0 "$pid" 2> /dev/null; then
  echo "still running after ${i}s${SMOKE_WINDOW:+, window $SMOKE_WINDOW is up}${SMOKE_DATA_PATH:+, data folder:}"
  if [ -n "${SMOKE_DATA_PATH:-}" ]; then compgen -G "$XDG_DATA_HOME/$SMOKE_DATA_PATH"; fi
  kill "$pid"
elif kill -0 "$pid" 2> /dev/null; then
  echo "no ${SMOKE_WINDOW:+window $SMOKE_WINDOW }${SMOKE_DATA_PATH:+or data folder $SMOKE_DATA_PATH }after 90s"
  find "$XDG_DATA_HOME" -maxdepth 3
  kill "$pid"
  ok=0
else
  wait "$pid" && rc=0 || rc=$?
  echo "exited early with status $rc"
  ok=0
fi
cat "$log"
if grep -E 'error while loading shared libraries|cannot open shared object|undefined symbol' "$log"; then ok=0; fi
[ "$ok" = 1 ]
EOS
  export HOME=/tmp/smoke-home XDG_DATA_HOME=/tmp/smoke-home/.local/share
  export SMOKE_SECONDS SMOKE_WINDOW SMOKE_DATA_PATH
  mkdir -p "$XDG_DATA_HOME"
  xvfb-run -a -s '-screen 0 1280x800x24' dbus-run-session -- bash /tmp/smoke.sh "${gui[@]}"
fi
echo "$MODE: OK"
