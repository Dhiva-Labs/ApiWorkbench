# Flatpak

`com.dhivalabs.api_workbench.yml` builds the Flatpak from the installed tree
of the .deb, so it ships the same binary as every other Linux package.

## How CI builds it

The `distros` job in `.github/workflows/desktop.yml` unpacks the .deb, cleans
the tree (`packaging/linux-distros/pack.sh`, which drops the Debian-only files
and `libdartjni.so`, see `distro.conf`) and passes it on. The `flatpak` job
unpacks it into `packaging/flatpak/tree/` and runs flatpak-builder in the
`ghcr.io/flathub-infra/flatpak-github-actions:gnome-51` image, on x86_64 and
aarch64. It then installs the bundle, checks every ELF file with ldd against
the GNOME 51 runtime, runs `apiworkbench-cli`, and starts the app under Xvfb
until its window is up (`x11_window.py`; the image has no xdotool) and Dart
has created its data folder.

The bundle, `apiworkbench-<version>-<arch>.flatpak`, refers to Flathub for
its runtime:

```sh
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user ./apiworkbench-<version>-x86_64.flatpak
flatpak run com.dhivalabs.api_workbench
flatpak run --command=apiworkbench-cli com.dhivalabs.api_workbench --help
```

## Sandbox

- `--share=network`: the app is an API client.
- `--filesystem=home:ro`: CA certificate, client certificate and .proto paths
  can be typed in by hand and are read again on every start. Opening and
  saving files (imports, exports, reports) goes through the file chooser
  portal, which grants write access to the chosen file only.
- `--socket=pulseaudio`: Chaos Mode's sound effects.
- HTTP/3 uses the `curl` of the runtime; when that curl has no HTTP/3 support
  the app says so, as it does on a host without one.

## Releases

Add a `<release>` line to `com.dhivalabs.api_workbench.metainfo.xml` with
each version bump; the CI fails when the newest version in `pubspec.yaml` is
missing there.

## Flathub

A Flathub submission would differ in two ways: the `tree` directory source
becomes an `archive` source (the release's
`apiworkbench_<version>_amd64.deb` / `_arm64.deb`, with `only-arches` and a
sha256 each, unpacked with `ar` and `tar` in the build commands, and
`libdartjni.so` removed), and the manifest goes to a new
`flathub/com.dhivalabs.api_workbench` repository through Flathub's review.
Nothing is published from this repository.
