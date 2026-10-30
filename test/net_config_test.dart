// http2 is a transitive dependency (of dio_http2_adapter); the tests use it
// to run a small HTTP/2 server.
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/http_service.dart';
import 'package:api_workbench/services/net_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http2/http2.dart' as h2;

// ---------------------------------------------------------------------------
// Fixtures and helpers
// ---------------------------------------------------------------------------

String fx(String name) => '${Directory.current.path}/test/fixtures/certs/$name';

/// A --cert path as curlNetworkArgs writes it: forward slashes on Windows.
String certArg(String path) =>
    Platform.isWindows ? path.replaceAll(r'\', '/') : path;

NetworkSettings net({
  ProxyMode mode = ProxyMode.none,
  String host = '',
  int port = 8080,
  String user = '',
  String password = '',
  String bypass = '',
  String ca = '',
  List<ClientCertificate>? certs,
}) => NetworkSettings(
  proxyMode: mode,
  proxyHost: host,
  proxyPort: port,
  proxyUser: user,
  proxyPassword: password,
  proxyBypass: bypass,
  caCertPath: ca,
  clientCerts: certs,
);

ClientCertificate pemCert({
  String host = '127.0.0.1',
  String key = 'client.key',
  String passphrase = '',
}) => ClientCertificate(
  host: host,
  certPath: fx('client.pem'),
  keyPath: fx(key),
  passphrase: passphrase,
);

ClientCertificate pfxCert({
  String host = '127.0.0.1',
  String file = 'client.p12',
  String passphrase = 'pfxpass',
}) => ClientCertificate(host: host, pfxPath: fx(file), passphrase: passphrase);

HttpService serviceWith(
  NetworkSettings network, {
  HttpVersionPref version = HttpVersionPref.v1,
  bool verifySsl = true,
}) {
  final svc = HttpService()
    ..configure(
      AppSettings(
        network: network,
        httpVersion: version,
        verifySsl: verifySsl,
        connectTimeoutS: 5,
        receiveTimeoutS: 10,
      ),
    );
  addTearDown(svc.dispose);
  return svc;
}

Future<ResponseData> get(HttpService svc, String url) =>
    svc.send(RequestModel(url: url), {}, tabId: 'net', record: false);

Map<String, dynamic> json(ResponseData r) =>
    jsonDecode(r.bodyText) as Map<String, dynamic>;

SecurityContext serverContext() => SecurityContext()
  ..useCertificateChain(fx('server.pem'))
  ..usePrivateKey(fx('server.key'))
  // The CA that client certificates must chain to.
  ..setTrustedCertificates(fx('ca.pem'));

/// An https server that answers with the client certificate's subject.
Future<HttpServer> httpsServer() async {
  final server = await HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    0,
    serverContext(),
    requestClientCertificate: true,
  );
  addTearDown(() => server.close(force: true));
  server.listen((req) {
    req.response
      ..headers.contentType = ContentType.json
      ..write(
        jsonEncode({
          'proto': 'h1',
          'path': req.uri.path,
          'cert': req.certificate?.subject,
        }),
      );
    req.response.close();
  });
  return server;
}

/// An https server that refuses connections without a client certificate
/// (TLS level) and answers `ok` to the others.
Future<SecureServerSocket> strictHttpsServer() async {
  final server = await SecureServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
    serverContext(),
    requestClientCertificate: true,
    requireClientCertificate: true,
  );
  addTearDown(server.close);
  server.listen((socket) {
    socket.listen((_) {
      socket.write(
        'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok',
      );
      socket.close();
    }, onError: (_) {});
  }, onError: (_) {});
  return server;
}

/// An https server that speaks HTTP/2 only (ALPN `h2`).
Future<SecureServerSocket> h2Server() async {
  final server = await SecureServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
    // ALPN has to be set on the context; `supportedProtocols` alone leaves
    // the protocol unselected.
    serverContext()..setAlpnProtocols(['h2'], true),
    requestClientCertificate: true,
  );
  addTearDown(server.close);
  server.listen((socket) {
    final connection = h2.ServerTransportConnection.viaSocket(socket);
    connection.incomingStreams.listen((stream) {
      stream.incomingMessages.listen((_) {});
      stream.sendHeaders([
        h2.Header.ascii(':status', '200'),
        h2.Header.ascii('content-type', 'application/json'),
      ]);
      stream.sendData(
        utf8.encode(
          jsonEncode({'proto': 'h2', 'cert': socket.peerCertificate?.subject}),
        ),
        endStream: true,
      );
    });
  }, onError: (_) {});
  return server;
}

/// A plain http server that reports the path it was asked for.
Future<HttpServer> httpServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((req) {
    req.response
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'proto': 'h1', 'path': req.uri.path}));
    req.response.close();
  });
  return server;
}

/// A forward proxy on a raw socket (dart:io's HttpServer cannot parse
/// CONNECT): serves absolute-form http requests and CONNECT tunnels,
/// optionally behind Basic authentication. Handles `Connection: close`
/// style exchanges only, which is all the tests need.
class TestProxy {
  TestProxy._(this.server, this.user, this.password);

  final ServerSocket server;
  final String? user;
  final String? password;

  /// `GET http://host:port/path` and `CONNECT host:port` for each request
  /// that was let through.
  final served = <String>[];

  /// Each Proxy-Authorization header received, 407 answers included.
  final authHeaders = <String?>[];

  int get port => server.port;

  static Future<TestProxy> start({String? user, String? password}) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = TestProxy._(server, user, password);
    addTearDown(server.close);
    server.listen(proxy._accept);
    return proxy;
  }

  void _accept(Socket client) {
    final head = <int>[];
    Socket? upstream;
    late StreamSubscription<List<int>> sub;
    sub = client.listen(
      (chunk) async {
        if (upstream != null) {
          upstream!.add(chunk);
          return;
        }
        head.addAll(chunk);
        final end = _headEnd(head);
        if (end < 0) return;
        sub.pause();
        try {
          upstream = await _handle(client, latin1.decode(head.sublist(0, end)));
        } catch (_) {
          client.destroy();
        }
        sub.resume();
      },
      onDone: () => upstream?.close(),
      onError: (_) => client.destroy(),
    );
  }

  static int _headEnd(List<int> b) {
    for (var i = 0; i + 3 < b.length; i++) {
      if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  /// Answers one request; returns the upstream socket of a CONNECT tunnel.
  Future<Socket?> _handle(Socket client, String head) async {
    final lines = head.split('\r\n');
    final request = lines.first.split(' ');
    final headers = {
      for (final l in lines.skip(1))
        if (l.contains(':'))
          l.substring(0, l.indexOf(':')).toLowerCase(): l
              .substring(l.indexOf(':') + 1)
              .trim(),
    };
    final auth = headers['proxy-authorization'];
    authHeaders.add(auth);
    if (user != null &&
        auth != 'Basic ${base64Encode(utf8.encode('$user:$password'))}') {
      client.write(
        'HTTP/1.1 407 Proxy Authentication Required\r\n'
        'Proxy-Authenticate: Basic realm="test"\r\n'
        'Content-Length: 0\r\nConnection: close\r\n\r\n',
      );
      await client.close();
      return null;
    }
    final method = request[0];
    final target = request[1];
    if (method == 'CONNECT') {
      final (host, port) = splitHostPort(target);
      final upstream = await Socket.connect(host, port!);
      served.add('CONNECT $target');
      client.write('HTTP/1.1 200 Connection established\r\n\r\n');
      upstream.listen(client.add, onDone: client.close, onError: (_) {});
      return upstream;
    }
    served.add('$method $target');
    final out = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      final resp = await (await out.openUrl(method, Uri.parse(target))).close();
      final body = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
      client.write(
        'HTTP/1.1 ${resp.statusCode} ${resp.reasonPhrase}\r\n'
        'Content-Type: ${resp.headers.contentType ?? 'text/plain'}\r\n'
        'X-Via-Proxy: 1\r\n'
        'Content-Length: ${body.length}\r\nConnection: close\r\n\r\n',
      );
      client.add(body);
    } finally {
      out.close(force: true);
    }
    await client.close();
    return null;
  }
}

final curlAvailable = () {
  try {
    return Process.runSync('curl', ['--version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}();

/// Runs the system curl with the arguments the HTTP/3 engine would add,
/// minus `--http3` (the machine's curl may not have it).
Future<ProcessResult> runCurl(
  List<String> networkArgs,
  String url, {
  Map<String, String> env = const {},
}) => Process.run(
  'curl',
  ['-sS', '--max-time', '10', ...networkArgs, url],
  environment: {
    for (final v in [
      'http_proxy',
      'HTTP_PROXY',
      'https_proxy',
      'HTTPS_PROXY',
      'all_proxy',
      'ALL_PROXY',
      'no_proxy',
      'NO_PROXY',
    ])
      v: '',
    ...env,
  },
);

void main() {
  // -------------------------------------------------------------------------
  group('proxy decision', () {
    final http = Uri.parse('http://api.example.com/x');
    final https = Uri.parse('https://api.example.com/x');

    test('none never proxies, whatever the environment says', () {
      final n = net(mode: ProxyMode.none, host: 'proxy', port: 3128);
      expect(
        proxyFor(n, http, environment: {'HTTP_PROXY': 'http://p:1'}),
        'DIRECT',
      );
      expect(proxyFor(n, https), 'DIRECT');
    });

    group('system', () {
      final n = net(mode: ProxyMode.system);
      String decide(Uri u, Map<String, String> env) =>
          proxyFor(n, u, environment: env);

      test('picks the variable for the scheme, upper or lower case', () {
        final env = {
          'HTTP_PROXY': 'http://plain.corp:3128',
          'https_proxy': 'http://secure.corp:3129',
        };
        expect(decide(http, env), 'PROXY plain.corp:3128');
        expect(decide(https, env), 'PROXY secure.corp:3129');
        expect(
          decide(https, {'HTTPS_PROXY': 'http://upper.corp:1'}),
          'PROXY upper.corp:1',
        );
        expect(
          decide(http, {'http_proxy': 'http://lower.corp:2'}),
          'PROXY lower.corp:2',
        );
      });

      test('is direct when the variable for the scheme is missing', () {
        expect(decide(https, {'HTTP_PROXY': 'http://p:1'}), 'DIRECT');
        expect(decide(http, {}), 'DIRECT');
        expect(decide(http, {'HTTP_PROXY': '  '}), 'DIRECT');
      });

      test('accepts a bare host:port and defaults the port to 1080', () {
        expect(
          decide(http, {'HTTP_PROXY': 'proxy.corp:8888'}),
          'PROXY proxy.corp:8888',
        );
        expect(
          decide(http, {'HTTP_PROXY': 'http://proxy.corp'}),
          'PROXY proxy.corp:1080',
        );
        expect(
          decide(http, {'HTTP_PROXY': 'http://proxy.corp:3128/'}),
          'PROXY proxy.corp:3128',
        );
      });

      test('NO_PROXY, upper or lower case, skips matching hosts', () {
        final proxied = {'HTTPS_PROXY': 'http://p:1'};
        expect(
          decide(https, {...proxied, 'NO_PROXY': 'example.com'}),
          'DIRECT',
        );
        expect(
          decide(https, {...proxied, 'no_proxy': 'other.org, example.com'}),
          'DIRECT',
        );
        expect(
          decide(https, {...proxied, 'NO_PROXY': '.example.com'}),
          'DIRECT',
        );
        expect(
          decide(https, {...proxied, 'NO_PROXY': 'other.org'}),
          'PROXY p:1',
        );
      });

      test('NO_PROXY understands * and CIDR ranges and ports', () {
        final proxied = {'HTTP_PROXY': 'http://p:1'};
        expect(decide(http, {...proxied, 'NO_PROXY': '*'}), 'DIRECT');
        expect(
          decide(Uri.parse('http://10.1.2.3/'), {
            ...proxied,
            'NO_PROXY': '10.0.0.0/8',
          }),
          'DIRECT',
        );
        expect(
          decide(Uri.parse('http://11.1.2.3/'), {
            ...proxied,
            'NO_PROXY': '10.0.0.0/8',
          }),
          'PROXY p:1',
        );
        expect(
          decide(Uri.parse('http://api.example.com:8080/'), {
            ...proxied,
            'NO_PROXY': 'api.example.com:8080',
          }),
          'DIRECT',
        );
        expect(
          decide(http, {...proxied, 'NO_PROXY': 'api.example.com:8080'}),
          'PROXY p:1',
        );
      });

      test(
        'credentials in the variable are decoded but kept out of the string',
        () {
          final env = {
            'HTTPS_PROXY': 'http://ada:p%40ss%3Aword@proxy.corp:3128',
          };
          expect(decide(https, env), 'PROXY proxy.corp:3128');
          final ep = proxyEndpointFor(n, https, environment: env)!;
          expect(ep.user, 'ada');
          expect(ep.password, 'p@ss:word');
          expect(ep.host, 'proxy.corp');
          expect(ep.port, 3128);
        },
      );

      test('reads the real environment when none is passed', () {
        final expected = HttpClient.findProxyFromEnvironment(
          https,
          environment: Platform.environment,
        );
        final noProxy =
            Platform.environment['no_proxy'] ??
            Platform.environment['NO_PROXY'];
        // Only compare when our extra NO_PROXY handling cannot differ.
        if (noProxy == null || noProxy.isEmpty) {
          expect(
            proxyFor(n, https),
            expected.contains('@')
                ? 'PROXY ${expected.split('@').last}'
                : expected,
          );
        }
      });
    });

    group('custom', () {
      test('routes through the proxy', () {
        final n = net(mode: ProxyMode.custom, host: 'proxy.corp', port: 3128);
        expect(proxyFor(n, http), 'PROXY proxy.corp:3128');
        expect(proxyFor(n, https), 'PROXY proxy.corp:3128');
      });

      test('without a host there is no proxy', () {
        final n = net(mode: ProxyMode.custom, host: '  ');
        expect(proxyFor(n, https), 'DIRECT');
      });

      test('accepts a pasted URL, with its port and credentials', () {
        final n = net(
          mode: ProxyMode.custom,
          host: 'http://ada:s3cret@proxy.corp:9999/',
          port: 1,
        );
        final ep = proxyEndpointFor(n, https)!;
        expect(
          (ep.host, ep.port, ep.user, ep.password),
          ('proxy.corp', 9999, 'ada', 's3cret'),
        );
        // The separate username field wins over the pasted one.
        n.proxyUser = 'grace';
        expect(proxyEndpointFor(n, https)!.user, 'grace');
      });

      test('brackets IPv6 proxy hosts', () {
        final n = net(mode: ProxyMode.custom, host: '::1', port: 3128);
        expect(proxyFor(n, https), 'PROXY [::1]:3128');
        final bracketed = net(mode: ProxyMode.custom, host: '[::1]:3129');
        expect(proxyFor(bracketed, https), 'PROXY [::1]:3129');
      });

      test('skips hosts on the bypass list', () {
        final n = net(
          mode: ProxyMode.custom,
          host: 'proxy.corp',
          bypass: 'localhost, 127.0.0.1, *.internal.test, intranet.corp',
        );
        for (final skipped in [
          'http://localhost:3000/',
          'http://127.0.0.1/',
          'https://api.internal.test/',
          'https://intranet.corp/',
          'https://wiki.intranet.corp/',
        ]) {
          expect(proxyFor(n, Uri.parse(skipped)), 'DIRECT', reason: skipped);
        }
        for (final proxied in [
          'https://internal.test/',
          'https://example.com/',
          'https://corp/',
          'https://notintranet.corp/',
        ]) {
          expect(
            proxyFor(n, Uri.parse(proxied)),
            'PROXY proxy.corp:8080',
            reason: proxied,
          );
        }
      });
    });

    group('bypass list entries', () {
      bool hit(String url, String list) => bypassMatches(Uri.parse(url), list);

      test('exact hosts include their subdomains', () {
        expect(hit('http://example.com', 'example.com'), isTrue);
        expect(hit('http://www.example.com', 'example.com'), isTrue);
        expect(hit('http://badexample.com', 'example.com'), isFalse);
        expect(hit('http://EXAMPLE.com', 'Example.COM'), isTrue);
      });

      test('*.suffix and .suffix match subdomains only', () {
        expect(hit('http://a.example.com', '*.example.com'), isTrue);
        expect(hit('http://a.b.example.com', '.example.com'), isTrue);
        expect(hit('http://example.com', '*.example.com'), isFalse);
        expect(hit('http://example.com', '.example.com'), isFalse);
        expect(hit('http://badexample.com', '*.example.com'), isFalse);
      });

      test('IP addresses, IPv6 in any spelling, and CIDR ranges', () {
        expect(hit('http://127.0.0.1:81/', '127.0.0.1'), isTrue);
        expect(hit('http://127.0.0.2/', '127.0.0.1'), isFalse);
        expect(hit('http://[::1]:8080/', '::1'), isTrue);
        expect(hit('http://[::1]/', '[::1]'), isTrue);
        expect(hit('http://[::1]/', '0:0:0:0:0:0:0:1'), isTrue);
        expect(hit('http://192.168.5.9/', '192.168.0.0/16'), isTrue);
        expect(hit('http://192.169.5.9/', '192.168.0.0/16'), isFalse);
        expect(hit('http://10.0.0.255/', '10.0.0.0/25'), isFalse);
        expect(hit('http://10.0.0.100/', '10.0.0.0/25'), isTrue);
        expect(hit('http://[fd00::5]/', 'fd00::/8'), isTrue);
        expect(hit('http://[fe80::5]/', 'fd00::/8'), isFalse);
        // An address never matches a name.
        expect(hit('http://127.0.0.1/', 'localhost'), isFalse);
      });

      test('ports, wildcards, <local>, * and separators', () {
        expect(hit('http://h:8080/', 'h:8080'), isTrue);
        expect(hit('http://h:8081/', 'h:8080'), isFalse);
        expect(hit('https://h/', 'h:443'), isTrue);
        expect(hit('http://192.168.1.1/', '192.168.*'), isTrue);
        expect(hit('http://build-7.corp/', 'build-*.corp'), isTrue);
        expect(hit('http://other.corp/', 'build-*.corp'), isFalse);
        expect(hit('http://intranet/', '<local>'), isTrue);
        expect(hit('http://a.b/', '<local>'), isFalse);
        expect(hit('http://anything.at.all/', '*'), isTrue);
        expect(hit('http://b/', 'a;b c\nb'), isTrue);
        expect(hit('http://b/', ''), isFalse);
        expect(hit('http://b/', ' , ;'), isFalse);
      });
    });

    group('client certificate selection', () {
      ClientCertificate c(String host, {bool enabled = true}) =>
          ClientCertificate(host: host, enabled: enabled);

      test('matches names, ports and wildcards', () {
        final exact = c('api.example.com');
        final withPort = c('api.example.com:8443');
        final wild = c('*.example.com');
        final n = net(certs: [wild, exact, withPort]);
        Uri u(String s) => Uri.parse(s);
        expect(clientCertFor(n, u('https://api.example.com/')), exact);
        expect(clientCertFor(n, u('https://API.example.com:8443/')), withPort);
        expect(clientCertFor(n, u('https://api.example.com:9443/')), exact);
        expect(clientCertFor(n, u('https://a.b.example.com/')), wild);
        expect(clientCertFor(n, u('https://example.com/')), isNull);
        expect(clientCertFor(n, u('https://other.org/')), isNull);
      });

      test('prefers the most specific pattern, in any order', () {
        final any = c('*');
        final domain = c('*.example.com');
        final sub = c('*.api.example.com');
        final host = c('x.api.example.com');
        final url = Uri.parse('https://x.api.example.com/');
        for (final order in [
          [any, domain, sub, host],
          [host, sub, domain, any],
          [domain, any, host, sub],
        ]) {
          expect(clientCertFor(net(certs: order), url), host);
        }
        expect(clientCertFor(net(certs: [any, domain, sub]), url), sub);
        expect(clientCertFor(net(certs: [any, domain]), url), domain);
        expect(clientCertFor(net(certs: [any]), url), any);
      });

      test(
        'skips disabled and empty entries; understands pasted URLs and IPs',
        () {
          final off = c('api.example.com', enabled: false);
          final empty = c('  ');
          final pasted = c('https://api.example.com:8443/v1');
          final ip = c('[::1]');
          final n = net(certs: [off, empty, pasted, ip]);
          expect(
            clientCertFor(n, Uri.parse('https://api.example.com/')),
            isNull,
          );
          expect(
            clientCertFor(n, Uri.parse('https://api.example.com:8443/')),
            pasted,
          );
          expect(clientCertFor(n, Uri.parse('https://[::1]/')), ip);
          expect(clientCertFor(n, Uri.parse('https://[0:0:0:0:0:0:0:1]/')), ip);
        },
      );
    });
  });

  // -------------------------------------------------------------------------
  group('settings that cannot be used', () {
    Future<String> failure(NetworkSettings n, [ClientCertificate? cert]) async {
      try {
        tlsContextFor(n, cert);
      } on NetConfigException catch (e) {
        return e.message;
      }
      fail('expected a NetConfigException');
    }

    test('a missing CA file names the file', () async {
      final msg = await failure(net(ca: '/nonexistent/ca.pem'));
      expect(msg, contains('CA certificate file was not found'));
      expect(msg, contains('/nonexistent/ca.pem'));
    });

    test('a CA file that is not a certificate', () async {
      expect(
        await failure(net(ca: fx('client.key'))),
        allOf(contains('not a PEM certificate'), contains('private key')),
      );
      expect(
        await failure(net(ca: fx('generate.sh'))),
        contains('not a PEM certificate'),
      );
    });

    test('a bad passphrase on a PFX', () async {
      expect(
        await failure(net(), pfxCert(passphrase: 'nope')),
        contains('passphrase for the PFX/P12 file is wrong'),
      );
      expect(
        await failure(net(), pfxCert(passphrase: '')),
        contains('needs a passphrase'),
      );
      expect(
        await failure(net(), pfxCert(file: 'missing.p12')),
        contains('PFX/P12 file was not found'),
      );
      expect(
        await failure(net(), pfxCert(file: 'client.pem')),
        contains('has no private key'),
      );
    });

    test('PEM certificate and key problems', () async {
      expect(
        await failure(net(), pemCert(key: 'client-enc.key')),
        contains('encrypted; enter its passphrase'),
      );
      expect(
        await failure(net(), pemCert(key: 'client-enc.key', passphrase: 'x')),
        contains('passphrase for the private key is wrong'),
      );
      expect(
        await failure(net(), pemCert(key: 'rogue-client.key')),
        contains('does not belong to the certificate'),
      );
      expect(
        await failure(net(), pemCert(key: 'missing.key')),
        contains('private key file was not found'),
      );
      expect(
        await failure(net(), pemCert(key: 'ca.pem')),
        contains('not a PEM private key'),
      );
      expect(
        await failure(
          net(),
          ClientCertificate(host: 'h', certPath: fx('client.key')),
        ),
        allOf(contains('not a PEM certificate'), contains('private key')),
      );
      expect(
        await failure(
          net(),
          ClientCertificate(host: 'h', certPath: fx('client.pem')),
        ),
        contains('No private key was given'),
      );
      expect(
        await failure(net(), ClientCertificate(host: 'h')),
        contains('has no certificate file'),
      );
    });

    test('a corrected certificate loads after a failed attempt', () async {
      // A wrong passphrase leaves OpenSSL errors queued; building the next
      // context must not trip over them.
      for (var i = 0; i < 3; i++) {
        await failure(net(), pemCert(key: 'client-enc.key', passphrase: 'x'));
        createIoClient(
          net(),
          verifySsl: true,
          cert: pemCert(key: 'client-enc.key', passphrase: 'keypass'),
        ).close(force: true);
        await failure(net(), pfxCert(passphrase: 'wrong'));
        createIoClient(
          net(),
          verifySsl: true,
          cert: pfxCert(),
        ).close(force: true);
      }
    });

    test('all PFX flavours load: modern, legacy, no password', () {
      for (final c in [
        pfxCert(),
        pfxCert(file: 'client-legacy.p12'),
        pfxCert(file: 'client-nopass.p12', passphrase: ''),
      ]) {
        expect(tlsContextFor(net(), c), isNotNull, reason: c.pfxPath);
      }
    });

    test('contexts are cached, and rebuilt when a file changes', () async {
      final dir = await Directory.systemTemp.createTemp('netcfg');
      addTearDown(() => dir.delete(recursive: true));
      final ca = File('${dir.path}/ca.pem')
        ..writeAsBytesSync(File(fx('ca.pem')).readAsBytesSync());
      final n = net(ca: ca.path);
      final first = tlsContextFor(n, null);
      expect(identical(tlsContextFor(n, null), first), isTrue);
      expect(tlsContextFor(net(), null), isNull);
      ca.writeAsBytesSync([
        ...File(fx('ca.pem')).readAsBytesSync(),
        ...File(fx('rogue-ca.pem')).readAsBytesSync(),
      ]);
      expect(identical(tlsContextFor(n, null), first), isFalse);
    });

    test('a DER certificate is accepted as a CA', () async {
      final dir = await Directory.systemTemp.createTemp('netcfg');
      addTearDown(() => dir.delete(recursive: true));
      final der = await Process.run('openssl', [
        'x509',
        '-in',
        fx('ca.pem'),
        '-outform',
        'DER',
      ], stdoutEncoding: null);
      final file = File('${dir.path}/ca.cer')
        ..writeAsBytesSync(der.stdout as List<int>);
      expect(tlsContextFor(net(ca: file.path), null), isNotNull);
    });

    test('one PEM file may hold the certificate and the key', () async {
      final dir = await Directory.systemTemp.createTemp('netcfg');
      addTearDown(() => dir.delete(recursive: true));
      final both = File('${dir.path}/both.pem')
        ..writeAsStringSync(
          File(fx('client.pem')).readAsStringSync() +
              File(fx('client.key')).readAsStringSync(),
        );
      final cert = ClientCertificate(host: '127.0.0.1', certPath: both.path);
      expect(tlsContextFor(net(), cert), isNotNull);
    });

    test('an invalid proxy port is reported when the client is made', () {
      for (final port in [0, 70000]) {
        expect(
          () => createIoClient(
            net(mode: ProxyMode.custom, host: 'proxy', port: port),
            verifySsl: true,
          ),
          throwsA(
            isA<NetConfigException>().having(
              (e) => e.message,
              'message',
              contains('proxy port'),
            ),
          ),
        );
      }
    });
  });

  group('unusable TLS settings and plain http', () {
    test('the client is made, and only https requests fail', () async {
      final target = await httpServer();
      final broken = net(ca: '/nonexistent/ca.pem');
      final client = createIoClient(broken, verifySsl: true);
      addTearDown(() => client.close(force: true));
      final ok = await client.getUrl(
        Uri.parse('http://127.0.0.1:${target.port}/'),
      );
      expect((await ok.close()).statusCode, 200);
      await expectLater(
        client.getUrl(Uri.parse('https://127.0.0.1:1/')),
        throwsA(
          isA<NetConfigException>().having(
            (e) => e.message,
            'message',
            contains('CA certificate file was not found'),
          ),
        ),
      );
    });

    test('through HttpService: http works, https says why not', () async {
      final target = await httpServer();
      final server = await httpsServer();
      final svc = serviceWith(net(ca: '/nonexistent/ca.pem'));
      expect(
        (await get(svc, 'http://127.0.0.1:${target.port}/')).statusCode,
        200,
      );
      final res = await get(svc, 'https://127.0.0.1:${server.port}/');
      expect(res.statusCode, 0);
      expect(res.error, contains('CA certificate file was not found'));
    });

    test('client certificates only apply to https', () {
      final n = net(certs: [pemCert(host: '*')]);
      expect(clientCertFor(n, Uri.parse('https://127.0.0.1/')), isNotNull);
      expect(clientCertFor(n, Uri.parse('wss://127.0.0.1/')), isNotNull);
      expect(clientCertFor(n, Uri.parse('http://127.0.0.1/')), isNull);
      expect(clientCertFor(n, Uri.parse('ws://127.0.0.1/')), isNull);
    });
  });

  // -------------------------------------------------------------------------
  group('custom CA over HTTP/1.1', () {
    test('an unknown CA is rejected, a trusted one passes', () async {
      final server = await httpsServer();
      final url = 'https://127.0.0.1:${server.port}/hello';

      final without = await get(serviceWith(net()), url);
      expect(without.error, isNotNull);
      expect(without.error, contains('TLS handshake failed'));
      expect(without.error, contains('CA certificate'));

      final withCa = await get(serviceWith(net(ca: fx('ca.pem'))), url);
      expect(withCa.error, isNull);
      expect(withCa.statusCode, 200);
      expect(json(withCa)['path'], '/hello');
    });

    test('the wrong CA is still rejected', () async {
      final server = await httpsServer();
      final res = await get(
        serviceWith(net(ca: fx('rogue-ca.pem'))),
        'https://127.0.0.1:${server.port}/',
      );
      expect(res.error, contains('TLS handshake failed'));
    });

    test('turning off verification still works without a CA', () async {
      final server = await httpsServer();
      final res = await get(
        serviceWith(net(), verifySsl: false),
        'https://127.0.0.1:${server.port}/',
      );
      expect(res.statusCode, 200);
    });

    test('a missing CA file becomes the request error, not a crash', () async {
      final server = await httpsServer();
      final res = await get(
        serviceWith(net(ca: '/nonexistent/ca.pem')),
        'https://127.0.0.1:${server.port}/',
      );
      expect(res.statusCode, 0);
      expect(res.error, contains('CA certificate file was not found'));
    });

    test('settings changes take effect after configure()', () async {
      final server = await httpsServer();
      final url = 'https://127.0.0.1:${server.port}/';
      final svc = serviceWith(net());
      expect((await get(svc, url)).error, isNotNull);
      svc.configure(AppSettings(network: net(ca: fx('ca.pem'))));
      expect((await get(svc, url)).statusCode, 200);
    });
  });

  // -------------------------------------------------------------------------
  group('client certificates (mTLS) over HTTP/1.1', () {
    Future<void> expectSubject(
      HttpService svc,
      HttpServer server,
      ClientCertificate cert,
    ) async {
      svc.configure(
        AppSettings(
          network: net(ca: fx('ca.pem'), certs: [cert]),
          connectTimeoutS: 5,
        ),
      );
      final res = await get(svc, 'https://127.0.0.1:${server.port}/who');
      expect(res.error, isNull);
      expect(json(res)['cert'], contains('CN=ApiWorkbench Test Client'));
    }

    test('PEM certificate and key', () async {
      final server = await httpsServer();
      await expectSubject(serviceWith(net()), server, pemCert());
    });

    test('PEM certificate with an encrypted key', () async {
      final server = await httpsServer();
      await expectSubject(
        serviceWith(net()),
        server,
        pemCert(key: 'client-enc.key', passphrase: 'keypass'),
      );
    });

    test('PFX with a passphrase', () async {
      final server = await httpsServer();
      await expectSubject(serviceWith(net()), server, pfxCert());
    });

    test('legacy-algorithm PFX and PFX without a password', () async {
      final server = await httpsServer();
      await expectSubject(
        serviceWith(net()),
        server,
        pfxCert(file: 'client-legacy.p12'),
      );
      await expectSubject(
        serviceWith(net()),
        server,
        pfxCert(file: 'client-nopass.p12', passphrase: ''),
      );
    });

    test('no certificate is sent to hosts that do not match', () async {
      final server = await httpsServer();
      final svc = serviceWith(
        net(
          ca: fx('ca.pem'),
          certs: [
            pemCert(host: 'other.example.com'),
            pemCert(host: '127.0.0.1:${server.port + 1}'),
          ],
        ),
      );
      final res = await get(svc, 'https://127.0.0.1:${server.port}/');
      expect(res.statusCode, 200);
      expect(json(res)['cert'], isNull);
    });

    test('a host:port pattern selects the certificate for that port', () async {
      final server = await httpsServer();
      final svc = serviceWith(
        net(
          ca: fx('ca.pem'),
          certs: [pemCert(host: '127.0.0.1:${server.port}')],
        ),
      );
      final res = await get(svc, 'https://127.0.0.1:${server.port}/');
      expect(json(res)['cert'], contains('ApiWorkbench Test Client'));
    });

    test('a disabled certificate is not sent', () async {
      final server = await httpsServer();
      final cert = pemCert()..enabled = false;
      final svc = serviceWith(net(ca: fx('ca.pem'), certs: [cert]));
      final res = await get(svc, 'https://127.0.0.1:${server.port}/');
      expect(json(res)['cert'], isNull);
    });

    test('a client certificate from an untrusted CA is refused', () async {
      final server = await httpsServer();
      final svc = serviceWith(
        net(
          ca: fx('ca.pem'),
          certs: [
            ClientCertificate(
              host: '127.0.0.1',
              certPath: fx('rogue-client.pem'),
              keyPath: fx('rogue-client.key'),
            ),
          ],
        ),
      );
      final res = await get(svc, 'https://127.0.0.1:${server.port}/');
      expect(res.error, isNotNull);
    });

    test('unusable certificate settings fail only that request', () async {
      final server = await httpsServer();
      final svc = serviceWith(
        net(
          ca: fx('ca.pem'),
          certs: [pfxCert(passphrase: 'wrong')],
        ),
      );
      final res = await get(svc, 'https://127.0.0.1:${server.port}/');
      expect(res.statusCode, 0);
      expect(res.error, contains('passphrase for the PFX/P12 file is wrong'));
    });

    test('a server that requires a certificate says so', () async {
      final server = await strictHttpsServer();
      final url = 'https://127.0.0.1:${server.port}/';
      final without = await get(serviceWith(net(ca: fx('ca.pem'))), url);
      expect(without.statusCode, 0);
      expect(without.error, contains('client certificate'));
      final withCert = await get(
        serviceWith(net(ca: fx('ca.pem'), certs: [pemCert()])),
        url,
      );
      expect(withCert.error, isNull);
      expect(withCert.bodyText, 'ok');
    });

    test('verification off does not drop the client certificate', () async {
      final server = await httpsServer();
      final svc = serviceWith(net(certs: [pemCert()]), verifySsl: false);
      final res = await get(svc, 'https://127.0.0.1:${server.port}/');
      expect(json(res)['cert'], contains('ApiWorkbench Test Client'));
    });
  });

  // -------------------------------------------------------------------------
  group('HTTP/2', () {
    Future<ResponseData> over2(NetworkSettings n, SecureServerSocket server) =>
        get(
          serviceWith(n, version: HttpVersionPref.v2),
          'https://127.0.0.1:${server.port}/',
        );

    test('custom CA: rejected without, trusted with', () async {
      final server = await h2Server();
      final without = await over2(net(), server);
      expect(without.error, isNotNull);
      final withCa = await over2(net(ca: fx('ca.pem')), server);
      expect(withCa.error, isNull);
      expect(json(withCa)['proto'], 'h2');
    });

    test('client certificate, PEM and PFX', () async {
      final server = await h2Server();
      for (final cert in [pemCert(), pfxCert()]) {
        final res = await over2(net(ca: fx('ca.pem'), certs: [cert]), server);
        expect(res.error, isNull);
        expect(json(res)['proto'], 'h2');
        expect(json(res)['cert'], contains('CN=ApiWorkbench Test Client'));
      }
    });

    test('unusable certificate settings are the request error', () async {
      final server = await h2Server();
      final res = await over2(
        net(
          ca: fx('ca.pem'),
          certs: [pfxCert(passphrase: 'wrong')],
        ),
        server,
      );
      expect(res.statusCode, 0);
      expect(res.error, contains('passphrase for the PFX/P12 file is wrong'));
    });
  });

  // -------------------------------------------------------------------------
  group('proxy over HTTP/1.1', () {
    test('plain http goes through a custom proxy', () async {
      final target = await httpServer();
      final proxy = await TestProxy.start();
      final svc = serviceWith(
        net(mode: ProxyMode.custom, host: '127.0.0.1', port: proxy.port),
      );
      final url = 'http://127.0.0.1:${target.port}/via';
      final res = await get(svc, url);
      expect(res.error, isNull);
      expect(res.statusCode, 200);
      expect(json(res)['path'], '/via');
      expect(res.headers['x-via-proxy'], ['1']);
      expect(proxy.served, ['GET $url']);
    });

    test('hosts on the bypass list skip the proxy', () async {
      final target = await httpServer();
      final proxy = await TestProxy.start();
      final url = 'http://127.0.0.1:${target.port}/direct';

      final bypassed = await get(
        serviceWith(
          net(
            mode: ProxyMode.custom,
            host: '127.0.0.1',
            port: proxy.port,
            bypass: 'localhost, 127.0.0.1',
          ),
        ),
        url,
      );
      expect(bypassed.statusCode, 200);
      expect(bypassed.headers['x-via-proxy'], isNull);
      expect(proxy.served, isEmpty);

      // The same request is proxied when the list names other hosts, and when
      // the address only matches a CIDR range that does not include it.
      for (final bypass in ['localhost, 10.0.0.0/8', '*.example.com']) {
        final proxied = await get(
          serviceWith(
            net(
              mode: ProxyMode.custom,
              host: '127.0.0.1',
              port: proxy.port,
              bypass: bypass,
            ),
          ),
          url,
        );
        expect(proxied.headers['x-via-proxy'], ['1'], reason: bypass);
      }
      expect(proxy.served, hasLength(2));

      final cidr = await get(
        serviceWith(
          net(
            mode: ProxyMode.custom,
            host: '127.0.0.1',
            port: proxy.port,
            bypass: '127.0.0.0/8',
          ),
        ),
        url,
      );
      expect(cidr.headers['x-via-proxy'], isNull);
      expect(proxy.served, hasLength(2));
    });

    test('mode none ignores the configured proxy', () async {
      final target = await httpServer();
      final proxy = await TestProxy.start();
      final res = await get(
        serviceWith(net(host: '127.0.0.1', port: proxy.port)),
        'http://127.0.0.1:${target.port}/',
      );
      expect(res.statusCode, 200);
      expect(proxy.served, isEmpty);
    });

    test('Basic credentials answer the proxy', () async {
      final target = await httpServer();
      final proxy = await TestProxy.start(user: 'ada', password: 's3cret');
      final url = 'http://127.0.0.1:${target.port}/';

      final ok = await get(
        serviceWith(
          net(
            mode: ProxyMode.custom,
            host: '127.0.0.1',
            port: proxy.port,
            user: 'ada',
            password: 's3cret',
          ),
        ),
        url,
      );
      expect(ok.statusCode, 200);
      expect(ok.headers['x-via-proxy'], ['1']);
      // Sent up front, not only after a 407.
      expect(proxy.authHeaders.first, startsWith('Basic '));

      final wrong = await get(
        serviceWith(
          net(
            mode: ProxyMode.custom,
            host: '127.0.0.1',
            port: proxy.port,
            user: 'ada',
            password: 'nope',
          ),
        ),
        url,
      );
      expect(wrong.statusCode, 407);

      final missing = await get(
        serviceWith(
          net(mode: ProxyMode.custom, host: '127.0.0.1', port: proxy.port),
        ),
        url,
      );
      expect(missing.statusCode, 407);
    });

    test('passwords with special characters are sent intact', () async {
      final target = await httpServer();
      const password = r'p@ss:w/rd%1&x';
      final proxy = await TestProxy.start(user: 'ada', password: password);
      final res = await get(
        serviceWith(
          net(
            mode: ProxyMode.custom,
            host: '127.0.0.1',
            port: proxy.port,
            user: 'ada',
            password: password,
          ),
        ),
        'http://127.0.0.1:${target.port}/',
      );
      expect(res.statusCode, 200);
    });

    test('credentials HTTP/1.1 cannot carry are refused up front', () async {
      final target = await httpServer();
      final proxy = await TestProxy.start();
      for (final (user, password) in [
        ('ada', 'a;b'),
        ('a:da', 'secret'),
        ('ada', ''),
        ('ada', ' secret'),
        (' ada', 'secret'),
      ]) {
        final n = net(
          mode: ProxyMode.custom,
          host: '127.0.0.1',
          port: proxy.port,
          user: user,
          password: password,
        );
        expect(
          () => createIoClient(n, verifySsl: true),
          throwsA(isA<NetConfigException>()),
          reason: '"$user" / "$password"',
        );
        final res = await get(
          serviceWith(n),
          'http://127.0.0.1:${target.port}/',
        );
        expect(res.statusCode, 0);
        expect(res.error, contains('cannot send'));
      }
      expect(proxy.served, isEmpty);
      expect(proxy.authHeaders, isEmpty);
    });

    test('https tunnels through CONNECT, authenticated', () async {
      final server = await httpsServer();
      final proxy = await TestProxy.start(user: 'ada', password: 's3cret');
      final url = 'https://127.0.0.1:${server.port}/tunnel';
      NetworkSettings via(String password) => net(
        mode: ProxyMode.custom,
        host: '127.0.0.1',
        port: proxy.port,
        user: 'ada',
        password: password,
        ca: fx('ca.pem'),
        certs: [pemCert()],
      );

      final ok = await get(serviceWith(via('s3cret')), url);
      expect(ok.error, isNull);
      expect(json(ok)['path'], '/tunnel');
      // The client certificate goes through the tunnel to the server.
      expect(json(ok)['cert'], contains('ApiWorkbench Test Client'));
      expect(proxy.served, ['CONNECT 127.0.0.1:${server.port}']);

      final bad = await get(serviceWith(via('wrong')), url);
      expect(bad.statusCode, 0);
      expect(bad.error, contains('proxy asked for credentials (407)'));
    });

    test('https through a proxy that has no credentials', () async {
      final server = await httpsServer();
      final proxy = await TestProxy.start();
      final res = await get(
        serviceWith(
          net(
            mode: ProxyMode.custom,
            host: '127.0.0.1',
            port: proxy.port,
            ca: fx('ca.pem'),
          ),
        ),
        'https://127.0.0.1:${server.port}/',
      );
      expect(res.statusCode, 200);
      expect(proxy.served, hasLength(1));
      expect(proxy.authHeaders.single, isNull);
    });

    test('a dead proxy is a connection error', () async {
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = dead.port;
      await dead.close();
      final res = await get(
        serviceWith(net(mode: ProxyMode.custom, host: '127.0.0.1', port: port)),
        'http://127.0.0.1:1/',
      );
      expect(res.statusCode, 0);
      expect(res.error, isNotNull);
    });
  });

  // -------------------------------------------------------------------------
  group('proxy over HTTP/2', () {
    NetworkSettings via(
      TestProxy proxy, {
      String user = '',
      String password = '',
      String bypass = '',
      List<ClientCertificate>? certs,
    }) => net(
      mode: ProxyMode.custom,
      host: '127.0.0.1',
      port: proxy.port,
      user: user,
      password: password,
      bypass: bypass,
      ca: fx('ca.pem'),
      certs: certs,
    );

    test('tunnels through CONNECT', () async {
      final server = await h2Server();
      final proxy = await TestProxy.start();
      final res = await get(
        serviceWith(via(proxy), version: HttpVersionPref.v2),
        'https://127.0.0.1:${server.port}/',
      );
      expect(res.error, isNull);
      expect(json(res)['proto'], 'h2');
      expect(proxy.served, ['CONNECT 127.0.0.1:${server.port}']);
    });

    test('authenticates, special characters included', () async {
      final server = await h2Server();
      const password = r'p@ss:w/rd%1&x;y ';
      final proxy = await TestProxy.start(user: 'ada', password: password);
      final res = await get(
        serviceWith(
          via(proxy, user: 'ada', password: password, certs: [pemCert()]),
          version: HttpVersionPref.v2,
        ),
        'https://127.0.0.1:${server.port}/',
      );
      expect(res.error, isNull);
      expect(json(res)['proto'], 'h2');
      expect(json(res)['cert'], contains('ApiWorkbench Test Client'));
      expect(proxy.served, hasLength(1));
    });

    test('wrong credentials are an error', () async {
      final server = await h2Server();
      final proxy = await TestProxy.start(user: 'ada', password: 's3cret');
      // dio_http2_adapter's proxy failure path also raises a stray async
      // error after the request has failed; keep it out of the test zone.
      final res = await runZonedGuarded(
        () => get(
          serviceWith(
            via(proxy, user: 'ada', password: 'nope'),
            version: HttpVersionPref.v2,
          ),
          'https://127.0.0.1:${server.port}/',
        ),
        (_, _) {},
      );
      expect(res!.statusCode, 0);
      expect(res.error, contains('proxy asked for credentials (407)'));
      expect(proxy.served, isEmpty);
      expect(proxy.authHeaders, hasLength(1));
    });

    test('bypassed hosts connect directly', () async {
      final server = await h2Server();
      final proxy = await TestProxy.start(user: 'ada', password: 'x');
      final res = await get(
        serviceWith(
          via(proxy, bypass: '127.0.0.1'),
          version: HttpVersionPref.v2,
        ),
        'https://127.0.0.1:${server.port}/',
      );
      expect(res.error, isNull);
      expect(proxy.served, isEmpty);
      expect(proxy.authHeaders, isEmpty);
    });

    test('plain http falls to HTTP/1.1 and still uses the proxy', () async {
      final target = await httpServer();
      final proxy = await TestProxy.start();
      final res = await get(
        serviceWith(via(proxy), version: HttpVersionPref.v2),
        'http://127.0.0.1:${target.port}/',
      );
      expect(res.statusCode, 200);
      expect(res.headers['x-via-proxy'], ['1']);
    });
  });

  // -------------------------------------------------------------------------
  group('curl arguments', () {
    final url = Uri.parse('https://api.example.com/x');

    test('no proxy tells curl to ignore its environment', () {
      expect(curlNetworkArgs(net(), url), ['--noproxy', '*']);
    });

    test('a custom proxy with credentials', () {
      final n = net(
        mode: ProxyMode.custom,
        host: 'proxy.corp',
        port: 3128,
        user: 'ada',
        password: 'p@ss:word',
      );
      expect(curlNetworkArgs(n, url), [
        '--proxy',
        'http://proxy.corp:3128',
        '--noproxy',
        '',
        '--proxy-user',
        'ada:p@ss:word',
      ]);
    });

    test('bypassed hosts are told to go direct', () {
      final n = net(
        mode: ProxyMode.custom,
        host: 'proxy.corp',
        bypass: '*.example.com',
      );
      expect(curlNetworkArgs(n, url), ['--noproxy', '*']);
      expect(curlNetworkArgs(n, Uri.parse('https://other.org/')), [
        '--proxy',
        'http://proxy.corp:8080',
        '--noproxy',
        '',
      ]);
    });

    test('IPv6 proxies are bracketed', () {
      final n = net(mode: ProxyMode.custom, host: '::1', port: 3128);
      expect(curlNetworkArgs(n, url).sublist(0, 2), [
        '--proxy',
        'http://[::1]:3128',
      ]);
    });

    test('PEM certificate, key and passphrase', () {
      final args = curlNetworkArgs(
        net(),
        url,
        cert: pemCert(key: 'client-enc.key', passphrase: 'keypass'),
      );
      expect(args.sublist(2), [
        '--cert',
        certArg(fx('client.pem')),
        '--key',
        fx('client-enc.key'),
        '--pass',
        'keypass',
      ]);
    });

    test('a combined PEM needs no --key', () {
      final args = curlNetworkArgs(
        net(),
        url,
        cert: ClientCertificate(host: 'h', certPath: '/tmp/both.pem'),
      );
      expect(args.sublist(2), ['--cert', '/tmp/both.pem']);
    });

    test('PFX goes as --cert file:password with the P12 type', () {
      final args = curlNetworkArgs(net(), url, cert: pfxCert());
      expect(args.sublist(2), [
        '--cert-type',
        'P12',
        '--cert',
        '${certArg(fx('client.p12'))}:pfxpass',
      ]);
    });

    test('colons in the certificate path are escaped', () {
      final args = curlNetworkArgs(
        net(),
        url,
        cert: ClientCertificate(
          host: 'h',
          pfxPath: '/tmp/a:b.p12',
          passphrase: 'x:y',
        ),
      );
      expect(args.last, r'/tmp/a\:b.p12:x:y');
    });

    test('the CA joins the system roots when a system bundle exists', () {
      final args = curlNetworkArgs(net(ca: fx('ca.pem')), url);
      expect(args[2], '--cacert');
      final bundle = File(args[3]);
      final ca = File(fx('ca.pem')).readAsStringSync();
      expect(bundle.existsSync(), isTrue);
      final text = bundle.readAsStringSync();
      expect(text, contains(ca.trim()));
      final hasSystemBundle = [
        '/etc/ssl/certs/ca-certificates.crt',
        '/etc/pki/tls/certs/ca-bundle.crt',
        '/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem',
        '/etc/ssl/ca-bundle.pem',
        '/etc/pki/tls/cacert.pem',
        '/etc/ssl/cert.pem',
        '/usr/local/share/certs/ca-root-nss.crt',
      ].any((p) => File(p).existsSync());
      if (hasSystemBundle) {
        expect(text.length, greaterThan(ca.length + 1000));
        expect(args[3], isNot(fx('ca.pem')));
      }
      // Asking again reuses the file.
      expect(curlNetworkArgs(net(ca: fx('ca.pem')), url)[3], args[3]);
    });

    test('system mode defers to the process environment for curl', () {
      final n = net(mode: ProxyMode.system);
      final args = curlNetworkArgs(n, url);
      final expected = proxyEndpointFor(n, url);
      expect(args.first, expected == null ? '--noproxy' : '--proxy');
    });
  });

  group('curl against local servers', () {
    // Windows' curl uses Schannel, which takes client certificates from the
    // certificate store rather than PEM files, so these runs are Linux and
    // macOS only; the arguments themselves are tested above.
    final skip = !curlAvailable
        ? 'curl is not installed'
        : (Platform.isWindows ? 'Schannel curl' : null);

    test('custom CA, then client certificates in each form', () async {
      final server = await httpsServer();
      final url = Uri.parse('https://127.0.0.1:${server.port}/curl');

      final noCa = await runCurl(curlNetworkArgs(net(), url), '$url');
      expect(noCa.exitCode, isNot(0), reason: 'untrusted CA must fail');

      for (final cert in <ClientCertificate?>[
        null,
        pemCert(),
        pemCert(key: 'client-enc.key', passphrase: 'keypass'),
        pfxCert(),
        pfxCert(file: 'client-nopass.p12', passphrase: ''),
      ]) {
        final n = net(ca: fx('ca.pem'), certs: [?cert]);
        final res = await runCurl(
          curlNetworkArgs(n, url, cert: clientCertFor(n, url)),
          '$url',
        );
        expect(res.exitCode, 0, reason: '${res.stderr} (${cert?.id})');
        final body = jsonDecode(res.stdout as String) as Map<String, dynamic>;
        expect(body['path'], '/curl');
        if (cert == null) {
          expect(body['cert'], isNull);
        } else {
          expect(body['cert'], contains('CN=ApiWorkbench Test Client'));
        }
      }
    }, skip: skip);

    test('a wrong key passphrase fails inside curl, not in our code', () async {
      final server = await httpsServer();
      final url = Uri.parse('https://127.0.0.1:${server.port}/');
      final n = net(
        ca: fx('ca.pem'),
        certs: [pemCert(key: 'client-enc.key', passphrase: 'wrong')],
      );
      final args = curlNetworkArgs(n, url, cert: clientCertFor(n, url));
      final res = await runCurl(args, '$url');
      expect(res.exitCode, isNot(0));
    }, skip: skip);

    test('proxy, credentials and bypass', () async {
      final target = await httpServer();
      final proxy = await TestProxy.start(user: 'ada', password: 'p@ss:word');
      final url = Uri.parse('http://127.0.0.1:${target.port}/p');
      NetworkSettings via({String user = 'ada', String bypass = ''}) => net(
        mode: ProxyMode.custom,
        host: '127.0.0.1',
        port: proxy.port,
        user: user,
        password: 'p@ss:word',
        bypass: bypass,
      );

      final ok = await runCurl(curlNetworkArgs(via(), url), '$url');
      expect(ok.exitCode, 0, reason: '${ok.stderr}');
      expect(ok.stdout, contains('"/p"'));
      expect(proxy.served, ['GET $url']);

      // curl's own NO_PROXY must not undo the decision made here.
      final env = await runCurl(
        curlNetworkArgs(via(), url),
        '$url',
        env: {'NO_PROXY': '127.0.0.1', 'no_proxy': '127.0.0.1'},
      );
      expect(env.exitCode, 0, reason: '${env.stderr}');
      expect(proxy.served, hasLength(2));

      // Bypassed: direct, even when curl's environment names a dead proxy.
      final direct = await runCurl(
        curlNetworkArgs(via(bypass: '127.0.0.1'), url),
        '$url',
        env: {
          'http_proxy': 'http://127.0.0.1:1',
          'HTTP_PROXY': 'http://127.0.0.1:1',
        },
      );
      expect(direct.exitCode, 0, reason: '${direct.stderr}');
      expect(proxy.served, hasLength(2));

      // No credentials: the proxy answers 407, which curl returns as a body.
      final denied = await runCurl([
        '-o',
        '/dev/null',
        '-w',
        '%{http_code}',
        ...curlNetworkArgs(via(user: ''), url),
      ], '$url');
      expect(denied.stdout, '407');
    }, skip: skip);

    test(
      'https through a CONNECT proxy with the CA and a certificate',
      () async {
        final server = await httpsServer();
        final proxy = await TestProxy.start(user: 'ada', password: 's3cret');
        final url = Uri.parse('https://127.0.0.1:${server.port}/t');
        final n = net(
          mode: ProxyMode.custom,
          host: '127.0.0.1',
          port: proxy.port,
          user: 'ada',
          password: 's3cret',
          ca: fx('ca.pem'),
          certs: [pfxCert()],
        );
        final res = await runCurl(
          curlNetworkArgs(n, url, cert: clientCertFor(n, url)),
          '$url',
        );
        expect(res.exitCode, 0, reason: '${res.stderr}');
        expect(res.stdout, contains('ApiWorkbench Test Client'));
        expect(proxy.served, ['CONNECT 127.0.0.1:${server.port}']);
      },
      skip: skip,
    );
  });

  // -------------------------------------------------------------------------
  group('error descriptions', () {
    test('only network setting errors are described', () {
      expect(describeNetworkError(null), isNull);
      expect(describeNetworkError(StateError('x')), isNull);
      expect(describeNetworkError(const SocketException('refused')), isNull);
      expect(describeNetworkError(NetConfigException('Bad file')), 'Bad file');
    });

    test('a failed tunnel names the proxy status', () {
      expect(
        describeNetworkError(
          const HttpException(
            'Proxy failed to establish tunnel (407 Proxy Authentication Required)',
          ),
        ),
        contains('asked for credentials'),
      );
      expect(
        describeNetworkError(
          const HttpException(
            'Proxy failed to establish tunnel (403 Forbidden)',
          ),
        ),
        contains('403 Forbidden'),
      );
    });

    test('a handshake error carries a hint for certificates', () {
      final verify = describeNetworkError(
        const HandshakeException(
          'Handshake error in client',
          OSError('CERTIFICATE_VERIFY_FAILED: self signed certificate'),
        ),
      );
      expect(verify, contains('TLS handshake failed'));
      expect(verify, contains('CA certificate'));
      final required = describeNetworkError(
        const HandshakeException(
          'Handshake error in client',
          OSError('TLSV13_ALERT_CERTIFICATE_REQUIRED'),
        ),
      );
      expect(required, contains('client certificate'));
    });
  });
}
