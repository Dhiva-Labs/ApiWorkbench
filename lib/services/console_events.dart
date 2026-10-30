import '../models/models.dart';

/// One request/response pair on the wire. Redirects and auth retries are
/// separate exchanges ([hop] counts them from 0).
class ExchangeRecord {
  ExchangeRecord({
    required this.id,
    required this.at,
    required this.source,
    required this.tabId,
    required this.hop,
    required this.method,
    required this.url,
    required this.requestHeaders,
    this.requestBody,
    this.requestBodyTruncated = false,
    this.status = 0,
    this.statusMessage = '',
    this.responseHeaders = const {},
    this.responseBody,
    this.responseBodyTruncated = false,
    this.responseSize = 0,
    this.durationMs = 0,
    this.error,
    this.protocol,
  });

  /// Bodies kept per exchange; the rest is dropped to bound memory.
  static const bodyLimit = 256 * 1024;

  final String id;
  final DateTime at;

  /// 'editor', 'runner', 'script', 'oauth', 'cli', ...
  final String source;
  final String tabId;
  final int hop;
  final String method;
  final Uri url;
  final List<MapEntry<String, String>> requestHeaders;
  final List<int>? requestBody;
  final bool requestBodyTruncated;
  final int status; // 0 = no response
  final String statusMessage;
  final Map<String, List<String>> responseHeaders;
  final List<int>? responseBody;
  final bool responseBodyTruncated;
  final int responseSize;
  final int durationMs;
  final String? error;
  final String? protocol;
}

enum ConsoleLevel { log, info, warn, error, debug }

/// A line of script output (`console.log`) or an app notice.
class ConsoleLine {
  ConsoleLine(this.level, this.message, {DateTime? at, this.source = ''})
    : at = at ?? DateTime.now();

  final ConsoleLevel level;
  final String message;
  final DateTime at;

  /// Where it came from, e.g. 'Pre-request: Get user'.
  final String source;
}

/// Summary of a response for places that must not keep the body.
ResponseData responseSummary(ResponseData r) => ResponseData(
  statusCode: r.statusCode,
  statusMessage: r.statusMessage,
  durationMs: r.durationMs,
  error: r.error,
  protocol: r.protocol,
);
