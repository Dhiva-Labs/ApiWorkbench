import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/load_test.dart';
import 'package:api_workbench/services/private_dir.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/temp_dir.dart';

void main() {
  late HttpServer server;
  late String base;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      req.response.write('{"ok":true}');
      await req.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  group('private log folder', () {
    late Directory sandbox;

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('aw_tmp_sandbox_');
    });
    tearDown(() => deleteTempDir(sandbox));

    /// Runs [body] with [sandbox] as the system temp directory.
    Future<T> inSandbox<T>(Future<T> Function() body) =>
        IOOverrides.runZoned(body, getSystemTempDirectory: () => sandbox);

    Future<LoadTestService> startRun() async {
      final svc = LoadTestService(AppSettings());
      await svc.start(
        plan: [LoadStep(RequestModel(url: '$base/ok'))],
        config: LoadTestConfig(virtualUsers: 1, iterations: 1),
        vars: const {},
      );
      return svc;
    }

    test('each run logs to its own folder, mode 0700, removed after', () async {
      await inSandbox(() async {
        final first = await startRun();
        final second = await startRun();
        final a = first.log!.file.parent;
        final b = second.log!.file.parent;

        expect(a.path, isNot(b.path));
        expect(a.parent.path, sandbox.path);
        expect(
          a.uri.pathSegments[a.uri.pathSegments.length - 2],
          startsWith('apiworkbench-load-'),
        );
        // Nothing sits in a fixed, guessable name.
        expect(
          Directory('${sandbox.path}/apiworkbench-load').existsSync(),
          isFalse,
        );
        if (!Platform.isWindows) {
          expect(a.statSync().mode & 0x1ff, 0x1c0, reason: 'mode 0700');
          expect(b.statSync().mode & 0x1ff, 0x1c0);
        }

        final file = first.log!.file;
        first.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(file.existsSync(), isFalse);
        expect(a.existsSync(), isFalse, reason: 'folder removed with the log');
        expect(b.existsSync(), isTrue);
        second.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
    });

    test('starting again replaces the previous run\'s folder', () async {
      await inSandbox(() async {
        final svc = await startRun();
        final first = svc.log!.file.parent;
        await svc.start(
          plan: [LoadStep(RequestModel(url: '$base/ok'))],
          config: LoadTestConfig(virtualUsers: 1, iterations: 1),
          vars: const {},
        );
        expect(first.existsSync(), isFalse);
        expect(svc.log!.file.parent.path, isNot(first.path));
        svc.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
    });

    test('a run clears the shared folder older versions left behind', () async {
      final legacy = Directory('${sandbox.path}/apiworkbench-load')
        ..createSync();
      File('${legacy.path}/load-1.jsonl').writeAsStringSync('{"url":"x"}');
      await inSandbox(() async {
        final svc = await startRun();
        expect(legacy.existsSync(), isFalse);
        svc.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
    });
  });

  group('private folders', () {
    late Directory sandbox;
    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('aw_private_dir_');
    });
    tearDown(() => deleteTempDir(sandbox));

    test('createPrivateDir gives unique 0700 folders', () async {
      final a = await createPrivateDir('aw-x-', parent: sandbox);
      final b = await createPrivateDir('aw-x-', parent: sandbox);
      expect(a.path, isNot(b.path));
      expect(
        a.uri.pathSegments[a.uri.pathSegments.length - 2],
        startsWith('aw-x-'),
      );
      if (!Platform.isWindows) {
        expect(a.statSync().mode & 0x1ff, 0x1c0);
      }
    });

    test('the sync variant makes the same folders, in the temp root', () {
      final a = createPrivateDirSync('aw-x-', parent: sandbox);
      // Without a parent it uses the system temp directory.
      final b = IOOverrides.runZoned(
        () => createPrivateDirSync('aw-y-'),
        getSystemTempDirectory: () => sandbox,
      );
      expect(a.parent.path, sandbox.path);
      expect(b.parent.path, sandbox.path);
      expect(
        b.uri.pathSegments[b.uri.pathSegments.length - 2],
        startsWith('aw-y-'),
      );
      if (!Platform.isWindows) {
        // mkdtemp: 0700 whatever the umask, with no chmod afterwards.
        expect(a.statSync().mode & 0x1ff, 0x1c0);
        expect(b.statSync().mode & 0x1ff, 0x1c0);
      }
    });

    test('stale folders and legacy names go, fresh ones stay', () async {
      final stale = await createPrivateDir('aw-x-', parent: sandbox);
      File('${stale.path}/old.txt').writeAsStringSync('x');
      final fresh = await createPrivateDir('aw-x-', parent: sandbox);
      final other = Directory('${sandbox.path}/other-dir')..createSync();
      final legacy = Directory('${sandbox.path}/aw_legacy')..createSync();
      await removeStalePrivateDirs(
        'aw-x-',
        parent: sandbox,
        maxAge: const Duration(days: 1),
        legacyNames: const ['aw_legacy'],
      );
      expect(legacy.existsSync(), isFalse);
      expect(other.existsSync(), isTrue);
      expect(fresh.existsSync(), isTrue, reason: 'recent folders stay');

      // Folder times cannot be set from Dart: a negative age makes
      // everything "older than the limit".
      await removeStalePrivateDirs(
        'aw-x-',
        parent: sandbox,
        maxAge: const Duration(days: -1),
      );
      expect(stale.existsSync(), isFalse);
      expect(fresh.existsSync(), isFalse);
      expect(other.existsSync(), isTrue, reason: 'other names are untouched');
    });

    test('a symlink at a legacy name is removed, not followed', () async {
      if (Platform.isWindows) return;
      final target = Directory('${sandbox.path}/target')..createSync();
      File('${target.path}/keep.txt').writeAsStringSync('keep');
      Link('${sandbox.path}/aw_legacy').createSync(target.path);
      await removeStalePrivateDirs(
        'aw-x-',
        parent: sandbox,
        legacyNames: const ['aw_legacy'],
      );
      expect(Link('${sandbox.path}/aw_legacy').existsSync(), isFalse);
      expect(File('${target.path}/keep.txt').existsSync(), isTrue);
    });
  });
}
