#!/usr/bin/env bash
# Renders the AUR PKGBUILD for one release and proves it builds.
#
# usage: aur.sh <amd64.deb> <arm64.deb> <outdir>
#
# Fills PKGBUILD.in with the version, the release download URL and the
# sha256 of both .debs, then, in an archlinux:latest container, generates
# .SRCINFO and runs makepkg on the x86_64 source (the .deb is placed next to
# the PKGBUILD, so makepkg verifies the checksum without downloading), and
# installs the result. Writes <name>-bin-<version>-aur.tar.gz holding
# PKGBUILD and .SRCINFO, ready to push to the AUR.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ $# -eq 3 ] || { echo "usage: $0 <amd64.deb> <arm64.deb> <outdir>" >&2; exit 2; }
deb_amd64="$(readlink -f "$1")"; deb_arm64="$(readlink -f "$2")"
mkdir -p "$3"; out="$(cd "$3" && pwd)"
# shellcheck source=/dev/null
. "$here/../linux-distros/distro.conf"
: "${VERSION:?set VERSION}"
: "${GITHUB_REPO:?distro.conf must set GITHUB_REPO, e.g. Dhiva-Labs/BranchPilot}"
# A release run passes its tag; otherwise it is the version with TAG_PREFIX.
tag="${RELEASE_TAG:-${TAG_PREFIX-v}$VERSION}"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
deps=""; for d in "${ARCH_DEPENDS[@]}"; do deps+="'$d' "; done
sed -e "s|@NAME@|$NAME|g" -e "s|@VERSION@|$VERSION|g" \
    -e "s|@SUMMARY@|${SUMMARY//\'/}|g" -e "s|@HOMEPAGE@|$HOMEPAGE|g" \
    -e "s|@LICENSE@|$LICENSE|g" -e "s|@ARCH_DEPENDS@|${deps% }|g" \
    -e "s|@RELEASE_URL@|https://github.com/$GITHUB_REPO/releases/download/$tag|g" \
    -e "s|@DEB_AMD64@|$(basename "$deb_amd64")|g" -e "s|@DEB_ARM64@|$(basename "$deb_arm64")|g" \
    -e "s|@SHA_AMD64@|$(sha256sum "$deb_amd64" | cut -d' ' -f1)|g" \
    -e "s|@SHA_ARM64@|$(sha256sum "$deb_arm64" | cut -d' ' -f1)|g" \
    -e "s|@GITHUB_REPO@|$GITHUB_REPO|g" -e "s|@TAG@|$tag|g" \
    -e "s|@LICENSE_FILE@|$LICENSE_FILE|g" \
    -e "s|@SHA_LICENSE@|$(sha256sum "$LICENSE_FILE" | cut -d' ' -f1)|g" \
    "$here/PKGBUILD.in" > "$work/PKGBUILD"
# makepkg finds every source next to the PKGBUILD and verifies it, so the
# check needs no download (the release may not exist yet).
cp "$deb_amd64" "$work/"
cp "$LICENSE_FILE" "$work/LICENSE-$VERSION"
if grep -n '@[A-Z0-9_]*@' "$work/PKGBUILD"; then echo "unfilled placeholder" >&2; exit 1; fi

# The build runs as an unprivileged user (makepkg refuses root); the files
# are handed back to the caller on the way out, so the cleanup trap here can
# delete them whether makepkg succeeded or not.
docker run --rm -v "$work:/build" -e HOST_IDS="$(id -u):$(id -g)" archlinux:latest bash -euo pipefail -c '
  trap "chown -R \"\$HOST_IDS\" /build" EXIT
  pacman -Syu --noconfirm --needed -q base-devel namcap
  useradd -m builder
  chown -R builder /build
  cd /build
  su builder -c "makepkg --printsrcinfo > .SRCINFO"
  su builder -c "makepkg --noconfirm --nodeps -f"
  namcap PKGBUILD
  pacman -U --noconfirm ./*-x86_64.pkg.tar.zst
  cat .SRCINFO
'
tar -C "$work" -czf "$out/$NAME-bin-$VERSION-aur.tar.gz" PKGBUILD .SRCINFO
ls -l "$out/$NAME-bin-$VERSION-aur.tar.gz"
