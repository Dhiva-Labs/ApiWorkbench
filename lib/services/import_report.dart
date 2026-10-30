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
  int assertionsFromScripts = 0;
  int capturesFromScripts = 0;

  /// Requests (or folders/collections) whose script text was kept but not
  /// fully converted.
  int scriptsKept = 0;
  int examplesSkipped = 0;
  int bodiesOnGetOrHead = 0;

  /// Postman auth type → requests that used it without an equivalent here.
  final unsupportedAuth = <String, int>{};
  final notes = <String>[];

  bool get isEmpty =>
      collections.isEmpty && environments.isEmpty && globals.isEmpty;

  /// One line per thing the user may need to act on.
  List<String> get warnings => [
    for (final e in unsupportedAuth.entries)
      '${e.value} request(s) use ${authLabel(e.key)} auth, which '
          'ApiWorkbench does not support yet; their auth was left empty.',
    if (scriptsKept > 0)
      '$scriptsKept Postman script(s) were found. ApiWorkbench does not run '
          'JavaScript, so recognised checks became Tests '
          '($assertionsFromScripts) and saved values became Captures '
          '($capturesFromScripts); the scripts themselves are kept on each '
          'request under Docs for reference.',
    if (examplesSkipped > 0)
      '$examplesSkipped saved response example(s) were not imported.',
    if (bodiesOnGetOrHead > 0)
      '$bodiesOnGetOrHead HEAD request(s) have a body, which '
          'ApiWorkbench does not send for HEAD.',
    ...notes,
  ];
}

String authLabel(String t) => switch (t) {
  'digest' => 'Digest',
  'oauth1' => 'OAuth 1.0',
  'oauth2' => 'OAuth 2.0 (no saved token)',
  'hawk' => 'Hawk',
  'awsv4' => 'AWS Signature',
  'ntlm' => 'NTLM',
  'edgegrid' => 'Akamai EdgeGrid',
  'jwt' => 'JWT Bearer',
  'asap' => 'ASAP (Atlassian)',
  _ => t,
};
