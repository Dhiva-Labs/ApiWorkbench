import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/curl_engine.dart';
import 'package:api_workbench/services/net_config.dart';
import 'package:api_workbench/services/private_temp.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/temp_dir.dart';

void main() {
  /// Lower-case header name -> value, per request the local server saw.
  final hits = <Map<String, String>>[];
  late HttpServer server;
  late String aBase;

  setUp(() async {
    hits.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    aBase = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final headers = <String, String>{};
      req.headers.forEach((k, v) => headers[k.toLowerCase()] = v.join(', '));
      hits.add(headers);
      await req.drain<void>();
      req.response.write('ok');
      await req.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  test('private temp folders are made for this user only', () {
    final dir = createPrivateTempDir('aw-private-');
    addTearDown(() => dir.deleteSync(recursive: true));
    expect(dir.existsSync(), isTrue);
    expect(dir.parent.path, Directory.systemTemp.path);
    expect(
      dir.path.split(Platform.pathSeparator).last,
      startsWith('aw-private-'),
    );
    if (!Platform.isWindows) {
      expect(dir.statSync().mode & 0x1FF, 0x1C0, reason: 'mode 0700');
    }
    final other = createPrivateTempDir('aw-private-');
    addTearDown(() => other.deleteSync(recursive: true));
    expect(other.path, isNot(dir.path));
  });

  group('curl engine', () {
    final url = Uri.parse('https://api.example.com/x?api_key=Q-SECRET');
    final network = curlNetworkOptions(
      NetworkSettings(
        proxyMode: ProxyMode.custom,
        proxyHost: 'proxy.corp',
        proxyPort: 3128,
        proxyUser: 'ada',
        proxyPassword: 'P-SECRET',
        proxyBypass: '',
      ),
      url,
      cert: ClientCertificate(
        host: 'api.example.com',
        pfxPath: '/certs/me.p12',
        passphrase: 'C-SECRET',
      ),
    );

    CurlInvocation invocation({
      List<MapEntry<String, String>> headers = const [],
      String method = 'GET',
      String? bodyPath,
      List<CurlOption>? net,
      Uri? uri,
    }) => curlInvocation(
      uri: uri ?? url,
      method: method,
      headers: headers,
      bodyPath: bodyPath,
      verifySsl: true,
      connectTimeoutS: 5,
      receiveTimeoutS: 5,
      bodyOut: '/tmp/out/body',
      headersOut: '/tmp/out/headers',
      network: net ?? network,
    );

    test('the command line holds fixed switches only', () {
      final run = invocation(
        method: 'POST',
        bodyPath: '/tmp/out/request',
        headers: const [
          MapEntry('Authorization', 'Bearer H-SECRET'),
          MapEntry('X-API-Key', 'K-SECRET'),
          MapEntry('X-Empty', ''),
        ],
      );
      expect(run.args, curlFixedArgs);
      expect(run.args.first, '-q');
      expect(run.args.join(' '), contains('--proto =http,https'));
      expect(run.args.join(' '), contains('--proto-redir =http,https'));
      expect(run.args.sublist(run.args.length - 2), ['--config', '-']);
      for (final secret in [
        'H-SECRET',
        'K-SECRET',
        'P-SECRET',
        'C-SECRET',
        'Q-SECRET',
      ]) {
        expect(run.args.join(' '), isNot(contains(secret)), reason: secret);
        expect(run.config, contains(secret), reason: secret);
      }
      final lines = run.config.split('\n');
      expect(lines, contains('header = "Authorization: Bearer H-SECRET"'));
      expect(lines, contains('header = "X-Empty;"'));
      expect(lines, contains('request = "POST"'));
      expect(lines, contains('data-binary = "@/tmp/out/request"'));
      expect(lines, contains('proxy-user = "ada:P-SECRET"'));
      expect(lines, contains('cert = "/certs/me.p12:C-SECRET"'));
      expect(lines, contains('url = "$url"'));
      expect(lines, contains('http3'));
    });

    test('config values are quoted the way curl reads them', () {
      expect(curlConfigQuote('plain'), '"plain"');
      expect(
        curlConfigQuote(r'C:\certs\a "b".p12'),
        r'"C:\\certs\\a \"b\".p12"',
      );
      expect(curlConfigQuote('tab\there'), r'"tab\there"');
      expect(const CurlOption('insecure').configLine, 'insecure');
    });

    test('a header with a line break is refused', () {
      expect(
        () => invocation(headers: const [MapEntry('X-A', 'one\r\nX-B: two')]),
        throwsArgumentError,
      );
    });

    final curlAvailable = () {
      try {
        return Process.runSync('curl', ['--version']).exitCode == 0;
      } catch (_) {
        return false;
      }
    }();

    test(
      'the system curl reads the config, skips .curlrc, refuses file:',
      () async {
        final home = await Directory.systemTemp.createTemp('aw_curl_home');
        addTearDown(() => deleteTempDir(home));
        final rc = 'header = "X-From-Curlrc: yes"\n';
        File('${home.path}/.curlrc').writeAsStringSync(rc);
        File('${home.path}/_curlrc').writeAsStringSync(rc);
        final env = {
          'HOME': home.path,
          'CURL_HOME': home.path,
          'XDG_CONFIG_HOME': home.path,
          'APPDATA': home.path,
          'USERPROFILE': home.path,
          for (final v in [
            'http_proxy',
            'HTTP_PROXY',
            'all_proxy',
            'ALL_PROXY',
          ])
            v: '',
        };
        Future<int> run(List<String> args, String config) async {
          final p = await Process.start('curl', args, environment: env);
          final drained = Future.wait([
            p.stdout.drain<void>(),
            p.stderr.drain<void>(),
          ]);
          p.stdin.add(utf8.encode(config));
          await p.stdin.close();
          await drained;
          return p.exitCode;
        }

        final out = await Directory.systemTemp.createTemp('aw_curl_out');
        addTearDown(() => deleteTempDir(out));
        const tricky = r'a "quoted" \back\slash value';
        final inv = curlInvocation(
          uri: Uri.parse('$aBase/echo'),
          method: 'GET',
          headers: const [MapEntry('X-Tricky', tricky)],
          verifySsl: true,
          connectTimeoutS: 5,
          receiveTimeoutS: 5,
          bodyOut: '${out.path}/body',
          headersOut: '${out.path}/headers',
          network: const [CurlOption('noproxy', '*')],
        );
        // This machine's curl may lack HTTP/3.
        final config = curlConfig(inv.options.where((o) => o.name != 'http3'));

        expect(await run(inv.args, config), 0);
        expect(hits.single['x-tricky'], tricky);
        expect(hits.single['x-from-curlrc'], isNull);

        // Without -q the same environment does load the file, so the check
        // above means something.
        hits.clear();
        expect(await run(inv.args.sublist(1), config), 0);
        expect(hits.single['x-from-curlrc'], 'yes');

        final local = File('${out.path}/local.txt')..writeAsStringSync('x');
        final fileRun = await run(
          curlFixedArgs,
          curlConfig([
            const CurlOption('silent'),
            CurlOption('url', Uri.file(local.path).toString()),
          ]),
        );
        expect(fileRun, 1, reason: 'unsupported protocol');
      },
      skip: curlAvailable ? null : 'curl is not installed',
    );
  });
}
