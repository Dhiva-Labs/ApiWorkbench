import 'package:flutter/material.dart';

import '../../theme.dart';
import '../help_tip.dart';
import 'body_tools.dart' show formatByteSize;

/// A hex view never shows more than this many bytes, to stay cheap.
const hexViewLimit = 1024 * 1024;

/// Digits in the offset column: enough for [hexViewLimit] (0x100000).
const _offsetDigits = 6;

/// One line of a hex dump: the offset, the bytes in hex and their ASCII.
class HexRow {
  const HexRow(this.offset, this.hex, this.ascii);

  /// Zero-padded hexadecimal offset of the first byte.
  final String offset;

  /// Space-separated bytes, padded to a full row so columns line up.
  final String hex;

  /// Printable ASCII for each byte, `.` for the rest.
  final String ascii;

  @override
  String toString() => '$offset  $hex  $ascii';
}

/// Formats the [perRow] bytes of [bytes] starting at [offset]. A row of 16
/// gets an extra gap after the eighth byte, as `xxd` does.
HexRow formatHexRow(List<int> bytes, int offset, int perRow) {
  final end = offset + perRow < bytes.length ? offset + perRow : bytes.length;
  final hex = StringBuffer();
  final ascii = StringBuffer();
  for (var i = 0; i < perRow; i++) {
    if (i > 0) {
      hex.write(' ');
      if (perRow == 16 && i == 8) hex.write(' ');
    }
    if (offset + i < end) {
      final b = bytes[offset + i];
      hex.write(b.toRadixString(16).padLeft(2, '0'));
      ascii.write(b >= 0x20 && b < 0x7f ? String.fromCharCode(b) : '.');
    } else {
      hex.write('  ');
    }
  }
  return HexRow(
    offset.toRadixString(16).padLeft(_offsetDigits, '0'),
    hex.toString(),
    ascii.toString(),
  );
}

/// Characters in a rendered row of [perRow] bytes, used to pick a row size
/// that fits the pane.
int hexRowChars(int perRow) =>
    _offsetDigits + 2 + (perRow * 3 - 1) + (perRow == 16 ? 1 : 0) + 2 + perRow;

/// A virtualized hex dump of [bytes] with offset, hex and ASCII columns.
/// Only the first [hexViewLimit] bytes are shown. The row size follows the
/// pane width: 16 bytes on wide panes, down to 2 on a 320 px phone.
class HexView extends StatelessWidget {
  const HexView({super.key, required this.bytes});

  final List<int> bytes;

  static const _fontSize = 12.0;
  static const _rowHeight = 18.0;
  static const _pad = 14.0;

  @override
  Widget build(BuildContext context) {
    final shown = bytes.length < hexViewLimit ? bytes.length : hexViewLimit;
    final mono = TextStyle(
      fontFamily: 'monospace',
      fontSize: _fontSize,
      height: 1.4,
      color: Palette.text,
    );
    final scaler = MediaQuery.textScalerOf(context);
    final painter = TextPainter(
      text: TextSpan(text: 'MMMMMMMMMM', style: mono),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final charWidth = painter.width / 10;
    painter.dispose();
    final rowHeight = _rowHeight * scaler.scale(1);

    return LayoutBuilder(
      builder: (context, c) {
        final fit = ((c.maxWidth - _pad * 2) / charWidth).floor();
        final perRow = [
          16,
          8,
          4,
        ].firstWhere((n) => hexRowChars(n) <= fit, orElse: () => 2);
        final rows = (shown + perRow - 1) ~/ perRow;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (bytes.length > hexViewLimit)
              Padding(
                padding: const EdgeInsets.fromLTRB(_pad, 0, _pad, 6),
                child: Text(
                  'Showing the first ${formatByteSize(hexViewLimit)} of '
                  '${formatByteSize(bytes.length)}. Save the response to a '
                  'file to see the rest.',
                  style: TextStyle(color: Palette.warning, fontSize: 12),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: _pad),
              child: _header(mono, perRow),
            ),
            Divider(height: 8, color: Palette.border),
            Expanded(
              child: SelectionArea(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: _pad),
                  itemCount: rows,
                  itemExtent: rowHeight,
                  itemBuilder: (_, i) {
                    final r = formatHexRow(bytes, i * perRow, perRow);
                    return Text.rich(
                      TextSpan(
                        style: mono,
                        children: [
                          TextSpan(
                            text: r.offset,
                            style: TextStyle(color: Palette.textDim),
                          ),
                          TextSpan(text: '  ${r.hex}  '),
                          TextSpan(
                            text: r.ascii,
                            style: TextStyle(color: Palette.post),
                          ),
                        ],
                      ),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _header(TextStyle mono, int perRow) {
    final cols = [
      for (var i = 0; i < perRow; i++)
        i.toRadixString(16).padLeft(2, '0') +
            (perRow == 16 && i == 7 ? ' ' : ''),
    ].join(' ');
    return HelpHover(
      'Each row shows where it starts in the body (offset, in hex), the '
      'bytes in hex, and the same bytes as text. Bytes that are not '
      'printable show as a dot.',
      title: 'Hex view',
      example: '000000  48 54 54 50  HTTP',
      child: Text(
        '${'offset'.padRight(_offsetDigits)}  $cols  text',
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
        style: mono.copyWith(color: Palette.textDim),
      ),
    );
  }
}
