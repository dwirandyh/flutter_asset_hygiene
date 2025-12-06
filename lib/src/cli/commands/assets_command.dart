import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../../models/models.dart';
import '../../scanner/asset_scanner.dart';
import '../../utils/file_utils.dart';
import '../../utils/logger.dart';

/// Command for scanning unused assets in Flutter/Dart projects
class AssetsCommand extends Command<int> {
  @override
  final String name = 'assets';

  @override
  final String description = 'Scan for unused assets in Flutter/Dart projects';

  @override
  final String invocation = 'flutter_hygiene assets [options]';

  AssetsCommand() {
    argParser
      ..addOption(
        'path',
        abbr: 'p',
        help: 'Path to the project root (default: current directory)',
        defaultsTo: '.',
      )
      ..addFlag(
        'include-tests',
        abbr: 't',
        help: 'Include test files in the scan',
        defaultsTo: false,
      )
      ..addFlag(
        'include-generated',
        abbr: 'g',
        help: 'Include generated files (*.g.dart, *.freezed.dart, etc.)',
        defaultsTo: false,
      )
      ..addOption(
        'exclude',
        abbr: 'e',
        help: 'Comma-separated glob patterns to exclude',
      )
      ..addOption(
        'format',
        abbr: 'f',
        help: 'Output format: console, json, csv, html',
        defaultsTo: 'console',
        allowed: ['console', 'json', 'csv', 'html'],
      )
      ..addOption(
        'output',
        abbr: 'o',
        help: 'Output file path (for json/csv formats)',
      )
      ..addFlag(
        'verbose',
        abbr: 'v',
        help: 'Show verbose output',
        defaultsTo: false,
      )
      ..addFlag(
        'delete',
        abbr: 'd',
        help: 'Delete unused assets (with confirmation)',
        defaultsTo: false,
      )
      ..addFlag('no-color', help: 'Disable colored output', defaultsTo: false)
      ..addFlag(
        'show-used',
        help: 'Also show used assets in the output',
        defaultsTo: false,
      )
      ..addFlag(
        'show-potential',
        help: 'Show potentially used assets (dynamic references)',
        defaultsTo: true,
      )
      ..addFlag(
        'scan-workspace',
        abbr: 'w',
        help: 'Scan entire Melos workspace for cross-package asset usage',
        defaultsTo: true,
      );
  }

  @override
  Future<int> run() async {
    final results = argResults!;

    final config = _buildConfig(results);
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

    // Run the scanner
    final scanner = AssetScanner(config: config, logger: logger);
    final result = await scanner.scan();

    // Output results
    await _outputResults(result, config, logger);

    // Handle delete option
    if (config.deleteUnused && result.unusedAssets.isNotEmpty) {
      await _handleDelete(result, config, logger);
    }

    // Return appropriate exit code
    return result.unusedAssets.isEmpty ? 0 : 1;
  }

  /// Build scan config from parsed arguments
  ScanConfig _buildConfig(dynamic results) {
    final pathArg = results['path'] as String;
    final rootPath = p.isAbsolute(pathArg) ? pathArg : p.absolute(pathArg);

    final excludePatterns = <String>[];
    if (results['exclude'] != null) {
      excludePatterns.addAll(
        (results['exclude'] as String).split(',').map((e) => e.trim()),
      );
    }

    final outputFormat = OutputFormat.fromString(results['format'] as String);
    // Silent mode for JSON/CSV output (unless writing to file)
    final silent =
        outputFormat != OutputFormat.console && results['output'] == null;

    return ScanConfig(
      rootPath: rootPath,
      includeTests: results['include-tests'] as bool,
      includeGenerated: results['include-generated'] as bool,
      excludePatterns: excludePatterns,
      outputFormat: outputFormat,
      verbose: results['verbose'] as bool,
      deleteUnused: results['delete'] as bool,
      silent: silent,
      scanWorkspace: results['scan-workspace'] as bool,
    );
  }

  /// Output scan results
  Future<void> _outputResults(
    ScanResult result,
    ScanConfig config,
    Logger logger,
  ) async {
    switch (config.outputFormat) {
      case OutputFormat.json:
        await _outputJson(result, config, logger);
        break;
      case OutputFormat.csv:
        await _outputCsv(result, config, logger);
        break;
      case OutputFormat.html:
        await _outputHtml(result, config, logger);
        break;
      case OutputFormat.console:
        _outputConsole(result, config, logger);
        break;
    }
  }

  /// Output results as JSON
  Future<void> _outputJson(
    ScanResult result,
    ScanConfig config,
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
    ScanResult result,
    ScanConfig config,
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
    ScanResult result,
    ScanConfig config,
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
  void _outputConsole(ScanResult result, ScanConfig config, Logger logger) {
    logger.divider();

    // Show warnings if any
    if (result.warnings.isNotEmpty) {
      logger.header('Warnings');
      for (final warning in result.warnings) {
        logger.warning(warning.toString());
      }
      logger.divider();
    }

    // Show unused assets
    if (result.unusedAssets.isNotEmpty) {
      logger.header('Unused Assets (${result.unusedAssets.length})');
      final sortedUnused = result.unusedAssets.toList()
        ..sort((a, b) {
          final pkgCompare = (a.packageName ?? '').compareTo(
            b.packageName ?? '',
          );
          if (pkgCompare != 0) return pkgCompare;
          return a.path.compareTo(b.path);
        });

      var totalSize = 0;
      for (final asset in sortedUnused) {
        final absPath = _resolveAssetAbsolutePath(asset, result, config);
        final size = FileUtils.getFileSize(absPath);
        totalSize += size;
        final sizeStr = size > 0 ? ' (${FileUtils.formatFileSize(size)})' : '';
        final pkgLabel = asset.packageName != null
            ? '[${asset.packageName}] '
            : '';
        logger.asset('$pkgLabel$absPath$sizeStr', used: false);
      }

      if (totalSize > 0) {
        logger.plain('');
        logger.info(
          'Total size of unused assets: ${FileUtils.formatFileSize(totalSize)}',
        );
      }
    } else {
      logger.success('No unused assets found!');
    }

    // Show potentially used assets
    if (result.potentiallyUsedAssets.isNotEmpty) {
      logger.header(
        'Potentially Used Assets (${result.potentiallyUsedAssets.length})',
      );
      logger.warning(
        'These assets have dynamic references and may or may not be used:',
      );
      final sortedPotential = result.potentiallyUsedAssets.toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final asset in sortedPotential) {
        final absPath = _resolveAssetAbsolutePath(asset, result, config);
        final pkgLabel = asset.packageName != null
            ? '[${asset.packageName}] '
            : '';
        logger.asset('$pkgLabel$absPath', potential: true);
      }
    }

    // Show summary
    logger.divider();
    logger.plain(result.summary);
  }

  /// Resolve an asset's absolute path using package mapping or the root path
  String _resolveAssetAbsolutePath(
    Asset asset,
    ScanResult result,
    ScanConfig config,
  ) {
    final pkgName = asset.packageName;
    final basePath = pkgName != null
        ? result.packagePaths[pkgName] ?? config.rootPath
        : config.rootPath;
    return p.normalize(p.join(basePath, asset.path));
  }

  /// Handle deletion of unused assets
  Future<void> _handleDelete(
    ScanResult result,
    ScanConfig config,
    Logger logger,
  ) async {
    logger.header('Delete Unused Assets');
    logger.warning(
      'This will permanently delete ${result.unusedAssets.length} files.',
    );
    logger.plain('');

    stdout.write('Are you sure you want to continue? [y/N] ');
    final response = stdin.readLineSync()?.toLowerCase();

    if (response != 'y' && response != 'yes') {
      logger.info('Deletion cancelled.');
      return;
    }

    var deletedCount = 0;
    var failedCount = 0;

    for (final asset in result.unusedAssets) {
      final fullPath = p.join(config.rootPath, asset.path);
      final deleted = await FileUtils.deleteFile(fullPath);
      if (deleted) {
        deletedCount++;
        logger.debug('Deleted: ${asset.path}');
      } else {
        failedCount++;
        logger.warning('Failed to delete: ${asset.path}');
      }
    }

    logger.divider();
    logger.success('Deleted $deletedCount files');
    if (failedCount > 0) {
      logger.warning('Failed to delete $failedCount files');
    }
  }
}
