import '../models/models.dart';

/// Auth attributes that hold a credential, per type, as Postman names
/// them ([AuthConfig.params]). Bearer, Basic and API key keep theirs in
/// dedicated fields: the token, the password and the key value.
const secretAuthParamsByType = <AuthType, Set<String>>{
  AuthType.oauth2: {'clientSecret', 'password', 'code_verifier'},
  AuthType.oauth1: {'consumerSecret', 'token', 'tokenSecret', 'privateKey'},
  AuthType.digest: {'password'},
  AuthType.awsV4: {'secretKey', 'sessionToken'},
  AuthType.ntlm: {'password'},
  AuthType.hawk: {'authKey'},
  AuthType.edgegrid: {'accessToken', 'clientToken', 'clientSecret'},
  AuthType.jwt: {'secret', 'privateKey'},
};

/// The OAuth 2.0 tokens currently in use, and the list of tokens saved
/// earlier. Left out (not emptied) with the secrets: no token means "get a
/// new one" after an import. `tokenType` and `expiresAt` describe the
/// access token and go with it.
const liveOAuth2TokenParams = {
  'accessToken',
  'refreshToken',
  'idToken',
  'id_token',
  'savedTokens',
};

/// A value that is only a `{{variable}}`, or nothing: no secret in it.
final _onlyVariable = RegExp(r'^\s*(\{\{[^{}]+\}\}\s*)?$');

/// Every attribute name that holds a credential for some auth type. An
/// auth keeps the attributes of a type it used before, so these are left
/// out whatever its type is now.
final _anySecretParam = {
  for (final keys in secretAuthParamsByType.values) ...keys,
};

/// A copy of [a] without its credentials and live tokens, and how many
/// values were left out (the live OAuth 2.0 tokens count once).
///
/// Credential fields stay, empty, so a file written from the copy still
/// imports as working auth that only needs its secrets filled in. Values
/// that only name a variable (`{{token}}`) hold no secret and are kept.
(AuthConfig, int) withoutAuthSecrets(AuthConfig a) {
  var leftOut = 0;
  String secret(String value) {
    if (_onlyVariable.hasMatch(value)) return value;
    leftOut++;
    return '';
  }

  final out = a.clone()
    ..bearerToken = secret(a.bearerToken)
    ..basicPassword = secret(a.basicPassword)
    ..apiKeyValue = secret(a.apiKeyValue)
    ..params = {};
  final own = secretAuthParamsByType[a.type] ?? const <String>{};
  bool literal(String key) => !_onlyVariable.hasMatch(a.params[key] ?? '');
  bool isToken(String key) =>
      liveOAuth2TokenParams.contains(key) && !own.contains(key);
  final accessTokenDropped = isToken('accessToken') && literal('accessToken');
  var tokenDropped = false;
  for (final e in a.params.entries) {
    if (isToken(e.key) && literal(e.key)) {
      tokenDropped = true;
    } else if (accessTokenDropped &&
        (e.key == 'tokenType' || e.key == 'expiresAt')) {
      // They describe the access token that was left out.
    } else if (own.contains(e.key) || _anySecretParam.contains(e.key)) {
      out.params[e.key] = secret(e.value);
    } else {
      out.params[e.key] = e.value;
    }
  }
  if (tokenDropped) leftOut++;
  return (out, leftOut);
}

/// What an export says when it left [count] secrets out.
String secretsLeftOutNote(int count) =>
    '$count password(s), key(s) or token(s) in auth settings were left '
    'out; their fields are empty in the file. Include secrets to keep '
    'them.';
