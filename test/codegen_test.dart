import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/codegen/codegen.dart';
import 'package:api_workbench/services/curl.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/theme.dart';
import 'package:api_workbench/ui/code_snippets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// One generator's output for [r].
Future<String> gen(
  String id,
  RequestModel r, {
  Map<String, String> vars = const {},
  CollectionModel? collection,
  bool unresolved = false,
}) => generateSnippet(
  codeGeneratorById(id),
  r,
  vars,
  collection: collection,
  unresolved: unresolved,
);

RequestModel postJson() => RequestModel(
  method: 'POST',
  url: 'https://api.example.com/v1/users',
  params: [KV(key: 'page', value: '2')],
  headers: [KV(key: 'X-Trace', value: 'abc')],
  bodyType: BodyType.json,
  body: '{"name":"Ada"}',
);

RequestModel getWithPath() => RequestModel(
  url: 'https://api.example.com/users/:id/posts',
  pathVariables: [KV(key: 'id', value: '42')],
  headers: [KV(key: 'Accept', value: 'application/json')],
);

RequestModel urlEncoded() => RequestModel(
  method: 'POST',
  url: 'https://auth.example.com/token',
  bodyType: BodyType.formUrlEncoded,
  formFields: [
    KV(key: 'grant_type', value: 'client_credentials'),
    KV(key: 'scope', value: 'a b&c'),
  ],
);

RequestModel multipart() => RequestModel(
  method: 'POST',
  url: 'http://localhost:8080/upload',
  bodyType: BodyType.formData,
  formFields: [
    KV(key: 'title', value: 'My photo'),
    KV(key: 'avatar', value: '/home/me/photo.png', isFile: true),
  ],
);

RequestModel withBody(String body) => RequestModel(
  method: 'POST',
  url: 'https://x.dev/echo',
  bodyType: BodyType.text,
  body: body,
);

/// Lines that must appear in a generator's output.
typedef Expect = Map<String, List<String>>;

void check(String scenario, String id, String out, List<String> lines) {
  for (final line in lines) {
    expect(out, contains(line), reason: '$scenario / $id is missing: $line');
  }
}

void main() {
  group('registry', () {
    test('lists every language of the issue with unique ids', () {
      final ids = codeGenerators.map((g) => g.id).toList();
      expect(ids.toSet().length, ids.length);
      expect(codeGenerators.map((g) => g.label).toSet().length, ids.length);
      expect(
        codeGenerators.map((g) => g.label),
        containsAll([
          'Shell – cURL',
          'Shell – HTTPie',
          'Shell – wget',
          'Shell – PowerShell',
          'Python – requests',
          'Python – http.client',
          'JavaScript – fetch',
          'JavaScript – axios',
          'JavaScript – Node.js https',
          'Java – java.net.http',
          'Java – OkHttp',
          'Kotlin – OkHttp',
          'C# – HttpClient',
          'Go – net/http',
          'PHP – cURL',
          'Ruby – Net::HTTP',
          'Swift – URLSession',
          'Dart – http',
          'Rust – reqwest',
        ]),
      );
    });

    test('an unknown id falls back to cURL', () {
      expect(codeGeneratorById('nope').id, 'curl');
      expect(codeGeneratorById(null).id, 'curl');
    });
  });

  group('POST with JSON, headers and a query', () {
    const lines = <String, List<String>>{
      'curl': [
        "curl -X POST 'https://api.example.com/v1/users?page=2'",
        "-H 'X-Trace: abc'",
        "-H 'Content-Type: application/json'",
        '--data-raw \'{"name":"Ada"}\'',
      ],
      'httpie': [
        "http POST 'https://api.example.com/v1/users?page=2'",
        "'X-Trace:abc'",
        '--raw \'{"name":"Ada"}\'',
      ],
      'wget': [
        '--method POST',
        "--header 'X-Trace: abc'",
        '--body-data \'{"name":"Ada"}\'',
        "'https://api.example.com/v1/users?page=2'",
      ],
      'powershell': [
        "-Uri 'https://api.example.com/v1/users?page=2'",
        '-Method Post',
        "'X-Trace' = 'abc'",
        "-ContentType 'application/json'",
        '\$body = \'{"name":"Ada"}\'',
      ],
      'python-requests': [
        'url = "https://api.example.com/v1/users?page=2"',
        '"X-Trace": "abc",',
        r'payload = "{\"name\":\"Ada\"}"',
        'requests.post(url, headers=headers, data=payload)',
      ],
      'python-http-client': [
        'http.client.HTTPSConnection("api.example.com")',
        'conn.request("POST", "/v1/users?page=2", payload, headers)',
      ],
      'js-fetch': [
        'method: "POST",',
        '"X-Trace": "abc",',
        r'body: "{\"name\":\"Ada\"}",',
        'fetch("https://api.example.com/v1/users?page=2", options)',
      ],
      'js-axios': [
        'method: "post",',
        'url: "https://api.example.com/v1/users?page=2",',
        r'data: "{\"name\":\"Ada\"}",',
      ],
      'node-https': [
        'hostname: "api.example.com",',
        'path: "/v1/users?page=2",',
        'req.end(body);',
      ],
      'java-http': [
        'URI.create("https://api.example.com/v1/users?page=2")',
        '.header("X-Trace", "abc")',
        r'.POST(BodyPublishers.ofString("{\"name\":\"Ada\"}"))',
      ],
      'java-okhttp': [
        '.url("https://api.example.com/v1/users?page=2")',
        'MediaType.parse("application/json")',
        r'RequestBody.create("{\"name\":\"Ada\"}", mediaType)',
        '.post(body)',
        '.addHeader("X-Trace", "abc")',
      ],
      'kotlin-okhttp': [
        '.url("https://api.example.com/v1/users?page=2")',
        r'"{\"name\":\"Ada\"}".toRequestBody("application/json".toMediaType())',
        '.post(body)',
        '.addHeader("X-Trace", "abc")',
      ],
      'csharp-httpclient': [
        'new HttpRequestMessage(HttpMethod.Post, "https://api.example.com/v1/users?page=2")',
        'request.Headers.TryAddWithoutValidation("X-Trace", "abc");',
        r'new StringContent("{\"name\":\"Ada\"}", Encoding.UTF8, "application/json")',
      ],
      'go-nethttp': [
        'endpoint := "https://api.example.com/v1/users?page=2"',
        'method := "POST"',
        r'strings.NewReader("{\"name\":\"Ada\"}")',
        'req.Header.Add("X-Trace", "abc")',
      ],
      'php-curl': [
        "CURLOPT_URL => 'https://api.example.com/v1/users?page=2',",
        "CURLOPT_CUSTOMREQUEST => 'POST',",
        'CURLOPT_POSTFIELDS => \'{"name":"Ada"}\',',
        "'X-Trace: abc',",
      ],
      'ruby-nethttp': [
        'Net::HTTP::Post.new(url)',
        "request['X-Trace'] = 'abc'",
        'request.body = \'{"name":"Ada"}\'',
      ],
      'swift-urlsession': [
        'request.httpMethod = "POST"',
        'request.setValue("abc", forHTTPHeaderField: "X-Trace")',
        r'let body = "{\"name\":\"Ada\"}"',
        'request.httpBody = body.data(using: .utf8)',
      ],
      'dart-http': [
        "http.Request('POST', Uri.parse('https://api.example.com/v1/users?page=2'))",
        "'X-Trace': 'abc',",
        'request.body = \'{"name":"Ada"}\';',
      ],
      'rust-reqwest': [
        '.post("https://api.example.com/v1/users?page=2")',
        '.header("X-Trace", "abc")',
        '.body(r#"{"name":"Ada"}"#)',
      ],
    };

    for (final g in codeGenerators) {
      test(g.label, () async {
        final out = await gen(g.id, postJson());
        check('post json', g.id, out, lines[g.id] ?? const ['<no lines>']);
        expect(out.contains('zzawvar'), isFalse);
      });
    }

    test('every generator has expectations', () {
      expect(lines.keys.toSet(), codeGenerators.map((g) => g.id).toSet());
    });
  });

  group('GET with a path variable', () {
    const lines = <String, List<String>>{
      'curl': ["curl 'https://api.example.com/users/42/posts'"],
      'httpie': ["http GET 'https://api.example.com/users/42/posts'"],
      'wget': ['--method GET'],
      'powershell': ['-Method Get', "'Accept' = 'application/json'"],
      'python-requests': ['requests.get(url, headers=headers)'],
      'python-http-client': [
        'conn.request("GET", "/users/42/posts", None, headers)',
      ],
      'js-fetch': ['method: "GET",'],
      'js-axios': ['method: "get",'],
      'node-https': ['method: "GET",', 'req.end();'],
      'java-http': ['.GET()'],
      'java-okhttp': ['.get()'],
      'kotlin-okhttp': ['.get()'],
      'csharp-httpclient': ['HttpMethod.Get'],
      'go-nethttp': [
        'method := "GET"',
        'http.NewRequest(method, endpoint, nil)',
      ],
      'php-curl': ["CURLOPT_CUSTOMREQUEST => 'GET',"],
      'ruby-nethttp': ['Net::HTTP::Get.new(url)'],
      'swift-urlsession': ['request.httpMethod = "GET"'],
      'dart-http': ["http.Request('GET',"],
      'rust-reqwest': ['.get("https://api.example.com/users/42/posts")'],
    };

    for (final g in codeGenerators) {
      test(g.label, () async {
        final out = await gen(g.id, getWithPath());
        expect(out, contains('/users/42/posts'));
        expect(out, isNot(contains(':id')));
        check('get path', g.id, out, lines[g.id] ?? const ['<no lines>']);
      });
    }

    test(
      'a {{variable}} value is resolved, an empty value keeps :id',
      () async {
        final r = getWithPath()..pathVariables.first.value = '{{uid}}';
        expect(
          await gen('curl', r, vars: {'uid': 'u-9'}),
          contains('/users/u-9/posts'),
        );
        r.pathVariables.first.value = '';
        expect(await gen('curl', r), contains('/users/:id/posts'));
      },
    );
  });

  group('urlencoded body', () {
    const lines = <String, List<String>>{
      'curl': [
        "--data-urlencode 'grant_type=client_credentials'",
        "--data-urlencode 'scope=a b&c'",
      ],
      'httpie': ['--form', "'grant_type=client_credentials'", "'scope=a b&c'"],
      'wget': [
        "--body-data 'grant_type=client_credentials&scope=a+b%26c'",
        "--header 'Content-Type: application/x-www-form-urlencoded'",
      ],
      'powershell': [
        '\$body = @{',
        "'grant_type' = 'client_credentials'",
        '-Body \$body',
      ],
      'python-requests': [
        'payload = {',
        '"grant_type": "client_credentials",',
        'data=payload',
      ],
      'python-http-client': [
        'urllib.parse.urlencode([',
        '("grant_type", "client_credentials"),',
        '"Content-Type": "application/x-www-form-urlencoded"',
      ],
      'js-fetch': [
        'const body = new URLSearchParams();',
        'body.append("grant_type", "client_credentials");',
        'body: body,',
      ],
      'js-axios': ['data.append("scope", "a b&c");', 'data: data,'],
      'node-https': ['params.append("scope", "a b&c");', 'params.toString()'],
      'java-http': [
        'BodyPublishers.ofString("grant_type=client_credentials&scope=a+b%26c")',
        '.header("Content-Type", "application/x-www-form-urlencoded")',
      ],
      'java-okhttp': [
        'new FormBody.Builder()',
        '.add("grant_type", "client_credentials")',
      ],
      'kotlin-okhttp': [
        'FormBody.Builder()',
        '.add("grant_type", "client_credentials")',
      ],
      'csharp-httpclient': [
        'new FormUrlEncodedContent(collection)',
        'collection.Add(new("grant_type", "client_credentials"));',
      ],
      'go-nethttp': [
        'data := url.Values{}',
        'data.Add("grant_type", "client_credentials")',
        'data.Encode()',
        'req.Header.Add("Content-Type", "application/x-www-form-urlencoded")',
      ],
      'php-curl': [
        'http_build_query([',
        "'grant_type' => 'client_credentials',",
      ],
      'ruby-nethttp': [
        'request.set_form_data(',
        "'grant_type' => 'client_credentials',",
      ],
      'swift-urlsession': [
        'let body = "grant_type=client_credentials&scope=a+b%26c"',
        'forHTTPHeaderField: "Content-Type"',
      ],
      'dart-http': [
        'request.bodyFields = {',
        "'grant_type': 'client_credentials',",
      ],
      'rust-reqwest': [
        '.form(&[("grant_type", "client_credentials"), ("scope", "a b&c")])',
      ],
    };

    for (final g in codeGenerators) {
      test(g.label, () async {
        final out = await gen(g.id, urlEncoded());
        check('urlencoded', g.id, out, lines[g.id] ?? const ['<no lines>']);
      });
    }

    test(
      'libraries that set the form type themselves do not repeat it',
      () async {
        for (final id in [
          'curl',
          'httpie',
          'powershell',
          'python-requests',
          'js-fetch',
          'js-axios',
          'java-okhttp',
          'kotlin-okhttp',
          'php-curl',
          'ruby-nethttp',
          'dart-http',
          'rust-reqwest',
        ]) {
          final out = await gen(id, urlEncoded());
          expect(
            out.toLowerCase(),
            isNot(contains('application/x-www-form-urlencoded')),
            reason: id,
          );
        }
      },
    );

    test('repeated field names survive where a map would lose them', () async {
      final r = urlEncoded()..formFields.add(KV(key: 'scope', value: 'b'));
      expect(await gen('python-requests', r), contains('("scope", "b"),'));
      expect(await gen('go-nethttp', r), contains('data.Add("scope", "b")'));
      expect(await gen('wget', r), contains('scope=a+b%26c&scope=b'));
    });
  });

  group('multipart body with a file', () {
    const lines = <String, List<String>>{
      'curl': ["-F 'title=My photo'", "-F 'avatar=@/home/me/photo.png'"],
      'httpie': [
        '--multipart',
        "'title=My photo'",
        "'avatar@/home/me/photo.png'",
      ],
      'wget': ['# wget cannot build a multipart/form-data body'],
      'powershell': ['-Form \$form', "(Get-Item -Path '/home/me/photo.png')"],
      'python-requests': [
        '("title", (None, "My photo")),',
        '("avatar", ("photo.png", open("/home/me/photo.png", "rb"))),',
        'files=files',
      ],
      'python-http-client': [
        '("avatar", None, "/home/me/photo.png"),',
        'multipart/form-data; boundary={boundary}',
      ],
      'js-fetch': [
        'const body = new FormData();',
        'body.append("title", "My photo");',
        'body.append("avatar", await openAsBlob("/home/me/photo.png"), "photo.png");',
      ],
      'js-axios': [
        'fs.createReadStream("/home/me/photo.png")',
        '...data.getHeaders(),',
      ],
      'node-https': ['form.pipe(req);', '...form.getHeaders(),'],
      'java-http': [
        'Files.readAllBytes(Path.of("/home/me/photo.png"))',
        r'filename=\"photo.png\"',
        'BodyPublishers.ofByteArrays(parts)',
      ],
      'java-okhttp': [
        '.addFormDataPart("title", "My photo")',
        '.addFormDataPart("avatar", "photo.png", RequestBody.create(new File("/home/me/photo.png")',
      ],
      'kotlin-okhttp': [
        '.addFormDataPart("avatar", "photo.png", File("/home/me/photo.png").asRequestBody(',
      ],
      'csharp-httpclient': [
        'new MultipartFormDataContent()',
        'content.Add(new StreamContent(File.OpenRead("/home/me/photo.png")), "avatar", "photo.png");',
      ],
      'go-nethttp': [
        'multipart.NewWriter(payload)',
        'os.Open("/home/me/photo.png")',
        'writer.CreateFormFile("avatar", "photo.png")',
        'writer.FormDataContentType()',
      ],
      'php-curl': [
        "new CURLFile('/home/me/photo.png'",
        "'title' => 'My photo',",
      ],
      'ruby-nethttp': [
        "File.open('/home/me/photo.png')",
        '"multipart/form-data"',
      ],
      'swift-urlsession': [
        'file("avatar", "photo.png", "/home/me/photo.png")',
        'field("title", "My photo")',
      ],
      'dart-http': [
        "http.MultipartRequest('POST'",
        "http.MultipartFile.fromPath('avatar', '/home/me/photo.png')",
      ],
      'rust-reqwest': [
        '.file("avatar", "/home/me/photo.png").await?',
        '.multipart(form)',
      ],
    };

    for (final g in codeGenerators) {
      test(g.label, () async {
        // The file does not exist on this machine: a snippet must not need it.
        final out = await gen(g.id, multipart());
        check('multipart', g.id, out, lines[g.id] ?? const ['<no lines>']);
      });
    }

    test(
      'the generated boundary of the preview never leaks into a snippet',
      () async {
        for (final g in codeGenerators) {
          final out = await gen(g.id, multipart());
          expect(out, isNot(contains('dio-boundary')), reason: g.id);
        }
      },
    );

    test('a disabled field and an empty file row are left out', () async {
      final r = multipart()
        ..formFields.add(KV(key: 'skip', value: 'x', enabled: false))
        ..formFields.add(KV(key: 'none', value: '', isFile: true));
      final out = await gen('curl', r);
      expect(out, isNot(contains('skip')));
      expect(out, isNot(contains('none=')));
    });
  });

  group('other body types', () {
    test('GraphQL is sent as its JSON envelope', () async {
      final r = RequestModel(
        method: 'POST',
        url: 'https://x.dev/graphql',
        bodyType: BodyType.graphql,
        body: 'query { users { id } }',
        graphqlVariables: '{"limit": 5}',
      );
      final out = await gen('curl', r);
      expect(out, contains('-H \'Content-Type: application/json\''));
      expect(
        out,
        contains(
          '--data-raw \'{"query":"query { users { id } }","variables":{"limit":5}}\'',
        ),
      );
      expect(
        await gen('python-requests', r),
        contains(r'\"variables\":{\"limit\":5}'),
      );
    });

    test('XML keeps its content type', () async {
      final r = RequestModel(
        method: 'PUT',
        url: 'https://x.dev/doc',
        bodyType: BodyType.xml,
        body: '<a b="1"/>',
      );
      expect(
        await gen('csharp-httpclient', r),
        contains(
          r'new StringContent("<a b=\"1\"/>", Encoding.UTF8, "application/xml")',
        ),
      );
      expect(await gen('curl', r), contains('Content-Type: application/xml'));
    });

    test('no body means no body arguments', () async {
      final r = RequestModel(url: 'https://x.dev/');
      expect(await gen('curl', r), "curl 'https://x.dev/'");
      expect(await gen('python-requests', r), isNot(contains('data=')));
      expect(
        await gen('go-nethttp', r),
        contains('http.NewRequest(method, endpoint, nil)'),
      );
    });
  });

  group('binary body', () {
    test('is read from the file where the language allows it', () async {
      final r = RequestModel(
        method: 'PUT',
        url: 'https://x.dev/blob',
        bodyType: BodyType.binary,
        body: '/tmp/data.bin',
      );
      check('binary', 'curl', await gen('curl', r), [
        "--data-binary '@/tmp/data.bin'",
        "-H 'Content-Type: application/octet-stream'",
      ]);
      check('binary', 'httpie', await gen('httpie', r), ["< '/tmp/data.bin'"]);
      check('binary', 'wget', await gen('wget', r), [
        "--body-file '/tmp/data.bin'",
      ]);
      check('binary', 'ps', await gen('powershell', r), [
        "-InFile '/tmp/data.bin'",
      ]);
      check('binary', 'py', await gen('python-requests', r), [
        'with open("/tmp/data.bin", "rb") as payload:',
      ]);
      check('binary', 'java', await gen('java-http', r), [
        'BodyPublishers.ofFile(Path.of("/tmp/data.bin"))',
      ]);
      check('binary', 'go', await gen('go-nethttp', r), [
        'os.Open("/tmp/data.bin")',
        'http.NewRequest(method, endpoint, file)',
      ]);
      check('binary', 'rust', await gen('rust-reqwest', r), [
        'tokio::fs::read("/tmp/data.bin").await?',
      ]);
      check('binary', 'csharp', await gen('csharp-httpclient', r), [
        'File.ReadAllBytes("/tmp/data.bin")',
      ]);
      check('binary', 'ruby', await gen('ruby-nethttp', r), [
        "File.binread('/tmp/data.bin')",
      ]);
      check('binary', 'php', await gen('php-curl', r), [
        "file_get_contents('/tmp/data.bin')",
      ]);
    });

    test('a file that exists is not read into the snippet', () async {
      final dir = await Directory.systemTemp.createTemp('codegen_bin');
      addTearDown(() => dir.delete(recursive: true));
      final f = File('${dir.path}/blob.bin')..writeAsBytesSync([1, 2, 3]);
      final r = RequestModel(
        method: 'POST',
        url: 'https://x.dev/blob',
        bodyType: BodyType.binary,
        body: f.path,
      );
      expect(await gen('curl', r), contains("'@${f.path}'"));
    });
  });

  group('escaping', () {
    test('quotes, apostrophes and backslashes', () async {
      final r = withBody(r'''it's "q" \ b''');
      final expected = <String, String>{
        'curl': r"""--data-raw 'it'\''s "q" \ b'""",
        'httpie': r"""--raw 'it'\''s "q" \ b'""",
        'wget': r"""--body-data 'it'\''s "q" \ b'""",
        'powershell': r"""$body = 'it''s "q" \ b'""",
        'python-requests': r'''payload = "it's \"q\" \\ b"''',
        'js-fetch': r'''body: "it's \"q\" \\ b",''',
        'java-http': r'''ofString("it's \"q\" \\ b")''',
        'kotlin-okhttp': r'''"it's \"q\" \\ b".toRequestBody''',
        'csharp-httpclient': r'''new StringContent("it's \"q\" \\ b"''',
        'go-nethttp': r'''strings.NewReader("it's \"q\" \\ b")''',
        'php-curl': r"""CURLOPT_POSTFIELDS => 'it\'s "q" \\ b',""",
        'ruby-nethttp': r"""request.body = 'it\'s "q" \\ b'""",
        'swift-urlsession': r'''let body = "it's \"q\" \\ b"''',
        'dart-http': r"""request.body = 'it\'s "q" \\ b';""",
        'rust-reqwest': r'''.body(r#"it's "q" \ b"#)''',
      };
      for (final e in expected.entries) {
        expect(await gen(e.key, r), contains(e.value), reason: e.key);
      }
    });

    test(
      'newlines use a multi-line literal where the language has one',
      () async {
        final r = withBody('line1\nline2');
        const expected = <String, String>{
          'python-requests': 'payload = """line1\nline2"""',
          'js-fetch': 'body: `line1\nline2`,',
          'js-axios': 'data: `line1\nline2`,',
          'java-http': '"line1\\n" +',
          'csharp-httpclient': 'new StringContent(@"line1\nline2"',
          'go-nethttp': 'strings.NewReader(`line1\nline2`)',
          'php-curl': "CURLOPT_POSTFIELDS => 'line1\nline2',",
          'ruby-nethttp': "request.body = 'line1\nline2'",
          'swift-urlsession': 'let body = """\nline1\nline2\n"""',
          'dart-http': "request.body = '''line1\nline2''';",
          'rust-reqwest': '.body(r"line1\nline2")',
          'kotlin-okhttp': '"""line1\nline2""".toRequestBody',
          'powershell': "\$body = 'line1\nline2'",
          'curl': "--data-raw 'line1\nline2'",
        };
        for (final e in expected.entries) {
          expect(await gen(e.key, r), contains(e.value), reason: e.key);
        }
      },
    );

    test('a carriage return is escaped, never left raw in a literal', () async {
      final r = withBody('a\r\nb');
      for (final g in codeGenerators) {
        if (const ['curl', 'httpie', 'wget', 'powershell'].contains(g.id)) {
          continue; // shell quoting keeps every byte as typed
        }
        final out = await gen(g.id, r);
        expect(out, isNot(contains('\r')), reason: g.id);
      }
    });

    test('unicode and interpolation sigils', () async {
      const body = 'é ✓ 😀 \$5 #{x} \${y}';
      final r = withBody(body);
      const expected = <String, String>{
        'curl': "--data-raw 'é ✓ 😀 \$5 #{x} \${y}'",
        'python-requests': 'payload = "é ✓ 😀 \$5 #{x} \${y}"',
        'js-fetch': 'body: "é ✓ 😀 \$5 #{x} \${y}",',
        // Java source stays ASCII, so it must compile under any encoding.
        'java-http': r'"\u00e9 \u2713 \ud83d\ude00 $5 #{x} ${y}"',
        'kotlin-okhttp': r'"é ✓ 😀 \$5 #{x} \${y}"',
        'dart-http': r"'é ✓ 😀 \$5 #{x} \${y}'",
        'ruby-nethttp': "'é ✓ 😀 \$5 #{x} \${y}'",
        'php-curl': "'é ✓ 😀 \$5 #{x} \${y}'",
        'go-nethttp': '"é ✓ 😀 \$5 #{x} \${y}"',
        'swift-urlsession': '"é ✓ 😀 \$5 #{x} \${y}"',
        'rust-reqwest': '"é ✓ 😀 \$5 #{x} \${y}"',
        'csharp-httpclient': '"é ✓ 😀 \$5 #{x} \${y}"',
      };
      for (final e in expected.entries) {
        expect(await gen(e.key, r), contains(e.value), reason: e.key);
      }
      // requests encodes a text body as Latin-1 unless told otherwise.
      expect(
        await gen('python-requests', r),
        contains('data=payload.encode("utf-8")'),
      );
      expect(
        await gen('python-http-client', r),
        contains('payload.encode("utf-8")'),
      );
    });

    test('a JS template literal escapes backticks and \${', () async {
      final out = await gen('js-fetch', withBody('a`b\n\${c}'));
      expect(
        out,
        contains(
          r'body: `a\`b'
          '\n'
          r'\${c}`,',
        ),
      );
    });

    test('Dart and Kotlin escape the dollar sign in headers too', () async {
      final r = RequestModel(
        url: 'https://x.dev/',
        headers: [KV(key: 'X-Price', value: r'$5')],
      );
      expect(await gen('dart-http', r), contains(r"'X-Price': '\$5'"));
      expect(
        await gen('kotlin-okhttp', r),
        contains(r'.addHeader("X-Price", "\$5")'),
      );
    });

    test('control characters are spelled out', () async {
      final r = withBody('a\u0001b');
      const expected = <String, String>{
        'python-requests': r'"a\x01b"',
        'js-fetch': r'"a\x01b"',
        'java-http': r'"a\u0001b"',
        'csharp-httpclient': r'"a\u0001b"',
        'go-nethttp': r'"a\x01b"',
        'php-curl': r'"a\x01b"',
        'ruby-nethttp': r'"a\x01b"',
        'swift-urlsession': r'"a\u{1}b"',
        'dart-http': r"'a\x01b'",
        'rust-reqwest': r'"a\u{1}b"',
        'kotlin-okhttp': r'"a\u0001b"',
      };
      for (final e in expected.entries) {
        expect(await gen(e.key, r), contains(e.value), reason: e.key);
      }
    });

    test('header values with quotes are quoted per language', () async {
      final r = RequestModel(
        url: 'https://x.dev/',
        headers: [KV(key: 'X-Note', value: 'it\'s "ok"')],
      );
      expect(
        await gen('curl', r),
        contains(
          r"-H 'X-Note: it'\''s "
          '"ok"'
          "'",
        ),
      );
      expect(
        await gen('python-requests', r),
        contains(
          r'"X-Note": "it'
          "'"
          r's \"ok\"",',
        ),
      );
      expect(await gen('powershell', r), contains("'X-Note' = 'it''s \"ok\"'"));
      expect(
        await gen('go-nethttp', r),
        contains(
          r'req.Header.Add("X-Note", "it'
          "'"
          r's \"ok\"")',
        ),
      );
    });

    test(
      'PowerShell turns control characters into a double-quoted string',
      () async {
        final out = await gen('powershell', withBody('a\r\nb\t\$c`d\x01'));
        expect(out, contains('\$body = "a`r\nb`t`\$c``d\$([char]1)"'));
      },
    );

    test('PowerShell also doubles typographic quotes', () async {
      final r = RequestModel(
        url: 'https://x.dev/',
        headers: [KV(key: 'X-Note', value: 'it’s')],
      );
      expect(await gen('powershell', r), contains("'it’’s'"));
    });
  });

  group('auth', () {
    test(
      'a bearer token appears as an Authorization header everywhere',
      () async {
        final r = postJson()
          ..authType = AuthType.bearer
          ..bearerToken = 'tok123';
        for (final g in codeGenerators) {
          final out = await gen(g.id, r);
          expect(out, contains('Authorization'), reason: g.id);
          expect(out, contains('Bearer tok123'), reason: g.id);
        }
      },
    );

    test('basic auth is encoded', () async {
      final r = postJson()
        ..authType = AuthType.basic
        ..basicUser = 'ada'
        ..basicPassword = 'secret';
      for (final g in codeGenerators) {
        final out = await gen(g.id, r);
        expect(out, contains('Basic YWRhOnNlY3JldA=='), reason: g.id);
      }
    });

    test(
      'an API key in the query lands in the URL, in a header in headers',
      () async {
        final q = postJson()
          ..authType = AuthType.apiKey
          ..apiKeyName = 'key'
          ..apiKeyValue = 'k 1'
          ..apiKeyInHeader = false;
        expect(await gen('curl', q), contains('page=2&key=k+1'));
        final h = postJson()
          ..authType = AuthType.apiKey
          ..apiKeyName = 'X-Api-Key'
          ..apiKeyValue = 'k1'
          ..apiKeyInHeader = true;
        expect(await gen('curl', h), contains("-H 'X-Api-Key: k1'"));
      },
    );

    test('inherited auth comes from the collection', () async {
      final c = CollectionModel(name: 'C')
        ..auth = (AuthConfig(
          type: AuthType.bearer,
          bearerToken: 'from-collection',
        ));
      final r = postJson()..authType = AuthType.inherit;
      expect(
        await gen('curl', r, collection: c),
        contains('Authorization: Bearer from-collection'),
      );
      expect(await gen('curl', r), isNot(contains('Authorization')));
    });

    test('auth values may use variables', () async {
      final r = postJson()
        ..authType = AuthType.bearer
        ..bearerToken = '{{token}}';
      expect(
        await gen('curl', r, vars: {'token': 'abc'}),
        contains('Authorization: Bearer abc'),
      );
    });
  });

  group('variables', () {
    RequestModel templated() => RequestModel(
      method: 'POST',
      url: '{{baseUrl}}/users/:id?x={{x}}',
      pathVariables: [KV(key: 'id', value: '{{uid}}')],
      params: [KV(key: 'q', value: '{{q}} z')],
      headers: [KV(key: 'X-Env', value: '{{env}}')],
      bodyType: BodyType.json,
      body: '{"id": "{{uid}}"}',
      authType: AuthType.basic,
      basicUser: '{{user}}',
      basicPassword: '{{pass}}',
    );

    const vars = {
      'baseUrl': 'https://h.dev',
      'uid': '5',
      'x': 'X',
      'q': 'Q',
      'env': 'prod',
      'user': 'u',
      'pass': 'p',
    };

    test('are substituted by default', () async {
      final out = await gen('curl', templated(), vars: vars);
      expect(out, contains("'https://h.dev/users/5?x=X&q=Q%20z'"));
      expect(out, contains("-H 'X-Env: prod'"));
      expect(out, contains('{"id": "5"}'));
      expect(out, isNot(contains('{{')));
    });

    test('stay as written when shown unresolved, in every generator', () async {
      for (final g in codeGenerators) {
        final out = await gen(g.id, templated(), vars: vars, unresolved: true);
        // Two generators split the URL into host and path.
        final split = const ['python-http-client', 'node-https'].contains(g.id);
        const path = '/users/{{uid}}?x={{x}}&q={{q}}';
        expect(out, contains(split ? path : '{{baseUrl}}$path'), reason: g.id);
        expect(out, contains('{{baseUrl}}'), reason: g.id);
        expect(out, contains('{{env}}'), reason: g.id);
        expect(out, contains('{{uid}}'), reason: g.id);
        expect(out, isNot(contains('zzawvar')), reason: g.id);
        expect(out, isNot(contains('%7B')), reason: g.id);
      }
    });

    test(
      'a placeholder host is not given a scheme or percent-encoded',
      () async {
        final out = await gen('curl', templated(), unresolved: true);
        expect(
          out,
          contains("'{{baseUrl}}/users/{{uid}}?x={{x}}&q={{q}}%20z'"),
        );
        final node = await gen('node-https', templated(), unresolved: true);
        expect(node, contains('hostname: "{{baseUrl}}",'));
      },
    );

    test('basic auth shows what it is built from', () async {
      final out = await gen('curl', templated(), unresolved: true);
      expect(out, contains('Authorization: Basic base64({{user}}:{{pass}})'));
    });

    test('built-in dynamic variables stay too', () async {
      final r = RequestModel(
        url: 'https://x.dev/',
        headers: [KV(key: 'X-Id', value: r'{{$guid}}')],
      );
      expect(await gen('curl', r, unresolved: true), contains(r'{{$guid}}'));
      expect(
        await gen('dart-http', r, unresolved: true),
        contains(r"'X-Id': '{{\$guid}}'"),
      );
      expect(await gen('curl', r), isNot(contains(r'{{$guid}}')));
    });

    test('an undefined variable stays visible when resolving', () async {
      final r = RequestModel(
        url: 'https://x.dev/',
        headers: [KV(key: 'X-A', value: '{{missing}}')],
      );
      expect(await gen('curl', r), contains('X-A: {{missing}}'));
    });

    test('an empty URL reports why instead of producing code', () async {
      expect(
        gen('curl', RequestModel()),
        throwsA(isA<RequestBuildException>()),
      );
    });
  });

  group('methods and settings', () {
    test('HEAD and custom methods', () async {
      final head = RequestModel(method: 'HEAD', url: 'https://x.dev/');
      expect(await gen('curl', head), startsWith("curl -I 'https://x.dev/'"));
      expect(await gen('php-curl', head), contains('CURLOPT_NOBODY => true,'));

      final custom = RequestModel(method: 'PURGE', url: 'https://x.dev/');
      expect(await gen('curl', custom), contains('-X PURGE'));
      expect(
        await gen('python-requests', custom),
        contains('requests.request("PURGE", url)'),
      );
      expect(
        await gen('csharp-httpclient', custom),
        contains('new HttpMethod("PURGE")'),
      );
      expect(
        await gen('rust-reqwest', custom),
        contains('Method::from_bytes(b"PURGE")?'),
      );
      expect(
        await gen('ruby-nethttp', custom),
        contains("Net::HTTPGenericRequest.new('PURGE'"),
      );
    });

    test(
      'a body on GET keeps -X GET so cURL does not switch to POST',
      () async {
        final r = RequestModel(
          url: 'https://x.dev/search',
          bodyType: BodyType.json,
          body: '{"q":1}',
        );
        expect(await gen('curl', r), contains('curl -X GET '));
      },
    );

    test('disabling certificate checks is carried over', () async {
      final r = postJson()..settings.verifySsl = false;
      expect(await gen('curl', r), contains('--insecure'));
      expect(await gen('wget', r), contains('--no-check-certificate'));
      expect(await gen('python-requests', r), contains('verify=False'));
      expect(await gen('go-nethttp', r), contains('InsecureSkipVerify: true'));
      expect(
        await gen('node-https', r),
        contains('rejectUnauthorized: false,'),
      );
      expect(
        await gen('php-curl', r),
        contains('CURLOPT_SSL_VERIFYPEER => false,'),
      );
    });

    test('an http URL with a port', () async {
      final r = RequestModel(url: 'http://localhost:8080/a?b=1');
      expect(
        await gen('python-http-client', r),
        contains('http.client.HTTPConnection("localhost", 8080)'),
      );
      expect(
        await gen('node-https', r),
        contains('import http from "node:http";'),
      );
      expect(await gen('node-https', r), contains('port: 8080,'));
      expect(await gen('ruby-nethttp', r), isNot(contains('use_ssl')));
    });
  });

  group('toCurl', () {
    test('quotes apostrophes in headers and exports multipart', () {
      final r = RequestModel(
        method: 'POST',
        url: 'https://x.dev/up',
        headers: [KV(key: 'X-Note', value: "it's")],
        bodyType: BodyType.formData,
        formFields: [
          KV(key: 'a', value: '1'),
          KV(key: 'f', value: '/tmp/x.txt', isFile: true),
        ],
      );
      final cmd = toCurl(r);
      expect(cmd, contains(r"-H 'X-Note: it'\''s'"));
      expect(cmd, contains("-F 'a=1'"));
      expect(cmd, contains("-F 'f=@/tmp/x.txt'"));
    });

    test('keeps {{variables}} unresolved and still re-imports', () {
      final r = RequestModel(
        method: 'POST',
        url: '{{base}}/x',
        bodyType: BodyType.json,
        body: '{"a":"{{b}}"}',
      );
      final cmd = toCurl(r);
      expect(cmd, contains("'{{base}}/x'"));
      final back = fromCurl(cmd)!;
      expect(back.url, '{{base}}/x');
      expect(back.body, '{"a":"{{b}}"}');
    });
  });

  group('code snippet dialog', () {
    late AppState state;
    late Directory dir;

    Future<void> setUpState(WidgetTester tester) async {
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('snippet_dialog');
        state = AppState(storage: Storage(overrideDir: dir));
        while (!state.loaded) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        state.globals.add(KV(key: 'host', value: 'api.example.com'));
        state.globals.add(KV(key: 'token', value: 's3cret'));
      });
    }

    Future<void> openDialog(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final tab = RequestTab(
        request: RequestModel(
          method: 'POST',
          url: 'https://{{host}}/v1/users/:id',
          pathVariables: [KV(key: 'id', value: '7')],
          bodyType: BodyType.json,
          body: '{"a":1}',
          authType: AuthType.bearer,
          bearerToken: '{{token}}',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => showCodeSnippetDialog(context, state, tab),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    String shown(WidgetTester tester) => tester
        .widget<SelectableText>(find.byKey(const ValueKey('snippet-code')))
        .data!;

    Future<void> pick(WidgetTester tester, String query, String label) async {
      await tester.tap(find.byKey(const ValueKey('snippet-language')));
      await tester.pumpAndSettle();
      // The menu builds only the items in view, centred on the current
      // language; scroll it until the wanted one is there.
      final menu = find.byType(Scrollable).last;
      for (
        var i = 0;
        i < 10 && find.text(label).hitTestable().evaluate().isEmpty;
        i++
      ) {
        await tester.drag(menu, Offset(0, i < 5 ? 200 : -200));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text(label).hitTestable().last);
      await tester.pumpAndSettle();
    }

    tearDown(() async => dir.delete(recursive: true));

    for (final size in [const Size(360, 640), const Size(1280, 800)]) {
      testWidgets(
        'works at ${size.width.toInt()} px: language, unresolved, copy',
        (tester) async {
          await setUpState(tester);
          String? copied;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'Clipboard.setData') {
                copied = (call.arguments as Map)['text'] as String;
              }
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );

          await openDialog(tester, size);
          expect(tester.takeException(), isNull);
          // cURL first, fully resolved.
          expect(
            shown(tester),
            startsWith("curl -X POST 'https://api.example.com/v1/users/7'"),
          );
          expect(shown(tester), contains('Authorization: Bearer s3cret'));

          // A search narrows the list; picking switches the code.
          await pick(tester, 'requests', 'Python – requests');
          expect(shown(tester), contains('import requests'));
          expect(tester.takeException(), isNull);

          // Unresolved keeps the placeholders.
          await tester.tap(find.byType(Switch));
          await tester.pumpAndSettle();
          expect(
            shown(tester),
            contains('url = "https://{{host}}/v1/users/7"'),
          );
          expect(shown(tester), contains('Bearer {{token}}'));
          expect(shown(tester), isNot(contains('s3cret')));

          await tester.tap(find.text('Copy'));
          await tester.pump();
          expect(copied, shown(tester));
          expect(find.text('Copied'), findsOneWidget);
          await tester.pump(const Duration(seconds: 3));
          expect(find.text('Copy'), findsOneWidget);

          // The code scrolls sideways instead of overflowing.
          final scroll = find.byKey(const ValueKey('snippet-code-scroll'));
          expect(scroll, findsOneWidget);
          expect(tester.takeException(), isNull);

          // Closing and reopening remembers the language for the session.
          if (size.width < 600) {
            await tester.tap(find.byType(CloseButton));
          } else {
            await tester.tap(find.text('Close'));
          }
          await tester.pumpAndSettle();
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();
          expect(shown(tester), contains('import requests'));
          // Put cURL back for the next test.
          await pick(tester, 'curl', 'Shell – cURL');
          expect(shown(tester), startsWith('curl '));
        },
      );
    }

    for (final size in [const Size(740, 360), const Size(360, 300)]) {
      testWidgets(
        'scrolls instead of overflowing at ${size.width.toInt()}x${size.height.toInt()}',
        (tester) async {
          await setUpState(tester);
          await openDialog(tester, size);
          expect(shown(tester), startsWith('curl '));
          expect(tester.takeException(), isNull);
          await tester.tap(find.byType(Switch));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('explains why a request cannot be turned into code', (
      tester,
    ) async {
      await setUpState(tester);
      final tab = RequestTab(request: RequestModel());
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: CodeSnippetDialog(state: state, tab: tab),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Request URL is empty'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
