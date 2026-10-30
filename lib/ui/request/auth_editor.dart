import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme.dart';
import '../help_tip.dart';

/// Edits an [AuthConfig]: a request's, a folder's or a collection's.
class AuthEditor extends StatefulWidget {
  const AuthEditor({
    super.key,
    required this.auth,
    required this.onChanged,
    this.allowInherit = true,
    this.inheritedFrom,
  });

  final AuthConfig auth;
  final VoidCallback onChanged;

  /// Offer "Inherit from parent" (not for a collection's own auth).
  final bool allowInherit;

  /// What inherit resolves to right now, e.g. 'Bearer Token from Orders'.
  final String? inheritedFrom;

  @override
  State<AuthEditor> createState() => _AuthEditorState();
}

class _AuthEditorState extends State<AuthEditor> {
  AuthConfig get auth => widget.auth;

  void _touch() => widget.onChanged();

  List<AuthType> get _types => [
    AuthType.none,
    if (widget.allowInherit || auth.type == AuthType.inherit) AuthType.inherit,
    for (final t in AuthType.values)
      if (t != AuthType.none && t != AuthType.inherit) t,
  ];

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Flexible(
              child: SizedBox(
                width: 260,
                child: DropdownButtonFormField<AuthType>(
                  initialValue: auth.type,
                  decoration: const InputDecoration(labelText: 'Auth type'),
                  items: [
                    for (final t in _types)
                      DropdownMenuItem(
                        value: t,
                        child: HelpHover(
                          _authTypeHelp(t).message,
                          title: t.label,
                          example: _authTypeHelp(t).example,
                          child: Text(t.label),
                        ),
                      ),
                  ],
                  onChanged: (t) {
                    if (t != null) {
                      setState(() => auth.type = t);
                      _touch();
                    }
                  },
                ),
              ),
            ),
            const HelpTip(
              'How this request proves who you are. The matching header or '
              'query parameter is added for you when you send.',
              title: 'Auth type',
              example: 'Authorization: Bearer eyJhbGci…',
            ),
          ],
        ),
        const SizedBox(height: 16),
        ...switch (auth.type) {
          AuthType.none => [
            Text(
              'No authentication will be applied.',
              style: TextStyle(color: Palette.textDim),
            ),
          ],
          AuthType.bearer => [
            _authField(
              'Token',
              auth.bearerToken,
              (v) => auth.bearerToken = v,
              obscure: true,
              help:
                  'The access token from your login or API dashboard. It is '
                  'sent in the Authorization header.',
              title: 'Bearer token',
              example: '{{token}}  →  Authorization: Bearer {{token}}',
            ),
          ],
          AuthType.basic => [
            _authField(
              'Username',
              auth.basicUser,
              (v) => auth.basicUser = v,
              help:
                  'Combined with the password into an Authorization: Basic '
                  'header.',
              title: 'Username',
              example: 'ada',
            ),
            const SizedBox(height: 12),
            _authField(
              'Password',
              auth.basicPassword,
              (v) => auth.basicPassword = v,
              obscure: true,
              help:
                  'Basic Auth only encodes the password, it does not encrypt '
                  'it, so use https:// addresses.',
              title: 'Password',
              example: '{{password}}',
            ),
          ],
          AuthType.apiKey => [
            _authField(
              'Key name',
              auth.apiKeyName,
              (v) => auth.apiKeyName = v,
              help:
                  'The header or query parameter name the API expects. Check '
                  'the API\'s docs.',
              title: 'Key name',
              example: 'X-API-Key',
            ),
            const SizedBox(height: 12),
            _authField(
              'Value',
              auth.apiKeyValue,
              (v) => auth.apiKeyValue = v,
              obscure: true,
              help:
                  'Your API key. A variable lets you change it in one place '
                  'for every request.',
              title: 'Key value',
              example: '{{apiKey}}',
            ),
            const SizedBox(height: 12),
            HelpHover(
              'Header sends the key as a request header. Query param adds it '
              'to the URL instead, where it may end up in server logs.',
              title: 'Where to send the key',
              example: 'X-API-Key: abc123  or  ?api_key=abc123',
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Header')),
                  ButtonSegment(value: false, label: Text('Query param')),
                ],
                selected: {auth.apiKeyInHeader},
                onSelectionChanged: (s) {
                  setState(() => auth.apiKeyInHeader = s.first);
                  _touch();
                },
              ),
            ),
          ],
          AuthType.inherit => [
            Text(
              widget.inheritedFrom == null
                  ? 'Uses the auth of the folder or collection this request '
                        'is saved in. Outside a collection no auth is sent.'
                  : 'Uses ${widget.inheritedFrom}.',
              style: TextStyle(color: Palette.textDim),
            ),
          ],
          _ => [
            // Each scheme's fields are added with its implementation
            // (issues #6, #7 and #8).
            Text(
              '${auth.type.label} settings are not available in this build.',
              style: TextStyle(color: Palette.textDim),
            ),
          ],
        },
      ],
    );
  }

  static ({String message, String? example}) _authTypeHelp(AuthType t) =>
      switch (t) {
        AuthType.none => (
          message: 'Send no credentials. Use it for public endpoints.',
          example: null,
        ),
        AuthType.bearer => (
          message:
              'Sends a token in the Authorization header. Most modern APIs '
              'and OAuth logins use this.',
          example: 'Authorization: Bearer eyJhbGci…',
        ),
        AuthType.basic => (
          message:
              'Sends a username and password, base64-encoded, in the '
              'Authorization header.',
          example: 'Authorization: Basic YWRhOnNlY3JldA==',
        ),
        AuthType.apiKey => (
          message:
              'Sends a key under a name you choose, as a header or a query '
              'parameter.',
          example: 'X-API-Key: abc123',
        ),
        AuthType.inherit => (
          message:
              'Use the auth set on the folder or collection, so one token '
              'covers every request in it.',
          example: 'Collection: Bearer {{token}}',
        ),
        _ => (message: t.label, example: null),
      };

  Widget _authField(
    String label,
    String value,
    ValueChanged<String> onChanged, {
    bool obscure = false,
    required String help,
    required String title,
    String? example,
  }) {
    return SizedBox(
      width: 420,
      child: TextFormField(
        initialValue: value,
        obscureText: obscure,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: HelpTip(help, title: title, example: example),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 32,
            minHeight: 32,
          ),
        ),
        onChanged: (v) {
          onChanged(v);
          _touch();
        },
      ),
    );
  }
}
