import 'dart:io';

import 'package:glob/glob.dart';
import 'package:glob/list_local_fs.dart';
import 'package:path/path.dart' as p;

/// Utility functions for file operations
class FileUtils {
  /// Find all Dart files in a directory
  static Future<List<File>> findDartFiles(
    String rootPath, {
    bool includeTests = false,
    bool includeGenerated = false,
    List<String> excludePatterns = const [],
  }) async {
    final files = <File>[];
    final root = Directory(rootPath);

    if (!root.existsSync()) {
      return files;
    }

    // Use a manual traversal to skip excluded directories early
    // This avoids permission errors when trying to list excluded directories
    await _findDartFilesRecursive(
      root,
      rootPath,
      files,
      includeTests: includeTests,
      includeGenerated: includeGenerated,
      excludePatterns: excludePatterns,
    );

    return files;
  }

  /// Recursively find Dart files, skipping excluded directories early
  static Future<void> _findDartFilesRecursive(
    Directory dir,
    String rootPath,
    List<File> files, {
    required bool includeTests,
    required bool includeGenerated,
    required List<String> excludePatterns,
  }) async {
    try {
      await for (final entity in dir.list(followLinks: false)) {
        final relativePath = p.relative(entity.path, from: rootPath);
        final normalizedPath = relativePath.replaceAll('\\', '/');

        // Skip excluded directories early (before recursing into them)
        if (entity is Directory) {
          // Check if this directory should be skipped
          if (_isBuildDirectory(normalizedPath) ||
              _isBuildDirectory('$normalizedPath/') ||
              _matchesExcludePattern(normalizedPath, excludePatterns) ||
              _matchesExcludePattern('$normalizedPath/', excludePatterns)) {
            continue;
          }

          // Recurse into non-excluded directories
          await _findDartFilesRecursive(
            entity,
            rootPath,
            files,
            includeTests: includeTests,
            includeGenerated: includeGenerated,
            excludePatterns: excludePatterns,
          );
          continue;
        }

        if (entity is! File) continue;

        // Skip non-Dart files
        if (!normalizedPath.endsWith('.dart')) continue;

        // Skip test files if not included
        if (!includeTests && _isTestFile(normalizedPath)) continue;

        // Skip generated files if not included
        if (!includeGenerated && _isGeneratedFile(normalizedPath)) continue;

        // Skip files matching exclude patterns
        if (_matchesExcludePattern(normalizedPath, excludePatterns)) continue;

        // Skip build directories (double-check for files)
        if (_isBuildDirectory(normalizedPath)) continue;

        files.add(entity);
      }
    } on FileSystemException {
      // Silently skip directories with permission issues
    }
  }

  /// Find all asset files in a directory
  static Future<List<File>> findAssetFiles(
    String rootPath,
    Set<String> extensions,
  ) async {
    final files = <File>[];
    final root = Directory(rootPath);

    if (!root.existsSync()) {
      return files;
    }

    await for (final entity in root.list(recursive: true)) {
      if (entity is! File) continue;

      final ext = p.extension(entity.path).toLowerCase().replaceAll('.', '');
      if (extensions.contains(ext)) {
        files.add(entity);
      }
    }

    return files;
  }

  /// Expand glob pattern to matching files
  static Future<List<String>> expandGlob(
    String pattern,
    String rootPath,
  ) async {
    final files = <String>[];
    final glob = Glob(pattern);

    await for (final entity in glob.list(root: rootPath)) {
      if (entity is File) {
        files.add(p.relative(entity.path, from: rootPath));
      }
    }

    return files;
  }

  /// Check if a path is a test file
  static bool _isTestFile(String path) {
    return path.contains('/test/') ||
        path.contains('/test_driver/') ||
        path.contains('/integration_test/') ||
        path.endsWith('_test.dart') ||
        path.startsWith('test/');
  }

  /// Check if a path is a generated file
  static bool _isGeneratedFile(String path) {
    return path.endsWith('.g.dart') ||
        path.endsWith('.freezed.dart') ||
        path.endsWith('.gr.dart') ||
        path.endsWith('.gen.dart') ||
        path.endsWith('.mocks.dart') ||
        path.endsWith('.chopper.dart') ||
        path.endsWith('.config.dart') ||
        path.contains('/generated/') ||
        path.contains('/.dart_tool/');
  }

  /// Check if path is in a build directory, SDK directory, or symlink directory
  static bool _isBuildDirectory(String path) {
    return path.contains('/build/') ||
        path.contains('/.dart_tool/') ||
        path.contains('/.fvm/') ||
        path.contains('/.pub-cache/') ||
        path.contains('/.pub/') ||
        path.contains('/flutter_sdk/') ||
        path.contains('/.symlinks/') ||
        path.contains('/ios/.symlinks/') ||
        path.contains('/macos/.symlinks/') ||
        path.contains('/.plugin_symlinks/') ||
        path.startsWith('build/') ||
        path.startsWith('.dart_tool/') ||
        path.startsWith('.fvm/') ||
        path.startsWith('ios/.symlinks/') ||
        path.startsWith('macos/.symlinks/') ||
        path.startsWith('.symlinks/');
  }

  /// Check if path matches any exclude pattern
  static bool _matchesExcludePattern(String path, List<String> patterns) {
    for (final pattern in patterns) {
      final glob = Glob(pattern);
      if (glob.matches(path)) {
        return true;
      }
    }
    return false;
  }

  /// Get file size in bytes
  static int getFileSize(String path) {
    final file = File(path);
    if (file.existsSync()) {
      return file.lengthSync();
    }
    return 0;
  }

  /// Format file size for display
  static String formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// Delete a file safely
  static Future<bool> deleteFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /// Check if a directory contains a pubspec.yaml
  static bool hasPubspec(String dirPath) {
    return File(p.join(dirPath, 'pubspec.yaml')).existsSync();
  }

  /// Normalize path separators
  static String normalizePath(String path) {
    return path.replaceAll('\\', '/');
  }
}
