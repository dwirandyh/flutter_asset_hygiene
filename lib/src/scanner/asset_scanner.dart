import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:path/path.dart' as p;

import '../models/models.dart';
import '../utils/file_utils.dart';
import '../utils/logger.dart';
import 'dart_ast_visitor.dart';
import 'generated_asset_parser.dart';
import 'melos_detector.dart';
import 'pubspec_parser.dart';

/// Main orchestrator for scanning unused assets
class AssetScanner {
  final ScanConfig config;
  final Logger logger;

  AssetScanner({required this.config, Logger? logger})
    : logger = logger ?? Logger(verbose: config.verbose);

  /// Run the scan and return results
  Future<ScanResult> scan() async {
    final stopwatch = Stopwatch()..start();

    if (!config.silent) {
      logger.header('Unused Assets Scanner');
      logger.info('Scanning: ${config.rootPath}');
    }

    // Check for Melos workspace at current path
    final melosDetector = MelosDetector(rootPath: config.rootPath);

    if (melosDetector.isMelosWorkspace) {
      if (!config.silent) {
        logger.info('Detected Melos workspace');
      }
      return _scanMelosWorkspace(melosDetector, stopwatch);
    }

    // Check if we're inside a Melos workspace (for cross-package scanning)
    if (config.scanWorkspace) {
      final workspaceRoot = _findMelosWorkspaceRoot(config.rootPath);
      if (workspaceRoot != null) {
        if (!config.silent) {
          logger.info('Found Melos workspace at: $workspaceRoot');
          logger.info('Scanning workspace for cross-package asset usage...');
        }
        return _scanPackageWithWorkspaceContext(workspaceRoot, stopwatch);
      }
    }

    // Single project scan
    return _scanSingleProject(config.rootPath, null, stopwatch);
  }

  /// Find Melos workspace root by traversing parent directories
  String? _findMelosWorkspaceRoot(String startPath) {
    var current = p.normalize(startPath);

    // Limit search depth to avoid infinite loop
    for (var i = 0; i < 10; i++) {
      final melosFile = File(p.join(current, 'melos.yaml'));
      if (melosFile.existsSync()) {
        return current;
      }

      final parent = p.dirname(current);
      if (parent == current) break; // Reached root
      current = parent;
    }

    return null;
  }

  /// Scan a package within Melos workspace context (for cross-package asset usage)
  Future<ScanResult> _scanPackageWithWorkspaceContext(
    String workspaceRoot,
    Stopwatch stopwatch,
  ) async {
    final workspaceDetector = MelosDetector(rootPath: workspaceRoot);
    final workspace = await workspaceDetector.parseWorkspace();
    final packagePathMap = <String, String>{};

    if (workspace == null) {
      // Fallback to single project scan
      return _scanSingleProject(config.rootPath, null, stopwatch);
    }

    // Parse declared assets from target package
    logger.debug('Parsing declared assets from target package...');
    final pubspecParser = PubspecParser(projectRoot: config.rootPath);
    final pubspecResult = await pubspecParser.parse();
    final declaredAssets = pubspecResult.allAssets;
    if (pubspecResult.packageName != null) {
      packagePathMap[pubspecResult.packageName!] = config.rootPath;
    }
    logger.debug('Found ${declaredAssets.length} declared assets');

    if (declaredAssets.isEmpty) {
      return ScanResult(
        declaredAssets: {},
        usedAssets: {},
        warnings: pubspecResult.warnings,
        scanDurationMs: stopwatch.elapsedMilliseconds,
        packagePaths: packagePathMap,
      );
    }

    // Parse generated asset mapping from target package
    logger.debug('Parsing generated asset files...');
    final generatedParser = GeneratedAssetParser(projectRoot: config.rootPath);
    final generatedMapping = await generatedParser.parseGeneratedAssets();
    logger.debug(
      'Found ${generatedMapping.propertyToPath.length} generated asset mappings',
    );

    // Scan ALL packages in workspace for asset usage
    final allVisitorResults = <AssetVisitorResult>[];
    final packagesToScan = <String>[workspaceRoot];

    for (final pkg in workspace.packages) {
      packagesToScan.add(pkg.path);
      packagePathMap[pkg.name] = pkg.path;
    }

    if (!config.silent) {
      logger.info(
        'Scanning ${packagesToScan.length} packages for asset usage...',
      );
    }

    for (final pkgPath in packagesToScan) {
      logger.debug('Scanning package: $pkgPath');

      // For workspace root, only scan lib/ folder to avoid scanning packages/ again
      final scanPath = pkgPath == workspaceRoot
          ? p.join(pkgPath, 'lib')
          : pkgPath;

      if (!Directory(scanPath).existsSync()) {
        logger.debug('Skipping non-existent path: $scanPath');
        continue;
      }

      final dartFiles = await FileUtils.findDartFiles(
        scanPath,
        includeTests: config.includeTests,
        includeGenerated: config.includeGenerated,
        excludePatterns: config.effectiveExcludePatterns,
      );

      logger.debug('Found ${dartFiles.length} dart files in $scanPath');

      for (final file in dartFiles) {
        final result = await _scanDartFile(file, pkgPath);
        if (result != null) {
          allVisitorResults.add(result);
        }
      }
    }

    // Merge all visitor results
    final mergedVisitorResult = AssetVisitorResult.merge(allVisitorResults);

    // Match detected assets with declared assets
    final usedAssets = _matchUsedAssets(
      declaredAssets,
      mergedVisitorResult.detectedAssets,
      config.rootPath,
    );

    // Match assets from generated class usage
    final usedFromGenerated = _matchGeneratedAssetUsage(
      declaredAssets,
      mergedVisitorResult.generatedAssetAccesses,
      generatedMapping,
    );
    usedAssets.addAll(usedFromGenerated);

    // Match potentially used assets
    final potentiallyUsedAssets = _matchPotentiallyUsedAssets(
      declaredAssets,
      usedAssets,
      mergedVisitorResult.potentialDirectories,
      config.rootPath,
    );

    // Match font families
    final usedFonts = _matchUsedFonts(
      pubspecResult.fonts,
      mergedVisitorResult.usedFontFamilies,
    );
    usedAssets.addAll(usedFonts);

    stopwatch.stop();

    return ScanResult(
      declaredAssets: declaredAssets,
      usedAssets: usedAssets,
      potentiallyUsedAssets: potentiallyUsedAssets,
      warnings: [...pubspecResult.warnings, ...mergedVisitorResult.warnings],
      scannedPackages: packagesToScan.map((p) => p.split('/').last).toList(),
      packagePaths: packagePathMap,
      scanDurationMs: stopwatch.elapsedMilliseconds,
    );
  }

  /// Scan a Melos workspace with cross-package asset detection
  Future<ScanResult> _scanMelosWorkspace(
    MelosDetector detector,
    Stopwatch stopwatch,
  ) async {
    final workspace = await detector.parseWorkspace();
    final packagePaths = <String, String>{};

    if (workspace == null) {
      if (!config.silent) {
        logger.error('Failed to parse Melos workspace');
      }
      return ScanResult(
        declaredAssets: {},
        usedAssets: {},
        packagePaths: const {},
        scanDurationMs: stopwatch.elapsedMilliseconds,
      );
    }

    if (!config.silent) {
      logger.info('Found ${workspace.packages.length} packages');
    }

    // Collect all declared assets from all packages
    final allDeclaredAssets = <Asset>{};
    final allGeneratedMappings = GeneratedAssetMapping();
    final allWarnings = <ScanWarning>[];
    final scannedPackages = <String>[];

    // Also parse root package if it has assets (monorepos often have assets in root)
    final rootPackage = await detector.getRootPackage();
    if (rootPackage != null) {
      logger.debug('Parsing assets from root package: ${rootPackage.name}');

      final pubspecParser = PubspecParser(
        projectRoot: rootPackage.path,
        packageName: rootPackage.name,
      );
      final pubspecResult = await pubspecParser.parse();
      allDeclaredAssets.addAll(pubspecResult.allAssets);
      allWarnings.addAll(pubspecResult.warnings);
      packagePaths[rootPackage.name] = rootPackage.path;

      final generatedParser = GeneratedAssetParser(
        projectRoot: rootPackage.path,
      );
      final generatedMapping = await generatedParser.parseGeneratedAssets();
      allGeneratedMappings.merge(generatedMapping);

      scannedPackages.add(rootPackage.name);
    }

    // Parse declared assets and generated mappings from each package
    for (final package in workspace.packages) {
      logger.debug('Parsing assets from package: ${package.name}');

      final pubspecParser = PubspecParser(
        projectRoot: package.path,
        packageName: package.name,
      );
      final pubspecResult = await pubspecParser.parse();
      allDeclaredAssets.addAll(pubspecResult.allAssets);
      allWarnings.addAll(pubspecResult.warnings);
      packagePaths[package.name] = package.path;

      final generatedParser = GeneratedAssetParser(projectRoot: package.path);
      final generatedMapping = await generatedParser.parseGeneratedAssets();
      allGeneratedMappings.merge(generatedMapping);

      scannedPackages.add(package.name);
    }

    logger.debug('Total declared assets: ${allDeclaredAssets.length}');
    logger.debug(
      'Total generated mappings: ${allGeneratedMappings.propertyToPath.length}',
    );

    // Scan all packages for asset usage
    final allVisitorResults = <AssetVisitorResult>[];

    // Also scan root lib/ folder if it exists
    final rootLibPath = p.join(config.rootPath, 'lib');
    if (Directory(rootLibPath).existsSync()) {
      logger.debug('Scanning root lib folder');
      final rootDartFiles = await FileUtils.findDartFiles(
        rootLibPath,
        includeTests: config.includeTests,
        includeGenerated: config.includeGenerated,
        excludePatterns: config.effectiveExcludePatterns,
      );
      for (final file in rootDartFiles) {
        final result = await _scanDartFile(file, config.rootPath);
        if (result != null) {
          allVisitorResults.add(result);
        }
      }
    }

    // Scan each package
    for (final package in workspace.packages) {
      logger.debug('Scanning package for usage: ${package.name}');
      final dartFiles = await FileUtils.findDartFiles(
        package.path,
        includeTests: config.includeTests,
        includeGenerated: config.includeGenerated,
        excludePatterns: config.effectiveExcludePatterns,
      );

      for (final file in dartFiles) {
        final result = await _scanDartFile(file, package.path);
        if (result != null) {
          allVisitorResults.add(result);
        }
      }
    }

    // Merge all visitor results
    final mergedVisitorResult = AssetVisitorResult.merge(allVisitorResults);

    // Match detected assets with declared assets
    final usedAssets = _matchUsedAssets(
      allDeclaredAssets,
      mergedVisitorResult.detectedAssets,
      config.rootPath,
    );

    // Match assets from generated class usage
    final usedFromGenerated = _matchGeneratedAssetUsage(
      allDeclaredAssets,
      mergedVisitorResult.generatedAssetAccesses,
      allGeneratedMappings,
    );
    usedAssets.addAll(usedFromGenerated);

    // Match potentially used assets
    final potentiallyUsedAssets = _matchPotentiallyUsedAssets(
      allDeclaredAssets,
      usedAssets,
      mergedVisitorResult.potentialDirectories,
      config.rootPath,
    );

    // Match font families
    final usedFonts = _matchUsedFonts(
      allDeclaredAssets.where((a) => a.type == AssetType.font).toSet(),
      mergedVisitorResult.usedFontFamilies,
    );
    usedAssets.addAll(usedFonts);

    stopwatch.stop();

    return ScanResult(
      declaredAssets: allDeclaredAssets,
      usedAssets: usedAssets,
      potentiallyUsedAssets: potentiallyUsedAssets,
      warnings: [...allWarnings, ...mergedVisitorResult.warnings],
      scannedPackages: scannedPackages,
      packagePaths: packagePaths,
      scanDurationMs: stopwatch.elapsedMilliseconds,
    );
  }

  /// Scan a single project
  Future<ScanResult> _scanSingleProject(
    String projectPath,
    String? packageName,
    Stopwatch stopwatch, {
    bool isPartOfWorkspace = false,
  }) async {
    // Parse pubspec.yaml for declared assets
    logger.debug('Parsing pubspec.yaml...');
    final pubspecParser = PubspecParser(
      projectRoot: projectPath,
      packageName: packageName,
    );
    final pubspecResult = await pubspecParser.parse();
    final packagePathMap = <String, String>{};
    if (pubspecResult.packageName != null) {
      packagePathMap[pubspecResult.packageName!] = projectPath;
    }

    final declaredAssets = pubspecResult.allAssets;
    logger.debug('Found ${declaredAssets.length} declared assets');

    if (declaredAssets.isEmpty && !isPartOfWorkspace && !config.silent) {
      logger.warning('No assets declared in pubspec.yaml');
    }

    // Parse generated asset files for mapping
    logger.debug('Parsing generated asset files...');
    final generatedParser = GeneratedAssetParser(projectRoot: projectPath);
    final generatedMapping = await generatedParser.parseGeneratedAssets();
    logger.debug(
      'Found ${generatedMapping.propertyToPath.length} generated asset mappings',
    );

    // Find all Dart files to scan
    logger.debug('Finding Dart files...');
    final dartFiles = await FileUtils.findDartFiles(
      projectPath,
      includeTests: config.includeTests,
      includeGenerated: config.includeGenerated,
      excludePatterns: config.effectiveExcludePatterns,
    );
    logger.debug('Found ${dartFiles.length} Dart files to scan');

    // Scan Dart files for asset references
    final visitorResults = <AssetVisitorResult>[];
    var scannedCount = 0;

    for (final file in dartFiles) {
      scannedCount++;
      if (config.verbose && !config.silent) {
        logger.progress('Scanning files: $scannedCount/${dartFiles.length}');
      }

      final result = await _scanDartFile(file, projectPath);
      if (result != null) {
        visitorResults.add(result);
      }
    }

    if (config.verbose && !config.silent) {
      logger.clearProgress();
    }

    // Merge visitor results
    final mergedVisitorResult = AssetVisitorResult.merge(visitorResults);

    // Match detected assets with declared assets
    final usedAssets = _matchUsedAssets(
      declaredAssets,
      mergedVisitorResult.detectedAssets,
      projectPath,
    );

    // Match assets from generated class usage
    final usedFromGenerated = _matchGeneratedAssetUsage(
      declaredAssets,
      mergedVisitorResult.generatedAssetAccesses,
      generatedMapping,
    );
    usedAssets.addAll(usedFromGenerated);

    // Match potentially used assets (from dynamic references)
    final potentiallyUsedAssets = _matchPotentiallyUsedAssets(
      declaredAssets,
      usedAssets,
      mergedVisitorResult.potentialDirectories,
      projectPath,
    );

    // Match font families
    final usedFonts = _matchUsedFonts(
      pubspecResult.fonts,
      mergedVisitorResult.usedFontFamilies,
    );
    usedAssets.addAll(usedFonts);

    return ScanResult(
      declaredAssets: declaredAssets,
      usedAssets: usedAssets,
      potentiallyUsedAssets: potentiallyUsedAssets,
      warnings: [...pubspecResult.warnings, ...mergedVisitorResult.warnings],
      scannedPackages: packageName != null ? [packageName] : [],
      packagePaths: packagePathMap,
      scanDurationMs: stopwatch.elapsedMilliseconds,
    );
  }

  /// Scan a single Dart file
  Future<AssetVisitorResult?> _scanDartFile(
    File file,
    String projectRoot,
  ) async {
    try {
      final content = await file.readAsString();
      final relativePath = p.relative(file.path, from: projectRoot);

      final parseResult = parseString(content: content);

      final visitor = AssetReferenceVisitor(
        filePath: relativePath,
        assetExtensions: config.assetExtensions,
      );

      parseResult.unit.visitChildren(visitor);

      return AssetVisitorResult.fromVisitor(visitor);
    } catch (e) {
      logger.debug('Error parsing ${file.path}: $e');
      return AssetVisitorResult(
        detectedAssets: {},
        potentialDirectories: {},
        usedFontFamilies: {},
        generatedAssetAccesses: {},
        warnings: [
          ScanWarning(
            type: ScanWarningType.parseError,
            message: 'Failed to parse file: $e',
            filePath: file.path,
          ),
        ],
      );
    }
  }

  /// Match detected asset paths with declared assets
  Set<Asset> _matchUsedAssets(
    Set<Asset> declaredAssets,
    Set<String> detectedPaths,
    String projectRoot,
  ) {
    final usedAssets = <Asset>{};

    for (final asset in declaredAssets) {
      final normalizedAssetPath = asset.normalizedPath;
      final assetFilename = asset.filename.toLowerCase();

      for (final detectedPath in detectedPaths) {
        final normalizedDetected = detectedPath.toLowerCase();

        // Exact match
        if (normalizedAssetPath == normalizedDetected) {
          usedAssets.add(asset);
          break;
        }

        // Match by filename (for cases where full path isn't used)
        if (normalizedDetected.endsWith(assetFilename)) {
          usedAssets.add(asset);
          break;
        }

        // Match by relative path variations
        if (_pathsMatch(normalizedAssetPath, normalizedDetected)) {
          usedAssets.add(asset);
          break;
        }
      }
    }

    return usedAssets;
  }

  /// Match potentially used assets from dynamic references
  Set<Asset> _matchPotentiallyUsedAssets(
    Set<Asset> declaredAssets,
    Set<Asset> usedAssets,
    Set<String> potentialDirectories,
    String projectRoot,
  ) {
    final potentiallyUsed = <Asset>{};

    for (final asset in declaredAssets) {
      if (usedAssets.contains(asset)) continue;

      final assetDir = asset.directory.toLowerCase();

      for (final potentialDir in potentialDirectories) {
        final normalizedPotential = potentialDir.toLowerCase();

        if (assetDir.startsWith(normalizedPotential) ||
            normalizedPotential.startsWith(assetDir)) {
          potentiallyUsed.add(asset);
          break;
        }
      }
    }

    return potentiallyUsed;
  }

  /// Match used fonts by font family name
  Set<Asset> _matchUsedFonts(
    Set<Asset> declaredFonts,
    Set<String> usedFontFamilies,
  ) {
    final usedFonts = <Asset>{};
    final lowerFamilies = usedFontFamilies.map((f) => f.toLowerCase()).toSet();

    for (final font in declaredFonts) {
      // Extract font family from declaration
      final declaration = font.declaration.toLowerCase();
      for (final family in lowerFamilies) {
        if (declaration.contains(family)) {
          usedFonts.add(font);
          break;
        }
      }
    }

    return usedFonts;
  }

  /// Match assets used via generated asset classes (flutter_gen, spider, etc.)
  Set<Asset> _matchGeneratedAssetUsage(
    Set<Asset> declaredAssets,
    Set<String> generatedAccesses,
    GeneratedAssetMapping mapping,
  ) {
    final usedAssets = <Asset>{};

    for (final access in generatedAccesses) {
      // Try to get asset path from mapping
      final assetPath = mapping.getAssetPath(access);
      if (assetPath != null) {
        // Find matching declared asset
        for (final asset in declaredAssets) {
          if (_pathsMatch(asset.normalizedPath, assetPath.toLowerCase())) {
            usedAssets.add(asset);
            break;
          }
        }
      }

      // Also try fuzzy matching based on property name
      final matchingPaths = mapping.getMatchingAssetPaths(access);
      for (final matchPath in matchingPaths) {
        for (final asset in declaredAssets) {
          if (_pathsMatch(asset.normalizedPath, matchPath.toLowerCase())) {
            usedAssets.add(asset);
          }
        }
      }

      // Fallback: try to match by converting property name to filename pattern
      final usedByPattern = _matchByPropertyPattern(declaredAssets, access);
      usedAssets.addAll(usedByPattern);
    }

    return usedAssets;
  }

  /// Match assets by converting property access pattern to filename
  Set<Asset> _matchByPropertyPattern(
    Set<Asset> declaredAssets,
    String propertyAccess,
  ) {
    final matches = <Asset>{};

    // Extract the meaningful part of the property access
    // e.g., "Assets.images.welcomePage1" -> "welcomePage1"
    // e.g., "Assets.images.welcomePage1.path" -> "welcomePage1"
    // e.g., "game_assets.Assets.images.imgNumberBoard.keyName" -> "imgNumberBoard"
    var parts = propertyAccess.split('.');

    // Handle import alias: if first part is lowercase (alias), skip it
    // e.g., "game_assets.Assets.images.logo" -> "Assets.images.logo"
    if (parts.isNotEmpty &&
        RegExp(r'^[a-z_][a-z0-9_]*$').hasMatch(parts.first)) {
      parts = parts.sublist(1);
    }

    // Need at least 3 parts for a specific asset: Assets.category.assetName
    // 2 parts like "Assets.icons" is a category reference, not a specific asset
    if (parts.length < 3) return matches;

    // Get the asset name (skip common suffixes)
    var assetName = parts.last;
    final commonSuffixes = ['path', 'keyName', 'provider', 'image', 'svg'];
    if (commonSuffixes.contains(assetName) && parts.length > 3) {
      assetName = parts[parts.length - 2];
    }

    // Skip if assetName is still a category name (e.g., icons, images)
    final categoryNames = ['icons', 'images', 'fonts', 'assets', 'animations'];
    if (categoryNames.contains(assetName.toLowerCase())) {
      return matches;
    }

    // Convert to different naming conventions for matching
    final snakeCase = _camelToSnake(assetName);
    final lowerCamel = assetName.toLowerCase();
    final kebabCase = snakeCase.replaceAll('_', '-');
    // Normalized version: remove all separators for fuzzy matching
    final normalizedAssetName = lowerCamel.replaceAll(RegExp(r'[-_]'), '');

    for (final asset in declaredAssets) {
      final fileName = p.basenameWithoutExtension(asset.path).toLowerCase();
      final fileNameNormalized = fileName.replaceAll(RegExp(r'[-_.]'), '');

      if (fileName == snakeCase ||
          fileName == lowerCamel ||
          fileName == kebabCase ||
          fileNameNormalized == normalizedAssetName ||
          // Also check if normalized versions match (handles VFX_Katsu_Skill2 vs vFXKatsuSkill2)
          _fuzzyMatch(assetName, p.basenameWithoutExtension(asset.path))) {
        matches.add(asset);
      }
    }

    return matches;
  }

  /// Convert camelCase to snake_case
  String _camelToSnake(String input) {
    return input
        .replaceAllMapped(
          RegExp(r'[A-Z]'),
          (match) => '_${match.group(0)!.toLowerCase()}',
        )
        .replaceFirst(RegExp(r'^_'), '');
  }

  /// Fuzzy match between property name and filename
  /// Handles cases like: vFXKatsuSkill2Atlas <-> VFX_Katsu_Skill2.atlas
  bool _fuzzyMatch(String propertyName, String fileName) {
    // Normalize both: remove separators and convert to lowercase
    final normalizedProperty = propertyName
        .replaceAll(RegExp(r'[-_.]'), '')
        .toLowerCase();
    final normalizedFile = fileName
        .replaceAll(RegExp(r'[-_.]'), '')
        .toLowerCase();

    // Direct match after normalization
    if (normalizedProperty == normalizedFile) return true;

    // Check if property name ends with file extension indicator
    // e.g., vFXKatsuSkill2Atlas -> vfxkatsuskill2 should match VFX_Katsu_Skill2
    final extensionSuffixes = [
      'atlas',
      'skel',
      'png',
      'jpg',
      'svg',
      'json',
      'mp3',
      'wav',
      'lottie',
    ];
    for (final suffix in extensionSuffixes) {
      if (normalizedProperty.endsWith(suffix)) {
        final withoutSuffix = normalizedProperty.substring(
          0,
          normalizedProperty.length - suffix.length,
        );
        if (withoutSuffix == normalizedFile) return true;
      }
    }

    return false;
  }

  /// Check if two paths match (handling various path formats)
  bool _pathsMatch(String path1, String path2) {
    // Remove leading slashes and normalize
    final p1 = path1.replaceAll(RegExp(r'^[/\\]+'), '');
    final p2 = path2.replaceAll(RegExp(r'^[/\\]+'), '');

    if (p1 == p2) return true;

    // Check if one ends with the other
    if (p1.endsWith(p2) || p2.endsWith(p1)) return true;

    // Check package asset format: packages/package_name/...
    if (p2.startsWith('packages/')) {
      final withoutPrefix = p2.replaceFirst(RegExp(r'packages/[^/]+/'), '');
      if (p1 == withoutPrefix || p1.endsWith(withoutPrefix)) return true;
    }

    return false;
  }

  /// Resolve cross-package asset references in a Melos workspace
  ScanResult _resolveCrossPackageReferences(
    ScanResult result,
    MelosWorkspace workspace,
  ) {
    // In a Melos workspace, assets from one package might be used in another
    // This is typically done via package: syntax or shared asset directories

    // For now, we keep the merged result as-is
    // Future enhancement: track package-specific asset usage
    return result;
  }
}
