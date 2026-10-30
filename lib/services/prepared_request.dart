import 'dart:convert';
import 'dart:typed_data';

import '../models/models.dart';

/// Ordered, case-preserving header rows with case-insensitive lookups.
/// Duplicate names are allowed (they are sent as separate lines).
class HeaderList extends Iterable<MapEntry<String, String>> {
  HeaderList([Iterable<MapEntry<String, String>>? rows]) : _rows = [...?rows];

  final List<MapEntry<String, String>> _rows;

  @override
  Iterator<MapEntry<String, String>> get iterator => _rows.iterator;

  static bool _same(String a, String b) => a.toLowerCase() == b.toLowerCase();

  bool has(String name) => _rows.any((e) => _same(e.key, name));

  /// First value of [name], or null.
  String? value(String name) {
    for (final e in _rows) {
      if (_same(e.key, name)) return e.value;
    }
    return null;
  }

  List<String> values(String name) => [
    for (final e in _rows)
      if (_same(e.key, name)) e.value,
  ];

  /// Replaces every [name] row with one, kept at the first one's position.
  void set(String name, String value) {
    final i = _rows.indexWhere((e) => _same(e.key, name));
    _rows.removeWhere((e) => _same(e.key, name));
    final row = MapEntry(name, value);
    if (i < 0 || i > _rows.length) {
      _rows.add(row);
    } else {
      _rows.insert(i, row);
    }
  }

  void add(String name, String value) => _rows.add(MapEntry(name, value));

  void remove(String name) => _rows.removeWhere((e) => _same(e.key, name));

  /// One value per name, duplicates joined (`; ` for Cookie, `, ` else).
  Map<String, String> toMap() {
    final out = <String, String>{};
    final names = <String, String>{}; // lower → first spelling
    for (final e in _rows) {
      final lower = e.key.toLowerCase();
      final key = names.putIfAbsent(lower, () => e.key);
      final sep = lower == 'cookie' ? '; ' : ', ';
      out[key] = out.containsKey(key) ? '${out[key]}$sep${e.value}' : e.value;
    }
    return out;
  }

  HeaderList copy() => HeaderList(_rows);
}

/// Transport options for one send: the request's own settings with the
/// app settings filling the gaps.
class ResolvedSettings {
  const ResolvedSettings({
    this.followRedirects = true,
    this.maxRedirects = 10,
    this.verifySsl = true,
    this.encodeUrl = true,
    this.useCookies = true,
    this.timeout,
    this.followOriginalMethod = false,
    this.followAuthorizationHeader = false,
    this.removeRefererOnRedirect = false,
  });

  factory ResolvedSettings.of(RequestSettings r, AppSettings app) =>
      ResolvedSettings(
        followRedirects: r.followRedirects ?? app.followRedirects,
        maxRedirects: r.maxRedirects ?? app.maxRedirects,
        verifySsl: r.verifySsl ?? app.verifySsl,
        encodeUrl: r.encodeUrl,
        useCookies: r.useCookies && app.cookiesEnabled,
        timeout: r.timeoutMs == null
            ? null
            : Duration(milliseconds: r.timeoutMs!),
        followOriginalMethod: r.followOriginalMethod,
        followAuthorizationHeader: r.followAuthorizationHeader,
        removeRefererOnRedirect: r.removeRefererOnRedirect,
      );

  final bool followRedirects;
  final int maxRedirects;
  final bool verifySsl;
  final bool encodeUrl;
  final bool useCookies;

  /// Receive timeout override; null = the app setting.
  final Duration? timeout;
  final bool followOriginalMethod;
  final bool followAuthorizationHeader;
  final bool removeRefererOnRedirect;
}

/// A request ready for the wire: variables substituted, path variables and
/// params in the URL, the body serialized to bytes. Auth signers, the
/// cookie jar and redirects work on this.
class PreparedRequest {
  PreparedRequest({
    required this.method,
    required this.url,
    HeaderList? headers,
    this.body,
    this.settings = const ResolvedSettings(),
  }) : headers = headers ?? HeaderList();

  String method;
  Uri url;
  final HeaderList headers;

  /// Serialized body (multipart included, with its boundary in the
  /// Content-Type header); null = no body.
  Uint8List? body;
  ResolvedSettings settings;

  String get bodyText =>
      body == null ? '' : utf8.decode(body!, allowMalformed: true);

  PreparedRequest copy() => PreparedRequest(
    method: method,
    url: url,
    headers: headers.copy(),
    body: body,
    settings: settings,
  );
}

/// Why a request could not be built; shown to the user as the error.
class RequestBuildException implements Exception {
  RequestBuildException(this.message);
  final String message;

  @override
  String toString() => message;
}
