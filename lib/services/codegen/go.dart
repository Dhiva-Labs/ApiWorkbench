import 'codegen.dart';
import 'literals.dart';

/// Go `net/http`.
class GoGenerator extends CodeGenerator {
  const GoGenerator();

  @override
  String get id => 'go-nethttp';
  @override
  String get language => 'Go';
  @override
  String get library => 'net/http';
  @override
  String get keywords => 'golang';

  /// [stmt] followed by the usual `if err != nil` bail-out.
  static String _check(String stmt) =>
      '\t$stmt\n\tif err != nil {\n\t\tfmt.Println(err)\n\t\treturn\n\t}';

  @override
  String generate(SnippetRequest r) {
    final imports = <String>{'fmt', 'io', 'net/http'};
    if (!r.verifySsl) imports.add('crypto/tls');
    final pre = <String>[];
    var payload = 'nil';
    var declareErr = false;
    String? multipartType;

    switch (r.body) {
      case NoBody():
        break;
      case RawBody(:final text):
        imports.add('strings');
        pre.add('\tpayload := strings.NewReader(${goStr(text)})');
        payload = 'payload';
      case UrlEncodedBody(:final fields):
        imports.addAll(['net/url', 'strings']);
        pre.add('\tdata := url.Values{}');
        for (final f in fields) {
          pre.add('\tdata.Add(${goStr(f.name)}, ${goStr(f.value)})');
        }
        pre.add('\tpayload := strings.NewReader(data.Encode())');
        payload = 'payload';
      case MultipartBody(:final fields):
        imports.addAll(['bytes', 'mime/multipart']);
        declareErr = true;
        pre.add('\tpayload := &bytes.Buffer{}');
        pre.add('\twriter := multipart.NewWriter(payload)');
        var n = 0;
        for (final f in fields) {
          if (f.isFile) {
            n++;
            imports.add('os');
            pre.add(_check('file$n, err := os.Open(${goStr(f.value)})'));
            pre.add('\tdefer file$n.Close()');
            pre.add(
              _check(
                'part$n, err := writer.CreateFormFile(${goStr(f.name)}, ${goStr(f.fileName)})',
              ),
            );
            pre.add(_check('_, err = io.Copy(part$n, file$n)'));
          } else {
            pre.add(
              _check(
                'err = writer.WriteField(${goStr(f.name)}, ${goStr(f.value)})',
              ),
            );
          }
        }
        pre.add(_check('err = writer.Close()'));
        payload = 'payload';
        multipartType = 'writer.FormDataContentType()';
      case FileBody(:final path):
        imports.add('os');
        pre.add(_check('file, err := os.Open(${goStr(path)})'));
        pre.add('\tdefer file.Close()');
        payload = 'file';
    }

    final b = StringBuffer('package main\n\nimport (\n');
    for (final i in (imports.toList()..sort())) {
      b.writeln('\t"$i"');
    }
    b.writeln(')\n');
    b.writeln('func main() {');
    b.writeln('\tendpoint := ${goStr(r.url)}');
    b.writeln('\tmethod := ${goStr(r.method)}\n');
    if (declareErr) b.writeln('\tvar err error');
    for (final l in pre) {
      b.writeln(l);
    }
    if (pre.isNotEmpty) b.writeln();
    b.writeln(
      r.verifySsl
          ? '\tclient := &http.Client{}'
          : '\tclient := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}}',
    );
    b.writeln(
      _check('req, err := http.NewRequest(method, endpoint, $payload)'),
    );
    for (final h in r.headers) {
      b.writeln('\treq.Header.Add(${goStr(h.key)}, ${goStr(h.value)})');
    }
    if (multipartType != null) {
      b.writeln('\treq.Header.Set("Content-Type", $multipartType)');
    }
    b.writeln();
    b.writeln(_check('res, err := client.Do(req)'));
    b.writeln('\tdefer res.Body.Close()\n');
    b.writeln(_check('body, err := io.ReadAll(res.Body)'));
    b.writeln('\tfmt.Println(string(body))');
    b.write('}');
    return b.toString();
  }
}
