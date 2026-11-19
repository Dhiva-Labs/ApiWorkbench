import '../../models/models.dart';

/// The user's answer when an imported collection's scripts would run for
/// the first time.
enum ScriptConsent {
  /// Run them, now and from now on: the collection becomes trusted.
  allow,

  /// Send without any scripts this time and ask again next time.
  skipScripts,

  /// Do not send.
  cancel,
}

bool _has(String script) => script.trim().isNotEmpty;

/// How many pre-request and test scripts [c] carries: collection, folder
/// and request level, each phase counted once.
int collectionScriptCount(CollectionModel c) {
  var n = 0;
  void add(String pre, String test) {
    if (_has(pre)) n++;
    if (_has(test)) n++;
  }

  add(c.preRequestScript, c.testScript);
  for (final f in c.folders.values) {
    add(f.preRequestScript, f.testScript);
  }
  for (final r in c.requests) {
    add(r.preRequestScript, r.testScript);
  }
  return n;
}

/// Whether sending [r] from [c] would run at least one script: the
/// collection's, a folder's on the request's path, or the request's own.
bool requestHasScripts(RequestModel r, CollectionModel? c) {
  if (_has(r.preRequestScript) || _has(r.testScript)) return true;
  if (c == null) return false;
  if (_has(c.preRequestScript) || _has(c.testScript)) return true;
  for (final path in CollectionModel.folderChain(r.folder)) {
    final f = c.folders[path];
    if (f != null && (_has(f.preRequestScript) || _has(f.testScript))) {
      return true;
    }
  }
  return false;
}

/// Whether sending [requests] from [c] needs the user's consent first:
/// [c] came from an import, its scripts were never allowed, and at least
/// one of the requests would run a script.
bool needsScriptConsent(CollectionModel? c, Iterable<RequestModel> requests) =>
    c != null && c.untrusted && requests.any((r) => requestHasScripts(r, c));
