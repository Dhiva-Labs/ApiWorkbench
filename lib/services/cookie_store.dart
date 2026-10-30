import 'dart:async';
import 'dart:io' show Cookie;

import 'cookie_jar.dart';
import 'json_store.dart';

/// The app's cookie jar: RFC 6265 storage and matching, saved in
/// cookies.json.
///
/// - Cookies come from Set-Cookie headers ([saveFromResponse]) and from the
///   cookie manager ([add], [update], [delete], [clearDomain], [clear]).
/// - A request gets the cookies whose domain, path and Secure flag match its
///   URL ([cookieHeaderFor], [matching]), longest path first, then oldest.
/// - Session cookies are kept across restarts too, as Postman does.
/// - Free of Flutter: the UI listens to [changes].
class PersistentCookieJar implements CookieJar {
  PersistentCookieJar([this._store]);

  /// The file the jar lives in.
  static const fileName = 'cookies.json';

  /// Browsers cap cookies per site; without a cap a server could grow the
  /// jar (and cookies.json) without bound. The oldest cookies go first.
  static const maxPerDomain = 180;
  static const maxTotal = 3000;

  final JsonStore? _store;

  /// Insertion order is creation order: replacing a cookie keeps its place.
  final Map<CookieKey, StoredCookie> _cookies = {};

  /// Replaceable in tests to move time.
  DateTime Function() clock = DateTime.now;

  /// How long changes wait before they are written, so a burst of
  /// Set-Cookie headers is one write.
  Duration saveDelay = const Duration(milliseconds: 400);

  final _changes = StreamController<void>.broadcast();
  Timer? _saveTimer;
  bool _dirty = false;
  Future<void> _writes = Future.value();
  int _version = 0;

  /// Fires after every change made through the API or a response. For
  /// widgets: `StreamBuilder(stream: jar.changes, ...)`.
  Stream<void> get changes => _changes.stream;

  /// Counts changes; cheap to compare when a cache must be refreshed.
  int get version => _version;

  /// Number of cookies, expired ones excluded.
  int get count {
    _purge(clock().toUtc());
    return _cookies.length;
  }

  /// Reads cookies.json. Expired cookies are dropped; a missing or damaged
  /// file leaves the jar as it is.
  Future<void> load() async {
    final store = _store;
    if (store == null) return;
    final j = await store.readJson(fileName);
    final list = j is Map ? j['cookies'] : j;
    if (list is! List) return;
    final now = clock().toUtc();
    var dropped = false;
    for (final item in list) {
      final c = StoredCookie.fromJson(item);
      if (c == null) continue;
      if (c.isExpired(now)) {
        dropped = true;
        continue;
      }
      _cookies.putIfAbsent(c.key, () => c);
    }
    if (dropped) _markDirty();
    _notify();
  }

  // -- CookieJar (what requests use) ----------------------------------------

  @override
  String? cookieHeaderFor(Uri url) {
    final hits = matching(url);
    if (hits.isEmpty) return null;
    return hits.map((c) => '${c.name}=${c.value}').join('; ');
  }

  @override
  List<Cookie> cookiesFor(Uri url) => [
    for (final c in matching(url)) c.toCookie(),
  ];

  @override
  void saveFromResponse(Uri url, List<String> setCookieHeaders) {
    final now = clock().toUtc();
    var changed = false;
    for (final raw in setCookieHeaders) {
      final sc = SetCookie.parse(raw);
      if (sc == null) continue; // Malformed: ignored, as browsers do.
      final cookie = evaluateSetCookie(sc, url, now: now).cookie;
      if (cookie != null && _put(cookie, now)) changed = true;
    }
    if (changed) _changed();
  }

  /// The cookies sent to [url], in sending order: longer paths first, then
  /// the ones that arrived first (RFC 6265 section 5.4).
  List<StoredCookie> matching(Uri url) {
    final now = clock().toUtc();
    _purge(now);
    final host = canonicalCookieHost(url);
    if (host.isEmpty) return const [];
    final path = url.path.isEmpty ? '/' : url.path;
    final secure = isSecureCookieContext(url);
    final hits = <(int, StoredCookie)>[];
    var i = 0;
    for (final c in _cookies.values) {
      i++;
      if (c.secure && !secure) continue;
      if (!(c.hostOnly ? host == c.domain : domainMatches(host, c.domain))) {
        continue;
      }
      if (!cookiePathMatches(path, c.path)) continue;
      hits.add((i, c));
    }
    // List.sort isn't stable, so ties fall back to insertion order.
    hits.sort((a, b) {
      final byPath = b.$2.path.length.compareTo(a.$2.path.length);
      if (byPath != 0) return byPath;
      final byAge = a.$2.created.compareTo(b.$2.created);
      return byAge != 0 ? byAge : a.$1.compareTo(b.$1);
    });
    return [for (final h in hits) h.$2];
  }

  // -- Cookie manager --------------------------------------------------------

  /// Every domain that has cookies, with how many, sorted by name.
  List<({String domain, int count})> domains() {
    _purge(clock().toUtc());
    final counts = <String, int>{};
    for (final c in _cookies.values) {
      counts[c.domain] = (counts[c.domain] ?? 0) + 1;
    }
    final names = counts.keys.toList()..sort();
    return [for (final d in names) (domain: d, count: counts[d]!)];
  }

  /// The cookies filed under [domain], sorted by name, then path.
  List<StoredCookie> cookiesIn(String domain) {
    _purge(clock().toUtc());
    return [
      for (final c in _cookies.values)
        if (c.domain == domain) c,
    ]..sort(_byNameThenPath);
  }

  /// All cookies, sorted by domain, name, then path.
  List<StoredCookie> all() {
    _purge(clock().toUtc());
    return _cookies.values.toList()..sort((a, b) {
      final d = a.domain.compareTo(b.domain);
      return d != 0 ? d : _byNameThenPath(a, b);
    });
  }

  static int _byNameThenPath(StoredCookie a, StoredCookie b) {
    final n = a.name.compareTo(b.name);
    return n != 0 ? n : a.path.compareTo(b.path);
  }

  /// Adds [cookie], replacing the one with the same domain, path and name.
  /// An already expired cookie deletes it instead.
  void add(StoredCookie cookie) {
    if (_put(cookie, clock().toUtc())) _changed();
  }

  /// Replaces [old] with [edited]. The cookie keeps its creation time, so
  /// editing a value doesn't change the sending order.
  void update(StoredCookie old, StoredCookie edited) {
    final now = clock().toUtc();
    final current = _cookies[old.key];
    if (current != null && old.key == edited.key && !edited.isExpired(now)) {
      // Same identity: overwrite in place, keeping its slot in the order.
      _cookies[old.key] = edited.copyWith(created: current.created);
    } else {
      final removed = _cookies.remove(old.key);
      _put(edited.copyWith(created: removed?.created), now);
    }
    _changed();
  }

  /// Removes [cookie]; false when it isn't in the jar.
  bool delete(StoredCookie cookie) {
    final removed = _cookies.remove(cookie.key) != null;
    if (removed) _changed();
    return removed;
  }

  /// Removes every cookie filed under [domain]; returns how many.
  int clearDomain(String domain) {
    final before = _cookies.length;
    _cookies.removeWhere((_, c) => c.domain == domain);
    final n = before - _cookies.length;
    if (n > 0) _changed();
    return n;
  }

  /// Removes everything.
  void clear() {
    if (_cookies.isEmpty) return;
    _cookies.clear();
    _changed();
  }

  // -- Internals -------------------------------------------------------------

  /// Stores [c] unless it is already expired, in which case it removes the
  /// cookie it would have replaced. True when the jar changed.
  bool _put(StoredCookie c, DateTime now) {
    final old = _cookies[c.key];
    if (c.isExpired(now)) return _cookies.remove(c.key) != null;
    _cookies[c.key] = old == null ? c : c.copyWith(created: old.created);
    _enforceLimits(c.domain);
    return true;
  }

  void _enforceLimits(String domain) {
    if (_cookies.length <= maxPerDomain) return;
    final mine = [
      for (final c in _cookies.values)
        if (c.domain == domain) c,
    ];
    if (mine.length > maxPerDomain) {
      mine.sort((a, b) => a.created.compareTo(b.created));
      for (final c in mine.take(mine.length - maxPerDomain)) {
        _cookies.remove(c.key);
      }
    }
    final over = _cookies.length - maxTotal;
    if (over > 0) {
      final oldest = _cookies.values.toList()
        ..sort((a, b) => a.created.compareTo(b.created));
      for (final c in oldest.take(over)) {
        _cookies.remove(c.key);
      }
    }
  }

  void _purge(DateTime now) {
    final before = _cookies.length;
    _cookies.removeWhere((_, c) => c.isExpired(now));
    if (_cookies.length != before) _markDirty();
  }

  void _changed() {
    _markDirty();
    _notify();
  }

  void _notify() {
    _version++;
    if (!_changes.isClosed) _changes.add(null);
  }

  void _markDirty() {
    if (_store == null) return;
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(saveDelay, () => unawaited(flush()));
  }

  /// Writes pending changes now and waits until every queued write has
  /// landed. Writes go through one queue, so they can't overtake each other.
  Future<void> flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    final store = _store;
    if (store != null && _dirty) {
      _dirty = false;
      final payload = <String, Object?>{
        'version': 1,
        'cookies': [for (final c in _cookies.values) c.toJson()],
      };
      _writes = _writes
          .then((_) => store.writeJson(fileName, payload))
          .catchError((Object _) {
            // A failed write (disk full, ...) must not block later ones.
          });
    }
    return _writes;
  }

  /// Saves what is pending and stops notifying.
  Future<void> dispose() async {
    await flush();
    await _changes.close();
  }
}
