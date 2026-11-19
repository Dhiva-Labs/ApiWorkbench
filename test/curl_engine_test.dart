import 'dart:io';

import 'package:api_workbench/services/private_temp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('private temp folders are made for this user only', () {
    final dir = createPrivateTempDir('aw-private-');
    addTearDown(() => dir.deleteSync(recursive: true));
    expect(dir.existsSync(), isTrue);
    expect(dir.parent.path, Directory.systemTemp.path);
    expect(
      dir.path.split(Platform.pathSeparator).last,
      startsWith('aw-private-'),
    );
    if (!Platform.isWindows) {
      expect(dir.statSync().mode & 0x1FF, 0x1C0, reason: 'mode 0700');
    }
    final other = createPrivateTempDir('aw-private-');
    addTearDown(() => other.deleteSync(recursive: true));
    expect(other.path, isNot(dir.path));
  });
}
