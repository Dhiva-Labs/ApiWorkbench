# ApiWorkbench

A fast, keyboard-friendly API client in the spirit of Postman — one Flutter
codebase for **Linux, Windows, macOS, Android and iOS**.

## Features

- **Postman import** — collections (v1, v2.0, v2.1), single requests or
  folders, environments, globals and full "Export data" dumps, from files or
  pasted JSON, into a new collection or an existing collection or folder.
  Folders, auth inheritance, collection variables, path variables, disabled
  params and headers, descriptions and every body type carry over. Common
  `pm.test` checks become Tests and `pm.environment.set(...)` calls become
  Captures; the original scripts are kept under Docs. A preview lists
  anything that couldn't be carried over before you import.
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
- **Auth helpers** — Bearer token, Basic auth, API key (header or query).
- **Environments** — define `{{variables}}` once, switch environments from the
  sidebar; substitution applies to URL, params, headers, body and auth.
- **Collections** — save, rename, duplicate and organise requests; persisted
  as JSON in the platform app-support directory.
- **History** — the last 100 sends with status, latency and age; reopen any
  of them in a new tab.
- **Response viewer** — status/latency/size bar, syntax-highlighted pretty
  JSON, raw view, sortable header table, copy-to-clipboard.
- **Tests (assertions)** — per-request checks that run after every send:
  status equals, body contains, JSON field equals (dot/bracket path like
  `data.items[0].id`), header contains, response time below N ms. Results
  show in the response panel's Tests tab.
- **Collection runner** — run a whole collection (or a single request)
  sequentially for 1–100 iterations with an optional delay, live pass/fail
  list, and latency stats (avg / min / max).
- **Recurring runs** — monitor mode: re-run the set every N seconds until
  stopped, e.g. to watch an endpoint while you develop against it.
- **Data-driven runs** — paste a JSON array of variable sets in the runner;
  each iteration substitutes one row ({{var}}) over the environment.
- **Workspace sharing** — export collections + environments to a JSON file
  and import them on another machine; same-id items are updated in place.
- **Docs export** — save any request + response as a Markdown document
  (headers, bodies, cURL); auth tokens are masked automatically.
- **SSL & timeouts** — optionally accept self-signed certificates for local
  dev servers; connect/response timeouts configurable in Settings.
- **HTTP/2 & HTTP/3** — pick the protocol in Settings. HTTP/2 negotiates
  h2 via ALPN with automatic HTTP/1.1 fallback. HTTP/3 (QUIC) uses the
  platform network stack on Android/iOS/macOS (Cronet / NSURLSession) and
  the system curl on Linux/Windows (needs a curl built with HTTP3); the
  response bar shows the negotiated version.
- **cURL interop** — copy any request as a cURL command, or import one.
- **Robust networking** — every status code is shown (no exceptions on 4xx/5xx),
  30 s connect / 60 s receive timeouts, redirect following, cancellable
  in-flight requests, readable messages for DNS/TLS/timeout failures.
- **Chaos Mode** 🎲 — optional (Settings): plays a sound per status class
  (success fanfare, sad trombone on 4xx, dramatic strings on 5xx, siren on
  network errors — original clips), confetti on 2xx, screen-shake on errors,
  and status emoji. Import your own meme clips from a local file or a
  myinstants.com URL and map them to status classes or exact codes.
- **Themes** — Teal (follows the system light/dark setting, or fixed light
  or dark) and Graphite and orange; switch from the rail or Settings.
- **Responsive UI** — desktop icon rail (collections, environments, history,
  import, export, settings) with a resizable side panel, request tabs,
  breadcrumbs and a draggable editor/response splitter; drawer + bottom
  request/response navigation on phones. Shortcuts: Ctrl+Enter send,
  Ctrl+S save, Ctrl+O import, Ctrl+T new tab, Ctrl+W close tab.

## Run

```sh
flutter run -d linux      # or windows, macos
flutter run -d <device>   # android / ios
```

## Build

```sh
flutter build linux --release
flutter build windows --release   # on Windows
flutter build macos --release     # on macOS
flutter build apk --release
flutter build ios --release       # on macOS
```

## Tests

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
