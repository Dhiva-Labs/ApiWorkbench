/// The command line is wrong: an unknown option, a missing file name, a
/// number that is not a number. Exit code 2, with a hint to read the help.
class UsageError implements Exception {
  UsageError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A file cannot be read or is not what the command expects: missing, not a
/// collection, no folder of that name, a data file with a bad row. Exit
/// code 2.
class InputError implements Exception {
  InputError(this.message);
  final String message;

  @override
  String toString() => message;
}
