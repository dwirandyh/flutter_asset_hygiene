import 'dart:io';

import 'package:glob/glob.dart';
import 'package:glob/list_local_fs.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../models/models.dart';

/// Parser for pubspec.yaml to extract declared assets
class PubspecParser {
  final String projectRoot;
  final String? packageName;

  PubspecParser({required this.projectRoot, this.packageName});

  /// Parse pubspec.yaml and return all declared assets
  Future<PubspecParseResult> parse() async {
    final pubspecFile = File(p.join(projectRoot, 'pubspec.yaml'));

    if (!pubspecFile.existsSync()) {
      return PubspecParseResult(
        assets: {},
        fonts: {},
        packageName: packageName,
        warnings: [
          ScanWarning(
            type: ScanWarningType.parseError,
            message: 'pubspec.yaml not found at $projectRoot',
          ),
        ],
      );
    }

    try {
      final content = await pubspecFile.readAsString();
      final yaml = loadYaml(content) as YamlMap?;

      if (yaml == null) {
        return PubspecParseResult(
          assets: {},
          fonts: {},
          packageName: packageName,
          warnings: [
            ScanWarning(
              type: ScanWarningType.parseError,
              message: 'Failed to parse pubspec.yaml',
              filePath: pubspecFile.path,
            ),
          ],
        );
      }

      final parsedPackageName =
          packageName ?? yaml['name']?.toString() ?? 'unknown';
      final flutter = yaml['flutter'] as YamlMap?;

      if (flutter == null) {
        return PubspecParseResult(
          assets: {},
          fonts: {},
          packageName: parsedPackageName,
        );
      }

      final assets = await _parseAssets(flutter, parsedPackageName);
      final fonts = _parseFonts(flutter, parsedPackageName);

      return PubspecParseResult(
        assets: assets.assets,
        fonts: fonts,
        packageName: parsedPackageName,
        warnings: assets.warnings,
      );
    } catch (e) {
      return PubspecParseResult(
        assets: {},
        fonts: {},
        packageName: packageName,
        warnings: [
          ScanWarning(
            type: ScanWarningType.parseError,
            message: 'Error parsing pubspec.yaml: $e',
            filePath: pubspecFile.path,
          ),
        ],
      );
    }
  }

  /// Parse assets section from flutter config
  Future<_AssetParseResult> _parseAssets(
    YamlMap flutter,
    String pkgName,
  ) async {
    final assetsSection = flutter['assets'];
    if (assetsSection == null) {
      return _AssetParseResult(assets: {}, warnings: []);
    }

    final assets = <Asset>{};
    final warnings = <ScanWarning>[];

    if (assetsSection is! YamlList) {
      warnings.add(
        ScanWarning(
          type: ScanWarningType.parseError,
          message: 'Invalid assets section format in pubspec.yaml',
        ),
      );
      return _AssetParseResult(assets: assets, warnings: warnings);
    }

    for (final assetEntry in assetsSection) {
      final assetPath = assetEntry.toString();

      // Check if it's a directory (ends with /)
      if (assetPath.endsWith('/')) {
        // Expand directory to all files
        final expandedAssets = await _expandDirectory(
          assetPath,
          pkgName,
          assetPath,
        );
        assets.addAll(expandedAssets);
      }
      // Check if it contains glob patterns
      else if (_isGlobPattern(assetPath)) {
        final expandedAssets = await _expandGlob(assetPath, pkgName, assetPath);
        assets.addAll(expandedAssets);
      }
      // Single file
      else {
        final fullPath = p.join(projectRoot, assetPath);
        if (File(fullPath).existsSync()) {
          assets.add(
            Asset(
              path: assetPath,
              type: AssetType.fromPath(assetPath),
              packageName: pkgName,
              declaration: assetPath,
            ),
          );
        } else {
          warnings.add(
            ScanWarning(
              type: ScanWarningType.missingAssetFile,
              message: 'Declared asset file not found: $assetPath',
            ),
          );
        }
      }
    }

    return _AssetParseResult(assets: assets, warnings: warnings);
  }

  /// Parse fonts section from flutter config
  Set<Asset> _parseFonts(YamlMap flutter, String pkgName) {
    final fontsSection = flutter['fonts'];
    if (fontsSection == null || fontsSection is! YamlList) {
      return {};
    }

    final fonts = <Asset>{};

    for (final fontFamily in fontsSection) {
      if (fontFamily is! YamlMap) continue;

      final familyName = fontFamily['family']?.toString();
      final fontsList = fontFamily['fonts'];

      if (fontsList is! YamlList) continue;

      for (final fontEntry in fontsList) {
        if (fontEntry is! YamlMap) continue;

        final assetPath = fontEntry['asset']?.toString();
        if (assetPath == null) continue;

        fonts.add(
          Asset(
            path: assetPath,
            type: AssetType.font,
            packageName: pkgName,
            declaration: 'fonts: $familyName - $assetPath',
          ),
        );
      }
    }

    return fonts;
  }

  /// Expand a directory declaration to all contained files
  Future<Set<Asset>> _expandDirectory(
    String dirPath,
    String pkgName,
    String declaration,
  ) async {
    final assets = <Asset>{};
    final fullPath = p.join(projectRoot, dirPath);
    final dir = Directory(fullPath);

    if (!dir.existsSync()) {
      return assets;
    }

    await for (final entity in dir.list(recursive: false)) {
      if (entity is File) {
        // Skip hidden files like .DS_Store
        final fileName = p.basename(entity.path);
        if (fileName.startsWith('.')) continue;

        final relativePath = p
            .relative(entity.path, from: projectRoot)
            .replaceAll('\\', '/');
        assets.add(
          Asset(
            path: relativePath,
            type: AssetType.fromPath(relativePath),
            packageName: pkgName,
            isDeclaredViaGlob: true,
            declaration: declaration,
          ),
        );
      }
    }

    return assets;
  }

  /// Expand a glob pattern to matching files
  Future<Set<Asset>> _expandGlob(
    String pattern,
    String pkgName,
    String declaration,
  ) async {
    final assets = <Asset>{};
    final glob = Glob(pattern);

    await for (final entity in glob.list(root: projectRoot)) {
      if (entity is File) {
        // Skip hidden files like .DS_Store
        final fileName = p.basename(entity.path);
        if (fileName.startsWith('.')) continue;

        final relativePath = p
            .relative(entity.path, from: projectRoot)
            .replaceAll('\\', '/');
        assets.add(
          Asset(
            path: relativePath,
            type: AssetType.fromPath(relativePath),
            packageName: pkgName,
            isDeclaredViaGlob: true,
            declaration: declaration,
          ),
        );
      }
    }

    return assets;
  }

  /// Check if a path contains glob patterns
  bool _isGlobPattern(String path) {
    return path.contains('*') || path.contains('?') || path.contains('[');
  }
}

/// Result of parsing pubspec.yaml
class PubspecParseResult {
  final Set<Asset> assets;
  final Set<Asset> fonts;
  final String? packageName;
  final List<ScanWarning> warnings;

  const PubspecParseResult({
    required this.assets,
    required this.fonts,
    this.packageName,
    this.warnings = const [],
  });

  /// Get all declared assets (assets + fonts)
  Set<Asset> get allAssets => {...assets, ...fonts};
}

class _AssetParseResult {
  final Set<Asset> assets;
  final List<ScanWarning> warnings;

  const _AssetParseResult({required this.assets, required this.warnings});
}
