import 'codegen.dart';
import 'literals.dart';
import 'shell.dart' show uniqueNames;

/// Ruby `Net::HTTP`.
class RubyGenerator extends CodeGenerator {
  const RubyGenerator();

  @override
  String get id => 'ruby-nethttp';
  @override
  String get language => 'Ruby';
  @override
  String get library => 'Net::HTTP';

  static const _classes = {
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
    final secure = r.parsedUrl.secure;
    final b = StringBuffer('require "uri"\nrequire "net/http"\n');
    if (!r.verifySsl && secure) b.writeln('require "openssl"');
    b.writeln();
    b.writeln('url = URI(${rbStr(r.url)})\n');
    b.writeln('http = Net::HTTP.new(url.host, url.port)');
    if (secure) b.writeln('http.use_ssl = true');
    if (!r.verifySsl && secure) {
      b.writeln('http.verify_mode = OpenSSL::SSL::VERIFY_NONE');
    }
    b.writeln();
    final cls = _classes[r.method];
    b.writeln(
      cls != null
          ? 'request = Net::HTTP::$cls.new(url)'
          : 'request = Net::HTTPGenericRequest.new(${rbStr(r.method)}, true, true, url)',
    );
    // set_form_data / set_form write the Content-Type themselves.
    final headers = r.headerMap(formType: r.body is UrlEncodedBody);
    headers.forEach((k, v) => b.writeln('request[${rbStr(k)}] = ${rbStr(v)}'));
    switch (r.body) {
      case NoBody():
        break;
      case RawBody(:final text):
        b.writeln('request.body = ${rbStr(text)}');
      case UrlEncodedBody(:final fields):
        if (uniqueNames(fields)) {
          b.writeln('request.set_form_data(');
          for (final f in fields) {
            b.writeln('  ${rbStr(f.name)} => ${rbStr(f.value)},');
          }
          b.writeln(')');
        } else {
          b.writeln('request.set_form_data([');
          for (final f in fields) {
            b.writeln('  [${rbStr(f.name)}, ${rbStr(f.value)}],');
          }
          b.writeln('])');
        }
      case MultipartBody(:final fields):
        b.writeln('request.set_form([');
        for (final f in fields) {
          b.writeln(
            f.isFile
                ? '  [${rbStr(f.name)}, File.open(${rbStr(f.value)})],'
                : '  [${rbStr(f.name)}, ${rbStr(f.value)}],',
          );
        }
        b.writeln('], "multipart/form-data")');
      case FileBody(:final path):
        b.writeln('request.body = File.binread(${rbStr(path)})');
    }
    b.writeln();
    b.writeln('response = http.request(request)');
    b.write('puts response.read_body');
    return b.toString();
  }
}
