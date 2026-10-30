import 'dart:io';

import 'package:api_workbench/cli/cli.dart';

/// `apiworkbench-cli`: runs a collection from the command line. See
/// `lib/cli/cli.dart`.
Future<void> main(List<String> args) async {
  final code = await runCli(args);
  await stdout.flush();
  await stderr.flush();
  exit(code);
}
