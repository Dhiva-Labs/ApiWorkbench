import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/services/auth/oauth2_redirect.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OAuth loopback listener', () {
    Future<(int, String)> hit(
      Uri url, {
      String method = 'GET',
      Map<String, String> headers = const {},
      String body = '',
    }) async {
      final client = HttpClient();
      try {
        final req = await client.openUrl(method, url);
        headers.forEach(req.headers.set);
        if (body.isNotEmpty) req.write(body);
        final res = await req.close();
        return (res.statusCode, await utf8.decoder.bind(res).join());
      } finally {
        client.close(force: true);
      }
    }

    Future<LoopbackRedirectListener> listen() async {
      final l = await LoopbackRedirectListener.start(
        'http://127.0.0.1/callback',
        state: 'st-1',
      );
      addTearDown(l.close);
      return l;
    }

    Future<bool> completesSoon(LoopbackRedirectListener l) async {
      var done = false;
      unawaited(l.result.then((_) => done = true, onError: (_) {}));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      return done;
    }

    Uri callback(LoopbackRedirectListener l, Map<String, String> q) =>
        l.redirectUri.replace(queryParameters: q);

    Uri fragmentUrl(LoopbackRedirectListener l) =>
        l.redirectUri.replace(path: '/__apiworkbench/fragment', query: '');

    test(
      'an answer with another state is ignored; the real one wins',
      () async {
        final l = await listen();
        final (s1, page) = await hit(
          callback(l, {'code': 'evil', 'state': 'x'}),
        );
        expect(s1, 200);
        expect(page, contains('ignored'));
        final (s2, _) = await hit(callback(l, {'error': 'access_denied'}));
        expect(s2, 200);
        expect(await completesSoon(l), isFalse);

        // The provider's redirect: a cross-site top-level navigation.
        final (s3, ok) = await hit(
          callback(l, {'code': 'good', 'state': 'st-1'}),
          headers: {
            'sec-fetch-site': 'cross-site',
            'sec-fetch-mode': 'navigate',
            'sec-fetch-dest': 'document',
          },
        );
        expect(s3, 200);
        expect(ok, contains('Signed in'));
        final got = await l.result;
        expect(got.queryParameters['code'], 'good');
      },
    );

    test('requests other pages make in the background are refused', () async {
      final l = await listen();
      final answer = {'code': 'c', 'state': 'st-1'};
      for (final headers in [
        {'origin': 'https://evil.example'},
        {'sec-fetch-mode': 'no-cors', 'sec-fetch-site': 'cross-site'},
        {'sec-fetch-mode': 'navigate', 'sec-fetch-dest': 'iframe'},
      ]) {
        final (status, _) = await hit(callback(l, answer), headers: headers);
        expect(status, 403, reason: '$headers');
      }
      for (final headers in [
        {'origin': 'https://evil.example'},
        {'origin': 'null'},
        {'sec-fetch-site': 'cross-site'},
      ]) {
        final (status, _) = await hit(
          fragmentUrl(l),
          method: 'POST',
          headers: headers,
          body: 'access_token=t&state=st-1',
        );
        expect(status, 403, reason: '$headers');
      }
      expect(await completesSoon(l), isFalse);
    });

    test('the fragment post from its own page completes the sign-in', () async {
      final l = await listen();
      final own = 'http://127.0.0.1:${l.redirectUri.port}';
      final (wrong, _) = await hit(
        fragmentUrl(l),
        method: 'POST',
        headers: {'origin': own, 'sec-fetch-site': 'same-origin'},
        body: 'access_token=t&state=nope',
      );
      expect(wrong, 409);
      expect(await completesSoon(l), isFalse);

      final (status, _) = await hit(
        fragmentUrl(l),
        method: 'POST',
        headers: {'origin': own, 'sec-fetch-site': 'same-origin'},
        body: 'access_token=t&state=st-1',
      );
      expect(status, 204);
      expect((await l.result).fragment, contains('access_token=t'));
    });

    test('a fixed state value is called out', () async {
      final fixed = await LoopbackRedirectListener.start(
        'https://example.com/cb',
        state: 'always-the-same',
        stateIsFixed: true,
      );
      addTearDown(fixed.close);
      expect(fixed.stateWarning, contains('fixed state'));
      expect(fixed.note, contains('fixed state'));
      expect(fixed.note, contains('not a loopback'));

      final random = await listen();
      expect(random.stateWarning, isNull);
    });
  });
}
