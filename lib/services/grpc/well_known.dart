/// Built-in .proto files: the well-known types, the parts of
/// `descriptor.proto` that server reflection returns, and the reflection
/// service itself. They satisfy imports such as
/// `import "google/protobuf/timestamp.proto";` without the file on disk.
library;

import 'descriptors.dart';
import 'proto_parser.dart';

const _any = '''
syntax = "proto3";
package google.protobuf;
message Any {
  string type_url = 1;
  bytes value = 2;
}
''';

const _duration = '''
syntax = "proto3";
package google.protobuf;
message Duration {
  int64 seconds = 1;
  int32 nanos = 2;
}
''';

const _empty = '''
syntax = "proto3";
package google.protobuf;
message Empty {}
''';

const _fieldMask = '''
syntax = "proto3";
package google.protobuf;
message FieldMask {
  repeated string paths = 1;
}
''';

const _struct = '''
syntax = "proto3";
package google.protobuf;
message Struct {
  map<string, Value> fields = 1;
}
message Value {
  oneof kind {
    NullValue null_value = 1;
    double number_value = 2;
    string string_value = 3;
    bool bool_value = 4;
    Struct struct_value = 5;
    ListValue list_value = 6;
  }
}
enum NullValue {
  NULL_VALUE = 0;
}
message ListValue {
  repeated Value values = 1;
}
''';

const _timestamp = '''
syntax = "proto3";
package google.protobuf;
message Timestamp {
  int64 seconds = 1;
  int32 nanos = 2;
}
''';

const _wrappers = '''
syntax = "proto3";
package google.protobuf;
message DoubleValue { double value = 1; }
message FloatValue { float value = 1; }
message Int64Value { int64 value = 1; }
message UInt64Value { uint64 value = 1; }
message Int32Value { int32 value = 1; }
message UInt32Value { uint32 value = 1; }
message BoolValue { bool value = 1; }
message StringValue { string value = 1; }
message BytesValue { bytes value = 1; }
''';

/// The fields of `descriptor.proto` a client needs to rebuild a schema from
/// reflection. Unlisted fields (most options, source info) are skipped as
/// unknown fields when decoding.
const _descriptor = '''
syntax = "proto2";
package google.protobuf;

message FileDescriptorSet {
  repeated FileDescriptorProto file = 1;
}

message FileDescriptorProto {
  optional string name = 1;
  optional string package = 2;
  repeated string dependency = 3;
  repeated int32 public_dependency = 10;
  repeated int32 weak_dependency = 11;
  repeated DescriptorProto message_type = 4;
  repeated EnumDescriptorProto enum_type = 5;
  repeated ServiceDescriptorProto service = 6;
  repeated FieldDescriptorProto extension = 7;
  optional FileOptions options = 8;
  optional string syntax = 12;
  optional int32 edition = 14;
}

message DescriptorProto {
  optional string name = 1;
  repeated FieldDescriptorProto field = 2;
  repeated FieldDescriptorProto extension = 6;
  repeated DescriptorProto nested_type = 3;
  repeated EnumDescriptorProto enum_type = 4;
  repeated OneofDescriptorProto oneof_decl = 8;
  optional MessageOptions options = 7;
}

message FieldDescriptorProto {
  enum Type {
    TYPE_DOUBLE = 1;
    TYPE_FLOAT = 2;
    TYPE_INT64 = 3;
    TYPE_UINT64 = 4;
    TYPE_INT32 = 5;
    TYPE_FIXED64 = 6;
    TYPE_FIXED32 = 7;
    TYPE_BOOL = 8;
    TYPE_STRING = 9;
    TYPE_GROUP = 10;
    TYPE_MESSAGE = 11;
    TYPE_BYTES = 12;
    TYPE_UINT32 = 13;
    TYPE_ENUM = 14;
    TYPE_SFIXED32 = 15;
    TYPE_SFIXED64 = 16;
    TYPE_SINT32 = 17;
    TYPE_SINT64 = 18;
  }
  enum Label {
    LABEL_OPTIONAL = 1;
    LABEL_REQUIRED = 2;
    LABEL_REPEATED = 3;
  }
  optional string name = 1;
  optional int32 number = 3;
  optional Label label = 4;
  optional Type type = 5;
  optional string type_name = 6;
  optional string extendee = 2;
  optional string default_value = 7;
  optional int32 oneof_index = 9;
  optional string json_name = 10;
  optional FieldOptions options = 8;
  optional bool proto3_optional = 17;
}

message OneofDescriptorProto {
  optional string name = 1;
}

message EnumDescriptorProto {
  optional string name = 1;
  repeated EnumValueDescriptorProto value = 2;
}

message EnumValueDescriptorProto {
  optional string name = 1;
  optional int32 number = 2;
}

message ServiceDescriptorProto {
  optional string name = 1;
  repeated MethodDescriptorProto method = 2;
}

message MethodDescriptorProto {
  optional string name = 1;
  optional string input_type = 2;
  optional string output_type = 3;
  optional bool client_streaming = 5;
  optional bool server_streaming = 6;
}

message FileOptions {
  optional string java_package = 1;
  optional string go_package = 11;
}

message MessageOptions {
  optional bool map_entry = 7;
}

message FieldOptions {
  optional bool packed = 2;
}
''';

String _reflection(String version) =>
    '''
syntax = "proto3";
package grpc.reflection.$version;

service ServerReflection {
  rpc ServerReflectionInfo(stream ServerReflectionRequest)
      returns (stream ServerReflectionResponse);
}

message ServerReflectionRequest {
  string host = 1;
  oneof message_request {
    string file_by_filename = 3;
    string file_containing_symbol = 4;
    ExtensionRequest file_containing_extension = 5;
    string all_extension_numbers_of_type = 6;
    string list_services = 7;
  }
}

message ExtensionRequest {
  string containing_type = 1;
  int32 extension_number = 2;
}

message ServerReflectionResponse {
  string valid_host = 1;
  ServerReflectionRequest original_request = 2;
  oneof message_response {
    FileDescriptorResponse file_descriptor_response = 4;
    ExtensionNumberResponse all_extension_numbers_response = 5;
    ListServiceResponse list_services_response = 6;
    ErrorResponse error_response = 7;
  }
}

message FileDescriptorResponse {
  repeated bytes file_descriptor_proto = 1;
}

message ExtensionNumberResponse {
  string base_type_name = 1;
  repeated int32 extension_number = 2;
}

message ListServiceResponse {
  repeated ServiceResponse service = 1;
}

message ServiceResponse {
  string name = 1;
}

message ErrorResponse {
  int32 error_code = 1;
  string error_message = 2;
}
''';

/// Source text of every built-in file, by import path.
final Map<String, String> builtInProtos = {
  'google/protobuf/any.proto': _any,
  'google/protobuf/duration.proto': _duration,
  'google/protobuf/empty.proto': _empty,
  'google/protobuf/field_mask.proto': _fieldMask,
  'google/protobuf/struct.proto': _struct,
  'google/protobuf/timestamp.proto': _timestamp,
  'google/protobuf/wrappers.proto': _wrappers,
  'google/protobuf/descriptor.proto': _descriptor,
  'grpc/reflection/v1/reflection.proto': _reflection('v1'),
  'grpc/reflection/v1alpha/reflection.proto': _reflection('v1alpha'),
};

/// A freshly parsed built-in file for [path], or null. Each call parses a
/// new copy, because linking a file ties it to one pool.
ProtoFile? builtInProto(String path) {
  final text = builtInProtos[path.replaceAll('\\', '/')];
  if (text == null) return null;
  return parseProto(text, name: path);
}

/// Parses [sources] (import path or file path → .proto text) and links
/// them, with the built-in files for imports none of them provide.
///
/// Throws [ProtoSchemaException] naming the file, line and column.
DescriptorPool buildPool(Map<String, String> sources) => DescriptorPool.build([
  for (final e in sources.entries) parseProto(e.value, name: e.key),
], fallback: builtInProto);
