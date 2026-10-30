import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ChangeNotifier, compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme.dart';
import '../adaptive.dart';
import '../help_tip.dart';

/// Searching stops after this many matches ("10000+" is shown).
const maxFindMatches = 10000;

/// Texts longer than this are searched in a background isolate so typing in
/// the find bar never stalls the UI.
const findAsyncThreshold = 256 * 1024;

/// Where the matches of one search start. Every match is as long as the
/// query, so the length is not stored.
class FindResult {
  const FindResult(this.starts, {this.capped = false});

  /// Offsets into the searched text, ascending, never overlapping.
  final List<int> starts;

  /// More matches exist beyond [maxFindMatches].
  final bool capped;
}

/// Finds [query] in [text]. Matches do not overlap. Case-insensitive search
/// folds case without changing offsets, so a match always lines up with the
/// original text.
FindResult findMatches(
  String text,
  String query, {
  bool caseSensitive = false,
  int max = maxFindMatches,
}) {
  if (query.isEmpty || text.isEmpty) return const FindResult([]);
  final starts = <int>[];
  var capped = false;

  void scan(String hay, String needle) {
    var i = 0;
    while (true) {
      final at = hay.indexOf(needle, i);
      if (at < 0) return;
      if (starts.length >= max) {
        capped = true;
        return;
      }
      starts.add(at);
      i = at + needle.length;
    }
  }

  if (caseSensitive) {
    scan(text, query);
  } else {
    final lowText = text.toLowerCase();
    final lowQuery = query.toLowerCase();
    // Lower-casing can change a string's length (e.g. U+0130), which would
    // shift every later offset; a regular expression keeps them exact.
    if (lowText.length == text.length && lowQuery.length == query.length) {
      scan(lowText, lowQuery);
    } else {
      try {
        final re = RegExp(
          RegExp.escape(query),
          caseSensitive: false,
          unicode: true,
        );
        for (final m in re.allMatches(text)) {
          if (starts.length >= max) {
            capped = true;
            break;
          }
          starts.add(m.start);
        }
      } on FormatException {
        // A query the regular expression engine rejects (a lone surrogate):
        // match it exactly instead.
        starts.clear();
        capped = false;
        scan(text, query);
      }
    }
  }
  return FindResult(starts, capped: capped);
}

class _FindArgs {
  const _FindArgs(this.text, this.query, this.caseSensitive);
  final String text;
  final String query;
  final bool caseSensitive;
}

FindResult _findInBackground(_FindArgs a) =>
    findMatches(a.text, a.query, caseSensitive: a.caseSensitive);

/// State of the find bar: the query, the text being searched, the matches
/// and which one is current. Shared by the bar and the Pretty / Raw views,
/// which highlight [matchesFor] their own text only.
class FindController extends ChangeNotifier {
  bool _open = false;
  String _query = '';
  bool _caseSensitive = false;
  String _text = '';
  FindResult _result = const FindResult([]);
  int _current = -1;
  int _navStamp = 0;
  int _focusStamp = 0;
  bool _busy = false;
  int _epoch = 0;
  Timer? _debounce;
  bool _disposed = false;

  /// Whether the find bar is showing.
  bool get isOpen => _open;
  String get query => _query;
  bool get caseSensitive => _caseSensitive;

  /// The text being searched.
  String get text => _text;

  /// Number of matches (capped at [maxFindMatches]).
  int get count => _result.starts.length;

  /// More matches exist than [count] reports.
  bool get capped => _result.capped;

  /// Index of the emphasised match, -1 when there is none.
  int get current => _current;

  /// A search over a big text is still running.
  bool get busy => _busy;

  /// Length of every match, in characters.
  int get queryLength => _query.length;

  /// Changes each time the current match moves, so views know to scroll to
  /// it.
  int get navStamp => _navStamp;

  /// Changes each time the bar is asked to take keyboard focus.
  int get focusStamp => _focusStamp;

  /// The match offsets to highlight in [shown], or none when [shown] is not
  /// the text this controller searched (another tab's view). Strings compare
  /// by identity first, so this is cheap even for a huge body.
  List<int> matchesFor(String shown) =>
      _open && shown == _text ? _result.starts : const [];

  /// Offset of the current match in the searched text, or null.
  int? get currentStart =>
      _current >= 0 && _current < count ? _result.starts[_current] : null;

  /// "3 of 12", "No results" or "" for the bar's label.
  String get label {
    if (_busy) return 'Searching…';
    if (_query.isEmpty) return '';
    if (count == 0) return 'No results';
    return '${_current + 1} of $count${capped ? '+' : ''}';
  }

  /// Shows the bar. When it is already open, asks it to take focus again.
  void open() {
    _open = true;
    _focusStamp++;
    notifyListeners();
  }

  /// Hides the bar and clears the highlights. The query is kept for the next
  /// time.
  void close() {
    if (!_open) return;
    _open = false;
    _epoch++;
    _debounce?.cancel();
    _busy = false;
    notifyListeners();
  }

  /// Sets the text to search (the Pretty or Raw text being shown). Searches
  /// again when it differs from the current one.
  void setText(String text) {
    if (text == _text) return;
    _text = text;
    _search();
  }

  void setQuery(String query) {
    if (query == _query) return;
    _query = query;
    _search(debounce: true);
  }

  void setCaseSensitive(bool value) {
    if (value == _caseSensitive) return;
    _caseSensitive = value;
    _search();
  }

  /// Moves to the next match, wrapping around.
  void next() => _step(1);

  /// Moves to the previous match, wrapping around.
  void previous() => _step(-1);

  void _step(int by) {
    if (count == 0) return;
    _current = (_current + by) % count;
    if (_current < 0) _current += count;
    _navStamp++;
    notifyListeners();
  }

  void _search({bool debounce = false}) {
    _debounce?.cancel();
    final epoch = ++_epoch;
    if (_query.isEmpty || _text.isEmpty) {
      _apply(const FindResult([]), epoch);
      return;
    }
    if (_text.length <= findAsyncThreshold) {
      _apply(findMatches(_text, _query, caseSensitive: _caseSensitive), epoch);
      return;
    }
    // Drop the old matches: they were made for another query and would be
    // drawn at the wrong length while this search runs.
    _result = const FindResult([]);
    _current = -1;
    _navStamp++;
    _busy = true;
    notifyListeners();
    final args = _FindArgs(_text, _query, _caseSensitive);
    Future<void> run() async {
      final r = await compute(_findInBackground, args);
      _apply(r, epoch);
    }

    if (debounce) {
      _debounce = Timer(const Duration(milliseconds: 200), run);
    } else {
      run();
    }
  }

  void _apply(FindResult r, int epoch) {
    if (_disposed || epoch != _epoch) return;
    _result = r;
    _busy = false;
    _current = r.starts.isEmpty ? -1 : 0;
    _navStamp++;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    super.dispose();
  }
}

/// Splits flat [base] spans at the edges of [starts] matches (each [length]
/// characters long) and gives them a background, with the [current] one
/// emphasised. [base] must cover the searched text exactly, in order.
List<TextSpan> overlayMatches(
  List<TextSpan> base,
  List<int> starts,
  int length,
  int current, {
  required Color matchColor,
  required Color currentColor,
}) {
  if (starts.isEmpty || length == 0) return base;
  final out = <TextSpan>[];
  var first = 0; // first match that can still touch the span
  var pos = 0;
  for (final span in base) {
    final t = span.text ?? '';
    final from = pos;
    final to = pos + t.length;
    pos = to;
    if (t.isEmpty) continue;
    while (first < starts.length && starts[first] + length <= from) {
      first++;
    }
    var cursor = from;
    for (var k = first; k < starts.length && starts[k] < to; k++) {
      final a = math.max(starts[k], from);
      final b = math.min(starts[k] + length, to);
      if (a > cursor) {
        out.add(
          TextSpan(
            text: t.substring(cursor - from, a - from),
            style: span.style,
          ),
        );
      }
      out.add(
        TextSpan(
          text: t.substring(a - from, b - from),
          style: (span.style ?? const TextStyle()).copyWith(
            backgroundColor: k == current ? currentColor : matchColor,
          ),
        ),
      );
      cursor = b;
    }
    if (cursor < to) {
      out.add(TextSpan(text: t.substring(cursor - from), style: span.style));
    }
  }
  return out;
}

/// Highlight colours for find matches.
Color get findMatchColor => Palette.post.withValues(alpha: 0.30);
Color get findCurrentColor => Palette.post.withValues(alpha: 0.85);

/// The find bar: a query field with a match count, previous / next, a
/// case-sensitivity toggle and close. Enter and Shift+Enter move between
/// matches; Escape closes the bar.
class FindBar extends StatefulWidget {
  const FindBar({super.key, required this.find, required this.onClose});

  final FindController find;

  /// Called for the close button and Escape.
  final VoidCallback onClose;

  @override
  State<FindBar> createState() => _FindBarState();
}

class _FindBarState extends State<FindBar> {
  late final TextEditingController _field = TextEditingController(
    text: widget.find.query,
  );
  late final FocusNode _focus = FocusNode(
    debugLabel: 'find field',
    onKeyEvent: _onKey,
  );
  int _focusStamp = -1;

  @override
  void initState() {
    super.initState();
    widget.find.addListener(_onFind);
    _onFind();
  }

  @override
  void didUpdateWidget(FindBar old) {
    super.didUpdateWidget(old);
    if (old.find != widget.find) {
      old.find.removeListener(_onFind);
      widget.find.addListener(_onFind);
    }
  }

  @override
  void dispose() {
    widget.find.removeListener(_onFind);
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onFind() {
    // Ctrl+F while the bar is open: focus the field and select its text.
    if (widget.find.focusStamp != _focusStamp) {
      _focusStamp = widget.find.focusStamp;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _focus.requestFocus();
        _field.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _field.text.length,
        );
      });
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        widget.find.previous();
      } else {
        widget.find.next();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final find = widget.find;
    return ListenableBuilder(
      listenable: find,
      builder: (context, _) {
        final touch = isTouch(context);
        final side = touch ? minTouchTarget : 32.0;
        final constraints = BoxConstraints(minWidth: side, minHeight: side);

        Widget button(
          IconData icon,
          VoidCallback? onTap,
          String title,
          String help, {
          String? example,
        }) => HelpHover(
          help,
          title: title,
          example: example,
          child: IconButton(
            iconSize: 18,
            constraints: constraints,
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            icon: Icon(icon, color: Palette.textDim),
            onPressed: onTap,
          ),
        );

        final hasMatches = find.count > 0;
        // The help sits on the magnifier, not the whole field: a tooltip
        // around a text field would compete with its long-press selection.
        final field = TextField(
          controller: _field,
          focusNode: _focus,
          autofocus: true,
          textInputAction: TextInputAction.search,
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(
            isDense: true,
            hintText: 'Find in body',
            prefixIcon: HelpHover(
              'Type to highlight every match in the Pretty or Raw view. '
              'Enter jumps to the next match, Shift+Enter to the previous '
              'one, Escape closes the bar.',
              title: 'Find in body',
              example: 'userId',
              child: Icon(Icons.search, size: 18),
            ),
            prefixIconConstraints: BoxConstraints(minWidth: 34),
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          ),
          onChanged: find.setQuery,
          // Soft keyboards report Enter as the action instead.
          onSubmitted: (_) {
            find.next();
            _focus.requestFocus();
          },
        );

        final label = HelpHover(
          'Which match is highlighted strongly, out of how many. Searching '
          'stops after $maxFindMatches matches.',
          title: 'Match count',
          example: '3 of 12',
          child: Text(
            find.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: find.query.isNotEmpty && !find.busy && find.count == 0
                  ? Palette.delete
                  : Palette.textDim,
            ),
          ),
        );

        final controls = [
          button(
            Icons.keyboard_arrow_up,
            hasMatches ? find.previous : null,
            'Previous match',
            'Jump to the match before this one. Shift+Enter does the same.',
          ),
          button(
            Icons.keyboard_arrow_down,
            hasMatches ? find.next : null,
            'Next match',
            'Jump to the next match. Enter does the same.',
          ),
          HelpHover(
            'Match upper and lower case exactly, so "id" does not find "ID".',
            title: 'Match case',
            example: 'Aa',
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => find.setCaseSensitive(!find.caseSensitive),
              child: Container(
                constraints: constraints,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  color: find.caseSensitive
                      ? Palette.accentSoft
                      : Colors.transparent,
                ),
                child: Text(
                  'Aa',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: find.caseSensitive
                        ? Palette.accent
                        : Palette.textDim,
                  ),
                ),
              ),
            ),
          ),
          button(
            Icons.close,
            widget.onClose,
            'Close find',
            'Hide the find bar and clear the highlights. Escape does the '
                'same.',
          ),
        ];

        return Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          decoration: BoxDecoration(
            color: Palette.surfaceAlt,
            border: Border(bottom: BorderSide(color: Palette.border)),
          ),
          child: LayoutBuilder(
            builder: (context, c) {
              if (c.maxWidth < 460) {
                // Phones: the field gets a line of its own.
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    field,
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(child: label),
                        ...controls,
                      ],
                    ),
                  ],
                );
              }
              return Row(
                children: [
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: field,
                    ),
                  ),
                  const SizedBox(width: 10),
                  ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 70),
                    child: label,
                  ),
                  const SizedBox(width: 4),
                  ...controls,
                ],
              );
            },
          ),
        );
      },
    );
  }
}
