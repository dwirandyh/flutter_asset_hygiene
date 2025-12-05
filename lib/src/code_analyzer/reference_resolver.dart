import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:path/path.dart' as p;

import '../models/code_element.dart';
import '../models/code_scan_config.dart';
import '../utils/file_utils.dart';
import '../utils/logger.dart';
import 'symbol_collector.dart';
import 'visitors/import_visitor.dart';
import 'visitors/reference_visitor.dart';

/// Resolves all references (usages) from Dart files
class ReferenceResolver {
  final CodeScanConfig config;
  final Logger logger;

  ReferenceResolver({
    required this.config,
    required this.logger,
  });

  /// Resolve all references from a directory
  Future<ReferenceCollection> resolve(
    String directoryPath, {
    String? packageName,
  }) async {
    final references = <CodeReference>[];
    final referencedIdentifiers = <String>{};
    final referencedTypes = <String>{};
    final usedImports = <String>{};
    final unusedImports = <UnusedImportInfo>[];

    // Find all Dart files
    final dartFiles = await FileUtils.findDartFiles(
      directoryPath,
      includeTests: config.includeTests,
      includeGenerated: false,
      excludePatterns: config.effectiveExcludePatterns,
    );

    logger.debug('Resolving references in ${dartFiles.length} files');

    for (final file in dartFiles) {
      final result = await _resolveFromFile(file, directoryPath, packageName);
      if (result != null) {
        references.addAll(result.references);
        referencedIdentifiers.addAll(result.referencedIdentifiers);
        referencedTypes.addAll(result.referencedTypes);
        usedImports.addAll(result.usedImports);
        unusedImports.addAll(result.unusedImports);
      }
    }

    return ReferenceCollection(
      references: references,
      referencedIdentifiers: referencedIdentifiers,
      referencedTypes: referencedTypes,
      usedImports: usedImports,
      unusedImports: unusedImports,
      packageName: packageName,
    );
  }

  /// Resolve references from a single file
  Future<FileReferenceResult?> _resolveFromFile(
    File file,
    String projectRoot,
    String? packageName,
  ) async {
    try {
      final content = await file.readAsString();
      final relativePath = p.relative(file.path, from: projectRoot);

      final parseResult = parseString(content: content);

      // Collect references
      final refVisitor = ReferenceVisitor(
        filePath: relativePath,
        packageName: packageName,
      );
      parseResult.unit.visitChildren(refVisitor);

      // Analyze imports
      final importVisitor = ImportVisitor(
        filePath: relativePath,
        packageName: packageName,
      );
      parseResult.unit.visitChildren(importVisitor);

      final unusedImports = importVisitor.getUnusedImports().map(
        (i) => UnusedImportInfo(
          uri: i.uri,
          location: i.location,
          prefix: i.prefix,
        ),
      ).toList();

      return FileReferenceResult(
        references: refVisitor.references,
        referencedIdentifiers: refVisitor.referencedIdentifiers,
        referencedTypes: refVisitor.referencedTypes,
        usedImports: refVisitor.usedImports,
        unusedImports: unusedImports,
        filePath: relativePath,
      );
    } catch (e) {
      logger.debug('Error resolving references in ${file.path}: $e');
      return null;
    }
  }

  /// Resolve references from multiple packages
  Future<ReferenceCollection> resolveFromPackages(
    List<PackageInfo> packages,
  ) async {
    final allReferences = <CodeReference>[];
    final allIdentifiers = <String>{};
    final allTypes = <String>{};
    final allUsedImports = <String>{};
    final allUnusedImports = <UnusedImportInfo>[];

    for (final package in packages) {
      logger.debug('Resolving references in package: ${package.name}');

      final collection = await resolve(
        package.path,
        packageName: package.name,
      );

      allReferences.addAll(collection.references);
      allIdentifiers.addAll(collection.referencedIdentifiers);
      allTypes.addAll(collection.referencedTypes);
      allUsedImports.addAll(collection.usedImports);
      allUnusedImports.addAll(collection.unusedImports);
    }

    return ReferenceCollection(
      references: allReferences,
      referencedIdentifiers: allIdentifiers,
      referencedTypes: allTypes,
      usedImports: allUsedImports,
      unusedImports: allUnusedImports,
    );
  }
}

/// Collection of references from analysis
class ReferenceCollection {
  /// All references found
  final List<CodeReference> references;

  /// All referenced identifiers
  final Set<String> referencedIdentifiers;

  /// All referenced types
  final Set<String> referencedTypes;

  /// All used import URIs
  final Set<String> usedImports;

  /// Unused imports found
  final List<UnusedImportInfo> unusedImports;

  /// Package name (if single package)
  final String? packageName;

  const ReferenceCollection({
    required this.references,
    required this.referencedIdentifiers,
    required this.referencedTypes,
    required this.usedImports,
    this.unusedImports = const [],
    this.packageName,
  });

  /// Check if an identifier is referenced
  bool isReferenced(String identifier) {
    return referencedIdentifiers.contains(identifier);
  }

  /// Check if a type is referenced
  bool isTypeReferenced(String typeName) {
    return referencedTypes.contains(typeName);
  }

  /// Merge multiple collections
  static ReferenceCollection merge(List<ReferenceCollection> collections) {
    final allReferences = <CodeReference>[];
    final allIdentifiers = <String>{};
    final allTypes = <String>{};
    final allUsedImports = <String>{};
    final allUnusedImports = <UnusedImportInfo>[];

    for (final collection in collections) {
      allReferences.addAll(collection.references);
      allIdentifiers.addAll(collection.referencedIdentifiers);
      allTypes.addAll(collection.referencedTypes);
      allUsedImports.addAll(collection.usedImports);
      allUnusedImports.addAll(collection.unusedImports);
    }

    return ReferenceCollection(
      references: allReferences,
      referencedIdentifiers: allIdentifiers,
      referencedTypes: allTypes,
      usedImports: allUsedImports,
      unusedImports: allUnusedImports,
    );
  }
}

/// Result from analyzing a single file
class FileReferenceResult {
  final List<CodeReference> references;
  final Set<String> referencedIdentifiers;
  final Set<String> referencedTypes;
  final Set<String> usedImports;
  final List<UnusedImportInfo> unusedImports;
  final String filePath;

  const FileReferenceResult({
    required this.references,
    required this.referencedIdentifiers,
    required this.referencedTypes,
    required this.usedImports,
    required this.unusedImports,
    required this.filePath,
  });
}

/// Information about an unused import
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


