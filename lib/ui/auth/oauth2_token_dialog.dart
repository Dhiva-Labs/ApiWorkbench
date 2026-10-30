import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/models.dart';
import '../../services/auth/auth.dart';
import '../../services/auth/auth_util.dart';
import '../../services/auth/oauth2_redirect.dart';
import '../../theme.dart';
import '../adaptive.dart';
import '../help_tip.dart';
import 'oauth2_panel.dart';

/// Desktop apps can listen on a loopback port for the browser's redirect;
/// phones fall back to pasting the redirected URL.
bool get canListenForRedirect => switch (defaultTargetPlatform) {
  TargetPlatform.linux ||
  TargetPlatform.windows ||
  TargetPlatform.macOS => !kIsWeb,
  _ => false,
};

/// Runs the auth's grant and stores the new token in [auth]. Returns the
/// token, or null when the dialog was closed without one.
Future<OAuth2Token?> showOAuth2TokenDialog(
  BuildContext context, {
  required AuthConfig auth,
  required AuthUiEnv env,
}) => showDialog<OAuth2Token>(
  context: context,
  builder: (_) => _TokenDialog(auth: auth, env: env),
);

class _TokenDialog extends StatefulWidget {
  const _TokenDialog({required this.auth, required this.env});
  final AuthConfig auth;
  final AuthUiEnv env;

  @override
  State<_TokenDialog> createState() => _TokenDialogState();
}

class _TokenDialogState extends State<_TokenDialog> {
  late final AuthContext _vars = AuthContext(vars: widget.env.vars);
  late final String _grant = OAuth2.grant(widget.auth);

  /// One state and verifier for the whole dialog, so a link copied before
  /// and a URL pasted after belong together.
  late final String _state = () {
    final s = _vars.param(widget.auth, 'state');
    return s.isEmpty ? randomAlnum(24) : s;
  }();
  late final String _verifier = () {
    final v = _vars.param(widget.auth, 'code_verifier');
    return v.isEmpty ? OAuth2.newCodeVerifier() : v;
  }();
  late final String _configuredRedirect = _vars.param(
    widget.auth,
    'redirect_uri',
  );

  /// The redirect_uri of the last authorization URL handed out; the code
  /// exchange must send the same one.
  late String _redirectUsed = _configuredRedirect;

  final _paste = TextEditingController();
  LoopbackRedirectListener? _listener;
  bool _busy = false;
  String? _waiting;
  String? _error;

  @override
  void dispose() {
    _listener?.close();
    _paste.dispose();
    super.dispose();
  }

  void _fail(Object e) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = e is AuthException ? e.message : '$e';
    });
  }

  void _done(OAuth2Token t) {
    if (mounted) Navigator.pop(context, t);
  }

  Future<void> _request() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final t = await widget.env.run(
        (ctx) => OAuth2.fetch(widget.auth, ctx, settings: widget.env.settings),
      );
      _done(t);
    } catch (e) {
      _fail(e);
    }
  }

  Uri _authUrl(String redirect) => OAuth2.authorizationUrl(
    widget.auth,
    _vars,
    redirectUri: redirect,
    state: _state,
    codeVerifier: _verifier,
  );

  Future<void> _signInWithBrowser() async {
    setState(() {
      _error = null;
      _waiting = null;
    });
    try {
      await _listener?.close();
      final listener = await LoopbackRedirectListener.start(
        _configuredRedirect,
      );
      _listener = listener;
      _redirectUsed = listener.redirectUri.toString();
      final url = _authUrl(_redirectUsed);
      final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
      if (!mounted) return;
      setState(() {
        _waiting =
            'Waiting for the browser to come back to $_redirectUsed'
            '${listener.note == null ? '.' : '.\n${listener.note}'}';
        if (!opened) {
          _error =
              'The browser could not be opened. Copy the authorization link '
              'below instead.';
        }
      });
      final redirected = await listener.result.timeout(
        const Duration(minutes: 10),
      );
      if (!mounted) return;
      setState(() => _busy = true);
      await _complete(redirected.toString(), strict: true);
    } on StateError {
      // Cancelled: a new attempt or the dialog closed.
    } on TimeoutException {
      _fail(AuthException('No answer from the browser in 10 minutes.'));
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _complete(String redirected, {bool strict = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final t = await widget.env.run(
        (ctx) => OAuth2.completeRedirect(
          widget.auth,
          ctx,
          redirected,
          redirectUri: _redirectUsed,
          state: _state,
          codeVerifier: _verifier,
          strictState: strict,
          settings: widget.env.settings,
        ),
      );
      _done(t);
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _copyLink() async {
    try {
      _redirectUsed = _configuredRedirect;
      final url = _authUrl(_configuredRedirect);
      await Clipboard.setData(ClipboardData(text: url.toString()));
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Authorization link copied.')),
      );
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _openLink() async {
    try {
      _redirectUsed = _configuredRedirect;
      await launchUrl(
        _authUrl(_configuredRedirect),
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      _fail(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dim = TextStyle(fontSize: 12.5, height: 1.35, color: Palette.textDim);
    final browser = OAuth2Grant.usesBrowser(_grant);
    return AdaptiveDialog(
      title: const Text('Get new access token'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Grant: ${OAuth2Grant.label(_grant)}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            if (!browser) ...[
              Text(
                _grant == OAuth2Grant.password
                    ? 'Sends the username, password and client credentials '
                          'to the access token URL.'
                    : 'Sends the client ID and secret to the access token URL.',
                style: dim,
              ),
              const SizedBox(height: 12),
              HelpHover(
                'Asks the token endpoint for a token now. Sending a request '
                'without a token does the same automatically.',
                title: 'Request token',
                example:
                    'POST {{accessTokenUrl}}  grant_type=client_credentials',
                child: FilledButton.icon(
                  onPressed: _busy ? null : _request,
                  icon: const Icon(Icons.key_outlined, size: 16),
                  label: const Text('Request token'),
                ),
              ),
            ] else ...[
              if (canListenForRedirect) ...[
                Text(
                  'Sign in in your browser. ApiWorkbench listens on this '
                  'computer for the redirect and finishes by itself.',
                  style: dim,
                ),
                const SizedBox(height: 10),
                HelpHover(
                  'Opens the authorization URL in the system browser and '
                  'catches the redirect on a 127.0.0.1 port.',
                  title: 'Sign in with the browser',
                  example: 'http://localhost:8080/callback',
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _signInWithBrowser,
                    icon: const Icon(Icons.open_in_browser, size: 16),
                    label: const Text('Sign in with the browser'),
                  ),
                ),
                if (_waiting != null) ...[
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_waiting!, style: dim)),
                    ],
                  ),
                ],
                const Divider(height: 28),
              ],
              LabelWithHelp(
                'Paste the redirected URL',
                'Open the authorization link in any browser, sign in, then '
                    'copy the address the browser ends up on (it holds the '
                    'code, or for the implicit grant the token after #).',
                example:
                    'https://oauth.example/cb?code=SplxlOBeZQQYbYS6WxSbIA'
                    '&state=xyz',
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  HelpHover(
                    'Copies the authorization URL with the redirect URI '
                    'from the settings.',
                    title: 'Copy authorization link',
                    child: OutlinedButton.icon(
                      onPressed: _copyLink,
                      icon: const Icon(Icons.link, size: 16),
                      label: const Text('Copy link'),
                    ),
                  ),
                  if (!canListenForRedirect)
                    HelpHover(
                      'Opens the authorization URL in the browser. After '
                      'signing in, copy the address you land on and paste it '
                      'here.',
                      title: 'Open in browser',
                      child: OutlinedButton.icon(
                        onPressed: _openLink,
                        icon: const Icon(Icons.open_in_browser, size: 16),
                        label: const Text('Open in browser'),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _paste,
                minLines: 1,
                maxLines: 4,
                style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace'),
                decoration: InputDecoration(
                  labelText: 'Redirected URL',
                  hintText: 'https://…?code=…&state=…',
                  suffixIcon: HelpTip(
                    'The full address from the browser after signing in.',
                    title: 'Redirected URL',
                    example: 'https://app.example/cb#access_token=…',
                  ),
                ),
              ),
              const SizedBox(height: 8),
              HelpHover(
                'Checks the state, then trades the code for a token (or, for '
                'the implicit grant, takes the token from the URL) and saves '
                'it.',
                title: 'Use this URL',
                example:
                    'POST {{accessTokenUrl}}  grant_type=authorization_code',
                child: FilledButton.tonal(
                  onPressed: _busy
                      ? null
                      : () {
                          final v = _paste.text.trim();
                          if (v.isNotEmpty) _complete(v);
                        },
                  child: const Text('Use this URL'),
                ),
              ),
            ],
            if (_busy) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              SelectableText(
                _error!,
                style: TextStyle(fontSize: 12.5, color: Palette.danger),
              ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
