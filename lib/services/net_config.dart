import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio_http2_adapter/dio_http2_adapter.dart';

import '../models/models.dart';

/// What a transport is built for. Requests with the same key share
/// connections.
class TransportKey {
  const TransportKey({required this.verifySsl, this.clientCertId});

  final bool verifySsl;

  /// The [ClientCertificate.id] presented, or null for none.
  final String? clientCertId;

  @override
  bool operator ==(Object other) =>
      other is TransportKey &&
      other.verifySsl == verifySsl &&
      other.clientCertId == clientCertId;

  @override
  int get hashCode => Object.hash(verifySsl, clientCertId);
}

/// A proxy or certificate setting that cannot be used, worded for the
/// person who has to fix it (missing file, wrong passphrase, bad port).
///
/// Transports throw it while they are being built (or, for certificate
/// files, on the first https request); `HttpService` turns it into the
/// request's error message through [describeNetworkError].
class NetConfigException implements Exception {
  NetConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
// Proxy
// ---------------------------------------------------------------------------

/// An HTTP proxy to send a request through, with optional Basic credentials.
class ProxyEndpoint {
  const ProxyEndpoint(
    this.host,
    this.port, {
    this.user = '',
    this.password = '',
  });

  /// Host name or address, without brackets around IPv6 literals.
  final String host;
  final int port;
  final String user;
  final String password;

  bool get hasCredentials => user.isNotEmpty;

  /// `host:port`, with IPv6 hosts in brackets.
  String get authority => '${host.contains(':') ? '[$host]' : host}:$port';

  /// Whether dart:io accepts the credentials inside a `PROXY user:pass@host`
  /// string. Its parser splits on `;` and `:`, trims, and rejects an empty
  /// password.
  bool get credentialsFitInProxyString =>
      password.isNotEmpty &&
      user == user.trim() &&
      password == password.trim() &&
      !user.contains(':') &&
      !user.contains(';') &&
      !password.contains(';');

  /// The value for `HttpClient.findProxy`.
  ///
  /// dart:io only sends proxy credentials that sit inside this string (the
  /// separate `addProxyCredentials` route is not used for CONNECT, and
  /// retries a rejected password forever), so credentials it cannot carry
  /// throw a [NetConfigException] instead of failing in some other way.
  String toFindProxyString() {
    if (!hasCredentials) return 'PROXY $authority';
    if (!credentialsFitInProxyString) {
      throw NetConfigException(
        'The proxy username or password has characters that HTTP/1.1 '
        'requests cannot send: ";", ":" in the user name, spaces at either '
        'end, or an empty password. Change the credentials, or use HTTP/2.',
      );
    }
    return 'PROXY $user:$password@$authority';
  }

  @override
  String toString() => authority;
}

/// Splits `host`, `host:port`, `[v6]` and `[v6]:port`. A bare IPv6 literal
/// (several colons, no brackets) is all host.
(String host, int? port) splitHostPort(String input) {
  final s = input.trim();
  if (s.startsWith('[')) {
    final end = s.indexOf(']');
    if (end > 0) {
      final rest = s.substring(end + 1);
      return (
        s.substring(1, end),
        rest.startsWith(':') ? int.tryParse(rest.substring(1)) : null,
      );
    }
  }
  final colon = s.indexOf(':');
  if (colon >= 0 && colon == s.lastIndexOf(':')) {
    final port = int.tryParse(s.substring(colon + 1));
    if (port != null) return (s.substring(0, colon), port);
  }
  return (s, null);
}

/// `http://host:8080/path` -> `host:8080`; text without a scheme or path is
/// returned trimmed.
String _stripSchemeAndPath(String s) {
  var out = s.trim().replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '');
  final slash = out.indexOf('/');
  if (slash >= 0) out = out.substring(0, slash);
  return out;
}

final _cidr = RegExp(r'^\[?([0-9a-f:.]+)\]?/(\d{1,3})$');

bool _sameAddress(InternetAddress a, InternetAddress b) {
  final x = a.rawAddress;
  final y = b.rawAddress;
  if (x.length != y.length) return false;
  for (var i = 0; i < x.length; i++) {
    if (x[i] != y[i]) return false;
  }
  return true;
}

bool _inCidr(InternetAddress network, int bits, InternetAddress host) {
  final n = network.rawAddress;
  final h = host.rawAddress;
  if (n.length != h.length || bits < 0 || bits > n.length * 8) return false;
  for (var i = 0; i < n.length && bits > 0; i++, bits -= 8) {
    final mask = bits >= 8 ? 0xFF : (0xFF << (8 - bits)) & 0xFF;
    if ((n[i] & mask) != (h[i] & mask)) return false;
  }
  return true;
}

/// Whether [url]'s host is on a proxy bypass [list] (comma, semicolon or
/// space separated). Entries are
///
/// * `*` for everything, and `<local>` for names without a dot;
/// * `example.com`: that host and its subdomains;
/// * `*.example.com` or `.example.com`: subdomains only;
/// * IP addresses and CIDR ranges (`10.0.0.0/8`, `fd00::/8`);
/// * other `*` patterns (`192.168.*`, `build-*.corp`);
///
/// each with an optional `:port`. Case is ignored.
bool bypassMatches(Uri url, String list) {
  final host = url.host.toLowerCase();
  if (host.isEmpty) return false;
  final hostIp = InternetAddress.tryParse(host);
  for (final raw in list.split(RegExp(r'[,;\s]+'))) {
    final text = raw.trim().toLowerCase();
    if (text.isEmpty) continue;
    final cidr = _cidr.firstMatch(text);
    if (cidr != null) {
      final network = InternetAddress.tryParse(cidr.group(1)!);
      if (network != null &&
          hostIp != null &&
          _inCidr(network, int.parse(cidr.group(2)!), hostIp)) {
        return true;
      }
      continue;
    }
    final entry = _stripSchemeAndPath(text);
    if (entry == '*') return true;
    if (entry == '<local>') {
      if (!host.contains('.') && hostIp == null) return true;
      continue;
    }
    final (name, port) = splitHostPort(entry);
    if (name.isEmpty || (port != null && port != url.port)) continue;
    final entryIp = InternetAddress.tryParse(name);
    if (entryIp != null) {
      if (hostIp != null && _sameAddress(entryIp, hostIp)) return true;
    } else if (name.startsWith('*.')) {
      if (host.endsWith(name.substring(1))) return true;
    } else if (name.startsWith('.')) {
      if (host.endsWith(name)) return true;
    } else if (name.contains('*')) {
      final glob = RegExp(
        '^${name.split('*').map(RegExp.escape).join('.*')}\$',
      );
      if (glob.hasMatch(host)) return true;
    } else if (host == name || host.endsWith('.$name')) {
      return true;
    }
  }
  return false;
}

String _decode(String s) {
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s;
  }
}

/// The custom proxy from [net], or null when no host is set. Accepts a host
/// pasted as `http://user:pass@proxy.corp:3128/`.
ProxyEndpoint? _customEndpoint(NetworkSettings net) {
  var h = _stripSchemeAndPath(net.proxyHost);
  if (h.isEmpty) return null;
  var user = net.proxyUser;
  var pass = net.proxyPassword;
  final at = h.lastIndexOf('@');
  if (at >= 0) {
    final info = h.substring(0, at);
    h = h.substring(at + 1);
    if (user.isEmpty) {
      final colon = info.indexOf(':');
      user = _decode(colon < 0 ? info : info.substring(0, colon));
      pass = colon < 0 ? '' : _decode(info.substring(colon + 1));
    }
  }
  final (host, port) = splitHostPort(h);
  if (host.isEmpty) return null;
  return ProxyEndpoint(host, port ?? net.proxyPort, user: user, password: pass);
}

/// Parses `PROXY [user:pass@]host:port` as produced by
/// [HttpClient.findProxyFromEnvironment]; null for `DIRECT`.
ProxyEndpoint? _parseProxyString(String s) {
  final first = s.split(';').first.trim();
  if (!first.startsWith('PROXY ')) return null;
  var rest = first.substring(6).trim();
  var user = '';
  var pass = '';
  final at = rest.lastIndexOf('@');
  if (at >= 0) {
    final info = rest.substring(0, at);
    rest = rest.substring(at + 1);
    final colon = info.indexOf(':');
    // Credentials in HTTP_PROXY are URL-encoded by convention; dart:io
    // would send them as written.
    user = _decode(colon < 0 ? info : info.substring(0, colon));
    pass = colon < 0 ? '' : _decode(info.substring(colon + 1));
  }
  final (host, port) = splitHostPort(rest);
  if (host.isEmpty || port == null) return null;
  return ProxyEndpoint(host, port, user: user, password: pass);
}

/// The proxy [url] goes through under [net], or null for a direct
/// connection.
///
/// [environment] replaces the process environment in system mode (tests).
ProxyEndpoint? proxyEndpointFor(
  NetworkSettings net,
  Uri url, {
  Map<String, String>? environment,
}) {
  switch (net.proxyMode) {
    case ProxyMode.none:
      return null;
    case ProxyMode.system:
      final env = environment ?? Platform.environment;
      // dart:io only understands NO_PROXY suffixes; this adds `*`, CIDR
      // ranges and ports, which the same variable carries elsewhere.
      final noProxy = env['no_proxy'] ?? env['NO_PROXY'];
      if (noProxy != null && bypassMatches(url, noProxy)) return null;
      return _parseProxyString(
        HttpClient.findProxyFromEnvironment(url, environment: env),
      );
    case ProxyMode.custom:
      final proxy = _customEndpoint(net);
      if (proxy == null || bypassMatches(url, net.proxyBypass)) return null;
      return proxy;
  }
}

/// `DIRECT` or `PROXY host:port` for [url], the form
/// `HttpClient.findProxy` uses (without credentials, so it is safe to log).
///
/// * none: always `DIRECT`;
/// * system: the HTTP_PROXY / HTTPS_PROXY / NO_PROXY variables, upper or
///   lower case (see [environment]);
/// * custom: the configured proxy unless [url] is on the bypass list.
String proxyFor(
  NetworkSettings net,
  Uri url, {
  Map<String, String>? environment,
}) {
  final proxy = proxyEndpointFor(net, url, environment: environment);
  return proxy == null ? 'DIRECT' : 'PROXY ${proxy.authority}';
}

/// Throws a [NetConfigException] when the custom proxy's port is not valid.
void _validateProxyPort(NetworkSettings net) {
  if (net.proxyMode != ProxyMode.custom) return;
  final proxy = _customEndpoint(net);
  if (proxy != null && (proxy.port < 1 || proxy.port > 65535)) {
    throw NetConfigException(
      'The proxy port ${proxy.port} is not valid. Use a number from 1 to '
      '65535 under Settings > Proxy and certificates.',
    );
  }
}

/// Sends requests from [client] through the configured proxy. A
/// [tlsProblem] makes https requests fail with it, from the same callback,
/// since `HttpClient` has no other per-request hook.
void _applyProxy(
  HttpClient client,
  NetworkSettings net, {
  NetConfigException? tlsProblem,
}) {
  _validateProxyPort(net);
  // Fail now, not on the first request, when dart:io cannot carry the
  // credentials.
  if (net.proxyMode == ProxyMode.custom) {
    _customEndpoint(net)?.toFindProxyString();
  }
  client.findProxy = (url) {
    if (tlsProblem != null && url.scheme == 'https') throw tlsProblem;
    return proxyEndpointFor(net, url)?.toFindProxyString() ?? 'DIRECT';
  };
}

// ---------------------------------------------------------------------------
// Client certificate selection
// ---------------------------------------------------------------------------

/// How well a client-certificate host [pattern] fits [url]; 0 for no match.
/// Specific patterns score higher: a host name, then longer `*.` wildcards,
/// then `*`; naming the port breaks ties.
int _certScore(String pattern, Uri url) {
  final (name, port) = splitHostPort(
    _stripSchemeAndPath(pattern).toLowerCase(),
  );
  if (name.isEmpty || (port != null && port != url.port)) return 0;
  final host = url.host.toLowerCase();
  final portBonus = port == null ? 0 : 1;
  if (name == '*') return 1000000 + portBonus;
  if (name.startsWith('*.') || name.startsWith('.')) {
    final suffix = name.startsWith('*.') ? name.substring(1) : name;
    return host.endsWith(suffix) ? 2000000 + suffix.length * 2 + portBonus : 0;
  }
  final a = InternetAddress.tryParse(name);
  final b = InternetAddress.tryParse(host);
  final same = a != null && b != null ? _sameAddress(a, b) : name == host;
  return same ? 3000000 + name.length * 2 + portBonus : 0;
}

/// The client certificate configured for [url]'s host, if any.
///
/// The host pattern is a name (`api.example.com`), a `*.` wildcard for
/// subdomains at any depth (`*.example.com`), or `*`, each with an optional
/// port (`api.example.com:8443`). A pattern without a port fits every port.
/// When several enabled entries fit, the most specific one wins, so a
/// certificate for one host can sit next to a wildcard for its domain.
/// Only https (and wss) URLs get one.
ClientCertificate? clientCertFor(NetworkSettings net, Uri url) {
  // A certificate only means something inside TLS.
  if (url.scheme != 'https' && url.scheme != 'wss') return null;
  ClientCertificate? best;
  var bestScore = 0;
  for (final c in net.clientCerts) {
    if (!c.enabled) continue;
    final score = _certScore(c.host, url);
    if (score > bestScore) {
      best = c;
      bestScore = score;
    }
  }
  return best;
}

// ---------------------------------------------------------------------------
// TLS: custom CA and client certificates
// ---------------------------------------------------------------------------

String _expandHome(String path) {
  final p = path.trim();
  if (p == '~' || p.startsWith('~/') || p.startsWith(r'~\')) {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null) return home + p.substring(1);
  }
  return p;
}

List<int> _readFile(String path, String what) {
  final file = File(_expandHome(path));
  if (!file.existsSync()) {
    throw NetConfigException('The $what was not found: $path');
  }
  try {
    final bytes = file.readAsBytesSync();
    if (bytes.isEmpty) throw NetConfigException('The $what is empty: $path');
    return bytes;
  } on FileSystemException catch (e) {
    throw NetConfigException(
      'The $what could not be read: $path (${e.osError?.message ?? e.message})',
    );
  }
}

/// A PEM certificate as is, or a bare DER certificate (starts with a
/// SEQUENCE tag, as many `.cer` and `.crt` files from Windows tools do)
/// wrapped as PEM.
List<int> _certAsPem(List<int> bytes) {
  final text = latin1.decode(bytes, allowInvalid: true);
  if (text.contains('-----BEGIN') || bytes.first != 0x30) return bytes;
  final b64 = base64Encode(bytes);
  final lines = [
    for (var i = 0; i < b64.length; i += 64)
      b64.substring(i, i + 64 > b64.length ? b64.length : i + 64),
  ];
  return latin1.encode(
    '-----BEGIN CERTIFICATE-----\n${lines.join('\n')}\n'
    '-----END CERTIFICATE-----\n',
  );
}

/// Failed TLS context calls leave their OpenSSL errors queued, and the next
/// successful call on the thread throws them. A call that always fails
/// drains the queue, so a corrected certificate is not rejected once more
/// for its predecessor's mistake.
void _drainTlsErrors() {
  try {
    SecurityContext().useCertificateChainBytes(const <int>[]);
  } catch (_) {}
}

String _tlsReason(Object e) {
  if (e is TlsException) {
    final os = e.osError?.message.trim() ?? '';
    return (os.isEmpty ? e.message : os).replaceAll(RegExp(r'\s+'), ' ');
  }
  return e.toString();
}

void _loadCa(SecurityContext context, String path) {
  final bytes = _certAsPem(_readFile(path, 'CA certificate file'));
  final text = latin1.decode(bytes, allowInvalid: true);
  if (!text.contains('CERTIFICATE-----')) {
    throw NetConfigException(
      'The CA certificate file is not a PEM certificate: $path'
      '${text.contains('PRIVATE KEY') ? ' (it holds a private key)' : ''}',
    );
  }
  try {
    context.setTrustedCertificatesBytes(bytes);
  } on TlsException catch (e) {
    throw NetConfigException(
      'The CA certificate file could not be loaded: $path (${_tlsReason(e)})',
    );
  }
}

void _loadClientCert(SecurityContext context, ClientCertificate cert) {
  final passphrase = cert.passphrase.isEmpty ? null : cert.passphrase;
  final pfx = cert.pfxPath.trim();
  if (pfx.isNotEmpty) {
    final bytes = _readFile(pfx, 'PFX/P12 file');
    try {
      context.useCertificateChainBytes(bytes, password: passphrase);
      context.usePrivateKeyBytes(bytes, password: passphrase);
    } on TlsException catch (e) {
      final reason = _tlsReason(e);
      throw NetConfigException(
        reason.contains('INCORRECT_PASSWORD')
            ? (passphrase == null
                  ? 'The PFX/P12 file needs a passphrase: $pfx'
                  : 'The passphrase for the PFX/P12 file is wrong: $pfx')
            : 'The PFX/P12 file could not be loaded: $pfx ($reason)',
      );
    } on ArgumentError {
      throw NetConfigException('The PFX/P12 file has no private key: $pfx');
    }
    return;
  }

  final certPath = cert.certPath.trim();
  if (certPath.isEmpty) {
    throw NetConfigException(
      'The client certificate for ${cert.host} has no certificate file. '
      'Choose a PEM certificate or a PFX/P12 file.',
    );
  }
  // One PEM file may hold both the certificate and its key.
  final keyPath = cert.keyPath.trim().isEmpty ? certPath : cert.keyPath.trim();
  final certBytes = _certAsPem(_readFile(certPath, 'client certificate file'));
  final certText = latin1.decode(certBytes, allowInvalid: true);
  if (!certText.contains('CERTIFICATE-----')) {
    throw NetConfigException(
      'The client certificate file is not a PEM certificate: $certPath'
      '${certText.contains('PRIVATE KEY') ? ' (it holds a private key; choose '
                'the certificate here and the key as the key file)' : ''}',
    );
  }
  final keyBytes = keyPath == certPath
      ? certBytes
      : _readFile(keyPath, 'private key file');
  final keyText = latin1.decode(keyBytes, allowInvalid: true);
  if (!keyText.contains('PRIVATE KEY-----')) {
    throw NetConfigException(
      keyPath == certPath
          ? 'No private key was given for the client certificate $certPath. '
                'Choose the key file, or use a file that holds both.'
          : 'The private key file is not a PEM private key: $keyPath',
    );
  }
  final encrypted = keyText.contains('ENCRYPTED');
  if (encrypted && passphrase == null) {
    throw NetConfigException(
      'The private key is encrypted; enter its passphrase: $keyPath',
    );
  }
  try {
    context.useCertificateChainBytes(certBytes);
    context.usePrivateKeyBytes(keyBytes, password: passphrase);
  } on TlsException catch (e) {
    final reason = _tlsReason(e);
    throw NetConfigException(
      reason.contains('KEY_VALUES_MISMATCH')
          ? 'The private key does not belong to the certificate '
                '($keyPath and $certPath).'
          : reason.contains('BAD_DECRYPT')
          ? 'The passphrase for the private key is wrong: $keyPath'
          : 'The client certificate could not be loaded: $certPath ($reason)',
    );
  } on ArgumentError {
    throw NetConfigException(
      encrypted
          ? 'The passphrase for the private key is wrong: $keyPath'
          : 'The private key could not be read: $keyPath',
    );
  }
}

final _contexts = <String, SecurityContext>{};

String _fileStamp(String path) {
  if (path.trim().isEmpty) return '';
  try {
    final stat = File(_expandHome(path)).statSync();
    return '$path@${stat.modified.microsecondsSinceEpoch}:${stat.size}';
  } catch (_) {
    return '$path@?';
  }
}

/// The TLS context for [net]'s CA certificate and [cert], or null when the
/// platform defaults apply. Built contexts are cached until a file or the
/// passphrase changes.
///
/// The CA is trusted *in addition to* the system roots. Throws a
/// [NetConfigException] for a missing or unreadable file, a wrong passphrase
/// or a key that does not fit the certificate.
SecurityContext? tlsContextFor(NetworkSettings net, ClientCertificate? cert) {
  final ca = net.caCertPath.trim();
  if (ca.isEmpty && cert == null) return null;
  final key = [
    _fileStamp(ca),
    if (cert != null) ...[
      _fileStamp(cert.pfxPath),
      _fileStamp(cert.certPath),
      _fileStamp(cert.keyPath),
      cert.passphrase,
    ],
  ].join('\u0000');
  final cached = _contexts[key];
  if (cached != null) return cached;

  _drainTlsErrors();
  try {
    final context = SecurityContext(withTrustedRoots: true);
    if (ca.isNotEmpty) _loadCa(context, ca);
    if (cert != null) _loadClientCert(context, cert);
    if (_contexts.length >= 16) _contexts.remove(_contexts.keys.first);
    return _contexts[key] = context;
  } catch (_) {
    _drainTlsErrors();
    rethrow;
  }
}

// ---------------------------------------------------------------------------
// Transports
// ---------------------------------------------------------------------------

/// dart:io client for HTTP/1.1 (and the HTTP/2 fallback), with the proxy,
/// CA certificate and client certificate from [net].
///
/// Throws a [NetConfigException] for a proxy that cannot be used. A CA or
/// client certificate that cannot be loaded only fails https requests, with
/// the reason, so plain http keeps working while the file is being fixed.
HttpClient createIoClient(
  NetworkSettings net, {
  required bool verifySsl,
  ClientCertificate? cert,
}) {
  SecurityContext? context;
  NetConfigException? tlsProblem;
  try {
    context = tlsContextFor(net, cert);
  } on NetConfigException catch (e) {
    tlsProblem = e;
  }
  final client = HttpClient(context: context);
  if (!verifySsl) client.badCertificateCallback = (_, _, _) => true;
  _applyProxy(client, net, tlsProblem: tlsProblem);
  return client;
}

/// A proxy [Uri] for the HTTP/2 adapter. It base64-encodes `userInfo` as is,
/// but [Uri] percent-encodes (and rejects some characters in) user info, so
/// a password like `p@ss` would reach the proxy as `p%40ss`. This carries
/// the raw `user:password` instead; the adapter reads only the host, port
/// and user info.
class _H2ProxyUri implements Uri {
  _H2ProxyUri(this._base, this._userInfo);

  final Uri _base;
  final String _userInfo;

  @override
  String get userInfo => _userInfo;
  @override
  String get scheme => _base.scheme;
  @override
  String get host => _base.host;
  @override
  int get port => _base.port;
  @override
  bool get hasPort => _base.hasPort;
  @override
  bool get hasScheme => _base.hasScheme;
  @override
  bool get hasAuthority => _base.hasAuthority;
  @override
  String get path => _base.path;
  @override
  String toString() => '${_base.scheme}://${_base.authority}';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Applies the same options to an HTTP/2 connection. HTTP/2 connections are
/// made per host, so pass the [url] being connected to (the adapter hands it
/// to `onClientCreate`) for proxy bypass rules to apply; without it the
/// proxy is used for every host.
void configureH2Client(
  ClientSetting config,
  NetworkSettings net, {
  required bool verifySsl,
  ClientCertificate? cert,
  Uri? url,
}) {
  config.context = tlsContextFor(net, cert);
  if (!verifySsl) config.onBadCertificate = (_) => true;
  _validateProxyPort(net);
  final proxy = proxyEndpointFor(
    net,
    url ?? Uri.parse('https://host.invalid/'),
  );
  if (proxy != null) {
    final base = Uri(scheme: 'http', host: proxy.host, port: proxy.port);
    config.proxy = proxy.hasCredentials
        ? _H2ProxyUri(base, '${proxy.user}:${proxy.password}')
        : base;
  }
}

/// A single file holding the system trust store followed by [caPath], for
/// curl: `--cacert` replaces curl's default bundle, so trusting an extra CA
/// *in addition to* the system roots means handing it both. Null when no
/// system bundle can be found (Windows, mostly), in which case the CA file
/// alone is used.
String? _curlBundleWith(String caPath) {
  final candidates = [
    Platform.environment['CURL_CA_BUNDLE'],
    Platform.environment['SSL_CERT_FILE'],
    '/etc/ssl/certs/ca-certificates.crt',
    '/etc/pki/tls/certs/ca-bundle.crt',
    '/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem',
    '/etc/ssl/ca-bundle.pem',
    '/etc/pki/tls/cacert.pem',
    '/etc/ssl/cert.pem',
    '/usr/local/share/certs/ca-root-nss.crt',
  ];
  try {
    for (final c in candidates) {
      if (c == null || c.isEmpty || !File(c).existsSync()) continue;
      final stamp = '${_fileStamp(c)}|${_fileStamp(caPath)}';
      final name = sha1.convert(utf8.encode(stamp)).toString().substring(0, 16);
      final tmp = Directory.systemTemp;
      final out = File('${tmp.path}/apiworkbench-ca-$name.pem');
      if (!out.existsSync()) {
        final extra = _certAsPem(_readFile(caPath, 'CA certificate file'));
        // Write beside it and rename, so a second instance never reads half
        // a file.
        final partial = File('${out.path}.$pid');
        partial.writeAsBytesSync([
          ...File(c).readAsBytesSync(),
          0x0A,
          ...extra,
          0x0A,
        ]);
        partial.renameSync(out.path);
        _dropOldBundles(tmp);
      }
      return out.path;
    }
  } catch (_) {}
  return null;
}

/// Removes bundles written for versions of the CA or system store that were
/// replaced; day-old ones only, since a running curl may still read one.
void _dropOldBundles(Directory dir) {
  final cutoff = DateTime.now().subtract(const Duration(days: 1));
  try {
    for (final f in dir.listSync()) {
      final name = f.uri.pathSegments.last;
      if (f is File &&
          name.startsWith('apiworkbench-ca-') &&
          name.endsWith('.pem') &&
          f.statSync().modified.isBefore(cutoff)) {
        f.deleteSync();
      }
    }
  } catch (_) {}
}

/// [path] as curl's `--cert` expects it: a colon separates the password, so
/// colons in the path are escaped, except a Windows drive letter's.
String _curlCertPath(String path) {
  var p = _expandHome(path);
  if (Platform.isWindows) p = p.replaceAll(r'\', '/');
  final head = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p) ? p.substring(0, 2) : '';
  return head + p.substring(head.length).replaceAll(':', r'\:');
}

/// Extra arguments for the curl HTTP/3 engine: proxy, CA certificate and
/// client certificate for [url].
///
/// Without a proxy the arguments say `--noproxy '*'`, so curl does not pick
/// one up from its own environment against the settings. Credentials are
/// passed as arguments (`--proxy-user`, `--pass`, `--cert file.p12:pass`)
/// and are visible in the process list while the request runs. Unlike the
/// dart:io transports this never throws; curl reports unreadable files.
List<String> curlNetworkArgs(
  NetworkSettings net,
  Uri url, {
  ClientCertificate? cert,
}) {
  final args = <String>[];

  final proxy = proxyEndpointFor(net, url);
  if (proxy == null) {
    args.addAll(['--noproxy', '*']);
  } else {
    // An empty --noproxy stops curl applying NO_PROXY on top of a decision
    // that has already taken it into account.
    args.addAll(['--proxy', 'http://${proxy.authority}', '--noproxy', '']);
    if (proxy.hasCredentials) {
      args.addAll(['--proxy-user', '${proxy.user}:${proxy.password}']);
    }
  }

  final ca = net.caCertPath.trim();
  if (ca.isNotEmpty) {
    args.addAll(['--cacert', _curlBundleWith(ca) ?? _expandHome(ca)]);
    // Schannel cannot check revocation for a private CA and would refuse
    // every certificate it signed.
    if (Platform.isWindows) args.add('--ssl-revoke-best-effort');
  }

  if (cert != null) {
    final pfx = cert.pfxPath.trim();
    if (pfx.isNotEmpty) {
      args.addAll([
        '--cert-type',
        'P12',
        '--cert',
        '${_curlCertPath(pfx)}:${cert.passphrase}',
      ]);
    } else if (cert.certPath.trim().isNotEmpty) {
      args.addAll(['--cert', _curlCertPath(cert.certPath)]);
      if (cert.keyPath.trim().isNotEmpty) {
        args.addAll(['--key', _expandHome(cert.keyPath)]);
      }
      if (cert.passphrase.isNotEmpty) args.addAll(['--pass', cert.passphrase]);
    }
  }
  return args;
}

// ---------------------------------------------------------------------------
// Error messages
// ---------------------------------------------------------------------------

/// A readable message for errors the proxy and certificate settings cause,
/// or null for anything else. [error] is a `DioException`'s `error`.
String? describeNetworkError(Object? error) {
  if (error is NetConfigException) return error.message;
  if (error is TlsException) {
    final reason = _tlsReason(error);
    final lower = reason.toLowerCase();
    final String hint;
    if (lower.contains('certificate_verify_failed') ||
        lower.contains('self signed') ||
        lower.contains('unable to get local issuer') ||
        lower.contains('certificate has expired')) {
      hint =
          'If the server uses a private CA, add that CA certificate under '
          'Settings > Proxy and certificates. For a local test server you '
          'can turn off "Verify TLS certificates" instead.';
    } else if (lower.contains('certificate_required') ||
        lower.contains('handshake_failure') ||
        lower.contains('bad_certificate') ||
        lower.contains('unknown_ca') ||
        lower.contains('alert')) {
      hint =
          'The server may require a client certificate. Add one for this '
          'host under Settings > Proxy and certificates.';
    } else {
      hint = '';
    }
    return 'TLS handshake failed: $reason${hint.isEmpty ? '' : '\n$hint'}';
  }
  if (error is HttpException &&
      error.message.contains('Proxy failed to establish tunnel')) {
    return _tunnelFailure(
      RegExp(r'\((\d{3}[^)]*)\)').firstMatch(error.message)?.group(1),
      error.message,
    );
  }
  // With TLS 1.3 a server that wants a client certificate only says so after
  // the handshake, as a reset; there is no alert to read.
  if (error is HttpException &&
      error.uri?.scheme == 'https' &&
      (error.message.contains('Connection reset by peer') ||
          error.message.contains('Connection closed before full header'))) {
    return 'The https server closed the connection without answering '
        '(${error.message.split(', uri').first}). Servers that require a '
        'client certificate do this when none was sent: add one for this '
        'host under Settings > Proxy and certificates.';
  }
  // dio_http2_adapter's CONNECT failure.
  if (error is SocketException &&
      error.message.startsWith('Proxy cannot be initialized')) {
    return _tunnelFailure(
      RegExp(r'\[HTTP/\S+ (\d{3}[^\]]*)\]').firstMatch(error.message)?.group(1),
      error.message,
    );
  }
  return null;
}

String _tunnelFailure(String? status, String fallback) =>
    status != null && status.startsWith('407')
    ? 'The proxy asked for credentials (407). Check the proxy username and '
          'password under Settings > Proxy and certificates.'
    : 'The proxy would not open a tunnel to the server '
          '(${status ?? fallback}).';
