import 'codegen.dart';
import 'literals.dart';

/// C# `HttpClient` (top-level statements, .NET 6+).
class CSharpGenerator extends CodeGenerator {
  const CSharpGenerator();

  @override
  String get id => 'csharp-httpclient';
  @override
  String get language => 'C#';
  @override
  String get library => 'HttpClient';
  @override
  String get keywords => 'csharp dotnet .net';

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

  static bool _isContentHeader(String name) {
    final n = name.toLowerCase();
    return n.startsWith('content-') ||
        n == 'allow' ||
        n == 'expires' ||
        n == 'last-modified';
  }

  @override
  String generate(SnippetRequest r) {
    final usings = <String>{'System', 'System.Net.Http'};
    final content = <String>[];
    final known = _methods[r.method];
    final method = known != null
        ? 'HttpMethod.$known'
        : 'new HttpMethod(${csStr(r.method)})';

    switch (r.body) {
      case NoBody():
        break;
      case RawBody(:final text):
        usings.add('System.Text');
        final ct = r.contentType;
        if (ct == null) {
          content.add(
            'request.Content = new StringContent(${csStr(text)}, Encoding.UTF8);',
          );
        } else if (ct.contains(';')) {
          usings.add('System.Net.Http.Headers');
          content.add(
            'request.Content = new StringContent(${csStr(text)}, Encoding.UTF8);',
          );
          content.add(
            'request.Content.Headers.ContentType = MediaTypeHeaderValue.Parse(${csStr(ct)});',
          );
        } else {
          content.add(
            'request.Content = new StringContent(${csStr(text)}, Encoding.UTF8, ${csStr(ct)});',
          );
        }
      case UrlEncodedBody(:final fields):
        usings.add('System.Collections.Generic');
        content.add(
          'var collection = new List<KeyValuePair<string, string>>();',
        );
        for (final f in fields) {
          content.add(
            'collection.Add(new(${csStr(f.name)}, ${csStr(f.value)}));',
          );
        }
        content.add('request.Content = new FormUrlEncodedContent(collection);');
      case MultipartBody(:final fields):
        if (fields.any((f) => f.isFile)) usings.add('System.IO');
        content.add('var content = new MultipartFormDataContent();');
        for (final f in fields) {
          content.add(
            f.isFile
                ? 'content.Add(new StreamContent(File.OpenRead(${csStr(f.value)})), ${csStr(f.name)}, ${csStr(f.fileName)});'
                : 'content.Add(new StringContent(${csStr(f.value)}), ${csStr(f.name)});',
          );
        }
        content.add('request.Content = content;');
      case FileBody(:final path):
        usings.addAll(['System.IO', 'System.Net.Http.Headers']);
        content.add(
          'request.Content = new ByteArrayContent(File.ReadAllBytes(${csStr(path)}));',
        );
        content.add(
          'request.Content.Headers.ContentType = new MediaTypeHeaderValue(${csStr(r.mediaType ?? 'application/octet-stream')});',
        );
    }

    final plain = <MapEntry<String, String>>[];
    final onContent = <MapEntry<String, String>>[];
    for (final h in r.headers) {
      final isType = h.key.toLowerCase() == 'content-type';
      if (_isContentHeader(h.key) && r.hasBody) {
        // Content-Type was handled where the content was built.
        if (!isType) onContent.add(h);
      } else if (!isType) {
        plain.add(h);
      }
    }

    final b = StringBuffer();
    for (final u in (usings.toList()..sort())) {
      b.writeln('using $u;');
    }
    b.writeln();
    if (r.verifySsl) {
      b.writeln('var client = new HttpClient();');
    } else {
      b.writeln('var handler = new HttpClientHandler');
      b.writeln('{');
      b.writeln(
        '    ServerCertificateCustomValidationCallback = HttpClientHandler.DangerousAcceptAnyServerCertificateValidator,',
      );
      b.writeln('};');
      b.writeln('var client = new HttpClient(handler);');
    }
    b.writeln(
      'var request = new HttpRequestMessage($method, ${csStr(r.url)});',
    );
    for (final h in plain) {
      b.writeln(
        'request.Headers.TryAddWithoutValidation(${csStr(h.key)}, ${csStr(h.value)});',
      );
    }
    for (final l in content) {
      b.writeln(l);
    }
    for (final h in onContent) {
      b.writeln(
        'request.Content.Headers.TryAddWithoutValidation(${csStr(h.key)}, ${csStr(h.value)});',
      );
    }
    b.writeln('var response = await client.SendAsync(request);');
    b.writeln('response.EnsureSuccessStatusCode();');
    b.write('Console.WriteLine(await response.Content.ReadAsStringAsync());');
    return b.toString();
  }
}
