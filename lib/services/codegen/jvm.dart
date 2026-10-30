import 'codegen.dart';
import 'literals.dart';

const _okHttpNeedsBody = {'POST', 'PUT', 'PATCH', 'PROPPATCH', 'REPORT'};

/// The OkHttp builder call for [r]: `.get()`, `.post(body)`, `.method(...)`.
/// [body] is the name of the body variable, null for no body, and [none] the
/// expression to use when the method insists on a body.
String _okHttpMethod(
  SnippetRequest r, {
  required String? body,
  required String none,
  required String Function(String) lit,
  required String nullLiteral,
}) {
  final m = r.method;
  if (body == null) {
    if (m == 'GET') return '.get()';
    if (m == 'HEAD') return '.head()';
    if (m == 'DELETE') return '.delete()';
    return '.method(${lit(m)}, ${_okHttpNeedsBody.contains(m) ? none : nullLiteral})';
  }
  return switch (m) {
    'POST' => '.post($body)',
    'PUT' => '.put($body)',
    'PATCH' => '.patch($body)',
    'DELETE' => '.delete($body)',
    _ => '.method(${lit(m)}, $body)',
  };
}

/// Java 11+ `java.net.http`.
class JavaHttpClientGenerator extends CodeGenerator {
  const JavaHttpClientGenerator();

  @override
  String get id => 'java-http';
  @override
  String get language => 'Java';
  @override
  String get library => 'java.net.http';

  @override
  String generate(SnippetRequest r) {
    const ind = '        ';
    String lit(String s) => javaStr(s, indent: '$ind    ');
    final imports = <String>{
      'java.net.URI',
      'java.net.http.HttpClient',
      'java.net.http.HttpRequest',
      'java.net.http.HttpRequest.BodyPublishers',
      'java.net.http.HttpResponse',
      'java.net.http.HttpResponse.BodyHandlers',
    };
    final pre = <String>[];
    String? publisher;
    switch (r.body) {
      case NoBody():
        break;
      case RawBody(:final text):
        publisher = 'BodyPublishers.ofString(${lit(text)})';
      case UrlEncodedBody(:final encoded):
        publisher = 'BodyPublishers.ofString(${lit(encoded)})';
      case MultipartBody(:final fields):
        // java.net.http has no multipart builder, so assemble the parts.
        imports.addAll([
          'java.nio.charset.StandardCharsets',
          'java.util.ArrayList',
          'java.util.List',
          if (fields.any((f) => f.isFile)) ...[
            'java.nio.file.Files',
            'java.nio.file.Path',
          ],
        ]);
        pre.add('String boundary = "----ApiWorkbenchFormBoundary";');
        pre.add('List<byte[]> parts = new ArrayList<>();');
        for (final f in fields) {
          String head(String disposition, [String extra = '']) => javaStr(
            '\r\nContent-Disposition: form-data; $disposition\r\n$extra\r\n',
            split: false,
          );
          if (f.isFile) {
            final h = head(
              'name="${f.name}"; filename="${f.fileName}"',
              'Content-Type: application/octet-stream\r\n',
            );
            pre.add(
              'parts.add(("--" + boundary + $h).getBytes(StandardCharsets.UTF_8));',
            );
            pre.add('parts.add(Files.readAllBytes(Path.of(${lit(f.value)})));');
            pre.add('parts.add("\\r\\n".getBytes(StandardCharsets.UTF_8));');
          } else {
            final h = head('name="${f.name}"');
            pre.add(
              'parts.add(("--" + boundary + $h + ${lit(f.value)} + "\\r\\n").getBytes(StandardCharsets.UTF_8));',
            );
          }
        }
        pre.add(
          'parts.add(("--" + boundary + "--\\r\\n").getBytes(StandardCharsets.UTF_8));',
        );
        publisher = 'BodyPublishers.ofByteArrays(parts)';
      case FileBody(:final path):
        imports.add('java.nio.file.Path');
        publisher = 'BodyPublishers.ofFile(Path.of(${lit(path)}))';
    }

    final call = publisher == null
        ? switch (r.method) {
            'GET' => '.GET()',
            'DELETE' => '.DELETE()',
            _ => '.method(${lit(r.method)}, BodyPublishers.noBody())',
          }
        : switch (r.method) {
            'POST' => '.POST($publisher)',
            'PUT' => '.PUT($publisher)',
            _ => '.method(${lit(r.method)}, $publisher)',
          };

    if (publisher == null && (r.method == 'GET' || r.method == 'DELETE')) {
      imports.remove('java.net.http.HttpRequest.BodyPublishers');
    }
    final b = StringBuffer();
    for (final i in (imports.toList()..sort())) {
      b.writeln('import $i;');
    }
    b.writeln('\npublic class Main {');
    b.writeln('    public static void main(String[] args) throws Exception {');
    b.writeln('${ind}HttpClient client = HttpClient.newHttpClient();');
    for (final l in pre) {
      b.writeln('$ind$l');
    }
    b.writeln('${ind}HttpRequest request = HttpRequest.newBuilder()');
    b.writeln('$ind    .uri(URI.create(${lit(r.url)}))');
    for (final h in r.headers) {
      b.writeln('$ind    .header(${lit(h.key)}, ${lit(h.value)})');
    }
    if (r.body is MultipartBody) {
      b.writeln(
        '$ind    .header("Content-Type", "multipart/form-data; boundary=" + boundary)',
      );
    }
    b.writeln('$ind    $call');
    b.writeln('$ind    .build();');
    b.writeln(
      '${ind}HttpResponse<String> response = client.send(request, BodyHandlers.ofString());',
    );
    b.writeln('${ind}System.out.println(response.body());');
    b.writeln('    }');
    b.write('}');
    return b.toString();
  }
}

/// Java with OkHttp 4.
class JavaOkHttpGenerator extends CodeGenerator {
  const JavaOkHttpGenerator();

  @override
  String get id => 'java-okhttp';
  @override
  String get language => 'Java';
  @override
  String get library => 'OkHttp';

  @override
  String generate(SnippetRequest r) {
    const ind = '        ';
    String lit(String s) => javaStr(s, indent: '$ind    ');
    final imports = <String>{
      'okhttp3.OkHttpClient',
      'okhttp3.Request',
      'okhttp3.RequestBody',
      'okhttp3.Response',
    };
    final pre = <String>[];
    String? body;
    final skip = <String>[];
    String media(String? ct) =>
        ct == null ? 'null' : 'MediaType.parse(${lit(ct)})';
    switch (r.body) {
      case NoBody():
        break;
      case RawBody(:final text):
        imports.add('okhttp3.MediaType');
        pre.add('MediaType mediaType = ${media(r.contentType)};');
        pre.add(
          'RequestBody body = RequestBody.create(${lit(text)}, mediaType);',
        );
        body = 'body';
        skip.add('content-type');
      case UrlEncodedBody(:final fields):
        imports.add('okhttp3.FormBody');
        pre.add('RequestBody body = new FormBody.Builder()');
        for (final f in fields) {
          pre.add('    .add(${lit(f.name)}, ${lit(f.value)})');
        }
        pre.add('    .build();');
        body = 'body';
        skip.add('content-type');
      case MultipartBody(:final fields):
        imports.addAll(['okhttp3.MediaType', 'okhttp3.MultipartBody']);
        if (fields.any((f) => f.isFile)) imports.add('java.io.File');
        pre.add('RequestBody body = new MultipartBody.Builder()');
        pre.add('    .setType(MultipartBody.FORM)');
        for (final f in fields) {
          pre.add(
            f.isFile
                ? '    .addFormDataPart(${lit(f.name)}, ${lit(f.fileName)}, RequestBody.create(new File(${lit(f.value)}), MediaType.parse("application/octet-stream")))'
                : '    .addFormDataPart(${lit(f.name)}, ${lit(f.value)})',
          );
        }
        pre.add('    .build();');
        body = 'body';
      case FileBody(:final path):
        imports.addAll(['okhttp3.MediaType', 'java.io.File']);
        pre.add(
          'RequestBody body = RequestBody.create(new File(${lit(path)}), ${media(r.contentType)});',
        );
        body = 'body';
        skip.add('content-type');
    }
    if (body != null && (r.method == 'GET' || r.method == 'HEAD')) {
      pre.insert(0, '// OkHttp rejects a body on GET and HEAD requests.');
    }

    if (body == null && !_okHttpNeedsBody.contains(r.method)) {
      imports.remove('okhttp3.RequestBody');
    }
    final b = StringBuffer();
    for (final i in (imports.toList()..sort())) {
      b.writeln('import $i;');
    }
    b.writeln('\npublic class Main {');
    b.writeln('    public static void main(String[] args) throws Exception {');
    b.writeln('${ind}OkHttpClient client = new OkHttpClient();');
    for (final l in pre) {
      b.writeln('$ind$l');
    }
    b.writeln('${ind}Request request = new Request.Builder()');
    b.writeln('$ind    .url(${lit(r.url)})');
    b.writeln(
      '$ind    ${_okHttpMethod(r, body: body, none: 'RequestBody.create(new byte[0], null)', lit: lit, nullLiteral: 'null')}',
    );
    for (final h in r.headersWithout(names: skip)) {
      b.writeln('$ind    .addHeader(${lit(h.key)}, ${lit(h.value)})');
    }
    b.writeln('$ind    .build();');
    b.writeln(
      '${ind}try (Response response = client.newCall(request).execute()) {',
    );
    b.writeln('$ind    System.out.println(response.body().string());');
    b.writeln('$ind}');
    b.writeln('    }');
    b.write('}');
    return b.toString();
  }
}

/// Kotlin with OkHttp 4.
class KotlinOkHttpGenerator extends CodeGenerator {
  const KotlinOkHttpGenerator();

  @override
  String get id => 'kotlin-okhttp';
  @override
  String get language => 'Kotlin';
  @override
  String get library => 'OkHttp';

  @override
  String generate(SnippetRequest r) {
    final imports = <String>{'okhttp3.OkHttpClient', 'okhttp3.Request'};
    final pre = <String>[];
    String? body;
    final skip = <String>[];
    String media(String ct) => '${ktStr(ct)}.toMediaType()';
    switch (r.body) {
      case NoBody():
        break;
      case RawBody(:final text):
        final ct = r.contentType;
        if (ct != null) imports.add('okhttp3.MediaType.Companion.toMediaType');
        imports.add('okhttp3.RequestBody.Companion.toRequestBody');
        pre.add(
          'val body = ${ktStr(text)}.toRequestBody(${ct == null ? '' : media(ct)})',
        );
        body = 'body';
        skip.add('content-type');
      case UrlEncodedBody(:final fields):
        imports.add('okhttp3.FormBody');
        pre.add('val body = FormBody.Builder()');
        for (final f in fields) {
          pre.add('    .add(${ktStr(f.name)}, ${ktStr(f.value)})');
        }
        pre.add('    .build()');
        body = 'body';
        skip.add('content-type');
      case MultipartBody(:final fields):
        imports.addAll([
          'okhttp3.MultipartBody',
          if (fields.any((f) => f.isFile)) ...[
            'okhttp3.MediaType.Companion.toMediaType',
            'okhttp3.RequestBody.Companion.asRequestBody',
            'java.io.File',
          ],
        ]);
        pre.add('val body = MultipartBody.Builder()');
        pre.add('    .setType(MultipartBody.FORM)');
        for (final f in fields) {
          pre.add(
            f.isFile
                ? '    .addFormDataPart(${ktStr(f.name)}, ${ktStr(f.fileName)}, File(${ktStr(f.value)}).asRequestBody("application/octet-stream".toMediaType()))'
                : '    .addFormDataPart(${ktStr(f.name)}, ${ktStr(f.value)})',
          );
        }
        pre.add('    .build()');
        body = 'body';
      case FileBody(:final path):
        imports.addAll([
          'okhttp3.MediaType.Companion.toMediaType',
          'okhttp3.RequestBody.Companion.asRequestBody',
          'java.io.File',
        ]);
        pre.add(
          'val body = File(${ktStr(path)}).asRequestBody(${media(r.contentType ?? 'application/octet-stream')})',
        );
        body = 'body';
        skip.add('content-type');
    }
    if (body != null && (r.method == 'GET' || r.method == 'HEAD')) {
      pre.insert(0, '// OkHttp rejects a body on GET and HEAD requests.');
    }
    if (body == null && _okHttpNeedsBody.contains(r.method)) {
      imports.add('okhttp3.RequestBody.Companion.toRequestBody');
    }

    final b = StringBuffer();
    for (final i in (imports.toList()..sort())) {
      b.writeln('import $i');
    }
    b.writeln('\nfun main() {');
    b.writeln('    val client = OkHttpClient()');
    for (final l in pre) {
      b.writeln('    $l');
    }
    b.writeln('    val request = Request.Builder()');
    b.writeln('        .url(${ktStr(r.url)})');
    b.writeln(
      '        ${_okHttpMethod(r, body: body, none: 'ByteArray(0).toRequestBody()', lit: ktStr, nullLiteral: 'null')}',
    );
    for (final h in r.headersWithout(names: skip)) {
      b.writeln('        .addHeader(${ktStr(h.key)}, ${ktStr(h.value)})');
    }
    b.writeln('        .build()\n');
    b.writeln('    client.newCall(request).execute().use { response ->');
    b.writeln('        println(response.body?.string())');
    b.writeln('    }');
    b.write('}');
    return b.toString();
  }
}
