import 'dart:io';

import 'package:glob/glob.dart';
import 'package:glob/list_local_fs.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Detects and handles Melos monorepo workspaces
class MelosDetector {
  final String rootPath;

  MelosDetector({required this.rootPath});

  /// Check if this is a Melos workspace
  bool get isMelosWorkspace {
    final melosFile = File(p.join(rootPath, 'melos.yaml'));
    return melosFile.existsSync();
  }

  /// Parse melos.yaml and return workspace configuration
  Future<MelosWorkspace?> parseWorkspace() async {
    if (!isMelosWorkspace) {
      return null;
    }

    final melosFile = File(p.join(rootPath, 'melos.yaml'));

    try {
      final content = await melosFile.readAsString();
      final yaml = loadYaml(content) as YamlMap?;

      if (yaml == null) {
        return null;
      }

      final name = yaml['name']?.toString() ?? 'unknown';
      final packagesGlobs = _parsePackagesGlobs(yaml);
      final packages = await _resolvePackages(packagesGlobs);

      return MelosWorkspace(
        name: name,
        rootPath: rootPath,
        packagesGlobs: packagesGlobs,
        packages: packages,
      );
    } catch (e) {
      return null;
    }
  }

  /// Parse the packages glob patterns from melos.yaml
  List<String> _parsePackagesGlobs(YamlMap yaml) {
    final packagesSection = yaml['packages'];

    if (packagesSection == null) {
      // Default Melos pattern
      return ['packages/**'];
    }

    if (packagesSection is YamlList) {
      return packagesSection.map((e) => e.toString()).toList();
    }

    if (packagesSection is String) {
      return [packagesSection];
    }

    return ['packages/**'];
  }

  /// Resolve glob patterns to actual package directories
  Future<List<MelosPackage>> _resolvePackages(List<String> globs) async {
    final packages = <MelosPackage>[];
    final seenPaths = <String>{};

    for (final pattern in globs) {
      // Melos uses glob patterns that end with the package name
      // e.g., "packages/*" or "packages/**"
      final glob = Glob(pattern);

      await for (final entity in glob.list(root: rootPath)) {
        if (entity is Directory) {
          final pubspecPath = p.join(entity.path, 'pubspec.yaml');
          if (File(pubspecPath).existsSync()) {
            final normalizedPath = p.normalize(entity.path);
            if (!seenPaths.contains(normalizedPath)) {
              seenPaths.add(normalizedPath);
              final package = await _parsePackage(entity.path);
              if (package != null) {
                packages.add(package);
              }
            }
          }
        }
      }
    }

    // Sort by path for consistent ordering
    packages.sort((a, b) => a.path.compareTo(b.path));
    return packages;
  }

  /// Parse a single package's pubspec.yaml
  Future<MelosPackage?> _parsePackage(String packagePath) async {
    final pubspecFile = File(p.join(packagePath, 'pubspec.yaml'));

    if (!pubspecFile.existsSync()) {
      return null;
    }

    try {
      final content = await pubspecFile.readAsString();
      final yaml = loadYaml(content) as YamlMap?;

      if (yaml == null) {
        return null;
      }

      final name = yaml['name']?.toString() ?? p.basename(packagePath);
      final relativePath = p.relative(packagePath, from: rootPath);

      return MelosPackage(
        name: name,
        path: packagePath,
        relativePath: relativePath,
      );
    } catch (e) {
      return null;
    }
  }

  /// Find the root project if it has assets (some monorepos have assets in root)
  Future<MelosPackage?> getRootPackage() async {
    final pubspecFile = File(p.join(rootPath, 'pubspec.yaml'));

    if (!pubspecFile.existsSync()) {
      return null;
    }

    try {
      final content = await pubspecFile.readAsString();
      final yaml = loadYaml(content) as YamlMap?;

      if (yaml == null) {
        return null;
      }

      // Check if root has flutter assets
      final flutter = yaml['flutter'] as YamlMap?;
      if (flutter == null) {
        return null;
      }

      final hasAssets = flutter['assets'] != null || flutter['fonts'] != null;
      if (!hasAssets) {
        return null;
      }

      final name = yaml['name']?.toString() ?? 'root';

      return MelosPackage(
        name: name,
        path: rootPath,
        relativePath: '.',
        isRoot: true,
      );
    } catch (e) {
      return null;
    }
  }
}

/// Represents a Melos workspace
class MelosWorkspace {
  final String name;
  final String rootPath;
  final List<String> packagesGlobs;
  final List<MelosPackage> packages;

  const MelosWorkspace({
    required this.name,
    required this.rootPath,
    required this.packagesGlobs,
    required this.packages,
  });

  /// Get all package paths including root if applicable
  List<String> get allPackagePaths => packages.map((p) => p.path).toList();

  @override
  String toString() =>
      'MelosWorkspace(name: $name, packages: ${packages.length})';
}

/// Represents a package within a Melos workspace
class MelosPackage {
  final String name;
  final String path;
  final String relativePath;
  final bool isRoot;

  const MelosPackage({
    required this.name,
    required this.path,
    required this.relativePath,
    this.isRoot = false,
  });

  @override
  String toString() => 'MelosPackage(name: $name, path: $relativePath)';
}
