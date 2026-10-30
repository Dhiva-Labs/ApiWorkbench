import '../models/models.dart';

/// What an import produced, plus everything worth telling the user about
/// what could not be carried over.
class ImportReport {
  final collections = <CollectionModel>[];
  final environments = <EnvironmentModel>[];

  /// Variables for the Globals scope (Postman globals files and dumps).
  final globals = <KV>[];

  /// Human-readable source formats seen, e.g. "Postman collection v2.1".
  final formats = <String>{};

  int requests = 0;
  int folders = 0;

  /// Scripts are imported as they are and run, never converted, so these
  /// stay 0. They remain for callers written before scripts ran.
  int assertionsFromScripts = 0;
  int capturesFromScripts = 0;

  /// Pre-request and test scripts carried over (request, folder and
  /// collection level).
  int scriptsKept = 0;

  /// Saved response examples carried over.
  int examples = 0;
  int bodiesOnGetOrHead = 0;

  /// Postman auth type names with no equivalent here (e.g. `asap`) →
  /// how many requests, folders and collections used them.
  final unsupportedAuth = <String, int>{};
  final notes = <String>[];

  bool get isEmpty =>
      collections.isEmpty && environments.isEmpty && globals.isEmpty;

  /// One line per thing the user may need to act on.
  List<String> get warnings => [
    for (final e in unsupportedAuth.entries)
      '${e.value} request(s) or folder(s) use ${authLabel(e.key)} auth, '
          'which ApiWorkbench does not support; their auth was left empty.',
    if (bodiesOnGetOrHead > 0)
      '$bodiesOnGetOrHead HEAD request(s) have a body, which '
          'ApiWorkbench does not send for HEAD.',
    ...notes,
  ];
}

String authLabel(String t) => switch (t) {
  'asap' => 'ASAP (Atlassian)',
  _ => authTypeFromPostman(t)?.label ?? t,
};
