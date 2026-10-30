import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme.dart';

/// Cookies set by the response (issue #12 adds attributes and the jar's
/// cookies for the URL).
class ResponseCookies extends StatelessWidget {
  const ResponseCookies({super.key, required this.response});

  final ResponseData response;

  @override
  Widget build(BuildContext context) {
    final raw = [
      for (final e in response.headers.entries)
        if (e.key.toLowerCase() == 'set-cookie') ...e.value,
    ];
    if (raw.isEmpty) {
      return Center(
        child: Text(
          'This response set no cookies.',
          style: TextStyle(color: Palette.textDim),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        for (final c in raw)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SelectableText(
              c,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
            ),
          ),
      ],
    );
  }
}
