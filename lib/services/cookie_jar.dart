import 'dart:io' show Cookie;

/// The cookie jar the HTTP service uses. See `cookie_store.dart` for the
/// persistent implementation.
abstract interface class CookieJar {
  /// Value for the Cookie header of a request to [url] (`a=1; b=2`), or
  /// null when no stored cookie matches.
  String? cookieHeaderFor(Uri url);

  /// Stores the cookies from a response's Set-Cookie header values.
  void saveFromResponse(Uri url, List<String> setCookieHeaders);

  /// Cookies that would be sent to [url].
  List<Cookie> cookiesFor(Uri url);
}
