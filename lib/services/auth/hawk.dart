import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../models/models.dart';
import '../request_builder.dart';
import 'auth.dart';
import 'auth_util.dart';

/// Hawk HTTP authentication (the `hawk.1.header` MAC scheme).
abstract final class HawkAuth {
  static const algorithms = ['sha256', 'sha1'];

  static void apply(PreparedRequest p, AuthConfig auth, AuthContext ctx) {
    final id = ctx.param(auth, 'authId');
    final key = ctx.param(auth, 'authKey');
    if (id.isEmpty || key.isEmpty) {
      throw AuthException('Hawk needs an Auth ID and an Auth Key.');
    }
    final algorithm = ctx.param(auth, 'algorithm', 'sha256').toLowerCase();
    final ts = ctx.param(auth, 'timestamp');
    final nonce = ctx.param(auth, 'nonce');
    p.headers.set(
      'Authorization',
      header(
        method: p.method,
        url: p.url,
        id: id,
        key: key,
        algorithm: algorithm,
        ts: ts.isEmpty ? '${ctx.now().millisecondsSinceEpoch ~/ 1000}' : ts,
        nonce: nonce.isEmpty ? randomAlnum(6) : nonce,
        ext: ctx.param(auth, 'extraData'),
        app: ctx.param(auth, 'app'),
        dlg: ctx.param(auth, 'delegation'),
        hash: authFlag(auth, 'includePayloadHash')
            ? payloadHash(
                algorithm,
                p.headers.value('content-type') ?? '',
                p.body ?? const [],
              )
            : null,
      ),
    );
  }

  static Hash _hash(String algorithm) => switch (algorithm.toLowerCase()) {
    'sha1' => sha1,
    'sha256' => sha256,
    _ => throw AuthException('Unsupported Hawk algorithm "$algorithm".'),
  };

  /// The `hash` attribute: the payload hash over the content type without
  /// parameters and the body.
  static String payloadHash(
    String algorithm,
    String contentType,
    List<int> body,
  ) {
    final ct = contentType.split(';').first.trim().toLowerCase();
    return base64.encode(
      _hash(
        algorithm,
      ).convert([...utf8.encode('hawk.1.payload\n$ct\n'), ...body, 0x0a]).bytes,
    );
  }

  /// The normalized request string the MAC covers.
  static String normalized({
    required String method,
    required Uri url,
    required String ts,
    required String nonce,
    String? hash,
    String ext = '',
    String app = '',
    String dlg = '',
  }) {
    final escapedExt = ext.replaceAll(r'\', r'\\').replaceAll('\n', r'\n');
    return [
      'hawk.1.header',
      ts,
      nonce,
      method.toUpperCase(),
      requestTarget(url),
      url.host.toLowerCase(),
      '${effectivePort(url)}',
      hash ?? '',
      escapedExt,
      if (app.isNotEmpty) ...[app, dlg],
      '',
    ].join('\n');
  }

  /// A complete `Authorization: Hawk ...` value.
  static String header({
    required String method,
    required Uri url,
    required String id,
    required String key,
    String algorithm = 'sha256',
    required String ts,
    required String nonce,
    String ext = '',
    String app = '',
    String dlg = '',
    String? hash,
  }) {
    final mac = base64.encode(
      Hmac(_hash(algorithm), utf8.encode(key))
          .convert(
            utf8.encode(
              normalized(
                method: method,
                url: url,
                ts: ts,
                nonce: nonce,
                hash: hash,
                ext: ext,
                app: app,
                dlg: dlg,
              ),
            ),
          )
          .bytes,
    );
    return [
      'Hawk id=${quoted(id)}',
      'ts=${quoted(ts)}',
      'nonce=${quoted(nonce)}',
      if (hash != null) 'hash=${quoted(hash)}',
      if (ext.isNotEmpty) 'ext=${quoted(ext)}',
      'mac=${quoted(mac)}',
      if (app.isNotEmpty) 'app=${quoted(app)}',
      if (app.isNotEmpty && dlg.isNotEmpty) 'dlg=${quoted(dlg)}',
    ].join(', ');
  }
}
