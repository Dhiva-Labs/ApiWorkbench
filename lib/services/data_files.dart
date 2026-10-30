import 'dart:convert';

/// Data files for data-driven runs: one row per iteration, every value a
/// string, available to requests as `{{column}}` and to scripts through
/// `pm.iterationData`. Shared by the collection runner and the CLI, so this
/// file must stay free of Flutter imports.

/// The two formats a data file can have.
enum DataFormat {
  csv,
  json;

  String get label => this == csv ? 'CSV' : 'JSON';
}

/// The rows of a data file, with the columns they came from.
class DataFile {
  DataFile(this.format, this.columns, this.rows);

  final DataFormat format;

  /// Column names in file order (JSON: first appearance across the rows).
  final List<String> columns;
  final List<Map<String, String>> rows;
}

/// Decodes the bytes of a data file: UTF-8 (with or without a byte-order
/// mark) or UTF-16 with a byte-order mark, as Excel saves "Unicode text".
/// The mark is dropped. Malformed UTF-8 is replaced instead of failing.
String decodeDataBytes(List<int> bytes) {
  if (bytes.length >= 2) {
    final le = bytes[0] == 0xFF && bytes[1] == 0xFE;
    final be = bytes[0] == 0xFE && bytes[1] == 0xFF;
    if (le || be) {
      final units = <int>[];
      for (var i = 2; i + 1 < bytes.length; i += 2) {
        units.add(
          le ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1],
        );
      }
      return String.fromCharCodes(units);
    }
  }
  final start =
      bytes.length >= 3 &&
          bytes[0] == 0xEF &&
          bytes[1] == 0xBB &&
          bytes[2] == 0xBF
      ? 3
      : 0;
  return utf8.decode(
    start == 0 ? bytes : bytes.sublist(start),
    allowMalformed: true,
  );
}

/// Parses [text] as a JSON array of objects or as CSV, whichever it is:
/// the file name's extension decides when it says so (`.csv`, `.tsv`,
/// `.json`), else the first character (`[` or `{` is JSON). Throws a
/// [FormatException] with a readable message for anything that is not a
/// data file or has no rows.
DataFile readDataFile(String text, {String? fileName}) {
  final body = _stripBom(text);
  if (body.trim().isEmpty) {
    throw const FormatException('The data file is empty.');
  }
  final name = (fileName ?? '').toLowerCase();
  final DataFile file;
  if (name.endsWith('.json')) {
    file = _readJson(body);
  } else if (name.endsWith('.csv')) {
    file = _readCsv(body, ',');
  } else if (name.endsWith('.tsv')) {
    file = _readCsv(body, '\t');
  } else {
    final first = body.trimLeft()[0];
    file = first == '[' || first == '{' ? _readJson(body) : _readCsv(body, ',');
  }
  if (file.rows.isEmpty) {
    throw FormatException(
      file.format == DataFormat.csv
          ? 'The CSV file has a header row but no data rows.'
          : 'The JSON data has no rows.',
    );
  }
  return file;
}

/// [readDataFile] without the column list.
List<Map<String, String>> parseDataFile(String text, {String? fileName}) =>
    readDataFile(text, fileName: fileName).rows;

/// Parses CSV text (RFC 4180) into one map per data row, keyed by the
/// header row. A header-only file gives no rows. [delimiter] is one
/// character; `\t` reads TSV.
///
/// Beyond the RFC: a byte-order mark, LF or CR line endings, and blank lines
/// are ignored; a row shorter than the header is padded with empty values;
/// columns with an empty header are dropped. A repeated header, a row with
/// more values than the header, an unterminated quote or text right after a
/// closing quote throw a [FormatException] naming the line.
List<Map<String, String>> parseCsv(String text, {String delimiter = ','}) =>
    _readCsv(_stripBom(text), delimiter).rows;

/// Parses a JSON array of flat objects, `[{"id": 1, "name": "a"}]`, into
/// rows of strings. A single object is one row. Numbers and booleans become
/// their JSON text, `null` an empty string, and nested values JSON text.
List<Map<String, String>> parseJsonRows(String text) =>
    _readJson(_stripBom(text)).rows;

String _stripBom(String s) => s.startsWith('﻿') ? s.substring(1) : s;

// ---- JSON ------------------------------------------------------------------

DataFile _readJson(String text) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (e) {
    throw FormatException('The data is not valid JSON: ${e.message}');
  }
  final items = decoded is List
      ? decoded
      : decoded is Map
      ? [decoded]
      : throw const FormatException(
          'JSON data must be an array of objects, '
          'like [{"userId": "1"}, {"userId": "2"}].',
        );
  final columns = <String>[];
  final seen = <String>{};
  final rows = <Map<String, String>>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item is! Map) {
      throw FormatException(
        'Item ${i + 1} of the JSON array is not an object. Each item is one '
        'iteration, like {"userId": "1"}.',
      );
    }
    final row = <String, String>{};
    for (final e in item.entries) {
      final key = e.key.toString();
      if (seen.add(key)) columns.add(key);
      row[key] = _plain(e.value);
    }
    rows.add(row);
  }
  return DataFile(DataFormat.json, columns, rows);
}

String _plain(Object? v) => v is String
    ? v
    : v == null
    ? ''
    : jsonEncode(v);

// ---- CSV -------------------------------------------------------------------

DataFile _readCsv(String text, String delimiter) {
  if (delimiter.length != 1) {
    throw ArgumentError.value(delimiter, 'delimiter', 'must be one character');
  }
  final records = _csvRecords(text, delimiter.codeUnitAt(0));
  if (records.isEmpty) {
    throw const FormatException('The CSV file is empty.');
  }

  final header = records.first;
  final names = [for (final h in header.fields) h.trim()];
  final firstAt = <String, int>{};
  for (var i = 0; i < names.length; i++) {
    final n = names[i];
    if (n.isEmpty) continue;
    final earlier = firstAt[n];
    if (earlier != null) {
      throw FormatException(
        'The CSV header repeats the column "$n" (columns ${earlier + 1} and '
        '${i + 1}). Column names must be unique.',
      );
    }
    firstAt[n] = i;
  }
  final columns = [
    for (final n in names)
      if (n.isNotEmpty) n,
  ];

  final rows = <Map<String, String>>[];
  for (final rec in records.skip(1)) {
    final f = rec.fields;
    if (f.length > names.length &&
        f.skip(names.length).any((v) => v.isNotEmpty)) {
      throw FormatException(
        'Line ${rec.line} has ${f.length} values but the header has '
        '${names.length} columns. Quote values that contain commas.',
      );
    }
    rows.add({
      for (var i = 0; i < names.length; i++)
        if (names[i].isNotEmpty) names[i]: i < f.length ? f[i] : '',
    });
  }
  return DataFile(DataFormat.csv, columns, rows);
}

class _Record {
  _Record(this.line, this.fields);

  /// Line the record starts on (1-based), for messages.
  final int line;
  final List<String> fields;
}

enum _State { fieldStart, unquoted, quoted, afterQuote }

/// The records of [text], blank lines left out. Not split by lines, because
/// quoted fields may hold line breaks.
List<_Record> _csvRecords(String text, int delim) {
  const quote = 0x22, lf = 0x0A, cr = 0x0D;
  final records = <_Record>[];
  var fields = <String>[];
  final field = StringBuffer();
  var state = _State.fieldStart;
  var line = 1;
  var recordLine = 1;
  var quotedAtLine = 1;
  var wasQuoted = false;

  void endField() {
    fields.add(field.toString());
    field.clear();
    state = _State.fieldStart;
  }

  void endRecord() {
    endField();
    // An empty line is one empty, unquoted field: not a record.
    final blank = fields.length == 1 && fields[0].isEmpty && !wasQuoted;
    if (!blank) records.add(_Record(recordLine, fields));
    fields = <String>[];
    wasQuoted = false;
    line++;
    recordLine = line;
  }

  final n = text.length;
  for (var i = 0; i < n; i++) {
    final c = text.codeUnitAt(i);
    switch (state) {
      case _State.quoted:
        if (c == quote) {
          if (i + 1 < n && text.codeUnitAt(i + 1) == quote) {
            field.writeCharCode(quote); // "" is a literal quote
            i++;
          } else {
            state = _State.afterQuote;
          }
        } else {
          if (c == lf) line++;
          field.writeCharCode(c);
        }
      case _State.afterQuote:
        if (c == delim) {
          endField();
        } else if (c == lf) {
          endRecord();
        } else if (c == cr) {
          if (i + 1 < n && text.codeUnitAt(i + 1) == lf) i++;
          endRecord();
        } else {
          throw FormatException(
            'Line $line: unexpected text after the closing quote of a value. '
            'Write a quote inside a quoted value as "".',
          );
        }
      case _State.fieldStart || _State.unquoted:
        if (c == quote && state == _State.fieldStart) {
          state = _State.quoted;
          wasQuoted = true;
          quotedAtLine = line;
        } else if (c == delim) {
          endField();
        } else if (c == lf) {
          endRecord();
        } else if (c == cr) {
          if (i + 1 < n && text.codeUnitAt(i + 1) == lf) i++;
          endRecord();
        } else {
          field.writeCharCode(c);
          state = _State.unquoted;
        }
    }
  }
  if (state == _State.quoted) {
    throw FormatException(
      'Line $quotedAtLine: a quoted value is never closed. Add the closing '
      'quote, or write a literal quote as "".',
    );
  }
  // A file without a final line break still ends its last record.
  if (state != _State.fieldStart || fields.isNotEmpty) endRecord();
  return records;
}
