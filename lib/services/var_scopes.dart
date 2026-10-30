import '../models/models.dart';

/// Postman's variable scopes, lowest precedence first.
enum VarScope { globals, collection, environment, data, local }

/// The variables one execution sees, over the live variable lists, so
/// scripts and captures write straight into globals, the collection and
/// the environment. Writes set the variable's current value; a new
/// variable gets an empty initial value, as in Postman.
class VarScopes {
  VarScopes({
    this.globals,
    this.collection,
    this.environment,
    Map<String, String>? session,
    Map<String, String>? data,
  }) : session = session ?? {},
       data = data ?? {};

  final List<KV>? globals;
  final List<KV>? collection;
  final List<KV>? environment;

  /// Values kept for this app session only: the environment's stand-in
  /// when none is selected. Sits between collection and environment.
  final Map<String, String> session;

  /// The runner's current data row (read-only for scripts).
  final Map<String, String> data;

  /// `pm.variables.set`: this execution only, highest precedence.
  final Map<String, String> local = {};

  bool globalsChanged = false;
  bool collectionChanged = false;
  bool environmentChanged = false;

  /// Every variable, higher scopes winning.
  Map<String, String> resolve() => {
    ...kvMap(globals),
    ...kvMap(collection),
    ...session,
    ...kvMap(environment),
    ...data,
    ...local,
  };

  List<KV>? _list(VarScope s) => switch (s) {
    VarScope.globals => globals,
    VarScope.collection => collection,
    VarScope.environment => environment,
    _ => null,
  };

  void _markChanged(VarScope s) {
    switch (s) {
      case VarScope.globals:
        globalsChanged = true;
      case VarScope.collection:
        collectionChanged = true;
      case VarScope.environment:
        environmentChanged = true;
      case VarScope.data || VarScope.local:
        break;
    }
  }

  /// Value of [key] in [scope] only (null when unset).
  String? get(VarScope scope, String key) {
    switch (scope) {
      case VarScope.data:
        return data[key];
      case VarScope.local:
        return local[key];
      case VarScope.environment when environment == null:
        return session[key];
      default:
        for (final v in _list(scope) ?? const <KV>[]) {
          if (v.enabled && v.key == key) return v.effective;
        }
        return null;
    }
  }

  /// All enabled values of [scope].
  Map<String, String> all(VarScope scope) => switch (scope) {
    VarScope.data => Map.of(data),
    VarScope.local => Map.of(local),
    VarScope.environment when environment == null => Map.of(session),
    _ => kvMap(_list(scope)),
  };

  void set(VarScope scope, String key, String value) {
    if (key.isEmpty) return;
    switch (scope) {
      case VarScope.data:
        return; // read-only
      case VarScope.local:
        local[key] = value;
        return;
      case VarScope.environment when environment == null:
        session[key] = value;
        return;
      default:
        final list = _list(scope);
        if (list == null) return;
        final row = list.where((v) => v.key == key).firstOrNull;
        if (row != null) {
          row
            ..current = value
            ..enabled = true;
        } else {
          list.add(KV(key: key, current: value));
        }
        _markChanged(scope);
    }
  }

  void unset(VarScope scope, String key) {
    switch (scope) {
      case VarScope.data:
        return;
      case VarScope.local:
        local.remove(key);
        return;
      case VarScope.environment when environment == null:
        session.remove(key);
        return;
      default:
        final list = _list(scope);
        if (list == null) return;
        final before = list.length;
        list.removeWhere((v) => v.key == key);
        if (list.length != before) _markChanged(scope);
    }
  }

  void clear(VarScope scope) {
    switch (scope) {
      case VarScope.data:
        return;
      case VarScope.local:
        local.clear();
      case VarScope.environment when environment == null:
        session.clear();
      default:
        final list = _list(scope);
        if (list == null || list.isEmpty) return;
        list.clear();
        _markChanged(scope);
    }
  }

  /// Where Captures store values: the environment when one is selected,
  /// else the collection, else the session.
  void capture(Map<String, String> values) {
    final scope = environment != null
        ? VarScope.environment
        : (collection != null ? VarScope.collection : VarScope.environment);
    values.forEach((k, v) => set(scope, k, v));
  }
}
