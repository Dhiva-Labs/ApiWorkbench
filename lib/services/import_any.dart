import 'dart:convert';

import 'har_import.dart';
import 'openapi_import.dart';
import 'postman_import.dart';

export 'import_report.dart';

/// Imports one file of any supported format into [into]: OpenAPI 3.0/3.1 and
/// Swagger 2.0 (JSON or YAML), HAR captures, Postman collections and
/// environments, and ApiWorkbench workspaces. Everything found goes into one
/// [ImportReport] so several files can share it. Throws [FormatException] for
/// anything else.
///
/// The format is recognised by content, not by file name. JSON is decoded
/// once and sent to the first importer that claims it: an `openapi` or
/// `swagger` version means a spec, `log.entries` a HAR, anything else the
/// Postman and workspace importer. Text that is not JSON is read as YAML, and
/// only an OpenAPI or Swagger document can come out of that.
///
/// [skipStaticAssets] and [dedupeHar] apply to HAR files only (see
/// [importHar]).
ImportReport importAnyFile(
  String raw, {
  ImportReport? into,
  bool skipStaticAssets = true,
  bool dedupeHar = true,
}) {
  final text = raw.startsWith('﻿') ? raw.substring(1) : raw;

  Object? json;
  var isJson = true;
  try {
    json = jsonDecode(text);
  } on FormatException {
    isJson = false;
  }

  if (isJson) {
    if (looksLikeHar(json)) {
      return importHarDocument(
        json,
        into: into,
        skipStaticAssets: skipStaticAssets,
        dedupe: dedupeHar,
      );
    }
    if (looksLikeOpenApi(json)) return importOpenApiDocument(json, into: into);
    return importApiFile(text, into: into);
  }

  // Not JSON: YAML, which only OpenAPI and Swagger use.
  final Object? yaml;
  try {
    yaml = decodeJsonOrYaml(text);
  } on FormatException {
    // A spec with a YAML mistake deserves the parser's message; other text
    // just gets the list of what is supported.
    if (_declaresSpec.hasMatch(text)) rethrow;
    throw FormatException(_notRecognised(text));
  }
  if (looksLikeOpenApi(yaml)) return importOpenApiDocument(yaml, into: into);
  throw FormatException(_notRecognised(text));
}

/// A line that starts a YAML OpenAPI or Swagger document.
final _declaresSpec = RegExp(
  r'''^\s*["']?(openapi|swagger)["']?\s*:''',
  multiLine: true,
);

/// A message for text that no importer could read.
String _notRecognised(String text) {
  final head = text.trimLeft();
  if (head.startsWith('{') || head.startsWith('[')) {
    return 'The file is not valid JSON.';
  }
  return 'Not a supported file. Use an OpenAPI or Swagger spec (JSON or '
      'YAML), a HAR capture, a Postman collection or environment, or an '
      'ApiWorkbench workspace.';
}
