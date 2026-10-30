# Privacy Policy: ApiWorkbench

Last updated: 31 October 2026

ApiWorkbench is an API client made by Dhiva Labs. This policy covers the app
on every platform it ships on (Windows, including the Microsoft Store build,
Linux, macOS, Android and iOS).

## Summary

ApiWorkbench has no accounts, analytics, telemetry, advertising or crash
reporting. It sends network requests only when you ask it to, only to the
addresses you enter, and nothing is sent to Dhiva Labs.

## Data stored on your device

Kept as JSON files in the app's private data folder (on Windows,
`%APPDATA%\Dhiva Labs\ApiWorkbench\apiworkbench`, or the app's private package
storage when installed from the Microsoft Store):

- **Collections and requests** you create or import, including URLs, headers,
  bodies, auth settings, tests and captures.
- **Environments, globals and variables**, which can hold secrets such as
  tokens and passwords if you put them there. Variables marked secret are
  only masked on screen and in exports, not encrypted.
- **Auth tokens** that OAuth 2.0 sign-ins return, stored with the request,
  folder or collection that uses them.
- **Cookies** that servers set, in `cookies.json`, until they expire or you
  delete them in the cookie manager (or turn the cookie jar off).
- **Collection history**: earlier versions of each collection, up to 50 per
  collection, in `history-*.json` files.
- **History**: the last 100 requests you sent (the request, status code,
  duration and time). Response bodies are not kept in history.
- **Settings**, including Chaos Mode sound rules.
- **Sound clips** you import for Chaos Mode, in a `sounds` folder.

These files are not encrypted; they are protected by your operating system
account like your other files. Removing the app (or that folder) deletes them.

When a load test records its call log, the log (and response bodies, if you
ask for them) is written to an `apiworkbench-load` folder in your temporary
folder and deleted when the next run starts or the load tester closes.

Files you export (workspace exports, Markdown docs, load test reports in HTML,
CSV or JSON) are written only where you choose to save them. Markdown docs
mask auth tokens.

## Network use

All network traffic is started by you:

- **Requests, collection runs and load tests** go to the URLs you enter, with
  the headers, bodies and credentials you configure. What those servers do
  with the data is governed by their own policies.
- **HTTP/3 requests** on Windows and Linux are made by your system's `curl`
  program, with the same request data, using temporary files that are
  deleted afterwards.
- **Scripts** (pre-request and test scripts) can send requests with
  `pm.sendRequest`, to the addresses the script names. They run only when you
  send a request or run a collection. Scripts in collections you import from
  others run the same way, so read them before you send.
- **OAuth 2.0 sign-in** opens the provider's page in your browser and listens
  briefly on 127.0.0.1 (your own computer only) for the redirect back, then
  stops listening.
- **WebSocket, Socket.IO, MQTT, Server-Sent Events and gRPC** connections go
  to the addresses you enter and stay open until you disconnect.
- **Importing a Chaos Mode clip from a URL** downloads that page and the
  audio file from the address you give (for example myinstants.com).

The app makes no other connections: no update checks, no usage reporting.

## Children

ApiWorkbench does not collect personal information from anyone, including
children.

## Changes

If this policy changes, the new version will be published in this file in the
app's public repository: <https://github.com/Dhiva-Labs/ApiWorkbench>.

## Contact

Questions about this policy: reachout@dhivalabs.com
