import 'dart:io';

/// Deletes a test's temporary folder. Windows refuses while a file in it is
/// still open (a write the app queued, a log being closed), so this retries
/// for a few seconds and then leaves the folder to the OS's temp cleanup.
Future<void> deleteTempDir(Directory dir) async {
  for (var attempt = 0; ; attempt++) {
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt >= 30) {
        if (Platform.isWindows) return;
        rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}
