import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../services/assertions.dart';
import '../services/captures.dart';
import '../services/http_service.dart';
import '../services/sound_service.dart';
import '../services/storage.dart';
import '../ui/help_tip.dart';

/// One open editor tab: a working copy of a request plus its latest response.
class RequestTab {
  RequestTab({required this.request, this.sourceCollectionId});

  final String id = newId();
  RequestModel request;
  String? sourceCollectionId; // set when the tab was opened from a collection
  ResponseData? response;
  List<AssertionResult> assertionResults = [];
  bool loading = false;
  bool dirty = false;
}

class AppState extends ChangeNotifier {
  AppState({Storage? storage, SoundService? sounds})
    : _storage = storage ?? Storage(),
      sounds = sounds ?? SoundService() {
    _init();
  }

  final Storage _storage;
  final HttpService http = HttpService();

  /// Injected in tests so the sound library lives in a temp directory.
  final SoundService sounds;

  bool loaded = false;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    http.dispose();
    tabs.clear();
    super.dispose();
  }

  final List<RequestTab> tabs = [];
  int activeTabIndex = 0;

  List<CollectionModel> collections = [];
  List<EnvironmentModel> environments = [];
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

  Map<String, String> get activeVars => {
    for (final v in activeEnvironment?.variables ?? <KV>[])
      if (v.enabled && v.key.isNotEmpty) v.key: v.value,
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

  /// Variables for a request: collection variables, then session captures,
  /// then the active environment (highest), matching Postman's scope order.
  Map<String, String> varsFor(String? collectionId) => {
    ...?collectionById(collectionId)?.variableMap,
    ...sessionVars,
    ...activeVars,
  };

  /// Stores captured values where later requests will see them: the active
  /// environment if one is selected, else the request's collection, else the
  /// session.
  void _storeCaptures(Map<String, String> values, String? collectionId) {
    if (values.isEmpty) return;
    final env = activeEnvironment;
    final col = collectionById(collectionId);
    final target = env?.variables ?? col?.variables;
    if (target == null) {
      sessionVars.addAll(values);
      return;
    }
    values.forEach((k, v) {
      final row = target.where((x) => x.key == k).firstOrNull;
      if (row != null) {
        row
          ..value = v
          ..enabled = true;
      } else {
        target.add(KV(key: k, value: v));
      }
    });
    if (env != null) {
      _storage.saveEnvironments(environments, activeEnvironmentId);
    } else {
      _storage.saveCollections(collections);
    }
  }

  Future<void> _init() async {
    collections = await _storage.loadCollections();
    final (envs, activeId) = await _storage.loadEnvironments();
    environments = envs;
    activeEnvironmentId = activeId;
    history = await _storage.loadHistory();
    settings = await _storage.loadSettings();
    hoverHelpEnabled.value = settings.hoverHelp;
    if (_disposed) return;
    http.configure(settings);
    if (tabs.isEmpty) newTab();
    loaded = true;
    notifyListeners();
  }

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

  void closeTab(int index) {
    http.cancel(tabs[index].id);
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
    tab.loading = true;
    tab.response = null;
    tab.assertionResults = [];
    notifyListeners();

    final res = await http.send(
      tab.request,
      varsFor(tab.sourceCollectionId),
      tabId: tab.id,
    );
    if (_disposed || !tabs.contains(tab)) return;
    tab.loading = false;
    tab.response = res;
    tab.assertionResults = evaluateAssertions(tab.request, res);
    if (res.error == null && tab.request.captures.isNotEmpty) {
      _storeCaptures(
        captureValues(tab.request.captures, res),
        tab.sourceCollectionId,
      );
    }

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
        request: tab.request.clone(),
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

    // Remove any older copy from all collections, then insert the new one.
    for (final c in collections) {
      c.requests.removeWhere((r) => r.id == tab.request.id);
    }
    collection.requests.add(tab.request.clone(sameId: true));
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
