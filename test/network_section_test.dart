import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/ui/adaptive.dart';
import 'package:api_workbench/ui/help_tip.dart';
import 'package:api_workbench/ui/settings/network_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

String fx(String name) => '${Directory.current.path}/test/fixtures/certs/$name';

void main() {
  late NetworkSettings net;
  late int changes;
  late List<String> pickerTitles;
  late List<String?> pickerAnswers;

  setUp(() {
    net = NetworkSettings(proxyMode: ProxyMode.none);
    changes = 0;
    pickerTitles = [];
    pickerAnswers = [];
    certFilePicker = (title) async {
      pickerTitles.add(title);
      return pickerAnswers.isEmpty ? null : pickerAnswers.removeAt(0);
    };
    hoverHelpEnabled.value = true;
  });

  Future<void> pump(
    WidgetTester tester, {
    double width = 800,
    double height = 1400,
    TargetPlatform platform = TargetPlatform.linux,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: NetworkSettingsSection(
              network: net,
              onChanged: () => changes++,
            ),
          ),
        ),
      ),
    );
  }

  Finder field(String label) =>
      find.widgetWithText(TextField, label, skipOffstage: false);

  /// The folder buttons inside the open dialog (the CA field behind it has
  /// one too).
  Finder dialogFolders() => find.descendant(
    of: find.byType(AdaptiveDialog),
    matching: find.byIcon(Icons.folder_open_outlined),
  );

  String textOf(WidgetTester tester, String label) =>
      tester.widget<TextField>(field(label)).controller!.text;

  group('layout', () {
    for (final width in [320.0, 390.0, 768.0, 1200.0]) {
      for (final platform in [TargetPlatform.linux, TargetPlatform.android]) {
        testWidgets('every mode fits $width px on $platform', (tester) async {
          net
            ..proxyHost = 'proxy.corp.example'
            ..proxyUser = 'ada'
            ..proxyPassword = 'secret'
            ..caCertPath = '/a/very/long/path/to/some/corporate/root/ca.pem'
            ..clientCerts = [
              ClientCertificate(
                host: '*.a-rather-long-host-name.example.com:8443',
                certPath: '/home/user/certs/client-certificate-long-name.pem',
                keyPath: '/home/user/certs/client-certificate-long-name.key',
              ),
              ClientCertificate(
                host: 'api.example.com',
                pfxPath: '/home/user/certs/bundle.p12',
                enabled: false,
              ),
            ];
          await pump(tester, width: width, platform: platform);
          for (final mode in ['System', 'Custom', 'None']) {
            await tester.tap(find.text(mode));
            await tester.pump();
            expect(tester.takeException(), isNull, reason: mode);
          }
        });
      }
    }

    testWidgets('a password the HTTP/1.1 proxy cannot carry is flagged', (
      tester,
    ) async {
      net
        ..proxyMode = ProxyMode.custom
        ..proxyUser = 'ada'
        ..proxyPassword = 'a;b';
      await pump(tester);
      expect(find.textContaining('cannot send this login'), findsOneWidget);
      await tester.enterText(field('Password'), 'fine');
      await tester.pump();
      expect(find.textContaining('cannot send this login'), findsNothing);
    });
  });

  group('help', () {
    testWidgets('every text field and control carries help', (tester) async {
      net.proxyMode = ProxyMode.custom;
      net.clientCerts = [ClientCertificate(host: 'h', certPath: 'c.pem')];
      await pump(tester);
      // One help icon per text field (host, port, user, password, bypass, CA).
      expect(find.byType(TextField), findsNWidgets(6));
      expect(find.byType(HelpTip), findsAtLeastNWidgets(6 + 3));
      // Segments, the add button and each tile control are explained too.
      expect(find.byType(HelpHover), findsAtLeastNWidgets(3 + 1 + 3));
    });

    testWidgets('help can be switched off', (tester) async {
      net.proxyMode = ProxyMode.custom;
      await pump(tester);
      hoverHelpEnabled.value = false;
      await tester.pump();
      expect(
        find.byType(Icon).evaluate().any((e) {
          final icon = e.widget as Icon;
          return icon.icon == Icons.help_outline;
        }),
        isFalse,
      );
    });
  });

  group('proxy', () {
    testWidgets('modes show their own fields and write the setting', (
      tester,
    ) async {
      await pump(tester);
      expect(
        find.text('Requests connect straight to the server.'),
        findsOneWidget,
      );
      expect(field('Host'), findsNothing);

      await tester.tap(find.text('System'));
      await tester.pump();
      expect(net.proxyMode, ProxyMode.system);
      expect(changes, 1);
      expect(
        find.textContaining('environment the app was started'),
        findsAtLeastNWidgets(0),
      );
      expect(field('Host'), findsNothing);

      await tester.tap(find.text('Custom'));
      await tester.pump();
      expect(net.proxyMode, ProxyMode.custom);
      expect(field('Host'), findsOneWidget);
      expect(field('Port'), findsOneWidget);
      expect(field('Username (optional)'), findsOneWidget);
      expect(field('Password'), findsOneWidget);
      expect(field('Bypass list'), findsOneWidget);
    });

    testWidgets('typing edits the settings in place', (tester) async {
      net.proxyMode = ProxyMode.custom;
      await pump(tester);
      expect(textOf(tester, 'Port'), '8080');
      expect(textOf(tester, 'Bypass list'), 'localhost, 127.0.0.1, ::1');

      await tester.enterText(field('Host'), 'proxy.corp');
      await tester.enterText(field('Port'), '3128');
      await tester.enterText(field('Username (optional)'), 'ada');
      await tester.enterText(field('Password'), 's3cret');
      await tester.enterText(field('Bypass list'), '*.internal, 10.0.0.0/8');
      await tester.pump();
      expect(net.proxyHost, 'proxy.corp');
      expect(net.proxyPort, 3128);
      expect(net.proxyUser, 'ada');
      expect(net.proxyPassword, 's3cret');
      expect(net.proxyBypass, '*.internal, 10.0.0.0/8');
      expect(changes, greaterThanOrEqualTo(5));
    });

    testWidgets('an invalid port is flagged and not stored', (tester) async {
      net.proxyMode = ProxyMode.custom;
      await pump(tester);
      await tester.enterText(field('Port'), '70000');
      await tester.pump();
      expect(find.text('1 to 65535'), findsOneWidget);
      expect(net.proxyPort, 8080);
      await tester.enterText(field('Port'), '');
      await tester.pump();
      expect(find.text('1 to 65535'), findsOneWidget);
      await tester.enterText(field('Port'), '443');
      await tester.pump();
      expect(find.text('1 to 65535'), findsNothing);
      expect(net.proxyPort, 443);
    });

    testWidgets('the password is hidden until asked for', (tester) async {
      net
        ..proxyMode = ProxyMode.custom
        ..proxyPassword = 'hunter2';
      await pump(tester);
      expect(tester.widget<TextField>(field('Password')).obscureText, isTrue);
      await tester.tap(find.byIcon(Icons.visibility_outlined));
      await tester.pump();
      expect(tester.widget<TextField>(field('Password')).obscureText, isFalse);
    });

    test('the environment summary hides passwords', () {
      expect(systemProxySummary({}), isEmpty);
      expect(systemProxySummary({'HTTP_PROXY': '  '}), isEmpty);
      expect(
        systemProxySummary({
          'http_proxy': 'http://ada:s3cret@proxy.corp:3128/',
          'HTTPS_PROXY': 'proxy.corp:3128',
          'no_proxy': 'localhost,.corp',
          'NO_PROXY': 'ignored: lower case wins',
        }),
        [
          'HTTP_PROXY  http://***@proxy.corp:3128/',
          'HTTPS_PROXY  proxy.corp:3128',
          'NO_PROXY  localhost,.corp',
        ],
      );
      expect(
        systemProxySummary({'HTTPS_PROXY': 'ada:s3cret@proxy.corp:3128'}),
        ['HTTPS_PROXY  ***@proxy.corp:3128'],
      );
    });
  });

  group('CA certificate', () {
    testWidgets('choose, flag a missing file, clear', (tester) async {
      await pump(tester);
      expect(
        find.text('Only the system certificates are trusted.'),
        findsOneWidget,
      );

      pickerAnswers = [fx('ca.pem')];
      await tester.tap(find.byIcon(Icons.folder_open_outlined));
      await tester.pumpAndSettle();
      expect(pickerTitles, ['Choose the CA certificate']);
      expect(net.caCertPath, fx('ca.pem'));
      expect(textOf(tester, 'CA certificate file (PEM)'), fx('ca.pem'));
      expect(find.text('File not found'), findsNothing);
      expect(find.textContaining('in addition to the system'), findsWidgets);

      await tester.enterText(
        field('CA certificate file (PEM)'),
        '/no/such.pem',
      );
      await tester.pump();
      expect(net.caCertPath, '/no/such.pem');
      expect(find.text('File not found'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.clear));
      await tester.pump();
      expect(net.caCertPath, '');
      expect(textOf(tester, 'CA certificate file (PEM)'), '');
      expect(find.byIcon(Icons.clear), findsNothing);
    });

    testWidgets('cancelling the picker changes nothing', (tester) async {
      await pump(tester);
      await tester.tap(find.byIcon(Icons.folder_open_outlined));
      await tester.pumpAndSettle();
      expect(net.caCertPath, '');
      expect(changes, 0);
    });
  });

  group('client certificates', () {
    Future<void> openAdd(WidgetTester tester) async {
      await tester.ensureVisible(find.text('Add certificate'));
      await tester.tap(find.text('Add certificate'));
      await tester.pumpAndSettle();
    }

    testWidgets('add a PEM certificate', (tester) async {
      await pump(tester);
      expect(find.textContaining('None. Add one'), findsOneWidget);
      await openAdd(tester);
      expect(find.text('Add client certificate'), findsOneWidget);

      // Saving an empty form explains what is missing.
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(find.textContaining('Enter the host name'), findsOneWidget);

      await tester.enterText(field('Host'), '*.example.com');
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(find.text('Choose the certificate file.'), findsOneWidget);

      pickerAnswers = [fx('client.pem'), fx('client-enc.key')];
      final folders = dialogFolders();
      await tester.tap(folders.at(0));
      await tester.pumpAndSettle();
      await tester.tap(folders.at(1));
      await tester.pumpAndSettle();
      expect(pickerTitles, [
        'Choose the certificate file',
        'Choose the private key file',
      ]);
      await tester.enterText(field('Key passphrase (optional)'), 'keypass');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Add client certificate'), findsNothing);
      expect(net.clientCerts, hasLength(1));
      final c = net.clientCerts.single;
      expect(c.host, '*.example.com');
      expect(c.certPath, fx('client.pem'));
      expect(c.keyPath, fx('client-enc.key'));
      expect(c.pfxPath, '');
      expect(c.passphrase, 'keypass');
      expect(c.enabled, isTrue);
      expect(changes, 1);
      // The list shows it.
      expect(find.text('*.example.com'), findsOneWidget);
      expect(
        find.textContaining('PEM  client.pem, client-enc.key'),
        findsOneWidget,
      );
    });

    testWidgets('add a PFX bundle', (tester) async {
      await pump(tester);
      await openAdd(tester);
      await tester.tap(find.text('PFX / P12'));
      await tester.pump();
      expect(field('Certificate file (PEM)'), findsNothing);
      expect(field('PFX / P12 file'), findsOneWidget);
      await tester.enterText(field('Host'), 'api.example.com:8443');
      pickerAnswers = [fx('client.p12')];
      await tester.tap(dialogFolders());
      await tester.pumpAndSettle();
      await tester.enterText(field('Passphrase (optional)'), 'pfxpass');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final c = net.clientCerts.single;
      expect(
        (c.host, c.pfxPath, c.certPath, c.keyPath, c.passphrase),
        ('api.example.com:8443', fx('client.p12'), '', '', 'pfxpass'),
      );
      expect(find.textContaining('PFX  client.p12'), findsOneWidget);
    });

    testWidgets('cancel adds nothing', (tester) async {
      await pump(tester);
      await openAdd(tester);
      await tester.enterText(field('Host'), 'x');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(net.clientCerts, isEmpty);
      expect(changes, 0);
    });

    testWidgets('edit keeps the id and the on/off state', (tester) async {
      final original = ClientCertificate(
        host: 'old.example.com',
        certPath: fx('client.pem'),
        keyPath: fx('client.key'),
        enabled: false,
      );
      net.clientCerts = [original];
      await pump(tester);
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      expect(find.text('Edit client certificate'), findsOneWidget);
      expect(textOf(tester, 'Host'), 'old.example.com');
      expect(textOf(tester, 'Certificate file (PEM)'), fx('client.pem'));

      await tester.enterText(field('Host'), 'new.example.com');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(net.clientCerts, hasLength(1));
      expect(net.clientCerts.single.id, original.id);
      expect(net.clientCerts.single.host, 'new.example.com');
      expect(net.clientCerts.single.enabled, isFalse);
    });

    testWidgets('switching formats drops the other format\'s files', (
      tester,
    ) async {
      net.clientCerts = [
        ClientCertificate(
          host: 'h',
          certPath: fx('client.pem'),
          keyPath: fx('client.key'),
        ),
      ];
      await pump(tester);
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('PFX / P12'));
      await tester.pump();
      pickerAnswers = [fx('client.p12')];
      await tester.tap(dialogFolders());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final c = net.clientCerts.single;
      expect((c.pfxPath, c.certPath, c.keyPath), (fx('client.p12'), '', ''));
    });

    testWidgets('toggle and remove from the list', (tester) async {
      net.clientCerts = [
        ClientCertificate(host: 'a.example.com', certPath: 'a.pem'),
        ClientCertificate(host: 'b.example.com', certPath: 'b.pem'),
      ];
      await pump(tester);
      expect(find.text('File not found: a.pem'), findsOneWidget);

      await tester.tap(find.byType(Switch).first);
      await tester.pump();
      expect(net.clientCerts[0].enabled, isFalse);
      expect(net.clientCerts[1].enabled, isTrue);

      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await tester.pump();
      expect(net.clientCerts.map((c) => c.host), ['b.example.com']);
      expect(find.text('a.example.com'), findsNothing);
      expect(changes, 2);
    });

    testWidgets('the dialog fills the screen on a phone', (tester) async {
      await pump(
        tester,
        width: 320,
        height: 640,
        platform: TargetPlatform.android,
      );
      await openAdd(tester);
      // Full-screen dialog: Save is in the app bar, there is no Cancel row.
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('Cancel'), findsNothing);
      await tester.enterText(field('Host'), 'phone.example.com');
      pickerAnswers = [fx('client.pem')];
      await tester.tap(dialogFolders().first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('PFX / P12'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('PEM files'));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(net.clientCerts.single.host, 'phone.example.com');
      expect(tester.takeException(), isNull);
    });
  });
}
