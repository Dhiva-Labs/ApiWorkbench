import 'dart:io';
import 'dart:typed_data';

import 'package:api_workbench/services/http_service.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records which requests reach it.
class _Recorder implements HttpClientAdapter {
  _Recorder(this.name, this.log);

  final String name;
  final List<String> log;
  bool closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    log.add('$name ${options.uri}');
    return ResponseBody.fromString('from $name', 200);
  }

  @override
  void close({bool force = false}) => closed = true;
}

/// The package files and libraries [entry] reaches through import, export
/// and part directives, each with the file that first pulled it in.
Map<String, String> reachable(String entry) {
  final directive = RegExp(
    r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''',
    multiLine: true,
  );
  final lib = Directory('lib').absolute.path;
  final seen = <String, String>{entry: ''};
  final queue = [File(entry).absolute.path];
  final files = {queue.first};
  while (queue.isNotEmpty) {
    final path = queue.removeAt(0);
    for (final m in directive.allMatches(File(path).readAsStringSync())) {
      final uri = m.group(1)!;
      String? local;
      if (uri.startsWith('package:api_workbench/')) {
        local = '$lib/${uri.substring('package:api_workbench/'.length)}';
      } else if (!uri.contains(':')) {
        local = File(path).parent.uri.resolve(uri).toFilePath();
      } else {
        seen.putIfAbsent(uri, () => path);
      }
      if (local != null && files.add(local)) {
        seen[local] = path;
        queue.add(local);
      }
    }
  }
  return seen;
}

void main() {
  group('HTTP/3 through the platform stack', () {
    test('https goes to the native adapter, plain http to HTTP/1.1', () async {
      final log = <String>[];
      HttpClientAdapter Function()? fallbackGiven;
      final native = _Recorder('native', log);
      final plain = <_Recorder>[];
      final adapter = nativeH3Adapter(
        (fallback) {
          fallbackGiven = fallback;
          return native;
        },
        () {
          final r = _Recorder('h1', log);
          plain.add(r);
          return r;
        },
      );
      for (final url in [
        'https://example.com/a',
        'http://example.com/b',
        'HTTPS://Example.com/c',
        'http://10.0.2.2:8080/d',
      ]) {
        await adapter.fetch(RequestOptions(path: url), null, null);
      }
      expect(log, [
        'native https://example.com/a',
        'h1 http://example.com/b',
        'native https://example.com/c',
        'h1 http://10.0.2.2:8080/d',
      ]);

      // The native adapter gets the HTTP/1.1 adapter as its own fallback.
      expect(fallbackGiven, isNotNull);
      expect(fallbackGiven!(), isA<_Recorder>());

      adapter.close();
      expect(native.closed, isTrue);
      expect(plain.first.closed, isTrue);
    });

    test('a plain http request is served over HTTP/1.1', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        req.response.write('plain ${req.protocolVersion}');
        await req.response.close();
      });
      final log = <String>[];
      final dio = Dio()
        ..httpClientAdapter = nativeH3Adapter(
          (_) => _Recorder('native', log),
          IOHttpClientAdapter.new,
        );
      addTearDown(dio.close);
      final res = await dio.get<String>('http://127.0.0.1:${server.port}/');
      expect(res.data, 'plain 1.1');
      expect(log, isEmpty, reason: 'the native adapter is never asked');
    });
  });

  test('the command-line runner never loads Flutter', () {
    // `dart build cli` cannot compile anything that reaches dart:ui, and
    // native_dio_adapter imports Flutter. Only the app registers it.
    final seen = reachable('bin/apiworkbench_cli.dart');
    String chain(String key) {
      final out = <String>[key];
      var at = seen[key];
      while (at != null && at.isNotEmpty) {
        out.add(at.replaceFirst('${Directory.current.path}/', ''));
        at = seen[at];
      }
      return out.join(' <= ');
    }

    for (final banned in [
      'dart:ui',
      'package:native_dio_adapter/',
      'package:flutter/',
      'package:flutter_test/',
    ]) {
      final hit = seen.keys.where((k) => k.startsWith(banned)).firstOrNull;
      expect(hit, isNull, reason: hit == null ? null : chain(hit));
    }
    expect(seen.keys.any((k) => k.endsWith('http_service.dart')), isTrue);
  });
}
