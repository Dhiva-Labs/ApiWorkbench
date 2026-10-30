import 'package:flutter/material.dart';

import '../json_view.dart' show bodyMono;
import 'find.dart';

/// The Raw view's text: selectable monospace with the find bar's matches
/// highlighted. [text] must be the same string given to
/// [FindController.setText] for the highlights to show.
class FindableText extends StatelessWidget {
  const FindableText({super.key, required this.text, this.find});

  final String text;
  final FindController? find;

  @override
  Widget build(BuildContext context) {
    final find = this.find;
    if (find == null) return SelectableText(text, style: bodyMono);
    return ListenableBuilder(
      listenable: find,
      builder: (context, _) {
        final matches = find.matchesFor(text);
        if (matches.isEmpty) return SelectableText(text, style: bodyMono);
        return SelectableText.rich(
          TextSpan(
            children: overlayMatches(
              [TextSpan(text: text, style: bodyMono)],
              matches,
              find.queryLength,
              find.current,
              matchColor: findMatchColor,
              currentColor: findCurrentColor,
            ),
          ),
        );
      },
    );
  }
}

/// A vertical scroll view around the text-body [child] that scrolls the
/// current find match into view when the find bar moves to it.
///
/// [text] is the string [child] draws; it is laid out once more off-screen to
/// learn where the match falls, which is cheap for a 64 KB preview.
class FindScroll extends StatefulWidget {
  const FindScroll({
    super.key,
    required this.find,
    required this.text,
    required this.child,
  });

  final FindController find;
  final String text;
  final Widget child;

  @override
  State<FindScroll> createState() => _FindScrollState();
}

class _FindScrollState extends State<FindScroll> {
  static const _padding = 14.0;

  final _scroll = ScrollController();
  int _stamp = -1;
  double _width = 0;

  // The last layout, reused while the text and width stay the same.
  TextPainter? _painter;
  String? _painted;
  double _paintedWidth = 0;
  double _paintedScale = 0;

  @override
  void initState() {
    super.initState();
    widget.find.addListener(_onFind);
    // A view built after the match moved (a tab switch) still scrolls to it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _toCurrent(false));
  }

  @override
  void didUpdateWidget(FindScroll old) {
    super.didUpdateWidget(old);
    if (old.find != widget.find) {
      old.find.removeListener(_onFind);
      widget.find.addListener(_onFind);
    }
  }

  @override
  void dispose() {
    widget.find.removeListener(_onFind);
    _painter?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onFind() {
    if (widget.find.navStamp == _stamp) return;
    _toCurrent(true);
  }

  void _toCurrent(bool animate) {
    final find = widget.find;
    _stamp = find.navStamp;
    if (!mounted || !_scroll.hasClients) return;
    if (!find.isOpen || find.text != widget.text) return;
    final start = find.currentStart;
    if (start == null || _width <= 0) return;

    final scale = MediaQuery.textScalerOf(context);
    final scaleKey = scale.scale(14);
    if (_painter == null ||
        _painted != widget.text ||
        _paintedWidth != _width ||
        _paintedScale != scaleKey) {
      _painter?.dispose();
      _painter = TextPainter(
        text: TextSpan(text: widget.text, style: bodyMono),
        textDirection: TextDirection.ltr,
        textScaler: scale,
      )..layout(maxWidth: _width);
      _painted = widget.text;
      _paintedWidth = _width;
      _paintedScale = scaleKey;
    }
    final painter = _painter!;
    final at = painter.getOffsetForCaret(
      TextPosition(offset: start.clamp(0, widget.text.length)),
      Rect.zero,
    );
    final pos = _scroll.position;
    // Keep the match a third of the way down, so there is context above it.
    final target = (_padding + at.dy - pos.viewportDimension / 3).clamp(
      0.0,
      pos.maxScrollExtent,
    );
    final visibleTop = pos.pixels;
    final visibleBottom = pos.pixels + pos.viewportDimension;
    final y = _padding + at.dy;
    if (y >= visibleTop + 8 &&
        y + painter.preferredLineHeight <= visibleBottom - 8) {
      return; // already on screen
    }
    if (animate) {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    } else {
      _scroll.jumpTo(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        _width = c.maxWidth - _padding * 2;
        return SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.all(_padding),
          child: Align(alignment: Alignment.topLeft, child: widget.child),
        );
      },
    );
  }
}
