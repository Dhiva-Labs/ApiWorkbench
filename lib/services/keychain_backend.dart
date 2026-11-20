import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secret_service_probe.dart';
import 'secret_store.dart';

/// The platform keychain through flutter_secure_storage:
/// - Linux: the Secret Service (GNOME Keyring, KWallet, KeePassXC) through
///   libsecret. All values go into one item labelled
///   `com.dhivalabs.api_workbench/FlutterSecureStorage`. libsecret is only
///   asked once [probeSecretService] has found the keyring usable, since
///   its calls block the app.
/// - Windows: a DPAPI-encrypted file, tied to the Windows account, in the
///   app's AppData folder (no Credential Manager size limit).
/// - Android: values encrypted with a key held in the Android Keystore.
/// - macOS and iOS: the Keychain. macOS uses the login keychain rather than
///   the data protection keychain, which would need a provisioning profile
///   for keychain sharing.
class KeychainBackend implements SecretBackend {
  KeychainBackend({
    FlutterSecureStorage? storage,
    Map<String, String>? env,
    Future<SecretServiceProbe> Function()? probe,
  }) : _storage =
           storage ??
           const FlutterSecureStorage(
             mOptions: MacOsOptions(usesDataProtectionKeychain: false),
           ),
       _env = env ?? Platform.environment,
       _probe = probe ?? probeSecretService;

  final FlutterSecureStorage _storage;
  final Map<String, String> _env;
  final Future<SecretServiceProbe> Function() _probe;

  @override
  Future<Map<String, String>> readAll() async {
    if (Platform.isLinux) {
      _checkSessionBus();
      final probe = await _probe();
      if (probe.state == SecretServiceState.unavailable) {
        throw SecretBackendException(probe.reason ?? 'No Secret Service.');
      }
    }
    return _call(_storage.readAll);
  }

  @override
  Future<void> write(String key, String value) =>
      _call(() => _storage.write(key: key, value: value));

  @override
  Future<void> delete(String key) => _call(() => _storage.delete(key: key));

  /// Linux reaches the Secret Service over the D-Bus session bus. Without
  /// one (a headless machine, a bare SSH login) libsecret would try to
  /// autolaunch a bus, so it is not asked at all.
  void _checkSessionBus() {
    if ((_env['DBUS_SESSION_BUS_ADDRESS'] ?? '').isNotEmpty) return;
    final runtime = _env['XDG_RUNTIME_DIR'] ?? '';
    if (runtime.isNotEmpty && File('$runtime/bus').existsSync()) return;
    throw const SecretBackendException(
      'There is no desktop session bus, so no Secret Service can be '
      'reached.',
    );
  }

  Future<T> _call<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on MissingPluginException {
      throw const SecretBackendException('This build has no keychain support.');
    } on PlatformException catch (e) {
      throw SecretBackendException(describePlatformError(e.code));
    }
  }
}

/// The Settings wording for a keychain error code from the platform plugin.
String describePlatformError(String code) {
  if (code == 'KeyringLocked') {
    return 'The system keychain is locked, or no Secret Service (GNOME '
        'Keyring, KWallet, KeePassXC) is running.';
  }
  if (Platform.isLinux) {
    return 'No Secret Service (GNOME Keyring, KWallet, KeePassXC) could be '
        'reached.';
  }
  return 'The system keychain reported an error'
      '${code.isEmpty ? '' : ' ($code)'}.';
}
