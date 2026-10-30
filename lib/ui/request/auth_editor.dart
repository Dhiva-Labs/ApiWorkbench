import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../services/auth/auth.dart';
import '../../services/auth/auth_util.dart';
import '../../services/request_builder.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../auth/auth_fields.dart';
import '../auth/oauth2_panel.dart';
import '../help_tip.dart';

/// Edits an [AuthConfig]: a request's, a folder's or a collection's.
class AuthEditor extends StatefulWidget {
  const AuthEditor({
    super.key,
    required this.auth,
    required this.onChanged,
    this.allowInherit = true,
    this.inheritedFrom,
    this.vars,
  });

  final AuthConfig auth;
  final VoidCallback onChanged;

  /// Offer "Inherit from parent" (not for a collection's own auth).
  final bool allowInherit;

  /// What inherit resolves to right now, e.g. 'Bearer Token from Orders'.
  final String? inheritedFrom;

  /// Variables for "Get new access token". Null: those of the request or
  /// collection that owns [auth], else of the active tab.
  final Map<String, String>? vars;

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

  // ---- params ----

  String _p(String key, [String fallback = '']) => auth.params[key] ?? fallback;

  void _setP(String key, String value) {
    auth.params[key] = value;
    _touch();
  }

  /// A change that shows or hides other fields.
  void _setPAndRebuild(String key, String value) =>
      setState(() => _setP(key, value));

  bool _flag(String key, {bool fallback = false}) =>
      authFlag(auth, key, fallback: fallback);

  // ---- environment for the OAuth 2.0 token UI ----

  AppState? _appState() {
    try {
      return Provider.of<AppState>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  /// The collection whose variables apply to [auth]: the tab or the
  /// collection (or folder) that owns it, else the active tab's.
  String? _collectionId(AppState s) {
    for (final t in s.tabs) {
      if (identical(t.request.auth, auth)) return t.sourceCollectionId;
    }
    for (final c in s.collections) {
      if (identical(c.auth, auth) ||
          c.folders.values.any((f) => identical(f.auth, auth))) {
        return c.id;
      }
    }
    return s.activeTab?.sourceCollectionId;
  }

  AuthUiEnv _env() {
    final s = _appState();
    final vars = widget.vars ?? s?.varsFor(_collectionId(s)) ?? const {};
    if (s == null) return AuthUiEnv(vars: vars);
    return AuthUiEnv(
      vars: vars,
      sendRaw: (p) =>
          s.http.sendPrepared(p, tabId: 'oauth2-token', source: 'auth'),
      settings: ResolvedSettings.of(RequestSettings(), s.settings),
    );
  }

  // ---- layout ----

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 820;
        final intro = _intro();
        final fields = _fields();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: wide
              ? [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 260, child: intro),
                      const SizedBox(width: 28),
                      Expanded(child: fields),
                    ],
                  ),
                ]
              : [intro, const SizedBox(height: 16), fields],
        );
      },
    );
  }

  /// The type picker and what the type does: Postman's left column.
  Widget _intro() {
    final about = _about(auth.type);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: SizedBox(
                width: 260,
                child: DropdownButtonFormField<AuthType>(
                  initialValue: auth.type,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Auth type'),
                  items: [
                    for (final t in _types)
                      DropdownMenuItem(
                        value: t,
                        child: HelpHover(
                          _authTypeHelp(t).message,
                          title: t.label,
                          example: _authTypeHelp(t).example,
                          child: Text(t.label, overflow: TextOverflow.ellipsis),
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
        if (about != null) ...[
          const SizedBox(height: 10),
          Text(
            about,
            style: TextStyle(fontSize: 12, height: 1.4, color: Palette.textDim),
          ),
        ],
      ],
    );
  }

  Widget _fields() {
    final children = switch (auth.type) {
      AuthType.none => [
        Text(
          'No authentication will be applied.',
          style: TextStyle(color: Palette.textDim),
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
      AuthType.bearer => _bearer(),
      AuthType.basic => _basic(),
      AuthType.apiKey => _apiKey(),
      AuthType.oauth2 => _oauth2(),
      AuthType.oauth1 => _oauth1(),
      AuthType.digest => _digest(),
      AuthType.awsV4 => _aws(),
      AuthType.ntlm => _ntlm(),
      AuthType.hawk => _hawk(),
      AuthType.edgegrid => _edgegrid(),
      AuthType.jwt => _jwt(),
    };
    return KeyedSubtree(
      // Fresh field state per type, so one type's text never shows in
      // another's field.
      key: ValueKey('auth-fields-${auth.type.name}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final w in children) ...[w, const SizedBox(height: 12)],
        ],
      ),
    );
  }

  /// A text field bound to a param.
  Widget _text(
    String key,
    String label, {
    required String help,
    String? title,
    String? example,
    String? hint,
    bool secret = false,
    bool multiline = false,
    bool mono = false,
    String fallback = '',
  }) => AuthTextField(
    key: ValueKey('auth-${auth.type.name}-$key'),
    label: label,
    value: _p(key, fallback),
    onChanged: (v) => _setP(key, v),
    help: help,
    title: title ?? label,
    example: example,
    hint: hint,
    secret: secret,
    multiline: multiline,
    mono: mono,
  );

  Widget _switch(
    String key,
    String title,
    String subtitle, {
    required String help,
    String? example,
    bool fallback = false,
  }) => AuthSwitch(
    title: title,
    subtitle: subtitle,
    value: _flag(key, fallback: fallback),
    onChanged: (v) => _setPAndRebuild(key, '$v'),
    help: help,
    example: example,
  );

  // ---- simple types ----

  List<Widget> _bearer() => [
    AuthTextField(
      key: const ValueKey('auth-bearer-token'),
      label: 'Token',
      value: auth.bearerToken,
      onChanged: (v) {
        auth.bearerToken = v;
        _touch();
      },
      secret: true,
      help:
          'The access token from your login or API dashboard. It is sent in '
          'the Authorization header.',
      title: 'Bearer token',
      example: '{{token}}  →  Authorization: Bearer {{token}}',
    ),
  ];

  List<Widget> _basic() => [
    AuthTextField(
      key: const ValueKey('auth-basic-user'),
      label: 'Username',
      value: auth.basicUser,
      onChanged: (v) {
        auth.basicUser = v;
        _touch();
      },
      help: 'Combined with the password into an Authorization: Basic header.',
      title: 'Username',
      example: 'ada',
    ),
    AuthTextField(
      key: const ValueKey('auth-basic-password'),
      label: 'Password',
      value: auth.basicPassword,
      onChanged: (v) {
        auth.basicPassword = v;
        _touch();
      },
      secret: true,
      help:
          'Basic Auth only encodes the password, it does not encrypt it, so '
          'use https:// addresses.',
      title: 'Password',
      example: '{{password}}',
    ),
  ];

  List<Widget> _apiKey() => [
    AuthTextField(
      key: const ValueKey('auth-apikey-name'),
      label: 'Key name',
      value: auth.apiKeyName,
      onChanged: (v) {
        auth.apiKeyName = v;
        _touch();
      },
      help:
          'The header or query parameter name the API expects. Check the '
          'API\'s docs.',
      title: 'Key name',
      example: 'X-API-Key',
    ),
    AuthTextField(
      key: const ValueKey('auth-apikey-value'),
      label: 'Value',
      value: auth.apiKeyValue,
      onChanged: (v) {
        auth.apiKeyValue = v;
        _touch();
      },
      secret: true,
      help:
          'Your API key. A variable lets you change it in one place for every '
          'request.',
      title: 'Key value',
      example: '{{apiKey}}',
    ),
    AuthSegmented(
      label: 'Add to',
      value: auth.apiKeyInHeader ? 'header' : 'query',
      options: const [
        AuthOption('header', 'Header'),
        AuthOption('query', 'Query param'),
      ],
      onChanged: (v) {
        setState(() => auth.apiKeyInHeader = v == 'header');
        _touch();
      },
      help:
          'Header sends the key as a request header. Query param adds it to '
          'the URL instead, where it may end up in server logs.',
      example: 'X-API-Key: abc123  or  ?api_key=abc123',
    ),
  ];

  // ---- OAuth 2.0 ----

  List<Widget> _oauth2() {
    final grant = OAuth2.grant(auth);
    final browser = OAuth2Grant.usesBrowser(grant);
    final implicit = grant == OAuth2Grant.implicit;
    final inHeader = _p('addTokenTo', 'header') != 'queryParams';
    return [
      OAuth2TokenPanel(
        auth: auth,
        env: _env,
        onChanged: () {
          setState(() {});
          _touch();
        },
      ),
      AuthSegmented(
        label: 'Add token to',
        value: inHeader ? 'header' : 'queryParams',
        options: const [
          AuthOption('header', 'Header'),
          AuthOption('queryParams', 'Query param'),
        ],
        onChanged: (v) => _setPAndRebuild('addTokenTo', v),
        help:
            'Header sends Authorization: <prefix> <token>. Query param adds '
            'access_token=<token> to the URL.',
        example: 'Authorization: Bearer ya29.a0Af…',
      ),
      if (inHeader)
        _text(
          'headerPrefix',
          'Header prefix',
          fallback: 'Bearer',
          help:
              'Written before the token in the Authorization header. Leave '
              'empty to send the token alone.',
          example: 'Bearer',
        ),
      const AuthHeading(
        'Configure new token',
        'How "Get new access token" (and the automatic fetch for client '
            'credentials and password grants) asks for a token.',
        example: 'Grant type: Authorization Code (With PKCE)',
      ),
      _text(
        'tokenName',
        'Token name',
        help: 'A name to tell tokens apart in the saved tokens list.',
        example: 'Staging admin',
      ),
      AuthDropdown(
        label: 'Grant type',
        value: grant,
        options: const [
          AuthOption(
            OAuth2Grant.authorizationCode,
            'Authorization Code',
            'You sign in in a browser; the app trades the returned code for '
                'a token.',
          ),
          AuthOption(
            OAuth2Grant.pkce,
            'Authorization Code (With PKCE)',
            'Authorization code with a one-time secret, for apps that cannot '
                'keep a client secret. The current best practice.',
          ),
          AuthOption(
            OAuth2Grant.implicit,
            'Implicit',
            'The token comes straight back in the redirect. Legacy; prefer '
                'PKCE.',
          ),
          AuthOption(
            OAuth2Grant.password,
            'Password Credentials',
            'Sends a username and password to the token endpoint. Only for '
                'first-party apps.',
          ),
          AuthOption(
            OAuth2Grant.clientCredentials,
            'Client Credentials',
            'Machine-to-machine: the client ID and secret alone get a token.',
          ),
        ],
        onChanged: (v) => _setPAndRebuild('grant_type', v),
        help:
            'Which OAuth 2.0 flow gets the token. Your provider\'s docs say '
            'which ones it supports.',
        example: 'Client Credentials',
      ),
      if (browser) ...[
        _text(
          'redirect_uri',
          'Callback URL',
          help:
              'Where the provider sends the browser after sign-in; it must be '
              'registered with the provider. A http://localhost:PORT address '
              'lets the desktop app catch it by itself.',
          example: 'http://localhost:8080/callback',
        ),
        _text(
          'authUrl',
          'Auth URL',
          help:
              'The provider\'s authorization endpoint, opened in the browser.',
          example: 'https://accounts.example.com/oauth2/authorize',
        ),
      ],
      if (!implicit)
        _text(
          'accessTokenUrl',
          'Access token URL',
          help: 'The provider\'s token endpoint.',
          example: 'https://accounts.example.com/oauth2/token',
        ),
      _text(
        'clientId',
        'Client ID',
        help: 'The public identifier of the app you registered.',
        example: '{{clientId}}',
      ),
      if (!implicit)
        _text(
          'clientSecret',
          'Client secret',
          secret: true,
          help:
              'The app\'s secret. Leave empty for public clients such as '
              'PKCE apps; the client ID is then sent in the body.',
          example: '{{clientSecret}}',
        ),
      if (grant == OAuth2Grant.pkce) ...[
        AuthDropdown(
          label: 'Code challenge method',
          value: _p('challengeAlgorithm', 'S256'),
          options: const [
            AuthOption('S256', 'SHA-256', 'Sends a hash of the verifier.'),
            AuthOption('plain', 'Plain', 'Sends the verifier itself.'),
          ],
          onChanged: (v) => _setP('challengeAlgorithm', v),
          help:
              'How the code challenge is made from the verifier. Use SHA-256 '
              'unless the provider only supports plain.',
          example: 'S256',
        ),
        _text(
          'code_verifier',
          'Code verifier',
          secret: true,
          help:
              'Optional. Leave empty to get a new random verifier for each '
              'sign-in (43 to 128 characters).',
          example: 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
        ),
      ],
      if (grant == OAuth2Grant.password) ...[
        _text(
          'username',
          'Username',
          help: 'The resource owner\'s username.',
          example: 'ada@example.com',
        ),
        _text(
          'password',
          'Password',
          secret: true,
          help: 'The resource owner\'s password.',
          example: '{{password}}',
        ),
      ],
      _text(
        'scope',
        'Scope',
        help: 'Space-separated permissions to ask for.',
        example: 'openid profile email',
      ),
      if (browser)
        _text(
          'state',
          'State',
          help:
              'Sent with the sign-in and checked when the browser comes back. '
              'Leave empty for a random one each time.',
          example: '{{\$guid}}',
        ),
      if (!implicit)
        AuthDropdown(
          label: 'Client authentication',
          value: _p('client_authentication', 'header'),
          options: const [
            AuthOption(
              'header',
              'Send as Basic Auth header',
              'Authorization: Basic base64(client_id:client_secret)',
            ),
            AuthOption(
              'body',
              'Send client credentials in body',
              'client_id and client_secret as form fields.',
            ),
          ],
          onChanged: (v) => _setP('client_authentication', v),
          help: 'How the token request proves which app is asking.',
          example: 'Authorization: Basic Y2xpZW50OnNlY3JldA==',
        ),
      AuthAdvanced(
        children: [
          if (!implicit)
            _text(
              'refreshTokenUrl',
              'Refresh token URL',
              help:
                  'Where refresh tokens are traded. Empty uses the access '
                  'token URL.',
              example: 'https://accounts.example.com/oauth2/token',
            ),
          _text(
            'audience',
            'Audience',
            help:
                'Sent as audience= with the sign-in and token requests. Some '
                'providers (Auth0, Okta) need it to issue an API token.',
            example: 'https://api.example.com',
          ),
          _text(
            'resource',
            'Resource',
            help:
                'Sent as resource= (RFC 8707): the API the token is for. '
                'Azure AD v1 and ADFS use it.',
            example: 'https://graph.microsoft.com',
          ),
        ],
      ),
    ];
  }

  // ---- OAuth 1.0 ----

  List<Widget> _oauth1() {
    final method = _p('signatureMethod', 'HMAC-SHA1');
    final rsa = method.startsWith('RSA');
    return [
      AuthDropdown(
        label: 'Add authorization data to',
        value: _flag('addParamsToHeader', fallback: true) ? 'true' : 'false',
        options: const [
          AuthOption('true', 'Request headers', 'Authorization: OAuth …'),
          AuthOption(
            'false',
            'Request body or URL',
            'oauth_* params go in a form body when there is one, else in the '
                'query string.',
          ),
        ],
        onChanged: (v) => _setPAndRebuild('addParamsToHeader', v),
        help: 'Where the oauth_* parameters and the signature are sent.',
        example: 'Authorization: OAuth oauth_consumer_key="…", …',
      ),
      AuthDropdown(
        label: 'Signature method',
        value: method,
        options: const [
          AuthOption('HMAC-SHA1', 'HMAC-SHA1'),
          AuthOption('HMAC-SHA256', 'HMAC-SHA256'),
          AuthOption('HMAC-SHA512', 'HMAC-SHA512'),
          AuthOption(
            'RSA-SHA1',
            'RSA-SHA1',
            'Signs with your RSA private key.',
          ),
          AuthOption('RSA-SHA256', 'RSA-SHA256'),
          AuthOption('RSA-SHA512', 'RSA-SHA512'),
          AuthOption(
            'PLAINTEXT',
            'PLAINTEXT',
            'Sends the secrets themselves. Only over https.',
          ),
        ],
        onChanged: (v) => _setPAndRebuild('signatureMethod', v),
        help:
            'How requests are signed. HMAC uses the consumer and token '
            'secrets; RSA uses a private key the server knows the public half '
            'of.',
        example: 'HMAC-SHA1',
      ),
      _text(
        'consumerKey',
        'Consumer key',
        help: 'Identifies your app to the service.',
        example: 'xvz1evFS4wEEPTGEFPHBog',
      ),
      if (!rsa)
        _text(
          'consumerSecret',
          'Consumer secret',
          secret: true,
          help: 'The app\'s secret, used to sign.',
          example: '{{consumerSecret}}',
        ),
      _text(
        'token',
        'Access token',
        help: 'The user\'s access token. Leave empty for 2-legged OAuth.',
        example: '370773112-GmHxMAgYyLbNEtIKZeRNFsMKPR9EyMZeS9weJAEb',
      ),
      if (!rsa)
        _text(
          'tokenSecret',
          'Token secret',
          secret: true,
          help: 'The secret that came with the access token.',
          example: '{{tokenSecret}}',
        ),
      if (rsa)
        _text(
          'privateKey',
          'Private key',
          secret: true,
          multiline: true,
          mono: true,
          help:
              'An unencrypted RSA private key in PEM form (PKCS#1 or PKCS#8).',
          example: '-----BEGIN PRIVATE KEY-----\nMIIEvQ…',
        ),
      AuthAdvanced(
        children: [
          _text(
            'callback',
            'Callback URL',
            help: 'oauth_callback, for the request-token step.',
            example: 'https://app.example/oauth/callback',
          ),
          _text(
            'verifier',
            'Verifier',
            help: 'oauth_verifier, for the access-token step.',
            example: 'hfdp7dh39dks9884',
          ),
          _text(
            'timestamp',
            'Timestamp',
            help: 'Seconds since 1970. Empty uses the current time.',
            example: '1318622958',
          ),
          _text(
            'nonce',
            'Nonce',
            help: 'A unique value per request. Empty generates one.',
            example: 'kYjzVBB8Y0ZFabxSWbWovY3uYSQ2pTgmZeNu2VS4cg',
          ),
          _text(
            'version',
            'Version',
            fallback: '1.0',
            help: 'oauth_version. Empty leaves it out.',
            example: '1.0',
          ),
          _text(
            'realm',
            'Realm',
            help: 'Optional realm for the Authorization header (not signed).',
            example: 'Photos',
          ),
          _switch(
            'includeBodyHash',
            'Include body hash',
            'Adds oauth_body_hash for bodies that are not forms.',
            help:
                'A hash of the raw body, so the signature covers JSON and '
                'other bodies too.',
            example: 'oauth_body_hash="2jmj7l5rSw0yVb/vlWAYkK/YBwk="',
          ),
          _switch(
            'addEmptyParamsToSign',
            'Add empty parameters to signature',
            'Signs empty oauth_token, oauth_callback and oauth_verifier too.',
            help:
                'Some servers expect empty oauth_* values to be sent and '
                'signed rather than left out.',
            example: 'oauth_token=""',
          ),
        ],
      ),
    ];
  }

  // ---- Digest ----

  List<Widget> _digest() => [
    _text(
      'username',
      'Username',
      help: 'Your username for this server.',
      example: 'Mufasa',
    ),
    _text(
      'password',
      'Password',
      secret: true,
      help: 'Never sent: only a hash of it goes over the wire.',
      example: '{{password}}',
    ),
    _switch(
      'disableRetryRequest',
      'Don\'t answer the challenge',
      'Keep the server\'s 401 instead of retrying with credentials.',
      help:
          'By default the 401 challenge is answered automatically. Turn this '
          'on to see the challenge itself.',
      example: 'WWW-Authenticate: Digest realm="…", nonce="…"',
    ),
    AuthAdvanced(
      help:
          'Usually filled in from the server\'s challenge. With a realm and '
          'nonce set here the first request is signed already.',
      children: [
        _text(
          'realm',
          'Realm',
          help: 'From the server\'s WWW-Authenticate challenge.',
          example: 'http-auth@example.org',
        ),
        _text(
          'nonce',
          'Nonce',
          help: 'The server nonce from the challenge.',
          example: '7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v',
        ),
        AuthDropdown(
          label: 'Algorithm',
          value: _p('algorithm', 'MD5'),
          options: [for (final a in DigestAuth.algorithms) AuthOption(a, a)],
          onChanged: (v) => _setP('algorithm', v),
          help:
              'The hash to use. A challenge from the server decides when it '
              'names one.',
          example: 'SHA-256',
        ),
        AuthDropdown(
          label: 'qop',
          value: _p('qop'),
          options: const [
            AuthOption('', 'None', 'RFC 2069 style, no client nonce.'),
            AuthOption('auth', 'auth', 'Protects the method and URI.'),
            AuthOption('auth-int', 'auth-int', 'Also covers the body.'),
          ],
          onChanged: (v) => _setP('qop', v),
          help: 'Quality of protection, if the server offers a choice.',
          example: 'auth',
        ),
        _text(
          'nonceCount',
          'Nonce count',
          help: 'nc, in hex. Empty uses 00000001.',
          example: '00000001',
        ),
        _text(
          'clientNonce',
          'Client nonce',
          help: 'cnonce. Empty generates one per request.',
          example: '0a4f113b',
        ),
        _text(
          'opaque',
          'Opaque',
          help: 'Echoed back to the server as it sent it.',
          example: '5ccc069c403ebaf9f0171e9517f40e41',
        ),
      ],
    ),
  ];

  // ---- AWS ----

  List<Widget> _aws() => [
    AuthSegmented(
      label: 'Add authorization data to',
      value: _flag('addAuthDataToQuery') ? 'true' : 'false',
      options: const [
        AuthOption('false', 'Request headers'),
        AuthOption('true', 'Request URL'),
      ],
      onChanged: (v) => _setPAndRebuild('addAuthDataToQuery', v),
      help:
          'Headers sign the request in the Authorization header. Request URL '
          'makes a presigned URL (valid 24 hours) instead.',
      example: '?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Signature=…',
    ),
    _text(
      'accessKey',
      'Access key',
      help: 'Your AWS access key ID.',
      example: 'AKIAIOSFODNN7EXAMPLE',
    ),
    _text(
      'secretKey',
      'Secret key',
      secret: true,
      help: 'The secret access key that goes with it.',
      example: '{{awsSecretKey}}',
    ),
    AuthAdvanced(
      help:
          'Region and service are read from *.amazonaws.com hosts when left '
          'empty. Set them for custom domains.',
      children: [
        _text(
          'region',
          'AWS region',
          help: 'Empty: from the host, else us-east-1.',
          example: 'eu-west-1',
        ),
        _text(
          'service',
          'Service name',
          help: 'The signing name of the service. Empty: from the host.',
          example: 'execute-api',
        ),
        _text(
          'sessionToken',
          'Session token',
          secret: true,
          help:
              'For temporary credentials (STS, SSO). Sent as '
              'X-Amz-Security-Token.',
          example: '{{awsSessionToken}}',
        ),
      ],
    ),
  ];

  // ---- NTLM ----

  List<Widget> _ntlm() => [
    _text(
      'username',
      'Username',
      help: r'Your Windows user name. DOMAIN\user works too.',
      example: r'CONTOSO\ada',
    ),
    _text(
      'password',
      'Password',
      secret: true,
      help: 'Used for the NTLMv2 response; never sent itself.',
      example: '{{password}}',
    ),
    AuthAdvanced(
      children: [
        _text(
          'domain',
          'Domain',
          help: 'The Windows domain. Often required by IIS servers.',
          example: 'CONTOSO',
        ),
        _text(
          'workstation',
          'Workstation',
          help: 'This computer\'s name, as the server should see it.',
          example: 'LAPTOP-01',
        ),
        _switch(
          'disableRetryRequest',
          'Don\'t finish the handshake',
          'Keep the server\'s 401 challenge instead of answering it.',
          help:
              'NTLM needs a second request to answer the challenge; turn this '
              'on only to inspect the challenge.',
          example: 'WWW-Authenticate: NTLM TlRMTVNTUAAC…',
        ),
      ],
    ),
  ];

  // ---- Hawk ----

  List<Widget> _hawk() => [
    _text(
      'authId',
      'Hawk Auth ID',
      help: 'The key identifier the server gave you.',
      example: 'dh37fgj492je',
    ),
    _text(
      'authKey',
      'Hawk Auth Key',
      secret: true,
      help: 'The shared key that signs requests.',
      example: '{{hawkKey}}',
    ),
    AuthDropdown(
      label: 'Algorithm',
      value: _p('algorithm', 'sha256'),
      options: const [
        AuthOption('sha256', 'SHA256'),
        AuthOption('sha1', 'SHA1'),
      ],
      onChanged: (v) => _setP('algorithm', v),
      help: 'The MAC hash; it must match the server\'s credentials.',
      example: 'sha256',
    ),
    AuthAdvanced(
      children: [
        _text(
          'user',
          'User',
          help: 'A user name kept with the credentials (not sent).',
          example: 'Steve',
        ),
        _text(
          'nonce',
          'Nonce',
          help: 'Empty generates one per request.',
          example: 'j4h3g2',
        ),
        _text(
          'extraData',
          'ext',
          help: 'Application data sent and signed with the request.',
          example: 'some-app-ext-data',
        ),
        _text('app', 'app', help: 'Oz application ID.', example: 'app-1'),
        _text(
          'delegation',
          'dlg',
          help: 'Oz delegated-by application ID.',
          example: 'app-0',
        ),
        _text(
          'timestamp',
          'Timestamp',
          help: 'Seconds since 1970. Empty uses the current time.',
          example: '1353832234',
        ),
        _switch(
          'includePayloadHash',
          'Include payload hash',
          'Signs the body and content type as well.',
          help: 'Adds hash="…" so the server can verify the body.',
          example: 'hash="Yi9LfIIFRtBEPt74PVmbTF/xVAwPn7ub15ePICfgnuY="',
        ),
      ],
    ),
  ];

  // ---- Akamai EdgeGrid ----

  List<Widget> _edgegrid() => [
    _text(
      'accessToken',
      'Access token',
      help: 'access_token from your .edgerc section.',
      example: 'akab-access-token-xxx-xxxxxxxxxxxxxxxx',
    ),
    _text(
      'clientToken',
      'Client token',
      help: 'client_token from your .edgerc section.',
      example: 'akab-client-token-xxx-xxxxxxxxxxxxxxxx',
    ),
    _text(
      'clientSecret',
      'Client secret',
      secret: true,
      help: 'client_secret from your .edgerc section.',
      example: '{{edgegridSecret}}',
    ),
    AuthAdvanced(
      children: [
        _text(
          'nonce',
          'Nonce',
          help: 'Empty generates a UUID per request.',
          example: 'nonce-xx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',
        ),
        _text(
          'timestamp',
          'Timestamp',
          help: 'Empty uses the current time.',
          example: '20140321T19:34:21+0000',
        ),
        _text(
          'baseURL',
          'Base URL',
          help:
              'The host from your .edgerc, kept for reference and Postman '
              'exports. The request URL\'s host is what gets signed.',
          example: 'https://akab-xxxx.luna.akamaiapis.net',
        ),
        _text(
          'headersToSign',
          'Headers to sign',
          help: 'Comma-separated header names included in the signature.',
          example: 'X-Custom-Header, X-Other',
        ),
      ],
    ),
  ];

  // ---- JWT ----

  List<Widget> _jwt() {
    final alg = _p('algorithm', 'HS256');
    final hmac = alg.startsWith('HS');
    final inHeader = _p('addTokenTo', 'header') != 'queryParam';
    return [
      AuthSegmented(
        label: 'Add JWT token to',
        value: inHeader ? 'header' : 'queryParam',
        options: const [
          AuthOption('header', 'Request header'),
          AuthOption('queryParam', 'Query param'),
        ],
        onChanged: (v) => _setPAndRebuild('addTokenTo', v),
        help: 'Where the signed token goes.',
        example: 'Authorization: Bearer eyJhbGciOi…',
      ),
      AuthDropdown(
        label: 'Algorithm',
        value: alg,
        options: [
          for (final a in JwtAuth.algorithms)
            AuthOption(a, a, switch (a.substring(0, 2)) {
              'HS' => 'HMAC with a shared secret.',
              'RS' => 'RSA PKCS#1 v1.5 with a private key.',
              'PS' => 'RSA-PSS with a private key.',
              _ => 'ECDSA with a P-256, P-384 or P-521 key.',
            }),
        ],
        onChanged: (v) => _setPAndRebuild('algorithm', v),
        help: 'How the token is signed; the server must expect the same.',
        example: 'HS256',
      ),
      if (hmac) ...[
        _text(
          'secret',
          'Secret',
          secret: true,
          help: 'The shared HMAC secret.',
          example: 'your-256-bit-secret',
        ),
        _switch(
          'isSecretBase64Encoded',
          'Secret Base64 encoded',
          'Decode the secret from base64 before signing.',
          help: 'Turn on when the provider gives the secret as base64.',
          example: 'c2VjcmV0IGJ5dGVz',
        ),
      ] else
        _text(
          'privateKey',
          'Private key',
          secret: true,
          multiline: true,
          mono: true,
          help:
              'An unencrypted PEM key: RSA for RS/PS (PKCS#1 or PKCS#8), EC '
              'for ES (SEC1 or PKCS#8) on the matching curve.',
          example: '-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMG…',
        ),
      _text(
        'payload',
        'Payload',
        multiline: true,
        mono: true,
        hint: '{"sub": "1234567890", "iat": {{\$timestamp}}}',
        help:
            'The claims as a JSON object. {{variables}} are filled in first, '
            'so {{\$timestamp}} gives a fresh iat.',
        example: '{"sub": "1234567890", "name": "John Doe"}',
      ),
      AuthAdvanced(
        children: [
          if (inHeader)
            _text(
              'headerPrefix',
              'Request header prefix',
              fallback: 'Bearer',
              help: 'Written before the token. Empty sends the token alone.',
              example: 'Bearer',
            )
          else
            _text(
              'queryParamKey',
              'Query param name',
              fallback: 'token',
              help: 'The query parameter that carries the token.',
              example: 'token',
            ),
          _text(
            'header',
            'JWT headers',
            multiline: true,
            mono: true,
            hint: '{"kid": "key-1"}',
            help:
                'Extra JOSE header fields as JSON. alg and typ are set for '
                'you.',
            example: '{"kid": "2024-01"}',
          ),
        ],
      ),
    ];
  }

  // ---- texts ----

  static String? _about(AuthType t) => switch (t) {
    AuthType.oauth2 =>
      'Get a token with one of the OAuth 2.0 grants; it is then added to '
          'every request. Expired tokens are refreshed on send when there '
          'is a refresh token, and client credentials or password tokens '
          'are fetched by themselves.',
    AuthType.oauth1 =>
      'Each request is signed with your consumer and token secrets (RFC '
          '5849). The timestamp and nonce are new for every request unless '
          'set under Advanced.',
    AuthType.digest =>
      'The first request goes out without credentials and the server\'s '
          '401 challenge is answered automatically. Only a hash of the '
          'password is sent.',
    AuthType.awsV4 =>
      'Signs the request with AWS Signature Version 4, covering the '
          'method, URL, headers and the exact body.',
    AuthType.ntlm =>
      'Windows NTLMv2: a three-step handshake on one connection, done '
          'automatically when you send.',
    AuthType.hawk =>
      'Signs each request with a Hawk MAC made from your key, the time and '
          'a nonce.',
    AuthType.edgegrid =>
      'Signs requests to Akamai APIs with the credentials from your .edgerc '
          'file.',
    AuthType.jwt =>
      'Builds and signs a JSON Web Token on every send, from the payload '
          'below.',
    _ => null,
  };

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
        AuthType.oauth2 => (
          message:
              'Sign in with an OAuth 2.0 provider (Google, Azure AD, Auth0, '
              'Keycloak, …) and send the access token.',
          example: 'Authorization: Bearer ya29.a0Af…',
        ),
        AuthType.oauth1 => (
          message: 'Signs each request with OAuth 1.0a, as X (Twitter) uses.',
          example: 'Authorization: OAuth oauth_consumer_key="…", …',
        ),
        AuthType.digest => (
          message:
              'Username and password with a challenge-response hash instead '
              'of sending the password.',
          example: 'Authorization: Digest username="ada", response="…"',
        ),
        AuthType.awsV4 => (
          message: 'Signs requests to AWS services and API Gateway.',
          example: 'Authorization: AWS4-HMAC-SHA256 Credential=AKIA…',
        ),
        AuthType.ntlm => (
          message: 'Windows authentication for IIS and SharePoint servers.',
          example: 'Authorization: NTLM TlRMTVNTUAAD…',
        ),
        AuthType.hawk => (
          message: 'Signs requests with a shared Hawk key.',
          example: 'Authorization: Hawk id="…", ts="…", mac="…"',
        ),
        AuthType.edgegrid => (
          message: 'Signs requests to Akamai {OPEN} APIs.',
          example: 'Authorization: EG1-HMAC-SHA256 client_token=…',
        ),
        AuthType.jwt => (
          message: 'Signs a JWT from your claims and sends it as a bearer.',
          example: 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9…',
        ),
      };
}
