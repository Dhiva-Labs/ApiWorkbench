import 'postman_import.dart';

/// Imports one file of any supported format into [into]: ApiWorkbench
/// workspaces and Postman files now; OpenAPI, Swagger and HAR with issues
/// #30 and #31. Throws [FormatException] for anything else.
ImportReport importAnyFile(String raw, {ImportReport? into}) =>
    importApiFile(raw, into: into);
