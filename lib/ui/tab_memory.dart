import 'package:flutter/material.dart';

/// Remembers the selected tab of the enclosing [DefaultTabController] in
/// [memory] under [owner], so a rebuilt view can start where the user left
/// it: pass `memory[owner] ?? 0` as the controller's `initialIndex`.
///
/// Used for views that are recreated while their subject stays the same,
/// such as a request tab's editor (recreated when switching tabs, or
/// between Request and Response on phones) and its response (recreated for
/// every new response).
class TabMemory extends StatefulWidget {
  const TabMemory({
    super.key,
    required this.owner,
    required this.memory,
    required this.child,
  });

  final Object owner;
  final Expando<int> memory;
  final Widget child;

  /// The remembered index for [owner], clamped to [length] tabs.
  static int initialIndex(Expando<int> memory, Object owner, int length) =>
      (memory[owner] ?? 0).clamp(0, length - 1);

  @override
  State<TabMemory> createState() => _TabMemoryState();
}

class _TabMemoryState extends State<TabMemory> {
  TabController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = DefaultTabController.of(context);
    if (c == _controller) return;
    _controller?.removeListener(_save);
    _controller = c..addListener(_save);
  }

  void _save() => widget.memory[widget.owner] = _controller!.index;

  @override
  void dispose() {
    _controller?.removeListener(_save);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
