# Changelog

All notable changes to ApiWorkbench are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases before 1.3.1 are described on the
[releases page](https://github.com/Dhiva-Labs/ApiWorkbench/releases).

## [1.3.1] - 2026-10-16

### Added

- Linux arm64 and Windows arm64 builds, next to the x64 ones. CI builds,
  tests and starts each package on a native runner of its architecture, and
  a published release carries `apiworkbench_<version>_arm64.deb` (with its
  `.sha256`), `ApiWorkbench-<version>-linux-arm64.tar.gz` and
  `ApiWorkbench-<version>-windows-arm64.zip`. The snap and the Microsoft
  Store package build for arm64 too.
- Windows x64 zip (`ApiWorkbench-<version>-windows-x64.zip`), Linux tarballs
  for x64 and arm64, and Microsoft Store packaging for Windows (`msix_config`
  in `pubspec.yaml`, `tool/build_store_msix.ps1`).
- A privacy policy (`PRIVACY.md`): requests are sent only when you send them,
  to the addresses you enter, and nothing is reported to Dhiva Labs.

### Changed

- The Microsoft Store package leaves out the Chaos Mode meme clips (third-party
  audio) and uses the synthesized sounds instead. Every other build keeps the
  clips.
- The Windows executable is labelled ApiWorkbench / Dhiva Labs in its version
  info, so the Windows data folder is `%APPDATA%\Dhiva Labs\ApiWorkbench`.
- Locked `jni` to 1.0.3, which compiles on Linux arm64.

### Fixed

- Windows: Chaos Mode played no sound because PowerShell did not load the
  media player assembly, and a user name with an apostrophe (for example
  `O'Neil`) broke the clip path.
- The load test teardown now waits for its log file to be deleted, which
  failed on Windows.
