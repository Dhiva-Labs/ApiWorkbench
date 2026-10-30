import 'codegen.dart';
import 'literals.dart';
import 'shell.dart' show uniqueNames;

bool _ascii(String s) => s.codeUnits.every((u) => u < 0x80);

/// A Python `{...}` dict literal of [map], one entry per line.
String _dict(Map<String, String> map) {
  if (map.isEmpty) return '{}';
  final b = StringBuffer('{\n');
  map.forEach((k, v) => b.writeln('    ${pyStr(k)}: ${pyStr(v)},'));
  b.write('}');
  return b.toString();
}

/// Python `requests`.
class PythonRequestsGenerator extends CodeGenerator {
  const PythonRequestsGenerator();

  @override
  String get id => 'python-requests';
  @override
  String get language => 'Python';
  @override
  String get library => 'requests';

  static const _verbs = {
    'GET',
    'POST',
    'PUT',
    'PATCH',
    'DELETE',
    'HEAD',
    'OPTIONS',
  };

  @override
  String generate(SnippetRequest r) {
    final b = StringBuffer('import requests\n\n');
    b.writeln('url = ${pyStr(r.url)}\n');
    final headers = r.headerMap(formType: r.body is UrlEncodedBody);
    if (headers.isNotEmpty) b.writeln('headers = ${_dict(headers)}\n');

    final args = <String>['url', if (headers.isNotEmpty) 'headers=headers'];
    var inWith = false;
    switch (r.body) {
      case NoBody():
        break;
      case RawBody(:final text):
        b.writeln('payload = ${pyStr(text)}\n');
        args.add(
          _ascii(text) ? 'data=payload' : 'data=payload.encode("utf-8")',
        );
      case UrlEncodedBody(:final fields):
        if (uniqueNames(fields)) {
          b.writeln('payload = {');
          for (final f in fields) {
            b.writeln('    ${pyStr(f.name)}: ${pyStr(f.value)},');
          }
          b.writeln('}\n');
        } else {
          b.writeln('payload = [');
          for (final f in fields) {
            b.writeln('    (${pyStr(f.name)}, ${pyStr(f.value)}),');
          }
          b.writeln(']\n');
        }
        args.add('data=payload');
      case MultipartBody(:final fields):
        // Text parts need the (None, value) form for requests to send them
        // as multipart rather than urlencoded.
        b.writeln('files = [');
        for (final f in fields) {
          b.writeln(
            f.isFile
                ? '    (${pyStr(f.name)}, (${pyStr(f.fileName)}, open(${pyStr(f.value)}, "rb"))),'
                : '    (${pyStr(f.name)}, (None, ${pyStr(f.value)})),',
          );
        }
        b.writeln(']\n');
        args.add('files=files');
      case FileBody(:final path):
        b.writeln('with open(${pyStr(path)}, "rb") as payload:');
        inWith = true;
        args.add('data=payload');
    }
    if (!r.verifySsl) args.add('verify=False');

    final call = _verbs.contains(r.method)
        ? 'requests.${r.method.toLowerCase()}(${args.join(', ')})'
        : 'requests.request(${pyStr(r.method)}, ${args.join(', ')})';
    if (inWith) {
      b.writeln('    response = $call');
      b.write('\nprint(response.text)');
    } else {
      b.writeln('response = $call\n');
      b.write('print(response.text)');
    }
    return b.toString();
  }
}

/// Python standard library `http.client`.
class PythonHttpClientGenerator extends CodeGenerator {
  const PythonHttpClientGenerator();

  @override
  String get id => 'python-http-client';
  @override
  String get language => 'Python';
  @override
  String get library => 'http.client';

  @override
  String generate(SnippetRequest r) {
    final u = r.parsedUrl;
    final imports = <String>['http.client'];
    final connArgs = <String>[pyStr(u.host), if (u.port != null) '${u.port}'];
    if (!r.verifySsl && u.secure) {
      imports.add('ssl');
      connArgs.add('context=ssl._create_unverified_context()');
    }
    final b = StringBuffer();
    final body = r.body;
    if (body is UrlEncodedBody) imports.add('urllib.parse');
    if (body is MultipartBody) imports.add('os');
    for (final i in imports) {
      b.writeln('import $i');
    }
    b.writeln();
    b.writeln(
      'conn = http.client.${u.secure ? 'HTTPSConnection' : 'HTTPConnection'}(${connArgs.join(', ')})',
    );

    final headers = r.headerMap();
    String? payload;
    switch (body) {
      case NoBody():
        break;
      case RawBody(:final text):
        b.writeln('payload = ${pyStr(text)}');
        payload = _ascii(text) ? 'payload' : 'payload.encode("utf-8")';
      case UrlEncodedBody(:final fields):
        b.writeln('payload = urllib.parse.urlencode([');
        for (final f in fields) {
          b.writeln('    (${pyStr(f.name)}, ${pyStr(f.value)}),');
        }
        b.writeln('])');
        payload = 'payload';
      case MultipartBody(:final fields):
        // The standard library has no multipart encoder, so build the body.
        b.writeln('boundary = "----ApiWorkbenchFormBoundary"');
        b.writeln('parts = [');
        for (final f in fields) {
          b.writeln(
            f.isFile
                ? '    (${pyStr(f.name)}, None, ${pyStr(f.value)}),'
                : '    (${pyStr(f.name)}, ${pyStr(f.value)}, None),',
          );
        }
        b.writeln(']');
        b.writeln('payload = b""');
        b.writeln('for name, value, path in parts:');
        b.writeln('    payload += f"--{boundary}\\r\\n".encode()');
        b.writeln('    if path:');
        b.writeln(
          '        payload += f\'Content-Disposition: form-data; name="{name}"; filename="{os.path.basename(path)}"\\r\\n\'.encode()',
        );
        b.writeln(
          '        payload += b"Content-Type: application/octet-stream\\r\\n\\r\\n"',
        );
        b.writeln('        with open(path, "rb") as f:');
        b.writeln('            payload += f.read()');
        b.writeln('    else:');
        b.writeln(
          '        payload += f\'Content-Disposition: form-data; name="{name}"\\r\\n\\r\\n\'.encode()',
        );
        b.writeln('        payload += value.encode("utf-8")');
        b.writeln('    payload += b"\\r\\n"');
        b.writeln('payload += f"--{boundary}--\\r\\n".encode()');
        payload = 'payload';
      case FileBody(:final path):
        b.writeln('with open(${pyStr(path)}, "rb") as f:');
        b.writeln('    payload = f.read()');
        payload = 'payload';
    }
    if (body is MultipartBody) {
      // The boundary variable keeps header and body in step.
      b.writeln('headers = {');
      headers.forEach((k, v) => b.writeln('    ${pyStr(k)}: ${pyStr(v)},'));
      b.writeln(
        '    "Content-Type": f"multipart/form-data; boundary={boundary}",',
      );
      b.writeln('}');
    } else {
      b.writeln('headers = ${_dict(headers)}');
    }
    b.writeln();
    b.writeln(
      'conn.request(${pyStr(r.method)}, ${pyStr(u.path)}, ${payload ?? 'None'}, headers)',
    );
    b.writeln('res = conn.getresponse()');
    b.writeln('data = res.read()\n');
    b.write('print(data.decode("utf-8"))');
    return b.toString();
  }
}
