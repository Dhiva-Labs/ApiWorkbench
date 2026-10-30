import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../services/console_events.dart';
import '../services/doc_export.dart' show maskSecrets;

/// Which entries the console lists.
enum ConsoleFilter {
  all('All'),
  network('Network'),
  logs('Logs'),
  errors('Errors');

  const ConsoleFilter(this.label);
  final String label;
}

/// One console row: a network exchange or a line of output.
sealed class ConsoleEntry {
  DateTime get at;

  /// Counts up in the order entries were added; set by [ConsoleLog]. A
  /// stable identity for list keys and "expanded" state, which indexes
  /// (shifted by the capacity trimming) are not.
  int seq = 0;

  /// A failed request (no response, or status 400 and up) or an error line.
  bool get isError;

  /// Rough memory held, for [ConsoleLog.byteBudget].
  int get weight;

  bool matches(ConsoleFilter f) => switch (f) {
    ConsoleFilter.all => true,
    ConsoleFilter.network => this is ExchangeEntry,
    ConsoleFilter.logs => this is LineEntry,
    ConsoleFilter.errors => isError,
  };
}

class ExchangeEntry extends ConsoleEntry {
  ExchangeEntry(this.record);
  final ExchangeRecord record;

  @override
  DateTime get at => record.at;

  @override
  bool get isError =>
      record.error != null || record.status == 0 || record.status >= 400;

  @override
  int get weight =>
      512 +
      (record.requestBody?.length ?? 0) +
      (record.responseBody?.length ?? 0);
}

class LineEntry extends ConsoleEntry {
  LineEntry(this.line);
  final ConsoleLine line;

  @override
  DateTime get at => line.at;

  @override
  bool get isError => line.level == ConsoleLevel.error;

  @override
  int get weight => 128 + line.message.length * 2;
}

/// The console's recent history, newest last. Bounded twice: at most
/// [capacity] entries, and about [byteBudget] bytes of captured bodies, so a
/// run of large downloads can't fill memory. The oldest entries go first and
/// are counted in [dropped].
class ConsoleLog extends ChangeNotifier {
  ConsoleLog({this.capacity = 1000, this.byteBudget = 64 * 1024 * 1024})
    : assert(capacity > 0);

  final int capacity;

  /// Upper bound for the captured bodies kept; the newest entry always stays.
  final int byteBudget;

  final List<ConsoleEntry> entries = [];

  int _nextSeq = 1;
  int _dropped = 0;
  int _bytes = 0;
  int _version = 0;

  /// Entries evicted for room since the last [clear].
  int get dropped => _dropped;

  /// Changes whenever [entries] does; a cheap key for cached views.
  int get version => _version;

  void addExchange(ExchangeRecord r) => _add([ExchangeEntry(r)]);

  void addLines(Iterable<ConsoleLine> lines) =>
      _add([for (final l in lines) LineEntry(l)]);

  void _add(List<ConsoleEntry> items) {
    if (items.isEmpty) return;
    for (final e in items) {
      e.seq = _nextSeq++;
      _bytes += e.weight;
    }
    entries.addAll(items);
    var over = entries.length - capacity;
    if (over < 0) over = 0;
    // Over budget: keep dropping the oldest, but never the newest entry.
    var bytes = _bytes;
    for (var i = 0; i < over; i++) {
      bytes -= entries[i].weight;
    }
    while (bytes > byteBudget && over < entries.length - 1) {
      bytes -= entries[over].weight;
      over++;
    }
    if (over > 0) {
      entries.removeRange(0, over);
      _dropped += over;
      _bytes = bytes;
    }
    _version++;
    notifyListeners();
  }

  void clear() {
    entries.clear();
    _dropped = 0;
    _bytes = 0;
    _version++;
    notifyListeners();
  }

  // Counts are asked for on every rebuild; recounting 1000 entries only when
  // something changed keeps that free.
  int _countsVersion = -1;
  ({int all, int network, int logs, int errors}) _counts = (
    all: 0,
    network: 0,
    logs: 0,
    errors: 0,
  );

  /// How many entries each [ConsoleFilter] would list.
  ({int all, int network, int logs, int errors}) counts() {
    if (_countsVersion != _version) {
      var network = 0, errors = 0;
      for (final e in entries) {
        if (e is ExchangeEntry) network++;
        if (e.isError) errors++;
      }
      _counts = (
        all: entries.length,
        network: network,
        logs: entries.length - network,
        errors: errors,
      );
      _countsVersion = _version;
    }
    return _counts;
  }

  /// The entries to list for [filter] and a search [query], oldest first.
  ///
  /// The search is case-insensitive over what the console shows: for an
  /// exchange its method, URL, status, source, error, headers and the first
  /// [searchBodyLimit] bytes of each body; for a line its text and source.
  /// It runs on the masked text, so a secret value can't be found by typing
  /// it.
  List<ConsoleEntry> view({
    ConsoleFilter filter = ConsoleFilter.all,
    String query = '',
    Set<String> secrets = const {},
  }) {
    final q = query.trim().toLowerCase();
    return [
      for (final e in entries)
        if (e.matches(filter) &&
            (q.isEmpty ||
                maskSecrets(
                  consoleSearchText(e),
                  secrets,
                ).toLowerCase().contains(q)))
          e,
    ];
  }
}

/// How much of each body the console search reads.
const searchBodyLimit = 32 * 1024;

/// The text a console search looks through for [e].
String consoleSearchText(ConsoleEntry e) {
  switch (e) {
    case LineEntry(:final line):
      return '${line.level.name} ${line.source} ${line.message}';
    case ExchangeEntry(:final record):
      final b = StringBuffer(
        '${record.method} ${record.url} ${record.status} '
        '${record.statusMessage} ${record.source} ${record.error ?? ''}\n',
      );
      for (final h in record.requestHeaders) {
        b.writeln('${h.key}: ${h.value}');
      }
      for (final h in record.responseHeaders.entries) {
        b.writeln('${h.key}: ${h.value.join(', ')}');
      }
      for (final body in [record.requestBody, record.responseBody]) {
        if (body == null || body.isEmpty) continue;
        b.writeln(
          utf8.decode(
            body.length > searchBodyLimit
                ? body.sublist(0, searchBodyLimit)
                : body,
            allowMalformed: true,
          ),
        );
      }
      return b.toString();
  }
}

// ---------------------------------------------------------------------------
// Presenting entries (shared by the panel and the copy buttons).
// ---------------------------------------------------------------------------

/// `12:03:45`, or `12:03:45.123` with [millis], in local time.
String formatClock(DateTime t, {bool millis = false}) {
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final base = '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  return millis ? '$base.${l.millisecond.toString().padLeft(3, '0')}' : base;
}

String formatDuration(int ms) =>
    ms < 1000 ? '$ms ms' : '${(ms / 1000).toStringAsFixed(2)} s';

String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
}

/// `HTTP/2` for the transport's `2`; `unknown` when it didn't report one.
String protocolLabel(String? p) => switch (p) {
  null || '' => 'not reported',
  final v when v.toUpperCase().startsWith('HTTP') => v,
  final v => 'HTTP/$v',
};

/// A captured body made readable.
class BodyView {
  const BodyView(this.text, {this.binary = false, this.json = false});

  /// What to show: pretty JSON when the body parses as JSON, else the text.
  final String text;

  /// The bytes aren't text; [text] is a placeholder.
  final bool binary;
  final bool json;
}

/// Decodes [bytes] for display. Valid JSON is pretty-printed (never when
/// [truncated], since a cut-off document won't parse); binary content gets a
/// placeholder instead of a wall of replacement characters.
BodyView describeBody(List<int>? bytes, {bool truncated = false}) {
  if (bytes == null || bytes.isEmpty) return const BodyView('');
  final head = bytes.length > 1024 ? bytes.sublist(0, 1024) : bytes;
  var bad = 0;
  final sample = utf8.decode(head, allowMalformed: true);
  for (final c in sample.codeUnits) {
    if (c == 0 || c == 0xFFFD) bad++;
  }
  // A cut multibyte character at the end of the sample is not "binary".
  if (bad > 0 && (bad > sample.length ~/ 10 || sample.contains('\u0000'))) {
    return BodyView('(binary data, ${formatSize(bytes.length)})', binary: true);
  }
  final text = utf8.decode(bytes, allowMalformed: true);
  if (!truncated) {
    final first = text.trimLeft();
    if (first.startsWith('{') || first.startsWith('[')) {
      try {
        return BodyView(
          const JsonEncoder.withIndent('  ').convert(jsonDecode(text)),
          json: true,
        );
      } catch (_) {
        // Not JSON after all: fall through to the raw text.
      }
    }
  }
  return BodyView(text);
}

/// Note shown under a body that was cut to [ExchangeRecord.bodyLimit].
String truncationNote(String what, int fullSize) =>
    '$what truncated at ${formatSize(ExchangeRecord.bodyLimit)}'
    '${fullSize > 0 ? ' (full size ${formatSize(fullSize)})' : ''}';

/// An entry as plain text, for copying. [bodyLimit] cuts each body to that
/// many characters (null keeps it whole); [secrets] are masked.
String consoleEntryText(
  ConsoleEntry e, {
  Set<String> secrets = const {},
  int? bodyLimit,
}) => maskSecrets(_entryText(e, bodyLimit), secrets);

/// Many entries, separated by blank lines.
String consoleText(
  Iterable<ConsoleEntry> entries, {
  Set<String> secrets = const {},
  int? bodyLimit,
}) => maskSecrets(
  entries.map((e) => _entryText(e, bodyLimit)).join('\n\n'),
  secrets,
);

String _entryText(ConsoleEntry e, int? bodyLimit) {
  switch (e) {
    case LineEntry(:final line):
      return '[${formatClock(line.at, millis: true)}] '
          '${line.level.name.toUpperCase()}'
          '${line.source.isEmpty ? '' : ' (${line.source})'}: ${line.message}';
    case ExchangeEntry(:final record):
      final r = record;
      final b = StringBuffer()
        ..writeln('[${formatClock(r.at, millis: true)}] ${r.method} ${r.url}');
      final status = r.error != null
          ? 'Error: ${r.error}'
          : r.status == 0
          ? 'No response'
          : '${r.status} ${r.statusMessage}'.trim();
      b.writeln(
        '$status · ${formatDuration(r.durationMs)} · '
        '${formatSize(r.responseSize)} · ${protocolLabel(r.protocol)} · '
        '${r.source} · hop ${r.hop}',
      );
      void headers(String title, Iterable<MapEntry<String, String>> hs) {
        b.writeln('\n$title');
        if (hs.isEmpty) b.writeln('  (none)');
        for (final h in hs) {
          b.writeln('  ${h.key}: ${h.value}');
        }
      }

      void body(String title, List<int>? bytes, bool cut, int size) {
        b.writeln('\n$title');
        if (bytes == null || bytes.isEmpty) {
          b.writeln('  (empty)');
          return;
        }
        var text = describeBody(bytes, truncated: cut).text;
        var shortened = false;
        if (bodyLimit != null && text.length > bodyLimit) {
          text = text.substring(0, bodyLimit);
          shortened = true;
        }
        b.writeln(text);
        if (shortened) b.writeln('… (cut for copying; open the entry for all)');
        if (cut) b.writeln('(${truncationNote('Body', size)})');
      }

      headers('Request headers', r.requestHeaders);
      body('Request body', r.requestBody, r.requestBodyTruncated, 0);
      headers('Response headers', [
        for (final h in r.responseHeaders.entries)
          for (final v in h.value) MapEntry(h.key, v),
      ]);
      body(
        'Response body',
        r.responseBody,
        r.responseBodyTruncated,
        r.responseSize,
      );
      return b.toString().trimRight();
  }
}
