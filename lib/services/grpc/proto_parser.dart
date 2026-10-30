/// A .proto parser for proto3 and the proto2 basics, so services can be
/// called without protoc. Options are read where they change the wire
/// format (`packed`, `json_name`, `default`) and otherwise skipped;
/// `extend` blocks, `reserved` and `extensions` are skipped too.
library;

import 'descriptors.dart';

/// Parses one .proto file. [name] is the path it is imported by; it is
/// used in error messages and to match imports.
///
/// Throws [ProtoSchemaException] with the line and column of the problem.
ProtoFile parseProto(String text, {required String name}) =>
    _Parser(name, text).parse();

enum _Kind { identifier, integer, decimal, string, symbol, end }

class _Token {
  const _Token(this.kind, this.text, this.line, this.column, [this.value]);

  final _Kind kind;

  /// The source text (for strings, the decoded value is in [value]).
  final String text;
  final int line;
  final int column;
  final String? value;

  bool sym(String s) => kind == _Kind.symbol && text == s;
  bool word(String s) => kind == _Kind.identifier && text == s;

  String describe() => switch (kind) {
    _Kind.end => 'the end of the file',
    _Kind.string => 'the string "$value"',
    _ => '"$text"',
  };
}

List<_Token> _lex(String file, String src) {
  final tokens = <_Token>[];
  var i = 0;
  var line = 1;
  var lineStart = 0;
  Never fail(String msg, int at) =>
      throw ProtoSchemaException(file, line, at - lineStart + 1, msg);

  bool isIdentStart(int c) =>
      (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f;
  bool isDigit(int c) => c >= 0x30 && c <= 0x39;

  while (i < src.length) {
    final c = src.codeUnitAt(i);
    if (c == 0x0a) {
      i++;
      line++;
      lineStart = i;
      continue;
    }
    if (c == 0x20 || c == 0x09 || c == 0x0d || c == 0x0c || c == 0x0b) {
      i++;
      continue;
    }
    final col = i - lineStart + 1;
    if (src.startsWith('//', i)) {
      while (i < src.length && src.codeUnitAt(i) != 0x0a) {
        i++;
      }
      continue;
    }
    if (src.startsWith('/*', i)) {
      final start = i;
      final startLine = line;
      i += 2;
      while (i < src.length && !src.startsWith('*/', i)) {
        if (src.codeUnitAt(i) == 0x0a) {
          line++;
          lineStart = i + 1;
        }
        i++;
      }
      if (i >= src.length) {
        throw ProtoSchemaException(
          file,
          startLine,
          start - lineStart + 1,
          'This /* comment is never closed with */.',
        );
      }
      i += 2;
      continue;
    }
    if (isIdentStart(c)) {
      final start = i;
      while (i < src.length &&
          (isIdentStart(src.codeUnitAt(i)) || isDigit(src.codeUnitAt(i)))) {
        i++;
      }
      tokens.add(_Token(_Kind.identifier, src.substring(start, i), line, col));
      continue;
    }
    if (isDigit(c) ||
        (c == 0x2e && i + 1 < src.length && isDigit(src.codeUnitAt(i + 1)))) {
      final start = i;
      final hex = src.startsWith('0x', i) || src.startsWith('0X', i);
      if (hex) i += 2;
      while (i < src.length) {
        final d = src.codeUnitAt(i);
        final prev = src.codeUnitAt(i - 1);
        if (isDigit(d) || isIdentStart(d) || d == 0x2e) {
          i++;
        } else if (!hex && (d == 0x2b || d == 0x2d) && (prev | 0x20) == 0x65) {
          i++; // exponent sign: 1e-5
        } else {
          break;
        }
      }
      final text = src.substring(start, i);
      final isFloat =
          !hex && (text.contains('.') || text.contains(RegExp('[eE]')));
      final valid = isFloat
          ? double.tryParse(
                  text.endsWith('f')
                      ? text.substring(0, text.length - 1)
                      : text,
                ) !=
                null
          : BigInt.tryParse(
                  hex ? text.substring(2) : text,
                  radix: hex ? 16 : 10,
                ) !=
                null;
      if (!valid) fail('"$text" is not a valid number.', start);
      tokens.add(
        _Token(isFloat ? _Kind.decimal : _Kind.integer, text, line, col),
      );
      continue;
    }
    if (c == 0x22 || c == 0x27) {
      final start = i;
      final out = StringBuffer();
      i++;
      while (true) {
        if (i >= src.length || src.codeUnitAt(i) == 0x0a) {
          fail('This string is never closed.', start);
        }
        final ch = src.codeUnitAt(i);
        if (ch == c) {
          i++;
          break;
        }
        if (ch == 0x5c) {
          i++;
          if (i >= src.length) fail('This string is never closed.', start);
          final e = src[i];
          i++;
          switch (e) {
            case 'n':
              out.write('\n');
            case 't':
              out.write('\t');
            case 'r':
              out.write('\r');
            case 'a':
              out.write('\x07');
            case 'b':
              out.write('\b');
            case 'f':
              out.write('\f');
            case 'v':
              out.write('\v');
            case 'x' || 'X':
              final m = RegExp(r'[0-9a-fA-F]{1,2}').matchAsPrefix(src, i);
              if (m == null) fail('"\\x" needs hex digits.', i - 2);
              out.writeCharCode(int.parse(m.group(0)!, radix: 16));
              i = m.end;
            case 'u' || 'U':
              final n = e == 'u' ? 4 : 8;
              final m = RegExp('[0-9a-fA-F]{$n}').matchAsPrefix(src, i);
              if (m == null) fail('"\\$e" needs $n hex digits.', i - 2);
              out.writeCharCode(int.parse(m.group(0)!, radix: 16));
              i = m.end;
            default:
              if (isDigit(e.codeUnitAt(0))) {
                final m = RegExp('[0-7]{1,3}').matchAsPrefix(src, i - 1);
                if (m == null) fail('Invalid octal escape.', i - 2);
                out.writeCharCode(int.parse(m.group(0)!, radix: 8));
                i = m.end;
              } else {
                out.write(e); // \\ \' \" \?
              }
          }
          continue;
        }
        out.writeCharCode(ch);
        i++;
      }
      tokens.add(
        _Token(
          _Kind.string,
          src.substring(start, i),
          line,
          col,
          out.toString(),
        ),
      );
      continue;
    }
    const symbols = '{}[]()<>;,=.-+:/';
    if (symbols.contains(src[i])) {
      tokens.add(_Token(_Kind.symbol, src[i], line, col));
      i++;
      continue;
    }
    fail('Unexpected character "${src[i]}".', i);
  }
  tokens.add(_Token(_Kind.end, '', line, src.length - lineStart + 1));
  return tokens;
}

const _labels = {'optional', 'required', 'repeated'};

class _Parser {
  _Parser(this.fileName, String text) : _tokens = _lex(fileName, text);

  final String fileName;
  final List<_Token> _tokens;
  int _i = 0;
  late ProtoFile _file;

  _Token get _t => _tokens[_i];
  _Token _peek(int ahead) => _tokens[(_i + ahead).clamp(0, _tokens.length - 1)];
  _Token _next() {
    final t = _tokens[_i];
    if (_i < _tokens.length - 1) _i++;
    return t;
  }

  bool get _atEnd => _t.kind == _Kind.end;

  ProtoSchemaException _error(String msg, [_Token? at]) {
    final t = at ?? _t;
    return ProtoSchemaException(fileName, t.line, t.column, msg);
  }

  void _expect(String sym, String context) {
    if (!_t.sym(sym)) {
      throw _error('Expected "$sym" $context, found ${_t.describe()}.');
    }
    _next();
  }

  String _ident(String context) {
    if (_t.kind != _Kind.identifier) {
      throw _error('Expected $context, found ${_t.describe()}.');
    }
    return _next().text;
  }

  /// A dotted name, optionally with a leading dot: `.pkg.Type`.
  String _dotted(String context) {
    final out = StringBuffer();
    if (_t.sym('.')) {
      _next();
      out.write('.');
    }
    out.write(_ident(context));
    while (_t.sym('.')) {
      _next();
      out
        ..write('.')
        ..write(_ident(context));
    }
    return out.toString();
  }

  String _string(String context) {
    if (_t.kind != _Kind.string) {
      throw _error(
        'Expected $context (a quoted string), found ${_t.describe()}.',
      );
    }
    final out = StringBuffer(_next().value ?? '');
    while (_t.kind == _Kind.string) {
      out.write(_next().value); // adjacent literals concatenate
    }
    return out.toString();
  }

  ProtoFile parse() {
    _file = ProtoFile(name: fileName);
    var first = true;
    var sawPackage = false;
    while (!_atEnd) {
      final t = _t;
      if (t.sym(';')) {
        _next();
      } else if (t.word('syntax') && _peek(1).sym('=')) {
        if (!first) {
          throw _error('"syntax" must be the first statement of the file.');
        }
        _next();
        _next();
        final at = _t;
        final s = _string('the syntax');
        if (s != 'proto2' && s != 'proto3') {
          throw _error('Unknown syntax "$s". Use "proto2" or "proto3".', at);
        }
        _file.syntax = s;
        _expect(';', 'after the syntax statement');
      } else if (t.word('edition') && _peek(1).sym('=')) {
        _next();
        _next();
        _string('the edition');
        _file.syntax = 'editions';
        _expect(';', 'after the edition statement');
      } else if (t.word('package')) {
        if (sawPackage) throw _error('A file can only have one package.');
        sawPackage = true;
        _next();
        _file.package = _dotted('a package name');
        if (_file.package.startsWith('.')) {
          throw _error('A package name cannot start with a dot.', t);
        }
        _expect(';', 'after the package name');
      } else if (t.word('import')) {
        _next();
        if (_t.word('public') || _t.word('weak')) _next();
        final path = _string('the imported file');
        _file.dependencies.add(path);
        _file.importLines[path] = t.line;
        _expect(';', 'after the import');
      } else if (t.word('option')) {
        _option();
      } else if (t.word('message')) {
        _file.messages.add(_message(null));
      } else if (t.word('enum')) {
        _file.enums.add(_enum());
      } else if (t.word('service')) {
        _file.services.add(_service());
      } else if (t.word('extend')) {
        _skipBlock();
      } else {
        throw _error(
          'Expected a message, enum, service, import, package or option, '
          'found ${t.describe()}.',
        );
      }
      first = false;
    }
    _finish();
    return _file;
  }

  /// `option name = value;` (skipped).
  void _option() {
    _next();
    _optionName();
    _expect('=', 'after the option name');
    _constant();
    _expect(';', 'after the option');
  }

  String _optionName() {
    final out = StringBuffer();
    while (true) {
      if (_t.sym('(')) {
        _next();
        out.write('(${_dotted('an option name')})');
        _expect(')', 'after the custom option name');
      } else {
        out.write(_ident('an option name'));
      }
      if (!_t.sym('.')) break;
      _next();
      out.write('.');
    }
    return out.toString();
  }

  /// A constant: string, number, identifier, or a `{...}` aggregate
  /// (skipped, returns null). Returns the value as text.
  String? _constant() {
    final t = _t;
    switch (t.kind) {
      case _Kind.string:
        return _string('a value');
      case _Kind.integer || _Kind.decimal:
        return _next().text;
      case _Kind.identifier:
        return _dotted('a value');
      case _Kind.symbol when t.text == '-' || t.text == '+':
        _next();
        if (_t.kind == _Kind.integer ||
            _t.kind == _Kind.decimal ||
            _t.word('inf') ||
            _t.word('nan')) {
          final v = _next().text;
          return t.text == '-' ? '-$v' : v;
        }
        throw _error('Expected a number after "${t.text}".');
      case _Kind.symbol when t.text == '{':
        _skipBalanced('{', '}');
        return null;
      default:
        throw _error('Expected a value, found ${t.describe()}.');
    }
  }

  void _skipBalanced(String open, String close) {
    final start = _t;
    var depth = 0;
    do {
      if (_atEnd) {
        throw _error('This "$open" is never closed with "$close".', start);
      }
      final t = _next();
      if (t.sym(open)) depth++;
      if (t.sym(close)) depth--;
    } while (depth > 0);
  }

  /// Skips `extend X { ... }` or another named block.
  void _skipBlock() {
    while (!_t.sym('{')) {
      if (_atEnd || _t.sym(';')) {
        throw _error('Expected "{", found ${_t.describe()}.');
      }
      _next();
    }
    _skipBalanced('{', '}');
  }

  void _skipStatement() {
    while (!_t.sym(';')) {
      if (_atEnd) throw _error('Expected ";", found the end of the file.');
      _next();
    }
    _next();
  }

  bool _startsBlock(String keyword) =>
      _t.word(keyword) &&
      _peek(1).kind == _Kind.identifier &&
      _peek(2).sym('{');

  MessageDescriptor _message(MessageDescriptor? parent) {
    final start = _next(); // "message"
    final name = _ident('a message name');
    final m = MessageDescriptor(
      name: name,
      file: _file,
      parent: parent,
      line: start.line,
      column: start.column,
    );
    _expect('{', 'after "message $name"');
    _messageBody(m, start);
    return m;
  }

  void _messageBody(MessageDescriptor m, _Token start) {
    while (!_t.sym('}')) {
      if (_atEnd) {
        throw _error(
          'Message "${m.name}" (line ${start.line}) is never closed with "}".',
        );
      }
      if (_t.sym(';')) {
        _next();
      } else if (_startsBlock('message')) {
        m.messages.add(_message(m));
      } else if (_startsBlock('enum')) {
        m.enums.add(_enum());
      } else if (_t.word('option')) {
        _option();
      } else if (_startsBlock('oneof')) {
        _oneof(m);
      } else if (_t.word('map') && _peek(1).sym('<')) {
        _mapField(m, null);
      } else if (_t.word('reserved') || _t.word('extensions')) {
        _skipStatement();
      } else if (_t.word('extend')) {
        _skipBlock();
      } else {
        _field(m, null);
      }
    }
    _next();
  }

  int _fieldNumber(String field) {
    final t = _t;
    if (t.kind != _Kind.integer) {
      throw _error(
        'Expected the field number of "$field", found ${t.describe()}.',
      );
    }
    _next();
    final hex = t.text.startsWith('0x') || t.text.startsWith('0X');
    final n = BigInt.parse(
      hex ? t.text.substring(2) : t.text,
      radix: hex ? 16 : 10,
    );
    if (n < BigInt.one || n > BigInt.from(536870911)) {
      throw _error(
        'Field numbers must be between 1 and 536870911; "$field" has $n.',
        t,
      );
    }
    final v = n.toInt();
    if (v >= 19000 && v <= 19999) {
      throw _error(
        'Field numbers 19000 to 19999 are reserved by protobuf; "$field" '
        'uses $v.',
        t,
      );
    }
    return v;
  }

  /// `[name = value, ...]` after a field.
  void _fieldOptions(FieldDescriptor f) {
    _expect('[', 'before the field options');
    while (true) {
      final at = _t;
      final name = _optionName();
      _expect('=', 'after the option "$name"');
      final valueAt = _t;
      final value = _constant();
      switch (name) {
        case 'packed':
          if (value != 'true' && value != 'false') {
            throw _error('"packed" must be true or false.', valueAt);
          }
          f.packedOption = value == 'true';
        case 'json_name':
          if (valueAt.kind != _Kind.string) {
            throw _error('"json_name" must be a string.', valueAt);
          }
          f.jsonName = value!;
        case 'default':
          if (_file.isProto3) {
            throw _error(
              'Default values are not allowed in proto3; every field '
              'defaults to zero, empty or false.',
              at,
            );
          }
          f.defaultValue = value;
      }
      if (_t.sym(',')) {
        _next();
        continue;
      }
      _expect(']', 'to close the field options');
      break;
    }
  }

  void _field(MessageDescriptor m, OneofDescriptor? oneof) {
    final start = _t;
    var label = FieldLabel.optional;
    var explicitOptional = false;
    if (_t.kind == _Kind.identifier &&
        _labels.contains(_t.text) &&
        !_peek(1).sym('=')) {
      if (oneof != null) {
        throw _error('Fields in a oneof cannot have a label (${_t.text}).');
      }
      label = FieldLabel.values.byName(_t.text);
      explicitOptional = _t.text == 'optional';
      if (label == FieldLabel.required && _file.isProto3) {
        throw _error('Required fields are not allowed in proto3.');
      }
      _next();
    }
    // A group is `group Name = N {`; a field whose message type is called
    // "group" has no block after its number.
    if (_t.word('group') &&
        _peek(1).kind == _Kind.identifier &&
        _peek(2).sym('=') &&
        (_peek(4).sym('{') || _peek(4).sym('['))) {
      _group(m, oneof, label, start);
      return;
    }
    if (_t.word('map') && _peek(1).sym('<')) {
      throw _error('Map fields cannot have a label.', start);
    }
    final typeAt = _t;
    final typeText = _dotted('a field type');
    final name = _ident('the field name after "$typeText"');
    _expect('=', 'after the field name "$name"');
    final number = _fieldNumber(name);
    final scalar = FieldType.scalar(typeText);
    final f = FieldDescriptor(
      name: name,
      number: number,
      label: label,
      type: scalar ?? FieldType.message,
      typeName: scalar == null ? typeText : null,
      line: typeAt.line,
      column: typeAt.column,
    )..containingType = m;
    if (_t.sym('[')) _fieldOptions(f);
    _expect(';', 'after field "$name"');
    if (explicitOptional && _file.isProto3) f.proto3Optional = true;
    _addField(m, f, oneof);
  }

  void _addField(MessageDescriptor m, FieldDescriptor f, OneofDescriptor? o) {
    for (final other in m.fields) {
      if (other.number == f.number) {
        throw ProtoSchemaException(
          fileName,
          f.line,
          f.column,
          'Field number ${f.number} is already used by "${other.name}" in '
          'message "${m.name}".',
        );
      }
      if (other.name == f.name) {
        throw ProtoSchemaException(
          fileName,
          f.line,
          f.column,
          'Message "${m.name}" already has a field named "${f.name}".',
        );
      }
    }
    m.fields.add(f);
    if (o != null) {
      f.oneof = o;
      o.fields.add(f);
    }
  }

  /// proto2 `optional group Result = 1 { ... }`: a nested message and a
  /// field of it, named in lower case.
  void _group(
    MessageDescriptor m,
    OneofDescriptor? oneof,
    FieldLabel label,
    _Token start,
  ) {
    if (_file.isProto3) {
      throw _error('Groups are not supported in proto3; use a message.');
    }
    _next(); // "group"
    final nameAt = _t;
    final name = _ident('the group name');
    if (name[0] != name[0].toUpperCase()) {
      throw _error('Group names must start with a capital letter.', nameAt);
    }
    _expect('=', 'after the group name');
    final number = _fieldNumber(name);
    final nested = MessageDescriptor(
      name: name,
      file: _file,
      parent: m,
      line: nameAt.line,
      column: nameAt.column,
    );
    final f = FieldDescriptor(
      name: name.toLowerCase(),
      number: number,
      label: label,
      type: FieldType.group,
      typeName: name,
      line: start.line,
      column: start.column,
    )..containingType = m;
    if (_t.sym('[')) _fieldOptions(f);
    _expect('{', 'to open group "$name"');
    _messageBody(nested, nameAt);
    m.messages.add(nested);
    _addField(m, f, oneof);
  }

  void _mapField(MessageDescriptor m, OneofDescriptor? oneof) {
    final start = _next(); // "map"
    if (oneof != null) {
      throw _error('Map fields are not allowed in a oneof.', start);
    }
    _expect('<', 'after "map"');
    final keyAt = _t;
    final keyText = _dotted('the map key type');
    final key = FieldType.scalar(keyText);
    if (key == null || !key.isMapKey) {
      throw _error(
        'Invalid map key type "$keyText". Keys must be an integer type, bool '
        'or string.',
        keyAt,
      );
    }
    _expect(',', 'after the map key type');
    final valueText = _dotted('the map value type');
    _expect('>', 'after the map value type');
    final name = _ident('the field name of the map');
    _expect('=', 'after the field name "$name"');
    final number = _fieldNumber(name);
    final entryName = '${_capitalize(protoJsonName(name))}Entry';
    final entry = MessageDescriptor(
      name: entryName,
      file: _file,
      parent: m,
      line: start.line,
      column: start.column,
    )..mapEntry = true;
    final valueScalar = FieldType.scalar(valueText);
    entry.fields
      ..add(
        FieldDescriptor(name: 'key', number: 1, type: key)
          ..containingType = entry,
      )
      ..add(
        FieldDescriptor(
          name: 'value',
          number: 2,
          type: valueScalar ?? FieldType.message,
          typeName: valueScalar == null ? valueText : null,
          line: start.line,
          column: start.column,
        )..containingType = entry,
      );
    final f = FieldDescriptor(
      name: name,
      number: number,
      label: FieldLabel.repeated,
      type: FieldType.message,
      typeName: entryName,
      line: start.line,
      column: start.column,
    )..containingType = m;
    if (_t.sym('[')) _fieldOptions(f);
    _expect(';', 'after map field "$name"');
    m.messages.add(entry);
    _addField(m, f, null);
  }

  void _oneof(MessageDescriptor m) {
    final start = _next(); // "oneof"
    final o = OneofDescriptor(_ident('the oneof name'));
    m.oneofs.add(o);
    _expect('{', 'after "oneof ${o.name}"');
    while (!_t.sym('}')) {
      if (_atEnd) {
        throw _error(
          'Oneof "${o.name}" (line ${start.line}) is never closed with "}".',
        );
      }
      if (_t.sym(';')) {
        _next();
      } else if (_t.word('option')) {
        _option();
      } else if (_t.word('map') && _peek(1).sym('<')) {
        _mapField(m, o);
      } else {
        _field(m, o);
      }
    }
    _next();
    if (o.fields.isEmpty) {
      throw _error('Oneof "${o.name}" must have at least one field.', start);
    }
  }

  EnumDescriptor _enum() {
    final start = _next(); // "enum"
    final name = _ident('an enum name');
    final e = EnumDescriptor(
      name: name,
      file: _file,
      line: start.line,
      column: start.column,
    );
    _expect('{', 'after "enum $name"');
    while (!_t.sym('}')) {
      if (_atEnd) {
        throw _error(
          'Enum "$name" (line ${start.line}) is never closed with "}".',
        );
      }
      if (_t.sym(';')) {
        _next();
      } else if (_t.word('option')) {
        _option();
      } else if (_t.word('reserved')) {
        _skipStatement();
      } else {
        final at = _t;
        final valueName = _ident('an enum value name');
        _expect('=', 'after the enum value "$valueName"');
        var negative = false;
        if (_t.sym('-')) {
          negative = true;
          _next();
        }
        final numAt = _t;
        if (numAt.kind != _Kind.integer) {
          throw _error(
            'Expected the number of "$valueName", found ${numAt.describe()}.',
          );
        }
        _next();
        final hex = numAt.text.startsWith('0x') || numAt.text.startsWith('0X');
        var n = BigInt.parse(
          hex ? numAt.text.substring(2) : numAt.text,
          radix: hex ? 16 : 10,
        );
        if (negative) n = -n;
        if (n < BigInt.from(-2147483648) || n > BigInt.from(2147483647)) {
          throw _error(
            'Enum value $n of "$valueName" is out of the int32 range.',
            numAt,
          );
        }
        if (_t.sym('[')) _skipBalanced('[', ']');
        _expect(';', 'after the enum value "$valueName"');
        if (e.values.isEmpty && _file.isProto3 && n != BigInt.zero) {
          throw _error(
            'The first value of enum "$name" must be zero in proto3, as it '
            'is the default.',
            at,
          );
        }
        if (e.valueByName(valueName) != null) {
          throw _error('Enum "$name" already has a value "$valueName".', at);
        }
        e.values.add(EnumValueDescriptor(valueName, n.toInt()));
      }
    }
    _next();
    if (e.values.isEmpty) {
      throw _error('Enum "$name" must have at least one value.', start);
    }
    return e;
  }

  ServiceDescriptor _service() {
    final start = _next(); // "service"
    final name = _ident('a service name');
    final s = ServiceDescriptor(name: name, file: _file, line: start.line);
    _expect('{', 'after "service $name"');
    while (!_t.sym('}')) {
      if (_atEnd) {
        throw _error(
          'Service "$name" (line ${start.line}) is never closed with "}".',
        );
      }
      if (_t.sym(';')) {
        _next();
      } else if (_t.word('option')) {
        _option();
      } else if (_t.word('rpc')) {
        s.methods.add(_rpc(s));
      } else {
        throw _error(
          'Expected "rpc" or "option" in service "$name", found '
          '${_t.describe()}.',
        );
      }
    }
    _next();
    return s;
  }

  MethodDescriptor _rpc(ServiceDescriptor s) {
    final start = _next(); // "rpc"
    final name = _ident('the rpc name');
    if (s.method(name) != null) {
      throw _error('Service "${s.name}" already has an rpc "$name".', start);
    }
    (bool, String) part(String role) {
      _expect('(', 'before the $role type of rpc "$name"');
      var stream = false;
      if (_t.word('stream') && !_peek(1).sym(')') && !_peek(1).sym('.')) {
        stream = true;
        _next();
      }
      final type = _dotted('the $role message type');
      _expect(')', 'after the $role type of rpc "$name"');
      return (stream, type);
    }

    final (clientStreaming, input) = part('request');
    if (!_t.word('returns')) {
      throw _error(
        'Expected "returns" in rpc "$name", found ${_t.describe()}.',
      );
    }
    _next();
    final (serverStreaming, output) = part('response');
    if (_t.sym('{')) {
      _skipBalanced('{', '}');
    } else {
      _expect(';', 'after rpc "$name"');
    }
    return MethodDescriptor(
      name: name,
      inputTypeName: input,
      outputTypeName: output,
      clientStreaming: clientStreaming,
      serverStreaming: serverStreaming,
      line: start.line,
      column: start.column,
    );
  }

  /// Full names, synthetic oneofs of proto3 `optional` fields (after the
  /// real ones, as protoc orders them).
  void _finish() {
    final pkg = _file.package;
    String join(String scope, String name) =>
        scope.isEmpty ? name : '$scope.$name';

    void message(MessageDescriptor m, String scope) {
      m.fullName = join(scope, m.name);
      for (final f in m.fields) {
        if (f.proto3Optional) {
          final o = OneofDescriptor('_${f.name}', synthetic: true);
          f.oneof = o;
          o.fields.add(f);
          m.oneofs.add(o);
        }
      }
      for (final e in m.enums) {
        e.fullName = join(m.fullName, e.name);
      }
      for (final n in m.messages) {
        message(n, m.fullName);
      }
    }

    for (final m in _file.messages) {
      message(m, pkg);
    }
    for (final e in _file.enums) {
      e.fullName = join(pkg, e.name);
    }
    for (final s in _file.services) {
      s.fullName = join(pkg, s.name);
    }
  }
}

String _capitalize(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
