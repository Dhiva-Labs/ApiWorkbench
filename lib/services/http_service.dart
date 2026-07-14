import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../models/models.dart';

/// Replaces {{variable}} placeholders using the active environment.
String substituteVars(String input, Map<String, String> vars) {
  if (vars.isEmpty || !input.contains('{{')) return input;
  return input.replaceAllMapped(RegExp(r'\{\{([^{}]+)\}\}'), (m) {
    final name = m.group(1)!.trim();
    return vars[name] ?? m.group(0)!;
  });
}

class HttpService {
  HttpService() {
    configure(AppSettings());
  }

  final Dio _dio = Dio(BaseOptions(
    followRedirects: true,
    maxRedirects: 10,
    // We want every status code back, never an exception for 4xx/5xx.
    validateStatus: (_) => true,
    responseType: ResponseType.bytes,
  ));

  AppSettings _settings = AppSettings();

  /// Applies TLS verification and timeout settings to the client.
  void configure(AppSettings settings) {
    _settings = settings;
    _dio.options.connectTimeout = Duration(seconds: settings.connectTimeoutS);
    _dio.options.receiveTimeout = Duration(seconds: settings.receiveTimeoutS);
    _dio.httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
      final client = HttpClient();
      if (!settings.verifySsl) {
        client.badCertificateCallback = (cert, host, port) => true;
      }
      return client;
    });
  }

  final Map<String, CancelToken> _inflight = {};

  void cancel(String tabId) {
    _inflight.remove(tabId)?.cancel('Cancelled by user');
  }

  Future<ResponseData> send(
    RequestModel r,
    Map<String, String> vars, {
    required String tabId,
  }) async {
    final sw = Stopwatch()..start();
    final token = CancelToken();
    _inflight[tabId] = token;
    try {
      var rawUrl = substituteVars(r.url.trim(), vars);
      if (rawUrl.isEmpty) {
        return ResponseData(error: 'Request URL is empty.');
      }
      if (!rawUrl.contains('://')) rawUrl = 'https://$rawUrl';

      Uri uri;
      try {
        uri = Uri.parse(rawUrl);
      } catch (e) {
        return ResponseData(error: 'Invalid URL: $e');
      }

      // Merge query params already in the URL with enabled rows from the
      // Params tab (rows win on duplicate keys are appended, like Postman).
      final qp = <String, List<String>>{};
      uri.queryParametersAll.forEach((k, v) => qp[k] = List.of(v));
      for (final p in r.params.where((p) => p.enabled && p.key.isNotEmpty)) {
        final k = substituteVars(p.key, vars);
        final v = substituteVars(p.value, vars);
        qp.putIfAbsent(k, () => []).add(v);
      }
      uri = uri.replace(queryParameters: qp.isEmpty ? null : qp);

      final headers = <String, dynamic>{};
      for (final h in r.headers.where((h) => h.enabled && h.key.isNotEmpty)) {
        headers[substituteVars(h.key, vars)] = substituteVars(h.value, vars);
      }

      switch (r.authType) {
        case AuthType.bearer:
          headers['Authorization'] =
              'Bearer ${substituteVars(r.bearerToken, vars)}';
        case AuthType.basic:
          final cred = base64Encode(utf8.encode(
              '${substituteVars(r.basicUser, vars)}:${substituteVars(r.basicPassword, vars)}'));
          headers['Authorization'] = 'Basic $cred';
        case AuthType.apiKey:
          final k = substituteVars(r.apiKeyName, vars);
          final v = substituteVars(r.apiKeyValue, vars);
          if (k.isNotEmpty) {
            if (r.apiKeyInHeader) {
              headers[k] = v;
            } else {
              final qp2 = Map<String, List<String>>.of(uri.queryParametersAll);
              qp2.putIfAbsent(k, () => []).add(v);
              uri = uri.replace(queryParameters: qp2);
            }
          }
        case AuthType.none:
          break;
      }

      Object? data;
      final hasBody = r.bodyType != BodyType.none &&
          !{'GET', 'HEAD'}.contains(r.method.toUpperCase());
      if (hasBody) {
        final ct = r.bodyType.contentType;
        final hasCt =
            headers.keys.any((k) => k.toLowerCase() == 'content-type');
        if (ct != null && !hasCt) headers['Content-Type'] = ct;
        if (r.bodyType == BodyType.formUrlEncoded) {
          data = r.formFields
              .where((f) => f.enabled && f.key.isNotEmpty)
              .map((f) =>
                  '${Uri.encodeQueryComponent(substituteVars(f.key, vars))}=${Uri.encodeQueryComponent(substituteVars(f.value, vars))}')
              .join('&');
        } else if (r.bodyType == BodyType.graphql) {
          Object? gqlVars;
          final rawVars = substituteVars(r.graphqlVariables, vars).trim();
          if (rawVars.isNotEmpty) {
            try {
              gqlVars = jsonDecode(rawVars);
            } catch (e) {
              return ResponseData(
                  error: 'GraphQL variables are not valid JSON: $e');
            }
          }
          data = jsonEncode({
            'query': substituteVars(r.body, vars),
            'variables': ?gqlVars,
          });
        } else {
          data = substituteVars(r.body, vars);
        }
      }

      final resp = await _dio.requestUri(
        uri,
        data: data,
        options: Options(method: r.method, headers: headers),
        cancelToken: token,
      );
      sw.stop();

      final respHeaders = <String, List<String>>{};
      resp.headers.forEach((k, v) => respHeaders[k] = v);
      return ResponseData(
        statusCode: resp.statusCode ?? 0,
        statusMessage: resp.statusMessage ?? '',
        headers: respHeaders,
        bodyBytes: (resp.data as List<int>?) ?? const [],
        durationMs: sw.elapsedMilliseconds,
        finalUrl: resp.realUri.toString(),
      );
    } on DioException catch (e) {
      sw.stop();
      final msg = switch (e.type) {
        DioExceptionType.connectionTimeout =>
          'Connection timed out (${_settings.connectTimeoutS} s). Check the host and your network.',
        DioExceptionType.receiveTimeout =>
          'The server took too long to respond (${_settings.receiveTimeoutS} s).',
        DioExceptionType.cancel => 'Request cancelled.',
        DioExceptionType.badCertificate =>
          'TLS certificate could not be verified: ${e.message}\n'
              'For a local dev server with a self-signed certificate, disable '
              '"Verify TLS certificates" in Settings.',
        DioExceptionType.connectionError =>
          'Connection failed: ${e.message ?? 'host unreachable'}',
        _ => e.message ?? e.toString(),
      };
      return ResponseData(error: msg, durationMs: sw.elapsedMilliseconds);
    } catch (e) {
      sw.stop();
      return ResponseData(
          error: e.toString(), durationMs: sw.elapsedMilliseconds);
    } finally {
      _inflight.remove(tabId);
    }
  }
}
