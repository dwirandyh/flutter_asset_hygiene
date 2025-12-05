import 'dart:io';

import 'src/cli/cli_runner.dart';

/// Entry point for the unused assets scanner CLI tool
Future<void> main(List<String> arguments) async {
  final runner = CliRunner(arguments);
  final exitCode = await runner.run();
  exit(exitCode);
}
