# ApiWorkbench v1.0.0

A fast, cross-platform API client — one Flutter codebase for **Linux, Windows, macOS, Android and iOS**.

## Highlights

- **Request builder** — all HTTP methods incl. the new **QUERY**; query params, headers, JSON / text / XML / form / **GraphQL** bodies; Bearer / Basic / API-key auth.
- **Protocols** — HTTP/1.1, **HTTP/2** (ALPN), and **HTTP/3** (QUIC) with automatic fallback.
- **Organise** — collections, `{{variable}}` environments, request history, multi-tab editing.
- **Test** — response assertions (status, JSON path, headers, latency) and a collection runner with **recurring** and **data-driven** runs.
- **Share** — cURL import/export, workspace import/export, Markdown docs export (secrets auto-masked).
- **Dev-friendly** — self-signed cert support, configurable timeouts, resizable panes, keyboard shortcuts.
- **🎲 Chaos Mode** — a Focus/Chaos toggle that plays a meme sound per status code (confetti on success, screen-shake on errors), plus a sound library for importing your own clips.

## Downloads

| Platform | File |
|---|---|
| Android | `ApiWorkbench-1.0.0.apk` |
| Linux (Debian/Ubuntu) | `apiworkbench_1.0.0_amd64.deb` |

### Install
- **Android:** enable "install unknown apps", then open the APK.
- **Linux:** `sudo apt install ./apiworkbench_1.0.0_amd64.deb`

### Checksums (SHA-256)
```
95dc5609d19fef8f14f1a73c1e27b5fc84c59f7123f4b6d07b2c878d730ad7fc  ApiWorkbench-1.0.0.apk
792463137d2612e3c2f3b78fc0c5b97e9bea8e93f242ed05c4b6e8a7ad15b494  apiworkbench_1.0.0_amd64.deb
```

## Notes
- The Android APK is signed with a debug key (fine for sideloading; a release keystore is needed for Play Store).
- Windows / macOS / iOS builds require those OSes to compile and aren't attached here.
