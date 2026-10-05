import 'dart:convert';
import 'dart:io';

/// Which response bodies a load run keeps in its log.
enum BodyCapture {
  none('None'),
  failures('Failures only'),
  all('All');

  const BodyCapture(this.label);
  final String label;
}

/// One completed call in a load run.
class LoadLogEntry {
  LoadLogEntry({
    required this.seq,
    required this.offsetMs,
    required this.startedAt,
    required this.vu,
    required this.iteration,
    required this.step,
    required this.name,
    required this.method,
    required this.url,
    required this.status,
    required this.durationMs,
    required this.sizeBytes,
    required this.pass,
    this.error,
    this.contentType,
    this.body,
    this.bodyTruncated = false,
  });

  final int seq;

  /// When the response finished, relative to the run start.
  final int offsetMs;
  final DateTime startedAt;
  final int vu;
  final int iteration;
  final int step;
  final String name;
  final String method;
  final String url;
  final int status;
  final int durationMs;
  final int sizeBytes;
  final bool pass;
  final String? error;
  final String? contentType;
  final String? body;
  final bool bodyTruncated;

  Map<String, dynamic> toJson() => {
    'seq': seq,
    'offsetMs': offsetMs,
    'startedAt': startedAt.toIso8601String(),
    'vu': vu,
    'iteration': iteration,
    'step': step,
    'name': name,
    'method': method,
    'url': url,
    'status': status,
    'durationMs': durationMs,
    'sizeBytes': sizeBytes,
    'pass': pass,
    'error': ?error,
    'contentType': ?contentType,
    'body': ?body,
    if (bodyTruncated) 'bodyTruncated': true,
  };

  factory LoadLogEntry.fromJson(Map<String, dynamic> j) => LoadLogEntry(
    seq: j['seq'] as int,
    offsetMs: j['offsetMs'] as int,
    startedAt: DateTime.parse(j['startedAt'] as String),
    vu: j['vu'] as int,
    iteration: j['iteration'] as int,
    step: j['step'] as int,
    name: j['name'] as String,
    method: j['method'] as String,
    url: j['url'] as String,
    status: j['status'] as int,
    durationMs: j['durationMs'] as int,
    sizeBytes: j['sizeBytes'] as int,
    pass: j['pass'] as bool,
    error: j['error'] as String?,
    contentType: j['contentType'] as String?,
    body: j['body'] as String?,
    bodyTruncated: j['bodyTruncated'] as bool? ?? false,
  );
}

/// Streams every call of a run to a JSON-lines file so the full log costs
/// disk, not RAM; only the newest [recentLimit] entries stay in memory for
/// the live view. Saved bodies are capped per response and per run.
class LoadLog {
  LoadLog._(this.file, this._sink, this.capture);

  static const recentLimit = 200;
  static const bodyLimitBytes = 64 * 1024;
  static const bodyBudgetBytes = 256 * 1024 * 1024;

  final File file;
  final IOSink _sink;
  final BodyCapture capture;
  final List<LoadLogEntry> recent = [];
  int count = 0;
  int _bodyBytes = 0;

  /// Bodies not kept because the run's body budget was used up.
  int bodiesDropped = 0;
  bool _closed = false;

  static Future<LoadLog> create(Directory dir, BodyCapture capture) async {
    await dir.create(recursive: true);
    final file = File(
      '${dir.path}${Platform.pathSeparator}'
      'load-${DateTime.now().microsecondsSinceEpoch}.jsonl',
    );
    return LoadLog._(file, file.openWrite(), capture);
  }

  bool wantsBody(bool pass) => switch (capture) {
    BodyCapture.none => false,
    BodyCapture.failures => !pass,
    BodyCapture.all => true,
  };

  /// Decodes at most [bodyLimitBytes] of [bytes] if the budget allows.
  ({String? body, bool truncated}) takeBody(List<int> bytes) {
    if (_bodyBytes >= bodyBudgetBytes) {
      bodiesDropped++;
      return (body: null, truncated: false);
    }
    final truncated = bytes.length > bodyLimitBytes;
    final slice = truncated ? bytes.sublist(0, bodyLimitBytes) : bytes;
    _bodyBytes += slice.length;
    return (
      body: utf8.decode(slice, allowMalformed: true),
      truncated: truncated,
    );
  }

  void add(LoadLogEntry e) {
    if (_closed) return;
    count++;
    _sink.writeln(jsonEncode(e.toJson()));
    recent.add(e);
    if (recent.length > recentLimit) recent.removeAt(0);
  }

  Future<void>? _closing;

  /// Flushes and closes the file; safe to call more than once.
  Future<void> close() {
    _closed = true;
    return _closing ??= () async {
      await _sink.flush();
      await _sink.close();
    }();
  }

  /// Every entry, oldest first. Waits for the file to be closed first.
  Stream<LoadLogEntry> entries() async* {
    await close();
    yield* file
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((l) => l.isNotEmpty)
        .map(
          (l) => LoadLogEntry.fromJson(jsonDecode(l) as Map<String, dynamic>),
        );
  }

  Future<void> delete() async {
    await close();
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
