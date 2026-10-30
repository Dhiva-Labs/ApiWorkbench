import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../../theme.dart';

/// Connection settings and composer of a WebSocket tab (issue #23).
class WebSocketEditor extends StatelessWidget {
  const WebSocketEditor({super.key, required this.tab});

  final RequestTab tab;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      'WebSocket requests are not available in this build.',
      style: TextStyle(color: Palette.textDim),
    ),
  );
}

/// Live message log of a WebSocket tab.
class WebSocketMessages extends StatelessWidget {
  const WebSocketMessages({super.key, required this.tab});

  final RequestTab tab;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
