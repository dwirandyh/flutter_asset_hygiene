import 'dart:io';

import 'package:args/command_runner.dart';

import 'commands/assets_command.dart';
import 'commands/unused_code_command.dart';

/// CLI runner for the Flutter Asset Hygiene tool
class CliRunner {
  final List<String> arguments;

  CliRunner(this.arguments);

  /// Run the CLI
  Future<int> run() async {
    final runner =
        CommandRunner<int>(
            'flutter_tools',
            'Flutter Asset Hygiene - Find unused assets and code in Flutter/Dart projects',
          )
          ..addCommand(AssetsCommand())
          ..addCommand(UnusedCodeCommand());

    try {
      // If no command is provided, show help
      if (arguments.isEmpty) {
        runner.printUsage();
        return 0;
      }

      // Handle global flags
      if (arguments.contains('--help') ||
          arguments.contains('-h') && arguments.length == 1) {
        runner.printUsage();
        return 0;
      }

      if (arguments.contains('--version')) {
        print('flutter_tools v0.3.0');
        return 0;
      }

      final result = await runner.run(arguments);
      return result ?? 0;
    } on UsageException catch (e) {
      stderr.writeln(e.message);
      stderr.writeln('');
      stderr.writeln(e.usage);
      return 64; // EX_USAGE
    } catch (e, stack) {
      stderr.writeln('Unexpected error: $e');
      if (arguments.contains('-v') || arguments.contains('--verbose')) {
        stderr.writeln(stack);
      }
      return 1;
    }
  }
}
