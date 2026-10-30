// Compiles QuickJS-ng and the FFI bridge into one dynamic library for the
// target being built. `flutter build`, `flutter test`, `dart run` and
// `dart test` all run this hook, so every platform gets a library built from
// the same sources: clang on Linux, MSVC on Windows (x64 and arm64), the NDK
// on Android and Xcode's clang on macOS and iOS.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const _quickjsSources = [
  'src/quickjs/quickjs.c',
  'src/quickjs/libregexp.c',
  'src/quickjs/libunicode.c',
  'src/quickjs/dtoa.c',
];

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    // native_toolchain_c drives cl.exe on Windows and a clang everywhere
    // else; the two take different flags.
    final msvc = os == OS.windows;
    final builder = CBuilder.library(
      name: 'quickjs_ffi',
      assetName: 'quickjs_ffi.dart',
      sources: ['src/bridge.c', ..._quickjsSources],
      includes: ['src/quickjs'],
      std: msvc ? 'c11' : 'gnu11',
      optimizationLevel: OptimizationLevel.o2,
      defines: {
        'QUICKJS_NG_BUILD': null,
        '_GNU_SOURCE': null,
        if (msvc) ...{
          'WIN32_LEAN_AND_MEAN': null,
          '_WIN32_WINNT': '0x0601',
          '_CRT_SECURE_NO_WARNINGS': null,
        },
      },
      flags: msvc
          ? const [
              // QuickJS-ng needs C11 atomics, which MSVC still gates.
              '/experimental:c11atomics',
              '/wd4018', '/wd4061', '/wd4100', '/wd4200', '/wd4242',
              '/wd4244', '/wd4245', '/wd4267', '/wd4388', '/wd4389',
              '/wd4456', '/wd4457', '/wd4710', '/wd4711', '/wd4820',
              '/wd4996', '/wd5045',
            ]
          : const [
              // Only the awq_* bridge functions are exported.
              '-fvisibility=hidden',
              // QuickJS-ng's own builds use unsigned char everywhere.
              '-funsigned-char',
              '-Wno-implicit-fallthrough',
              '-Wno-sign-compare',
              '-Wno-unused-parameter',
              '-Wno-unused-but-set-variable',
              '-Wno-missing-field-initializers',
            ],
      libraries: [if (os == OS.linux || os == OS.android) 'm'],
    );
    await builder.run(
      input: input,
      output: output,
      logger: Logger('')
        ..level = Level.INFO
        ..onRecord.listen(
          (r) => stdout.writeln('${r.level.name}: ${r.message}'),
        ),
    );
  });
}
