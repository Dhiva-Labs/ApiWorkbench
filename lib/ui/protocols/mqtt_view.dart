import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../../theme.dart';

/// Connection settings and composer of a Mqtt tab (issue #25).
class MqttEditor extends StatelessWidget {
  const MqttEditor({super.key, required this.tab});

  final RequestTab tab;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      'Mqtt requests are not available in this build.',
      style: TextStyle(color: Palette.textDim),
    ),
  );
}

/// Live message log of a Mqtt tab.
class MqttMessages extends StatelessWidget {
  const MqttMessages({super.key, required this.tab});

  final RequestTab tab;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
