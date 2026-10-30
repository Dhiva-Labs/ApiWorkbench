import 'codegen.dart';
import 'literals.dart';
import 'shell.dart' show uniqueNames;

/// Dart with `package:http`.
class DartHttpGenerator extends CodeGenerator {
  const DartHttpGenerator();

  @override
  String get id => 'dart-http';
  @override
  String get language => 'Dart';
  @override
  String get library => 'http';
  @override
  String get keywords => 'flutter';

  @override
  String generate(SnippetRequest r) {
    final body = r.body;
    final multipart = body is MultipartBody;
    // bodyFields sets the form Content-Type itself, but only for a map.
    final fieldsMap = body is UrlEncodedBody && uniqueNames(body.fields);
    final headers = r.headerMap(formType: fieldsMap);
    final cls = multipart ? 'http.MultipartRequest' : 'http.Request';

    final imports = <String>[
      if (body is FileBody) "import 'dart:io';\n",
      "import 'package:http/http.dart' as http;",
    ];
    final b = StringBuffer(imports.join('\n'));
    b.writeln('\n');
    b.writeln('Future<void> main() async {');
    if (headers.isNotEmpty) {
      b.writeln('  final headers = {');
      headers.forEach((k, v) => b.writeln('    ${dartStr(k)}: ${dartStr(v)},'));
      b.writeln('  };\n');
    }
    b.writeln(
      '  final request = $cls(${dartStr(r.method)}, Uri.parse(${dartStr(r.url)}));',
    );
    if (headers.isNotEmpty) b.writeln('  request.headers.addAll(headers);');
    switch (body) {
      case NoBody():
        break;
      case RawBody(:final text):
        b.writeln('  request.body = ${dartStr(text)};');
      case UrlEncodedBody(:final fields, :final encoded):
        if (fieldsMap) {
          b.writeln('  request.bodyFields = {');
          for (final f in fields) {
            b.writeln('    ${dartStr(f.name)}: ${dartStr(f.value)},');
          }
          b.writeln('  };');
        } else {
          b.writeln('  request.body = ${dartStr(encoded)};');
        }
      case MultipartBody(:final fields):
        final text = fields.where((f) => !f.isFile).toList();
        if (text.isNotEmpty) {
          b.writeln('  request.fields.addAll({');
          for (final f in text) {
            b.writeln('    ${dartStr(f.name)}: ${dartStr(f.value)},');
          }
          b.writeln('  });');
        }
        for (final f in fields.where((f) => f.isFile)) {
          b.writeln(
            '  request.files.add(await http.MultipartFile.fromPath(${dartStr(f.name)}, ${dartStr(f.value)}));',
          );
        }
      case FileBody(:final path):
        b.writeln(
          '  request.bodyBytes = await File(${dartStr(path)}).readAsBytes();',
        );
    }
    b.writeln();
    b.writeln('  final response = await request.send();');
    b.writeln('  print(await response.stream.bytesToString());');
    b.write('}');
    return b.toString();
  }
}
