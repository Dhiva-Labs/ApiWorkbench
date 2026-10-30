import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../../theme.dart';

/// Connection settings and composer of a Grpc tab (issue #27).
class GrpcEditor extends StatelessWidget {
  const GrpcEditor({super.key, required this.tab});

  final RequestTab tab;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      'Grpc requests are not available in this build.',
      style: TextStyle(color: Palette.textDim),
    ),
  );
}

/// Live message log of a Grpc tab.
class GrpcMessages extends StatelessWidget {
  const GrpcMessages({super.key, required this.tab});

  final RequestTab tab;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
