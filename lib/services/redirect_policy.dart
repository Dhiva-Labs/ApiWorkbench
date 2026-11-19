/// Rules for following redirects, shared by every transport that follows
/// them in app code (the HTTP service and Server-Sent Events), so a header
/// that must not reach another site is dropped the same way everywhere.
library;

/// The only URL schemes requests are sent to or redirects are followed to.
const webSchemes = {'http', 'https'};

/// Status codes whose `Location` is followed.
const redirectStatusCodes = {301, 302, 303, 307, 308};

/// Whether [url] is an `http`/`https` URL with a host.
bool isWebUrl(Uri url) =>
    webSchemes.contains(url.scheme.toLowerCase()) && url.host.isNotEmpty;

/// `scheme://host:port` of [url], the default port filled in. Unlike
/// [Uri.origin] it never throws, so it is safe on any URL.
String originOf(Uri url) {
  final scheme = url.scheme.toLowerCase();
  return '$scheme://${url.host.toLowerCase()}:${url.port}';
}

/// Whether [a] and [b] share scheme, host and port.
bool sameOrigin(Uri a, Uri b) => originOf(a) == originOf(b);

/// Whether a hop from [from] to [to] goes from https to plain http.
bool isDowngrade(Uri from, Uri to) =>
    from.scheme.toLowerCase() == 'https' && to.scheme.toLowerCase() == 'http';

/// The URL a `Location` header sends [from] to, or null when it must not
/// be followed: it does not parse, its scheme is not http or https, or it
/// has no host. The caller then hands the 3xx response back as it is.
Uri? redirectTarget(Uri from, String location) {
  final ref = Uri.tryParse(location.trim());
  if (ref == null) return null;
  final Uri to;
  try {
    to = from.resolveUri(ref);
  } on FormatException {
    return null;
  }
  return isWebUrl(to) ? to : null;
}

/// Headers that are credentials whatever they hold.
const _credentialNames = {
  'authorization',
  'proxy-authorization',
  'cookie',
  'cookie2',
};

/// Parts of a header name that mark it as carrying a secret: API keys and
/// tokens set by hand (`X-API-Key`, `X-Auth-Token`, `Private-Token`, ...).
const _credentialParts = [
  'auth',
  'token',
  'secret',
  'passw',
  'credential',
  'session',
  'signature',
  'apikey',
  'api-key',
  'api_key',
  'csrf',
  'xsrf',
];

/// Whether a header called [name] carries credentials, judging by the name
/// alone: Authorization, Proxy-Authorization and Cookie, AWS `X-Amz-*`
/// signing headers, and names that mention a key, token, secret, password,
/// session or signature (`Idempotency-Key` is not a credential).
bool isCredentialHeaderName(String name) {
  final n = name.trim().toLowerCase();
  if (_credentialNames.contains(n) || n.startsWith('x-amz-')) return true;
  if (_credentialParts.any(n.contains)) return true;
  final words = n.split(RegExp(r'[-_.\s]+'));
  return words.contains('key') && !words.contains('idempotency');
}

/// Decides which headers a redirect hop to another origin drops.
///
/// Credentials never follow a redirect to another origin (scheme, host or
/// port), and an https to http downgrade counts as one. What is dropped:
/// every header [isCredentialHeaderName] matches, plus every header an auth
/// helper set on the request ([authHeaders], lower-case names, as
/// `applyAuth` reports them), whatever it is called.
///
/// [keepAuthorization] is the request's "Keep Authorization on redirects to
/// other hosts" setting. It keeps the `Authorization` header only, as its
/// description says, and never on a downgrade to plain http, where the
/// header would cross the network in clear text. Cookies, proxy
/// credentials and the other auth headers are dropped regardless; cookies
/// for the new origin still come from the cookie jar when it is on.
class RedirectCredentialPolicy {
  const RedirectCredentialPolicy({
    this.authHeaders = const {},
    this.keepAuthorization = false,
  });

  final Set<String> authHeaders;
  final bool keepAuthorization;

  /// Whether the hop from [from] to [to] must drop credentials.
  static bool appliesTo(Uri from, Uri to) => !sameOrigin(from, to);

  /// Whether header [name] is dropped on a hop from [from] to [to] (a hop
  /// for which [appliesTo] is true).
  bool drops(String name, {required Uri from, required Uri to}) {
    final n = name.trim().toLowerCase();
    if (n == 'authorization' && keepAuthorization && !isDowngrade(from, to)) {
      return false;
    }
    return isCredentialHeaderName(n) || authHeaders.contains(n);
  }

  /// [headers] as they may be sent on the hop from [from] to [to]: all of
  /// them for a same-origin hop, the credentials left out otherwise.
  List<MapEntry<String, String>> filter(
    Iterable<MapEntry<String, String>> headers, {
    required Uri from,
    required Uri to,
  }) {
    if (!appliesTo(from, to)) return [...headers];
    return [
      for (final h in headers)
        if (!drops(h.key, from: from, to: to)) h,
    ];
  }

  /// The distinct names in [headers] the hop from [from] to [to] drops.
  Set<String> namesToDrop(
    Iterable<MapEntry<String, String>> headers, {
    required Uri from,
    required Uri to,
  }) {
    if (!appliesTo(from, to)) return const {};
    return {
      for (final h in headers)
        if (drops(h.key, from: from, to: to)) h.key,
    };
  }
}

/// The method and whether the body is kept on a redirect with [status],
/// following browsers and Postman: 303 (and 301/302 for anything but GET
/// and HEAD, unless [keepMethod]) become a bodiless GET; 307 and 308 keep
/// both.
({String method, bool keepBody}) redirectMethod(
  String method,
  int status, {
  bool keepMethod = false,
}) {
  final m = method.toUpperCase();
  final toGet =
      status == 303 ||
      ((status == 301 || status == 302) &&
          !keepMethod &&
          m != 'GET' &&
          m != 'HEAD');
  if (!toGet) return (method: method, keepBody: true);
  return (method: m == 'HEAD' ? 'HEAD' : 'GET', keepBody: false);
}
