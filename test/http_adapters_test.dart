import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The package files and libraries [entry] reaches through import, export
/// and part directives, each with the file that first pulled it in.
Map<String, String> reachable(String entry) {
  final directive = RegExp(
    r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''',
    multiLine: true,
  );
  final lib = Directory('lib').absolute.path;
  final seen = <String, String>{entry: ''};
  final queue = [File(entry).absolute.path];
  final files = {queue.first};
  while (queue.isNotEmpty) {
    final path = queue.removeAt(0);
    for (final m in directive.allMatches(File(path).readAsStringSync())) {
      final uri = m.group(1)!;
      String? local;
      if (uri.startsWith('package:api_workbench/')) {
        local = '$lib/${uri.substring('package:api_workbench/'.length)}';
      } else if (!uri.contains(':')) {
        local = File(path).parent.uri.resolve(uri).toFilePath();
      } else {
        seen.putIfAbsent(uri, () => path);
      }
      if (local != null && files.add(local)) {
        seen[local] = path;
        queue.add(local);
      }
    }
  }
  return seen;
}

void main() {
  test('the command-line runner never loads Flutter', () {
    // `dart build cli` cannot compile anything that reaches dart:ui, and
    // native_dio_adapter imports Flutter. Only the app registers it.
    final seen = reachable('bin/apiworkbench_cli.dart');
    String chain(String key) {
      final out = <String>[key];
      var at = seen[key];
      while (at != null && at.isNotEmpty) {
        out.add(at.replaceFirst('${Directory.current.path}/', ''));
        at = seen[at];
      }
      return out.join(' <= ');
    }

    for (final banned in [
      'dart:ui',
      'package:native_dio_adapter/',
      'package:flutter/',
      'package:flutter_test/',
    ]) {
      final hit = seen.keys.where((k) => k.startsWith(banned)).firstOrNull;
      expect(hit, isNull, reason: hit == null ? null : chain(hit));
    }
    expect(seen.keys.any((k) => k.endsWith('http_service.dart')), isTrue);
  });
}
