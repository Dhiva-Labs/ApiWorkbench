import 'codegen.dart';
import 'literals.dart';

/// A JavaScript object literal of [map] whose lines sit at [indent].
String _object(Map<String, String> map, String indent) {
  if (map.isEmpty) return '{}';
  final b = StringBuffer('{\n');
  map.forEach((k, v) => b.writeln('$indent  ${jsStr(k)}: ${jsStr(v)},'));
  b.write('$indent}');
  return b.toString();
}

/// `const [name] = new FormData()` filling lines for a multipart body, with
/// [file] building the value of a file part.
List<String> _formDataLines(
  String name,
  List<SnippetField> fields,
  String Function(SnippetField) file,
) => [
  'const $name = new FormData();',
  for (final f in fields)
    f.isFile
        ? '$name.append(${jsStr(f.name)}, ${file(f)}, ${jsStr(f.fileName)});'
        : '$name.append(${jsStr(f.name)}, ${jsStr(f.value)});',
];

List<String> _searchParamsLines(String name, List<SnippetField> fields) => [
  'const $name = new URLSearchParams();',
  for (final f in fields) '$name.append(${jsStr(f.name)}, ${jsStr(f.value)});',
];

/// JavaScript `fetch` (browsers and Node.js 18+).
class JsFetchGenerator extends CodeGenerator {
  const JsFetchGenerator();

  @override
  String get id => 'js-fetch';
  @override
  String get language => 'JavaScript';
  @override
  String get library => 'fetch';
  @override
  String get keywords => 'node browser js';

  @override
  String generate(SnippetRequest r) {
    final imports = <String>[];
    final pre = <String>[];
    final notes = <String>[];
    String? body;
    switch (r.body) {
      case NoBody():
        break;
      case RawBody(:final text):
        body = jsStr(text);
      case UrlEncodedBody(:final fields):
        pre.addAll(_searchParamsLines('body', fields));
        body = 'body';
      case MultipartBody(:final fields):
        if (fields.any((f) => f.isFile)) {
          imports.add('import { openAsBlob } from "node:fs";');
          notes.add('// File parts need Node.js 20+, as an ES module.');
        }
        pre.addAll(
          _formDataLines(
            'body',
            fields,
            (f) => 'await openAsBlob(${jsStr(f.value)})',
          ),
        );
        body = 'body';
      case FileBody(:final path):
        imports.add('import { readFile } from "node:fs/promises";');
        notes.add('// Reading the file needs an ES module (top-level await).');
        body = 'await readFile(${jsStr(path)})';
    }
    if (body != null && (r.method == 'GET' || r.method == 'HEAD')) {
      notes.add('// fetch rejects a body on GET and HEAD requests.');
    }

    final headers = r.headerMap(formType: r.body is UrlEncodedBody);
    final b = StringBuffer();
    for (final i in imports) {
      b.writeln(i);
    }
    if (imports.isNotEmpty) b.writeln();
    for (final n in notes) {
      b.writeln(n);
    }
    for (final l in pre) {
      b.writeln(l);
    }
    if (pre.isNotEmpty) b.writeln();
    b.writeln('const options = {');
    b.writeln('  method: ${jsStr(r.method)},');
    if (headers.isNotEmpty) b.writeln('  headers: ${_object(headers, '  ')},');
    if (body != null) b.writeln('  body: $body,');
    b.writeln('};\n');
    b.writeln('fetch(${jsStr(r.url)}, options)');
    b.writeln('  .then((response) => response.text())');
    b.writeln('  .then((result) => console.log(result))');
    b.write('  .catch((error) => console.error(error));');
    return b.toString();
  }
}

/// JavaScript `axios`.
class JsAxiosGenerator extends CodeGenerator {
  const JsAxiosGenerator();

  @override
  String get id => 'js-axios';
  @override
  String get language => 'JavaScript';
  @override
  String get library => 'axios';
  @override
  String get keywords => 'node browser js';

  @override
  String generate(SnippetRequest r) {
    final imports = <String>['import axios from "axios";'];
    final pre = <String>[];
    String? data;
    var spreadHeaders = false;
    switch (r.body) {
      case NoBody():
        break;
      case RawBody(:final text):
        data = jsStr(text);
      case UrlEncodedBody(:final fields):
        pre.addAll(_searchParamsLines('data', fields));
        data = 'data';
      case MultipartBody(:final fields):
        imports.add('import FormData from "form-data";');
        if (fields.any((f) => f.isFile)) {
          imports.add('import fs from "node:fs";');
        }
        pre.addAll([
          'const data = new FormData();',
          for (final f in fields)
            f.isFile
                ? 'data.append(${jsStr(f.name)}, fs.createReadStream(${jsStr(f.value)}));'
                : 'data.append(${jsStr(f.name)}, ${jsStr(f.value)});',
        ]);
        data = 'data';
        spreadHeaders = true; // carries the multipart boundary
      case FileBody(:final path):
        imports.add('import fs from "node:fs";');
        data = 'fs.createReadStream(${jsStr(path)})';
    }

    final headers = r.headerMap(formType: r.body is UrlEncodedBody);
    final b = StringBuffer();
    for (final i in imports) {
      b.writeln(i);
    }
    b.writeln();
    for (final l in pre) {
      b.writeln(l);
    }
    if (pre.isNotEmpty) b.writeln();
    b.writeln('const config = {');
    b.writeln('  method: ${jsStr(r.method.toLowerCase())},');
    b.writeln('  url: ${jsStr(r.url)},');
    if (headers.isNotEmpty || spreadHeaders) {
      b.write('  headers: {');
      b.writeln();
      if (spreadHeaders) b.writeln('    ...data.getHeaders(),');
      headers.forEach((k, v) => b.writeln('    ${jsStr(k)}: ${jsStr(v)},'));
      b.writeln('  },');
    }
    if (data != null) b.writeln('  data: $data,');
    b.writeln('};\n');
    b.writeln('axios');
    b.writeln('  .request(config)');
    b.writeln('  .then((response) => console.log(response.data))');
    b.write('  .catch((error) => console.error(error));');
    return b.toString();
  }
}

/// Node.js `https` (or `http`) module.
class NodeHttpsGenerator extends CodeGenerator {
  const NodeHttpsGenerator();

  @override
  String get id => 'node-https';
  @override
  String get language => 'JavaScript';
  @override
  String get library => 'Node.js https';
  @override
  String get keywords => 'node http';

  @override
  String generate(SnippetRequest r) {
    final u = r.parsedUrl;
    final mod = u.secure ? 'https' : 'http';
    final imports = <String>['import $mod from "node:$mod";'];
    final pre = <String>[];
    var spreadHeaders = false;
    String end = 'req.end();';
    switch (r.body) {
      case NoBody():
        break;
      case RawBody(:final text):
        pre.add('const body = ${jsStr(text)};');
        end = 'req.end(body);';
      case UrlEncodedBody(:final fields):
        pre.addAll(_searchParamsLines('params', fields));
        pre.add('const body = params.toString();');
        end = 'req.end(body);';
      case MultipartBody(:final fields):
        imports.add('import FormData from "form-data";');
        if (fields.any((f) => f.isFile)) {
          imports.add('import fs from "node:fs";');
        }
        pre.addAll([
          'const form = new FormData();',
          for (final f in fields)
            f.isFile
                ? 'form.append(${jsStr(f.name)}, fs.createReadStream(${jsStr(f.value)}));'
                : 'form.append(${jsStr(f.name)}, ${jsStr(f.value)});',
        ]);
        end = 'form.pipe(req);';
        spreadHeaders = true;
      case FileBody(:final path):
        imports.add('import fs from "node:fs";');
        end = 'fs.createReadStream(${jsStr(path)}).pipe(req);';
    }

    final headers = r.headerMap();
    final b = StringBuffer();
    for (final i in imports) {
      b.writeln(i);
    }
    b.writeln();
    for (final l in pre) {
      b.writeln(l);
    }
    if (pre.isNotEmpty) b.writeln();
    b.writeln('const options = {');
    b.writeln('  method: ${jsStr(r.method)},');
    b.writeln('  hostname: ${jsStr(u.host)},');
    if (u.port != null) b.writeln('  port: ${u.port},');
    b.writeln('  path: ${jsStr(u.path)},');
    if (headers.isNotEmpty || spreadHeaders) {
      b.writeln('  headers: {');
      if (spreadHeaders) b.writeln('    ...form.getHeaders(),');
      headers.forEach((k, v) => b.writeln('    ${jsStr(k)}: ${jsStr(v)},'));
      b.writeln('  },');
    }
    if (!r.verifySsl && u.secure) b.writeln('  rejectUnauthorized: false,');
    b.writeln('};\n');
    b.writeln('const req = $mod.request(options, (res) => {');
    b.writeln('  const chunks = [];');
    b.writeln('  res.on("data", (chunk) => chunks.push(chunk));');
    b.writeln(
      '  res.on("end", () => console.log(Buffer.concat(chunks).toString()));',
    );
    b.writeln('});\n');
    b.writeln('req.on("error", (error) => console.error(error));');
    b.write(end);
    return b.toString();
  }
}
