# ApiWorkbench

[![ARM64 builds](https://github.com/Dhiva-Labs/ApiWorkbench/actions/workflows/desktop.yml/badge.svg?branch=main)](https://github.com/Dhiva-Labs/ApiWorkbench/actions/workflows/desktop.yml)
![Linux x64 | arm64](https://img.shields.io/badge/Linux-x64%20%7C%20arm64-informational?logo=linux&logoColor=white)
![Windows x64 | arm64](https://img.shields.io/badge/Windows-x64%20%7C%20arm64-informational?logo=windows&logoColor=white)

A fast, keyboard-friendly API client in the spirit of Postman — one Flutter
codebase for **Linux, Windows, macOS, Android and iOS**.

## Features

- **Postman import and export** — collections (v1, v2.0, v2.1), single
  requests or folders, environments, globals and full "Export data" dumps,
  from files or pasted JSON, into a new collection or an existing collection
  or folder. Folders and their settings, inherited auth (every Postman auth
  type), scripts, saved examples, collection variables, path variables,
  secret variables, disabled rows, descriptions, request settings and every
  body type carry over. Export collections (v2.1), environments and globals
  back to Postman.
- **OpenAPI, Swagger and HAR** — import OpenAPI 3.0/3.1 and Swagger 2.0
  (JSON or YAML) as a collection with folders by tag, parameters, example
  bodies, auth and response examples; export a collection as OpenAPI 3.0.
  Import HAR files from browser developer tools, without static assets.
- **Scripts** — pre-request and post-response JavaScript with Postman's `pm`
  API on an embedded QuickJS engine, at collection, folder and request level:
  variables in every scope, `pm.request` changes, `pm.response` and its
  `to.have.*` checks, `pm.test` and `pm.expect` (chai), `pm.sendRequest`,
  `pm.cookies`, `pm.visualizer`, `postman.setNextRequest`, `console.*`, and
  lodash, crypto-js, moment, uuid, tv4 and ajv through `require()`. Scripts
  have a timeout and no file system access. Scripts in imported collections
  run when you send, as in Postman, so look at them first.
- **Folders** — collections show a folder tree; run, load-test or import into
  any collection or folder from its menu.
- **Collection variables** — `{{variables}}` scoped to a collection; the
  active environment wins on a name clash. Postman dynamic variables such as
  `{{$guid}}`, `{{$timestamp}}` and `{{$randomEmail}}` are generated on send.
- **Captures** — save values from a response (`token = body.data.token`,
  `etag = header.ETag`, `code = status`) into variables for later requests,
  in the editor, the collection runner and the load tester.
- **Load testing** — hit one request or a collection with up to 1,000
  parallel users, for a number of iterations, a duration or until stopped,
  with live throughput and p50/p95/p99 latency; every call can be logged and
  saved as an HTML, CSV or JSON report.
- **Request tabs** — work on several requests at once; unsaved changes are
  marked with a dot.
- **Full request builder** — all HTTP methods including the new QUERY
  (safe method with body), query params, headers, JSON / text / XML /
  form-urlencoded / multipart form-data (text and file fields) / binary file /
  GraphQL bodies (query + variables) with a JSON beautifier.
- **Auth** — Bearer token, Basic auth, API key, OAuth 2.0 (authorization
  code with PKCE, implicit, password and client credentials; sign-in through
  the system browser, automatic refresh, saved tokens), OAuth 1.0, Digest,
  NTLM, AWS Signature v4, Hawk, Akamai EdgeGrid and JWT Bearer. Requests can
  inherit auth from their folder or collection, which also carry scripts and
  a description.
- **Cookies** — a cookie jar that keeps what servers set (redirect hops
  included) and sends it back, a cookie manager to edit it, and a Cookies
  response tab. Turn it off in Settings or per request.
- **Console** — every request on the wire, redirects included, with headers
  and bodies, and script output; filter, search and copy. Secret values are
  masked.
- **Request settings** — per request: follow redirects and their limit, keep
  the method or Authorization on redirects, certificate checks, URL
  encoding, cookies and a timeout.
- **Proxy and certificates** — no proxy, the system proxy (environment
  variables) or a custom one with login and bypass list; an extra trusted CA;
  client certificates (mutual TLS) per host, as PEM or PFX.
- **Environments and Globals** — define `{{variables}}` once, switch
  environments from the sidebar; Globals apply everywhere. Variables have an
  initial value (shared and exported) and a current value (written by scripts
  and captures), and can be secret. Substitution applies to URL, path
  variables, params, headers, body and auth.
- **Path variables** — `:id` segments in the URL get their own table under
  Params, with values and descriptions.
- **Bulk edit** — edit params, headers and form fields as `key: value` lines.
- **Collections** — save, rename, duplicate and organise requests; persisted
  as JSON in the platform app-support directory.
- **History** — the last 100 sends with status, latency and age; reopen any
  of them in a new tab.
- **Response viewer** — status/latency/size bar, syntax-highlighted pretty
  JSON, raw view, a Preview tab for HTML, images, SVG and PDF (and a hex
  view for other binary), header table, find in body (Ctrl+F), the full body
  beyond the 64 KB preview, save the body to a file, copy-to-clipboard.
- **Examples** — save a response as an example of its request; examples are
  listed under the request in the collection tree and can be edited.
- **Tests (assertions)** — per-request checks that run after every send:
  status equals, body contains, JSON field equals (dot/bracket path like
  `data.items[0].id`), header contains, response time below N ms. Results
  show in the response panel's Tests tab.
- **Collection runner** — run a whole collection (or a single request)
  sequentially for 1–100 iterations with an optional delay, live pass/fail
  list, and latency stats (avg / min / max).
- **Recurring runs** — monitor mode: re-run the set every N seconds until
  stopped, e.g. to watch an endpoint while you develop against it.
- **Data-driven runs** — load a CSV or JSON data file in the runner, or paste
  one; each iteration substitutes one row ({{var}}) over the environment.
  Scripts see it as `pm.iterationData`.
- **Command-line runner** — `apiworkbench-cli`, a Newman-style runner for CI
  (see below).
- **Workspace sharing** — export collections + environments to a JSON file
  and import them on another machine; same-id items are updated in place.
- **Docs export** — save any request + response as a Markdown document
  (headers, bodies, cURL), or a whole collection as one HTML page or
  Markdown file; auth tokens and secrets are masked automatically.
- **Version history** — earlier versions of each collection are kept
  locally, with a diff against the current one and restore.
- **SSL & timeouts** — optionally accept self-signed certificates for local
  dev servers; connect/response timeouts configurable in Settings.
- **HTTP/2 & HTTP/3** — pick the protocol in Settings. HTTP/2 negotiates
  h2 via ALPN with automatic HTTP/1.1 fallback. HTTP/3 (QUIC) uses the
  platform network stack on Android/iOS/macOS (Cronet / NSURLSession) and
  the system curl on Linux/Windows (needs a curl built with HTTP3); the
  response bar shows the negotiated version.
- **Code snippets** — the request as code in 19 languages: cURL, HTTPie,
  wget, PowerShell, Python (requests, http.client), JavaScript (fetch, axios,
  Node), Java (java.net.http, OkHttp), Kotlin, C#, Go, PHP, Ruby, Swift, Dart
  and Rust, with variables and auth filled in or kept as `{{variables}}`.
- **cURL interop** — copy any request as a cURL command, or import one.
- **WebSocket, Socket.IO, MQTT, Server-Sent Events and gRPC** — new request
  types from the tab bar's ▾ menu, with a live message log. gRPC loads
  services through server reflection or from `.proto` files and supports all
  four call types.
- **GraphQL schema** — fetch the schema by introspection, browse it, click to
  insert fields with their variables, get field suggestions while typing, and
  prettify the query.
- **Robust networking** — every status code is shown (no exceptions on 4xx/5xx),
  30 s connect / 60 s receive timeouts, redirects followed hop by hop (the
  Authorization header is dropped when one leaves the host), cancellable
  in-flight requests, readable messages for DNS/TLS/timeout failures. GET
  requests send their body when one is set.
- **Chaos Mode** 🎲 — optional (Settings): plays a sound per status class
  (success fanfare, sad trombone on 4xx, dramatic strings on 5xx, siren on
  network errors — original clips), confetti on 2xx, screen-shake on errors,
  and status emoji. Import your own meme clips from a local file or a
  myinstants.com URL and map them to status classes or exact codes.
- **Hover help** — every field, tab, button and badge explains itself with a
  short card (title, explanation and an example); long-press on touch screens.
  Turn it off in Settings once you know your way around.
- **Themes** — Teal (follows the system light/dark setting, or fixed light
  or dark) and Graphite and orange; switch from the rail or Settings.
- **Responsive UI** — desktop icon rail (collections, environments, history,
  import, export, settings) with a resizable side panel, request tabs,
  breadcrumbs and a draggable editor/response splitter; drawer + bottom
  request/response navigation on phones. Shortcuts: Ctrl+Enter send,
  Ctrl+S save, Ctrl+O import, Ctrl+T new tab, Ctrl+W close tab, Ctrl+F find
  in the response.

## Install

Download from the [releases page](https://github.com/Dhiva-Labs/ApiWorkbench/releases):

| Platform | File |
|---|---|
| Linux x64 (Debian, Ubuntu) | `apiworkbench_<version>_amd64.deb` |
| Linux arm64 (Debian, Ubuntu) | `apiworkbench_<version>_arm64.deb` |
| Linux x64 (other distributions) | `ApiWorkbench-<version>-linux-x64.tar.gz` |
| Linux arm64 (other distributions) | `ApiWorkbench-<version>-linux-arm64.tar.gz` |
| Windows x64 | `ApiWorkbench-<version>-windows-x64.zip` |
| Windows arm64 | `ApiWorkbench-<version>-windows-arm64.zip` |
| Android | `ApiWorkbench-<version>.apk` |

```sh
sudo apt install ./apiworkbench_<version>_arm64.deb       # or _amd64.deb
sha256sum -c apiworkbench_<version>_arm64.deb.sha256      # optional check
tar -xzf ApiWorkbench-<version>-linux-arm64.tar.gz && ./ApiWorkbench-<version>-linux-arm64/apiworkbench
```

The tarball needs GTK 3 (`libgtk-3-0`). On Windows, unzip and run
`apiworkbench.exe`. Snap: `sudo snap install apiworkbench` (amd64 and arm64).

Every push to `main` builds, tests and packages ApiWorkbench for Linux and
Windows on x64 and arm64 (the **Desktop builds** workflow). Its run page has
the Microsoft Store packages (`.msix`) and the snaps for both architectures as
artifacts. The Linux and Windows packages above are attached to a release when
it is published; a file that was attached by hand is left as it is.

## Command-line runner

`apiworkbench-cli` runs a collection without the app, for CI. It reads an
ApiWorkbench workspace export or a Postman collection, runs scripts, tests
and captures like the app's runner, and exits with 1 when anything fails.

```sh
apiworkbench-cli run shop.postman_collection.json \
  -e staging.postman_environment.json -d users.csv -n 2 \
  -r cli,junit --reporter-junit-export results.xml
```

Options follow Newman:
- Variables: `-e` (environment), `-g` (globals), `--env-var k=v` and
  `--global-var k=v`.
- Run control: `-d` (data file), `-n` (iterations), `--folder`,
  `--delay-request`, `--timeout-request`, `--bail` and `--insecure`.
- Reports: `-r` takes cli, json, junit and html. Each reporter has an
  `--reporter-<name>-export` path.

Run `apiworkbench-cli run --help` for the full list. It ships in the .deb
(`/usr/bin/apiworkbench-cli`), the tarball, the Windows zip and the snap
(`apiworkbench.cli`; a confined snap reads files under your home folder and
removable media only).

## Run

```sh
flutter run -d linux      # or windows, macos
flutter run -d <device>   # android / ios
```

## Build

```sh
flutter build linux --release     # builds for the machine's architecture: x64 or arm64
tool/build_deb.sh                 # dist/apiworkbench_<version>_<amd64|arm64>.deb
tool/build_tarball.sh             # dist/ApiWorkbench-<version>-linux-<x64|arm64>.tar.gz
flutter build windows --release   # on Windows (x64 or arm64)
powershell -File tool\build_store_msix.ps1   # Microsoft Store .msix, on Windows
pwsh tool\package_windows.ps1     # dist\ApiWorkbench-<version>-windows-<arch>.zip + the .msix
flutter build macos --release     # on macOS
flutter build apk --release
flutter build ios --release       # on macOS
```

The Microsoft Store package leaves out the third-party meme clips in
`assets/sounds/meme/`: `tool/build_store_msix.ps1` drops them from the bundle
and builds with `--dart-define=CHAOS_MEME_SOUNDS=false`, so Chaos Mode uses
the synthesized sounds there. All other builds keep the clips. On an ARM64
Windows machine the same script produces `ApiWorkbench-arm64.msix`.

## Tests

`flutter test integration_test/layout_sweep_test.dart -d linux` renders every
screen at phone, tablet and desktop sizes in each theme and fails on any
overflow; `integration_test/screenshots_test.dart` regenerates `screenshots/`.

```sh
flutter test                      # core unit tests
flutter test test/live_network_test.dart   # needs internet
```

## Layout

```
lib/
  models/models.dart        # request/collection/environment/history models
  services/http_service.dart# dio-based sender, {{var}} substitution
  services/storage.dart     # JSON persistence (path_provider)
  services/curl.dart        # cURL import/export
  services/assertions.dart  # response test evaluation + JSON path walker
  services/runner.dart      # iteration/recurring runner engine
  services/postman_import.dart # Postman/workspace import + script conversion
  services/captures.dart    # response value capture
  services/dynamic_vars.dart# {{$guid}}-style dynamic variables
  services/load_test.dart   # load tester (+ load_log, load_report)
  state/app_state.dart      # tabs, collections, envs, history (provider)
  ui/                       # home (rail + panel), sidebar tree, request
                            # editor, response view, import dialog, runner,
                            # load test, logo
theme.dart                  # runtime-switchable palettes
```

## Memory and mobile update

Response previews are capped at 64 KiB; copying and exporting still use the full
response. The runner retains the latest 200 summaries while keeping aggregate
statistics for the complete run. See [implementation notes and feature ideas](IMPROVEMENTS.md)
for behavior changes, remaining memory limits and the suggested roadmap.

## Privacy

No accounts, analytics or telemetry; the app only sends the requests you make.
See [PRIVACY.md](PRIVACY.md).

## Sponsors

Dhiva Labs is an independent, self-funded lab. [Sponsorships](https://github.com/sponsors/Dhiva-Labs) help bring this project and the rest of Dhiva Labs to every platform, iPhone and Mac included.

[![Sponsor Dhiva Labs](https://img.shields.io/badge/Sponsor-Dhiva%20Labs-ea4aaa?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/Dhiva-Labs)

Monthly sponsors at $10 and up are listed here:

<!-- sponsors -->
*Be the first: [sponsor Dhiva Labs](https://github.com/sponsors/Dhiva-Labs).*
<!-- sponsors -->
