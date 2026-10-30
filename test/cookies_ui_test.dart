import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/theme.dart';
import 'package:api_workbench/ui/cookies_dialog.dart';
import 'package:api_workbench/ui/response/cookies_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  group('cookie manager and Cookies tab', () {
    late Directory dir;
    late AppState state;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('aw_ckui_');
    });
    tearDown(() async {
      state.dispose();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    Future<void> pumpApp(
      WidgetTester tester,
      Size size,
      Widget Function(BuildContext) body,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      state = AppState(storage: Storage(overrideDir: dir));
      state.cookies.saveDelay = const Duration(days: 1);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            theme: buildTheme(),
            home: Builder(builder: (c) => Scaffold(body: body(c))),
          ),
        ),
      );
      await tester.pump();
    }

    void fill() {
      final jar = state.cookies;
      jar.saveFromResponse(Uri.parse('https://api.example.com/v1/login'), [
        'session=abcdef0123456789abcdef0123456789abcdef0123456789; HttpOnly; Secure; SameSite=Lax',
        'theme=dark; Domain=example.com; Path=/; Max-Age=86400',
        'very_long_cookie_name_for_overflow_checks=${'x' * 200}; Path=/v1',
      ]);
      jar.saveFromResponse(Uri.parse('http://localhost:3000/'), ['dev=1']);
      jar.saveFromResponse(Uri.parse('https://shop.test/'), ['cart=3']);
    }

    for (final size in [const Size(360, 640), const Size(1280, 800)]) {
      testWidgets(
        'manager lists domains and cookies at ${size.width.toInt()}',
        (tester) async {
          await pumpApp(
            tester,
            size,
            (c) => TextButton(
              onPressed: () => showCookieManager(c),
              child: const Text('open'),
            ),
          );
          fill();
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();

          expect(find.text('Cookies'), findsWidgets);
          // (Wide layouts also show the first domain's name as a heading.)
          expect(find.text('api.example.com'), findsWidgets);
          expect(find.text('localhost'), findsOneWidget);
          expect(find.text('shop.test'), findsOneWidget);

          // Select a domain (phones switch to its cookie list).
          await tester.tap(find.text('api.example.com').first);
          await tester.pumpAndSettle();
          expect(find.text('session'), findsOneWidget);
          expect(find.text('HttpOnly'), findsWidgets);
          expect(find.text('Secure'), findsWidgets);
          expect(tester.takeException(), isNull);
          await tester.runAsync(() => state.cookies.flush());
        },
      );
    }

    testWidgets('manager can search, add, edit, delete and clear', (
      tester,
    ) async {
      await pumpApp(
        tester,
        const Size(1280, 800),
        (c) => TextButton(
          onPressed: () => showCookieManager(c),
          child: const Text('open'),
        ),
      );
      fill();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Search narrows the domain list.
      await tester.enterText(find.byKey(const Key('cookie-search')), 'shop');
      await tester.pumpAndSettle();
      expect(find.text('shop.test'), findsWidgets);
      expect(find.text('api.example.com'), findsNothing);
      await tester.enterText(find.byKey(const Key('cookie-search')), '');
      await tester.pumpAndSettle();

      // Add a cookie.
      await tester.tap(find.byKey(const Key('cookie-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('cookie-domain')),
        'added.test',
      );
      await tester.enterText(
        find.byKey(const Key('cookie-line')),
        'token=xyz; Path=/; Secure',
      );
      await tester.tap(find.byKey(const Key('cookie-save')));
      await tester.pumpAndSettle();
      final added = state.cookies.cookiesIn('added.test').single;
      expect(added.value, 'xyz');
      expect(added.secure, isTrue);
      expect(find.text('added.test'), findsWidgets);

      // Invalid input shows an error and keeps the form open.
      await tester.tap(find.byKey(const Key('cookie-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('cookie-line')), 'junk');
      await tester.tap(find.byKey(const Key('cookie-save')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Expected name=value'), findsOneWidget);
      await tester.tap(find.byKey(const Key('cookie-cancel')));
      await tester.pumpAndSettle();

      // Edit the added cookie.
      await tester.tap(find.byKey(const Key('cookie-edit-token')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('cookie-line')),
        'token=changed; Path=/',
      );
      await tester.tap(find.byKey(const Key('cookie-save')));
      await tester.pumpAndSettle();
      expect(state.cookies.cookiesIn('added.test').single.value, 'changed');

      // Delete it.
      await tester.tap(find.byKey(const Key('cookie-delete-token')));
      await tester.pumpAndSettle();
      expect(state.cookies.cookiesIn('added.test'), isEmpty);

      // Clear a domain, after confirming.
      await tester.tap(find.text('shop.test'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cookie-clear-domain')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cookie-confirm')));
      await tester.pumpAndSettle();
      expect(state.cookies.cookiesIn('shop.test'), isEmpty);

      // Clear everything.
      await tester.tap(find.byKey(const Key('cookie-clear-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cookie-confirm')));
      await tester.pumpAndSettle();
      expect(state.cookies.count, 0);
      expect(find.textContaining('No cookies'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() => state.cookies.flush());
    });

    for (final size in [const Size(360, 640), const Size(1280, 800)]) {
      testWidgets('response Cookies tab at ${size.width.toInt()}', (
        tester,
      ) async {
        late ResponseData res;
        await pumpApp(tester, size, (c) {
          res = ResponseData(
            statusCode: 200,
            finalUrl: 'https://api.example.com/v1/login',
            headers: {
              'set-cookie': [
                'session=abcdef; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=3600',
                'theme=dark; Domain=example.com; Expires=Wed, 21 Oct 2099 07:28:00 GMT',
                'bad=1; Domain=evil.test',
                'gone=; Max-Age=0',
              ],
            },
          );
          return ResponseCookies(response: res);
        });
        // The jar holds what an earlier response stored.
        state.cookies.saveFromResponse(
          Uri.parse(res.finalUrl!),
          res.headers['set-cookie']!,
        );
        await tester.pump();

        expect(find.textContaining('Set by this response'), findsOneWidget);
        expect(find.text('session'), findsWidgets);
        // The tab scrolls; bring each part into view in turn.
        for (final text in [
          'does not match',
          'Deletes',
          'Cookies in the jar for this URL',
        ]) {
          await tester.scrollUntilVisible(
            find.textContaining(text),
            300,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.textContaining(text), findsOneWidget, reason: text);
        }
        expect(tester.takeException(), isNull);
        await tester.runAsync(() => state.cookies.flush());
      });
    }

    testWidgets('response without cookies says so', (tester) async {
      await pumpApp(
        tester,
        const Size(360, 640),
        (c) => ResponseCookies(
          response: ResponseData(statusCode: 200, finalUrl: 'http://x.test/'),
        ),
      );
      expect(find.text('This response set no cookies.'), findsOneWidget);
      expect(find.textContaining('No cookies in the jar'), findsOneWidget);
    });
  });
}
