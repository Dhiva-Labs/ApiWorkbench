import 'dart:io';

import 'package:dio_http2_adapter/dio_http2_adapter.dart';

import '../models/models.dart';

/// What a transport is built for. Requests with the same key share
/// connections.
class TransportKey {
  const TransportKey({required this.verifySsl, this.clientCertId});

  final bool verifySsl;

  /// The [ClientCertificate.id] presented, or null for none.
  final String? clientCertId;

  @override
  bool operator ==(Object other) =>
      other is TransportKey &&
      other.verifySsl == verifySsl &&
      other.clientCertId == clientCertId;

  @override
  int get hashCode => Object.hash(verifySsl, clientCertId);
}

/// The client certificate configured for [url]'s host, if any.
ClientCertificate? clientCertFor(NetworkSettings net, Uri url) {
  for (final c in net.clientCerts) {
    if (!c.enabled || c.host.trim().isEmpty) continue;
    var pattern = c.host.trim().toLowerCase();
    int? port;
    final colon = pattern.lastIndexOf(':');
    if (colon > 0 && int.tryParse(pattern.substring(colon + 1)) != null) {
      port = int.parse(pattern.substring(colon + 1));
      pattern = pattern.substring(0, colon);
    }
    if (port != null && port != url.port) continue;
    final host = url.host.toLowerCase();
    final match = pattern.startsWith('*.')
        ? host.endsWith(pattern.substring(1))
        : host == pattern;
    if (match) return c;
  }
  return null;
}

/// dart:io client for HTTP/1.1 (and the HTTP/2 fallback).
HttpClient createIoClient(
  NetworkSettings net, {
  required bool verifySsl,
  ClientCertificate? cert,
}) {
  final client = HttpClient();
  if (!verifySsl) client.badCertificateCallback = (_, _, _) => true;
  return client;
}

/// Applies the same options to an HTTP/2 connection.
void configureH2Client(
  ClientSetting config,
  NetworkSettings net, {
  required bool verifySsl,
  ClientCertificate? cert,
}) {
  if (!verifySsl) config.onBadCertificate = (_) => true;
}

/// Extra arguments for the curl HTTP/3 engine (proxy, certificates).
List<String> curlNetworkArgs(
  NetworkSettings net,
  Uri url, {
  ClientCertificate? cert,
}) => const [];
