import 'dart:io' show Cookie;

import 'cookie_jar.dart';
import 'json_store.dart';

/// The app's cookie jar, saved in cookies.json.
///
/// Minimal placeholder: cookies are kept per exact host and path rules,
/// expiry and attributes are not applied yet. Issue #12 replaces this with
/// an RFC 6265 jar and a cookie manager.
class PersistentCookieJar implements CookieJar {
  PersistentCookieJar([this._store]);

  final JsonStore? _store;
  final Map<String, Map<String, Cookie>> _byHost = {};

  Future<void> load() async {}

  @override
  String? cookieHeaderFor(Uri url) {
    final cookies = cookiesFor(url);
    if (cookies.isEmpty) return null;
    return cookies.map((c) => '${c.name}=${c.value}').join('; ');
  }

  @override
  List<Cookie> cookiesFor(Uri url) =>
      _byHost[url.host.toLowerCase()]?.values.toList() ?? const [];

  @override
  void saveFromResponse(Uri url, List<String> setCookieHeaders) {
    final jar = _byHost.putIfAbsent(url.host.toLowerCase(), () => {});
    for (final raw in setCookieHeaders) {
      try {
        final c = Cookie.fromSetCookieValue(raw);
        jar[c.name] = c;
      } catch (_) {
        // Malformed Set-Cookie: ignored, like browsers do.
      }
    }
    _store; // persisted by the full implementation
  }
}
