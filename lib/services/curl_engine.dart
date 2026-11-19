import 'dart:convert';
import 'dart:io';

import '../models/models.dart';
import 'private_dir.dart';
import 'redirect_policy.dart';

/// HTTP/3 transport for desktop platforms, backed by the system `curl`.
/// Dart has no cross-platform QUIC client yet; curl built with HTTP3
/// (ngtcp2/nghttp3 or quiche) fills that gap on Linux/Windows.
class CurlH3Engine {
  bool? _supported;
  String _curlVersionLine = '';
  final Map<String, Process> _procs = {};

  Future<bool> supported() async {
    if (_supported != null) return _supported!;
    try {
      final r = await Process.run('curl', ['--version']);
      final out = (r.stdout as String? ?? '');
      _curlVersionLine = out.split('\n').first.trim();
      // curl lists enabled features on a "Features:" line; HTTP3 appears
      // only when built against a QUIC library.
      _supported = out.contains('HTTP3');
    } catch (_) {
      _curlVersionLine = 'curl not found on PATH';
      _supported = false;
    }
    return _supported!;
  }

  void cancel(String tabId) => _procs.remove(tabId)?.kill();

  Future<ResponseData> send({
    required Uri uri,
    required String method,
    required List<MapEntry<String, String>> headers,
    List<int>? body,
    required bool verifySsl,
    required int connectTimeoutS,
    required int receiveTimeoutS,
    required String tabId,
    List<CurlOption> network = const [],
  }) async {
    if (!isWebUrl(uri)) {
      return ResponseData(error: 'Only http:// and https:// URLs can be sent.');
    }
    if (!await supported()) {
      return ResponseData(
        error:
            'HTTP/3 on this platform uses the system curl, but yours has '
            'no HTTP3 support ($_curlVersionLine).\n'
            'Install a curl built with HTTP/3 (≥ 8.6 with ngtcp2/nghttp3), '
            'or switch to HTTP/2 in Settings.',
      );
    }

    // A private directory per request for the body and the response,
    // removed afterwards.
    final Directory tmp;
    try {
      tmp = createPrivateDirSync('apiworkbench_h3');
    } on FileSystemException catch (e) {
      return ResponseData(error: 'curl transport failed: ${e.message}');
    }
    final bodyFile = File('${tmp.path}/body');
    final headerFile = File('${tmp.path}/headers');
    final requestFile = File('${tmp.path}/request');
    try {
      final hasBody = body != null && body.isNotEmpty;
      if (hasBody) await requestFile.writeAsBytes(body, flush: true);
      final CurlInvocation run;
      try {
        run = curlInvocation(
          uri: uri,
          method: method,
          headers: headers,
          bodyPath: hasBody ? requestFile.path : null,
          verifySsl: verifySsl,
          connectTimeoutS: connectTimeoutS,
          receiveTimeoutS: receiveTimeoutS,
          bodyOut: bodyFile.path,
          headersOut: headerFile.path,
          network: network,
        );
      } on ArgumentError catch (e) {
        return ResponseData(error: '${e.message}');
      }

      // Process.start with an argument list: nothing is shell-interpreted.
      final proc = await Process.start('curl', run.args);
      _procs[tabId] = proc;
      final outF = proc.stdout.transform(utf8.decoder).join();
      final errF = proc.stderr.transform(utf8.decoder).join();
      try {
        proc.stdin.add(utf8.encode(run.config));
        await proc.stdin.close();
      } catch (_) {
        // curl exited before reading its config; its exit code says why.
      }
      final code = await proc.exitCode;
      _procs.remove(tabId);
      final wOut = await outF;
      final errText = (await errF).trim();

      if (code != 0) {
        return ResponseData(error: _exitMessage(code, errText));
      }

      final parts = wOut.trim().split('|');
      final status = int.tryParse(parts.first) ?? 0;
      final protocol = parts.length > 1 ? parts[1] : null;
      final headerText = await headerFile.exists()
          ? await headerFile.readAsString()
          : '';
      final (respHeaders, statusMessage) = parseCurlHeaders(headerText);
      final bytes = await bodyFile.exists()
          ? await bodyFile.readAsBytes()
          : <int>[];
      return ResponseData(
        statusCode: status,
        statusMessage: statusMessage,
        headers: respHeaders,
        bodyBytes: bytes,
        protocol: protocol,
        finalUrl: uri.toString(),
      );
    } catch (e) {
      return ResponseData(error: 'curl transport failed: $e');
    } finally {
      _procs.remove(tabId);
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }

  String _exitMessage(int code, String stderr) => switch (code) {
    6 => 'Could not resolve host.',
    7 => 'Connection refused — is the server up?',
    28 => 'Request timed out.',
    60 =>
      'TLS certificate could not be verified. For a local dev '
          'server with a self-signed certificate, disable "Verify TLS '
          'certificates" in Settings.',
    1 => 'curl refused the URL: only http:// and https:// are allowed.',
    -9 || -15 => 'Request cancelled.',
    _ => stderr.isNotEmpty ? stderr : 'curl exited with code $code',
  };
}

/// Parses `curl -D` output. Redirects produce several header blocks; the
/// last one belongs to the final response.
(Map<String, List<String>>, String) parseCurlHeaders(String text) {
  final blocks = text
      .replaceAll('\r\n', '\n')
      .split('\n\n')
      .where((b) => b.trim().isNotEmpty)
      .toList();
  if (blocks.isEmpty) return ({}, '');
  final lines = blocks.last.trim().split('\n');
  var statusMessage = '';
  final headers = <String, List<String>>{};
  for (final line in lines) {
    if (line.startsWith('HTTP/')) {
      // e.g. "HTTP/3 200" or "HTTP/1.1 301 Moved Permanently"
      final m = RegExp(r'^HTTP/\S+\s+\d+\s*(.*)$').firstMatch(line.trim());
      statusMessage = m?.group(1) ?? '';
      continue;
    }
    final idx = line.indexOf(':');
    if (idx > 0) {
      final k = line.substring(0, idx).trim();
      final v = line.substring(idx + 1).trim();
      headers.putIfAbsent(k, () => []).add(v);
    }
  }
  return (headers, statusMessage);
}

/// One curl option: `--name value` on a command line, `name = "value"` in
/// a config file. [value] is null for a switch such as `insecure`.
class CurlOption {
  const CurlOption(this.name, [this.value]);

  /// The long option name without dashes, e.g. `proxy-user`.
  final String name;
  final String? value;

  /// The option as command-line arguments.
  List<String> get args => ['--$name', ?value];

  /// The option as a line of a curl config file.
  String get configLine =>
      value == null ? name : '$name = ${curlConfigQuote(value!)}';

  @override
  bool operator ==(Object other) =>
      other is CurlOption && other.name == name && other.value == value;

  @override
  int get hashCode => Object.hash(name, value);

  @override
  String toString() => args.join(' ');
}

/// [value] as a quoted curl config file parameter: in double quotes, with
/// backslash and quote escaped and tab, line feed, carriage return and
/// vertical tab written as their escapes (curl drops a backslash before any
/// other character, so every backslash is doubled).
String curlConfigQuote(String value) {
  final out = StringBuffer('"');
  for (final c in value.split('')) {
    out.write(switch (c) {
      r'\' => r'\\',
      '"' => r'\"',
      '\t' => r'\t',
      '\n' => r'\n',
      '\r' => r'\r',
      '\v' => r'\v',
      _ => c,
    });
  }
  out.write('"');
  return out.toString();
}

/// A curl config file holding [options], one per line.
String curlConfig(Iterable<CurlOption> options) =>
    options.map((o) => '${o.configLine}\n').join();

/// What the HTTP/3 engine runs: [args] go on the command line, [options]
/// are written to curl's standard input as a config file (`--config -`).
class CurlInvocation {
  const CurlInvocation(this.args, this.options);

  /// Fixed switches only, never anything from the request.
  final List<String> args;

  /// Everything else, the URL, headers and any credential included.
  final List<CurlOption> options;

  String get config => curlConfig(options);
}

/// The command line every engine run uses. `-q` must come first so curl
/// skips the user's `.curlrc`; the protocol lists stop curl from fetching
/// anything but http and https. The rest is read from standard input, so
/// headers, proxy and certificate passwords and the URL (which may carry an
/// API key) stay out of the process list.
const curlFixedArgs = [
  '-q',
  '--proto',
  '=http,https',
  '--proto-redir',
  '=http,https',
  '--config',
  '-',
];

/// Builds the curl run for one request without redirects (the HTTP service
/// follows them hop by hop). [network] comes from `curlNetworkOptions`.
///
/// Throws [ArgumentError] for a header with a line break in its name or
/// value, which would otherwise split into extra header lines.
CurlInvocation curlInvocation({
  required Uri uri,
  required String method,
  required List<MapEntry<String, String>> headers,
  String? bodyPath,
  required bool verifySsl,
  required int connectTimeoutS,
  required int receiveTimeoutS,
  required String bodyOut,
  required String headersOut,
  List<CurlOption> network = const [],
}) {
  final o = <CurlOption>[
    const CurlOption('silent'),
    const CurlOption('show-error'),
    // Negotiate h3, fall back to h2/1.1 when unavailable.
    const CurlOption('http3'),
    CurlOption('output', bodyOut),
    CurlOption('dump-header', headersOut),
    const CurlOption('write-out', '%{response_code}|%{http_version}'),
    CurlOption('connect-timeout', '$connectTimeoutS'),
    CurlOption('max-time', '${connectTimeoutS + receiveTimeoutS}'),
  ];
  if (!verifySsl) o.add(const CurlOption('insecure'));
  final m = method.toUpperCase();
  if (m == 'HEAD') {
    o.add(const CurlOption('head'));
  } else if (m != 'GET' || bodyPath != null) {
    // --data-binary alone would turn a GET into a POST.
    o.add(CurlOption('request', m));
  }
  for (final h in headers) {
    if ('${h.key}${h.value}'.contains(RegExp('[\r\n]'))) {
      throw ArgumentError('Header "${h.key}" contains a line break.');
    }
    // `Name;` sends an empty header; `Name:` would remove it.
    o.add(
      CurlOption(
        'header',
        h.value.isEmpty ? '${h.key};' : '${h.key}: ${h.value}',
      ),
    );
  }
  if (bodyPath != null) o.add(CurlOption('data-binary', '@$bodyPath'));
  o.addAll(network);
  o.add(CurlOption('url', uri.toString()));
  return CurlInvocation(curlFixedArgs, o);
}
