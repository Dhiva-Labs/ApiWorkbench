import 'dart:convert';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/postman_import.dart';
import 'package:api_workbench/services/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('imports leave out local file paths', () {
    test('an ApiWorkbench workspace file: form files and file bodies', () {
      final ws = buildWorkspaceJson([
        CollectionModel(
          name: 'Shared',
          preRequestScript: 'a();',
          requests: [
            RequestModel(
              name: 'Upload',
              bodyType: BodyType.formData,
              formFields: [
                KV(
                  key: 'doc',
                  value: '/home/someone/notes/report.pdf',
                  isFile: true,
                ),
                KV(key: 'empty', isFile: true),
                KV(key: 'note', value: 'kept'),
              ],
              testScript: 'b();',
              examples: [
                ResponseExample(
                  name: 'ok',
                  originalRequest: RequestModel(
                    bodyType: BodyType.binary,
                    body: '/etc/hostname',
                  ),
                ),
              ],
            ),
            RequestModel(
              name: 'Raw',
              bodyType: BodyType.binary,
              body: r'C:\Users\someone\secrets.txt',
            ),
          ],
        ),
      ], []);
      final r = importApiFile(ws);
      final c = r.collections.single;
      final up = c.requests.first;
      expect(up.formFields.map((f) => '${f.key}=${f.value}:${f.isFile}'), [
        'doc=:true',
        'empty=:true',
        'note=kept:false',
      ]);
      expect(up.formFields.first.description, contains('"report.pdf"'));
      expect(up.examples.single.originalRequest!.body, isEmpty);
      expect(c.requests[1].body, isEmpty);
      // Examples are cleared too, but only what would be sent is counted.
      expect(r.fileReferencesCleared, 2);
      expect(r.warnings.single, contains('2 file path(s) were not imported'));

      final kept = importApiFile(ws, keepFilePaths: true);
      expect(kept.fileReferencesCleared, 0);
      expect(
        kept.collections.single.requests.first.formFields.first.value,
        '/home/someone/notes/report.pdf',
      );
    });

    test('a Postman file field with a list of paths keeps one row each', () {
      final r = importApiFile(
        jsonEncode({
          'info': {'name': 'P', 'schema': 'collection/v2.1.0'},
          'item': [
            {
              'name': 'Up',
              'request': {
                'method': 'POST',
                'url': 'https://x.test',
                'body': {
                  'mode': 'formdata',
                  'formdata': [
                    {
                      'key': 'f',
                      'type': 'file',
                      'src': ['/a/1.png', '/b/2.png'],
                    },
                    {'key': 'none', 'type': 'file', 'src': []},
                  ],
                },
              },
            },
          ],
        }),
      );
      final fields = r.collections.single.requests.single.formFields;
      expect(fields.map((f) => '${f.key}=${f.value}'), ['f=', 'f=', 'none=']);
      expect(fields[1].description, contains('"2.png"'));
      expect(r.fileReferencesCleared, 2);
    });
  });
}
