import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_http2_adapter/dio_http2_adapter.dart';
import 'package:native_dio_adapter/native_dio_adapter.dart';

import '../models/models.dart';
import 'auth/auth.dart';
import 'console_events.dart';
import 'cookie_jar.dart';
import 'curl_engine.dart';
import 'net_config.dart';
import 'request_builder.dart';

export 'request_builder.dart' show substituteVars;

class HttpService {
  HttpService() {
    configure(AppSettings());
  }

  AppSettings _settings = AppSettings();
  AppSettings get settings => _settings;

  /// Cookies are sent and stored when set (and the request allows it).
  CookieJar? cookieJar;

  final _exchanges = StreamController<ExchangeRecord>.broadcast();

  /// Every exchange on the wire (redirect hops and auth retries included)
  /// for sends with `record: true`.
  Stream<ExchangeRecord> get exchanges => _exchanges.stream;

  final Map<TransportKey, Dio> _dios = {};

  /// Applies TLS verification, HTTP version, timeouts, proxy and
  /// certificates. Open connections are closed.
  void configure(AppSettings settings) {
    for (final d in _dios.values) {
      d.close(force: true);
    }
    _dios.clear();
    _settings = settings;
  }

  static final bool _platformHasNativeH3 =
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  final CurlH3Engine _curl = CurlH3Engine();

  bool get _useCurlH3 =>
      _settings.httpVersion == HttpVersionPref.v3 && !_platformHasNativeH3;

  Dio _dioFor(TransportKey key) => _dios.putIfAbsent(key, () {
    final net = _settings.network;
    final cert = key.clientCertId == null
        ? null
        : net.clientCerts.where((c) => c.id == key.clientCertId).firstOrNull;
    final dio = Dio(
      BaseOptions(
        followRedirects: false,
        // We want every status code back, never an exception for 4xx/5xx.
        validateStatus: (_) => true,
        responseType: ResponseType.bytes,
        connectTimeout: Duration(seconds: _settings.connectTimeoutS),
        receiveTimeout: Duration(seconds: _settings.receiveTimeoutS),
      ),
    );
    HttpClientAdapter h1() => IOHttpClientAdapter(
      createHttpClient: () =>
          createIoClient(net, verifySsl: key.verifySsl, cert: cert),
    );
    switch (_settings.httpVersion) {
      case HttpVersionPref.v1:
        dio.httpClientAdapter = h1();
      case HttpVersionPref.v2:
        // HTTP/2 via ALPN for https; servers that only speak HTTP/1.1 fall
        // back through the adapter. Plain http:// is routed straight to
        // HTTP/1.1 (h2c prior-knowledge would break normal servers).
        final h2 = Http2Adapter(
          ConnectionManager(
            idleTimeout: const Duration(seconds: 15),
            onClientCreate: (uri, config) => configureH2Client(
              config,
              net,
              verifySsl: key.verifySsl,
              cert: cert,
              url: uri,
            ),
          ),
          fallbackAdapter: h1(),
        );
        dio.httpClientAdapter = _SchemeRoutingAdapter(h2: h2, h1: h1());
      case HttpVersionPref.v3:
        // Cronet (Android) / NSURLSession (iOS, macOS) negotiate HTTP/3
        // themselves and fall back to h2/h1 per server support. Desktop
        // requests go to the curl engine; this adapter covers the rest.
        dio.httpClientAdapter = _platformHasNativeH3 ? NativeAdapter() : h1();
    }
    return dio;
  });

  final Map<String, CancelToken> _inflight = {};

  void cancel(String tabId) {
    _inflight.remove(tabId)?.cancel('Cancelled by user');
    _curl.cancel(tabId);
  }

  void dispose() {
    for (final id in _inflight.keys.toList()) {
      cancel(id);
    }
    for (final d in _dios.values) {
      d.close(force: true);
    }
    _dios.clear();
    _exchanges.close();
  }

  /// Builds [r] with [vars], applies [auth] (default: the request's own) and
  /// sends it, following redirects and auth challenges.
  Future<ResponseData> send(
    RequestModel r,
    Map<String, String> vars, {
    required String tabId,
    AuthConfig? auth,
    void Function()? onAuthUpdated,
    bool record = true,
    String source = 'editor',
  }) async {
    final sw = Stopwatch()..start();
    final PreparedRequest p;
    try {
      p = await buildRequest(r, vars, app: _settings);
    } on RequestBuildException catch (e) {
      return ResponseData(error: e.message);
    }
    final authConfig = auth ?? r.auth;
    final ctx = AuthContext(
      vars: vars,
      request: r,
      onUpdated: onAuthUpdated,
      sendRaw: (raw) => sendPrepared(
        raw,
        tabId: '$tabId-auth',
        record: record,
        source: 'auth',
      ),
    );
    try {
      await applyAuth(p, authConfig, ctx);
    } on AuthException catch (e) {
      return ResponseData(
        error: 'Auth: ${e.message}',
        durationMs: sw.elapsedMilliseconds,
      );
    }
    return sendPrepared(
      p,
      tabId: tabId,
      auth: authConfig,
      authContext: ctx,
      record: record,
      source: source,
      stopwatch: sw,
    );
  }

  /// Sends a built request: adds cookies, follows redirects, and lets
  /// [auth] answer one 401 challenge.
  Future<ResponseData> sendPrepared(
    PreparedRequest p, {
    required String tabId,
    AuthConfig? auth,
    AuthContext? authContext,
    bool record = true,
    String source = 'editor',
    Stopwatch? stopwatch,
  }) async {
    final sw = stopwatch ?? (Stopwatch()..start());
    final token = CancelToken();
    _inflight[tabId] = token;
    final userCookie = p.headers.value('cookie');
    final origin = p.url.origin;
    var hop = p.copy();
    var hopIndex = 0;
    var redirects = 0;
    var challenged = false;
    try {
      while (true) {
        final jar = hop.settings.useCookies ? cookieJar : null;
        if (jar != null) {
          final fromJar = jar.cookieHeaderFor(hop.url);
          final own = hop.url.origin == origin ? userCookie : null;
          final cookie = [?own, ?fromJar].join('; ');
          if (cookie.isEmpty) {
            hop.headers.remove('cookie');
          } else {
            hop.headers.set('Cookie', cookie);
          }
        }

        final res = await _sendOnce(
          hop,
          tabId: tabId,
          token: token,
          hop: hopIndex++,
          record: record,
          source: source,
        );
        if (res.error != null) {
          return _withDuration(res, sw.elapsedMilliseconds);
        }
        final setCookie = _headerValues(res.headers, 'set-cookie');
        if (jar != null && setCookie.isNotEmpty) {
          jar.saveFromResponse(hop.url, setCookie);
        }

        if (res.statusCode == 401 &&
            !challenged &&
            auth != null &&
            authContext != null) {
          challenged = true;
          final retry = await retryAfterChallenge(hop, res, auth, authContext);
          if (retry != null) {
            hop = retry;
            continue;
          }
        }

        final location = _headerValues(res.headers, 'location').firstOrNull;
        const redirectCodes = {301, 302, 303, 307, 308};
        if (!hop.settings.followRedirects ||
            !redirectCodes.contains(res.statusCode) ||
            location == null) {
          return _withDuration(res, sw.elapsedMilliseconds);
        }
        if (++redirects > hop.settings.maxRedirects) {
          return ResponseData(
            error:
                'Stopped after ${hop.settings.maxRedirects} redirects (the '
                'maximum). The server may be redirecting in a loop; raise the '
                'limit in the request\'s Settings tab if it is expected.',
            durationMs: sw.elapsedMilliseconds,
          );
        }
        hop = _redirect(hop, res.statusCode, location);
      }
    } finally {
      if (identical(_inflight[tabId], token)) _inflight.remove(tabId);
    }
  }

  /// The next hop of a redirect, following browsers and Postman: 303 (and
  /// 301/302 for non-GET unless told otherwise) become a bodiless GET;
  /// Authorization is dropped when the origin changes.
  PreparedRequest _redirect(PreparedRequest from, int status, String location) {
    final next = from.copy()..url = from.url.resolve(location);
    final toGet =
        status == 303 ||
        ((status == 301 || status == 302) &&
            !from.settings.followOriginalMethod &&
            from.method != 'GET' &&
            from.method != 'HEAD');
    if (toGet) {
      next
        ..method = from.method == 'HEAD' ? 'HEAD' : 'GET'
        ..body = null;
      next.headers
        ..remove('content-type')
        ..remove('content-length');
    }
    if (next.url.origin != from.url.origin &&
        !from.settings.followAuthorizationHeader) {
      next.headers.remove('authorization');
    }
    next.headers.remove('host');
    if (from.settings.removeRefererOnRedirect) {
      next.headers.remove('referer');
    }
    return next;
  }

  Future<ResponseData> _sendOnce(
    PreparedRequest p, {
    required String tabId,
    required CancelToken token,
    required int hop,
    required bool record,
    required String source,
  }) async {
    final at = DateTime.now();
    final res = await _transport(p, tabId: tabId, token: token);
    if (record && _exchanges.hasListener) {
      const limit = ExchangeRecord.bodyLimit;
      final req = p.body;
      final body = res.bodyBytes;
      _exchanges.add(
        ExchangeRecord(
          id: newId(),
          at: at,
          source: source,
          tabId: tabId,
          hop: hop,
          method: p.method,
          url: p.url,
          requestHeaders: p.headers.toList(),
          requestBody: req == null
              ? null
              : (req.length > limit ? req.sublist(0, limit) : req),
          requestBodyTruncated: (req?.length ?? 0) > limit,
          status: res.statusCode,
          statusMessage: res.statusMessage,
          responseHeaders: res.headers,
          responseBody: body.length > limit ? body.sublist(0, limit) : body,
          responseBodyTruncated: body.length > limit,
          responseSize: body.length,
          durationMs: res.durationMs,
          error: res.error,
          protocol: res.protocol,
        ),
      );
    }
    return res;
  }

  /// One request on the wire, no redirects.
  Future<ResponseData> _transport(
    PreparedRequest p, {
    required String tabId,
    required CancelToken token,
  }) async {
    final sw = Stopwatch()..start();
    final net = _settings.network;
    final cert = clientCertFor(net, p.url);
    final receive =
        p.settings.timeout ?? Duration(seconds: _settings.receiveTimeoutS);
    if (_useCurlH3) {
      final res = await _curl.send(
        uri: p.url,
        method: p.method,
        headers: p.headers.toList(),
        body: p.body,
        verifySsl: p.settings.verifySsl,
        connectTimeoutS: _settings.connectTimeoutS,
        receiveTimeoutS: (receive.inMilliseconds / 1000).ceil(),
        tabId: tabId,
        extraArgs: curlNetworkArgs(net, p.url, cert: cert),
      );
      return _withDuration(res, sw.elapsedMilliseconds);
    }
    final dio = _dioFor(
      TransportKey(verifySsl: p.settings.verifySsl, clientCertId: cert?.id),
    );
    try {
      final resp = await dio.requestUri<List<int>>(
        p.url,
        data: p.body == null ? null : Stream.value(p.body!),
        options: Options(
          method: p.method,
          headers: {
            ...p.headers.toMap(),
            if (p.body != null) Headers.contentLengthHeader: p.body!.length,
          },
          followRedirects: false,
          receiveTimeout: receive,
          // Without this dio adds a JSON Content-Type to bodies sent
          // without one.
          contentType: p.headers.value('content-type'),
        ),
        cancelToken: token,
      );
      final respHeaders = <String, List<String>>{};
      resp.headers.forEach((k, v) => respHeaders[k] = v);
      return ResponseData(
        statusCode: resp.statusCode ?? 0,
        statusMessage: resp.statusMessage ?? '',
        headers: respHeaders,
        bodyBytes: resp.data ?? const [],
        durationMs: sw.elapsedMilliseconds,
        finalUrl: p.url.toString(),
      );
    } on DioException catch (e) {
      final timeoutS = receive.inMilliseconds % 1000 == 0
          ? '${receive.inSeconds}'
          : (receive.inMilliseconds / 1000).toStringAsFixed(1);
      final msg = describeNetworkError(e.error) ?? switch (e.type) {
        DioExceptionType.connectionTimeout =>
          'Connection timed out (${_settings.connectTimeoutS} s). Check the host and your network.',
        DioExceptionType.receiveTimeout =>
          'The server took too long to respond ($timeoutS s).',
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
      return ResponseData(
        error: e.toString(),
        durationMs: sw.elapsedMilliseconds,
      );
    }
  }
}

List<String> _headerValues(Map<String, List<String>> headers, String name) {
  final out = <String>[];
  for (final e in headers.entries) {
    if (e.key.toLowerCase() == name) out.addAll(e.value);
  }
  return out;
}

ResponseData _withDuration(ResponseData r, int ms) => ResponseData(
  statusCode: r.statusCode,
  statusMessage: r.statusMessage,
  headers: r.headers,
  bodyBytes: r.bodyBytes,
  durationMs: ms,
  error: r.error,
  finalUrl: r.finalUrl,
  protocol: r.protocol,
);

/// Routes https to the HTTP/2 adapter (which itself falls back to HTTP/1.1
/// when the server doesn't negotiate h2) and plain http to HTTP/1.1.
class _SchemeRoutingAdapter implements HttpClientAdapter {
  _SchemeRoutingAdapter({required this.h2, required this.h1});

  final HttpClientAdapter h2;
  final HttpClientAdapter h1;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final adapter = options.uri.scheme == 'https' ? h2 : h1;
    return adapter.fetch(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) {
    h2.close(force: force);
    h1.close(force: force);
  }
}
