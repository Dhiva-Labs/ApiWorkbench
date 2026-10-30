import 'codegen.dart';
import 'literals.dart';

/// True when no field name appears twice, so a map can hold the fields.
bool uniqueNames(List<SnippetField> fields) =>
    fields.map((f) => f.name).toSet().length == fields.length;

/// cURL: `curl -X POST 'url' -H '...' --data-raw '...'`, one option per line.
class CurlGenerator extends CodeGenerator {
  const CurlGenerator();

  @override
  String get id => 'curl';
  @override
  String get language => 'Shell';
  @override
  String get library => 'cURL';
  @override
  String get keywords => 'bash sh terminal';

  @override
  String generate(SnippetRequest r) {
    final method = switch (r.method) {
      'HEAD' => '-I ',
      'GET' when !r.hasBody => '',
      _ => '-X ${r.method} ',
    };
    final opts = <String>[
      if (!r.verifySsl) '--insecure',
      for (final h in r.headersWithout(formType: r.body is UrlEncodedBody))
        '-H ${shQuote('${h.key}: ${h.value}')}',
    ];
    switch (r.body) {
      case NoBody():
        break;
      case RawBody(:final text):
        opts.add('--data-raw ${shQuote(text)}');
      case UrlEncodedBody(:final fields):
        opts.addAll(curlFormOptions(fields, multipart: false));
      case MultipartBody(:final fields):
        opts.addAll(curlFormOptions(fields, multipart: true));
      case FileBody(:final path):
        opts.add('--data-binary ${shQuote('@$path')}');
    }
    final b = StringBuffer("curl $method${shQuote(r.url)}");
    for (final o in opts) {
      b.write(' \\\n  $o');
    }
    return b.toString();
  }
}

/// cURL options for form [fields]: `--data-urlencode` for a urlencoded body,
/// `-F` (or `--form-string` for text `-F` would misread) for multipart.
List<String> curlFormOptions(
  List<SnippetField> fields, {
  required bool multipart,
}) {
  final out = <String>[];
  for (final f in fields) {
    if (!multipart) {
      // --data-urlencode sends the name as written, so special characters
      // in it are encoded here.
      final name = RegExp(r'^[A-Za-z0-9._~\-\[\]{}$]*$').hasMatch(f.name)
          ? f.name
          : Uri.encodeQueryComponent(f.name);
      out.add('--data-urlencode ${shQuote('$name=${f.value}')}');
    } else if (f.isFile) {
      final quoted =
          f.value.contains(';') ||
              f.value.contains('"') ||
              f.value.contains(',')
          ? '"${f.value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"'
          : f.value;
      out.add('-F ${shQuote('${f.name}=@$quoted')}');
    } else if (!f.value.startsWith('@') &&
        !f.value.startsWith('<') &&
        !f.value.contains(';')) {
      out.add('-F ${shQuote('${f.name}=${f.value}')}');
    } else {
      // -F would read a leading @ or < as a file, and ; as an option.
      out.add('--form-string ${shQuote('${f.name}=${f.value}')}');
    }
  }
  return out;
}

/// HTTPie: `http POST 'url' 'Header:value' --raw '...'`.
class HttpieGenerator extends CodeGenerator {
  const HttpieGenerator();

  @override
  String get id => 'httpie';
  @override
  String get language => 'Shell';
  @override
  String get library => 'HTTPie';

  @override
  String generate(SnippetRequest r) {
    final parts = <String>[
      if (!r.verifySsl) '--verify=no',
      switch (r.body) {
        UrlEncodedBody() => '--form',
        MultipartBody() => '--multipart',
        _ => '',
      },
    ].where((s) => s.isNotEmpty).toList();
    final items = <String>[
      for (final h in r.headersWithout(formType: r.body is UrlEncodedBody))
        h.value.isEmpty ? shQuote('${h.key};') : shQuote('${h.key}:${h.value}'),
    ];
    String? stdin;
    switch (r.body) {
      case NoBody():
        break;
      case RawBody(:final text):
        parts.add('--raw ${shQuote(text)}');
      case UrlEncodedBody(:final fields):
        for (final f in fields) {
          items.add(shQuote('${_key(f.name)}=${f.value}'));
        }
      case MultipartBody(:final fields):
        for (final f in fields) {
          items.add(
            shQuote(
              f.isFile
                  ? '${_key(f.name)}@${f.value}'
                  : '${_key(f.name)}=${f.value}',
            ),
          );
        }
      case FileBody(:final path):
        stdin = shQuote(path);
    }
    final b = StringBuffer('http ${r.method} ${shQuote(r.url)}');
    for (final o in [...parts, ...items]) {
      b.write(' \\\n  $o');
    }
    if (stdin != null) b.write(' \\\n  < $stdin');
    return b.toString();
  }

  /// Field names escape the characters HTTPie reads as separators.
  static String _key(String name) =>
      name.replaceAllMapped(RegExp(r'[\\=:@;]'), (m) => '\\${m.group(0)}');
}

/// wget: `wget --method POST --header '...' --body-data '...' 'url'`.
class WgetGenerator extends CodeGenerator {
  const WgetGenerator();

  @override
  String get id => 'wget';
  @override
  String get language => 'Shell';
  @override
  String get library => 'wget';

  @override
  String generate(SnippetRequest r) {
    final opts = <String>[
      '--quiet',
      if (!r.verifySsl) '--no-check-certificate',
      '--method ${r.method}',
      for (final h in r.headers) '--header ${shQuote('${h.key}: ${h.value}')}',
    ];
    final notes = <String>[];
    switch (r.body) {
      case NoBody():
        break;
      case RawBody(:final text):
        opts.add('--body-data ${shQuote(text)}');
      case UrlEncodedBody(:final encoded):
        opts.add('--body-data ${shQuote(encoded)}');
      case MultipartBody():
        notes.add(
          '# wget cannot build a multipart/form-data body. Use cURL with -F,',
        );
        notes.add(
          '# or write the encoded body to a file and send it with --body-file.',
        );
      case FileBody(:final path):
        opts.add('--body-file ${shQuote(path)}');
    }
    opts.add('--output-document -');
    final b = StringBuffer();
    for (final n in notes) {
      b.writeln(n);
    }
    b.write('wget');
    for (final o in opts) {
      b.write(' \\\n  $o');
    }
    b.write(' \\\n  ${shQuote(r.url)}');
    return b.toString();
  }
}

/// PowerShell: `Invoke-RestMethod` with a headers table and a body.
class PowerShellGenerator extends CodeGenerator {
  const PowerShellGenerator();

  @override
  String get id => 'powershell';
  @override
  String get language => 'Shell';
  @override
  String get library => 'PowerShell';
  @override
  String get keywords => 'invoke-restmethod windows';

  static const _methods = {
    'GET': 'Get',
    'POST': 'Post',
    'PUT': 'Put',
    'PATCH': 'Patch',
    'DELETE': 'Delete',
    'HEAD': 'Head',
    'OPTIONS': 'Options',
    'TRACE': 'Trace',
  };

  @override
  String generate(SnippetRequest r) {
    final b = StringBuffer();
    final body = r.body;
    // -ContentType is its own parameter, and the default form type is
    // implied by a form table.
    final headers = r.headerMap(names: const ['content-type']);
    final contentType = r.contentType;

    if (headers.isNotEmpty) {
      b.writeln('\$headers = @{');
      headers.forEach((k, v) => b.writeln('    ${psQuote(k)} = ${psQuote(v)}'));
      b.writeln('}');
      b.writeln();
    }

    String? bodyArg;
    String? contentArg = contentType == null || body is MultipartBody
        ? null
        : '-ContentType ${psQuote(contentType)}';
    switch (body) {
      case NoBody():
        break;
      case RawBody(:final text):
        b.writeln('\$body = ${psQuote(text)}');
        b.writeln();
        bodyArg = '-Body \$body';
      case UrlEncodedBody(:final fields, :final encoded):
        if (uniqueNames(fields)) {
          b.writeln('\$body = @{');
          for (final f in fields) {
            b.writeln('    ${psQuote(f.name)} = ${psQuote(f.value)}');
          }
          b.writeln('}');
          if (contentType?.toLowerCase().trim() ==
              'application/x-www-form-urlencoded') {
            contentArg = null; // implied by a table body
          }
        } else {
          b.writeln('\$body = ${psQuote(encoded)}');
        }
        b.writeln();
        bodyArg = '-Body \$body';
      case MultipartBody(:final fields):
        b.writeln('# -Form needs PowerShell 6.1 or later.');
        b.writeln('\$form = @{');
        for (final f in fields) {
          final v = f.isFile
              ? '(Get-Item -Path ${psQuote(f.value)})'
              : psQuote(f.value);
          b.writeln('    ${psQuote(f.name)} = $v');
        }
        b.writeln('}');
        if (!uniqueNames(fields)) {
          b.writeln(
            '# Repeated field names are collapsed into one by a table.',
          );
        }
        b.writeln();
        bodyArg = '-Form \$form';
      case FileBody(:final path):
        bodyArg = '-InFile ${psQuote(path)}';
    }

    final known = _methods[r.method];
    final args = <String>[
      '-Uri ${psQuote(r.url)}',
      known != null ? '-Method $known' : '-CustomMethod ${psQuote(r.method)}',
      if (headers.isNotEmpty) '-Headers \$headers',
      ?contentArg,
      ?bodyArg,
      if (!r.verifySsl) '-SkipCertificateCheck',
    ];
    b.write('\$response = Invoke-RestMethod ${args.join(' `\n    ')}');
    b.write('\n\$response | ConvertTo-Json -Depth 10');
    return b.toString();
  }
}
