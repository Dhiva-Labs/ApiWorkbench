import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../state/console_log.dart';
import '../theme.dart';

/// Network exchanges and script output, newest last (issue #13 adds
/// details, filters and search).
class ConsolePanel extends StatelessWidget {
  const ConsolePanel({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final log = context.read<AppState>().console;
    return ListenableBuilder(
      listenable: log,
      builder: (context, _) => Column(
        children: [
          Row(
            children: [
              const SizedBox(width: 12),
              Text(
                'Console',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                  color: Palette.textDim,
                ),
              ),
              const Spacer(),
              TextButton(onPressed: log.clear, child: const Text('Clear')),
              if (onClose != null)
                IconButton(
                  tooltip: 'Close console',
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: onClose,
                ),
            ],
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: log.entries.length,
              itemBuilder: (_, i) => Text(switch (log.entries[i]) {
                ExchangeEntry(:final record) =>
                  '${record.method} ${record.url}  ${record.error ?? record.status}  ${record.durationMs} ms',
                LineEntry(:final line) => '${line.level.name}: ${line.message}',
              }, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }
}

/// The console on its own page (phones).
Future<void> showConsolePage(BuildContext context) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Console')),
          body: const ConsolePanel(),
        ),
      ),
    );
