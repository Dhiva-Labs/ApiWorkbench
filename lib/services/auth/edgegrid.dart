import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../models/models.dart';
import '../request_builder.dart';
import 'auth.dart';
import 'auth_util.dart';

/// Akamai EdgeGrid (EG1-HMAC-SHA256) request signing.
abstract final class EdgeGridAuth {
  /// Bytes of a POST body that the content hash covers (Akamai's default).
  static const maxBody = 131072;

  static void apply(PreparedRequest p, AuthConfig auth, AuthContext ctx) {
    final clientToken = ctx.param(auth, 'clientToken');
    final accessToken = ctx.param(auth, 'accessToken');
    final clientSecret = ctx.param(auth, 'clientSecret');
    if (clientToken.isEmpty || accessToken.isEmpty || clientSecret.isEmpty) {
      throw AuthException(
        'Akamai EdgeGrid needs the client token, access token and client '
        'secret from your .edgerc.',
      );
    }
    final ts = ctx.param(auth, 'timestamp');
    final nonce = ctx.param(auth, 'nonce');
    p.headers.set(
      'Authorization',
      header(
        method: p.method,
        url: p.url,
        headers: p.headers,
        body: p.body,
        clientToken: clientToken,
        accessToken: accessToken,
        clientSecret: clientSecret,
        timestamp: ts.isEmpty ? formatTimestamp(ctx.now()) : ts,
        nonce: nonce.isEmpty ? newId() : nonce,
        headersToSign: ctx
            .param(auth, 'headersToSign')
            .split(RegExp(r'[,;\s]+'))
            .where((h) => h.isNotEmpty)
            .toList(),
      ),
    );
  }

  /// `20140321T19:34:21+0000`.
  static String formatTimestamp(DateTime t) {
    final u = t.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${u.year}${two(u.month)}${two(u.day)}'
        'T${two(u.hour)}:${two(u.minute)}:${two(u.second)}+0000';
  }

  /// The tab-separated string that is signed, without the auth data.
  static String dataToSign({
    required String method,
    required Uri url,
    required HeaderList headers,
    List<int>? body,
    List<String> headersToSign = const [],
    int maxBody = EdgeGridAuth.maxBody,
  }) {
    final canonHeaders = [
      for (final name in headersToSign)
        if (headers.value(name) case final v?)
          '${name.toLowerCase()}:${v.trim().replaceAll(RegExp(r'\s+'), ' ')}',
    ].join('\t');
    final m = method.toUpperCase();
    final content = body ?? const [];
    final contentHash = m == 'POST' && content.isNotEmpty
        ? base64.encode(
            sha256
                .convert(
                  content.length > maxBody
                      ? content.sublist(0, maxBody)
                      : content,
                )
                .bytes,
          )
        : '';
    final host = headers.value('host') ?? url.host;
    return [
      m,
      url.scheme,
      host,
      requestTarget(url),
      canonHeaders,
      contentHash,
      '',
    ].join('\t');
  }

  /// A complete `Authorization: EG1-HMAC-SHA256 ...` value.
  static String header({
    required String method,
    required Uri url,
    required HeaderList headers,
    List<int>? body,
    required String clientToken,
    required String accessToken,
    required String clientSecret,
    required String timestamp,
    required String nonce,
    List<String> headersToSign = const [],
    int maxBody = EdgeGridAuth.maxBody,
  }) {
    final authData =
        'EG1-HMAC-SHA256 client_token=$clientToken;'
        'access_token=$accessToken;timestamp=$timestamp;nonce=$nonce;';
    String mac(String key, String data) => base64.encode(
      Hmac(sha256, utf8.encode(key)).convert(utf8.encode(data)).bytes,
    );
    final signingKey = mac(clientSecret, timestamp);
    final data =
        dataToSign(
          method: method,
          url: url,
          headers: headers,
          body: body,
          headersToSign: headersToSign,
          maxBody: maxBody,
        ) +
        authData;
    return '${authData}signature=${mac(signingKey, data)}';
  }
}
