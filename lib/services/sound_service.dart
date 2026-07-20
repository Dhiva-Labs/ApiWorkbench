import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';


/// One playable sound: a bundled original or a user-imported meme clip.
class SoundInfo {
  SoundInfo({required this.id, required this.name, this.builtin = false});

  final String id;
  String name;
  final bool builtin;
}

/// (id, display name, bundled asset file under assets/sounds/).
const builtinSounds = [
  // the real meme clips (bundled at the user's request)
  ('meme_200', '🎉 Mission Passed! (GTA) — 200', 'meme_200.mp3'),
  ('meme_201', '🎊 Vine Boom — 201', 'meme_201.mp3'),
  ('meme_204', '🦗 Crickets — 204', 'meme_204.mp3'),
  ('meme_302', '🔄 Slide whistle — 302', 'meme_302.mp3'),
  ('meme_304', '😐 Windows notification — 304', 'meme_304.mp3'),
  ('meme_400', '🤦 Bruh — 400', 'meme_400.mp3'),
  ('meme_401', '🚫 Access Denied — 401', 'meme_401.mp3'),
  ('meme_403', '👮 FBI OPEN UP! — 403', 'meme_403.mp3'),
  ('meme_404', '💀 Sad trombone — 404', 'meme_404.mp3'),
  ('meme_405', '🙅 Nope. — 405', 'meme_405.mp3'),
  ('meme_408', '⏰ Thinking music — 408', 'meme_408.mp3'),
  ('meme_409', '⚔️ Metal pipe — 409', 'meme_409.mp3'),
  ('meme_410', '👻 And it\'s gone — 410', 'meme_410.mp3'),
  ('meme_418', '🫖 Tea kettle — 418', 'meme_418.mp3'),
  ('meme_422', '📋 Task failed successfully — 422', 'meme_422.mp3'),
  ('meme_429', '🚨 Alarm siren — 429', 'meme_429.mp3'),
  ('meme_500', '🔥 Explosion — 500', 'meme_500.mp3'),
  ('meme_501', '🚧 Construction — 501', 'meme_501.mp3'),
  ('meme_502', '🌉 Record scratch — 502', 'meme_502.mp3'),
  ('meme_503', '🚑 Flatline — 503', 'meme_503.mp3'),
  ('meme_504', '📞 Ringing forever — 504', 'meme_504.mp3'),
  ('meme_505', '💾 Windows 98 startup — 505', 'meme_505.mp3'),
  // synthesized originals (kept as alternates / class fallbacks)
  ('head_out', '🏃 Imma head out (synth) — 301', 'head_out.wav'),
  ('tada', 'Ta-da! (synth, 2xx fallback)', 'tada.wav'),
  ('whoosh', 'Whoosh (synth, 3xx fallback)', 'whoosh.wav'),
  ('fail', 'Womp womp trombone (synth, 4xx fallback)', 'fail.wav'),
  ('dramatic', 'Dramatic strings (synth, 5xx fallback)', 'dramatic.wav'),
  ('alarm', 'Siren (synth, network errors)', 'alarm.wav'),
  ('mission_passed', 'Mission passed (synth)', 'mission_passed.wav'),
  ('boom_applause', 'Boom + applause (synth)', 'boom_applause.wav'),
  ('crickets', 'Crickets (synth)', 'crickets.wav'),
  ('slide_whistle', 'Slide whistle (synth)', 'slide_whistle.wav'),
  ('ding', 'Notification ding (synth)', 'ding.wav'),
  ('bruh', 'Bruh (synth)', 'bruh.wav'),
  ('access_denied', 'Access denied (synth)', 'access_denied.wav'),
  ('open_up', 'Open up knocks (synth)', 'open_up.wav'),
  ('nope', 'Nope (synth)', 'nope.wav'),
  ('thinking', 'Thinking music (synth)', 'thinking.wav'),
  ('metal_pipe', 'Metal pipe (synth)', 'metal_pipe.wav'),
  ('its_gone', 'And it\'s gone (synth)', 'its_gone.wav'),
  ('kettle', 'Tea kettle (synth)', 'kettle.wav'),
  ('task_failed', 'Task failed successfully (synth)', 'task_failed.wav'),
  ('this_is_fine', 'This is fine + boom (synth)', 'this_is_fine.wav'),
  ('construction', 'Construction (synth)', 'construction.wav'),
  ('record_scratch', 'Record scratch (synth)', 'record_scratch.wav'),
  ('flatline', 'Flatline (synth)', 'flatline.wav'),
  ('phone_ring', 'Phone ringing (synth)', 'phone_ring.wav'),
  ('retro_startup', 'Retro startup (synth)', 'retro_startup.wav'),
];

/// Resolves which sound id applies to a response. Exact code rules win,
/// then the status class ('4xx'), then 'error' for transport failures.
String? soundIdFor(Map<String, String> rules, int status, {bool isError = false}) {
  String? pick(String key) {
    final v = rules[key];
    return (v == null || v.isEmpty) ? null : v;
  }

  if (isError || status <= 0) return pick('error');
  return pick('$status') ?? pick('${status ~/ 100}xx');
}

/// Extracts a direct audio URL from myinstants.com page HTML (or returns the
/// input when it already points at an audio file).
String? extractAudioUrl(String urlOrHtml, {String? pageUrl}) {
  final direct = RegExp(r'\.(mp3|wav|ogg|m4a)(\?.*)?$', caseSensitive: false);
  if (direct.hasMatch(urlOrHtml.trim()) && !urlOrHtml.contains('\n')) {
    return urlOrHtml.trim();
  }
  final m = RegExp("['\"(]/?(media/sounds/[^'\")]+\\.(?:mp3|wav|ogg|m4a))")
      .firstMatch(urlOrHtml);
  if (m != null) {
    final base = Uri.tryParse(pageUrl ?? 'https://www.myinstants.com');
    return Uri.parse(
            'https://${base?.host ?? 'www.myinstants.com'}/${m.group(1)}')
        .toString();
  }
  // Absolute audio URLs (e.g. og:audio meta tags).
  final abs = RegExp(r'https?://[^\s' '"' r"'()<>]+\.(?:mp3|wav|ogg|m4a)",
          caseSensitive: false)
      .firstMatch(urlOrHtml);
  return abs?.group(0);
}

/// Stores user sounds on disk and plays clips with whatever the platform
/// offers (no extra native audio dependency needed).
class SoundService {
  SoundService({Directory? overrideDir}) : _override = overrideDir;

  final Directory? _override;
  Directory? _dir;
  final List<SoundInfo> custom = [];
  bool _loaded = false;

  List<SoundInfo> get all => [
        for (final (id, name, _) in builtinSounds)
          SoundInfo(id: id, name: name, builtin: true),
        ...custom,
      ];

  Future<Directory> _base() async {
    if (_dir != null) return _dir!;
    final root = _override ?? await getApplicationSupportDirectory();
    _dir = await Directory('${root.path}/apiworkbench/sounds')
        .create(recursive: true);
    return _dir!;
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = File('${(await _base()).path}/sounds.json');
      if (!await f.exists()) return;
      final list = jsonDecode(await f.readAsString()) as List<dynamic>;
      custom
        ..clear()
        ..addAll(list.map((e) => SoundInfo(
            id: e['id'] as String, name: e['name'] as String? ?? 'sound')));
    } catch (_) {}
  }

  Future<void> _persist() async {
    final f = File('${(await _base()).path}/sounds.json');
    await f.writeAsString(jsonEncode([
      for (final s in custom) {'id': s.id, 'name': s.name},
    ]));
  }

  /// Copies a local audio file into the library.
  Future<SoundInfo> importFile(String path, {String? name}) async {
    await load();
    final src = File(path);
    final ext = path.contains('.') ? path.split('.').last : 'mp3';
    final id = 'u${DateTime.now().millisecondsSinceEpoch}.$ext';
    await src.copy('${(await _base()).path}/$id');
    final info = SoundInfo(
        id: id, name: name ?? path.split(Platform.pathSeparator).last);
    custom.add(info);
    await _persist();
    return info;
  }

  /// Downloads a sound the user pointed at — a direct audio URL or a
  /// myinstants.com page (the audio link is extracted from the HTML).
  Future<SoundInfo> importUrl(String url, {String? name}) async {
    await load();
    final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30)));
    var audioUrl = extractAudioUrl(url);
    if (audioUrl == null) {
      final page = await dio.get<String>(url,
          options: Options(responseType: ResponseType.plain));
      audioUrl = extractAudioUrl(page.data ?? '', pageUrl: url);
    }
    if (audioUrl == null) {
      throw Exception('No audio file found at that URL.');
    }
    final resp = await dio.get<List<int>>(audioUrl,
        options: Options(responseType: ResponseType.bytes));
    final bytes = resp.data ?? [];
    if (bytes.isEmpty) throw Exception('The audio download was empty.');
    if (bytes.length > 10 * 1024 * 1024) {
      throw Exception('That file is over 10 MB — pick a short clip.');
    }
    final ext = audioUrl.split('.').last.split('?').first;
    final id = 'u${DateTime.now().millisecondsSinceEpoch}.$ext';
    await File('${(await _base()).path}/$id').writeAsBytes(bytes);
    final fallback = Uri.parse(audioUrl).pathSegments.last;
    final info = SoundInfo(id: id, name: name ?? fallback);
    custom.add(info);
    await _persist();
    return info;
  }

  Future<void> delete(SoundInfo s) async {
    custom.remove(s);
    try {
      await File('${(await _base()).path}/${s.id}').delete();
    } catch (_) {}
    await _persist();
  }

  /// Returns a playable file path for a sound id, extracting bundled
  /// assets to disk on first use.
  Future<String?> resolvePath(String id) async {
    final dir = await _base();
    for (final (bid, _, file) in builtinSounds) {
      if (bid == id) {
        final f = File('${dir.path}/builtin_$file');
        if (!await f.exists()) {
          final data = await rootBundle.load('assets/sounds/$file');
          await f.writeAsBytes(data.buffer.asUint8List());
        }
        return f.path;
      }
    }
    final f = File('${dir.path}/$id');
    return await f.exists() ? f.path : null;
  }

  Future<void> playForStatus(Map<String, String> rules, int status,
      {bool isError = false}) async {
    final id = soundIdFor(rules, status, isError: isError);
    if (id == null) return;
    await play(id);
  }

  Future<void> play(String id) async {
    try {
      final path = await resolvePath(id);
      if (path == null) return;
      await _playFile(path);
    } catch (_) {
      // Fun mode must never break a request.
    }
  }

  // ---------------- platform playback ----------------

  static const _channel = MethodChannel('apiworkbench/sound');
  String? _linuxPlayer;

  Future<void> _playFile(String path) async {
    if (Platform.isAndroid || Platform.isIOS) {
      await _channel.invokeMethod('play', {'path': path});
      return;
    }
    if (Platform.isMacOS) {
      await Process.start('afplay', [path]);
      return;
    }
    if (Platform.isWindows) {
      await Process.start('powershell', [
        '-NoProfile',
        '-c',
        "\$p=New-Object System.Windows.Media.MediaPlayer;\$p.Open('$path');\$p.Play();Start-Sleep 4",
      ]);
      return;
    }
    // Linux: first available player that handles common formats.
    _linuxPlayer ??= await _detectLinuxPlayer();
    if (_linuxPlayer == null) return;
    final args = switch (_linuxPlayer!) {
      'ffplay' => ['-nodisp', '-autoexit', '-loglevel', 'quiet', path],
      'gst-play-1.0' => ['--quiet', path],
      _ => [path],
    };
    await Process.start(_linuxPlayer!, args);
  }

  Future<String?> _detectLinuxPlayer() async {
    // Order favours players that decode mp3 (imported meme clips).
    for (final p in ['gst-play-1.0', 'ffplay', 'mpv', 'pw-play', 'paplay', 'aplay']) {
      final r = await Process.run('which', [p]);
      if (r.exitCode == 0) return p;
    }
    return null;
  }
}
