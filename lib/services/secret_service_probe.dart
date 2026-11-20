import 'dart:async';

import 'package:dbus/dbus.dart';

/// What [probeSecretService] found.
enum SecretServiceState {
  /// The default keyring can be used now (or does not exist yet).
  ready,

  /// No Secret Service can be used now; [SecretServiceProbe.reason] says
  /// why.
  unavailable,

  /// The probe could not tell; the plugin finds out itself.
  unknown,
}

class SecretServiceProbe {
  const SecretServiceProbe(this.state, [this.reason]);
  final SecretServiceState state;
  final String? reason;
}

const _name = 'org.freedesktop.secrets';
const _service = 'org.freedesktop.Secret.Service';
const _collection = 'org.freedesktop.Secret.Collection';
const _prompt = 'org.freedesktop.Secret.Prompt';

/// Looks at the session's Secret Service over D-Bus, asynchronously, before
/// libsecret is asked anything (Linux, issue #61).
///
/// The libsecret plugin makes blocking calls on the thread that also runs
/// the app, so a locked keyring whose unlock prompt never appears would
/// freeze the app at start. Here a locked default keyring is unlocked
/// through the Secret Service's own prompt, which the desktop shows while
/// the app keeps running; when that is cancelled or not answered within
/// [promptTimeout] the app uses its fallback file for this session instead
/// of waiting. Each plain call is bounded by [callTimeout].
Future<SecretServiceProbe> probeSecretService({
  Duration callTimeout = const Duration(seconds: 5),
  Duration promptTimeout = const Duration(seconds: 75),
}) async {
  final DBusClient client;
  try {
    client = DBusClient.session(introspectable: false);
  } catch (_) {
    return const SecretServiceProbe(SecretServiceState.unknown);
  }
  try {
    final service = DBusRemoteObject(
      client,
      name: _name,
      path: DBusObjectPath('/org/freedesktop/secrets'),
    );
    final alias =
        (await service
                .callMethod(_service, 'ReadAlias', [
                  const DBusString('default'),
                ], replySignature: DBusSignature('o'))
                .timeout(callTimeout))
            .values
            .first
            .asObjectPath();
    // No default keyring yet: a fresh profile, created on the first save.
    if (alias.value == '/') {
      return const SecretServiceProbe(SecretServiceState.ready);
    }
    final keyring = DBusRemoteObject(client, name: _name, path: alias);
    Future<bool> locked() async =>
        (await keyring
                .getProperty(
                  _collection,
                  'Locked',
                  signature: DBusSignature('b'),
                )
                .timeout(callTimeout))
            .asBoolean();
    if (!await locked()) {
      return const SecretServiceProbe(SecretServiceState.ready);
    }
    final unlock = await service
        .callMethod(_service, 'Unlock', [
          DBusArray.objectPath([alias]),
        ], replySignature: DBusSignature('aoo'))
        .timeout(callTimeout);
    final promptPath = unlock.values[1].asObjectPath();
    if (promptPath.value != '/') {
      final prompt = DBusRemoteObject(client, name: _name, path: promptPath);
      final completed = DBusRemoteObjectSignalStream(
        object: prompt,
        interface: _prompt,
        name: 'Completed',
      ).first;
      await prompt
          .callMethod(_prompt, 'Prompt', [
            const DBusString(''),
          ], replySignature: DBusSignature(''))
          .timeout(callTimeout);
      final DBusSignal done;
      try {
        done = await completed.timeout(promptTimeout);
      } on TimeoutException {
        unawaited(
          prompt
              .callMethod(_prompt, 'Dismiss', const [])
              .then((_) {}, onError: (_) {}),
        );
        return const SecretServiceProbe(
          SecretServiceState.unavailable,
          'The system keychain is locked and was not unlocked in time.',
        );
      }
      if (done.values.first.asBoolean()) {
        return const SecretServiceProbe(
          SecretServiceState.unavailable,
          'The system keychain is locked; unlocking it was cancelled.',
        );
      }
    }
    if (await locked()) {
      return const SecretServiceProbe(
        SecretServiceState.unavailable,
        'The system keychain is locked.',
      );
    }
    return const SecretServiceProbe(SecretServiceState.ready);
  } on DBusServiceUnknownException {
    return const SecretServiceProbe(
      SecretServiceState.unavailable,
      'No Secret Service (GNOME Keyring, KWallet, KeePassXC) is running.',
    );
  } on DBusAccessDeniedException {
    return const SecretServiceProbe(
      SecretServiceState.unavailable,
      'This sandbox is not allowed to reach the Secret Service.',
    );
  } on TimeoutException {
    return const SecretServiceProbe(
      SecretServiceState.unavailable,
      'The Secret Service did not answer in time.',
    );
  } catch (_) {
    // A service that answers differently (an older KWallet bridge, say):
    // let libsecret find out.
    return const SecretServiceProbe(SecretServiceState.unknown);
  } finally {
    unawaited(client.close().then((_) {}, onError: (_) {}));
  }
}
