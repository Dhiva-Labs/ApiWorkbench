import 'codegen.dart';
import 'literals.dart';

/// Swift `URLSession`.
class SwiftGenerator extends CodeGenerator {
  const SwiftGenerator();

  @override
  String get id => 'swift-urlsession';
  @override
  String get language => 'Swift';
  @override
  String get library => 'URLSession';
  @override
  String get keywords => 'ios macos';

  @override
  String generate(SnippetRequest r) {
    final b = StringBuffer('import Foundation\n');
    b.writeln('#if canImport(FoundationNetworking)');
    b.writeln('import FoundationNetworking');
    b.writeln('#endif\n');
    b.writeln(
      'var request = URLRequest(url: URL(string: ${swiftStr(r.url)})!)',
    );
    b.writeln('request.httpMethod = ${swiftStr(r.method)}');
    for (final h in r.headerMap().entries) {
      b.writeln(
        'request.setValue(${swiftStr(h.value)}, forHTTPHeaderField: ${swiftStr(h.key)})',
      );
    }
    switch (r.body) {
      case NoBody():
        break;
      case RawBody(:final text):
        b.writeln('\nlet body = ${swiftStr(text)}');
        b.writeln('request.httpBody = body.data(using: .utf8)');
      case UrlEncodedBody(:final encoded):
        // URLComponents leaves & and + raw in values, so send the encoded
        // string as is.
        b.writeln('\nlet body = ${swiftStr(encoded)}');
        b.writeln('request.httpBody = body.data(using: .utf8)');
      case MultipartBody(:final fields):
        b.writeln('\nlet boundary = "----ApiWorkbenchFormBoundary"');
        b.writeln('var body = Data()\n');
        b.writeln('func field(_ name: String, _ value: String) {');
        b.writeln(
          r'    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))',
        );
        b.writeln('}\n');
        if (fields.any((f) => f.isFile)) {
          b.writeln(
            'func file(_ name: String, _ filename: String, _ path: String) {',
          );
          b.writeln(
            '    guard let content = FileManager.default.contents(atPath: path) else {',
          );
          b.writeln(r'        fatalError("File not found: \(path)")');
          b.writeln('    }');
          b.writeln(
            r'    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))',
          );
          b.writeln('    body.append(content)');
          b.writeln(r'    body.append(Data("\r\n".utf8))');
          b.writeln('}\n');
        }
        for (final f in fields) {
          b.writeln(
            f.isFile
                ? 'file(${swiftStr(f.name)}, ${swiftStr(f.fileName)}, ${swiftStr(f.value)})'
                : 'field(${swiftStr(f.name)}, ${swiftStr(f.value)})',
          );
        }
        b.writeln(r'body.append(Data("--\(boundary)--\r\n".utf8))');
        b.writeln();
        b.writeln(
          r'request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")',
        );
        b.writeln('request.httpBody = body');
      case FileBody(:final path):
        b.writeln(
          '\nrequest.httpBody = FileManager.default.contents(atPath: ${swiftStr(path)})',
        );
    }
    b.writeln();
    b.writeln(
      'let task = URLSession.shared.dataTask(with: request) { data, response, error in',
    );
    b.writeln('    if let error = error {');
    b.writeln('        print(error)');
    b.writeln('        return');
    b.writeln('    }');
    b.writeln('    if let data = data {');
    b.writeln('        print(String(decoding: data, as: UTF8.self))');
    b.writeln('    }');
    b.writeln('}\n');
    b.write('task.resume()');
    return b.toString();
  }
}
