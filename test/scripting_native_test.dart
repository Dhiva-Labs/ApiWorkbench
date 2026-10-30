import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/scripting/engine_factory.dart';
import 'package:api_workbench/services/scripting/script_assets.dart';
import 'package:api_workbench/services/scripting/script_engine.dart';
import 'package:api_workbench/services/var_scopes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quickjs_ffi/quickjs_ffi.dart';

/// The library the build hook produced for this test run, found on disk so
/// the explicit-path loading a CLI uses can be checked too.
String? builtLibrary() {
  final name = Platform.isWindows
      ? 'quickjs_ffi.dll'
      : Platform.isMacOS
      ? 'libquickjs_ffi.dylib'
      : 'libquickjs_ffi.so';
  for (final root in ['build', '.dart_tool']) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final f in dir.listSync(recursive: true, followLinks: false)) {
      if (f is File && f.uri.pathSegments.last == name) return f.absolute.path;
    }
  }
  return null;
}

void main() {
  group('QuickJs', () {
    late QuickJs quickJs;
    setUpAll(() => quickJs = QuickJs.open());

    test('the build hook bundles the library for flutter test', () {
      expect(quickJs.location, 'asset');
    });

    test('a library file can be loaded by path', () {
      final path = builtLibrary();
      expect(path, isNotNull, reason: 'flutter test built the library');
      final q = QuickJs.open(path: path);
      expect(q.location, path);
      final rt = q.newRuntime();
      addTearDown(rt.dispose);
      expect(rt.eval('6 * 7').value, 42);
    });

    test('a missing library is reported, not thrown at random', () {
      expect(
        () => QuickJs.open(path: '/no/such/libquickjs.so'),
        throwsA(isA<QuickJsUnavailable>()),
      );
      expect(QuickJs.tryOpen(path: '/no/such/libquickjs.so'), isNull);
    });

    test('eval returns JSON values and exception text', () {
      final rt = quickJs.newRuntime();
      addTearDown(rt.dispose);
      expect(rt.eval('({a: [1, "x", null], b: true})').value, {
        'a': [1, 'x', null],
        'b': true,
      });
      expect(rt.eval('undefined').value, isNull);
      expect(rt.eval('"é😀"').value, 'é😀');
      final err = rt.eval('\n  null.x', filename: 'my.js');
      expect(err.ok, isFalse);
      expect(err.timedOut, isFalse);
      expect(err.error, startsWith('TypeError: cannot read property'));
      expect(err.error, contains('my.js:2'));
      expect(rt.eval('throw "plain"').error, 'plain');
    });

    test('pending jobs run on demand', () {
      final rt = quickJs.newRuntime();
      addTearDown(rt.dispose);
      rt.eval('var log = []; Promise.resolve(1).then(v => log.push(v));');
      expect(rt.eval('log').value, isEmpty);
      expect(rt.runJobs(), isNull);
      expect(rt.eval('log').value, [1]);
    });

    test('the deadline interrupts code that catches everything', () {
      final rt = quickJs.newRuntime();
      addTearDown(rt.dispose);
      rt.setDeadline(150);
      final sw = Stopwatch()..start();
      final r = rt.eval('for (;;) { try { for (;;) {} } catch (e) {} }');
      expect(r.timedOut, isTrue);
      expect(sw.elapsedMilliseconds, lessThan(3000));
      rt.setDeadline(0);
      expect(rt.eval('1 + 1').value, 2, reason: 'usable after an interrupt');
      rt.setDeadline(100);
      rt.eval('Promise.resolve().then(() => { for (;;) {} })');
      expect(rt.runJobs()?.timedOut, isTrue);
    });

    test('the memory limit stops allocation without crashing', () {
      final rt = quickJs.newRuntime(memoryLimit: 8 << 20);
      addTearDown(rt.dispose);
      final r = rt.eval(
        'const a = []; for (;;) a.push("x".repeat(1 << 16) + a.length);',
      );
      expect(r.ok, isFalse);
      expect(r.error, contains('out of memory'));
    });

    test('compiled modules load in other runtimes', () {
      final rt = quickJs.newRuntime();
      final code = rt.compile(
        '(function (n) { return n * 2; })',
        filename: 'double',
      );
      rt.dispose();
      addTearDown(code.dispose);
      for (var i = 0; i < 2; i++) {
        final other = quickJs.newRuntime()..addModule('double', code);
        expect(other.eval('__awLoad("double")(21)').value, 42);
        expect(
          other.eval('__awLoad("missing")').error,
          contains("Cannot find module 'missing'"),
        );
        other.dispose();
      }
      final bad = quickJs.newRuntime();
      addTearDown(bad.dispose);
      expect(() => bad.compile('let = ;'), throwsA(isA<FormatException>()));
    });

    test('there is no std, os or module loader', () {
      final rt = quickJs.newRuntime();
      addTearDown(rt.dispose);
      expect(
        rt.eval('[typeof std, typeof os, typeof print, typeof console]').value,
        ['undefined', 'undefined', 'undefined', 'undefined'],
      );
      rt.eval(
        'var r = "pending"; '
        'import("std").then(() => r = "loaded", e => r = String(e));',
      );
      expect(rt.runJobs(), isNull);
      expect(rt.eval('r').value, isNot('loaded'));
    });
  });

  group('createScriptEngine', () {
    ScriptContext ctx({ScriptPhase phase = ScriptPhase.preRequest}) =>
        ScriptContext(
          phase: phase,
          request: RequestModel(),
          response: phase == ScriptPhase.test
              ? ResponseData(statusCode: 200)
              : null,
          scopes: VarScopes(),
          info: const ScriptInfo(requestName: 'R', requestId: 'r'),
        );

    test('finds the script files in a source checkout', () {
      expect(
        findScriptAssetDir(),
        endsWith('assets${Platform.pathSeparator}js'),
      );
    });

    test('returns null when the library does not load', () {
      expect(createScriptEngine(libraryPath: '/no/such/lib.so'), isNull);
    });

    test('an engine on an explicit library path runs scripts', () async {
      final engine = createScriptEngine(libraryPath: builtLibrary())!;
      addTearDown(engine.dispose);
      final out = await engine.run(const [
        ScriptSource('pm.test("ok", () => pm.expect(1).to.equal(1));', 'R'),
      ], ctx());
      expect(out.error, isNull);
      expect(out.tests.single.pass, isTrue);
    });

    test('a broken asset loader gives an error outcome', () async {
      final engine = createScriptEngine(
        loadAsset: (_) async => throw const FileSystemException('gone'),
      )!;
      addTearDown(engine.dispose);
      final out = await engine.run(const [ScriptSource('1', 'R')], ctx());
      expect(out.error, contains('script engine failed'));
    });

    test('warm runs are fast', () async {
      final engine = createScriptEngine()!;
      addTearDown(engine.dispose);
      Future<void> once() async {
        final out = await engine.run(const [
          ScriptSource(
            'pm.test("s", () => pm.expect(pm.response.code).to.equal(200));',
            'R',
          ),
        ], ctx(phase: ScriptPhase.test));
        expect(out.tests.single.pass, isTrue);
      }

      await once(); // starts the worker and compiles the libraries
      final sw = Stopwatch()..start();
      for (var i = 0; i < 20; i++) {
        await once();
      }
      // A loose bound for slow CI machines; locally a run takes a few ms.
      expect(sw.elapsedMilliseconds / 20, lessThan(250));
    });
  });
}
