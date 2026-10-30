import 'dart:convert';
import 'dart:typed_data';

/// Which way a log entry travelled.
enum Direction {
  /// Sent by this client.
  sent,

  /// Received from the server or broker.
  received,

  /// Not a message: connected, disconnected, errors and other notes.
  system,
}

/// How binary payloads are written out as text.
enum BinaryFormat { hex, base64 }

/// Calls listeners when something changes. A tiny stand-in for Flutter's
/// ChangeNotifier so the connection code stays free of Flutter imports.
mixin ChangeSignal {
  final List<void Function()> _listeners = [];

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  /// Tells every listener that state changed.
  void notify() {
    for (final l in List.of(_listeners)) {
      l();
    }
  }
}

/// One line of a message log.
class LogEntry {
  LogEntry({
    required this.seq,
    required this.direction,
    DateTime? time,
    this.label = '',
    this.title,
    this.text = '',
    this.bytes,
    Map<String, String>? meta,
    this.isError = false,
  }) : time = time ?? DateTime.now(),
       meta = meta ?? const {},
       size = bytes?.length ?? utf8.encode(text).length;

  /// Position in the log, counted from the first message ever added.
  final int seq;
  final Direction direction;
  final DateTime time;

  /// Short kind shown as a badge: `text`, `binary`, `event`, `ack`, `error`.
  final String label;

  /// Headline such as an event name or an MQTT topic.
  final String? title;

  /// The payload as text. Empty for binary entries.
  final String text;

  /// The payload of a binary message.
  final Uint8List? bytes;

  /// Extra facts shown as chips: id, QoS, retain, ...
  final Map<String, String> meta;

  /// A failure rather than a normal note (system entries only).
  final bool isError;

  /// Payload size in bytes.
  final int size;

  bool get isBinary => bytes != null;

  String? _pretty;
  bool _prettyDone = false;

  /// The text re-indented when it is a JSON object or array, else null.
  String? get prettyText {
    if (!_prettyDone) {
      _prettyDone = true;
      _pretty = bytes == null ? prettyJson(text) : null;
    }
    return _pretty;
  }

  /// The full payload for display: indented JSON, plain text, or the bytes
  /// in [format].
  String body(BinaryFormat format) {
    final b = bytes;
    if (b != null) {
      return format == BinaryFormat.hex ? hexDump(b) : base64.encode(b);
    }
    return prettyText ?? text;
  }

  /// A one-line summary of at most [max] characters.
  String preview(BinaryFormat format, {int max = 160}) {
    final b = bytes;
    final String raw;
    if (b != null) {
      raw = format == BinaryFormat.hex
          ? hexLine(b.length > max ~/ 3 ? b.sublist(0, max ~/ 3) : b)
          : base64.encode(b.length > max ? b.sublist(0, max * 3 ~/ 4) : b);
      return b.length > max ~/ 3 && format == BinaryFormat.hex ? '$raw …' : raw;
    }
    raw = text.length > max * 2 ? text.substring(0, max * 2) : text;
    final flat = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length > max ? '${flat.substring(0, max)}…' : flat;
  }

  String? _search;

  /// Lower-case text the search box looks through.
  String get searchable => _search ??= [
    label,
    ?title,
    text,
    if (bytes != null) ...[hexLine(bytes!), base64.encode(bytes!)],
    ...meta.entries.map((e) => '${e.key} ${e.value}'),
  ].join('\n').toLowerCase();

  /// A plain-text rendering used by Copy and export.
  String asText(BinaryFormat format) {
    final head = StringBuffer(formatClock(time))
      ..write(' ')
      ..write(switch (direction) {
        Direction.sent => 'SENT',
        Direction.received => 'RECEIVED',
        Direction.system => 'SYSTEM',
      });
    if (label.isNotEmpty) head.write(' $label');
    if (title != null) head.write(' $title');
    for (final e in meta.entries) {
      head.write(' ${e.key}=${e.value}');
    }
    if (direction != Direction.system || size > 0) {
      head.write(' ($size B)');
    }
    final payload = body(format);
    return payload.isEmpty ? head.toString() : '$head\n$payload';
  }
}

/// A bounded, ordered list of [LogEntry]s. The oldest entries are dropped
/// once [capacity] is exceeded.
class MessageLog with ChangeSignal {
  MessageLog({this.capacity = 2000});

  final int capacity;
  final List<LogEntry> _entries = [];
  int _next = 1;

  /// How many entries were discarded to stay within [capacity].
  int dropped = 0;

  List<LogEntry> get entries => List.unmodifiable(_entries);
  int get length => _entries.length;
  bool get isEmpty => _entries.isEmpty;

  LogEntry operator [](int i) => _entries[i];

  /// Appends an entry and returns it.
  LogEntry add(
    Direction direction, {
    String label = '',
    String? title,
    String text = '',
    Uint8List? bytes,
    Map<String, String>? meta,
    bool isError = false,
    DateTime? time,
  }) {
    final entry = LogEntry(
      seq: _next++,
      direction: direction,
      time: time,
      label: label,
      title: title,
      text: text,
      bytes: bytes,
      meta: meta,
      isError: isError,
    );
    _entries.add(entry);
    if (_entries.length > capacity) {
      final extra = _entries.length - capacity;
      _entries.removeRange(0, extra);
      dropped += extra;
    }
    notify();
    return entry;
  }

  void clear() {
    _entries.clear();
    dropped = 0;
    notify();
  }

  /// Entries that pass the [directions] filter and contain [query].
  List<LogEntry> filtered({String query = '', Set<Direction>? directions}) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty && (directions == null || directions.length == 3)) {
      return _entries;
    }
    return [
      for (final e in _entries)
        if ((directions == null || directions.contains(e.direction)) &&
            (q.isEmpty || e.searchable.contains(q)))
          e,
    ];
  }

  /// All entries written out as plain text, one block per message.
  String export(BinaryFormat format, {Iterable<LogEntry>? only}) =>
      (only ?? _entries).map((e) => e.asText(format)).join('\n\n');
}

/// [text] re-indented when it is a JSON object or array, else null.
String? prettyJson(String text) {
  final t = text.trim();
  if (t.isEmpty || !(t.startsWith('{') || t.startsWith('['))) return null;
  try {
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(t));
  } on FormatException {
    return null;
  }
}

/// Bytes as space-separated hex pairs on one line.
String hexLine(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

/// Bytes as hex, 16 per line, each line followed by its printable text.
String hexDump(List<int> bytes) {
  final out = StringBuffer();
  for (var i = 0; i < bytes.length; i += 16) {
    final row = bytes.sublist(i, i + 16 > bytes.length ? bytes.length : i + 16);
    if (i > 0) out.writeln();
    out
      ..write(i.toRadixString(16).padLeft(4, '0'))
      ..write('  ')
      ..write(hexLine(row).padRight(47))
      ..write('  ')
      ..write(
        String.fromCharCodes(row.map((b) => b >= 0x20 && b < 0x7f ? b : 0x2e)),
      );
  }
  return out.toString();
}

/// `12:34:56.789`
String formatClock(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.'
      '${t.millisecond.toString().padLeft(3, '0')}';
}

/// `12 B`, `3.4 KB`, `1.2 MB`
String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
