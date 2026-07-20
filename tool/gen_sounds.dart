// Synthesizes the built-in Fun Mode sounds as 16-bit mono WAVs.
// Original compositions/sound-alikes — safe to bundle, unlike ripped clips.
// Run with: dart run tool/gen_sounds.dart
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

const rate = 44100;
final _rnd = Random(7);

void main() {
  Directory('assets/sounds').createSync(recursive: true);
  final sounds = <String, List<double>>{
    // class fallbacks
    'tada': tada(),
    'whoosh': whoosh(),
    'fail': fail(), // womp womp trombone (404 + 4xx fallback)
    'dramatic': dramatic(),
    'alarm': alarm(), // siren (429 + network errors)
    // per-status memes
    'mission_passed': missionPassed(), // 200
    'boom_applause': boomApplause(), // 201
    'crickets': crickets(), // 204
    'head_out': headOut(), // 301
    'slide_whistle': slideWhistle(), // 302
    'ding': ding(), // 304
    'bruh': bruh(), // 400
    'access_denied': accessDenied(), // 401
    'open_up': openUp(), // 403
    'nope': nope(), // 405
    'thinking': thinking(), // 408
    'metal_pipe': metalPipe(), // 409
    'its_gone': itsGone(), // 410
    'kettle': kettle(), // 418
    'task_failed': taskFailed(), // 422
    'this_is_fine': thisIsFine(), // 500
    'construction': construction(), // 501
    'record_scratch': recordScratch(), // 502
    'flatline': flatline(), // 503
    'phone_ring': phoneRing(), // 504
    'retro_startup': retroStartup(), // 505
  };
  var total = 0;
  sounds.forEach((name, samples) {
    final f = File('assets/sounds/$name.wav');
    f.writeAsBytesSync(_wav(_normalize(samples)));
    total += f.lengthSync();
    stdout.writeln(
        '  $name.wav  ${(f.lengthSync() / 1024).toStringAsFixed(0)} KB');
  });
  stdout.writeln('total ${(total / 1024).toStringAsFixed(0)} KB');
}

// ---------------- WAV + mixing toolkit ----------------

List<double> _normalize(List<double> s) {
  var peak = 0.0;
  for (final v in s) {
    peak = max(peak, v.abs());
  }
  if (peak < 1e-6) return s;
  final g = 0.88 / peak;
  return [for (final v in s) v * g];
}

Uint8List _wav(List<double> samples) {
  final n = samples.length;
  final data = ByteData(44 + n * 2);
  void ascii(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + n * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, n * 2, Endian.little);
  for (var i = 0; i < n; i++) {
    data.setInt16(44 + i * 2, (samples[i].clamp(-1.0, 1.0) * 32000).round(),
        Endian.little);
  }
  return data.buffer.asUint8List();
}

List<double> _silence(double s) => List.filled((s * rate).round(), 0.0);

/// tone with attack/decay envelope, optional glide, vibrato and timbre.
/// timbre: 0 = pure sine, higher adds harmonics (brassy/buzzy).
List<double> _note(double freq, double dur,
    {double vol = 0.6,
    double vibrato = 0,
    double glideTo = 0,
    double timbre = 0.25,
    double attack = 0.015,
    double decay = 2.5}) {
  final n = (dur * rate).round();
  final out = List<double>.filled(n, 0);
  final target = glideTo == 0 ? freq : glideTo;
  var phase = 0.0;
  for (var i = 0; i < n; i++) {
    final t = i / n;
    final f = freq +
        (target - freq) * t +
        (vibrato > 0 ? vibrato * sin(2 * pi * 6 * i / rate) : 0);
    phase += 2 * pi * f / rate;
    final env = min(1.0, i / (rate * attack)) * exp(-decay * t);
    out[i] = vol *
        env *
        ((1 - timbre) * sin(phase) +
            timbre * 0.6 * sin(2 * phase) +
            timbre * 0.35 * sin(3 * phase));
  }
  return out;
}

/// filtered noise burst (one-pole lowpass), for thumps/claps/whooshes.
List<double> _noise(double dur,
    {double vol = 0.5,
    double cutoff = 3000,
    double attack = 0.002,
    double decay = 6}) {
  final n = (dur * rate).round();
  final out = List<double>.filled(n, 0);
  final a = 1 - exp(-2 * pi * cutoff / rate);
  var y = 0.0;
  for (var i = 0; i < n; i++) {
    final t = i / n;
    y += a * ((_rnd.nextDouble() * 2 - 1) - y);
    out[i] = vol * min(1.0, i / (rate * attack)) * exp(-decay * t) * y * 3;
  }
  return out;
}

List<double> _mix(List<List<double>> parts) {
  final n = parts.map((p) => p.length).reduce(max);
  final out = List<double>.filled(n, 0);
  for (final p in parts) {
    for (var i = 0; i < p.length; i++) {
      out[i] += p[i];
    }
  }
  return out;
}

List<double> _at(double sec, List<double> p) =>
    _mix([_silence(sec + p.length / rate), _seqPad(sec, p)]);

List<double> _seqPad(double sec, List<double> p) =>
    [..._silence(sec), ...p];

List<double> _seq(List<List<double>> parts, {double overlap = 0}) {
  final out = <double>[];
  final skip = (overlap * rate).round();
  for (final p in parts) {
    final at = max(0, out.length - skip);
    while (out.length < at + p.length) {
      out.add(0);
    }
    for (var i = 0; i < p.length; i++) {
      out[at + i] += p[i];
    }
  }
  return out;
}

// ---------------- class fallbacks ----------------

List<double> tada() => _seq([
      _note(523.25, 0.14),
      _note(659.25, 0.14),
      _note(783.99, 0.14),
      _mix([_note(1046.5, 0.5), _note(783.99, 0.5, vol: 0.3)]),
    ], overlap: 0.04);

List<double> whoosh() => _note(280, 0.28, glideTo: 950, vol: 0.5);

List<double> fail() => _seq([
      _note(233.08, 0.28, glideTo: 220, vibrato: 3, timbre: 0.45),
      _note(220.00, 0.28, glideTo: 207, vibrato: 3, timbre: 0.45),
      _note(196.00, 0.30, glideTo: 185, vibrato: 4, timbre: 0.45),
      _note(174.61, 0.60, glideTo: 152, vibrato: 6, vol: 0.7, timbre: 0.45),
    ], overlap: 0.03);

List<double> dramatic() => _mix([
      _note(220.0, 1.3, vibrato: 4, vol: 0.42),
      _note(261.6, 1.3, vibrato: 4, vol: 0.36),
      _note(329.6, 1.3, vibrato: 5, vol: 0.34),
      _at(0.25, _note(110.0, 1.0, vol: 0.5)),
    ]);

List<double> alarm() => _seq([
      for (var i = 0; i < 2; i++) ...[
        _note(740, 0.16, vol: 0.55, timbre: 0.5),
        _note(520, 0.16, vol: 0.55, timbre: 0.5),
      ],
      _note(740, 0.28, vol: 0.55, timbre: 0.5),
    ]);

// ---------------- per-status memes ----------------

/// 200 — triumphant "mission passed" fanfare (original melody).
List<double> missionPassed() => _seq([
      _mix([_note(392, 0.22, timbre: 0.5), _note(196, 0.22, timbre: 0.5)]),
      _mix([_note(523, 0.22, timbre: 0.5), _note(262, 0.22, timbre: 0.5)]),
      _mix([_note(659, 0.22, timbre: 0.5), _note(330, 0.22, timbre: 0.5)]),
      _mix([
        _note(784, 0.9, timbre: 0.5, decay: 1.6),
        _note(523, 0.9, timbre: 0.5, decay: 1.6, vol: 0.4),
        _note(392, 0.9, timbre: 0.5, decay: 1.6, vol: 0.4),
        _note(196, 0.9, timbre: 0.5, decay: 1.6, vol: 0.5),
      ]),
    ], overlap: 0.05);

/// 201 — deep boom + applause.
List<double> boomApplause() => _mix([
      _note(55, 0.5, glideTo: 38, vol: 1.0, timbre: 0.1, decay: 5),
      _noise(0.25, vol: 0.5, cutoff: 900, decay: 9),
      // applause: many short claps
      for (var i = 0; i < 26; i++)
        _at(0.15 + i * 0.028 + _rnd.nextDouble() * 0.05,
            _noise(0.05, vol: 0.30, cutoff: 2600, decay: 22)),
    ]);

/// 204 — crickets.
List<double> crickets() {
  List<double> chirp(double at) => _at(
      at,
      _mix([
        for (var i = 0; i < 3; i++)
          _at(i * 0.055,
              _note(4300, 0.045, vol: 0.30, timbre: 0.05, decay: 4)),
      ]));
  return _mix([chirp(0.05), chirp(0.55), chirp(1.1)]);
}

/// 301 — footsteps walking off + door shut ("imma head out").
List<double> headOut() => _mix([
      _at(0.00, _noise(0.09, vol: 0.55, cutoff: 350, decay: 14)),
      _at(0.28, _noise(0.09, vol: 0.45, cutoff: 320, decay: 14)),
      _at(0.56, _noise(0.09, vol: 0.35, cutoff: 300, decay: 14)),
      _at(0.84, _noise(0.08, vol: 0.28, cutoff: 280, decay: 14)),
      _at(1.15, _mix([
        _noise(0.16, vol: 0.8, cutoff: 500, decay: 10),
        _note(90, 0.18, vol: 0.6, decay: 8),
      ])),
    ]);

/// 302 — cartoon slide whistle (down).
List<double> slideWhistle() =>
    _note(1250, 0.55, glideTo: 320, vol: 0.5, vibrato: 12, timbre: 0.1);

/// 304 — soft notification ding.
List<double> ding() => _mix([
      _note(1568, 0.5, vol: 0.4, timbre: 0.05, decay: 4),
      _note(2093, 0.5, vol: 0.25, timbre: 0.05, decay: 5),
      _at(0.10, _note(2349, 0.4, vol: 0.18, timbre: 0.05, decay: 5)),
    ]);

/// 400 — deadpan "bruh" buzz.
List<double> bruh() => _mix([
      _note(155, 0.30, glideTo: 92, vol: 0.8, timbre: 0.6, decay: 3),
      _note(310, 0.30, glideTo: 184, vol: 0.25, timbre: 0.6, decay: 3),
    ]);

/// 401 — harsh access-denied double buzzer.
List<double> accessDenied() => _seq([
      _note(311, 0.16, vol: 0.7, timbre: 0.7, decay: 1.2),
      _silence(0.05),
      _note(233, 0.30, vol: 0.7, timbre: 0.7, decay: 1.5),
    ]);

/// 403 — three aggressive door knocks + siren blip ("open up!").
List<double> openUp() => _mix([
      _at(0.00, _knock()),
      _at(0.16, _knock()),
      _at(0.32, _knock()),
      _at(0.60, _note(880, 0.18, glideTo: 660, vol: 0.5, timbre: 0.5)),
      _at(0.80, _note(880, 0.24, glideTo: 660, vol: 0.5, timbre: 0.5)),
    ]);

List<double> _knock() => _mix([
      _noise(0.06, vol: 0.9, cutoff: 700, decay: 18),
      _note(120, 0.07, glideTo: 80, vol: 0.7, decay: 12),
    ]);

/// 405 — curt "nope" double beep.
List<double> nope() => _seq([
      _note(392, 0.12, vol: 0.6, timbre: 0.4, decay: 3),
      _silence(0.06),
      _note(294, 0.18, vol: 0.6, timbre: 0.4, decay: 3),
    ]);

/// 408 — gentle thinking/waiting noodle (original tune).
List<double> thinking() {
  List<double> pluck(double f, double at) =>
      _at(at, _note(f, 0.30, vol: 0.45, timbre: 0.15, decay: 5));
  return _mix([
    pluck(523, 0.00), pluck(659, 0.25), pluck(784, 0.50), pluck(659, 0.75),
    pluck(523, 1.00), pluck(659, 1.25), pluck(880, 1.50), pluck(784, 1.80),
  ]);
}

/// 409 — metal pipe clang (inharmonic partials, two bounces).
List<double> metalPipe() {
  List<double> clang(double vol) => _mix([
        _noise(0.03, vol: vol, cutoff: 6000, decay: 25),
        _note(526, 0.7, vol: vol * 0.8, timbre: 0.0, decay: 6),
        _note(1377, 0.6, vol: vol * 0.7, timbre: 0.0, decay: 8),
        _note(2214, 0.5, vol: vol * 0.5, timbre: 0.0, decay: 10),
        _note(3316, 0.4, vol: vol * 0.35, timbre: 0.0, decay: 12),
      ]);
  return _mix([clang(0.9), _at(0.42, clang(0.45))]);
}

/// 410 — pop, then it whooshes away… and it's gone.
List<double> itsGone() => _mix([
      _note(600, 0.05, glideTo: 900, vol: 0.5, timbre: 0.1, decay: 1),
      _at(0.10, _note(700, 0.5, glideTo: 120, vol: 0.4, timbre: 0.1)),
      _at(0.12, _noise(0.45, vol: 0.25, cutoff: 1200, decay: 5)),
    ]);

/// 418 — tea kettle whistle building up.
List<double> kettle() {
  final n = (1.2 * rate).round();
  final out = List<double>.filled(n, 0);
  var phase = 0.0;
  for (var i = 0; i < n; i++) {
    final t = i / n;
    final f = 2100 + 500 * t + 30 * sin(2 * pi * 9 * i / rate);
    phase += 2 * pi * f / rate;
    final env = pow(t, 1.5) * exp(-1.2 * max(0, t - 0.85) * 8);
    out[i] = 0.5 * env * (sin(phase) + 0.3 * (_rnd.nextDouble() * 2 - 1));
  }
  return out;
}

/// 422 — cheerful ding… then buzzer: task failed successfully.
List<double> taskFailed() => _seq([
      _mix([_note(1046, 0.28, vol: 0.45, timbre: 0.05, decay: 4),
            _note(1318, 0.28, vol: 0.3, timbre: 0.05, decay: 4)]),
      _silence(0.08),
      _note(180, 0.4, vol: 0.7, timbre: 0.75, decay: 1.2),
    ]);

/// 500 — calm chime… then the room explodes (this is fine).
List<double> thisIsFine() => _mix([
      _note(880, 0.35, vol: 0.3, timbre: 0.05, decay: 3),
      _at(0.40, _note(988, 0.35, vol: 0.3, timbre: 0.05, decay: 3)),
      _at(0.85, _mix([
        _note(50, 0.9, glideTo: 32, vol: 1.0, timbre: 0.15, decay: 3.5),
        _noise(0.5, vol: 0.7, cutoff: 1400, decay: 5),
        _noise(0.9, vol: 0.3, cutoff: 400, decay: 3),
      ])),
    ]);

/// 501 — jackhammer + reverse beep.
List<double> construction() => _mix([
      for (var i = 0; i < 10; i++)
        _at(i * 0.07, _mix([
          _noise(0.04, vol: 0.55, cutoff: 900, decay: 20),
          _note(95, 0.05, vol: 0.5, decay: 15),
        ])),
      _at(0.85, _note(1000, 0.18, vol: 0.35, timbre: 0.3, decay: 2)),
      _at(1.15, _note(1000, 0.18, vol: 0.35, timbre: 0.3, decay: 2)),
    ]);

/// 502 — record scratch.
List<double> recordScratch() {
  final n = (0.45 * rate).round();
  final out = List<double>.filled(n, 0);
  final a = 1 - exp(-2 * pi * 2500 / rate);
  var y = 0.0;
  for (var i = 0; i < n; i++) {
    final t = i / n;
    // wobbling playback speed = amplitude/pitch judder
    final wob = 0.5 + 0.5 * sin(2 * pi * (14 - 10 * t) * t * 3);
    y += a * ((_rnd.nextDouble() * 2 - 1) - y);
    out[i] = 0.75 * (1 - t) * wob * y * 3;
  }
  return _mix([out, _note(300, 0.4, glideTo: 80, vol: 0.25, timbre: 0.4)]);
}

/// 503 — two monitor beeps, then flatline.
List<double> flatline() => _mix([
      _at(0.00, _note(880, 0.10, vol: 0.4, timbre: 0.2, decay: 1)),
      _at(0.45, _note(880, 0.10, vol: 0.4, timbre: 0.2, decay: 1)),
      _at(0.90, _note(880, 1.3, vol: 0.35, timbre: 0.2, decay: 0.4,
          attack: 0.005)),
    ]);

/// 504 — phone ringing… forever (two rings).
List<double> phoneRing() {
  List<double> ring(double at) => _at(
      at,
      _mix([
        for (var i = 0; i < 20; i++)
          _at(i * 0.032, _mix([
            _note(440, 0.028, vol: 0.30, timbre: 0.2, decay: 0.5),
            _note(480, 0.028, vol: 0.30, timbre: 0.2, decay: 0.5),
          ])),
      ]));
  return _mix([ring(0), ring(1.05)]);
}

/// 505 — warm retro startup chord sweep (original, 90s energy).
List<double> retroStartup() => _mix([
      _at(0.00, _note(277.2, 1.8, vol: 0.30, timbre: 0.1, decay: 1.2)),
      _at(0.12, _note(415.3, 1.7, vol: 0.28, timbre: 0.1, decay: 1.2)),
      _at(0.24, _note(554.4, 1.6, vol: 0.26, timbre: 0.1, decay: 1.2)),
      _at(0.36, _note(830.6, 1.5, vol: 0.22, timbre: 0.1, decay: 1.2)),
      _at(0.55, _note(1108.7, 1.3, vol: 0.18, timbre: 0.05, decay: 1.2)),
      _at(0.00, _note(69.3, 2.0, vol: 0.30, timbre: 0.1, decay: 1.0)),
    ]);
