import 'dart:io' show Cookie, HttpDate, InternetAddress, SameSite;

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

// ---------------------------------------------------------------------------
// RFC 6265 building blocks. Everything below is pure (no I/O, and no clock
// unless one is passed in) so the rules can be tested one by one.
// ---------------------------------------------------------------------------

/// Identity of a stored cookie: (domain, path, name). A new cookie with the
/// same identity replaces the old one (RFC 6265 section 5.3, step 11).
typedef CookieKey = (String domain, String path, String name);

/// The longest Max-Age honoured, in seconds (about 100 years). Larger values
/// would overflow [DateTime] arithmetic and mean "never" anyway.
const _maxAgeCap = 3153600000;

/// "Deleted": an expiry in the past, the result of Max-Age <= 0.
final _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

/// A Set-Cookie header value taken apart, before it is checked against the
/// URL it came from.
///
/// Parsing is lenient, like browsers: dart:io's parser is tried first, and a
/// tolerant RFC 6265 parser takes over for values it rejects (spaces or
/// quotes in a value, an unreadable Expires or Max-Age, ...).
class SetCookie {
  const SetCookie({
    required this.raw,
    required this.name,
    required this.value,
    this.domain,
    this.path,
    this.expires,
    this.maxAge,
    this.secure = false,
    this.httpOnly = false,
    this.sameSite,
  });

  /// The header value as received.
  final String raw;
  final String name;

  /// Kept exactly as sent, quotes included.
  final String value;

  /// The Domain attribute, lower-cased and without its leading dot; null
  /// when absent or empty.
  final String? domain;

  /// The Path attribute; null when absent, empty or not starting with `/`.
  final String? path;

  /// The Expires attribute (UTC); null when absent or unreadable.
  final DateTime? expires;

  /// The Max-Age attribute in seconds; null when absent or unreadable.
  final int? maxAge;
  final bool secure;
  final bool httpOnly;

  /// `Lax`, `Strict` or `None`; null when absent or unknown.
  final String? sameSite;

  /// Parses [raw]; null when it has no `name=value` pair at all.
  static SetCookie? parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    try {
      final c = Cookie.fromSetCookieValue(text);
      if (c.name.isNotEmpty) return _fromIo(raw, c);
    } catch (_) {
      // Fall through to the tolerant parser.
    }
    return _lenient(raw);
  }

  static SetCookie _fromIo(String raw, Cookie c) => SetCookie(
    raw: raw,
    name: c.name,
    value: c.value,
    domain: _cleanDomain(c.domain),
    path: _cleanPath(c.path),
    expires: c.expires?.toUtc(),
    maxAge: c.maxAge,
    secure: c.secure,
    httpOnly: c.httpOnly,
    sameSite: _cleanSameSite(c.sameSite?.name),
  );

  /// RFC 6265 section 5.2, applied loosely.
  static SetCookie? _lenient(String raw) {
    final parts = raw.split(';');
    final pair = parts.first;
    final eq = pair.indexOf('=');
    if (eq < 0) return null;
    final name = pair.substring(0, eq).trim();
    if (name.isEmpty) return null;
    final value = pair.substring(eq + 1).trim();

    String? domain, path, sameSite;
    DateTime? expires;
    int? maxAge;
    var secure = false, httpOnly = false;
    for (final attr in parts.skip(1)) {
      final i = attr.indexOf('=');
      final key = (i < 0 ? attr : attr.substring(0, i)).trim().toLowerCase();
      final val = i < 0 ? '' : attr.substring(i + 1).trim();
      switch (key) {
        case 'expires':
          expires = parseCookieDate(val) ?? expires;
        case 'max-age':
          if (RegExp(r'^-?\d+$').hasMatch(val)) {
            // Too long for an int: far in the future, or far in the past.
            maxAge =
                int.tryParse(val) ?? (val.startsWith('-') ? -1 : _maxAgeCap);
          }
        case 'domain':
          domain = _cleanDomain(val);
        case 'path':
          path = _cleanPath(val);
        case 'secure':
          secure = true;
        case 'httponly':
          httpOnly = true;
        case 'samesite':
          sameSite = _cleanSameSite(val);
      }
    }
    return SetCookie(
      raw: raw,
      name: name,
      value: value,
      domain: domain,
      path: path,
      expires: expires,
      maxAge: maxAge,
      secure: secure,
      httpOnly: httpOnly,
      sameSite: sameSite,
    );
  }

  /// When the cookie lapses if received at [now]: Max-Age wins over Expires,
  /// and Max-Age <= 0 means "already gone". Null for a session cookie.
  DateTime? expiryAt(DateTime now) {
    final age = maxAge;
    if (age == null) return expires;
    if (age <= 0) return _epoch;
    return now.toUtc().add(
      Duration(seconds: age > _maxAgeCap ? _maxAgeCap : age),
    );
  }
}

String? _cleanDomain(String? d) {
  var s = (d ?? '').trim().toLowerCase();
  while (s.startsWith('.')) {
    s = s.substring(1);
  }
  return s.isEmpty ? null : s;
}

String? _cleanPath(String? p) {
  final s = (p ?? '').trim();
  return s.startsWith('/') ? s : null;
}

String? _cleanSameSite(String? s) => switch ((s ?? '').trim().toLowerCase()) {
  'lax' => 'Lax',
  'strict' => 'Strict',
  'none' => 'None',
  _ => null,
};

/// A cookie as the jar keeps it.
class StoredCookie {
  const StoredCookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.created,
    this.hostOnly = true,
    this.path = '/',
    this.expires,
    this.secure = false,
    this.httpOnly = false,
    this.sameSite,
  });

  final String name;
  final String value;

  /// Lower-case host without a leading dot. For a [hostOnly] cookie this is
  /// the exact host that set it.
  final String domain;

  /// True when the server sent no Domain attribute: only [domain] itself
  /// gets the cookie back, not its subdomains.
  final bool hostOnly;
  final String path;

  /// When the cookie lapses (UTC); null for a session cookie. The jar keeps
  /// session cookies across restarts, as Postman does.
  final DateTime? expires;
  final bool secure;
  final bool httpOnly;

  /// `Lax`, `Strict` or `None`. Shown only: an API client has no "site" to
  /// compare, so it never withholds a cookie because of it.
  final String? sameSite;

  /// When the cookie first arrived. A replacement inherits it, so editing a
  /// cookie doesn't change its place in the sending order.
  final DateTime created;

  CookieKey get key => (domain, path, name);
  bool get isSession => expires == null;

  /// Whether the cookie has lapsed at [now].
  bool isExpired(DateTime now) => expires != null && !expires!.isAfter(now);

  StoredCookie copyWith({DateTime? created}) => StoredCookie(
    name: name,
    value: value,
    domain: domain,
    hostOnly: hostOnly,
    path: path,
    expires: expires,
    secure: secure,
    httpOnly: httpOnly,
    sameSite: sameSite,
    created: created ?? this.created,
  );

  /// A dart:io [Cookie] copy for scripts. Changing it doesn't touch the jar,
  /// and values dart:io would refuse (spaces, quotes) are carried as they
  /// are.
  Cookie toCookie() => _CookieView(this);

  /// The cookie as an editable Set-Cookie line. The Domain attribute is
  /// written only for cookies that also match subdomains.
  String toSetCookieLine() {
    final b = StringBuffer('$name=$value');
    if (!hostOnly) b.write('; Domain=$domain');
    b.write('; Path=$path');
    if (expires != null) b.write('; Expires=${HttpDate.format(expires!)}');
    if (secure) b.write('; Secure');
    if (httpOnly) b.write('; HttpOnly');
    if (sameSite != null) b.write('; SameSite=$sameSite');
    return b.toString();
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'value': value,
    'domain': domain,
    'hostOnly': hostOnly,
    'path': path,
    if (expires != null) 'expires': expires!.microsecondsSinceEpoch,
    if (secure) 'secure': true,
    if (httpOnly) 'httpOnly': true,
    if (sameSite != null) 'sameSite': sameSite,
    'created': created.microsecondsSinceEpoch,
  };

  /// Reads one saved cookie; null when it is damaged.
  static StoredCookie? fromJson(Object? j) {
    if (j is! Map) return null;
    final name = j['name'], value = j['value'], domain = j['domain'];
    if (name is! String || name.isEmpty || value is! String) return null;
    if (domain is! String || domain.isEmpty) return null;
    final path = j['path'];
    final expires = j['expires'], created = j['created'];
    return StoredCookie(
      name: name,
      value: value,
      domain: domain.toLowerCase(),
      hostOnly: j['hostOnly'] as bool? ?? true,
      path: path is String && path.startsWith('/') ? path : '/',
      expires: expires is int
          ? DateTime.fromMicrosecondsSinceEpoch(expires, isUtc: true)
          : null,
      secure: j['secure'] as bool? ?? false,
      httpOnly: j['httpOnly'] as bool? ?? false,
      sameSite: _cleanSameSite(j['sameSite'] as String?),
      created: created is int
          ? DateTime.fromMicrosecondsSinceEpoch(created, isUtc: true)
          : DateTime.now().toUtc(),
    );
  }

  @override
  String toString() => '$name=$value';
}

/// What [StoredCookie.toCookie] hands out: a detached copy that implements
/// dart:io's [Cookie] without its character checks. Unlike a parsed header it
/// always carries the domain, so scripts can tell where a cookie belongs.
class _CookieView implements Cookie {
  _CookieView(StoredCookie c)
    : name = c.name,
      value = c.value,
      domain = c.domain,
      path = c.path,
      expires = c.expires,
      secure = c.secure,
      httpOnly = c.httpOnly,
      sameSite = switch (c.sameSite) {
        'Lax' => SameSite.lax,
        'Strict' => SameSite.strict,
        'None' => SameSite.none,
        _ => null,
      };

  @override
  String name;
  @override
  String value;
  @override
  DateTime? expires;
  @override
  int? maxAge;
  @override
  String? domain;
  @override
  String? path;
  @override
  bool secure;
  @override
  bool httpOnly;
  @override
  SameSite? sameSite;

  @override
  String toString() => '$name=$value';
}

/// The host of [url] as cookies see it: lower-case, no trailing dot.
String canonicalCookieHost(Uri url) {
  var h = url.host.toLowerCase();
  while (h.endsWith('.')) {
    h = h.substring(0, h.length - 1);
  }
  return h;
}

/// Whether [host] is an IPv4 or IPv6 literal. Cookies for those never match
/// subdomains.
bool isIpHost(String host) => InternetAddress.tryParse(host) != null;

/// RFC 6265 section 5.1.3: [host] equals [domain] or is a subdomain of it.
/// IP addresses only ever match themselves.
bool domainMatches(String host, String domain) {
  if (host == domain) return true;
  return !isIpHost(host) && host.endsWith('.$domain');
}

/// A few well-known two-label public suffixes. The real list has thousands
/// of entries; this keeps `Domain=co.uk` from sharing a cookie between
/// unrelated sites without shipping it.
const _multiLabelSuffixes = {
  'co.uk', 'org.uk', 'me.uk', 'ltd.uk', 'plc.uk', 'net.uk', 'ac.uk', //
  'gov.uk', 'sch.uk', 'com.au', 'net.au', 'org.au', 'edu.au', 'gov.au',
  'co.nz', 'org.nz', 'net.nz', 'co.jp', 'ne.jp', 'or.jp', 'ac.jp', 'go.jp',
  'co.in', 'net.in', 'org.in', 'ac.in', 'gov.in', 'com.br', 'net.br',
  'org.br', 'gov.br', 'com.cn', 'net.cn', 'org.cn', 'gov.cn', 'com.mx',
  'co.za', 'org.za', 'com.sg', 'com.hk', 'com.tw', 'co.kr', 'or.kr',
  'com.tr', 'co.id', 'com.my', 'com.ar', 'co.il',
};

/// Single labels (`com`, `localhost`) and the common two-label suffixes
/// above. Real hosts can't set cookies for these.
bool isPublicSuffix(String domain) =>
    !domain.contains('.') || _multiLabelSuffixes.contains(domain);

/// RFC 6265 section 5.1.4: the directory part of the request path, `/` when
/// there is none.
String defaultCookiePath(String requestPath) {
  if (requestPath.isEmpty || !requestPath.startsWith('/')) return '/';
  final last = requestPath.lastIndexOf('/');
  return last == 0 ? '/' : requestPath.substring(0, last);
}

/// RFC 6265 section 5.1.4: [cookiePath] equals [requestPath] or is a
/// directory prefix of it.
bool cookiePathMatches(String requestPath, String cookiePath) {
  final path = requestPath.isEmpty ? '/' : requestPath;
  if (path == cookiePath) return true;
  if (!path.startsWith(cookiePath)) return false;
  return cookiePath.endsWith('/') || path[cookiePath.length] == '/';
}

/// Whether Secure cookies may go to [url]: https, or a loopback host.
/// Browsers treat `localhost` and 127.0.0.1 as secure contexts, so local
/// development with a Secure cookie works over plain http.
bool isSecureCookieContext(Uri url) {
  if (url.scheme == 'https' || url.scheme == 'wss') return true;
  final h = canonicalCookieHost(url);
  return h == 'localhost' ||
      h.endsWith('.localhost') ||
      h == '::1' ||
      RegExp(r'^127(\.\d{1,3}){3}$').hasMatch(h);
}

const _months = [
  'jan', 'feb', 'mar', 'apr', 'may', 'jun', //
  'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
];

/// RFC 6265 section 5.1.1: reads the many date spellings found in Expires
/// attributes (`Wed, 21 Oct 2026 07:28:00 GMT`, `Wed, 21-Oct-26 ...`, ...).
/// Returns null when it can't find a time, day, month and year.
DateTime? parseCookieDate(String input) {
  final tokens = input
      .split(RegExp(r'[\x09\x20-\x2F\x3B-\x40\x5B-\x60\x7B-\x7E]+'))
      .where((t) => t.isNotEmpty);
  int? hour, minute, second, day, month, year;
  for (final t in tokens) {
    if (hour == null) {
      final m = RegExp(
        r'^(\d{1,2}):(\d{1,2}):(\d{1,2})(?:\D.*)?$',
      ).firstMatch(t);
      if (m != null) {
        hour = int.parse(m[1]!);
        minute = int.parse(m[2]!);
        second = int.parse(m[3]!);
        continue;
      }
    }
    if (day == null) {
      final m = RegExp(r'^(\d{1,2})(?:\D.*)?$').firstMatch(t);
      if (m != null) {
        day = int.parse(m[1]!);
        continue;
      }
    }
    if (month == null && t.length >= 3) {
      final i = _months.indexOf(t.substring(0, 3).toLowerCase());
      if (i >= 0) {
        month = i + 1;
        continue;
      }
    }
    if (year == null) {
      final m = RegExp(r'^(\d{2,4})(?:\D.*)?$').firstMatch(t);
      if (m != null) {
        year = int.parse(m[1]!);
        continue;
      }
    }
  }
  if (hour == null ||
      minute == null ||
      second == null ||
      day == null ||
      month == null ||
      year == null) {
    return null;
  }
  if (year >= 70 && year <= 99) year += 1900;
  if (year >= 0 && year <= 69) year += 2000;
  if (day < 1 || day > 31 || year < 1601) return null;
  if (hour > 23 || minute > 59 || second > 59) return null;
  final d = DateTime.utc(year, month, day, hour, minute, second);
  return d.month == month ? d : null; // 31 Feb and friends roll over
}

/// What the jar makes of a Set-Cookie received from a URL: the cookie to
/// store, or the reason it is ignored.
typedef CookieVerdict = ({StoredCookie? cookie, String? rejection});

/// RFC 6265 section 5.3: decides whether [sc], received in a response from
/// [url], is accepted, and builds the cookie that would be stored.
///
/// A Max-Age <= 0 (or an Expires in the past) yields a cookie that is
/// already expired: the jar treats it as "delete the cookie with this
/// identity". Max-Age wins over Expires.
CookieVerdict evaluateSetCookie(SetCookie sc, Uri url, {DateTime? now}) {
  final t = (now ?? DateTime.now()).toUtc();
  CookieVerdict reject(String why) => (cookie: null, rejection: why);

  final host = canonicalCookieHost(url);
  if (host.isEmpty) return reject('The request URL has no host.');

  String domain;
  bool hostOnly;
  final attr = sc.domain;
  if (attr == null) {
    domain = host;
    hostOnly = true;
  } else if (isIpHost(host)) {
    // IP addresses can't have subdomains: only the address itself matches.
    if (attr != host) {
      return reject('Domain "$attr" does not match the IP address $host.');
    }
    domain = host;
    hostOnly = true;
  } else if (isPublicSuffix(attr)) {
    // A host may set a cookie for itself even if it is a bare name such as
    // "localhost", but never share one with every site under a suffix.
    if (attr != host) {
      return reject(
        'Domain "$attr" is a public suffix; cookies can\'t be shared there.',
      );
    }
    domain = host;
    hostOnly = true;
  } else if (!domainMatches(host, attr)) {
    return reject('Domain "$attr" does not match the host $host.');
  } else {
    domain = attr;
    hostOnly = false;
  }

  return (
    cookie: StoredCookie(
      name: sc.name,
      value: sc.value,
      domain: domain,
      hostOnly: hostOnly,
      path: sc.path ?? defaultCookiePath(url.path),
      expires: sc.expiryAt(t),
      secure: sc.secure,
      httpOnly: sc.httpOnly,
      sameSite: sc.sameSite,
      created: t,
    ),
    rejection: null,
  );
}

/// Builds a cookie from a hand-typed Set-Cookie [line] filed under [domain],
/// for the cookie manager. Unlike [evaluateSetCookie] nothing is checked
/// against a request: the user decides. A `Domain=` attribute in the line
/// makes it match subdomains too.
///
/// Throws [FormatException] with a message fit for a form field.
StoredCookie cookieFromLine(String line, String domain, {DateTime? now}) {
  final sc = SetCookie.parse(line);
  if (sc == null) {
    throw const FormatException(
      'Expected name=value, for example: session=abc123; Path=/; Secure',
    );
  }
  var host = domain.trim();
  if (host.contains('://')) host = Uri.tryParse(host)?.host ?? host;
  final d = _cleanDomain(host);
  if (d == null) {
    throw const FormatException(
      'Enter the domain, for example api.example.com',
    );
  }
  final t = (now ?? DateTime.now()).toUtc();
  return StoredCookie(
    name: sc.name,
    value: sc.value,
    domain: d,
    hostOnly: sc.domain == null,
    path: sc.path ?? '/',
    expires: sc.expiryAt(t),
    secure: sc.secure,
    httpOnly: sc.httpOnly,
    sameSite: sc.sameSite,
    created: t,
  );
}
