import 'dart:math' as math;

/// Looks up a `$ref` target, e.g. `#/components/schemas/Pet`. Returns the
/// referenced schema or null when it cannot be found.
typedef SchemaResolver = Object? Function(String ref);

/// Builds example values from JSON Schema (OpenAPI 3.0/3.1 and Swagger 2.0
/// dialects), the way API documentation tools show "example value".
///
/// Order of preference for any schema: `example`, the first of `examples`,
/// `const`, `default`, the first `enum` value, then a value made from `type`
/// and `format`. Objects are built from `properties` (and `allOf`), arrays get
/// one item, `oneOf`/`anyOf` use their first alternative, and `nullable` never
/// produces null. A `$ref` that is already being expanded (a circular schema)
/// or nesting deeper than [maxDepth] is left out, so the result is always
/// finite and small even for a wide, deeply shared schema (at most
/// [maxNodes] schemas are visited per sample).
class SchemaSampler {
  SchemaSampler({
    this.resolve,
    this.maxDepth = 6,
    this.forRequest,
    this.maxNodes = 2000,
  });

  /// Follows `$ref`; without it references are ignored.
  final SchemaResolver? resolve;

  /// How many object/array levels are expanded.
  final int maxDepth;

  /// How many schemas one [sample] call may visit before it stops expanding.
  final int maxNodes;

  /// True builds a request body (properties marked `readOnly` are left out),
  /// false a response (`writeOnly` ones are left out), null keeps all.
  final bool? forRequest;

  /// A sample for [schema], or null when it has no usable shape.
  Object? sample(Object? schema) {
    _left = maxNodes;
    final v = _sample(schema, 0, const []);
    return identical(v, _cut) ? null : v;
  }

  /// Marks a branch that was cut off (cycle, depth, read-only filtering), so
  /// containers can leave it out instead of writing a misleading null.
  static final Object _cut = Object();

  int _left = 0;

  Object? _sample(Object? node, int depth, List<String> refs) {
    if (node == true) return <String, dynamic>{};
    if (node is! Map) return null;
    if (--_left < 0) return _cut;
    final s = node;

    final ref = s[r'$ref'];
    if (ref is String) {
      if (refs.contains(ref)) return _cut;
      final target = resolve?.call(ref);
      if (target is! Map) return null;
      // Siblings of a $ref (OpenAPI 3.1) refine the target. Going through
      // _sample again follows a target that is itself a $ref.
      return _sample(
        {
          ...target,
          for (final e in s.entries)
            if (e.key != r'$ref') e.key: e.value,
        },
        depth,
        [...refs, ref],
      );
    }

    if (forRequest == true && s['readOnly'] == true) return _cut;
    if (forRequest == false && s['writeOnly'] == true) return _cut;

    if (s.containsKey('example')) return s['example'];
    final examples = s['examples'];
    if (examples is List && examples.isNotEmpty) return examples.first;
    if (s.containsKey('const')) return s['const'];
    if (s.containsKey('default') && s['default'] != null) return s['default'];
    final values = s['enum'];
    if (values is List && values.isNotEmpty) {
      for (final v in values) {
        if (v != null) return v;
      }
      return null;
    }

    if (depth > maxDepth) return _cut;

    final allOf = s['allOf'];
    if (allOf is List && allOf.isNotEmpty) {
      return _merge([
        for (final part in allOf) _sample(part, depth, refs),
        if (s['properties'] is Map) _object(s, depth, refs),
      ]);
    }
    for (final key in const ['oneOf', 'anyOf']) {
      final options = s[key];
      if (options is List && options.isNotEmpty) {
        // The first alternative that is not just "null".
        var pick = options.first;
        for (final o in options) {
          if (!(o is Map && o['type'] == 'null')) {
            pick = o;
            break;
          }
        }
        final v = _sample(pick, depth, refs);
        // Properties next to the alternatives apply to all of them.
        if (v is Map && s['properties'] is Map) {
          return _merge([_object(s, depth, refs), v]);
        }
        return v;
      }
    }

    var type = s['type'];
    if (type is List) {
      type = type.where((t) => t != 'null').firstOrNull ?? 'null';
    }
    type ??= _inferType(s);

    switch (type) {
      case 'string':
        return _string(s);
      case 'integer':
        return _number(s, integer: true);
      case 'number':
        return _number(s, integer: false);
      case 'boolean':
        return true;
      case 'array':
        return _array(s, depth, refs);
      case 'object':
        return _object(s, depth, refs);
      case 'file':
        return '';
      default:
        return null;
    }
  }

  static String? _inferType(Map s) {
    if (s.containsKey('properties') ||
        s.containsKey('additionalProperties') ||
        s.containsKey('required')) {
      return 'object';
    }
    if (s.containsKey('items')) return 'array';
    if (s.containsKey('format') ||
        s.containsKey('pattern') ||
        s.containsKey('minLength') ||
        s.containsKey('maxLength')) {
      return 'string';
    }
    if (s.containsKey('minimum') || s.containsKey('maximum')) return 'number';
    return null;
  }

  Object? _merge(List<Object?> parts) {
    final live = parts.where((p) => p != null && !identical(p, _cut)).toList();
    if (live.isEmpty) return null;
    if (live.every((p) => p is Map)) {
      return <String, dynamic>{
        for (final p in live) ...(p as Map).cast<String, dynamic>(),
      };
    }
    return live.first;
  }

  Object? _object(Map s, int depth, List<String> refs) {
    final out = <String, dynamic>{};
    final props = s['properties'];
    if (props is Map) {
      props.forEach((k, v) {
        final value = _sample(v, depth + 1, refs);
        if (!identical(value, _cut)) out['$k'] = value;
      });
    }
    final extra = s['additionalProperties'];
    if (out.isEmpty && extra is Map) {
      final value = _sample(extra, depth + 1, refs);
      if (!identical(value, _cut)) out['additionalProp1'] = value;
    }
    return out;
  }

  Object? _array(Map s, int depth, List<String> refs) {
    final max = (s['maxItems'] as num?)?.toInt();
    if (max == 0) return <Object?>[];
    final item = _sample(s['items'], depth + 1, refs);
    if (item == null || identical(item, _cut)) return <Object?>[];
    final min = (s['minItems'] as num?)?.toInt() ?? 1;
    // One item is the clearest example; more only when the schema insists.
    final count = math.min(math.max(min, 1), math.min(max ?? 3, 3));
    return List<Object?>.filled(count, item);
  }

  static Object _string(Map s) {
    final format = '${s['format'] ?? ''}';
    switch (format) {
      case 'date-time':
        return '2024-01-15T10:30:00Z';
      case 'date':
        return '2024-01-15';
      case 'time':
        return '10:30:00';
      case 'duration':
        return 'P3D';
      case 'email' || 'idn-email':
        return 'user@example.com';
      case 'uuid':
        return '3fa85f64-5717-4562-b3fc-2c963f66afa6';
      case 'uri' || 'url' || 'iri':
        return 'https://example.com';
      case 'uri-reference':
        return '/path';
      case 'hostname' || 'idn-hostname':
        return 'example.com';
      case 'ipv4':
        return '192.0.2.1';
      case 'ipv6':
        return '2001:db8::1';
      case 'byte':
        return 'c3RyaW5n'; // base64 of "string"
      case 'binary':
        return '';
      case 'password':
        return 'password';
      case 'json-pointer':
        return '/path/to/value';
    }
    var v = 'string';
    final min = (s['minLength'] as num?)?.toInt();
    final max = (s['maxLength'] as num?)?.toInt();
    if (min != null && v.length < min) {
      v = List.filled((min / v.length).ceil(), v).join().substring(0, min);
    }
    if (max != null && max >= 0 && v.length > max) v = v.substring(0, max);
    return v;
  }

  static num _number(Map s, {required bool integer}) {
    num v = integer ? 0 : 0.0;
    final min = s['minimum'] as num?;
    final max = s['maximum'] as num?;
    // 3.0 uses booleans next to minimum/maximum, 3.1 uses numbers.
    final exMin = s['exclusiveMinimum'];
    final exMax = s['exclusiveMaximum'];
    final step = integer ? 1 : 0.5;
    if (exMin is num) {
      v = exMin + step;
    } else if (min != null) {
      v = exMin == true ? min + step : min;
    }
    if (exMax is num) {
      if (v >= exMax) v = exMax - step;
    } else if (max != null && v > max) {
      v = exMax == true ? max - step : max;
    }
    final multiple = s['multipleOf'];
    if (multiple is num && multiple > 0) {
      v = (v / multiple).ceil() * multiple;
    }
    return integer ? v.toInt() : v.toDouble();
  }
}

/// One-shot form of [SchemaSampler.sample].
Object? sampleFromSchema(
  Object? schema, {
  SchemaResolver? resolve,
  int maxDepth = 6,
  bool? forRequest,
  int maxNodes = 2000,
}) => SchemaSampler(
  resolve: resolve,
  maxDepth: maxDepth,
  forRequest: forRequest,
  maxNodes: maxNodes,
).sample(schema);
