import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:path/path.dart' as p;

import '../models/code_element.dart';
import '../models/code_scan_config.dart';
import '../utils/file_utils.dart';
import '../utils/logger.dart';
import 'symbol_collector.dart';
import 'visitors/semantic_reference_visitor.dart';

/// Semantic analyzer using full type resolution via AnalysisContextCollection.
///
/// This provides accurate analysis for:
/// - Extension methods (implicit usage without extension name)
/// - DI patterns (GetIt, injectable, riverpod)
/// - Granular import tracking (per-symbol usage in show/hide)
/// - Cross-file type resolution
class SemanticAnalyzer {
  final CodeScanConfig config;
  final Logger logger;

  AnalysisContextCollection? _contextCollection;

  SemanticAnalyzer({required this.config, required this.logger});

  /// Initialize the analysis context for the given paths.
  Future<void> initialize(List<String> includedPaths) async {
    final normalizedPaths = includedPaths
        .map((p) => p.normalizePath(config.rootPath))
        .where((path) => Directory(path).existsSync())
        .toList();

    if (normalizedPaths.isEmpty) {
      logger.warning('No valid paths found for semantic analysis');
      return;
    }

    logger.debug(
      'Initializing semantic analyzer for ${normalizedPaths.length} paths',
    );

    try {
      _contextCollection = AnalysisContextCollection(
        includedPaths: normalizedPaths,
        resourceProvider: PhysicalResourceProvider.INSTANCE,
      );
      logger.debug('Semantic analyzer initialized successfully');
    } catch (e) {
      logger.warning('Failed to initialize semantic analyzer: $e');
      _contextCollection = null;
    }
  }

  /// Check if semantic analysis is available
  bool get isAvailable => _contextCollection != null;

  /// Resolve a file and return the resolved unit result.
  Future<ResolvedUnitResult?> resolveFile(String filePath) async {
    if (_contextCollection == null) {
      logger.debug('Semantic analyzer not initialized, skipping: $filePath');
      return null;
    }

    final normalizedPath = p.normalize(p.absolute(filePath));

    try {
      final context = _contextCollection!.contextFor(normalizedPath);
      final result = await context.currentSession.getResolvedUnit(
        normalizedPath,
      );

      if (result is ResolvedUnitResult) {
        return result;
      }

      logger.debug('Failed to resolve file: $filePath');
      return null;
    } catch (e) {
      logger.debug('Error resolving file $filePath: $e');
      return null;
    }
  }

  /// Analyze a directory and collect semantic references.
  ///
  /// [workspaceRoot] - Optional workspace root for consistent path reporting.
  ///                   If provided, file paths will be relative to this root.
  ///                   If not provided, defaults to directoryPath.
  Future<SemanticReferenceCollection> analyzeDirectory(
    String directoryPath, {
    String? packageName,
    String? workspaceRoot,
  }) async {
    final references = <SemanticReference>[];
    final usedElements = <String>{};
    final usedExtensions = <String>{};
    final importUsage = <String, ImportUsageInfo>{};
    final diRegistrations = <DIRegistration>[];
    final effectiveWorkspaceRoot = workspaceRoot ?? directoryPath;

    // Find all Dart files
    // ALWAYS include test files for reference resolution to avoid false positives
    // on test-only code (e.g., createForTesting methods used only in tests)
    final dartFiles = await FileUtils.findDartFiles(
      directoryPath,
      includeTests: true, // Always include tests for reference resolution
      includeGenerated: false,
      excludePatterns: config.effectiveExcludePatterns,
    );

    logger.debug('Analyzing ${dartFiles.length} files semantically');

    // First pass: analyze all files and collect results
    final allResults = <String, FileSemanticResult>{};

    // Track part-library relationships
    final partToLibrary = <String, String>{}; // part file -> library file
    final libraryParts = <String, List<String>>{}; // library file -> part files

    for (final file in dartFiles) {
      final result = await _analyzeFile(
        file,
        effectiveWorkspaceRoot,
        packageName,
      );
      if (result != null) {
        allResults[result.filePath] = result;
        references.addAll(result.references);
        usedElements.addAll(result.usedElementIds);
        usedExtensions.addAll(result.usedExtensions);
        diRegistrations.addAll(result.diRegistrations);

        // Track part file relationships
        if (result.isPartFile && result.libraryFilePath != null) {
          // Resolve library path relative to part file's directory
          final partDir = p.dirname(result.filePath);
          final libraryPath = p.normalize(
            p.join(partDir, result.libraryFilePath!),
          );
          partToLibrary[result.filePath] = libraryPath;
          libraryParts.putIfAbsent(libraryPath, () => []).add(result.filePath);
        }
      }
    }

    // Second pass: aggregate import usage, considering part files
    for (final entry in allResults.entries) {
      final result = entry.value;

      // Skip part files - their usage will be aggregated into library file
      if (result.isPartFile) {
        continue;
      }

      // For library files, aggregate usage from all parts
      final partFiles = libraryParts[result.filePath] ?? [];

      for (final importEntry in result.importUsage.entries) {
        var usage = importEntry.value;

        // Aggregate usage from part files
        for (final partPath in partFiles) {
          final partResult = allResults[partPath];
          if (partResult != null) {
            // Part files don't have their own imports, but they use symbols
            // from the library's imports. Merge the used elements.
            usage = usage.copyWith(
              usedSymbols: {...usage.usedSymbols, ...partResult.usedElementIds},
              isUsedImplicitly:
                  usage.isUsedImplicitly ||
                  partResult.usedElementIds.isNotEmpty,
            );
          }
        }

        // Use filePath:uri as key to track per-file import usage
        final key = '${result.filePath}:${importEntry.key}';
        importUsage[key] = usage;
      }
    }

    return SemanticReferenceCollection(
      references: references,
      usedElementIds: usedElements,
      usedExtensions: usedExtensions,
      importUsage: importUsage,
      diRegistrations: diRegistrations,
      packageName: packageName,
    );
  }

  /// Analyze a single file with full semantic resolution.
  Future<FileSemanticResult?> _analyzeFile(
    File file,
    String projectRoot,
    String? packageName,
  ) async {
    final resolvedUnit = await resolveFile(file.path);
    if (resolvedUnit == null) {
      return null;
    }

    final relativePath = p.relative(file.path, from: projectRoot);

    final visitor = SemanticReferenceVisitor(
      filePath: relativePath,
      packageName: packageName,
      resolvedUnit: resolvedUnit,
      logger: logger,
    );

    resolvedUnit.unit.visitChildren(visitor);

    return FileSemanticResult(
      filePath: relativePath,
      references: visitor.references,
      usedElementIds: visitor.usedElementIds,
      usedExtensions: visitor.usedExtensions,
      importUsage: visitor.importUsage,
      diRegistrations: visitor.diRegistrations,
      isPartFile: visitor.isPartFile,
      libraryFilePath: visitor.libraryFilePath,
    );
  }

  /// Analyze multiple packages (for monorepo support).
  ///
  /// [workspaceRoot] - Optional workspace root for consistent path reporting.
  ///                   If provided, all file paths will be relative to this root.
  Future<SemanticReferenceCollection> analyzePackages(
    List<PackageInfo> packages, {
    String? workspaceRoot,
  }) async {
    final allReferences = <SemanticReference>[];
    final allUsedElements = <String>{};
    final allUsedExtensions = <String>{};
    final allImportUsage = <String, ImportUsageInfo>{};
    final allDiRegistrations = <DIRegistration>[];

    // Initialize context collection with all package paths
    final packagePaths = packages.map((p) => p.path).toList();
    await initialize(packagePaths);

    for (final package in packages) {
      logger.debug('Analyzing package semantically: ${package.name}');

      try {
        final collection = await analyzeDirectory(
          package.path,
          packageName: package.name,
          workspaceRoot: workspaceRoot,
        );

        allReferences.addAll(collection.references);
        allUsedElements.addAll(collection.usedElementIds);
        allUsedExtensions.addAll(collection.usedExtensions);
        allDiRegistrations.addAll(collection.diRegistrations);

        // Import usage is already keyed by filePath:uri from analyzeDirectory
        // Just add them directly without merging
        allImportUsage.addAll(collection.importUsage);
      } catch (e) {
        logger.warning('Error analyzing package ${package.name}: $e');
      }
    }

    return SemanticReferenceCollection(
      references: allReferences,
      usedElementIds: allUsedElements,
      usedExtensions: allUsedExtensions,
      importUsage: allImportUsage,
      diRegistrations: allDiRegistrations,
    );
  }

  /// Dispose the analysis context.
  void dispose() {
    _contextCollection = null;
  }
}

/// Extension to normalize paths
extension on String {
  String normalizePath(String rootPath) {
    if (p.isAbsolute(this)) {
      return p.normalize(this);
    }
    return p.normalize(p.join(rootPath, this));
  }
}

/// Collection of semantic references from analysis.
class SemanticReferenceCollection {
  /// All semantic references found
  final List<SemanticReference> references;

  /// Set of used element IDs (fully qualified)
  final Set<String> usedElementIds;

  /// Set of used extension names
  final Set<String> usedExtensions;

  /// Import usage tracking (URI -> usage info)
  final Map<String, ImportUsageInfo> importUsage;

  /// DI registrations found
  final List<DIRegistration> diRegistrations;

  /// Package name (if single package)
  final String? packageName;

  const SemanticReferenceCollection({
    required this.references,
    required this.usedElementIds,
    required this.usedExtensions,
    required this.importUsage,
    required this.diRegistrations,
    this.packageName,
  });

  /// Check if an element is used (by fully qualified ID).
  bool isElementUsed(String elementId) {
    return usedElementIds.contains(elementId);
  }

  /// Check if an extension is used.
  bool isExtensionUsed(String extensionName) {
    return usedExtensions.contains(extensionName);
  }

  /// Get partially used imports.
  List<PartiallyUsedImport> getPartiallyUsedImports() {
    final result = <PartiallyUsedImport>[];

    for (final entry in importUsage.entries) {
      final info = entry.value;
      if (info.shownSymbols.isNotEmpty) {
        final unusedSymbols = info.shownSymbols.difference(info.usedSymbols);
        if (unusedSymbols.isNotEmpty && info.usedSymbols.isNotEmpty) {
          result.add(
            PartiallyUsedImport(
              uri: entry.key,
              usedSymbols: info.usedSymbols.toList(),
              unusedSymbols: unusedSymbols.toList(),
              location: info.location,
            ),
          );
        }
      }
    }

    return result;
  }

  /// Get completely unused imports.
  List<UnusedImportInfo> getUnusedImports() {
    final result = <UnusedImportInfo>[];

    for (final entry in importUsage.entries) {
      final info = entry.value;
      if (info.usedSymbols.isEmpty && !info.isUsedImplicitly) {
        result.add(
          UnusedImportInfo(
            // Use the actual URI from ImportUsageInfo, not the key
            // (key is filePath:uri for uniqueness)
            uri: info.uri,
            location: info.location,
            prefix: info.prefix,
          ),
        );
      }
    }

    return result;
  }

  /// Merge with another collection.
  SemanticReferenceCollection merge(SemanticReferenceCollection other) {
    // Import usage is keyed by filePath:uri, so just combine them
    final mergedImportUsage = Map<String, ImportUsageInfo>.from(importUsage);
    mergedImportUsage.addAll(other.importUsage);

    return SemanticReferenceCollection(
      references: [...references, ...other.references],
      usedElementIds: {...usedElementIds, ...other.usedElementIds},
      usedExtensions: {...usedExtensions, ...other.usedExtensions},
      importUsage: mergedImportUsage,
      diRegistrations: [...diRegistrations, ...other.diRegistrations],
    );
  }
}

/// Result from analyzing a single file semantically.
class FileSemanticResult {
  final String filePath;
  final List<SemanticReference> references;
  final Set<String> usedElementIds;
  final Set<String> usedExtensions;
  final Map<String, ImportUsageInfo> importUsage;
  final List<DIRegistration> diRegistrations;

  /// Whether this file is a part file (has `part of` directive)
  final bool isPartFile;

  /// The library file path if this is a part file
  final String? libraryFilePath;

  const FileSemanticResult({
    required this.filePath,
    required this.references,
    required this.usedElementIds,
    required this.usedExtensions,
    required this.importUsage,
    required this.diRegistrations,
    this.isPartFile = false,
    this.libraryFilePath,
  });
}

/// A semantic reference with full element information.
class SemanticReference {
  /// The element being referenced (fully qualified ID)
  final String elementId;

  /// The element's library URI
  final String? libraryUri;

  /// Location of the reference
  final SourceLocation location;

  /// Type of reference
  final ReferenceType type;

  /// Package where the reference occurs
  final String? packageName;

  /// Whether this is an implicit reference (e.g., extension method)
  final bool isImplicit;

  const SemanticReference({
    required this.elementId,
    this.libraryUri,
    required this.location,
    required this.type,
    this.packageName,
    this.isImplicit = false,
  });
}

/// Information about import usage.
class ImportUsageInfo {
  /// The import URI
  final String uri;

  /// Import prefix (if any)
  final String? prefix;

  /// Symbols shown in the import (from show combinator)
  final Set<String> shownSymbols;

  /// Symbols hidden in the import (from hide combinator)
  final Set<String> hiddenSymbols;

  /// Symbols actually used from this import
  final Set<String> usedSymbols;

  /// Whether this import is used implicitly (e.g., for side effects)
  final bool isUsedImplicitly;

  /// Location of the import directive
  final SourceLocation location;

  const ImportUsageInfo({
    required this.uri,
    this.prefix,
    this.shownSymbols = const {},
    this.hiddenSymbols = const {},
    this.usedSymbols = const {},
    this.isUsedImplicitly = false,
    required this.location,
  });

  ImportUsageInfo merge(ImportUsageInfo other) {
    return ImportUsageInfo(
      uri: uri,
      prefix: prefix ?? other.prefix,
      shownSymbols: {...shownSymbols, ...other.shownSymbols},
      hiddenSymbols: {...hiddenSymbols, ...other.hiddenSymbols},
      usedSymbols: {...usedSymbols, ...other.usedSymbols},
      isUsedImplicitly: isUsedImplicitly || other.isUsedImplicitly,
      location: location,
    );
  }

  ImportUsageInfo copyWith({
    String? uri,
    String? prefix,
    Set<String>? shownSymbols,
    Set<String>? hiddenSymbols,
    Set<String>? usedSymbols,
    bool? isUsedImplicitly,
    SourceLocation? location,
  }) {
    return ImportUsageInfo(
      uri: uri ?? this.uri,
      prefix: prefix ?? this.prefix,
      shownSymbols: shownSymbols ?? this.shownSymbols,
      hiddenSymbols: hiddenSymbols ?? this.hiddenSymbols,
      usedSymbols: usedSymbols ?? this.usedSymbols,
      isUsedImplicitly: isUsedImplicitly ?? this.isUsedImplicitly,
      location: location ?? this.location,
    );
  }
}

/// Information about a partially used import.
class PartiallyUsedImport {
  final String uri;
  final List<String> usedSymbols;
  final List<String> unusedSymbols;
  final SourceLocation location;

  const PartiallyUsedImport({
    required this.uri,
    required this.usedSymbols,
    required this.unusedSymbols,
    required this.location,
  });

  String get suggestion {
    if (usedSymbols.isEmpty) {
      return 'Remove the unused import';
    }
    return 'Update to: import \'$uri\' show ${usedSymbols.join(', ')};';
  }

  String get message {
    return 'Import \'$uri\' has unused symbols: ${unusedSymbols.join(', ')}';
  }
}

/// Information about an unused import.
class UnusedImportInfo {
  final String uri;
  final SourceLocation location;
  final String? prefix;

  const UnusedImportInfo({
    required this.uri,
    required this.location,
    this.prefix,
  });

  String get displayName {
    if (prefix != null) {
      return '$uri as $prefix';
    }
    return uri;
  }
}

/// DI registration information.
class DIRegistration {
  /// The type being registered
  final String typeName;

  /// The DI framework
  final DIFramework framework;

  /// Registration type (singleton, factory, etc.)
  final DIRegistrationType registrationType;

  /// Location of the registration
  final SourceLocation location;

  /// Package name
  final String? packageName;

  const DIRegistration({
    required this.typeName,
    required this.framework,
    required this.registrationType,
    required this.location,
    this.packageName,
  });
}

/// Supported DI frameworks.
enum DIFramework { getIt, injectable, riverpod, provider, bloc }

/// DI registration types.
enum DIRegistrationType {
  singleton,
  lazySingleton,
  factory,
  provider,
  notifier,
}
