import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme.dart';

/// Proxy, CA certificate and client certificate settings, edited in place
/// on [network] (issues #14 and #15).
class NetworkSettingsSection extends StatelessWidget {
  const NetworkSettingsSection({
    super.key,
    required this.network,
    required this.onChanged,
  });

  final NetworkSettings network;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => Text(
    'Proxy and certificate settings are not available in this build.',
    style: TextStyle(fontSize: 12, color: Palette.textDim),
  );
}
