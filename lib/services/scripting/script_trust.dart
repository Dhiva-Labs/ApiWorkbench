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

/// Whether [r] carries scripts of its own that were never allowed (see
/// [RequestModel.untrustedScripts]).
bool hasUntrustedOwnScripts(RequestModel r) =>
    r.untrustedScripts && requestHasScripts(r, null);

/// What the user is asked about before scripts that were never allowed
/// run for the first time.
class ScriptConsentQuestion {
  const ScriptConsentQuestion({
    required this.name,
    required this.scripts,
    this.request = false,
  });

  /// The imported collection's name, or the request's.
  final String name;

  /// How many pre-request and test scripts it carries.
  final int scripts;

  /// A request that came from an imported collection (reopened from
  /// History, for one) rather than the collection itself.
  final bool request;
}

/// The question to ask before sending [requests] from [c], or null when
/// nothing needs consent: [c] came from an import and its scripts were
/// never allowed, or a request carries such scripts of its own, and at
/// least one of them would run.
ScriptConsentQuestion? scriptConsentQuestion(
  CollectionModel? c,
  Iterable<RequestModel> requests,
) {
  if (c != null &&
      c.untrusted &&
      requests.any((r) => requestHasScripts(r, c))) {
    return ScriptConsentQuestion(
      name: c.name,
      scripts: collectionScriptCount(c),
    );
  }
  final own = requests.where(hasUntrustedOwnScripts).toList();
  if (own.isEmpty) return null;
  var n = 0;
  for (final r in own) {
    if (_has(r.preRequestScript)) n++;
    if (_has(r.testScript)) n++;
  }
  return ScriptConsentQuestion(
    name: own.length == 1 ? own.single.name : '${own.length} requests',
    scripts: n,
    request: true,
  );
}

/// Whether sending [requests] from [c] needs the user's consent first (see
/// [scriptConsentQuestion]).
bool needsScriptConsent(CollectionModel? c, Iterable<RequestModel> requests) =>
    scriptConsentQuestion(c, requests) != null;
