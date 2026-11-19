import 'dart:io';

import 'package:api_workbench/ui/response/external_open.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/temp_dir.dart';

void main() {
  late Directory sandbox;
  late Future<bool> Function(Uri) savedLauncher;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('aw_preview_sandbox_');
    savedLauncher = uriLauncher;
    resetPreviewFolder();
  });
  tearDown(() async {
    uriLauncher = savedLauncher;
    resetPreviewFolder();
    await deleteTempDir(sandbox);
  });

  /// Runs [body] with [sandbox] as the system temp directory.
  Future<T> inSandbox<T>(Future<T> Function() body) =>
      IOOverrides.runZoned(body, getSystemTempDirectory: () => sandbox);

  test('previews go to a private, randomly named folder', () async {
    await inSandbox(() async {
      final file = await writeTempFile('page.html', [1, 2, 3]);
      final dir = file.parent;
      expect(dir.parent.path, sandbox.path);
      expect(
        dir.uri.pathSegments[dir.uri.pathSegments.length - 2],
        startsWith('apiworkbench-preview-'),
      );
      expect(
        dir.uri.pathSegments[dir.uri.pathSegments.length - 2],
        isNot('apiworkbench-preview-'),
        reason: 'the name has a random part',
      );
      expect(file.readAsBytesSync(), [1, 2, 3]);
      if (!Platform.isWindows) {
        expect(dir.statSync().mode & 0x1ff, 0x1c0, reason: 'mode 0700');
      }
      // Nothing is written to the fixed folder older versions used.
      expect(
        Directory('${sandbox.path}/apiworkbench_preview').existsSync(),
        isFalse,
      );
    });
  });

  test('one body reuses its file, other bodies get their own', () async {
    await inSandbox(() async {
      final a = await writeTempFile('r.json', [1, 2, 3]);
      final again = await writeTempFile('r.json', [1, 2, 3]);
      final other = await writeTempFile('r.json', [4, 5, 6]);
      expect(again.path, a.path);
      expect(other.path, isNot(a.path));
      expect(other.parent.path, a.parent.path, reason: 'one folder per run');
      expect(other.readAsBytesSync(), [4, 5, 6]);
    });
  });

  test('a file name cannot leave the folder', () async {
    await inSandbox(() async {
      final file = await writeTempFile('../../outside.txt', [1]);
      expect(file.parent.parent.path, sandbox.path);
      expect(file.existsSync(), isTrue);
    });
  });

  test('a new run gets a new folder and clears the old shared one', () async {
    final legacy = Directory('${sandbox.path}/apiworkbench_preview')
      ..createSync();
    File('${legacy.path}/abc-old.html').writeAsStringSync('old response');
    await inSandbox(() async {
      final first = await writeTempFile('a.txt', [1]);
      expect(legacy.existsSync(), isFalse);
      resetPreviewFolder();
      final second = await writeTempFile('a.txt', [1]);
      expect(second.parent.path, isNot(first.parent.path));
    });
  });

  test('a folder removed behind our back is made again', () async {
    await inSandbox(() async {
      final first = await writeTempFile('a.txt', [1]);
      first.parent.deleteSync(recursive: true);
      final second = await writeTempFile('a.txt', [1]);
      expect(second.existsSync(), isTrue);
      if (!Platform.isWindows) {
        expect(second.parent.statSync().mode & 0x1ff, 0x1c0);
      }
    });
  });

  testWidgets('opening hands the private file to the system launcher', (
    tester,
  ) async {
    final launched = <Uri>[];
    uriLauncher = (uri) async {
      launched.add(uri);
      return true;
    };
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => inSandbox(
        () => openBytesExternally(
          context,
          name: 'doc.html',
          bytes: [65, 66],
          app: 'the browser',
        ),
      ),
    );
    expect(launched, hasLength(1));
    expect(launched.single.scheme, 'file');
    final opened = File.fromUri(launched.single);
    expect(opened.existsSync(), isTrue);
    expect(opened.path, startsWith(sandbox.path));
    expect(opened.readAsStringSync(), 'AB');
  });
}
