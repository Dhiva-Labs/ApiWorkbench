import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../../theme.dart';

/// Connection settings and composer of a Sse tab (issue #26).
class SseEditor extends StatelessWidget {
  const SseEditor({super.key, required this.tab});

  final RequestTab tab;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      'Sse requests are not available in this build.',
      style: TextStyle(color: Palette.textDim),
    ),
  );
}

/// Live message log of a Sse tab.
class SseMessages extends StatelessWidget {
  const SseMessages({super.key, required this.tab});

  final RequestTab tab;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
