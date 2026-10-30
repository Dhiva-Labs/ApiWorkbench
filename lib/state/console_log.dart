import 'package:flutter/foundation.dart';

import '../services/console_events.dart';

/// One console row: a network exchange or a line of output.
sealed class ConsoleEntry {
  DateTime get at;
}

class ExchangeEntry extends ConsoleEntry {
  ExchangeEntry(this.record);
  final ExchangeRecord record;

  @override
  DateTime get at => record.at;
}

class LineEntry extends ConsoleEntry {
  LineEntry(this.line);
  final ConsoleLine line;

  @override
  DateTime get at => line.at;
}

/// The console's recent history, newest last, capped at [capacity].
class ConsoleLog extends ChangeNotifier {
  ConsoleLog({this.capacity = 1000});

  final int capacity;
  final List<ConsoleEntry> entries = [];

  void addExchange(ExchangeRecord r) => _add([ExchangeEntry(r)]);

  void addLines(Iterable<ConsoleLine> lines) =>
      _add([for (final l in lines) LineEntry(l)]);

  void _add(List<ConsoleEntry> items) {
    if (items.isEmpty) return;
    entries.addAll(items);
    final over = entries.length - capacity;
    if (over > 0) entries.removeRange(0, over);
    notifyListeners();
  }

  void clear() {
    entries.clear();
    notifyListeners();
  }
}
