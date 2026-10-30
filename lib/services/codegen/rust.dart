import 'codegen.dart';
import 'literals.dart';

/// Rust with `reqwest` (async, on tokio).
class RustGenerator extends CodeGenerator {
  const RustGenerator();

  @override
  String get id => 'rust-reqwest';
  @override
  String get language => 'Rust';
  @override
  String get library => 'reqwest';

  static const _builders = {
    'GET': 'get',
    'POST': 'post',
    'PUT': 'put',
    'PATCH': 'patch',
    'DELETE': 'delete',
    'HEAD': 'head',
  };

  @override
  String generate(SnippetRequest r) {
    final b = StringBuffer();
    final body = r.body;
    final reqwest = body is MultipartBody
        ? 'reqwest = { version = "0.12", features = ["multipart", "stream"] }'
        : 'reqwest = "0.12"';
    b.write(
      '// Cargo.toml: $reqwest, tokio = { version = "1", features = ["full"] }\n\n',
    );
    b.writeln('#[tokio::main]');
    b.writeln('async fn main() -> Result<(), Box<dyn std::error::Error>> {');
    b.writeln(
      r.verifySsl
          ? '    let client = reqwest::Client::new();\n'
          : '    let client = reqwest::Client::builder()\n        .danger_accept_invalid_certs(true)\n        .build()?;\n',
    );

    final build = <String>[];
    final headers = r.headersWithout(formType: body is UrlEncodedBody);
    for (final h in headers) {
      build.add('.header(${rustStr(h.key)}, ${rustStr(h.value)})');
    }
    switch (body) {
      case NoBody():
        break;
      case RawBody(:final text):
        build.add('.body(${rustStr(text)})');
      case UrlEncodedBody(:final fields):
        build.add(
          '.form(&[${fields.map((f) => '(${rustStr(f.name)}, ${rustStr(f.value)})').join(', ')}])',
        );
      case MultipartBody(:final fields):
        b.writeln('    let form = reqwest::multipart::Form::new();');
        for (final f in fields) {
          b.writeln(
            f.isFile
                ? '    let form = form.file(${rustStr(f.name)}, ${rustStr(f.value)}).await?;'
                : '    let form = form.text(${rustStr(f.name)}, ${rustStr(f.value)});',
          );
        }
        b.writeln();
        build.add('.multipart(form)');
      case FileBody(:final path):
        build.add('.body(tokio::fs::read(${rustStr(path)}).await?)');
    }

    final verb = _builders[r.method];
    final start = verb != null
        ? '.$verb(${rustStr(r.url)})'
        : '.request(${_method(r.method)}, ${rustStr(r.url)})';
    b.writeln('    let response = client');
    b.writeln('        $start');
    for (final c in build) {
      b.writeln('        $c');
    }
    b.writeln('        .send()');
    b.writeln('        .await?;\n');
    b.writeln('    println!("{}", response.text().await?);');
    b.writeln('    Ok(())');
    b.write('}');
    return b.toString();
  }

  static String _method(String m) => switch (m) {
    'OPTIONS' => 'reqwest::Method::OPTIONS',
    'TRACE' => 'reqwest::Method::TRACE',
    'CONNECT' => 'reqwest::Method::CONNECT',
    _ => 'reqwest::Method::from_bytes(b${rustStr(m)})?',
  };
}
