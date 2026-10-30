import '../../models/models.dart';
import 'csharp.dart';
import 'dart_http.dart';
import 'go.dart';
import 'javascript.dart';
import 'jvm.dart';
import 'php.dart';
import 'python.dart';
import 'ruby.dart';
import 'rust.dart';
import 'shell.dart';
import 'snippet_request.dart';
import 'swift.dart';

export '../request_builder.dart' show RequestBuildException;
export 'literals.dart' show shQuote;
export 'snippet_request.dart';

/// Turns a resolved request into source code for one language and library.
abstract class CodeGenerator {
  const CodeGenerator();

  /// Stable key, e.g. `python-requests`; used to remember the last choice.
  String get id;

  /// Language group, e.g. `Python`.
  String get language;

  /// The library or tool, e.g. `requests`.
  String get library;

  /// Name shown in pickers: `Python – requests`.
  String get label => '$language – $library';

  /// Short text for search matching, beyond [label].
  String get keywords => '';

  /// The code for [r], without a trailing newline.
  String generate(SnippetRequest r);
}

/// Every generator, in the order pickers list them.
const List<CodeGenerator> codeGenerators = [
  CurlGenerator(),
  HttpieGenerator(),
  WgetGenerator(),
  PowerShellGenerator(),
  PythonRequestsGenerator(),
  PythonHttpClientGenerator(),
  JsFetchGenerator(),
  JsAxiosGenerator(),
  NodeHttpsGenerator(),
  JavaHttpClientGenerator(),
  JavaOkHttpGenerator(),
  KotlinOkHttpGenerator(),
  CSharpGenerator(),
  GoGenerator(),
  PhpCurlGenerator(),
  RubyGenerator(),
  SwiftGenerator(),
  DartHttpGenerator(),
  RustGenerator(),
];

/// The generator with [id], or the first one (cURL) when unknown.
CodeGenerator codeGeneratorById(String? id) => codeGenerators.firstWhere(
  (g) => g.id == id,
  orElse: () => codeGenerators.first,
);

/// Resolves [request] (see [resolveSnippetRequest]) and generates it with
/// [generator] in one step.
Future<String> generateSnippet(
  CodeGenerator generator,
  RequestModel request,
  Map<String, String> vars, {
  CollectionModel? collection,
  AppSettings? app,
  bool unresolved = false,
}) async => generator.generate(
  await resolveSnippetRequest(
    request,
    vars,
    collection: collection,
    app: app,
    unresolved: unresolved,
  ),
);
