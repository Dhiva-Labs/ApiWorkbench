import 'dart:convert';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/secret_fields.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/secret_fixtures.dart';

/// Every fixture secret found in [json].
List<String> leaked(Object? json) {
  final text = jsonEncode(json);
  return [
    for (final s in fixtureSecrets)
      if (text.contains(s)) s,
  ];
}

void main() {
  group('extract and fill', () {
    test('collections lose every credential and get them back', () {
      final json = [secretCollection().toJson()];
      final original = jsonEncode(json);
      final copy = deepCopyJson(json);
      final secrets = SecretDoc.collections.extract(copy);

      expect(leaked(copy), isEmpty);
      final text = jsonEncode(copy);
      for (final plain in fixturePlain.take(3)) {
        expect(text, contains(plain));
      }
      expect(text, contains('client-id-public'));
      // Nothing of a model's live maps was touched.
      expect(jsonEncode(json), original);

      final again = jsonDecode(jsonEncode(copy));
      expect(SecretDoc.collections.fill(again, secrets), isFalse);
      expect(jsonEncode(again), original);
    });

    test('the live model is not changed by extracting from its JSON', () {
      final c = secretCollection();
      SecretDoc.collections.extract(deepCopyJson([c.toJson()]));
      expect(c.requests.first.auth.params['accessToken'], 'oauth-access-0003');
      expect(c.requests[1].protocolConfig['password'], 'mqtt-pass-0007');
    });

    test('environments, globals and settings round trip', () {
      final docs = {
        SecretDoc.environments: {
          'environments': [secretEnvironment().toJson()],
          'activeId': 'env-1',
        },
        SecretDoc.globals: [for (final g in secretGlobals()) g.toJson()],
        SecretDoc.settings: secretSettings().toJson(),
      };
      for (final MapEntry(key: doc, value: json) in docs.entries) {
        final original = jsonEncode(json);
        final copy = deepCopyJson(json);
        final secrets = doc.extract(copy);
        expect(secrets, isNotEmpty, reason: doc.name);
        expect(leaked(copy), isEmpty, reason: doc.name);
        final again = jsonDecode(jsonEncode(copy));
        doc.fill(again, secrets);
        // Optional fields come back last; the content is the same.
        expect(again, jsonDecode(original), reason: doc.name);
      }
    });

    test('a secret variable without a current value stays without one', () {
      final json = [KV(key: 'k', value: 'only-initial', secret: true).toJson()];
      final copy = deepCopyJson(json);
      final secrets = SecretDoc.globals.extract(copy);
      final again = jsonDecode(jsonEncode(copy));
      SecretDoc.globals.fill(again, secrets);
      final kv = KV.fromJson((again as List).single as Map<String, dynamic>);
      expect(kv.value, 'only-initial');
      expect(kv.current, isNull);
    });

    test('repeated ids and header names keep their own values', () {
      final json = [
        CollectionModel(
          id: 'c',
          name: 'Dup',
          requests: [
            RequestModel(
              id: 'same',
              bearerToken: 'first-token',
              headers: [
                KV(key: 'Authorization', value: 'one'),
                KV(key: 'authorization', value: 'two'),
              ],
            ),
            RequestModel(id: 'same', bearerToken: 'second-token'),
          ],
        ).toJson(),
      ];
      final original = jsonEncode(json);
      final copy = deepCopyJson(json);
      final secrets = SecretDoc.collections.extract(copy);
      expect(secrets, hasLength(4));
      final again = jsonDecode(jsonEncode(copy));
      SecretDoc.collections.fill(again, secrets);
      expect(jsonEncode(again), original);
    });

    test('a value still in the file wins and is reported', () {
      final json = [secretCollection().toJson()];
      final found = SecretDoc.collections.fill(json, {
        'c/col-1/auth/bearerToken': 'stale',
      });
      expect(found, isTrue);
      expect((json.single['auth'] as Map)['bearerToken'], 'col-bearer-0001');
    });
  });

  group('history entries', () {
    test('lose auth secrets and credential headers', () {
      final r = secretCollection().requests.first.toJson();
      expect(scrubHistoryRequest(r, const []), isTrue);
      expect(leaked(r), isEmpty);
      final back = RequestModel.fromJson(r);
      expect(back.url, 'https://api.example.com/orders');
      expect(back.authType, AuthType.oauth2);
      expect(back.auth.params['clientId'], 'client-id-public');
      expect(back.headers.map((h) => h.key), [
        'Authorization',
        'Cookie',
        'X-Trace',
      ]);
      expect(back.headers.last.value, 'keep-me-header');
    });

    test('lose secret values typed into the url, params and body', () {
      final r = RequestModel(
        url: 'https://x.example.com/admin?key=env-current-0012',
        params: [
          KV(key: 'key', value: 'env-current-0012'),
          KV(key: 'user', value: 'admin'),
        ],
        body: '{"password": "env-current-0012", "role": "admin"}',
      ).toJson();
      expect(
        scrubHistoryRequest(r, const ['env-current-0012', 'admin']),
        isTrue,
      );
      expect(jsonEncode(r), isNot(contains('env-current-0012')));
      // A short secret blanks a row that is exactly it, and nothing else.
      expect(r['url'], 'https://x.example.com/admin?key=');
      expect(r['body'], '{"password": "", "role": "admin"}');
      expect((r['params'] as List).last['v'], '');
    });

    test('an entry without credentials is unchanged', () {
      final r = RequestModel(url: 'https://x.example.com').toJson();
      final before = jsonEncode(r);
      expect(scrubHistoryRequest(r, const ['unrelated']), isFalse);
      expect(jsonEncode(r), before);
    });
  });

  group('version history snapshots', () {
    test('keep no secrets, and a live collection lends its own back', () {
      final c = secretCollection();
      final snap = withoutSecrets(c.toJson());
      expect(leaked(snap), isEmpty);
      final restored = jsonDecode(jsonEncode(snap)) as Map<String, dynamic>;
      fillCollection(restored, collectionSecrets(c.toJson()));
      expect(jsonEncode(restored), jsonEncode(c.toJson()));
    });
  });
}
