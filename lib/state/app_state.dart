import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/models.dart';
import '../services/cookie_store.dart';
import '../services/executor.dart';
import '../services/http_service.dart';
import '../services/scripting/engine_factory.dart';
import '../services/scripting/script_engine.dart';
import '../services/sound_service.dart';
import '../services/storage.dart';
import '../services/var_scopes.dart';
import '../services/version_history.dart';
import '../ui/help_tip.dart';
import 'console_log.dart';

/// One open editor tab: a working copy of a request plus its latest response.
class RequestTab {
  RequestTab({required this.request, this.sourceCollectionId});

  final String id = newId();
  RequestModel request;
  String? sourceCollectionId; // set when the tab was opened from a collection
  ResponseData? response;
  List<AssertionResult> assertionResults = [];

  /// `pm.test` results and the script failure of the last send, if any.
  List<ScriptTestResult> scriptTests = [];
  String? scriptError;

  /// `pm.visualizer.set` output of the last send.
  VisualizerOutput? visualizer;
  bool loading = false;
  bool dirty = false;

  /// Live connection of a non-HTTP tab (WebSocket, MQTT, ...). Owned and
  /// disposed by that protocol's view; closed when the tab closes.
  Object? session;
}

/// A protocol session that must be closed with its tab.
abstract interface class TabSession {
  void close();
}

class AppState extends ChangeNotifier {
  AppState({Storage? storage, SoundService? sounds})
    : _storage = storage ?? Storage(),
      sounds = sounds ?? SoundService() {
    _init();
  }

  final Storage _storage;
  final HttpService http = HttpService();

  /// Script engine for this platform; null when none is available.
  /// Reads its sandbox from the asset bundle, which on Android lives
  /// inside the APK rather than on disk.
  final ScriptEngine? scripts = createScriptEngine(
    loadAsset: rootBundle.loadString,
  );
  late final RequestExecutor executor = RequestExecutor(http, engine: scripts);
  late final PersistentCookieJar cookies = PersistentCookieJar(_storage);
  late final CollectionHistory collectionHistory = CollectionHistory(_storage);

  /// Every exchange and script line, for the console panel.
  final ConsoleLog console = ConsoleLog();
  StreamSubscription<Object>? _exchangeSub;

  /// Injected in tests so the sound library lives in a temp directory.
  final SoundService sounds;

  bool loaded = false;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _exchangeSub?.cancel();
    for (final t in tabs) {
      _closeSession(t);
    }
    http.dispose();
    scripts?.dispose();
    console.dispose();
    tabs.clear();
    super.dispose();
  }

  final List<RequestTab> tabs = [];
  int activeTabIndex = 0;

  List<CollectionModel> collections = [];
  List<EnvironmentModel> environments = [];

  /// The Globals scope: seen by every request, lowest precedence.
  List<KV> globals = [];
  String? activeEnvironmentId;
  List<HistoryEntry> history = [];
  AppSettings settings = AppSettings();

  RequestTab? get activeTab =>
      tabs.isEmpty ? null : tabs[activeTabIndex.clamp(0, tabs.length - 1)];

  EnvironmentModel? get activeEnvironment {
    for (final e in environments) {
      if (e.id == activeEnvironmentId) return e;
    }
    return null;
  }

  Map<String, String> get activeVars => kvMap(activeEnvironment?.variables);

  /// Values of every secret variable (globals, collections,
  /// environments), initial and current, for masking in the console, docs
  /// and exports.
  Set<String> get secretValues => {
    for (final list in [
      globals,
      for (final c in collections) c.variables,
      for (final e in environments) e.variables,
    ])
      for (final v in list)
        if (v.secret) ...[
          if (v.value.isNotEmpty) v.value,
          if ((v.current ?? '').isNotEmpty) v.current!,
        ],
  };

  /// Values captured by requests outside any collection while no
  /// environment is active; kept for this session only.
  final Map<String, String> sessionVars = {};

  CollectionModel? collectionById(String? id) {
    if (id == null) return null;
    for (final c in collections) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Live variable scopes for a request in [collectionId] (or none).
  VarScopes scopesFor(String? collectionId) => VarScopes(
    globals: globals,
    collection: collectionById(collectionId)?.variables,
    environment: activeEnvironment?.variables,
    session: sessionVars,
  );

  /// Variables for a request: globals, collection, session captures, then
  /// the active environment (highest), matching Postman's scope order.
  Map<String, String> varsFor(String? collectionId) =>
      scopesFor(collectionId).resolve();

  /// Saves what an execution changed (variables) and logs its script
  /// output. Used by the editor and the runner.
  void absorb(VarScopes scopes, ExecResult result) {
    if (scopes.environmentChanged) {
      _storage.saveEnvironments(environments, activeEnvironmentId);
    }
    if (scopes.collectionChanged) _storage.saveCollections(collections);
    if (scopes.globalsChanged) _storage.saveGlobals(globals);
    scopes
      ..environmentChanged = false
      ..collectionChanged = false
      ..globalsChanged = false;
    console.addLines(result.logs);
  }

  Future<void> _init() async {
    collections = await _storage.loadCollections();
    final (envs, activeId) = await _storage.loadEnvironments();
    environments = envs;
    activeEnvironmentId = activeId;
    history = await _storage.loadHistory();
    globals = await _storage.loadGlobals();
    settings = await _storage.loadSettings();
    await cookies.load();
    http.cookieJar = cookies;
    _exchangeSub = http.exchanges.listen(console.addExchange);
    hoverHelpEnabled.value = settings.hoverHelp;
    if (_disposed) return;
    http.configure(settings);
    if (tabs.isEmpty) newTab();
    loaded = true;
    notifyListeners();
  }

  /// Writes everything that is saved lazily (cookies, collection history,
  /// queued files). Called when the app is hidden or about to exit.
  Future<void> flushPending() => Future.wait([
    cookies.flush(),
    collectionHistory.flush(),
    _storage.flush(),
  ]);

  /// Lets UI trigger a rebuild after mutating owned services (sound library).
  void notifyRefresh() => notifyListeners();

  void updateSettings(AppSettings s) {
    settings = s;
    hoverHelpEnabled.value = s.hoverHelp;
    http.configure(s);
    _storage.saveSettings(s);
    notifyListeners();
  }

  /// Merges an imported workspace: same-id items are replaced, new ones
  /// added. Returns (collections, environments) counts actually imported.
  (int, int) mergeWorkspace(
    List<CollectionModel> cols,
    List<EnvironmentModel> envs,
  ) {
    for (final c in cols) {
      collections.removeWhere((x) => x.id == c.id);
      collections.add(c);
    }
    for (final e in envs) {
      environments.removeWhere((x) => x.id == e.id);
      environments.add(e);
    }
    if (cols.isNotEmpty) _storage.saveCollections(collections);
    if (envs.isNotEmpty) {
      _storage.saveEnvironments(environments, activeEnvironmentId);
    }
    notifyListeners();
    return (cols.length, envs.length);
  }

  /// Adds imported globals; an existing name gets the imported value.
  int mergeGlobals(List<KV> imported) {
    for (final v in imported) {
      if (v.key.isEmpty) continue;
      globals.removeWhere((x) => x.key == v.key);
      globals.add(v);
    }
    if (imported.isNotEmpty) updateGlobals();
    return imported.length;
  }

  /// Persists after editing [globals] in place.
  void updateGlobals() {
    _storage.saveGlobals(globals);
    notifyListeners();
  }

  /// Adds imported requests into an existing collection instead of creating
  /// new ones. Requests keep their folders, nested under [folder]; with
  /// [groupByCollection] each imported collection gets its own folder.
  /// Imported collection variables are added only where [target] has no
  /// variable of that name, so existing values are never overwritten.
  ({int requests, int variables}) addToCollection(
    CollectionModel target,
    List<CollectionModel> imported, {
    String folder = '',
    bool groupByCollection = false,
  }) {
    String join(String a, String b) =>
        a.isEmpty ? b : (b.isEmpty ? a : '$a/$b');
    var requests = 0;
    var variables = 0;
    for (final c in imported) {
      final base = groupByCollection
          ? join(folder, c.name.replaceAll('/', '∕'))
          : folder;
      for (final r in c.requests) {
        r.folder = join(base, r.folder);
        target.requests.add(r);
        requests++;
      }
      for (final v in c.variables) {
        if (v.key.isEmpty || target.variables.any((x) => x.key == v.key)) {
          continue;
        }
        target.variables.add(v);
        variables++;
      }
    }
    _persistCollections();
    return (requests: requests, variables: variables);
  }

  // ---------------- Tabs ----------------

  void newTab([RequestModel? request, String? sourceCollectionId]) {
    tabs.add(
      RequestTab(
        request: request ?? RequestModel(),
        sourceCollectionId: sourceCollectionId,
      ),
    );
    activeTabIndex = tabs.length - 1;
    notifyListeners();
  }

  void openRequest(RequestModel r, {String? collectionId}) {
    // Re-focus an existing tab editing the same saved request.
    for (var i = 0; i < tabs.length; i++) {
      if (tabs[i].request.id == r.id) {
        activeTabIndex = i;
        notifyListeners();
        return;
      }
    }
    newTab(r.clone(sameId: true), collectionId);
  }

  void _closeSession(RequestTab t) {
    final session = t.session;
    if (session is TabSession) session.close();
    t.session = null;
  }

  void closeTab(int index) {
    http.cancel(tabs[index].id);
    _closeSession(tabs[index]);
    tabs.removeAt(index);
    if (tabs.isEmpty) {
      newTab();
      return;
    }
    if (activeTabIndex >= tabs.length) activeTabIndex = tabs.length - 1;
    notifyListeners();
  }

  void selectTab(int index) {
    activeTabIndex = index;
    notifyListeners();
  }

  /// Call after mutating the active tab's request from the editor.
  void touchActive() {
    final t = activeTab;
    if (t != null) t.dirty = true;
    notifyListeners();
  }

  // ---------------- Sending ----------------

  Future<void> sendActive() async {
    final tab = activeTab;
    if (tab == null || tab.loading) return;
    if (tab.request.kind != RequestKind.http) return; // protocols connect
    tab.loading = true;
    tab.response = null;
    tab.assertionResults = [];
    tab.scriptTests = [];
    tab.scriptError = null;
    tab.visualizer = null;
    notifyListeners();

    final collection = collectionById(tab.sourceCollectionId);
    final scopes = scopesFor(tab.sourceCollectionId);
    final result = await executor.execute(
      tab.request,
      ExecContext(
        scopes: scopes,
        collection: collection,
        tabId: tab.id,
        onAuthUpdated: () {
          if (collection != null) _storage.saveCollections(collections);
          tab.dirty = true;
        },
      ),
    );
    if (_disposed || !tabs.contains(tab)) return;
    final res = result.response;
    tab.loading = false;
    tab.response = res;
    tab.assertionResults = result.assertions;
    tab.scriptTests = result.scriptTests;
    tab.scriptError = result.scriptError;
    tab.visualizer = result.visualizer;
    absorb(scopes, result);

    if (settings.chaosMode) {
      // Fire and forget — a missing player must never block the response.
      sounds.playForStatus(
        settings.chaosRules,
        res.statusCode,
        isError: res.error != null,
      );
    }

    history.insert(
      0,
      HistoryEntry(
        request: tab.request.clone()..examples = [],
        statusCode: res.statusCode,
        durationMs: res.durationMs,
        at: DateTime.now(),
      ),
    );
    if (history.length > 100) history.removeRange(100, history.length);
    _storage.saveHistory(history);
    notifyListeners();
  }

  void cancelActive() {
    final tab = activeTab;
    if (tab != null) http.cancel(tab.id);
  }

  // ---------------- Collections ----------------

  CollectionModel addCollection(String name) {
    final c = CollectionModel(name: name);
    collections.add(c);
    _persistCollections();
    return c;
  }

  void renameCollection(CollectionModel c, String name) {
    c.name = name;
    _persistCollections();
  }

  void deleteCollection(CollectionModel c) {
    collections.remove(c);
    _persistCollections();
  }

  /// Saves the active tab's request into [collection] (updating in place if it
  /// already lives there).
  void saveActiveTo(CollectionModel collection, {String? name}) {
    final tab = activeTab;
    if (tab == null) return;
    if (name != null && name.isNotEmpty) tab.request.name = name;

    // Replace the saved copy where it is, so saving keeps the request's
    // place in the collection; remove copies from other collections.
    final saved = tab.request.clone(sameId: true);
    final at = collection.requests.indexWhere((r) => r.id == saved.id);
    for (final c in collections) {
      if (c != collection) c.requests.removeWhere((r) => r.id == saved.id);
    }
    if (at >= 0) {
      collection.requests[at] = saved;
    } else {
      collection.requests.add(saved);
    }
    tab.sourceCollectionId = collection.id;
    tab.dirty = false;
    _persistCollections();
  }

  void deleteRequest(CollectionModel c, RequestModel r) {
    c.requests.remove(r);
    _persistCollections();
  }

  void duplicateRequest(CollectionModel c, RequestModel r) {
    final copy = r.clone()..name = '${r.name} (copy)';
    c.requests.insert(c.requests.indexOf(r) + 1, copy);
    _persistCollections();
  }

  /// Persists after editing a collection in place (e.g. its variables).
  void updateCollections() => _persistCollections();

  void _persistCollections() {
    _storage.saveCollections(collections);
    collectionHistory.record(collections);
    notifyListeners();
  }

  // ---------------- Environments ----------------

  EnvironmentModel addEnvironment(String name) {
    final e = EnvironmentModel(name: name);
    environments.add(e);
    activeEnvironmentId ??= e.id;
    _persistEnvironments();
    return e;
  }

  void updateEnvironment() => _persistEnvironments();

  void deleteEnvironment(EnvironmentModel e) {
    environments.remove(e);
    if (activeEnvironmentId == e.id) activeEnvironmentId = null;
    _persistEnvironments();
  }

  void setActiveEnvironment(String? id) {
    activeEnvironmentId = id;
    _persistEnvironments();
  }

  void _persistEnvironments() {
    _storage.saveEnvironments(environments, activeEnvironmentId);
    notifyListeners();
  }

  // ---------------- History ----------------

  void clearHistory() {
    history.clear();
    _storage.saveHistory(history);
    notifyListeners();
  }
}
