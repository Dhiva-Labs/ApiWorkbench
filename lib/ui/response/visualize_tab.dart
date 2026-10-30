import 'package:flutter/material.dart';

import '../../services/scripting/script_engine.dart';

/// Shows `pm.visualizer.set` output (issue #10 renders the HTML).
class VisualizeView extends StatelessWidget {
  const VisualizeView({super.key, required this.output});

  final VisualizerOutput output;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(14),
    child: SelectableText(
      output.html,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
    ),
  );
}
