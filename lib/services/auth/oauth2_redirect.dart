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
///
/// Any program or web page on the machine can reach the listener, so it
/// only accepts the browser coming back to it: requests that another web
/// page makes in the background (a foreign `Origin`, a cross-site
/// `Sec-Fetch-Site` on the fragment post, a non-navigation fetch) are
/// refused, and an answer whose `state` is not the one sent is ignored
/// while the listener keeps waiting for the real one.
class LoopbackRedirectListener {
  LoopbackRedirectListener._(
    this._servers,
    this.redirectUri,
    this.usesConfiguredUri,
    this._addressNote, {
    required String state,
    required bool stateIsFixed,
  }) : _state = state,
       stateWarning = stateIsFixed && state.isNotEmpty
           ? 'This auth uses a fixed state value, so it does not protect '
                 'the sign-in from forged answers. Leave State empty to use '
                 'a random one each time.'
           : null {
    for (final s in _servers) {
      s.listen(_handle, onError: (_) {});
    }
  }

  final List<HttpServer> _servers;

  /// The redirect_uri to put in the authorization request.
  final Uri redirectUri;

  /// False when the configured redirect URI could not be served here.
  final bool usesConfiguredUri;

  final String? _addressNote;

  /// The `state` sent in the authorization request; answers carrying
  /// another one are ignored. Empty: no check here.
  final String _state;

  /// Set when the collection configures a fixed `state` value.
  final String? stateWarning;

  /// What the UI should tell the user while waiting: why another address
  /// is used, and [stateWarning]. Null when there is nothing to say.
  String? get note {
    final parts = [?_addressNote, ?stateWarning];
    return parts.isEmpty ? null : parts.join('\n');
  }

  final _done = Completer<Uri>();

  /// Completes with the full redirect URL (the implicit grant's fragment
  /// included) the first time the browser comes back.
  Future<Uri> get result => _done.future;

  static const _fragmentPath = '/__apiworkbench/fragment';

  static bool isLoopback(Uri u) =>
      u.scheme == 'http' &&
      const {'localhost', '127.0.0.1', '::1'}.contains(u.host.toLowerCase());

  /// Starts listening for [configuredRedirect] (the auth's redirect_uri).
  ///
  /// [state] is the value sent in the authorization request; answers with a
  /// different or missing state are ignored. [stateIsFixed] says it comes
  /// from the auth settings rather than being random, which adds
  /// [stateWarning].
  static Future<LoopbackRedirectListener> start(
    String configuredRedirect, {
    String state = '',
    bool stateIsFixed = false,
  }) async {
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
        return LoopbackRedirectListener._(
          servers,
          configured,
          true,
          null,
          state: state,
          stateIsFixed: stateIsFixed,
        );
      } on SocketException {
        return _random(
          configured.path,
          'Port ${configured.port} is in use, so the sign-in listens on '
          'another port.',
          state: state,
          stateIsFixed: stateIsFixed,
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
      state: state,
      stateIsFixed: stateIsFixed,
    );
  }

  static Future<LoopbackRedirectListener> _random(
    String path,
    String note, {
    required String state,
    required bool stateIsFixed,
  }) async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final uri = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: s.port,
      path: path.isEmpty || path == '/' ? '/callback' : path,
    );
    return LoopbackRedirectListener._(
      [s],
      uri,
      false,
      note,
      state: state,
      stateIsFixed: stateIsFixed,
    );
  }

  /// Whether [origin] (an `Origin` header) is this listener itself.
  bool _isOwnOrigin(String origin, HttpRequest req) {
    final o = Uri.tryParse(origin.trim());
    if (o == null || o.scheme != 'http' || !isLoopback(o)) return false;
    final port = req.connectionInfo?.localPort ?? redirectUri.port;
    return o.port == port;
  }

  /// Why [req] is refused before it is looked at, or null to accept it.
  ///
  /// The provider sends the browser back with a top-level navigation, which
  /// is cross-site by nature, so the callback accepts navigations only
  /// (`Sec-Fetch-Mode: navigate` to a document) and no foreign `Origin`.
  /// The fragment post comes from the listener's own page: it must be
  /// same-origin. Clients that send none of these headers (older browsers,
  /// command-line tools) are let through; the state check still applies.
  String? _refusal(HttpRequest req, {required bool fragmentPost}) {
    final h = req.headers;
    final origin = h.value('origin');
    if (origin != null && origin != 'null' && !_isOwnOrigin(origin, req)) {
      return 'foreign origin';
    }
    if (origin == 'null') return 'opaque origin';
    final site = h.value('sec-fetch-site')?.toLowerCase();
    final mode = h.value('sec-fetch-mode')?.toLowerCase();
    final dest = h.value('sec-fetch-dest')?.toLowerCase();
    if (fragmentPost) {
      if (site != null && site != 'same-origin') return 'cross-site post';
      return null;
    }
    if (mode != null && mode != 'navigate') return 'not a navigation';
    if (dest != null && dest != 'document') return 'not a page load';
    return null;
  }

  /// Whether the answer [params] carries the state that was sent.
  bool _stateMatches(Map<String, String> params) =>
      _state.isEmpty || params['state'] == _state;

  static const _ignoredMessage =
      'This sign-in answer does not belong to the sign-in ApiWorkbench '
      'started, so it was ignored. ApiWorkbench is still waiting.';

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final path = req.uri.path;
    final expected = redirectUri.path.isEmpty ? '/' : redirectUri.path;
    try {
      if (req.method == 'POST' && path == _fragmentPath) {
        if (_refusal(req, fragmentPost: true) != null) {
          res.statusCode = HttpStatus.forbidden;
          return;
        }
        final fragment = await utf8.decoder.bind(req).join();
        if (!_stateMatches(_formParams(fragment))) {
          res.statusCode = HttpStatus.conflict;
          return;
        }
        res.statusCode = HttpStatus.noContent;
        _finish(redirectUri.replace(fragment: fragment));
      } else if (req.method == 'GET' && path == expected) {
        if (_refusal(req, fragmentPost: false) != null) {
          res.statusCode = HttpStatus.forbidden;
          return;
        }
        final q = req.uri.queryParameters;
        final answered =
            q.containsKey('code') ||
            q.containsKey('error') ||
            q.containsKey('access_token');
        res.headers.contentType = ContentType.html;
        if (answered && !_stateMatches(q)) {
          res.write(_page(_ignoredMessage));
        } else if (answered) {
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

  /// `a=1&b=2` form pairs, tolerating bad percent-encoding.
  static Map<String, String> _formParams(String s) {
    try {
      return Uri.splitQueryString(s);
    } on FormatException {
      return const {};
    }
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
      'else{fetch("$_fragmentPath",{method:"POST",body:h}).then(function(r){'
      'm.textContent=r.ok?"Signed in. You can close this tab and return to '
      'ApiWorkbench.":"$_ignoredMessage";'
      'history.replaceState(null,"",location.pathname);});}'
      '</script></body>';
}
