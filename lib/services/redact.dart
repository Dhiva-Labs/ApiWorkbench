import 'dart:convert';

import '../models/models.dart';
import 'request_builder.dart' show substituteVars;

/// What a credential is replaced with in a report. Same glyphs the Console,
/// the docs export and the diff view use for secrets.
const redactMask = '••••••';

/// Query parameters that carry a credential wherever they appear. Names are
/// compared lowercased with `-`, `_` and spaces removed, so `api_key`,
/// `API-Key` and `apiKey` are one entry.
///
/// A bare `key` is not listed: it is an ordinary parameter on many APIs. The
/// API Key helper's own parameter name is added per request instead (see
/// [authCredentialNames]).
const _sensitiveParams = {
  'apikey',
  'accesstoken',
  'token',
  'idtoken',
  'refreshtoken',
  'clientsecret',
  'password',
  'passwd',
  'secret',
  'sig',
  'signature',
  'sessiontoken',
  'authtoken',
  'authorization',
  // AWS Signature v4 query signing (and the older v2 form).
  'xamzsignature',
  'xamzcredential',
  'xamzsecuritytoken',
  'awsaccesskeyid',
  // Google Cloud signed URLs.
  'xgoogsignature',
  'xgoogcredential',
  // OAuth 1.0 sent in the query.
  'oauthsignature',
  'oauthtoken',
  'oauthconsumerkey',
};

/// Headers whose whole value is a credential, by normalised name.
const _sensitiveHeaders = {
  'authorization',
  'proxyauthorization',
  'cookie',
  'setcookie',
  'setcookie2',
  'xapikey',
  'apikey',
  'xauthtoken',
  'xaccesstoken',
  'xamzsecuritytoken',
  'xcsrftoken',
  'xxsrftoken',
  'xgoogapikey',
};

String _normalise(String name) =>
    name.toLowerCase().replaceAll(RegExp(r'[-_\s]'), '');

/// Whether the query parameter [name] is a credential. [extra] holds names
/// the request's own auth helper adds (see [authCredentialNames]).
bool isSensitiveParam(String name, {Set<String> extra = const {}}) {
  var key = name;
  try {
    key = Uri.decodeQueryComponent(name);
  } catch (_) {}
  final n = _normalise(key);
  return _sensitiveParams.contains(n) || extra.contains(n);
}

/// Whether the header [name] holds a credential. [extra] holds header names
/// the request's own auth helper uses (an API key header, say).
bool isSensitiveHeader(String name, {Set<String> extra = const {}}) {
  final n = _normalise(name);
  return _sensitiveHeaders.contains(n) ||
      extra.contains(n) ||
      n.contains('apikey') ||
      n.contains('secret') ||
      n.contains('password');
}

/// Query parameter and header names [auth] puts credentials in, normalised
/// for [Redactor]. [vars] resolves `{{variables}}` used in those names.
({Set<String> query, Set<String> headers}) authCredentialNames(
  AuthConfig auth, [
  Map<String, String> vars = const {},
]) {
  final query = <String>{};
  final headers = <String>{};
  String name(String raw) =>
      _normalise(vars.isEmpty ? raw : substituteVars(raw, vars));
  switch (auth.type) {
    case AuthType.apiKey:
      if (auth.apiKeyName.isNotEmpty) {
        (auth.apiKeyInHeader ? headers : query).add(name(auth.apiKeyName));
      }
    case AuthType.jwt:
      if (auth.params['addTokenTo'] == 'queryParam') {
        final k = auth.params['queryParamKey'] ?? '';
        query.add(name(k.isEmpty ? 'token' : k));
      }
    default:
      break;
  }
  query.remove('');
  headers.remove('');
  return (query: query, headers: headers);
}

/// Masks credentials in the text a report shows: secret variable values
/// (and the URL-encoded, JSON-escaped and base64 forms they take on the
/// wire), auth query parameters, credentials inside a URL, and credential
/// headers.
///
/// Build one per run and reuse it: the encoded forms of the secrets are worked
/// out once. [withAuth] gives a copy that also knows one request's auth
/// helper, whose parameter or header name is user-chosen.
class Redactor {
  Redactor({Iterable<String> secrets = const []})
    : this._(_Forms(secrets), const {}, const {});

  Redactor._(this._forms, this._extraParams, this._extraHeaders);

  /// Masks nothing but the built-in credential parameters and headers.
  static final Redactor standard = Redactor();

  final _Forms _forms;
  final Set<String> _extraParams;
  final Set<String> _extraHeaders;

  /// Whether there are secret values to look for.
  bool get hasSecrets => _forms.all.isNotEmpty;

  /// A copy that also masks the names [auth] puts credentials in.
  Redactor withAuth(AuthConfig? auth, [Map<String, String> vars = const {}]) {
    if (auth == null) return this;
    final n = authCredentialNames(auth, vars);
    if (n.query.isEmpty && n.headers.isEmpty) return this;
    return Redactor._(
      _forms,
      {..._extraParams, ...n.query},
      {..._extraHeaders, ...n.headers},
    );
  }

  /// [text] with secret values, Basic credentials and the credentials in any
  /// URL inside it masked.
  String text(String text) {
    if (text.isEmpty) return text;
    // Basic first: its base64 form must be decoded before a shorter piece of
    // it is masked on its own.
    return _urls(_forms.mask(_basic(text)));
  }

  /// [url] with secret values, credentials in the user-info part, and
  /// credential query parameters (also in the fragment) masked. Works on a
  /// template such as `{{base}}/x?token={{t}}` too.
  String url(String url) {
    if (url.isEmpty) return url;
    final hash = url.indexOf('#');
    final head = hash < 0 ? url : url.substring(0, hash);
    final fragment = hash < 0 ? null : url.substring(hash + 1);
    final q = head.indexOf('?');
    final base = _userInfo(_forms.mask(q < 0 ? head : head.substring(0, q)));
    final query = q < 0 ? null : head.substring(q + 1);
    return '$base'
        '${query == null ? '' : '?${_pairs(_forms.mask(query))}'}'
        '${fragment == null ? '' : '#${_fragment(_forms.mask(fragment))}'}';
  }

  /// One header value. Credential headers keep only their shape: the scheme
  /// of an Authorization value, the name and attributes of a Set-Cookie.
  String headerValue(String name, String value) {
    final n = _normalise(name);
    if (n == 'location' || n == 'contentlocation') return url(value);
    if (!isSensitiveHeader(name, extra: _extraHeaders)) return text(value);
    return switch (n) {
      'authorization' || 'proxyauthorization' => _authValue(value),
      'cookie' => _cookies(value),
      'setcookie' || 'setcookie2' => _setCookie(value),
      _ => redactMask,
    };
  }

  /// [headers] (name to values) with every value passed through
  /// [headerValue].
  Map<String, List<String>> headers(Map<String, List<String>> headers) => {
    for (final e in headers.entries)
      e.key: [for (final v in e.value) headerValue(e.key, v)],
  };

  // ---- pieces -----------------------------------------------------------

  static final _urlRe = RegExp(
    r'''https?://[^\s"'<>\\]+''',
    caseSensitive: false,
  );
  static final _trailing = RegExp(r'[.,;:)\]}]+$');

  String _urls(String s) {
    if (!s.contains('://')) return s;
    return s.replaceAllMapped(_urlRe, (m) {
      final found = m[0]!;
      final tail = _trailing.firstMatch(found)?[0] ?? '';
      return '${url(found.substring(0, found.length - tail.length))}$tail';
    });
  }

  static final _userInfoRe = RegExp(
    r'^([A-Za-z][A-Za-z0-9+.-]*://)([^/@?#]+)@',
  );

  String _userInfo(String base) {
    final m = _userInfoRe.firstMatch(base);
    if (m == null) return base;
    final info = m[2]!;
    final colon = info.indexOf(':');
    final shown = colon < 0
        ? redactMask
        : '${info.substring(0, colon)}:$redactMask';
    return '${m[1]}$shown${base.substring(m.end - 1)}';
  }

  static final _placeholderOnly = RegExp(r'^(\{\{[^{}]*\}\})+$');

  String _pairs(String query) {
    if (!query.contains('=')) return query;
    return query
        .split('&')
        .map((part) {
          final eq = part.indexOf('=');
          if (eq < 0) return part;
          final value = part.substring(eq + 1);
          // Nothing to hide in an empty value or in a `{{variable}}`
          // reference in a request template.
          if (value.isEmpty || _placeholderOnly.hasMatch(value)) return part;
          return isSensitiveParam(part.substring(0, eq), extra: _extraParams)
              ? '${part.substring(0, eq + 1)}$redactMask'
              : part;
        })
        .join('&');
  }

  /// An OAuth implicit-flow redirect keeps its tokens in the fragment.
  String _fragment(String fragment) =>
      fragment.contains('=') ? _pairs(fragment) : fragment;

  static final _scheme = RegExp(r'^\s*([A-Za-z][A-Za-z0-9_-]*)\s+\S');

  String _authValue(String value) {
    final m = _scheme.firstMatch(value);
    return m == null ? redactMask : '${m[1]} $redactMask';
  }

  String _cookies(String value) => value
      .split(';')
      .map((p) {
        final eq = p.indexOf('=');
        return eq < 0 ? p : '${p.substring(0, eq + 1)}$redactMask';
      })
      .join(';');

  /// `name=value; Path=/; HttpOnly`: only the value is a credential.
  String _setCookie(String value) {
    final eq = value.indexOf('=');
    if (eq < 0) return redactMask;
    final semi = value.indexOf(';');
    final end = semi < 0 ? value.length : semi;
    if (eq > end) return value;
    return '${value.substring(0, eq + 1)}$redactMask${value.substring(end)}';
  }

  static final _basicRe = RegExp(
    r'\bBasic\s+([A-Za-z0-9+/_-]{8,}={0,2})',
    caseSensitive: false,
  );

  /// `Basic <base64>` whose decoded `user:password` holds a secret: the
  /// secret's base64 form depends on what precedes it, so the whole token is
  /// decoded and masked instead of being searched for.
  String _basic(String s) {
    if (!hasSecrets) return s;
    return s.replaceAllMapped(_basicRe, (m) {
      final token = m[1]!;
      String decoded;
      try {
        decoded = utf8.decode(
          base64.decode(
            base64.normalize(token.replaceAll('-', '+').replaceAll('_', '/')),
          ),
          allowMalformed: true,
        );
      } catch (_) {
        return m[0]!;
      }
      return _forms.containsAny(decoded)
          ? '${m[0]!.substring(0, m[0]!.length - token.length)}$redactMask'
          : m[0]!;
    });
  }
}

/// Secret values and the other shapes they take on the wire.
class _Forms {
  _Forms(Iterable<String> secrets) {
    final raw = <String>{
      for (final s in secrets)
        // Shorter values would mask too much; the console and docs ignore
        // them as well.
        if (s.length >= 4) s,
    };
    _raw = raw.toList();
    final all = <String>{...raw};
    for (final s in raw) {
      all
        ..addAll(_urlForms(s))
        ..addAll(_otherForms(s));
    }
    // Longest first so a value containing another is masked whole.
    this.all = all.where((f) => f.length >= 4).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
  }

  late final List<String> _raw;
  late final List<String> all;

  String mask(String text) {
    var out = text;
    for (final f in all) {
      if (out.contains(f)) out = out.replaceAll(f, redactMask);
    }
    return out;
  }

  /// Whether [text] holds one of the plain secret values.
  bool containsAny(String text) => _raw.any(text.contains);

  static Iterable<String> _urlForms(String s) {
    String lower(String e) =>
        e.replaceAllMapped(RegExp('%[0-9A-F]{2}'), (m) => m[0]!.toLowerCase());
    String strict(String e) => e.replaceAllMapped(
      RegExp(r"[!'()*]"),
      (m) => '%${m[0]!.codeUnitAt(0).toRadixString(16).toUpperCase()}',
    );
    final forms = [
      Uri.encodeComponent(s),
      Uri.encodeQueryComponent(s),
      Uri.encodeFull(s),
      strict(Uri.encodeComponent(s)),
    ];
    return [...forms, for (final f in forms) lower(f)];
  }

  static Iterable<String> _otherForms(String s) {
    final json = jsonEncode(s);
    final b64 = base64.encode(utf8.encode(s));
    return [json.substring(1, json.length - 1), b64, b64.replaceAll('=', '')];
  }
}
