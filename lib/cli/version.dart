/// Version printed by `apiworkbench-cli --version` and written to reports.
///
/// Keep in step with `version:` in pubspec.yaml; test/cli_test.dart fails
/// when they differ, because a compiled binary cannot read the pubspec.
const cliVersion = '1.4.0';

/// Executable name used in messages and reports.
const cliName = 'apiworkbench-cli';
