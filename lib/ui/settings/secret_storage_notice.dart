import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/secret_store.dart';
import '../../theme.dart';

/// The keychain behind [SecretStorageMode.keychain] on this platform.
String keychainName() {
  if (Platform.isLinux) return 'the Secret Service (GNOME Keyring, KWallet)';
  if (Platform.isWindows) return 'Windows data protection';
  if (Platform.isAndroid) return 'the Android Keystore';
  if (Platform.isMacOS) return 'the macOS Keychain';
  if (Platform.isIOS) return 'the iOS Keychain';
  return 'the system keychain';
}

/// Where passwords, tokens and secret variables are kept (issue #61), for
/// the Security section of Settings.
class SecretStorageNotice extends StatelessWidget {
  const SecretStorageNotice({super.key, required this.status});

  final SecretStorageStatus status;

  @override
  Widget build(BuildContext context) {
    final small = TextStyle(
      fontSize: 11.5,
      height: 1.35,
      color: Palette.textDim,
    );
    if (status.mode == SecretStorageMode.keychain) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.key_outlined, size: 16, color: Palette.success),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Passwords, tokens and secret variables are kept in '
              '${keychainName()}, not in the workspace files.',
              style: small,
            ),
          ),
        ],
      );
    }
    final command = status.snapConnectCommand;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Palette.warning.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: Palette.warning,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Secrets are stored in a local file because no system '
                  'keychain is available.',
                  style: TextStyle(fontSize: 12.5, height: 1.35),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            [
              ?status.reason,
              if (!Platform.isWindows)
                'The file is in the app\'s data folder and only your user '
                    'can read it.',
            ].join(' '),
            style: small,
          ),
          if (status.keychainHoldsOlderSecrets) ...[
            const SizedBox(height: 6),
            Text(
              'Secrets saved earlier are still in the keychain. They come '
              'back, together with the ones saved since, the next time '
              'ApiWorkbench starts with the keychain available.',
              style: small,
            ),
          ],
          if (command != null) ...[
            const SizedBox(height: 8),
            Text(
              'This snap needs permission to use your desktop keychain. Run '
              'this once, then restart ApiWorkbench:',
              style: small,
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    command,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Copy command',
                  icon: const Icon(Icons.copy, size: 16),
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: command)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
