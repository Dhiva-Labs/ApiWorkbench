#!/usr/bin/env bash
# Runs the keychain smoke app (main.dart next to this script) against a real
# Secret Service, in isolation: a private D-Bus session (no service
# activation), a throwaway GNOME Keyring under a temporary HOME and a
# headless GNOME Shell. The desktop's own session bus, keyring and display
# are never reached.
#
#   flutter build linux --debug -t test/keychain_smoke/main.dart
#   test/keychain_smoke/run.sh keychain   # unlocked keyring: secrets go there
#   test/keychain_smoke/run.sh file       # no Secret Service: fallback file
#   test/keychain_smoke/run.sh locked     # a locked keyring and no prompter
#
# Needs gnome-shell, gnome-keyring-daemon and dbus-run-session.
set -euo pipefail
mode="${1:-keychain}"
case "$mode" in keychain|file|locked) ;; *) echo "usage: $0 [keychain|file|locked]" >&2; exit 2 ;; esac
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app="$repo/build/linux/x64/debug/bundle/apiworkbench"
[ -x "$app" ] || { echo "build it first: flutter build linux --debug -t test/keychain_smoke/main.dart" >&2; exit 1; }

# Short: Wayland socket paths must stay under 108 bytes.
work="$(mktemp -d "${TMPDIR:-/tmp}/awkc.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home" "$work/run" "$work/services"
chmod 700 "$work/run"
sed "s|<standard_session_servicedirs />|<servicedir>$work/services</servicedir>|" \
  /usr/share/dbus-1/session.conf > "$work/session.conf"

cat > "$work/inner.sh" <<'EOS'
set -u
keyring() {
  gnome-keyring-daemon "$@" --components=secrets \
    --control-directory="$XDG_RUNTIME_DIR/keyring" >> "$WORK/keyring.env"
}
case "$MODE" in
  keychain)
    # Creates and unlocks a login keyring with a throwaway password.
    printf test | keyring --unlock
    ;;
  locked)
    # The same keyring, then the daemon restarted without the password: the
    # keyring is locked, and with no service activation there is no prompt.
    printf test | keyring --unlock
    sleep 1
    pkill -f -- "--control-directory=$XDG_RUNTIME_DIR/keyring"
    sleep 1
    keyring --start
    ;;
esac
gnome-shell --headless --wayland --no-x11 --wayland-display=awkc \
  --virtual-monitor 800x600 > "$WORK/shell.log" 2>&1 &
shell=$!
for _ in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/awkc" ] && break; sleep 0.2; done
WAYLAND_DISPLAY=awkc GDK_BACKEND=wayland timeout 120 "$APP"
rc=$?
kill "$shell" 2> /dev/null
# Only this run's daemon has this control directory on its command line.
pkill -f -- "--control-directory=$XDG_RUNTIME_DIR/keyring" 2> /dev/null
exit "$rc"
EOS

env -i HOME="$work/home" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$work/run" \
  XDG_DATA_HOME="$work/home/.local/share" XDG_CONFIG_HOME="$work/home/.config" \
  XDG_CACHE_HOME="$work/home/.cache" GSETTINGS_BACKEND=memory \
  APP="$app" WORK="$work" MODE="$mode" \
  AW_SMOKE_EXPECT="$([ "$mode" = keychain ] && echo keychain || echo file)" \
  dbus-run-session --config-file="$work/session.conf" -- bash "$work/inner.sh"
