import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:path/path.dart' as p;

import '../models/code_element.dart';
import '../models/code_scan_config.dart';
import '../utils/file_utils.dart';
import '../utils/logger.dart';
import 'visitors/declaration_visitor.dart';

/// Collects all symbol declarations from Dart files
class SymbolCollector {
  final CodeScanConfig config;
  final Logger logger;

  SymbolCollector({required this.config, required this.logger});

  /// Collect all declarations from a directory
  Future<SymbolCollection> collect(
    String directoryPath, {
    String? packageName,
  }) async {
    final declarations = <CodeElement>[];
    final fileDeclarations = <String, List<CodeElement>>{};

    // Find all Dart files
    final dartFiles = await FileUtils.findDartFiles(
      directoryPath,
      includeTests: config.includeTests,
      includeGenerated:
          false, // Always exclude generated for unused code analysis
      excludePatterns: config.effectiveExcludePatterns,
    );

    logger.debug('Found ${dartFiles.length} Dart files in $directoryPath');

    for (final file in dartFiles) {
      final result = await _collectFromFile(file, directoryPath, packageName);
      if (result != null) {
        declarations.addAll(result);
        final relativePath = p.relative(file.path, from: directoryPath);
        fileDeclarations[relativePath] = result;
      }
    }

    return SymbolCollection(
      declarations: declarations,
      fileDeclarations: fileDeclarations,
      packageName: packageName,
    );
  }

  /// Collect declarations from a single file
  Future<List<CodeElement>?> _collectFromFile(
    File file,
    String projectRoot,
    String? packageName,
  ) async {
    try {
      final content = await file.readAsString();
      final relativePath = p.relative(file.path, from: projectRoot);

      final parseResult = parseString(content: content);

      final visitor = DeclarationVisitor(
        filePath: relativePath,
        packageName: packageName,
      );

      parseResult.unit.visitChildren(visitor);

      logger.debug(
        'Collected ${visitor.declarations.length} declarations from $relativePath',
      );

      return visitor.declarations;
    } catch (e) {
      logger.debug('Error parsing ${file.path}: $e');
      return null;
    }
  }

  /// Collect declarations from multiple packages
  Future<SymbolCollection> collectFromPackages(
    List<PackageInfo> packages,
  ) async {
    final allDeclarations = <CodeElement>[];
    final allFileDeclarations = <String, List<CodeElement>>{};
    final packageDeclarations = <String, List<CodeElement>>{};

    for (final package in packages) {
      logger.debug('Collecting symbols from package: ${package.name}');

      final collection = await collect(package.path, packageName: package.name);

      allDeclarations.addAll(collection.declarations);
      allFileDeclarations.addAll(collection.fileDeclarations);
      packageDeclarations[package.name] = collection.declarations;
    }

    return SymbolCollection(
      declarations: allDeclarations,
      fileDeclarations: allFileDeclarations,
      packageDeclarations: packageDeclarations,
    );
  }
}

/// Collection of symbols from analysis
class SymbolCollection {
  /// All declarations found
  final List<CodeElement> declarations;

  /// Declarations grouped by file
  final Map<String, List<CodeElement>> fileDeclarations;

  /// Declarations grouped by package (for monorepo)
  final Map<String, List<CodeElement>> packageDeclarations;

  /// Package name (if single package)
  final String? packageName;

  const SymbolCollection({
    required this.declarations,
    this.fileDeclarations = const {},
    this.packageDeclarations = const {},
    this.packageName,
  });

  /// Get declarations by type
  List<CodeElement> byType(CodeElementType type) {
    return declarations.where((d) => d.type == type).toList();
  }

  /// Get all classes
  List<CodeElement> get classes => byType(CodeElementType.classDeclaration);

  /// Get all mixins
  List<CodeElement> get mixins => byType(CodeElementType.mixinDeclaration);

  /// Get all extensions
  List<CodeElement> get extensions =>
      byType(CodeElementType.extensionDeclaration);

  /// Get all enums
  List<CodeElement> get enums => byType(CodeElementType.enumDeclaration);

  /// Get all typedefs
  List<CodeElement> get typedefs => byType(CodeElementType.typedefDeclaration);

  /// Get all top-level functions
  List<CodeElement> get functions => byType(CodeElementType.topLevelFunction);

  /// Get all top-level variables
  List<CodeElement> get variables => byType(CodeElementType.topLevelVariable);

  /// Get all methods
  List<CodeElement> get methods => byType(CodeElementType.method);

  /// Get all imports
  List<CodeElement> get imports => byType(CodeElementType.importDirective);

  /// Get all exports
  List<CodeElement> get exports => byType(CodeElementType.exportDirective);

  /// Merge multiple collections
  static SymbolCollection merge(List<SymbolCollection> collections) {
    final allDeclarations = <CodeElement>[];
    final allFileDeclarations = <String, List<CodeElement>>{};
    final allPackageDeclarations = <String, List<CodeElement>>{};

    for (final collection in collections) {
      allDeclarations.addAll(collection.declarations);
      allFileDeclarations.addAll(collection.fileDeclarations);
      allPackageDeclarations.addAll(collection.packageDeclarations);
    }

    return SymbolCollection(
      declarations: allDeclarations,
      fileDeclarations: allFileDeclarations,
      packageDeclarations: allPackageDeclarations,
    );
  }
}

/// Information about a package
class PackageInfo {
  final String name;
  final String path;
  final bool isRoot;

  const PackageInfo({
    required this.name,
    required this.path,
    this.isRoot = false,
  });
}
