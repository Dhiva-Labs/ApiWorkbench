import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/sound_service.dart';

void main() {
  group('sound rule resolution', () {
    final rules = {
      '2xx': 'tada',
      '4xx': 'fail',
      '404': 'custom404.mp3',
      '5xx': '',
      'error': 'alarm',
    };

    test('exact code beats the class rule', () {
      expect(soundIdFor(rules, 404), 'custom404.mp3');
      expect(soundIdFor(rules, 400), 'fail');
    });

    test('empty rule means silence, transport errors use error rule', () {
      expect(soundIdFor(rules, 500), isNull);
      expect(soundIdFor(rules, 0, isError: true), 'alarm');
      expect(soundIdFor(rules, 200), 'tada');
      expect(soundIdFor(rules, 301), isNull); // no 3xx rule set
    });
  });

  group('myinstants URL extraction', () {
    test('direct audio URLs pass through', () {
      expect(extractAudioUrl('https://x.com/a/faaak.mp3'),
          'https://x.com/a/faaak.mp3');
    });

    test('instant page HTML yields the media URL', () {
      const html = '<html><button class="small-button" '
          "onclick=\"play('/media/sounds/fbi-open-up.mp3', ...)\">"
          '</button></html>';
      expect(extractAudioUrl(html, pageUrl: 'https://www.myinstants.com/en/instant/fbi'),
          'https://www.myinstants.com/media/sounds/fbi-open-up.mp3');
    });

    test('pages without audio return null', () {
      expect(extractAudioUrl('<html>nothing here</html>'), isNull);
    });

    test('absolute og:audio URLs are found', () {
      const html = '<meta property="og:audio" '
          'content="https://www.myinstants.com/media/sounds/sad-violin.mp3">';
      expect(extractAudioUrl(html),
          'https://www.myinstants.com/media/sounds/sad-violin.mp3');
    });
  });

  group('sound library', () {
    test('import file persists and reloads; delete removes it', () async {
      final tmp = await Directory.systemTemp.createTemp('awb_sounds');
      addTearDown(() => tmp.delete(recursive: true));
      final clip = File('${tmp.path}/meme.wav');
      await clip.writeAsBytes(List.filled(64, 0));

      final lib = SoundService(overrideDir: tmp);
      final s = await lib.importFile(clip.path, name: 'Faaak');
      expect(lib.custom.single.name, 'Faaak');
      expect(await lib.resolvePath(s.id), isNotNull);

      final lib2 = SoundService(overrideDir: tmp);
      await lib2.load();
      expect(lib2.custom.single.name, 'Faaak');

      await lib2.delete(lib2.custom.single);
      expect(lib2.custom, isEmpty);
      final lib3 = SoundService(overrideDir: tmp);
      await lib3.load();
      expect(lib3.custom, isEmpty);
    });
  });

  group('settings', () {
    test('chaos mode round trip keeps rules', () {
      final s = AppSettings(chaosMode: true)..chaosRules['404'] = 'x.mp3';
      final back = AppSettings.fromJson(s.toJson());
      expect(back.chaosMode, isTrue);
      expect(back.chaosRules['404'], 'x.mp3');
      expect(back.chaosRules['2xx'], 'tada');
    });

    test('defaults: chaos mode off with the builtin rule set', () {
      final s = AppSettings.fromJson({});
      expect(s.chaosMode, isFalse);
      expect(s.chaosRules, defaultChaosRules());
    });

    test('default table maps to the real meme clips', () {
      final r = defaultChaosRules();
      expect(r['200'], 'meme_200'); // GTA mission passed
      expect(r['404'], 'meme_404'); // sad trombone
      expect(r['403'], 'meme_403'); // FBI open up
      expect(r['418'], 'meme_418'); // tea kettle
      expect(r['505'], 'meme_505'); // Windows 98 startup
      expect(r['301'], 'head_out'); // synth stand-in, clip not findable
      // every default rule points at a real builtin
      final ids = builtinSounds.map((b) => b.$1).toSet();
      for (final v in r.values) {
        expect(ids, contains(v), reason: 'rule sound $v missing');
      }
    });

    test('both legacy default sets migrate; custom sets are untouched', () {
      for (final legacy in legacyChaosRuleSets) {
        final s = AppSettings.fromJson({'chaosRules': legacy});
        expect(s.chaosRules['200'], 'meme_200', reason: 'legacy set upgraded');
      }
      final custom = {'2xx': 'mycustom.mp3'};
      final s2 = AppSettings.fromJson({'chaosRules': custom});
      expect(s2.chaosRules, custom);
    });
  });

  test('every bundled sound asset exists with a valid header', () {
    for (final (id, _, file) in builtinSounds) {
      final f = File('assets/sounds/$file');
      expect(f.existsSync(), isTrue, reason: '$file missing');
      final head = f.openSync().readSync(3);
      if (file.endsWith('.wav')) {
        expect(String.fromCharCodes(f.openSync().readSync(4)), 'RIFF',
            reason: '$file not RIFF');
      } else {
        final isMp3 = String.fromCharCodes(head) == 'ID3' ||
            (head[0] == 0xFF && (head[1] & 0xE0) == 0xE0);
        expect(isMp3, isTrue, reason: '$file ($id) is not mp3');
      }
    }
  });
}
