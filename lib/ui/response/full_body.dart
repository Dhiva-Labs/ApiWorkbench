import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';

import '../../theme.dart';
import '../json_view.dart' show bodyMono, jsonSpans;
import 'find.dart';

/// Above this size the full body asks for confirmation first.
const fullBodyWarnBytes = 5 * 1024 * 1024;

/// The full body view never decodes more than this; the rest is cut off.
const fullBodyLimitBytes = 32 * 1024 * 1024;

/// JSON larger than this is shown as received instead of indented, because
/// parsing it needs several times its size in memory.
const prettyJsonLimitBytes = 8 * 1024 * 1024;

/// Work on bodies larger than this runs in a background isolate.
const _isolateThresholdBytes = 1024 * 1024;

/// Lines longer than this are split into several rows so no single row is
/// expensive to draw (a minified 5 MB JSON is one line).
const defaultRowColumns = 1000;

/// A large text cut into display rows without copying it: row `i` is
/// `text[starts[i]..starts[i + 1]]` minus its line break.
class RowIndex {
  const RowIndex(this.text, this.starts, this.longestRow);

  final String text;

  /// Start offset of each row, plus `text.length` at the end.
  final Int32List starts;

  /// Characters in the longest row.
  final int longestRow;

  int get rowCount => starts.length - 1;

  /// The text of row [i] without its line break.
  String rowText(int i) {
    var end = starts[i + 1];
    if (end > starts[i] && text.codeUnitAt(end - 1) == 0x0A) end--;
    if (end > starts[i] && text.codeUnitAt(end - 1) == 0x0D) end--;
    return text.substring(starts[i], end);
  }

  /// The row holding [offset].
  int rowOf(int offset) {
    var lo = 0;
    var hi = rowCount - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (starts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }
}

/// Cuts [text] into rows at line breaks, and every [maxColumns] characters
/// within a longer line. Never splits a surrogate pair.
RowIndex indexRows(String text, {int maxColumns = defaultRowColumns}) {
  final starts = <int>[];
  var longest = 0;
  final n = text.length;
  var i = 0;
  while (i < n) {
    starts.add(i);
    final nl = text.indexOf('\n', i);
    final lineEnd = nl < 0 ? n : nl;
    var p = i;
    while (lineEnd - p > maxColumns) {
      var cut = p + maxColumns;
      if ((text.codeUnitAt(cut) & 0xFC00) == 0xDC00) cut--; // low surrogate
      starts.add(cut);
      longest = math.max(longest, cut - p);
      p = cut;
    }
    longest = math.max(longest, lineEnd - p);
    i = nl < 0 ? n : nl + 1;
  }
  starts.add(n);
  return RowIndex(text, Int32List.fromList(starts), longest);
}

/// The whole body, decoded and indexed for the virtualized text view.
class FullBodyData {
  const FullBodyData({
    required this.raw,
    required this.pretty,
    required this.shownBytes,
    required this.totalBytes,
  });

  /// The body as the server sent it.
  final RowIndex raw;

  /// The body as indented JSON, or null when it is not JSON or too large to
  /// parse ([prettyJsonLimitBytes]).
  final RowIndex? pretty;

  /// Bytes decoded; less than [totalBytes] when the body was cut at
  /// [fullBodyLimitBytes].
  final int shownBytes;
  final int totalBytes;

  bool get cut => shownBytes < totalBytes;
}

/// Decodes and indexes [bytes] on the calling isolate.
FullBodyData buildFullBody(List<int> bytes) {
  final total = bytes.length;
  final cutOff = total > fullBodyLimitBytes;
  final shown = cutOff ? bytes.sublist(0, fullBodyLimitBytes) : bytes;
  String text;
  if (cutOff) {
    text = utf8.decode(shown, allowMalformed: true);
  } else {
    try {
      text = utf8.decode(shown);
    } catch (_) {
      text = latin1.decode(shown, allowInvalid: true);
    }
  }

  RowIndex? pretty;
  final lead = text.trimLeft();
  if (shown.length <= prettyJsonLimitBytes &&
      (lead.startsWith('{') || lead.startsWith('['))) {
    try {
      final indented = const JsonEncoder.withIndent(
        '  ',
      ).convert(jsonDecode(text));
      pretty = indexRows(indented);
    } catch (_) {
      pretty = null;
    }
  }
  return FullBodyData(
    raw: indexRows(text),
    pretty: pretty,
    shownBytes: shown.length,
    totalBytes: total,
  );
}

FullBodyData _buildFullBodyTask(Uint8List bytes) => buildFullBody(bytes);

/// [buildFullBody], moved to a background isolate for bodies over 1 MB so
/// the UI keeps drawing while a big body is decoded and indented.
Future<FullBodyData> prepareFullBody(List<int> bytes) {
  if (bytes.length <= _isolateThresholdBytes) {
    return Future.value(buildFullBody(bytes));
  }
  return compute(
    _buildFullBodyTask,
    bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
  );
}

/// A virtualized view of a text far too large for one text widget: fixed-height
/// rows built on demand, scrolling both ways, with find highlights.
///
/// With [colourJson] the rows are syntax-coloured as indented JSON (a line at
/// a time, which is exact because JSON strings cannot span lines).
class LargeTextView extends StatefulWidget {
  const LargeTextView({
    super.key,
    required this.index,
    this.find,
    this.colourJson = false,
  });

  final RowIndex index;
  final FindController? find;
  final bool colourJson;

  @override
  State<LargeTextView> createState() => _LargeTextViewState();
}

class _LargeTextViewState extends State<LargeTextView> {
  static const _padding = 14.0;

  final _vertical = ScrollController();
  final _horizontal = ScrollController();
  int _stamp = -1;
  Size _viewport = Size.zero;
  double _rowHeight = 20;
  double _charWidth = 8;

  @override
  void initState() {
    super.initState();
    widget.find?.addListener(_onFind);
    WidgetsBinding.instance.addPostFrameCallback((_) => _toCurrent());
  }

  @override
  void didUpdateWidget(LargeTextView old) {
    super.didUpdateWidget(old);
    if (old.find != widget.find) {
      old.find?.removeListener(_onFind);
      widget.find?.addListener(_onFind);
    }
  }

  @override
  void dispose() {
    widget.find?.removeListener(_onFind);
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  void _onFind() {
    if (widget.find!.navStamp == _stamp) return;
    _toCurrent();
  }

  void _toCurrent() {
    final find = widget.find;
    if (find == null || !mounted) return;
    _stamp = find.navStamp;
    if (!find.isOpen || find.text != widget.index.text) return;
    final start = find.currentStart;
    if (start == null || !_vertical.hasClients) return;

    final row = widget.index.rowOf(start);
    final v = _vertical.position;
    final top = row * _rowHeight;
    if (top < v.pixels || top + _rowHeight > v.pixels + v.viewportDimension) {
      _vertical.jumpTo(
        (top - v.viewportDimension / 3).clamp(0.0, v.maxScrollExtent),
      );
    }
    if (_horizontal.hasClients) {
      final h = _horizontal.position;
      final x = (start - widget.index.starts[row]) * _charWidth;
      if (x < h.pixels || x + _charWidth > h.pixels + h.viewportDimension) {
        _horizontal.jumpTo(
          (x - h.viewportDimension / 3).clamp(0.0, h.maxScrollExtent),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final index = widget.index;
    if (index.rowCount == 0) {
      return Center(
        child: Text('(empty body)', style: TextStyle(color: Palette.textDim)),
      );
    }
    final scaler = MediaQuery.textScalerOf(context);
    final probe = TextPainter(
      text: TextSpan(text: 'MMMMMMMMMM', style: bodyMono),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    _charWidth = probe.width / 10;
    _rowHeight = probe.height;
    probe.dispose();

    return LayoutBuilder(
      builder: (context, c) {
        _viewport = Size(c.maxWidth, c.maxHeight);
        final contentWidth = math.max(
          _viewport.width,
          index.longestRow * _charWidth + _padding * 2,
        );
        final list = ListView.builder(
          controller: _vertical,
          itemCount: index.rowCount,
          itemExtent: _rowHeight,
          itemBuilder: (_, i) => _row(i),
        );
        // The scrollbars sit outside the horizontal scroll view so they stay
        // at the pane edges instead of at the end of the widest line.
        return Scrollbar(
          controller: _vertical,
          notificationPredicate: (n) => n.metrics.axis == Axis.vertical,
          child: Scrollbar(
            controller: _horizontal,
            notificationPredicate: (n) => n.metrics.axis == Axis.horizontal,
            child: SingleChildScrollView(
              controller: _horizontal,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: contentWidth,
                height: _viewport.height,
                child: SelectionArea(child: list),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _row(int i) {
    final index = widget.index;
    final text = index.rowText(i);
    final rowStart = index.starts[i];
    var spans = widget.colourJson
        ? jsonSpans(text)
        : [TextSpan(text: text, style: bodyMono)];

    final find = widget.find;
    final matches = find?.matchesFor(index.text) ?? const <int>[];
    if (matches.isNotEmpty) {
      final len = find!.queryLength;
      // Matches touching this row: the first one that ends after it starts,
      // up to the last one that starts before it ends.
      final lo = _firstAtOrAfter(matches, rowStart - len + 1);
      final rowEnd = rowStart + text.length;
      var hi = lo;
      while (hi < matches.length && matches[hi] < rowEnd) {
        hi++;
      }
      if (hi > lo) {
        spans = overlayMatches(
          spans,
          [for (var k = lo; k < hi; k++) matches[k] - rowStart],
          len,
          find.current - lo,
          matchColor: findMatchColor,
          currentColor: findCurrentColor,
        );
      }
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _padding),
      child: Text.rich(
        TextSpan(children: spans),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
      ),
    );
  }

  /// Index of the first element of [sorted] that is >= [value].
  static int _firstAtOrAfter(List<int> sorted, int value) {
    var lo = 0;
    var hi = sorted.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (sorted[mid] < value) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}
