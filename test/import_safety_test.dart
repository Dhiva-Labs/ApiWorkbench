import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/console_events.dart';
import 'package:api_workbench/services/executor.dart';
import 'package:api_workbench/services/http_service.dart';
import 'package:api_workbench/services/postman_import.dart';
import 'package:api_workbench/services/runner.dart';
import 'package:api_workbench/services/scripting/script_engine.dart';
import 'package:api_workbench/services/scripting/script_trust.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:api_workbench/services/var_scopes.dart';
import 'package:api_workbench/services/workspace.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/state/console_log.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/temp_dir.dart';

/// A script engine that records what it was asked to run.
class RecordingEngine implements ScriptEngine {
  final runs = <List<ScriptSource>>[];

  @override
  Future<ScriptOutcome> run(
    List<ScriptSource> scripts,
    ScriptContext ctx,
  ) async {
    runs.add(scripts);
    return ScriptOutcome(tests: [const ScriptTestResult('ran', true)]);
  }

  @override
  void dispose() {}
}

/// A collection as an import leaves it: scripts at every level.
CollectionModel scripted(String base, {bool untrusted = true}) =>
    CollectionModel(
      name: 'Imported',
      untrusted: untrusted,
      preRequestScript: 'pm.collectionVariables.set("seen", "1");',
      folders: {'F': FolderMeta(testScript: 'pm.test("folder", () => {});')},
      requests: [
        RequestModel(
          name: 'Ping',
          url: '$base/ping',
          folder: 'F',
          testScript: 'pm.test("request ran", () => {});',
        ),
      ],
    );

void main() {
  // The app's engine reads its sandbox through the asset bundle; the
  // binding's stand-in HTTP client would answer every request with 400.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late HttpServer server;
  late String base;
  final paths = <String>[];

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      paths.add(req.uri.path);
      req.response.headers.contentType = ContentType.json;
      req.response.write('{"ok":true}');
      await req.response.close();
    });
  });

  tearDownAll(() => server.close(force: true));
  setUp(paths.clear);

  group('imports leave out local file paths', () {
    test('an ApiWorkbench workspace file: form files and file bodies', () {
      final ws = buildWorkspaceJson([
        CollectionModel(
          name: 'Shared',
          preRequestScript: 'a();',
          requests: [
            RequestModel(
              name: 'Upload',
              bodyType: BodyType.formData,
              formFields: [
                KV(
                  key: 'doc',
                  value: '/home/someone/notes/report.pdf',
                  isFile: true,
                ),
                KV(key: 'empty', isFile: true),
                KV(key: 'note', value: 'kept'),
              ],
              testScript: 'b();',
              examples: [
                ResponseExample(
                  name: 'ok',
                  originalRequest: RequestModel(
                    bodyType: BodyType.binary,
                    body: '/etc/hostname',
                  ),
                ),
              ],
            ),
            RequestModel(
              name: 'Raw',
              bodyType: BodyType.binary,
              body: r'C:\Users\someone\secrets.txt',
            ),
          ],
        ),
      ], []);
      final r = importApiFile(ws);
      final c = r.collections.single;
      final up = c.requests.first;
      expect(up.formFields.map((f) => '${f.key}=${f.value}:${f.isFile}'), [
        'doc=:true',
        'empty=:true',
        'note=kept:false',
      ]);
      expect(up.formFields.first.description, contains('"report.pdf"'));
      expect(up.examples.single.originalRequest!.body, isEmpty);
      expect(c.requests[1].body, isEmpty);
      // Examples are cleared too, but only what would be sent is counted.
      expect(r.fileReferencesCleared, 2);
      expect(r.warnings.single, contains('2 file path(s) were not imported'));
      expect(r.scriptsKept, 2);
      expect(r.scriptsNote, startsWith('2 scripts imported.'));

      final kept = importApiFile(ws, keepFilePaths: true);
      expect(kept.fileReferencesCleared, 0);
      expect(
        kept.collections.single.requests.first.formFields.first.value,
        '/home/someone/notes/report.pdf',
      );
    });

    test('a Postman file field with a list of paths keeps one row each', () {
      final r = importApiFile(
        jsonEncode({
          'info': {'name': 'P', 'schema': 'collection/v2.1.0'},
          'item': [
            {
              'name': 'Up',
              'request': {
                'method': 'POST',
                'url': 'https://x.test',
                'body': {
                  'mode': 'formdata',
                  'formdata': [
                    {
                      'key': 'f',
                      'type': 'file',
                      'src': ['/a/1.png', '/b/2.png'],
                    },
                    {'key': 'none', 'type': 'file', 'src': []},
                  ],
                },
              },
            },
          ],
        }),
      );
      final fields = r.collections.single.requests.single.formFields;
      expect(fields.map((f) => '${f.key}=${f.value}'), ['f=', 'f=', 'none=']);
      expect(fields[1].description, contains('"2.png"'));
      expect(r.fileReferencesCleared, 2);
      expect(r.scriptsNote, isNull);
    });
  });

  group('the untrusted flag', () {
    test('collections saved before it existed load as trusted', () async {
      final old = CollectionModel.fromJson({
        'id': 'c1',
        'name': 'Mine',
        'requests': <Object>[],
        'preRequestScript': 'a();',
      });
      expect(old.untrusted, isFalse);
      expect(old.toJson().containsKey('untrusted'), isFalse);

      final marked = CollectionModel(name: 'X', untrusted: true);
      expect(marked.toJson()['untrusted'], isTrue);
      expect(CollectionModel.fromJson(marked.toJson()).untrusted, isTrue);

      // A 1.4 data folder.
      final dir = await Directory.systemTemp.createTemp('aw_trust_');
      addTearDown(() => deleteTempDir(dir));
      Directory('${dir.path}/apiworkbench').createSync();
      File('${dir.path}/apiworkbench/collections.json').writeAsStringSync(
        jsonEncode([
          {
            'id': 'c1',
            'name': 'Mine',
            'requests': [
              {'id': 'r1', 'name': 'R', 'testScript': 'pm.test("x", ()=>{});'},
            ],
          },
        ]),
      );
      final loaded = await Storage(overrideDir: dir).loadCollections();
      expect(loaded.single.untrusted, isFalse);
    });

    test('requests and history entries saved before it carry no mark', () {
      final old = HistoryEntry.fromJson({
        'id': 'h1',
        'request': {'id': 'r1', 'name': 'R', 'testScript': 'a();'},
        'statusCode': 200,
        'durationMs': 5,
        'at': '2026-11-01T10:00:00.000',
      });
      expect(old.request.untrustedScripts, isFalse);
      expect(old.toJson()['request'], isNot(contains('untrustedScripts')));

      final marked = RequestModel(name: 'M', untrustedScripts: true);
      expect(marked.toJson()['untrustedScripts'], isTrue);
      expect(RequestModel.fromJson(marked.toJson()).untrustedScripts, isTrue);
      expect(marked.clone().untrustedScripts, isTrue);
    });
  });

  group('the executor', () {
    late HttpService http;
    setUp(() => http = HttpService());
    tearDown(() => http.dispose());

    test('runs no script of an untrusted collection', () async {
      final engine = RecordingEngine();
      final c = scripted(base);
      final res = await RequestExecutor(http, engine: engine).execute(
        c.requests.single,
        ExecContext(
          scopes: VarScopes(collection: c.variables),
          collection: c,
        ),
      );
      expect(engine.runs, isEmpty);
      expect(paths, ['/ping'], reason: 'the request itself is sent');
      expect(res.scriptTests, isEmpty);
      expect(res.logs.single.level, ConsoleLevel.warn);
      expect(res.logs.single.message, contains('"Imported" was imported'));
      expect(c.variables, isEmpty, reason: 'nothing ran');

      c.untrusted = false;
      final again = await RequestExecutor(http, engine: engine).execute(
        c.requests.single,
        ExecContext(
          scopes: VarScopes(collection: c.variables),
          collection: c,
        ),
      );
      expect(engine.runs.length, 2, reason: 'pre-request and test');
      expect(engine.runs.first.map((s) => s.origin), ['Collection Imported']);
      expect(engine.runs.last.map((s) => s.origin), [
        'Folder F',
        'Request Ping',
      ]);
      expect(again.logs, isEmpty);
    });

    test('the runner skips them too', () async {
      final engine = RecordingEngine();
      final runner = RunnerService(http, engine: engine);
      addTearDown(runner.dispose);
      final c = scripted(base);
      await runner.start(requests: c.requests, collection: c);
      expect(engine.runs, isEmpty);
      expect(runner.results.single.response.statusCode, 200);
    });

    test('a marked request runs none of its scripts', () async {
      final engine = RecordingEngine();
      final reopened = RequestModel(
        name: 'Ping',
        url: '$base/ping',
        testScript: 'pm.test("request ran", () => {});',
        untrustedScripts: true,
      );
      final res = await RequestExecutor(
        http,
        engine: engine,
      ).execute(reopened, ExecContext(scopes: VarScopes()));
      expect(engine.runs, isEmpty);
      expect(paths, ['/ping']);
      expect(res.logs.single.message, contains('"Ping" came from an imported'));

      // A marked request without scripts of its own leaves a trusted
      // collection's scripts alone.
      final c = scripted(base, untrusted: false);
      final plain = RequestModel(
        name: 'Plain',
        url: '$base/ping',
        folder: 'F',
        untrustedScripts: true,
      );
      await RequestExecutor(
        http,
        engine: engine,
      ).execute(plain, ExecContext(scopes: VarScopes(), collection: c));
      expect(engine.runs.length, 2);
    });

    test('which requests need consent', () {
      final c = scripted(base);
      expect(collectionScriptCount(c), 3);
      expect(needsScriptConsent(c, c.requests), isTrue);
      final plain = RequestModel(name: 'Plain', folder: 'G');
      final quiet = CollectionModel(
        name: 'Q',
        untrusted: true,
        requests: [plain],
        folders: {'F': FolderMeta(testScript: 'x();')},
      );
      expect(needsScriptConsent(quiet, [plain]), isFalse);
      expect(
        needsScriptConsent(scripted(base, untrusted: false), c.requests),
        isFalse,
      );
      expect(needsScriptConsent(null, c.requests), isFalse);

      final marked = c.requests.single.clone()..untrustedScripts = true;
      final q = scriptConsentQuestion(null, [marked])!;
      expect(q.request, isTrue);
      expect(q.name, 'Ping');
      expect(q.scripts, 1);
      expect(scriptConsentQuestion(c, [marked])!.request, isFalse);
    });
  });

  group('the app', () {
    late Directory dir;
    late AppState state;

    Future<AppState> load() async {
      final s = AppState(storage: Storage(overrideDir: dir));
      while (!s.loaded) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      return s;
    }

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('aw_consent_');
      state = await load();
    });

    tearDown(() async {
      await state.flushPending();
      state.dispose();
      await deleteTempDir(dir);
    });

    List<String> consoleText() => [
      for (final e in state.console.entries)
        if (e is LineEntry) e.line.message,
    ];

    test('imported collections start untrusted', () {
      final (n, _) = state.addImported([scripted(base, untrusted: false)], []);
      expect(n, 1);
      expect(state.collections.single.untrusted, isTrue);
    });

    test('importing scripted requests into a collection marks it', () {
      final mine = state.addCollection('Mine');
      state.addToCollection(mine, [
        CollectionModel(
          name: 'HAR',
          requests: [RequestModel(name: 'a')],
        ),
      ]);
      expect(mine.untrusted, isFalse, reason: 'no scripts came along');
      state.addToCollection(mine, [scripted(base, untrusted: false)]);
      expect(mine.untrusted, isTrue);
    });

    test('Send asks once: without scripts, then allowed for good', () async {
      state.addImported([scripted(base)], []);
      final c = state.collections.single;
      state.openRequest(c.requests.single, collectionId: c.id);
      final asked = <int>[];
      var answer = ScriptConsent.skipScripts;
      state.askScriptConsent = (q) async {
        expect(q.name, 'Imported');
        expect(q.request, isFalse);
        asked.add(q.scripts);
        return answer;
      };

      await state.sendActive();
      expect(asked, [3]);
      expect(paths, ['/ping']);
      expect(state.activeTab!.scriptTests, isEmpty);
      expect(c.untrusted, isTrue);
      expect(consoleText().last, contains('Scripts were not run'));

      // Still untrusted, so the next send asks again.
      answer = ScriptConsent.allow;
      await state.sendActive();
      expect(asked, [3, 3]);
      expect(c.untrusted, isFalse);
      expect(
        state.activeTab!.scriptTests.map((t) => t.name),
        containsAll(['folder', 'request ran']),
      );
      expect(state.activeTab!.scriptError, isNull);

      // Allowed for good: no more questions, and it is saved.
      await state.sendActive();
      expect(asked.length, 2);
      await state.flushPending();
      final saved = await Storage(overrideDir: dir).loadCollections();
      expect(saved.single.untrusted, isFalse);
    });

    test('Cancel sends nothing', () async {
      state.addImported([scripted(base)], []);
      final c = state.collections.single;
      state.openRequest(c.requests.single, collectionId: c.id);
      state.askScriptConsent = (_) async => ScriptConsent.cancel;
      await state.sendActive();
      expect(paths, isEmpty);
      expect(state.activeTab!.loading, isFalse);
      expect(state.activeTab!.response, isNull);
      expect(c.untrusted, isTrue);
    });

    test('no question without scripts, or with scripts turned off', () async {
      final quiet = CollectionModel(
        name: 'Quiet',
        requests: [RequestModel(name: 'Ping', url: '$base/ping')],
      );
      state.addImported([quiet], []);
      var asked = 0;
      state.askScriptConsent = (_) async {
        asked++;
        return ScriptConsent.cancel;
      };
      state.openRequest(quiet.requests.single, collectionId: quiet.id);
      await state.sendActive();
      expect(asked, 0);
      expect(paths, ['/ping']);

      state.addImported([scripted(base)], []);
      final loud = state.collections.last;
      state.updateSettings(AppSettings(scriptsEnabled: false));
      state.openRequest(loud.requests.single, collectionId: loud.id);
      await state.sendActive();
      expect(asked, 0);
      expect(paths, ['/ping', '/ping']);
    });

    test('History keeps the mark, and a reopened request asks first', () async {
      state.addImported([scripted(base)], []);
      final c = state.collections.single;
      state.openRequest(c.requests.single, collectionId: c.id);
      final asked = <ScriptConsentQuestion>[];
      var answer = ScriptConsent.skipScripts;
      state.askScriptConsent = (q) async {
        asked.add(q);
        return answer;
      };
      await state.sendActive();
      expect(asked.single.request, isFalse);
      final entry = state.history.first;
      expect(entry.request.untrustedScripts, isTrue);
      expect(
        HistoryEntry.fromJson(
          jsonDecode(jsonEncode(entry.toJson())) as Map<String, dynamic>,
        ).request.untrustedScripts,
        isTrue,
      );

      // What the History list does when an entry is tapped.
      state.newTab(entry.request.clone());
      await state.sendActive();
      expect(asked.length, 2);
      expect(asked.last.request, isTrue);
      expect(asked.last.name, 'Ping');
      expect(asked.last.scripts, 1);
      expect(paths, ['/ping', '/ping']);
      expect(state.activeTab!.scriptTests, isEmpty);
      expect(consoleText().last, contains('came from an imported collection'));
      expect(state.history.first.request.untrustedScripts, isTrue);

      answer = ScriptConsent.allow;
      await state.sendActive();
      expect(asked.length, 3);
      expect(state.activeTab!.scriptTests.map((t) => t.name), ['request ran']);
      expect(state.activeTab!.request.untrustedScripts, isFalse);
      expect(state.history.first.request.untrustedScripts, isFalse);
      expect(c.untrusted, isTrue, reason: 'only the request was allowed');

      await state.sendActive();
      expect(asked.length, 3);
    });

    test('old history entries reopen as before', () async {
      final old = HistoryEntry.fromJson({
        'request': {
          'name': 'Mine',
          'url': '$base/ping',
          'testScript': 'pm.test("mine", () => {});',
        },
      });
      state.askScriptConsent = (_) async => ScriptConsent.cancel;
      state.newTab(old.request.clone());
      await state.sendActive();
      expect(paths, ['/ping']);
      expect(state.activeTab!.scriptTests.map((t) => t.name), ['mine']);
    });

    test('allowing a marked request clears its saved copy', () async {
      final mine = state.addCollection('Mine');
      mine.requests.add(
        RequestModel(
          name: 'Saved',
          url: '$base/ping',
          testScript: 'pm.test("saved", () => {});',
          untrustedScripts: true,
        ),
      );
      state.updateCollections();
      state.openRequest(mine.requests.single, collectionId: mine.id);
      expect(
        state.scriptConsentNeeded(mine.id, [state.activeTab!.request]),
        isTrue,
      );
      state.askScriptConsent = (_) async => ScriptConsent.allow;
      await state.sendActive();
      expect(mine.requests.single.untrustedScripts, isFalse);
      await state.flushPending();
      final saved = await Storage(overrideDir: dir).loadCollections();
      expect(saved.single.requests.single.untrustedScripts, isFalse);
    });

    test('the runner asks for a marked request without a collection', () async {
      final marked = RequestModel(
        name: 'Ping',
        url: '$base/ping',
        testScript: 'x();',
        untrustedScripts: true,
      );
      expect(state.scriptConsentNeeded(null, [marked]), isTrue);
      ScriptConsentQuestion? asked;
      final go = await state.allowImportedScripts(
        null,
        [marked],
        ask: (q) async {
          asked = q;
          return ScriptConsent.cancel;
        },
      );
      expect(go, isFalse);
      expect(asked!.request, isTrue);
      expect(marked.untrustedScripts, isTrue);
    });

    test('globals: an import never silently replaces a value', () {
      state.globals.addAll([
        KV(key: 'host', value: 'mine.test'),
        KV(key: 'same', value: 'x'),
        KV(key: 'token', value: '', current: 'live'),
      ]);
      final imported = [
        KV(key: 'host', value: 'theirs.test'),
        KV(key: 'same', value: 'x'),
        KV(key: 'token', value: ''),
        KV(key: 'fresh', value: 'new'),
      ];
      expect(state.conflictingGlobals(imported), ['host', 'token']);

      expect(state.mergeGlobals(imported), 1, reason: 'only "fresh"');
      expect(kvMap(state.globals), {
        'host': 'mine.test',
        'same': 'x',
        'token': 'live',
        'fresh': 'new',
      });

      expect(state.mergeGlobals(imported, overwrite: true), 4);
      expect(kvMap(state.globals)['host'], 'theirs.test');
      expect(kvMap(state.globals)['token'], '');
    });
  });

  test('every import goes through the untrusted handling', () {
    // mergeWorkspace adds collections as they are; imports use
    // AppState.addImported, which marks them. Only a version-history
    // restore (the user's own snapshot) may call it directly.
    final callers = <String>{
      for (final f in Directory('lib').listSync(recursive: true))
        if (f is File &&
            f.path.endsWith('.dart') &&
            f.readAsStringSync().contains('.mergeWorkspace('))
          f.path.replaceAll(r'\', '/'),
    };
    expect(callers.difference({'lib/ui/version_history_dialog.dart'}), isEmpty);
  });
}
