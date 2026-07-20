import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../services/assertions.dart';
import '../services/http_service.dart';
import '../services/sound_service.dart';
import '../services/storage.dart';

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
  AppState({Storage? storage}) : _storage = storage ?? Storage() {
    _init();
  }

  final Storage _storage;
  final HttpService http = HttpService();
  final SoundService sounds = SoundService();

  bool loaded = false;

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

  Future<void> _init() async {
    collections = await _storage.loadCollections();
    final (envs, activeId) = await _storage.loadEnvironments();
    environments = envs;
    activeEnvironmentId = activeId;
    history = await _storage.loadHistory();
    settings = await _storage.loadSettings();
    http.configure(settings);
    if (tabs.isEmpty) newTab();
    loaded = true;
    notifyListeners();
  }

  /// Lets UI trigger a rebuild after mutating owned services (sound library).
  void notifyRefresh() => notifyListeners();

  void updateSettings(AppSettings s) {
    settings = s;
    http.configure(s);
    _storage.saveSettings(s);
    notifyListeners();
  }

  /// Merges an imported workspace: same-id items are replaced, new ones
  /// added. Returns (collections, environments) counts actually imported.
  (int, int) mergeWorkspace(
      List<CollectionModel> cols, List<EnvironmentModel> envs) {
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

  // ---------------- Tabs ----------------

  void newTab([RequestModel? request, String? sourceCollectionId]) {
    tabs.add(RequestTab(
        request: request ?? RequestModel(),
        sourceCollectionId: sourceCollectionId));
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

    final res = await http.send(tab.request, activeVars, tabId: tab.id);
    tab.loading = false;
    tab.response = res;
    tab.assertionResults = evaluateAssertions(tab.request, res);

    if (settings.chaosMode) {
      // Fire and forget — a missing player must never block the response.
      sounds.playForStatus(settings.chaosRules, res.statusCode,
          isError: res.error != null);
    }

    history.insert(
        0,
        HistoryEntry(
          request: tab.request.clone(),
          statusCode: res.statusCode,
          durationMs: res.durationMs,
          at: DateTime.now(),
        ));
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
