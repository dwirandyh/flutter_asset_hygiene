import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/code_scan_config.dart';
import '../models/code_scan_result.dart';
import '../scanner/melos_detector.dart';
import '../utils/logger.dart';
import 'di_detector.dart';
import 'reference_resolver.dart';
import 'semantic_analyzer.dart';
import 'symbol_collector.dart';
import 'unused_detector.dart';

/// Main orchestrator for unused code analysis.
///
/// Supports two analysis modes:
/// - AST-only (fast): Name-based reference matching
/// - Semantic (accurate): Full type resolution with extension/DI tracking
class CodeAnalyzer {
  final CodeScanConfig config;
  final Logger logger;

  /// Semantic analyzer for full type resolution (lazy initialized)
  SemanticAnalyzer? _semanticAnalyzer;

  CodeAnalyzer({required this.config, Logger? logger})
    : logger = logger ?? Logger(verbose: config.verbose);

  /// Whether semantic analysis is enabled
  bool get useSemanticAnalysis => config.semantic.enabled;

  /// Run the analysis and return results
  Future<CodeScanResult> analyze() async {
    final stopwatch = Stopwatch()..start();

    logger.header('Unused Code Analysis');
    logger.info('Analyzing: ${config.rootPath}');

    if (useSemanticAnalysis) {
      logger.info('Using semantic analysis (accurate mode)');
    } else {
      logger.info('Using AST-only analysis (fast mode)');
    }

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

    // Phase 2.5: Semantic analysis (if enabled)
    SemanticReferenceCollection? semanticRefs;
    DIDetectionResult? diResult;

    if (useSemanticAnalysis) {
      logger.debug('Phase 2.5: Running semantic analysis...');
      final semanticResult = await _runSemanticAnalysis(config.rootPath);
      semanticRefs = semanticResult.references;
      diResult = semanticResult.diResult;

      if (semanticRefs != null) {
        logger.debug(
          'Found ${semanticRefs.usedExtensions.length} extension usages',
        );
        logger.debug(
          'Found ${semanticRefs.usedElementIds.length} element usages',
        );
      }

      if (diResult != null) {
        logger.debug('Found ${diResult.allTypes.length} DI-registered types');
      }
    }

    // Phase 3: Detect unused code
    logger.debug('Phase 3: Detecting unused code...');
    final unusedDetector = UnusedDetector(config: config, logger: logger);
    final issues = unusedDetector.detect(
      symbols: symbols,
      references: references,
      semanticReferences: semanticRefs,
      diTypes: diResult?.allTypes,
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

  /// Run semantic analysis on a directory.
  Future<_SemanticAnalysisResult> _runSemanticAnalysis(
    String directoryPath,
  ) async {
    try {
      _semanticAnalyzer ??= SemanticAnalyzer(config: config, logger: logger);
      await _semanticAnalyzer!.initialize([directoryPath]);

      if (!_semanticAnalyzer!.isAvailable) {
        logger.warning(
          'Semantic analysis not available, falling back to AST-only',
        );
        return _SemanticAnalysisResult(references: null, diResult: null);
      }

      final refs = await _semanticAnalyzer!.analyzeDirectory(directoryPath);

      // Run DI detection if enabled
      DIDetectionResult? diResult;
      if (config.semantic.detectDI) {
        diResult = DIDetectionResult(
          registeredTypes: refs.diRegistrations.map((r) => r.typeName).toSet(),
          retrievedTypes: {},
          registrations: refs.diRegistrations,
          retrievals: [],
        );
      }

      return _SemanticAnalysisResult(references: refs, diResult: diResult);
    } catch (e) {
      logger.warning('Semantic analysis failed: $e');
      return _SemanticAnalysisResult(references: null, diResult: null);
    }
  }

  /// Run semantic analysis on multiple packages.
  ///
  /// [workspaceRoot] - Optional workspace root for consistent path reporting.
  Future<_SemanticAnalysisResult> _runSemanticAnalysisForPackages(
    List<PackageInfo> packages, {
    String? workspaceRoot,
  }) async {
    try {
      _semanticAnalyzer ??= SemanticAnalyzer(config: config, logger: logger);
      final refs = await _semanticAnalyzer!.analyzePackages(
        packages,
        workspaceRoot: workspaceRoot,
      );

      // Run DI detection if enabled
      DIDetectionResult? diResult;
      if (config.semantic.detectDI) {
        diResult = DIDetectionResult(
          registeredTypes: refs.diRegistrations.map((r) => r.typeName).toSet(),
          retrievedTypes: {},
          registrations: refs.diRegistrations,
          retrievals: [],
        );
      }

      return _SemanticAnalysisResult(references: refs, diResult: diResult);
    } catch (e) {
      logger.warning('Semantic analysis failed: $e');
      return _SemanticAnalysisResult(references: null, diResult: null);
    }
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

    // Build exclude patterns for ALL sub-packages from root scan to avoid duplicates.
    // Each sub-package will be scanned separately, so we must exclude them from root.
    // Also collect absolute paths of excluded packages for nested package detection.
    final subPackageExcludePatterns = <String>[];
    final excludedAbsolutePaths = <String>[];
    for (final pkg in workspace.packages) {
      // Get relative path from root to package
      final relativePath = p.relative(pkg.path, from: config.rootPath);
      // Exclude ALL sub-packages from root scan to prevent duplicate declarations
      subPackageExcludePatterns.add('**/$relativePath/**');
      subPackageExcludePatterns.add('$relativePath/**');

      // Track excluded packages for nested package detection
      if (config.monorepo.excludePackages.contains(pkg.name)) {
        excludedAbsolutePaths.add(p.normalize(pkg.path));
      }
    }

    // Helper to check if a package is nested inside an excluded package
    bool isNestedInExcludedPackage(String packagePath) {
      final normalizedPath = p.normalize(packagePath);
      for (final excludedPath in excludedAbsolutePaths) {
        if (normalizedPath.startsWith('$excludedPath/') ||
            normalizedPath.startsWith('$excludedPath${p.separator}')) {
          return true;
        }
      }
      return false;
    }

    // Add root package if it has Dart code
    final rootLibPath = p.join(config.rootPath, 'lib');
    if (Directory(rootLibPath).existsSync()) {
      packages.add(
        PackageInfo(
          name: workspace.name,
          path: config.rootPath,
          isRoot: true,
          additionalExcludePatterns: subPackageExcludePatterns,
        ),
      );
      packagePaths[workspace.name] = config.rootPath;
    }

    // Add workspace packages (filtering excluded packages)
    for (final pkg in workspace.packages) {
      // Skip packages that are in the exclude list
      if (config.monorepo.excludePackages.contains(pkg.name)) {
        logger.debug('Skipping excluded package: ${pkg.name}');
        continue;
      }

      // Skip packages that are nested inside an excluded package
      if (isNestedInExcludedPackage(pkg.path)) {
        logger.debug('Skipping package nested in excluded path: ${pkg.name}');
        continue;
      }

      // If include list is specified, only include those packages
      if (config.monorepo.includePackages.isNotEmpty &&
          !config.monorepo.includePackages.contains(pkg.name)) {
        logger.debug('Skipping non-included package: ${pkg.name}');
        continue;
      }

      // Skip packages that match exclude patterns (e.g., packages/design_system/**/*)
      final relativePath = p.relative(pkg.path, from: config.rootPath);
      if (_matchesExcludePatterns(relativePath, config.excludePatterns)) {
        logger.debug('Skipping package matching exclude pattern: ${pkg.name}');
        continue;
      }

      packages.add(PackageInfo(name: pkg.name, path: pkg.path));
      packagePaths[pkg.name] = pkg.path;
    }

    // Phase 1: Collect all declarations from all packages
    logger.debug('Phase 1: Collecting declarations from all packages...');
    final symbolCollector = SymbolCollector(config: config, logger: logger);
    final symbols = await symbolCollector.collectFromPackages(
      packages,
      workspaceRoot: config.rootPath,
    );
    logger.debug('Found ${symbols.declarations.length} total declarations');

    // Phase 2: Resolve all references from all packages
    logger.debug('Phase 2: Resolving references from all packages...');
    final referenceResolver = ReferenceResolver(config: config, logger: logger);
    final references = await referenceResolver.resolveFromPackages(
      packages,
      workspaceRoot: config.rootPath,
    );
    logger.debug('Found ${references.references.length} total references');

    // Phase 2.5: Semantic analysis (if enabled)
    SemanticReferenceCollection? semanticRefs;
    DIDetectionResult? diResult;

    if (useSemanticAnalysis) {
      logger.debug('Phase 2.5: Running semantic analysis...');
      final semanticResult = await _runSemanticAnalysisForPackages(
        packages,
        workspaceRoot: config.rootPath,
      );
      semanticRefs = semanticResult.references;
      diResult = semanticResult.diResult;

      if (semanticRefs != null) {
        logger.debug(
          'Found ${semanticRefs.usedExtensions.length} extension usages',
        );
      }

      if (diResult != null) {
        logger.debug('Found ${diResult.allTypes.length} DI-registered types');
      }
    }

    // Phase 3: Detect unused code
    logger.debug('Phase 3: Detecting unused code...');
    final unusedDetector = UnusedDetector(config: config, logger: logger);
    final issues = unusedDetector.detect(
      symbols: symbols,
      references: references,
      semanticReferences: semanticRefs,
      diTypes: diResult?.allTypes,
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

    // Collect absolute paths of excluded packages for nested package detection
    final excludedAbsolutePaths = <String>[];
    for (final pkg in workspace.packages) {
      if (config.monorepo.excludePackages.contains(pkg.name)) {
        excludedAbsolutePaths.add(p.normalize(pkg.path));
      }
    }

    // Helper to check if a package is nested inside an excluded package
    bool isNestedInExcludedPackage(String packagePath) {
      final normalizedPath = p.normalize(packagePath);
      for (final excludedPath in excludedAbsolutePaths) {
        if (normalizedPath.startsWith('$excludedPath/') ||
            normalizedPath.startsWith('$excludedPath${p.separator}')) {
          return true;
        }
      }
      return false;
    }

    // Collect all packages for reference resolution (filtering excluded packages)
    final packages = <PackageInfo>[];

    for (final pkg in workspace.packages) {
      // Skip packages that are in the exclude list
      if (config.monorepo.excludePackages.contains(pkg.name)) {
        logger.debug('Skipping excluded package: ${pkg.name}');
        continue;
      }

      // Skip packages that are nested inside an excluded package
      if (isNestedInExcludedPackage(pkg.path)) {
        logger.debug('Skipping package nested in excluded path: ${pkg.name}');
        continue;
      }

      // If include list is specified, only include those packages
      if (config.monorepo.includePackages.isNotEmpty &&
          !config.monorepo.includePackages.contains(pkg.name)) {
        logger.debug('Skipping non-included package: ${pkg.name}');
        continue;
      }

      // Skip packages that match exclude patterns
      final relativePath = p.relative(pkg.path, from: workspaceRoot);
      if (_matchesExcludePatterns(relativePath, config.excludePatterns)) {
        logger.debug('Skipping package matching exclude pattern: ${pkg.name}');
        continue;
      }

      packages.add(PackageInfo(name: pkg.name, path: pkg.path));
      packagePaths[pkg.name] = pkg.path;
    }

    // Collect declarations only from target package
    logger.debug('Collecting declarations from target package...');
    final symbolCollector = SymbolCollector(config: config, logger: logger);
    final targetSymbols = await symbolCollector.collect(
      config.rootPath,
      workspaceRoot: workspaceRoot,
    );

    // Resolve references from ALL packages (for cross-package detection)
    logger.debug('Resolving references from all packages...');
    final referenceResolver = ReferenceResolver(config: config, logger: logger);
    final allReferences = await referenceResolver.resolveFromPackages(
      packages,
      workspaceRoot: workspaceRoot,
    );

    // Semantic analysis (if enabled)
    SemanticReferenceCollection? semanticRefs;
    DIDetectionResult? diResult;

    if (useSemanticAnalysis) {
      logger.debug('Running semantic analysis...');
      final semanticResult = await _runSemanticAnalysisForPackages(
        packages,
        workspaceRoot: workspaceRoot,
      );
      semanticRefs = semanticResult.references;
      diResult = semanticResult.diResult;
    }

    // Detect unused in target package using all references
    logger.debug('Detecting unused code...');
    final unusedDetector = UnusedDetector(config: config, logger: logger);
    final issues = unusedDetector.detect(
      symbols: targetSymbols,
      references: allReferences,
      semanticReferences: semanticRefs,
      diTypes: diResult?.allTypes,
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

  /// Dispose resources
  void dispose() {
    _semanticAnalyzer?.dispose();
    _semanticAnalyzer = null;
  }

  /// Check if a path matches any of the exclude patterns.
  bool _matchesExcludePatterns(String path, List<String> patterns) {
    for (final pattern in patterns) {
      if (_matchesGlobPattern(path, pattern)) {
        return true;
      }
    }
    return false;
  }

  /// Simple glob pattern matching.
  bool _matchesGlobPattern(String path, String pattern) {
    // Normalize the pattern - remove trailing slashes and wildcards for directory matching
    var normalizedPattern = pattern;

    // Handle patterns like "packages/design_system/**/*" or "packages/design_system/**"
    if (normalizedPattern.endsWith('/**/*')) {
      normalizedPattern = normalizedPattern.substring(
        0,
        normalizedPattern.length - 5,
      );
    } else if (normalizedPattern.endsWith('/**')) {
      normalizedPattern = normalizedPattern.substring(
        0,
        normalizedPattern.length - 3,
      );
    } else if (normalizedPattern.endsWith('/*')) {
      normalizedPattern = normalizedPattern.substring(
        0,
        normalizedPattern.length - 2,
      );
    }

    // Check if path starts with the pattern (directory match)
    if (path == normalizedPattern ||
        path.startsWith('$normalizedPattern/') ||
        path.startsWith('$normalizedPattern${p.separator}')) {
      return true;
    }

    // Handle patterns starting with **/ (match anywhere)
    if (pattern.startsWith('**/')) {
      final suffix = pattern.substring(3);
      // Remove trailing wildcards
      var cleanSuffix = suffix;
      if (cleanSuffix.endsWith('/**/*')) {
        cleanSuffix = cleanSuffix.substring(0, cleanSuffix.length - 5);
      } else if (cleanSuffix.endsWith('/**')) {
        cleanSuffix = cleanSuffix.substring(0, cleanSuffix.length - 3);
      }
      return path.contains(cleanSuffix);
    }

    return false;
  }
}

/// Result of semantic analysis
class _SemanticAnalysisResult {
  final SemanticReferenceCollection? references;
  final DIDetectionResult? diResult;

  const _SemanticAnalysisResult({
    required this.references,
    required this.diResult,
  });
}
