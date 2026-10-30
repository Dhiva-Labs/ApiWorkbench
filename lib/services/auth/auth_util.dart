import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../models/models.dart';
import '../request_builder.dart';

final _random = Random.secure();

/// [n] cryptographically random bytes.
Uint8List randomBytes(int n) =>
    Uint8List.fromList(List.generate(n, (_) => _random.nextInt(256)));

const _alnum = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

/// A random string of [n] letters and digits, for nonces.
String randomAlnum(int n) => String.fromCharCodes(
  List.generate(n, (_) => _alnum.codeUnitAt(_random.nextInt(62))),
);

/// Lowercase hex of [bytes].
String hexOf(List<int> bytes) {
  final out = StringBuffer();
  for (final b in bytes) {
    out.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

/// Bytes of a hex string (whitespace ignored).
Uint8List hexBytes(String hex) {
  final s = hex.replaceAll(RegExp(r'\s'), '');
  return Uint8List.fromList([
    for (var i = 0; i + 1 < s.length; i += 2)
      int.parse(s.substring(i, i + 2), radix: 16),
  ]);
}

/// Base64url without padding, as JWTs and PKCE use it.
String base64UrlNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// RFC 3986 percent-encoding: every byte except the unreserved characters
/// `A-Z a-z 0-9 - . _ ~` becomes `%XX` (uppercase). OAuth 1.0 and AWS
/// signatures both require exactly this form.
String rfc3986(String s) {
  final out = StringBuffer();
  for (final b in utf8.encode(s)) {
    final unreserved =
        (b >= 0x41 && b <= 0x5A) ||
        (b >= 0x61 && b <= 0x7A) ||
        (b >= 0x30 && b <= 0x39) ||
        b == 0x2D ||
        b == 0x2E ||
        b == 0x5F ||
        b == 0x7E;
    if (unreserved) {
      out.writeCharCode(b);
    } else {
      out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

/// Decodes a form or query component (`+` is a space). Malformed escapes
/// are kept as typed rather than failing the send.
String decodeComponent(String s) {
  try {
    return Uri.decodeQueryComponent(s);
  } on ArgumentError {
    return s;
  } on FormatException {
    return s;
  }
}

/// `name=value` pairs of a query string or form body, decoded, in order and
/// with duplicates kept. A bare `name` has an empty value.
List<MapEntry<String, String>> formPairs(String raw) => [
  for (final part in raw.split('&'))
    if (part.isNotEmpty)
      () {
        final eq = part.indexOf('=');
        return eq < 0
            ? MapEntry(decodeComponent(part), '')
            : MapEntry(
                decodeComponent(part.substring(0, eq)),
                decodeComponent(part.substring(eq + 1)),
              );
      }(),
];

/// A boolean auth param as Postman stores it ("true"/"false").
bool authFlag(AuthConfig auth, String key, {bool fallback = false}) {
  final v = auth.params[key]?.trim().toLowerCase();
  if (v == null || v.isEmpty) return fallback;
  return v == 'true' || v == '1' || v == 'yes';
}

/// The port a URL talks to, explicit or the scheme's default.
int effectivePort(Uri u) => u.hasPort
    ? u.port
    : switch (u.scheme) {
        'https' || 'wss' => 443,
        _ => 80,
      };

/// The Host header for [u]: host, plus `:port` when it isn't the default.
String hostHeader(Uri u) {
  final host = u.host.contains(':') ? '[${u.host}]' : u.host;
  final defaultPort = u.scheme == 'https' ? 443 : 80;
  return u.hasPort && u.port != defaultPort ? '$host:${u.port}' : host;
}

/// The request target signers use: the path (or `/`) plus `?query`.
String requestTarget(Uri u) {
  final path = u.path.isEmpty ? '/' : u.path;
  return u.hasQuery ? '$path?${u.query}' : path;
}

/// True when the body is an `application/x-www-form-urlencoded` form.
bool isFormBody(PreparedRequest p) => (p.headers.value('content-type') ?? '')
    .toLowerCase()
    .startsWith('application/x-www-form-urlencoded');

/// Hex SHA-256 of [bytes].
String sha256Hex(List<int> bytes) => hexOf(sha256.convert(bytes).bytes);

/// One challenge of a `WWW-Authenticate` header, such as
/// `Digest realm="x", nonce="y"` or `NTLM TlRMTVNTUAAC...`.
class AuthChallenge {
  AuthChallenge(this.scheme, [Map<String, String>? params, this.token68])
    : params = params ?? {};

  /// The scheme as sent, e.g. `Digest`.
  final String scheme;

  /// Auth-params with lowercase names and unquoted values.
  final Map<String, String> params;

  /// The single token form used by NTLM and Negotiate.
  final String? token68;

  bool isScheme(String s) => scheme.toLowerCase() == s.toLowerCase();
}

final _tokenChar = RegExp(r"[A-Za-z0-9!#$%&'*+\-.^_`|~]");
final _token68 = RegExp(r'^[A-Za-z0-9\-._~+/]+=*$');

/// Parses `WWW-Authenticate` values. One value may hold several
/// challenges (`Basic realm="a", Digest realm="b", nonce="c"`), and a
/// server may also send several values.
List<AuthChallenge> parseChallenges(Iterable<String> values) {
  final out = <AuthChallenge>[];
  for (final v in values) {
    out.addAll(_parseChallengeValue(v));
  }
  return out;
}

List<AuthChallenge> _parseChallengeValue(String s) {
  final out = <AuthChallenge>[];
  var i = 0;
  bool isWs(int at) => at < s.length && (s[at] == ' ' || s[at] == '\t');
  void skipWs() {
    while (isWs(i)) {
      i++;
    }
  }

  String readToken() {
    final start = i;
    while (i < s.length && _tokenChar.hasMatch(s[i])) {
      i++;
    }
    return s.substring(start, i);
  }

  String readValue() {
    if (i < s.length && s[i] == '"') {
      i++;
      final b = StringBuffer();
      while (i < s.length && s[i] != '"') {
        if (s[i] == '\\' && i + 1 < s.length) i++;
        b.write(s[i++]);
      }
      i++; // closing quote
      return b.toString();
    }
    final start = i;
    while (i < s.length && s[i] != ',' && !isWs(i)) {
      i++;
    }
    return s.substring(start, i);
  }

  while (i < s.length) {
    while (i < s.length && (s[i] == ',' || isWs(i))) {
      i++;
    }
    final scheme = readToken();
    if (scheme.isEmpty) break;
    final c = AuthChallenge(scheme);
    out.add(c);
    skipWs();
    // token68 (NTLM, Negotiate): one blob up to the next comma.
    final comma = s.indexOf(',', i);
    final segment = s.substring(i, comma < 0 ? s.length : comma).trim();
    if (segment.isNotEmpty && _token68.hasMatch(segment)) {
      out[out.length - 1] = AuthChallenge(scheme, null, segment);
      i = comma < 0 ? s.length : comma + 1;
      continue;
    }
    while (i < s.length) {
      skipWs();
      final save = i;
      final name = readToken();
      skipWs();
      if (name.isEmpty || i >= s.length || s[i] != '=') {
        // The start of the next challenge.
        i = save;
        break;
      }
      i++; // '='
      skipWs();
      c.params[name.toLowerCase()] = readValue();
      skipWs();
      if (i < s.length && s[i] == ',') {
        i++;
        skipWs();
        // A token followed by '=' is another param; otherwise a new
        // challenge starts here.
        final peek = i;
        readToken();
        skipWs();
        final isParam = i < s.length && s[i] == '=';
        i = peek;
        if (!isParam) break;
      } else {
        break;
      }
    }
  }
  return out;
}

/// `WWW-Authenticate` values of a response, any header-name case.
List<String> wwwAuthenticate(ResponseData res) => [
  for (final e in res.headers.entries)
    if (e.key.toLowerCase() == 'www-authenticate') ...e.value,
];

/// Quotes [v] for a header auth-param.
String quoted(String v) =>
    '"${v.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
