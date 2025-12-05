import 'asset.dart';

/// Result of scanning a project for unused assets
class ScanResult {
  /// All declared assets found in pubspec.yaml
  final Set<Asset> declaredAssets;

  /// Assets that are used in the codebase
  final Set<Asset> usedAssets;

  /// Assets that are potentially used (dynamic references)
  final Set<Asset> potentiallyUsedAssets;

  /// Warnings generated during scan
  final List<ScanWarning> warnings;

  /// Packages scanned (for monorepo)
  final List<String> scannedPackages;

  /// Map of package name to absolute path (for resolving asset locations)
  final Map<String, String> packagePaths;

  /// Time taken to scan in milliseconds
  final int scanDurationMs;

  const ScanResult({
    required this.declaredAssets,
    required this.usedAssets,
    this.potentiallyUsedAssets = const {},
    this.warnings = const [],
    this.scannedPackages = const [],
    this.packagePaths = const {},
    this.scanDurationMs = 0,
  });

  /// Get unused assets (declared but not used)
  Set<Asset> get unusedAssets {
    return declaredAssets
        .where(
          (asset) =>
              !usedAssets.contains(asset) &&
              !potentiallyUsedAssets.contains(asset),
        )
        .toSet();
  }

  /// Get unused assets excluding potentially used ones
  Set<Asset> get definitelyUnusedAssets {
    return declaredAssets.where((asset) => !usedAssets.contains(asset)).toSet();
  }

  /// Summary statistics
  int get totalDeclared => declaredAssets.length;
  int get totalUsed => usedAssets.length;
  int get totalUnused => unusedAssets.length;
  int get totalPotentiallyUsed => potentiallyUsedAssets.length;

  /// Calculate potential space savings (requires file sizes)
  String get summary =>
      '''
Scan Summary:
  Declared assets: $totalDeclared
  Used assets: $totalUsed
  Potentially used: $totalPotentiallyUsed
  Unused assets: $totalUnused
  Packages scanned: ${scannedPackages.length}
  Scan duration: ${scanDurationMs}ms
''';

  /// Convert to JSON map
  Map<String, dynamic> toJson() {
    return {
      'declaredAssets': declaredAssets.map((a) => a.path).toList(),
      'usedAssets': usedAssets.map((a) => a.path).toList(),
      'potentiallyUsedAssets': potentiallyUsedAssets
          .map((a) => a.path)
          .toList(),
      'unusedAssets': unusedAssets.map((a) => a.path).toList(),
      'warnings': warnings.map((w) => w.toJson()).toList(),
      'scannedPackages': scannedPackages,
      'packagePaths': packagePaths,
      'statistics': {
        'totalDeclared': totalDeclared,
        'totalUsed': totalUsed,
        'totalPotentiallyUsed': totalPotentiallyUsed,
        'totalUnused': totalUnused,
        'scanDurationMs': scanDurationMs,
      },
    };
  }

  /// Convert to CSV string
  String toCsv() {
    final buffer = StringBuffer();
    buffer.writeln('status,path,package,type');

    for (final asset in unusedAssets) {
      buffer.writeln(
        'unused,${asset.path},${asset.packageName ?? ''},${asset.type.name}',
      );
    }

    for (final asset in potentiallyUsedAssets) {
      buffer.writeln(
        'potentially_used,${asset.path},${asset.packageName ?? ''},${asset.type.name}',
      );
    }

    for (final asset in usedAssets) {
      buffer.writeln(
        'used,${asset.path},${asset.packageName ?? ''},${asset.type.name}',
      );
    }

    return buffer.toString();
  }

  /// Merge multiple scan results (for monorepo)
  static ScanResult merge(List<ScanResult> results) {
    final declaredAssets = <Asset>{};
    final usedAssets = <Asset>{};
    final potentiallyUsedAssets = <Asset>{};
    final warnings = <ScanWarning>[];
    final scannedPackages = <String>{};
    final packagePaths = <String, String>{};
    var totalDuration = 0;

    for (final result in results) {
      declaredAssets.addAll(result.declaredAssets);
      usedAssets.addAll(result.usedAssets);
      potentiallyUsedAssets.addAll(result.potentiallyUsedAssets);
      warnings.addAll(result.warnings);
      scannedPackages.addAll(result.scannedPackages);
      packagePaths.addAll(result.packagePaths);
      totalDuration += result.scanDurationMs;
    }

    return ScanResult(
      declaredAssets: declaredAssets,
      usedAssets: usedAssets,
      potentiallyUsedAssets: potentiallyUsedAssets,
      warnings: warnings,
      scannedPackages: scannedPackages.toList(),
      packagePaths: packagePaths,
      scanDurationMs: totalDuration,
    );
  }
}

/// Warning generated during scan
class ScanWarning {
  final ScanWarningType type;
  final String message;
  final String? filePath;
  final int? lineNumber;

  const ScanWarning({
    required this.type,
    required this.message,
    this.filePath,
    this.lineNumber,
  });

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'message': message,
    if (filePath != null) 'filePath': filePath,
    if (lineNumber != null) 'lineNumber': lineNumber,
  };

  @override
  String toString() {
    final location = filePath != null
        ? ' at $filePath${lineNumber != null ? ':$lineNumber' : ''}'
        : '';
    return '[${type.name}] $message$location';
  }
}

/// Types of warnings
enum ScanWarningType {
  /// Dynamic asset path detected (interpolation/concatenation)
  dynamicAssetPath,

  /// Asset declared but file not found
  missingAssetFile,

  /// Could not parse file
  parseError,

  /// Generated asset class detected
  generatedAssetClass,

  /// Conditional import with assets
  conditionalImport,

  /// Asset reference in annotation
  annotationReference,
}
