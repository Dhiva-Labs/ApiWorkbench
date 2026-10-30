import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Catches an OAuth 2.0 redirect on a loopback address (RFC 8252 §7.3)
/// while the user signs in in the system browser.
///
/// With a `http://localhost:PORT/...` (or 127.0.0.1) redirect URI the
/// listener uses that port, so the URI registered with the provider works
/// as is. Otherwise it picks a free port, and [redirectUri] is the address
/// to send instead ([usesConfiguredUri] is false so the UI can say so).
class LoopbackRedirectListener {
  LoopbackRedirectListener._(
    this._servers,
    this.redirectUri,
    this.usesConfiguredUri,
    this.note,
  ) {
    for (final s in _servers) {
      s.listen(_handle, onError: (_) {});
    }
  }

  final List<HttpServer> _servers;

  /// The redirect_uri to put in the authorization request.
  final Uri redirectUri;

  /// False when the configured redirect URI could not be served here.
  final bool usesConfiguredUri;

  /// Why another address is used, for the UI; null when it isn't.
  final String? note;

  final _done = Completer<Uri>();

  /// Completes with the full redirect URL (the implicit grant's fragment
  /// included) the first time the browser comes back.
  Future<Uri> get result => _done.future;

  static const _fragmentPath = '/__apiworkbench/fragment';

  static bool isLoopback(Uri u) =>
      u.scheme == 'http' &&
      const {'localhost', '127.0.0.1', '::1'}.contains(u.host.toLowerCase());

  /// Starts listening for [configuredRedirect] (the auth's redirect_uri).
  static Future<LoopbackRedirectListener> start(
    String configuredRedirect,
  ) async {
    final configured = Uri.tryParse(configuredRedirect.trim());
    if (configured != null && isLoopback(configured) && configured.hasPort) {
      try {
        final servers = [
          await HttpServer.bind(InternetAddress.loopbackIPv4, configured.port),
        ];
        // Browsers may resolve localhost to ::1 first.
        if (configured.host.toLowerCase() == 'localhost') {
          try {
            servers.add(
              await HttpServer.bind(
                InternetAddress.loopbackIPv6,
                configured.port,
              ),
            );
          } on SocketException {
            // No IPv6 loopback; IPv4 is enough.
          }
        }
        return LoopbackRedirectListener._(servers, configured, true, null);
      } on SocketException {
        return _random(
          configured.path,
          'Port ${configured.port} is in use, so the sign-in listens on '
          'another port.',
        );
      }
    }
    return _random(
      configured != null && isLoopback(configured) ? configured.path : '',
      configured != null && isLoopback(configured)
          ? 'The redirect URI has no port, so the sign-in listens on a '
                'random one.'
          : 'The redirect URI is not a loopback address, so the sign-in '
                'uses a local one instead. Your provider must allow it '
                '(most allow any http://127.0.0.1 port), or paste the '
                'redirected URL below.',
    );
  }

  static Future<LoopbackRedirectListener> _random(
    String path,
    String note,
  ) async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final uri = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: s.port,
      path: path.isEmpty || path == '/' ? '/callback' : path,
    );
    return LoopbackRedirectListener._([s], uri, false, note);
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final path = req.uri.path;
    final expected = redirectUri.path.isEmpty ? '/' : redirectUri.path;
    try {
      if (req.method == 'POST' && path == _fragmentPath) {
        final fragment = await utf8.decoder.bind(req).join();
        res.statusCode = HttpStatus.noContent;
        _finish(redirectUri.replace(fragment: fragment));
      } else if (req.method == 'GET' && path == expected) {
        final q = req.uri.queryParameters;
        final answered =
            q.containsKey('code') ||
            q.containsKey('error') ||
            q.containsKey('access_token');
        res.headers.contentType = ContentType.html;
        if (answered) {
          res.write(
            _page(
              'Signed in. You can close this tab and return to '
              'ApiWorkbench.',
            ),
          );
          _finish(redirectUri.replace(query: req.uri.query));
        } else {
          // The implicit grant puts the token after '#', which browsers
          // never send; this page posts it back.
          res.write(_fragmentPage);
        }
      } else {
        res.statusCode = HttpStatus.notFound;
      }
    } finally {
      await res.close();
    }
  }

  void _finish(Uri u) {
    if (!_done.isCompleted) _done.complete(u);
  }

  /// Stops listening. A pending [result] completes with an error.
  Future<void> close() async {
    if (!_done.isCompleted) {
      // Nobody may be listening to result any more.
      _done.future.ignore();
      _done.completeError(StateError('Sign-in cancelled'));
    }
    for (final s in _servers) {
      await s.close(force: true);
    }
  }

  static String _page(String message) =>
      '<!doctype html><meta charset="utf-8"><title>ApiWorkbench</title>'
      '<body style="font:16px sans-serif;margin:3em;text-align:center">'
      '<p>${const HtmlEscape().convert(message)}</p></body>';

  static const _fragmentPage =
      '<!doctype html><meta charset="utf-8"><title>ApiWorkbench</title>'
      '<body style="font:16px sans-serif;margin:3em;text-align:center">'
      '<p id="m">Finishing sign-in…</p><script>'
      'var h=location.hash.replace(/^#/,"");'
      'var m=document.getElementById("m");'
      'if(!h){m.textContent="No authorization response in this address.";}'
      'else{fetch("$_fragmentPath",{method:"POST",body:h}).then(function(){'
      'm.textContent="Signed in. You can close this tab and return to '
      'ApiWorkbench.";history.replaceState(null,"",location.pathname);});}'
      '</script></body>';
}
