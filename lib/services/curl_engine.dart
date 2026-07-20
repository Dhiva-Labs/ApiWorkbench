import 'dart:convert';
import 'dart:io';

import '../models/models.dart';

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
    required Map<String, String> headers,
    String? body,
    required bool verifySsl,
    required int connectTimeoutS,
    required int receiveTimeoutS,
    required String tabId,
  }) async {
    if (!await supported()) {
      return ResponseData(
        error: 'HTTP/3 on this platform uses the system curl, but yours has '
            'no HTTP3 support ($_curlVersionLine).\n'
            'Install a curl built with HTTP/3 (≥ 8.6 with ngtcp2/nghttp3), '
            'or switch to HTTP/2 in Settings.',
      );
    }

    final tmp = await Directory.systemTemp.createTemp('apiworkbench_h3');
    final bodyFile = File('${tmp.path}/body');
    final headerFile = File('${tmp.path}/headers');
    try {
      final args = <String>[
        '-sS',
        '--http3', // negotiate h3, fall back to h2/1.1 when unavailable
        '-L', '--max-redirs', '10',
        '-o', bodyFile.path,
        '-D', headerFile.path,
        '-w', r'%{response_code}|%{http_version}',
        '--connect-timeout', '$connectTimeoutS',
        '--max-time', '${connectTimeoutS + receiveTimeoutS}',
      ];
      if (!verifySsl) args.add('-k');
      final m = method.toUpperCase();
      if (m == 'HEAD') {
        args.add('--head');
      } else if (m != 'GET') {
        args.addAll(['-X', m]);
      }
      headers.forEach((k, v) => args.addAll(['-H', '$k: $v']));
      if (body != null && body.isNotEmpty) {
        args.addAll(['--data-binary', body]);
      }
      args.add(uri.toString());

      // Process.start with an argument list: nothing is shell-interpreted.
      final proc = await Process.start('curl', args);
      _procs[tabId] = proc;
      final outF = proc.stdout.transform(utf8.decoder).join();
      final errF = proc.stderr.transform(utf8.decoder).join();
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
      final headerText =
          await headerFile.exists() ? await headerFile.readAsString() : '';
      final (respHeaders, statusMessage) = parseCurlHeaders(headerText);
      final bytes =
          await bodyFile.exists() ? await bodyFile.readAsBytes() : <int>[];
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
        60 => 'TLS certificate could not be verified. For a local dev '
            'server with a self-signed certificate, disable "Verify TLS '
            'certificates" in Settings.',
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
