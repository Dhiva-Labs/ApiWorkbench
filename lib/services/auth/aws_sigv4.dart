import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../models/models.dart';
import '../request_builder.dart';
import 'auth.dart';
import 'auth_util.dart';

/// AWS Signature Version 4: the signature goes in the Authorization header
/// or, with `addAuthDataToQuery`, in the query string (a presigned URL).
abstract final class AwsSigV4 {
  /// Headers never signed: the transport or later steps change them.
  static const _unsigned = {
    'authorization',
    'connection',
    'content-length',
    'cookie',
    'expect',
    'user-agent',
    'x-amzn-trace-id',
  };

  /// Lifetime of a presigned URL.
  static const presignSeconds = 86400;

  static void apply(PreparedRequest p, AuthConfig auth, AuthContext ctx) {
    final accessKey = ctx.param(auth, 'accessKey');
    final secretKey = ctx.param(auth, 'secretKey');
    if (accessKey.isEmpty || secretKey.isEmpty) {
      throw AuthException('AWS Signature needs an access key and secret key.');
    }
    sign(
      p,
      accessKey: accessKey,
      secretKey: secretKey,
      sessionToken: ctx.param(auth, 'sessionToken'),
      region: ctx.param(auth, 'region'),
      service: ctx.param(auth, 'service'),
      query: authFlag(auth, 'addAuthDataToQuery'),
      now: ctx.now(),
    );
  }

  /// Signs [p] in place. An empty [service] or [region] is read from an
  /// `*.amazonaws.com` host. An `X-Amz-Date` header already on the request
  /// is used as the signing time.
  static void sign(
    PreparedRequest p, {
    required String accessKey,
    required String secretKey,
    String sessionToken = '',
    String region = '',
    String service = '',
    bool query = false,
    required DateTime now,
  }) {
    final inferred = inferServiceRegion(p.url.host);
    final svc = service.isNotEmpty
        ? service
        : (inferred.service ??
              (throw AuthException(
                'Set the AWS service name (e.g. execute-api, s3); it could '
                'not be read from ${p.url.host}.',
              )));
    final reg = region.isNotEmpty ? region : (inferred.region ?? 'us-east-1');
    final s3 = svc == 's3';

    final existing = query ? null : p.headers.value('x-amz-date');
    final amzDate = existing != null && _amzDate.hasMatch(existing)
        ? existing
        : formatAmzDate(now);
    final date = amzDate.substring(0, 8);
    final scope = '$date/$reg/$svc/aws4_request';

    var payloadHash = p.headers.value('x-amz-content-sha256');
    payloadHash ??= s3 && query
        ? 'UNSIGNED-PAYLOAD'
        : sha256Hex(p.body ?? const []);

    if (!query) {
      if (existing == null) p.headers.set('X-Amz-Date', amzDate);
      if (sessionToken.isNotEmpty) {
        p.headers.set('X-Amz-Security-Token', sessionToken);
      }
      if (s3 && !p.headers.has('x-amz-content-sha256')) {
        p.headers.set('X-Amz-Content-Sha256', payloadHash);
      }
    }

    // Canonical headers: lowercase names, trimmed values with inner runs of
    // spaces collapsed, duplicates joined with commas.
    final canon = <String, List<String>>{};
    if (!p.headers.has('host')) canon['host'] = [hostHeader(p.url)];
    for (final h in p.headers) {
      final name = h.key.toLowerCase();
      if (_unsigned.contains(name)) continue;
      canon
          .putIfAbsent(name, () => [])
          .add(h.value.trim().replaceAll(RegExp(r'\s+'), ' '));
    }
    final names = canon.keys.toList()..sort();
    final signedHeaders = names.join(';');

    if (query) {
      var url = p.url;
      for (final e in {
        'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
        'X-Amz-Credential': '$accessKey/$scope',
        'X-Amz-Date': amzDate,
        'X-Amz-Expires': '$presignSeconds',
        if (sessionToken.isNotEmpty) 'X-Amz-Security-Token': sessionToken,
        'X-Amz-SignedHeaders': signedHeaders,
      }.entries) {
        url = _appendRaw(url, e.key, e.value);
      }
      p.url = url;
    }

    final canonicalRequest = [
      p.method.toUpperCase(),
      canonicalUri(p.url.path, s3: s3),
      canonicalQuery(p.url.query),
      for (final n in names) '$n:${canon[n]!.join(',')}',
      '',
      signedHeaders,
      payloadHash,
    ].join('\n');
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      scope,
      sha256Hex(utf8.encode(canonicalRequest)),
    ].join('\n');

    List<int> mac(List<int> key, String data) =>
        Hmac(sha256, key).convert(utf8.encode(data)).bytes;
    var k = mac(utf8.encode('AWS4$secretKey'), date);
    k = mac(k, reg);
    k = mac(k, svc);
    k = mac(k, 'aws4_request');
    final signature = hexOf(mac(k, stringToSign));

    if (query) {
      p.url = _appendRaw(p.url, 'X-Amz-Signature', signature);
    } else {
      p.headers.set(
        'Authorization',
        'AWS4-HMAC-SHA256 Credential=$accessKey/$scope, '
            'SignedHeaders=$signedHeaders, Signature=$signature',
      );
    }
  }

  static final _amzDate = RegExp(r'^\d{8}T\d{6}Z$');

  /// `20150830T123600Z`.
  static String formatAmzDate(DateTime t) {
    final u = t.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${u.year.toString().padLeft(4, '0')}${two(u.month)}${two(u.day)}'
        'T${two(u.hour)}${two(u.minute)}${two(u.second)}Z';
  }

  /// Every path segment URI-encoded. S3 encodes the decoded path once;
  /// other services normalize the path and encode it as sent (so `%20`
  /// becomes `%2520`), as AWS specifies.
  static String canonicalUri(String path, {required bool s3}) {
    if (path.isEmpty) return '/';
    if (s3) {
      return path.split('/').map((s) => rfc3986(_decodePath(s))).join('/');
    }
    final out = <String>[];
    for (final seg in path.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (out.isNotEmpty) out.removeLast();
        continue;
      }
      out.add(rfc3986(seg));
    }
    final trailing = path.endsWith('/') && out.isNotEmpty ? '/' : '';
    return '/${out.join('/')}$trailing';
  }

  /// Query pairs decoded, RFC 3986-encoded and sorted by name, then value.
  static String canonicalQuery(String query) {
    final pairs = [
      for (final e in formPairs(query))
        MapEntry(rfc3986(e.key), rfc3986(e.value)),
    ];
    pairs.sort((a, b) {
      final c = a.key.compareTo(b.key);
      return c != 0 ? c : a.value.compareTo(b.value);
    });
    return pairs.map((e) => '${e.key}=${e.value}').join('&');
  }

  /// Service and region from an `*.amazonaws.com` host, when they can be
  /// told apart: `dynamodb.eu-west-1.amazonaws.com`,
  /// `bucket.s3.us-west-2.amazonaws.com`, `abc.execute-api.us-east-1...`.
  static ({String? service, String? region}) inferServiceRegion(String host) {
    final m = RegExp(
      r'^(.*?)\.?amazonaws\.com(\.cn)?$',
    ).firstMatch(host.toLowerCase());
    if (m == null) return (service: null, region: null);
    final labels = m.group(1)!.split('.').where((l) => l.isNotEmpty).toList();
    if (labels.isEmpty) return (service: null, region: null);
    final region = RegExp(r'^[a-z]{2}(-gov|-iso[a-z]*)?-[a-z]+-\d+$');
    for (var i = labels.length - 1; i >= 0; i--) {
      if (region.hasMatch(labels[i])) {
        return (
          service: i > 0 ? _service(labels[i - 1]) : null,
          region: labels[i],
        );
      }
      // Legacy dashed S3 hosts: s3-us-west-2.amazonaws.com.
      final dashed = RegExp(r'^s3-(.+)$').firstMatch(labels[i]);
      if (dashed != null && region.hasMatch(dashed.group(1)!)) {
        return (service: 's3', region: dashed.group(1));
      }
    }
    return (service: _service(labels.last), region: null);
  }

  static String _service(String label) {
    final s = label.replaceAll('-fips', '');
    return s.startsWith('s3') ? 's3' : s;
  }

  static String _decodePath(String s) {
    try {
      return Uri.decodeComponent(s);
    } on ArgumentError {
      return s;
    }
  }

  /// Appends `key=value`, both RFC 3986-encoded (AWS rejects `+` for a
  /// space and wants `/` encoded in the credential).
  static Uri _appendRaw(Uri url, String key, String value) {
    final pair = '${rfc3986(key)}=${rfc3986(value)}';
    final q = url.hasQuery && url.query.isNotEmpty
        ? '${url.query}&$pair'
        : pair;
    return url.replace(query: q);
  }
}
