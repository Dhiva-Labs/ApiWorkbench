# Memory and mobile improvements

## Implemented

- Runner retains the latest 200 result summaries, without response bodies or headers. Assertions still evaluate the complete response before summarization. Pass/fail counts and latency statistics cover the entire run, including evicted results.
- Response rendering decodes and caches a maximum 64 KiB preview. Full response bytes remain available for assertions, copying and documentation export. A visible notice explains truncated previews.
- JSON formatting/highlighting is cached for the mounted view and limited to small payloads. Mobile mounts only the selected request/response section.
- Network adapters close when replaced; app disposal cancels active requests and closes the client. Responses finishing after a tab closes or the app is disposed are discarded.
- Runner disposal ignores pending results and prevents overlapping starts while an earlier run unwinds.
- Import/save dialog controllers are disposed. Fixed the animation controller lifecycle when leaving a response with Chaos Mode disabled.
- Phone UI has bottom request/response navigation, response status badges, request progress, a full-width URL field with URL keyboard, larger request-tab close targets, and wrapping response/runner metrics. Long environment names truncate safely. Assertion fields can scroll horizontally on narrow screens.

## Next additions, in suggested order

1. **Response comparison:** compare two saved responses with JSON field changes and timing differences. This builds on the response viewer and makes regression debugging easier.
2. **OpenAPI import:** generate collections, example bodies and parameters from an API specification, extending the existing workspace and cURL import flows.
3. **Request chaining:** extract values from a response into an environment for login → authenticated request workflows in the collection runner.
4. **Secure secret storage:** move tokens and passwords into platform keychains, with explicit controls for including credentials in workspace exports.
5. **Search and favorites:** filter collections and history by endpoint, method or status; pin frequently used requests for quick phone access.
6. **Disk-backed large responses:** stream downloads to temporary files and page the viewer. Current previews bound rendering, but complete network responses and responses held in open tabs still occupy memory.
7. **Mobile sharing:** import cURL from the system share sheet and share sanitized request examples directly from a phone.

## Limits and release notes

These changes remove identifiable retention and rendering costs; no physical-device heap benchmark has been performed. History still retains request bodies and active tabs still retain their full latest response. Full-body copying/export can allocate large strings.

Android release builds currently use the repository's debug signing configuration, suitable for local installation but not a production store release. iOS packaging requires macOS/Xcode and signing credentials.
