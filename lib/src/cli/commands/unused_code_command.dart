import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../../code_analyzer/auto_fixer.dart';
import '../../code_analyzer/code_analyzer.dart';
import '../../models/code_element.dart';
import '../../models/code_scan_config.dart';
import '../../models/code_scan_result.dart';
import '../../utils/file_utils.dart';
import '../../utils/logger.dart';

/// Command for detecting unused code in Flutter/Dart projects
class UnusedCodeCommand extends Command<int> {
  @override
  final String name = 'unused-code';

  @override
  final String description =
      'Detect unused code (classes, functions, imports, etc.) in Flutter/Dart projects';

  @override
  final String invocation = 'flutter_hygiene unused-code [options]';

  UnusedCodeCommand() {
    argParser
      ..addOption(
        'path',
        abbr: 'p',
        help: 'Path to the project root (default: current directory)',
        defaultsTo: '.',
      )
      ..addOption(
        'config',
        abbr: 'c',
        help: 'Path to YAML configuration file',
        defaultsTo: 'unused_code.yaml',
      )
      ..addFlag(
        'include-tests',
        abbr: 't',
        help: 'Include test files in analysis',
        defaultsTo: false,
      )
      ..addFlag(
        'exclude-public-api',
        help: 'Skip public API (exported symbols)',
        defaultsTo: false,
      )
      ..addFlag(
        'exclude-overrides',
        help: 'Skip @override methods',
        defaultsTo: true,
      )
      ..addFlag(
        'scan-workspace',
        abbr: 'w',
        help: 'Scan entire Melos workspace',
        defaultsTo: true,
      )
      ..addFlag(
        'cross-package',
        help: 'Detect cross-package usage in monorepo',
        defaultsTo: true,
      )
      ..addOption(
        'format',
        abbr: 'f',
        help: 'Output format: console, json, csv, html',
        defaultsTo: 'console',
        allowed: ['console', 'json', 'csv', 'html'],
      )
      ..addOption('output', abbr: 'o', help: 'Output file path')
      ..addOption(
        'severity',
        help: 'Minimum severity level: info, warning, error',
        defaultsTo: 'warning',
        allowed: ['info', 'warning', 'error'],
      )
      ..addFlag(
        'fix-dry-run',
        help: 'Show what would be removed without making changes',
        defaultsTo: false,
      )
      ..addFlag(
        'fix',
        help: 'Auto-remove unused code (dangerous!)',
        defaultsTo: false,
      )
      ..addFlag(
        'verbose',
        abbr: 'v',
        help: 'Show verbose output',
        defaultsTo: false,
      )
      ..addFlag('no-color', help: 'Disable colored output', defaultsTo: false)
      ..addOption(
        'exclude',
        abbr: 'e',
        help: 'Comma-separated glob patterns to exclude',
      );
  }

  @override
  Future<int> run() async {
    final results = argResults!;

    final config = await _buildConfig(results);
    final logger = Logger(
      verbose: config.verbose,
      useColors: !(results['no-color'] as bool),
    );

    // Validate path
    if (!Directory(config.rootPath).existsSync()) {
      logger.error('Directory not found: ${config.rootPath}');
      return 1;
    }

    // Check for pubspec.yaml
    if (!FileUtils.hasPubspec(config.rootPath)) {
      logger.error(
        'No pubspec.yaml found in ${config.rootPath}. Is this a Dart/Flutter project?',
      );
      return 1;
    }

    // Run the analyzer
    final analyzer = CodeAnalyzer(config: config, logger: logger);
    final result = await analyzer.analyze();

    // Output results
    await _outputResults(result, config, logger);

    // Handle fix options
    if (config.fix && result.issues.isNotEmpty) {
      await _handleFix(result, config, logger, dryRun: false);
    } else if (config.fixDryRun && result.issues.isNotEmpty) {
      await _handleFix(result, config, logger, dryRun: true);
    }

    // Return appropriate exit code
    final hasErrors = result.issues.any(
      (i) => i.severity == IssueSeverity.error,
    );
    final hasWarnings = result.issues.any(
      (i) => i.severity == IssueSeverity.warning,
    );

    if (hasErrors) return 2;
    if (hasWarnings) return 1;
    return 0;
  }

  /// Build config from parsed arguments and optional YAML file
  Future<CodeScanConfig> _buildConfig(dynamic results) async {
    final pathArg = results['path'] as String;
    final rootPath = p.isAbsolute(pathArg) ? pathArg : p.absolute(pathArg);

    final excludePatterns = <String>[];
    if (results['exclude'] != null) {
      excludePatterns.addAll(
        (results['exclude'] as String).split(',').map((e) => e.trim()),
      );
    }

    final outputFormat = CodeOutputFormat.fromString(
      results['format'] as String,
    );
    final severity = IssueSeverity.fromString(results['severity'] as String);

    // Try to load YAML config
    final configPath = results['config'] as String;
    final configFile = File(p.join(rootPath, configPath));

    CodeScanConfig config;
    if (configFile.existsSync()) {
      config = await CodeScanConfig.fromYamlFile(configFile.path);
      // Override with CLI args
      config = config.copyWith(
        rootPath: rootPath,
        includeTests: results['include-tests'] as bool,
        excludePublicApi: results['exclude-public-api'] as bool,
        excludeOverrides: results['exclude-overrides'] as bool,
        scanWorkspace: results['scan-workspace'] as bool,
        crossPackageAnalysis: results['cross-package'] as bool,
        outputFormat: outputFormat,
        minSeverity: severity,
        verbose: results['verbose'] as bool,
        fix: results['fix'] as bool,
        fixDryRun: results['fix-dry-run'] as bool,
        excludePatterns: excludePatterns.isNotEmpty ? excludePatterns : null,
      );
    } else {
      config = CodeScanConfig(
        rootPath: rootPath,
        includeTests: results['include-tests'] as bool,
        excludePublicApi: results['exclude-public-api'] as bool,
        excludeOverrides: results['exclude-overrides'] as bool,
        scanWorkspace: results['scan-workspace'] as bool,
        crossPackageAnalysis: results['cross-package'] as bool,
        outputFormat: outputFormat,
        minSeverity: severity,
        verbose: results['verbose'] as bool,
        fix: results['fix'] as bool,
        fixDryRun: results['fix-dry-run'] as bool,
        excludePatterns: excludePatterns,
      );
    }

    return config;
  }

  /// Output analysis results
  Future<void> _outputResults(
    CodeScanResult result,
    CodeScanConfig config,
    Logger logger,
  ) async {
    switch (config.outputFormat) {
      case CodeOutputFormat.json:
        await _outputJson(result, config, logger);
        break;
      case CodeOutputFormat.csv:
        await _outputCsv(result, config, logger);
        break;
      case CodeOutputFormat.html:
        await _outputHtml(result, config, logger);
        break;
      case CodeOutputFormat.console:
        _outputConsole(result, config, logger);
        break;
    }
  }

  /// Output results as JSON
  Future<void> _outputJson(
    CodeScanResult result,
    CodeScanConfig config,
    Logger logger,
  ) async {
    final json = const JsonEncoder.withIndent('  ').convert(result.toJson());

    final outputPath = argResults!['output'] as String?;
    if (outputPath != null) {
      await File(outputPath).writeAsString(json);
      logger.success('Results written to $outputPath');
    } else {
      print(json);
    }
  }

  /// Output results as CSV
  Future<void> _outputCsv(
    CodeScanResult result,
    CodeScanConfig config,
    Logger logger,
  ) async {
    final csv = result.toCsv();

    final outputPath = argResults!['output'] as String?;
    if (outputPath != null) {
      await File(outputPath).writeAsString(csv);
      logger.success('Results written to $outputPath');
    } else {
      print(csv);
    }
  }

  /// Output results as HTML
  Future<void> _outputHtml(
    CodeScanResult result,
    CodeScanConfig config,
    Logger logger,
  ) async {
    final html = result.toHtml();

    final outputPath = argResults!['output'] as String?;
    if (outputPath != null) {
      await File(outputPath).writeAsString(html);
      logger.success('Results written to $outputPath');
    } else {
      print(html);
    }
  }

  /// Output results to console
  void _outputConsole(
    CodeScanResult result,
    CodeScanConfig config,
    Logger logger,
  ) {
    logger.plain('');
    logger.plain(
      '═══════════════════════════════════════════════════════════════',
    );
    logger.plain('                    Unused Code Analysis');
    logger.plain(
      '═══════════════════════════════════════════════════════════════',
    );
    logger.plain('');

    if (result.issues.isEmpty) {
      logger.success('No unused code found!');
      logger.plain('');
      return;
    }

    // Group issues by file
    final issuesByFile = <String, List<CodeIssue>>{};
    for (final issue in result.issues) {
      final file = issue.location.filePath;
      issuesByFile.putIfAbsent(file, () => []).add(issue);
    }

    // Sort files
    final sortedFiles = issuesByFile.keys.toList()..sort();

    for (final file in sortedFiles) {
      final issues = issuesByFile[file]!;
      issues.sort((a, b) => a.location.line.compareTo(b.location.line));

      logger.plain('📁 $file');
      for (final issue in issues) {
        final icon = _getSeverityIcon(issue.severity);
        logger.plain(
          '  $icon [${issue.category.name}] ${issue.symbol} - ${issue.message}',
        );
        logger.plain(
          '      Line ${issue.location.line}: ${issue.codeSnippet ?? ''}',
        );
      }
      logger.plain('');
    }

    logger.plain(
      '───────────────────────────────────────────────────────────────',
    );
    logger.plain('Summary:');
    logger.plain('  Files scanned: ${result.statistics.filesScanned}');
    logger.plain('  Unused classes: ${result.statistics.unusedClasses}');
    logger.plain('  Unused functions: ${result.statistics.unusedFunctions}');
    logger.plain('  Unused parameters: ${result.statistics.unusedParameters}');
    logger.plain('  Unused imports: ${result.statistics.unusedImports}');
    logger.plain('  Total issues: ${result.statistics.totalIssues}');
    logger.plain(
      '  Scan duration: ${result.statistics.scanDurationMs / 1000}s',
    );
    logger.plain(
      '═══════════════════════════════════════════════════════════════',
    );
  }

  String _getSeverityIcon(IssueSeverity severity) {
    switch (severity) {
      case IssueSeverity.error:
        return '❌';
      case IssueSeverity.warning:
        return '⚠️';
      case IssueSeverity.info:
        return 'ℹ️';
    }
  }

  /// Handle fix or fix-dry-run
  Future<void> _handleFix(
    CodeScanResult result,
    CodeScanConfig config,
    Logger logger, {
    required bool dryRun,
  }) async {
    final fixableIssues = result.issues.where((i) => i.canAutoFix).toList();
    if (fixableIssues.isEmpty) {
      logger.info('No auto-fixable issues found.');
      return;
    }

    final autoFixer = AutoFixer(config: config, logger: logger);

    if (dryRun) {
      final fixResult = await autoFixer.applyFixes(result, dryRun: true);
      if (fixResult.totalIssues == 0) {
        logger.info('No auto-fixable issues found.');
        return;
      }

      logger.header('Fix Dry Run - Would remove:');
      final files = fixResult.fileIssues;
      final sortedFiles = files.keys.toList()..sort();

      for (final file in sortedFiles) {
        final relativePath = p.relative(file, from: config.rootPath);
        logger.plain('📄 $relativePath');
        for (final issue in files[file]!) {
          logger.plain(
            '  - ${issue.symbol} (${issue.category.name}) at line ${issue.location.line}',
          );
        }
      }

      logger.plain('');
      logger.info(
        'Total: ${fixResult.totalIssues} issue(s) across ${files.length} file(s).',
      );
      if (fixResult.skippedIssues.isNotEmpty) {
        logger.warning(
          'Skipped ${fixResult.skippedIssues.length} issue(s) because files were missing or offsets were invalid.',
        );
      }
      return;
    }

    logger.header('Auto-fix Unused Code');
    logger.warning(
      'This will permanently modify ${fixableIssues.length} issue(s) across '
      '${fixableIssues.map((i) => i.location.filePath).toSet().length} file(s).',
    );
    logger.plain('');

    stdout.write('Are you sure you want to continue? [y/N] ');
    final response = stdin.readLineSync()?.toLowerCase();

    if (response != 'y' && response != 'yes') {
      logger.info('Fix cancelled.');
      return;
    }

    final fixResult = await autoFixer.applyFixes(result, dryRun: false);
    if (fixResult.totalIssues == 0) {
      logger.info('No changes were applied.');
      return;
    }

    final deletedMsg = fixResult.filesDeleted > 0
        ? ', deleted ${fixResult.filesDeleted} file(s)'
        : '';
    logger.success(
      'Auto-fix applied: removed ${fixResult.totalIssues} issue(s) across ${fixResult.filesChanged} file(s)$deletedMsg.',
    );
    if (fixResult.skippedIssues.isNotEmpty) {
      logger.warning(
        'Skipped ${fixResult.skippedIssues.length} issue(s) because files were missing or offsets were invalid.',
      );
    }
  }
}
