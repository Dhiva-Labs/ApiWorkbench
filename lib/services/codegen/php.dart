import 'codegen.dart';
import 'literals.dart';
import 'shell.dart' show uniqueNames;

/// PHP with the cURL extension.
class PhpCurlGenerator extends CodeGenerator {
  const PhpCurlGenerator();

  @override
  String get id => 'php-curl';
  @override
  String get language => 'PHP';
  @override
  String get library => 'cURL';

  @override
  String generate(SnippetRequest r) {
    final opts = <String>[
      'CURLOPT_URL => ${phpStr(r.url)},',
      'CURLOPT_RETURNTRANSFER => true,',
      if (!r.verifySsl) ...[
        'CURLOPT_SSL_VERIFYPEER => false,',
        'CURLOPT_SSL_VERIFYHOST => 0,',
      ],
      r.method == 'HEAD'
          ? 'CURLOPT_NOBODY => true,'
          : 'CURLOPT_CUSTOMREQUEST => ${phpStr(r.method)},',
    ];
    switch (r.body) {
      case NoBody():
        break;
      case RawBody(:final text):
        opts.add('CURLOPT_POSTFIELDS => ${phpStr(text)},');
      case UrlEncodedBody(:final fields, :final encoded):
        if (uniqueNames(fields)) {
          final b = StringBuffer('CURLOPT_POSTFIELDS => http_build_query([\n');
          for (final f in fields) {
            b.writeln('        ${phpStr(f.name)} => ${phpStr(f.value)},');
          }
          b.write('    ]),');
          opts.add(b.toString());
        } else {
          opts.add('CURLOPT_POSTFIELDS => ${phpStr(encoded)},');
        }
      case MultipartBody(:final fields):
        // An array body makes cURL send multipart/form-data.
        final b = StringBuffer('CURLOPT_POSTFIELDS => [\n');
        for (final f in fields) {
          b.writeln(
            f.isFile
                ? '        ${phpStr(f.name)} => new CURLFile(${phpStr(f.value)}, \'application/octet-stream\', ${phpStr(f.fileName)}),'
                : '        ${phpStr(f.name)} => ${phpStr(f.value)},',
          );
        }
        b.write('    ],');
        opts.add(b.toString());
      case FileBody(:final path):
        opts.add('CURLOPT_POSTFIELDS => file_get_contents(${phpStr(path)}),');
    }
    // cURL sets the form type itself for a string body.
    final headers = r.headersWithout(formType: r.body is UrlEncodedBody);
    if (headers.isNotEmpty) {
      final b = StringBuffer('CURLOPT_HTTPHEADER => [\n');
      for (final h in headers) {
        b.writeln('        ${phpStr('${h.key}: ${h.value}')},');
      }
      b.write('    ],');
      opts.add(b.toString());
    }

    final b = StringBuffer('<?php\n\n\$curl = curl_init();\n\n');
    b.writeln('curl_setopt_array(\$curl, [');
    for (final o in opts) {
      b.writeln('    $o');
    }
    b.writeln(']);\n');
    b.writeln('\$response = curl_exec(\$curl);');
    b.writeln('\$error = curl_error(\$curl);\n');
    b.writeln('curl_close(\$curl);\n');
    b.writeln('if (\$error) {');
    b.writeln("    echo 'cURL Error: ' . \$error;");
    b.writeln('} else {');
    b.writeln('    echo \$response;');
    b.write('}');
    return b.toString();
  }
}
