import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/models.dart';
import '../../services/auth/auth.dart';
import '../../services/http_service.dart';
import '../../services/request_builder.dart';
import '../../theme.dart';
import '../adaptive.dart';
import '../help_tip.dart';
import 'oauth2_token_dialog.dart';

/// Variables and network access for the OAuth 2.0 UI: the token dialog
/// and the Refresh button send token requests outside a request send.
class AuthUiEnv {
  const AuthUiEnv({
    this.vars = const {},
    this.sendRaw,
    this.settings = const ResolvedSettings(),
  });

  final Map<String, String> vars;

  /// Sends without auth (the app's HTTP service). Null: a private
  /// [HttpService] is used for the call.
  final Future<ResponseData> Function(PreparedRequest p)? sendRaw;

  /// TLS and timeout settings for token requests.
  final ResolvedSettings settings;

  /// Runs [job] with a context that can send.
  Future<T> run<T>(Future<T> Function(AuthContext ctx) job) async {
    if (sendRaw != null) {
      return job(AuthContext(vars: vars, sendRaw: sendRaw));
    }
    final http = HttpService();
    try {
      return await job(
        AuthContext(
          vars: vars,
          sendRaw: (p) => http.sendPrepared(p, tabId: 'oauth2', source: 'auth'),
        ),
      );
    } finally {
      http.dispose();
    }
  }
}

String _mask(String token) => '•' * token.length.clamp(8, 32);

String _duration(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds} s';
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  if (d.inHours < 24) {
    final m = d.inMinutes % 60;
    return m == 0 ? '${d.inHours} h' : '${d.inHours} h $m min';
  }
  return '${d.inDays} d';
}

String _clock(DateTime t) {
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

/// "Expires in 59 min (2026-10-31 14:02)" / "Expired 3 min ago" / none.
({String text, bool expired}) expiryText(DateTime? at, [DateTime? now]) {
  if (at == null) return (text: 'No expiry given', expired: false);
  final n = now ?? DateTime.now();
  if (!n.isBefore(at)) {
    return (text: 'Expired ${_duration(n.difference(at))} ago', expired: true);
  }
  return (
    text: 'Expires in ${_duration(at.difference(n))} (${_clock(at)})',
    expired: false,
  );
}

/// The current OAuth 2.0 token: masked with a reveal toggle, its expiry,
/// Get new / Refresh / Clear, and the saved tokens to switch between.
class OAuth2TokenPanel extends StatefulWidget {
  const OAuth2TokenPanel({
    super.key,
    required this.auth,
    required this.env,
    required this.onChanged,
  });

  final AuthConfig auth;

  /// Built when needed, so variables are current.
  final AuthUiEnv Function() env;
  final VoidCallback onChanged;

  @override
  State<OAuth2TokenPanel> createState() => _OAuth2TokenPanelState();
}

class _OAuth2TokenPanelState extends State<OAuth2TokenPanel> {
  bool _reveal = false;
  bool _busy = false;

  AuthConfig get auth => widget.auth;

  void _changed() {
    setState(() {});
    widget.onChanged();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _getNew() async {
    final t = await showOAuth2TokenDialog(
      context,
      auth: auth,
      env: widget.env(),
    );
    if (t == null || !mounted) return;
    _changed();
    _snack('New access token saved${t.name.isEmpty ? '' : ' (${t.name})'}.');
  }

  Future<void> _refresh() async {
    final env = widget.env();
    setState(() => _busy = true);
    try {
      await env.run((ctx) => OAuth2.refresh(auth, ctx, settings: env.settings));
      _changed();
      _snack('Access token refreshed.');
    } on AuthException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _manage() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _ManageTokensDialog(auth: auth, onChanged: _changed),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = OAuth2.current(auth);
    final saved = OAuth2.saved(auth);
    final dim = TextStyle(fontSize: 12, color: Palette.textDim);
    return Container(
      constraints: const BoxConstraints(maxWidth: 560),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Palette.surfaceAlt,
        border: Border.all(color: Palette.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const LabelWithHelp(
            'Current token',
            'The access token added to requests. It is saved with this '
                'request, folder or collection, and refreshed on send when it '
                'has expired and a refresh token is available.',
            example: 'Authorization: Bearer eyJhbGciOi…',
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          if (t == null)
            Text(
              OAuth2Grant.canAutoFetch(OAuth2.grant(auth))
                  ? 'No token yet. One is fetched automatically when you '
                        'send, or get one now.'
                  : 'No token yet. Click "Get new access token" to sign in.',
              style: dim,
            )
          else ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: SelectableText(
                    _reveal ? t.accessToken : _mask(t.accessToken),
                    key: const ValueKey('oauth2-token-text'),
                    maxLines: _reveal ? 6 : 1,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                IconButton(
                  tooltip: _reveal ? 'Hide token' : 'Show token',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  icon: Icon(
                    _reveal
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                  onPressed: () => setState(() => _reveal = !_reveal),
                ),
                IconButton(
                  tooltip: 'Copy token',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  icon: const Icon(Icons.copy_outlined),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: t.accessToken));
                    _snack('Token copied.');
                  },
                ),
              ],
            ),
            const SizedBox(height: 4),
            Builder(
              builder: (context) {
                final e = expiryText(t.expiresAt);
                return Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    Text(
                      e.text,
                      style: TextStyle(
                        fontSize: 12,
                        color: e.expired ? Palette.danger : Palette.success,
                      ),
                    ),
                    if (t.tokenType.isNotEmpty)
                      Text('Type: ${t.tokenType}', style: dim),
                    if (t.refreshToken.isNotEmpty)
                      Text('Has a refresh token', style: dim),
                  ],
                );
              },
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              HelpHover(
                'Runs the selected grant: signs you in in the browser for the '
                'authorization code and implicit grants, or asks the token '
                'endpoint directly for the others.',
                title: 'Get new access token',
                child: FilledButton.icon(
                  onPressed: _busy ? null : _getNew,
                  icon: const Icon(Icons.key_outlined, size: 16),
                  label: const Text('Get new access token'),
                ),
              ),
              if (t != null && t.refreshToken.isNotEmpty)
                HelpHover(
                  'Trades the refresh token for a new access token now, '
                  'instead of waiting for the current one to expire.',
                  title: 'Refresh',
                  example: 'grant_type=refresh_token',
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _refresh,
                    icon: _busy
                        ? const SizedBox.square(
                            dimension: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh, size: 16),
                    label: const Text('Refresh'),
                  ),
                ),
              if (t != null)
                HelpHover(
                  'Stops using this token. It stays in the saved tokens until '
                  'you delete it there.',
                  title: 'Clear',
                  child: TextButton(
                    onPressed: () {
                      OAuth2.clear(auth);
                      _changed();
                    },
                    child: const Text('Clear'),
                  ),
                ),
            ],
          ),
          if (saved.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: HelpHover(
                    'Tokens fetched earlier for this auth. Pick one to use it '
                    'again.',
                    title: 'Saved tokens',
                    child: DropdownButtonFormField<int>(
                      key: ValueKey('saved-${t?.accessToken}-${saved.length}'),
                      isExpanded: true,
                      initialValue: () {
                        final i = saved.indexWhere(
                          (s) => s.accessToken == t?.accessToken,
                        );
                        return i < 0 ? null : i;
                      }(),
                      hint: const Text('Use a saved token'),
                      decoration: const InputDecoration(
                        labelText: 'Saved tokens',
                      ),
                      style: TextStyle(fontSize: 13, color: Palette.text),
                      items: [
                        for (var i = 0; i < saved.length; i++)
                          DropdownMenuItem(
                            value: i,
                            child: Text(
                              _tokenLabel(saved[i], i),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (i) {
                        if (i == null) return;
                        OAuth2.use(auth, saved[i]);
                        _changed();
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                HelpHover(
                  'See every saved token, and delete the ones you no longer '
                  'need.',
                  title: 'Manage tokens',
                  child: TextButton(
                    onPressed: _manage,
                    child: const Text('Manage'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

String _tokenLabel(OAuth2Token t, int i) {
  final name = t.name.isEmpty ? 'Token ${i + 1}' : t.name;
  final e = t.expiresAt == null
      ? ''
      : (t.isExpired(DateTime.now()) ? ' · expired' : ' · valid');
  return '$name · ${_clock(t.obtainedAt)}$e';
}

class _ManageTokensDialog extends StatefulWidget {
  const _ManageTokensDialog({required this.auth, required this.onChanged});
  final AuthConfig auth;
  final VoidCallback onChanged;

  @override
  State<_ManageTokensDialog> createState() => _ManageTokensDialogState();
}

class _ManageTokensDialogState extends State<_ManageTokensDialog> {
  void _save(List<OAuth2Token> tokens) {
    setState(() => OAuth2.setSaved(widget.auth, tokens));
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OAuth2.saved(widget.auth);
    final current = widget.auth.params['accessToken'];
    final now = DateTime.now();
    return AdaptiveDialog(
      title: const Text('Saved tokens'),
      height: 380,
      content: tokens.isEmpty
          ? Center(
              child: Text(
                'No saved tokens.',
                style: TextStyle(color: Palette.textDim),
              ),
            )
          : ListView(
              children: [
                for (var i = 0; i < tokens.length; i++)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      tokens[i].accessToken == current
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color: Palette.accent,
                    ),
                    title: Text(
                      _tokenLabel(tokens[i], i),
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      expiryText(tokens[i].expiresAt, now).text,
                      style: TextStyle(fontSize: 12, color: Palette.textDim),
                    ),
                    onTap: () {
                      OAuth2.use(widget.auth, tokens[i]);
                      widget.onChanged();
                      setState(() {});
                    },
                    trailing: IconButton(
                      tooltip: 'Delete token',
                      icon: Icon(
                        Icons.delete_outline,
                        size: 18,
                        color: Palette.danger,
                      ),
                      onPressed: () {
                        if (tokens[i].accessToken == current) {
                          OAuth2.clear(widget.auth);
                        }
                        _save([...tokens]..removeAt(i));
                      },
                    ),
                  ),
              ],
            ),
      actions: [
        HelpHover(
          'Removes the tokens whose expiry has passed.',
          title: 'Delete expired',
          child: TextButton(
            onPressed: tokens.any((t) => t.isExpired(now))
                ? () => _save([
                    for (final t in tokens)
                      if (!t.isExpired(now)) t,
                  ])
                : null,
            child: const Text('Delete expired'),
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
