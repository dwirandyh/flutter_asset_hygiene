import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/code_scan_config.dart';
import '../models/code_scan_result.dart';
import '../scanner/melos_detector.dart';
import '../utils/logger.dart';
import 'reference_resolver.dart';
import 'symbol_collector.dart';
import 'unused_detector.dart';

/// Main orchestrator for unused code analysis
class CodeAnalyzer {
  final CodeScanConfig config;
  final Logger logger;

  CodeAnalyzer({
    required this.config,
    Logger? logger,
  }) : logger = logger ?? Logger(verbose: config.verbose);

  /// Run the analysis and return results
  Future<CodeScanResult> analyze() async {
    final stopwatch = Stopwatch()..start();

    logger.header('Unused Code Analysis');
    logger.info('Analyzing: ${config.rootPath}');

    // Check for Melos workspace
    final melosDetector = MelosDetector(rootPath: config.rootPath);

    if (melosDetector.isMelosWorkspace && config.scanWorkspace) {
      logger.info('Detected Melos workspace');
      return _analyzeWorkspace(melosDetector, stopwatch);
    }

    // Check if inside a Melos workspace
    if (config.scanWorkspace && config.crossPackageAnalysis) {
      final workspaceRoot = _findMelosWorkspaceRoot(config.rootPath);
      if (workspaceRoot != null) {
        logger.info('Found Melos workspace at: $workspaceRoot');
        return _analyzeWithWorkspaceContext(workspaceRoot, stopwatch);
      }
    }

    // Single project analysis
    return _analyzeSingleProject(stopwatch);
  }

  /// Find Melos workspace root
  String? _findMelosWorkspaceRoot(String startPath) {
    var current = p.normalize(startPath);

    for (var i = 0; i < 10; i++) {
      final melosFile = File(p.join(current, 'melos.yaml'));
      if (melosFile.existsSync()) {
        return current;
      }

      final parent = p.dirname(current);
      if (parent == current) break;
      current = parent;
    }

    return null;
  }

  /// Analyze a single project
  Future<CodeScanResult> _analyzeSingleProject(Stopwatch stopwatch) async {
    logger.debug('Analyzing single project...');

    // Phase 1: Collect declarations
    logger.debug('Phase 1: Collecting declarations...');
    final symbolCollector = SymbolCollector(config: config, logger: logger);
    final symbols = await symbolCollector.collect(config.rootPath);
    logger.debug('Found ${symbols.declarations.length} declarations');

    // Phase 2: Resolve references
    logger.debug('Phase 2: Resolving references...');
    final referenceResolver = ReferenceResolver(config: config, logger: logger);
    final references = await referenceResolver.resolve(config.rootPath);
    logger.debug('Found ${references.references.length} references');

    // Phase 3: Detect unused code
    logger.debug('Phase 3: Detecting unused code...');
    final unusedDetector = UnusedDetector(config: config, logger: logger);
    final issues = unusedDetector.detect(
      symbols: symbols,
      references: references,
    );
    logger.debug('Found ${issues.length} issues');

    stopwatch.stop();

    return CodeScanResult(
      issues: issues,
      declarations: symbols.declarations.toSet(),
      references: references.references.toSet(),
      statistics: ScanStatistics.fromIssues(
        issues,
        filesScanned: symbols.fileDeclarations.length,
        scanDurationMs: stopwatch.elapsedMilliseconds,
      ),
    );
  }

  /// Analyze a Melos workspace
  Future<CodeScanResult> _analyzeWorkspace(
    MelosDetector detector,
    Stopwatch stopwatch,
  ) async {
    final workspace = await detector.parseWorkspace();
    final packagePaths = <String, String>{};

    if (workspace == null) {
      logger.error('Failed to parse Melos workspace');
      return CodeScanResult(
        issues: [],
        statistics: ScanStatistics(
          filesScanned: 0,
          totalIssues: 0,
          scanDurationMs: stopwatch.elapsedMilliseconds,
        ),
      );
    }

    logger.info('Found ${workspace.packages.length} packages');

    // Collect all packages
    final packages = <PackageInfo>[];

    // Add root package if it has Dart code
    final rootLibPath = p.join(config.rootPath, 'lib');
    if (Directory(rootLibPath).existsSync()) {
      packages.add(PackageInfo(
        name: workspace.name,
        path: config.rootPath,
        isRoot: true,
      ));
      packagePaths[workspace.name] = config.rootPath;
    }

    // Add workspace packages
    for (final pkg in workspace.packages) {
      packages.add(PackageInfo(
        name: pkg.name,
        path: pkg.path,
      ));
      packagePaths[pkg.name] = pkg.path;
    }

    // Phase 1: Collect all declarations from all packages
    logger.debug('Phase 1: Collecting declarations from all packages...');
    final symbolCollector = SymbolCollector(config: config, logger: logger);
    final symbols = await symbolCollector.collectFromPackages(packages);
    logger.debug('Found ${symbols.declarations.length} total declarations');

    // Phase 2: Resolve all references from all packages
    logger.debug('Phase 2: Resolving references from all packages...');
    final referenceResolver = ReferenceResolver(config: config, logger: logger);
    final references = await referenceResolver.resolveFromPackages(packages);
    logger.debug('Found ${references.references.length} total references');

    // Phase 3: Detect unused code
    logger.debug('Phase 3: Detecting unused code...');
    final unusedDetector = UnusedDetector(config: config, logger: logger);
    final issues = unusedDetector.detect(
      symbols: symbols,
      references: references,
    );
    logger.debug('Found ${issues.length} issues');

    stopwatch.stop();

    return CodeScanResult(
      issues: issues,
      declarations: symbols.declarations.toSet(),
      references: references.references.toSet(),
      statistics: ScanStatistics.fromIssues(
        issues,
        filesScanned: symbols.fileDeclarations.length,
        scanDurationMs: stopwatch.elapsedMilliseconds,
      ),
      scannedPackages: packages.map((p) => p.name).toList(),
      packagePaths: packagePaths,
    );
  }

  /// Analyze a package with workspace context (for cross-package usage)
  Future<CodeScanResult> _analyzeWithWorkspaceContext(
    String workspaceRoot,
    Stopwatch stopwatch,
  ) async {
    final workspaceDetector = MelosDetector(rootPath: workspaceRoot);
    final workspace = await workspaceDetector.parseWorkspace();
    final packagePaths = <String, String>{};

    if (workspace == null) {
      return _analyzeSingleProject(stopwatch);
    }

    // Collect all packages for reference resolution
    final packages = <PackageInfo>[];

    for (final pkg in workspace.packages) {
      packages.add(PackageInfo(
        name: pkg.name,
        path: pkg.path,
      ));
      packagePaths[pkg.name] = pkg.path;
    }

    // Collect declarations only from target package
    logger.debug('Collecting declarations from target package...');
    final symbolCollector = SymbolCollector(config: config, logger: logger);
    final targetSymbols = await symbolCollector.collect(config.rootPath);

    // Resolve references from ALL packages (for cross-package detection)
    logger.debug('Resolving references from all packages...');
    final referenceResolver = ReferenceResolver(config: config, logger: logger);
    final allReferences = await referenceResolver.resolveFromPackages(packages);

    // Detect unused in target package using all references
    logger.debug('Detecting unused code...');
    final unusedDetector = UnusedDetector(config: config, logger: logger);
    final issues = unusedDetector.detect(
      symbols: targetSymbols,
      references: allReferences,
    );

    stopwatch.stop();

    return CodeScanResult(
      issues: issues,
      declarations: targetSymbols.declarations.toSet(),
      references: allReferences.references.toSet(),
      statistics: ScanStatistics.fromIssues(
        issues,
        filesScanned: targetSymbols.fileDeclarations.length,
        scanDurationMs: stopwatch.elapsedMilliseconds,
      ),
      scannedPackages: packages.map((p) => p.name).toList(),
      packagePaths: packagePaths,
    );
  }
}

