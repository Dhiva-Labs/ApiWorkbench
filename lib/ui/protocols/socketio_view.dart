import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../../theme.dart';

/// Connection settings and composer of a SocketIo tab (issue #24).
class SocketIoEditor extends StatelessWidget {
  const SocketIoEditor({super.key, required this.tab});

  final RequestTab tab;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      'SocketIo requests are not available in this build.',
      style: TextStyle(color: Palette.textDim),
    ),
  );
}

/// Live message log of a SocketIo tab.
class SocketIoMessages extends StatelessWidget {
  const SocketIoMessages({super.key, required this.tab});

  final RequestTab tab;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
