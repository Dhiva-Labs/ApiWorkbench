import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/auth/auth.dart';
import 'package:api_workbench/ui/help_tip.dart';
import 'package:api_workbench/ui/request/auth_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late int changes;

  setUp(() => changes = 0);

  Future<void> pumpEditor(
    WidgetTester tester,
    AuthConfig auth, {
    double width = 1280,
    double height = 900,
    Map<String, String>? vars,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AuthEditor(auth: auth, onChanged: () => changes++, vars: vars),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openAdvanced(WidgetTester tester) async {
    final adv = find.text('Advanced');
    if (adv.evaluate().isEmpty) return;
    await tester.ensureVisible(adv.first);
    await tester.tap(adv.first);
    await tester.pumpAndSettle();
  }

  TextField fieldLabelled(WidgetTester tester, String label) =>
      tester.widget<TextField>(
        find.ancestor(of: find.text(label), matching: find.byType(TextField)),
      );

  for (final width in [320.0, 1280.0]) {
    for (final type in AuthType.values) {
      testWidgets('${type.name} lays out at ${width.toInt()} px', (
        tester,
      ) async {
        final auth = AuthConfig(
          type: type,
          params: {
            if (type == AuthType.oauth2) ...{
              'accessToken': 'a' * 120,
              'refreshToken': 'r',
              'expiresAt': '2099-01-01T00:00:00Z',
              OAuth2.savedTokensKey:
                  '[{"accessToken":"${'a' * 120}","name":"A very long token '
                  'name that has to be cut short on phones",'
                  '"obtainedAt":"2026-10-31T00:00:00Z"}]',
            },
          },
        );
        await pumpEditor(tester, auth, width: width, height: 2400);
        await openAdvanced(tester);
        expect(tester.takeException(), isNull);
        if (type != AuthType.none && type != AuthType.inherit) {
          expect(find.byType(HelpTip), findsWidgets);
        }
      });
    }
  }

  testWidgets('fields write Postman attribute names', (tester) async {
    final auth = AuthConfig(type: AuthType.oauth1);
    await pumpEditor(tester, auth);
    await tester.enterText(
      find.ancestor(
        of: find.text('Consumer key'),
        matching: find.byType(TextField),
      ),
      'ck',
    );
    expect(auth.params['consumerKey'], 'ck');
    expect(changes, greaterThan(0));

    await openAdvanced(tester);
    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    expect(auth.params['includeBodyHash'], 'true');
  });

  testWidgets('secrets are obscured until revealed', (tester) async {
    final auth = AuthConfig(
      type: AuthType.digest,
      params: {'password': 'hunter2'},
    );
    await pumpEditor(tester, auth, width: 320);
    expect(fieldLabelled(tester, 'Password').obscureText, isTrue);
    final eye = find.descendant(
      of: find.ancestor(
        of: find.text('Password'),
        matching: find.byType(TextField),
      ),
      matching: find.byIcon(Icons.visibility_outlined),
    );
    await tester.tap(eye);
    await tester.pump();
    expect(fieldLabelled(tester, 'Password').obscureText, isFalse);
    expect(fieldLabelled(tester, 'Username').obscureText, isFalse);
  });

  testWidgets('a stored private key shows as hidden until revealed', (
    tester,
  ) async {
    final auth = AuthConfig(
      type: AuthType.jwt,
      params: {
        'algorithm': 'RS256',
        'privateKey':
            '-----BEGIN PRIVATE KEY-----\nMII\n-----END PRIVATE KEY-----',
      },
    );
    await pumpEditor(tester, auth);
    expect(find.textContaining('Hidden (3 lines)'), findsOneWidget);
    expect(find.text('Secret'), findsNothing);
    await tester.tap(find.byIcon(Icons.visibility_outlined).first);
    await tester.pump();
    expect(find.textContaining('Hidden'), findsNothing);
    expect(find.textContaining('BEGIN PRIVATE KEY'), findsOneWidget);
  });

  testWidgets('OAuth 2.0 grant type picks the fields', (tester) async {
    final auth = AuthConfig(
      type: AuthType.oauth2,
      params: {'grant_type': 'client_credentials'},
    );
    await pumpEditor(tester, auth);
    expect(find.text('Auth URL'), findsNothing);
    expect(find.text('Access token URL'), findsOneWidget);
    expect(find.text('Client secret'), findsOneWidget);

    await tester.tap(find.text('Client Credentials'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Authorization Code (With PKCE)').last);
    await tester.pumpAndSettle();
    expect(auth.params['grant_type'], 'authorization_code_with_pkce');
    expect(find.text('Auth URL'), findsOneWidget);
    expect(find.text('Callback URL'), findsOneWidget);
    expect(find.text('Code challenge method'), findsOneWidget);
    expect(find.text('State'), findsOneWidget);

    await tester.tap(find.text('Authorization Code (With PKCE)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Implicit').last);
    await tester.pumpAndSettle();
    expect(find.text('Access token URL'), findsNothing);
    expect(find.text('Client secret'), findsNothing);
  });

  testWidgets('current token: masked, revealed, cleared', (tester) async {
    final auth = AuthConfig(
      type: AuthType.oauth2,
      params: {
        'accessToken': 'tok-123',
        'tokenType': 'Bearer',
        'expiresAt': '2000-01-01T00:00:00Z',
      },
    );
    await pumpEditor(tester, auth, width: 320);
    expect(find.text('tok-123'), findsNothing);
    expect(find.textContaining(RegExp(r'^Expired .* ago$')), findsOneWidget);
    await tester.tap(find.byTooltip('Show token'));
    await tester.pump();
    expect(find.text('tok-123'), findsOneWidget);

    await tester.ensureVisible(find.text('Clear'));
    await tester.tap(find.text('Clear'));
    await tester.pump();
    expect(auth.params.containsKey('accessToken'), isFalse);
    expect(find.textContaining('No token yet'), findsOneWidget);
    expect(changes, greaterThan(0));
  });

  testWidgets('saved tokens can be picked and deleted', (tester) async {
    final auth = AuthConfig(type: AuthType.oauth2);
    OAuth2.store(auth, OAuth2Token(accessToken: 'one', name: 'First'));
    OAuth2.store(auth, OAuth2Token(accessToken: 'two', name: 'Second'));
    await pumpEditor(tester, auth);
    expect(auth.params['accessToken'], 'two');

    await tester.tap(find.textContaining('Second ·'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('First ·').last);
    await tester.pumpAndSettle();
    expect(auth.params['accessToken'], 'one');

    await tester.tap(find.text('Manage'));
    await tester.pumpAndSettle();
    expect(find.text('Saved tokens'), findsWidgets);
    await tester.tap(find.byTooltip('Delete token').first);
    await tester.pumpAndSettle();
    expect(OAuth2.saved(auth).map((t) => t.name), ['First']);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
  });

  testWidgets('Get new access token: paste the redirected URL (implicit)', (
    tester,
  ) async {
    final auth = AuthConfig(
      type: AuthType.oauth2,
      params: {
        'grant_type': 'implicit',
        'authUrl': 'https://idp.test/authorize',
        'clientId': '{{client}}',
        'state': 'fixed-state',
        'tokenName': 'Pasted',
      },
    );
    await pumpEditor(tester, auth, width: 320, vars: {'client': 'app'});
    await tester.tap(find.text('Get new access token'));
    await tester.pumpAndSettle();
    expect(find.text('Paste the redirected URL'), findsOneWidget);

    await tester.enterText(
      find.ancestor(
        of: find.text('Redirected URL'),
        matching: find.byType(TextField),
      ),
      'https://cb.test/#access_token=pasted-token&expires_in=3600'
      '&state=fixed-state',
    );
    await tester.tap(find.text('Use this URL'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    expect(auth.params['accessToken'], 'pasted-token');
    expect(find.text('Paste the redirected URL'), findsNothing);
    expect(find.textContaining('Expires in'), findsOneWidget);
    expect(OAuth2.saved(auth).single.name, 'Pasted');
  });

  testWidgets('a pasted URL with the wrong state is refused', (tester) async {
    final auth = AuthConfig(
      type: AuthType.oauth2,
      params: {
        'grant_type': 'implicit',
        'authUrl': 'https://idp.test/authorize',
        'state': 'mine',
      },
    );
    await pumpEditor(tester, auth);
    await tester.tap(find.text('Get new access token'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.ancestor(
        of: find.text('Redirected URL'),
        matching: find.byType(TextField),
      ),
      'https://cb.test/#access_token=x&state=theirs',
    );
    await tester.tap(find.text('Use this URL'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.textContaining('does not match'), findsOneWidget);
    expect(auth.params.containsKey('accessToken'), isFalse);
  });
}
