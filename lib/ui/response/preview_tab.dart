import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme.dart';

/// Renders the response body: images now; HTML, SVG, PDF and a hex view
/// come with issue #19.
class ResponsePreview extends StatelessWidget {
  const ResponsePreview({super.key, required this.response});

  final ResponseData response;

  @override
  Widget build(BuildContext context) {
    final ct = (response.contentType ?? '').toLowerCase();
    if (ct.startsWith('image/') && !ct.contains('svg')) {
      return InteractiveViewer(
        child: Center(
          child: Image.memory(
            Uint8List.fromList(response.bodyBytes),
            errorBuilder: (_, _, _) => _note('The image could not be decoded.'),
          ),
        ),
      );
    }
    return _note('No preview for ${ct.isEmpty ? 'this response' : ct}.');
  }

  Widget _note(String text) => Center(
    child: Text(text, style: TextStyle(color: Palette.textDim)),
  );
}
