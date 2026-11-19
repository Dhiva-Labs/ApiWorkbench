// A real-keychain check for issue #61, built as a Linux app and run in a
// private D-Bus session by run.sh (never the desktop's own session or
// keyring). Not a `flutter test` file: plugins only load in a real build.
import 'dart:io';

import 'package:api_workbench/services/keychain_backend.dart';
import 'package:api_workbench/services/secret_service_probe.dart';
import 'package:api_workbench/services/secret_store.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:flutter/widgets.dart';

import '../support/secret_fixtures.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // keychain: a Secret Service is running and unlocked. file: none is.
  final expect = Platform.environment['AW_SMOKE_EXPECT'] ?? 'keychain';
  var ok = true;
  void check(bool pass, String what) {
    stdout.writeln('${pass ? 'PASS' : 'FAIL'} $what');
    ok &= pass;
  }

  // The app waits 75 s for an unlock prompt to be answered; nobody answers
  // here.
  KeychainBackend backend() => KeychainBackend(
    probe: () => probeSecretService(promptTimeout: const Duration(seconds: 5)),
  );
  final dir = await Directory.systemTemp.createTemp('aw_keychain_smoke');
  try {
    final watch = Stopwatch()..start();
    final s = Storage(overrideDir: dir, keychain: backend());
    await s.saveCollections([secretCollection()]);
    await s.saveSettings(secretSettings());
    await s.flush();
    final status = s.secrets.status;
    check(
      status.mode.name == expect,
      'mode ${status.mode.name} (${status.reason ?? 'no reason'}) '
      'after ${watch.elapsedMilliseconds} ms',
    );
    final leaks = <String>[];
    for (final f in Directory('${dir.path}/apiworkbench').listSync()) {
      if (f is! File) continue;
      if (expect == 'keychain' || !f.path.endsWith('secrets.json')) {
        final text = f.readAsStringSync();
        leaks.addAll(fixtureSecrets.where(text.contains));
      }
    }
    check(leaks.isEmpty, 'no secret in the data folder files $leaks');

    final again = Storage(overrideDir: dir, keychain: backend());
    final cols = await again.loadCollections();
    final settings = await again.loadSettings();
    check(
      cols.single.auth.bearerToken == 'col-bearer-0001' &&
          cols.single.requests.first.auth.params['refreshToken'] ==
              'oauth-refresh-0004' &&
          settings.network.proxyPassword == 'proxy-pass-0014',
      'secrets read back by a fresh start',
    );
    if (expect == 'keychain') {
      final keychain = backend();
      final items = await keychain.readAll();
      check(
        items.keys.toSet().containsAll({
          '${SecretStore.keyPrefix}collections',
          '${SecretStore.keyPrefix}settings',
        }),
        'keychain keys ${items.keys.toList()}',
      );
      for (final k in items.keys) {
        await keychain.delete(k);
      }
      check((await keychain.readAll()).isEmpty, 'keychain cleaned up');
    }
  } catch (e, st) {
    check(false, 'threw $e\n$st');
  } finally {
    await dir.delete(recursive: true);
  }
  stdout.writeln(ok ? 'KEYCHAIN SMOKE OK' : 'KEYCHAIN SMOKE FAILED');
  exit(ok ? 0 : 1);
}
