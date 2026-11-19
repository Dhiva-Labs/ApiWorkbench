/// Where credentials sit in the saved JSON documents, and how they are taken
/// out before a document is written and put back after it is read
/// (issue #61).
///
/// The models keep every secret in memory, so import, export, auth and the
/// editors see them as before. Only the copies written to the data folder
/// lose them: [SecretDoc.extract] moves each secret into a flat map keyed by
/// a stable path (collection, request, folder and certificate ids, variable
/// and header names), which goes to the keychain, and [SecretDoc.fill] puts
/// the values back into a document that was just read.
///
/// Pure Dart, no Flutter, so the command-line runner could use it too.
library;

/// [AuthConfig.params] keys that hold secrets, whatever the auth type.
const secretAuthParams = {
  'accessToken',
  'refreshToken',
  'idToken',
  'savedTokens',
  'clientSecret',
  'clientToken',
  'password',
  'consumerSecret',
  'token',
  'tokenSecret',
  'privateKey',
  'secretKey',
  'sessionToken',
  'authKey',
  'secret',
  'code_verifier',
  'passphrase',
  'headerSecret',
};

/// Request headers (lower case) whose values are credentials.
const credentialHeaders = {
  'authorization',
  'proxy-authorization',
  'cookie',
  'x-api-key',
  'api-key',
  'apikey',
  'x-auth-token',
  'x-access-token',
  'x-amz-security-token',
};

/// Whether a request header named [name] carries a credential.
bool isCredentialHeader(String name) =>
    credentialHeaders.contains(name.trim().toLowerCase());

/// Keys of a request's protocol settings that hold credentials: the MQTT
/// password and the Socket.IO auth payload.
const _secretProtocolKeys = {'password', 'auth'};

/// One saved document and the walk that finds its secrets.
enum SecretDoc {
  /// collections.json: a list of collections.
  collections('collections'),

  /// environments.json: `{environments: [...], activeId}`.
  environments('environments'),

  /// globals.json: a list of variables.
  globals('globals'),

  /// settings.json: proxy password and client certificate passphrases.
  settings('settings');

  const SecretDoc(this.entry);

  /// The name of this document's entry in the secret store.
  final String entry;

  /// Removes the secrets from [json] (in place; pass a copy of anything
  /// that shares maps with live models, see [deepCopyJson]) and returns
  /// them by path.
  Map<String, String> extract(Object? json) {
    final v = _Extract();
    _walk(json, v);
    return v.out;
  }

  /// Puts [secrets] back into [json], in place, wherever the document has
  /// an empty field at that path. Returns true when [json] still carried a
  /// secret of its own (a file from before the keychain, or one written by
  /// an older version): that value is kept, and the document should be
  /// saved again to move it out.
  bool fill(Object? json, Map<String, String> secrets) {
    final v = _Fill(secrets);
    _walk(json, v);
    return v.found;
  }

  void _walk(Object? json, _Visitor v) {
    switch (this) {
      case SecretDoc.collections:
        if (json is List) _collections(json, v);
      case SecretDoc.environments:
        if (json is Map) {
          final envs = json['environments'];
          if (envs is! List) return;
          final seen = <String, int>{};
          for (final e in envs) {
            if (e is! Map) continue;
            final p = 'e/${_slot(seen, e['id'])}';
            _vars(e['variables'], '$p/var', v);
          }
        }
      case SecretDoc.globals:
        _vars(json, 'g', v);
      case SecretDoc.settings:
        if (json is! Map) return;
        final net = json['network'];
        if (net is! Map) return;
        v.field(net, 'proxyPassword', 'net/proxyPassword', optional: true);
        final certs = net['clientCerts'];
        if (certs is! List) return;
        final seen = <String, int>{};
        for (final c in certs) {
          if (c is! Map) continue;
          final p = 'net/cert/${_slot(seen, c['id'])}';
          v.field(c, 'passphrase', '$p/passphrase', optional: true);
        }
    }
  }
}

/// Secrets of one collection's JSON, keyed as [SecretDoc.collections] keys
/// them. Used to carry a live collection's secrets into a restored
/// snapshot.
Map<String, String> collectionSecrets(Map<String, dynamic> collectionJson) {
  final v = _Extract();
  _collections([deepCopyJson(collectionJson)], v);
  return v.out;
}

/// [collectionJson] (a copy) without its secrets: what a version history
/// snapshot keeps.
Map<String, dynamic> withoutSecrets(Map<String, dynamic> collectionJson) {
  final copy = deepCopyJson(collectionJson) as Map<String, dynamic>;
  _collections([copy], _Extract());
  return copy;
}

/// Fills empty secret fields of [collectionJson] (in place) from
/// [secrets], as returned by [collectionSecrets].
void fillCollection(
  Map<String, dynamic> collectionJson,
  Map<String, String> secrets,
) => _collections([collectionJson], _Fill(secrets));

/// Removes credentials from one saved request history entry's request JSON,
/// in place: auth secrets, credential headers, protocol passwords, and any
/// of [knownSecrets] (secret variable values and the like) that were typed
/// into the URL, a parameter, a header or the body. Returns true when it
/// changed anything. The request keeps everything else, so it can still be
/// opened again and pointed at its auth.
bool scrubHistoryRequest(
  Map<String, dynamic> request,
  Iterable<String> knownSecrets,
) {
  final v = _Extract();
  _request(request, 'h', v);
  var changed = v.out.values.any((s) => s.isNotEmpty);
  // A row whose value is a secret is blanked whatever its length; inside
  // longer text only values of [_minScrubbed] characters or more are cut
  // out, so a short one ("admin", "true") does not cut into a path.
  final exact = {
    for (final s in knownSecrets)
      if (s.isNotEmpty) s,
  };
  final values = [
    for (final s in exact)
      if (s.length >= _minScrubbed) s,
  ]..sort((a, b) => b.length.compareTo(a.length));
  if (exact.isEmpty) return changed;
  String strip(String text) {
    var out = text;
    for (final s in values) {
      if (out.contains(s)) out = out.replaceAll(s, '');
    }
    return out;
  }

  for (final key in ['url', 'body', 'graphqlVariables']) {
    final text = request[key];
    if (text is! String || text.isEmpty) continue;
    final next = strip(text);
    if (next != text) {
      request[key] = next;
      changed = true;
    }
  }
  for (final list in ['params', 'pathVariables', 'headers', 'formFields']) {
    final rows = request[list];
    if (rows is! List) continue;
    for (final row in rows) {
      if (row is! Map) continue;
      final value = row['v'];
      if (value is! String || value.isEmpty) continue;
      if (exact.contains(value) || values.any(value.contains)) {
        row['v'] = '';
        changed = true;
      }
    }
  }
  return changed;
}

/// The shortest secret cut out of longer history text.
const _minScrubbed = 8;

/// A copy of decoded JSON that shares no map or list with [json]. Model
/// `toJson` methods hand out some live maps (auth params, protocol
/// settings), which must not be edited in place.
Object? deepCopyJson(Object? json) => switch (json) {
  Map() => <String, dynamic>{
    for (final e in json.entries) '${e.key}': deepCopyJson(e.value),
  },
  List() => [for (final e in json) deepCopyJson(e)],
  _ => json,
};

/// Walks a list of collection JSON objects.
void _collections(List<dynamic> json, _Visitor v) {
  final seen = <String, int>{};
  for (final c in json) {
    if (c is! Map) continue;
    final p = 'c/${_slot(seen, c['id'])}';
    final auth = c['auth'];
    if (auth is Map) _auth(auth, '$p/auth', v);
    _vars(c['variables'], '$p/var', v);
    final folders = c['folders'];
    if (folders is Map) {
      for (final e in folders.entries) {
        final f = e.value;
        if (f is! Map) continue;
        final fa = f['auth'];
        if (fa is Map) _auth(fa, '$p/f/${_enc('${e.key}')}/auth', v);
      }
    }
    final requests = c['requests'];
    if (requests is List) {
      final rs = <String, int>{};
      for (final r in requests) {
        if (r is Map) _request(r, '$p/r/${_slot(rs, r['id'])}', v);
      }
    }
  }
}

void _request(Map<dynamic, dynamic> r, String p, _Visitor v) {
  // A request keeps its auth fields at the top level (AuthConfig.toJson
  // spread into the request).
  _auth(r, '$p/a', v);
  final headers = r['headers'];
  if (headers is List) {
    final seen = <String, int>{};
    for (final h in headers) {
      if (h is! Map) continue;
      final name = h['k'];
      if (name is! String || !isCredentialHeader(name)) continue;
      v.field(h, 'v', '$p/h/${_slot(seen, name.trim().toLowerCase())}');
    }
  }
  final proto = r['protocol'];
  if (proto is Map) {
    for (final k in _secretProtocolKeys) {
      if (proto[k] is String) v.field(proto, k, '$p/proto/$k');
    }
  }
  final examples = r['examples'];
  if (examples is List) {
    final seen = <String, int>{};
    for (final e in examples) {
      if (e is! Map) continue;
      final req = e['request'];
      if (req is Map) _request(req, '$p/ex/${_slot(seen, e['id'])}', v);
    }
  }
}

void _auth(Map<dynamic, dynamic> a, String p, _Visitor v) {
  for (final k in const ['bearerToken', 'basicPassword', 'apiKeyValue']) {
    v.field(a, k, '$p/$k');
  }
  final params = a['authParams'];
  if (params is Map) {
    for (final k in secretAuthParams) {
      if (params.containsKey(k)) v.field(params, k, '$p/ap/$k');
    }
  }
}

/// Variables (KV rows): the initial and current values of secret ones.
void _vars(Object? rows, String p, _Visitor v) {
  if (rows is! List) return;
  final seen = <String, int>{};
  for (final kv in rows) {
    if (kv is! Map || kv['s'] != true) continue;
    final slot = '$p/${_slot(seen, kv['k'])}';
    v.field(kv, 'v', '$slot/v');
    // Null "current" means "same as initial", so it is removed rather than
    // emptied.
    v.field(kv, 'c', '$slot/c', optional: true);
  }
}

String _enc(String s) => Uri.encodeComponent(s);

/// [id] made safe for a path, numbered when it repeats in one list (an
/// imported file may reuse ids). `#` is always encoded by [_enc], so a
/// numbered slot never collides with an id.
String _slot(Map<String, int> seen, Object? id) {
  final key = '${id ?? ''}';
  final n = seen.update(key, (c) => c + 1, ifAbsent: () => 0);
  return n == 0 ? _enc(key) : '${_enc(key)}#$n';
}

abstract class _Visitor {
  /// Handles the secret at `m[key]`. Required fields are always written
  /// and empty when unset; [optional] ones are left out instead.
  void field(
    Map<dynamic, dynamic> m,
    String key,
    String path, {
    bool optional = false,
  });
}

class _Extract implements _Visitor {
  final out = <String, String>{};

  @override
  void field(
    Map<dynamic, dynamic> m,
    String key,
    String path, {
    bool optional = false,
  }) {
    final value = m[key];
    if (value is! String) return;
    if (optional) {
      out[path] = value;
      m.remove(key);
    } else if (value.isNotEmpty) {
      out[path] = value;
      m[key] = '';
    }
  }
}

class _Fill implements _Visitor {
  _Fill(this.secrets);
  final Map<String, String> secrets;
  bool found = false;

  @override
  void field(
    Map<dynamic, dynamic> m,
    String key,
    String path, {
    bool optional = false,
  }) {
    final value = m[key];
    if (value is String && value.isNotEmpty) {
      found = true; // a secret still in the file: it wins, and moves out
      return;
    }
    if (optional && m.containsKey(key)) return;
    final s = secrets[path];
    if (s != null) m[key] = s;
  }
}
