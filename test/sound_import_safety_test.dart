import 'dart:io';

import 'package:api_workbench/services/sound_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/temp_dir.dart';

/// Reads the PowerShell single-quoted string literal that starts at
/// [start] (the opening quote) the way PowerShell does: `'` and the
/// typographic single quotes all open and close a literal, and a doubled one
/// is a literal quote. Returns the text and where the literal ends.
({String text, int end}) _psLiteral(String s, int start) {
  const quotes = "'\u2018\u2019\u201a\u201b";
  expect(quotes.contains(s[start]), isTrue, reason: 'starts with a quote');
  final b = StringBuffer();
  var i = start + 1;
  while (i < s.length) {
    final c = s[i];
    if (quotes.contains(c)) {
      if (i + 1 < s.length && quotes.contains(s[i + 1])) {
        b.write(c);
        i += 2;
        continue;
      }
      return (text: b.toString(), end: i + 1);
    }
    b.write(c);
    i++;
  }
  fail('unterminated literal in: $s');
}

void main() {
  group('safeSoundExtension', () {
    test('keeps short alphanumeric extensions, lowercased', () {
      expect(safeSoundExtension('mp3'), 'mp3');
      expect(safeSoundExtension('WAV'), 'wav');
      expect(safeSoundExtension('m4a'), 'm4a');
      expect(safeSoundExtension('flac'), 'flac');
      expect(safeSoundExtension(' ogg '), 'ogg');
    });

    test('falls back to mp3 for anything else', () {
      for (final bad in [
        null,
        '',
        'toolong',
        "mp3'; calc; '",
        'mp3\u2019',
        'a/b',
        r'a\b',
        'mp3#frag',
        'mp 3',
        'mp3\n',
        '../x',
        '\u00e9\u00e9',
      ]) {
        expect(safeSoundExtension(bad), 'mp3', reason: '$bad');
      }
    });
  });

  group('windowsPlayCommand', () {
    String opened(String path) {
      final cmd = windowsPlayCommand(path);
      const call = r'$p.Open(';
      final at = cmd.indexOf(call);
      expect(at, greaterThan(0));
      final lit = _psLiteral(cmd, at + call.length);
      // After the literal only the call's closing parenthesis and the
      // fixed rest of the command may follow.
      expect(
        cmd.substring(lit.end),
        r');$p.Play();Start-Sleep 4',
        reason: 'the path ended the string early: $cmd',
      );
      return lit.text;
    }

    test('a plain path is one string literal', () {
      const path = r'C:\Users\Ada\sounds\u1.mp3';
      final cmd = windowsPlayCommand(path);
      expect(cmd, startsWith('Add-Type -AssemblyName PresentationCore;'));
      expect(cmd, contains(r"$p.Open('C:\Users\Ada\sounds\u1.mp3');"));
      expect(opened(path), path);
    });

    test('quotes in the path, plain or typographic, cannot end the string', () {
      for (final path in [
        r"C:\Users\O'Neil\u1.mp3",
        "C:\\Users\\O\u2019Neil\\u1.mp3",
        "C:\\u1.mp3'); calc; ('",
        "C:\\u1.mp3\u2019); calc; (\u2018",
        "C:\\u1.mp3\u201a); calc; (\u201b",
        "C:\\a'b\u2018c\u2019d\u201ae\u201bf'.mp3",
      ]) {
        expect(opened(path), path, reason: path);
      }
    });

    test('control characters and \$ use an escaped double-quoted string', () {
      final cmd = windowsPlayCommand('C:\\a\$(calc)\r\n.mp3');
      expect(cmd, contains(r'$p.Open("'));
      expect(cmd, contains(r'`$(calc)'));
      expect(cmd, contains('`r'));
      // Everything after the path is the fixed tail.
      expect(cmd, endsWith(r'");$p.Play();Start-Sleep 4'));
    });
  });

  group('importing', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('awb_snd_'));
    tearDown(() => deleteTempDir(tmp));

    Future<File> clip(String name) async =>
        File('${tmp.path}/$name')..writeAsBytesSync(List.filled(16, 0));

    test('the stored file keeps a safe extension', () async {
      final svc = SoundService(overrideDir: tmp);
      final good = await svc.importFile((await clip('Meme.WAV')).path);
      expect(good.id, endsWith('.wav'));

      // An extension a URL or a file name could use to smuggle text.
      final odd = await svc.importFile((await clip("x.m'p3")).path);
      expect(odd.id, endsWith('.mp3'));
      expect(odd.id, isNot(contains("'")));
      final nodot = Directory('${tmp.path}/some.dir')..createSync();
      final noExt = File('${nodot.path}/clip')..writeAsBytesSync([1, 2, 3]);
      final plain = await svc.importFile(noExt.path);
      expect(plain.id, endsWith('.mp3'));
      expect(plain.id, isNot(contains('/')));

      for (final s in svc.custom) {
        final stored = await svc.resolvePath(s.id);
        expect(stored, isNotNull, reason: s.id);
        expect(File(stored!).parent.path, endsWith('apiworkbench/sounds'));
      }
    });
  });
}
