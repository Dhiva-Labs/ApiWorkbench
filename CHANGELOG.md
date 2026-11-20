# Changelog

All notable changes to ApiWorkbench are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases before 1.3.1 are described on the
[releases page](https://github.com/Dhiva-Labs/ApiWorkbench/releases).

## [1.5.0] - 2026-11-20

The security release: credentials stay with the server they were meant for,
imported collections can't act on your machine before you've looked at them,
secrets live in the system keychain, and reports no longer carry them. Also a
leaner, edge-to-edge Android build and refreshed dependencies.

### Security

- **Redirects.** A redirect to another site no longer carries credentials:
  `Authorization`, cookies, proxy credentials, API key and AWS signature
  headers, and other headers that look like secrets are dropped, including on
  an https → http downgrade. Server-Sent Events follow redirects with the same
  rules.
- Digest and NTLM only answer authentication challenges from the server the
  request was sent to.
- Requests and redirects are limited to http and https. A redirect to any
  other kind of address is shown instead of followed.
- **Imported collections.** Imports no longer bring local file paths; choose
  upload files again. The import summary says how many were left out.
- Scripts in an imported collection run only after you allow them: the first
  Send or Runner start asks once (Allow scripts, Run without scripts,
  Cancel). Collections from earlier versions stay trusted.
- Importing globals no longer silently replaces existing values; you choose
  to keep yours or replace them.
- Postman collection and workspace exports leave out OAuth tokens, passwords,
  API keys and other auth secrets unless "Include current values and secrets"
  is on.
- `apiworkbench-cli` reads request files only inside `--working-dir` (default:
  the current folder); `--insecure-file-read` allows other locations.
- **Keychain.** Passwords, tokens, API keys, OAuth tokens, credential headers,
  secret variable values, the proxy password and client certificate
  passphrases are kept in the system keychain instead of the workspace files:
  the Secret Service (GNOME Keyring, KWallet) on Linux, Windows data
  protection, the Android Keystore and the macOS Keychain. Existing workspaces
  are moved over on first start.
- Without a keychain, secrets are kept in a file in the data folder that only
  your user can read, and Settings › Security says so. Snap users can run
  `sudo snap connect apiworkbench:password-manager-service` and restart the
  app to use the desktop keyring.
- Request history and collection version history no longer store
  credentials; existing history is cleaned on first start. A request reopened
  from history needs its auth chosen again.
- The data folder is readable only by your user (folder 0700, files 0600) on
  Linux and macOS.
- **Reports.** Load-test logs and reports (HTML, CSV, JSON) and command-line
  reports (console, JSON, HTML, JUnit) mask API keys, tokens, signatures,
  passwords and secret variable values, including URL-encoded forms.
  Command-line reports also mask `Authorization`, `Cookie` and `Set-Cookie`.
- Load-test logs, response previews and the HTTP/3 engine's temporary files
  are written to private, per-run folders instead of shared fixed ones.
- HTTP/3 on Linux and Windows keeps headers and passwords out of the process
  list and ignores `~/.curlrc`.
- OAuth browser sign-in ignores answers that don't match the sign-in in
  progress and warns when a fixed `state` value is configured.
- Android: workspace data is no longer included in cloud backups or
  device-to-device transfers.
- The script engine (QuickJS-ng) is updated to 0.18.0 for upstream
  memory-safety fixes.
- dio_http2_adapter 2.9.0 (GHSA-cr65-55v9-xhvv). ApiWorkbench follows
  redirects itself, so the adapter's redirect code was not used, but the
  dependency is updated.

### Changed

- Android draws edge to edge on every version, with the system bars handled
  consistently.
- Android: a leaner release build. The app's own Java/Kotlin code is about a
  third smaller and almost all of it is optimised.
- HTTP/3 on Android falls back to HTTP/1.1 on devices without a working
  Cronet provider, and plain `http://` requests use HTTP/1.1.
- File picking and saving use file_picker 13 on every platform; Android image
  picks no longer decode full-size images.
- dio 5.11.1 (response streams respect backpressure, so large responses no
  longer pile up in memory) and the HTTP/2 adapter offers HTTP/1.1 to servers
  that refuse h2-only negotiation.
- Linux packages depend on libsecret; the AppImage includes it.
- macOS: sandboxed builds can receive the OAuth sign-in redirect and open and
  save the files you pick.
- Dependencies refreshed, including cupertino_icons 2 and flutter_svg 2.4.

### Upgrading and downgrading

- Once 1.5.0 has moved them, ApiWorkbench 1.4.x shows empty passwords, tokens
  and secret variables, because they are in the keychain. Upgrading again
  brings them back. Export with current values before downgrading if you need
  them in 1.4.
- Cross-site redirects now drop custom headers that look like secrets (for
  example `X-Session-Id`). Same-site redirects are unchanged.

## [1.4.0] - 2026-10-31

The Postman gaps release: scripts, every Postman auth type, cookies, the
console, streaming protocols, gRPC and the formats Postman reads and writes.

### Added

- **Scripts.** Pre-request and post-response scripts run with Postman's
  `pm` API on an embedded QuickJS engine (built from source for every
  platform, including arm64). Scripts run at collection, folder and
  request level, in Postman's order.
  - Variables: `pm.environment`, `pm.collectionVariables`, `pm.globals`,
    `pm.variables` and `pm.iterationData`.
  - Requests: `pm.request` (pre-request scripts can change it),
    `pm.response`, `pm.sendRequest` and `pm.cookies`.
  - Tests: `pm.test`, `pm.expect` (chai) and the `pm.response.to.*`
    assertions.
  - Flow: `pm.execution.skipRequest` and `postman.setNextRequest` in the
    runner.
  - Libraries: lodash, crypto-js, moment, uuid, tv4 and ajv through
    `require()`.
  - `console.*` output goes to the Console.
  - `pm.visualizer` output appears in a new Visualize response tab.
  - Scripts get a timeout, a memory cap, and no file system access.
- **Auth.** OAuth 2.0 with every grant: authorization code with PKCE,
  implicit, password and client credentials. "Get new access token" signs in
  through the system browser and a local redirect listener. Tokens refresh
  automatically, and a saved-token list is kept per request.
  - Also: OAuth 1.0, Digest, NTLM, AWS Signature v4, Hawk, Akamai EdgeGrid
    and JWT Bearer.
  - Requests can inherit auth from their folder or collection.
- **Collection and folder settings**: auth, scripts and description for each
  collection and folder.
- **Cookies**:
  - An RFC 6265 cookie jar. It keeps cookies from every response (redirect
    hops included) and sends them back.
  - A cookie manager to browse, add, edit and delete cookies.
  - A Cookies response tab.
  - Settings to turn the jar off app-wide and per request.
- **Console.** Every request on the wire, redirects included, with headers
  and bodies, plus script output. It has filters and search, and secret
  values are masked.
- **Request settings**: a per-request Settings tab for following redirects,
  the redirect limit, keeping the method and Authorization on redirects,
  certificate checks, URL encoding, the cookie jar and the timeout.
- **Proxy and certificates**:
  - Proxy: none, system (environment variables) or custom, with a login and
    a bypass list.
  - An extra trusted CA certificate.
  - Client certificates (mutual TLS) per host, as PEM or PFX.
- **Variables**:
  - A Globals scope.
  - Separate initial and current values. Scripts and captures write current
    values; you can reset or persist them.
  - Secret variables, masked in editors, the Console, docs and reports.
- **New request types**:
  - WebSocket: composer, saved messages, ping and auto-reconnect.
  - Socket.IO: event listeners and emit with acknowledgements.
  - MQTT: subscriptions, publish, QoS, retain and last will.
  - Server-Sent Events, with reconnect and `Last-Event-ID`.
  - gRPC: services from server reflection or imported `.proto` files; all
    four call types, metadata, TLS and deadlines.
- **GraphQL**:
  - Fetch the schema by introspection.
  - Browse it in an explorer and click to insert fields with their
    variables.
  - Field suggestions while you type, and a prettifier.
- **Path variables**: `:id` segments get their own table under Params, and
  values are filled in on send.
- **Code snippets in 19 languages**: cURL, HTTPie, wget and PowerShell;
  Python, JavaScript and Node; Java, Kotlin, C# and Go; PHP, Ruby, Swift,
  Dart and Rust. Snippets use the resolved request, with auth, or with
  `{{variables}}` kept as written.
- **Bulk edit** for params, headers and form fields, as `key: value` lines.
- **Response tools**:
  - A Preview tab for HTML, images, SVG and PDF, and a hex view for binary
    bodies.
  - Save the response body to a file.
  - Find in body (Ctrl+F).
  - A full-body view beyond the 64 KB preview.
- **Saved response examples**: save a response as an example, then edit,
  duplicate or delete it from the collection tree.
- **Import and export**:
  - Postman: export collections (v2.1), environments and globals. Postman
    imports now keep scripts, examples, path variables, inherited auth,
    folder settings, globals and secret variables.
  - OpenAPI 3.0 and 3.1 and Swagger 2.0: import (JSON or YAML) and export
    (OpenAPI 3.0).
  - HAR: import, with static assets left out.
- **Runner and CLI**:
  - The collection runner takes CSV or JSON data files.
  - New `apiworkbench-cli` command, a Newman-style runner for CI. It runs a
    workspace export or a Postman collection with environment, globals and
    data files, and writes cli, JSON, JUnit and HTML reports. It ships in
    the .deb, the tarball, the snap (`apiworkbench.cli`) and the Windows
    zip.
- **Collection docs and history**:
  - Generate documentation for a whole collection, as one HTML page or as
    Markdown.
  - Local version history for collections, with a diff and restore.

### Changed

- Redirects are followed by the app, hop by hop, so cookies and the Console
  see each one. The Authorization header is dropped when a redirect leaves
  the original host.
- GET requests send their body when one is set, like Postman. HEAD never
  does.
- Saving a request keeps its place in the collection.
- On Android, iOS and macOS, HTTP/3 falls back to HTTP/1.1 when a proxy,
  CA, client certificate or "don't verify" is set, because the platform
  network stacks don't apply those settings.

## [1.3.1] - 2026-10-16 (not published; included in 1.4.0)

### Added

- Linux arm64 and Windows arm64 builds, next to the x64 ones. CI builds,
  tests and starts each package on a native runner of its architecture, and
  a published release carries `apiworkbench_<version>_arm64.deb` (with its
  `.sha256`), `ApiWorkbench-<version>-linux-arm64.tar.gz` and
  `ApiWorkbench-<version>-windows-arm64.zip`. The snap and the Microsoft
  Store package build for arm64 too.
- Windows x64 zip (`ApiWorkbench-<version>-windows-x64.zip`), Linux tarballs
  for x64 and arm64, and Microsoft Store packaging for Windows (`msix_config`
  in `pubspec.yaml`, `tool/build_store_msix.ps1`).
- A privacy policy (`PRIVACY.md`): requests are sent only when you send them,
  to the addresses you enter, and nothing is reported to Dhiva Labs.

### Changed

- The Microsoft Store package leaves out the Chaos Mode meme clips (third-party
  audio) and uses the synthesized sounds instead. Every other build keeps the
  clips.
- The Windows executable is labelled ApiWorkbench / Dhiva Labs in its version
  info, so the Windows data folder is `%APPDATA%\Dhiva Labs\ApiWorkbench`.
- Locked `jni` to 1.0.3, which compiles on Linux arm64.
- The load test's test teardown waits for the log file to be deleted, so the
  test suite passes on Windows.

### Fixed

- Windows: Chaos Mode played no sound because PowerShell did not load the
  media player assembly, and a user name with an apostrophe (for example
  `O'Neil`) broke the clip path.
