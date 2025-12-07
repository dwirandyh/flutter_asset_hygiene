import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as p;

import '../models/code_element.dart';
import '../models/code_scan_config.dart';
import '../models/code_scan_result.dart';
import '../utils/logger.dart';

/// Applies auto-fix actions for unused code issues.
class AutoFixer {
  final CodeScanConfig config;
  final Logger logger;

  /// Maximum number of cascading cleanup iterations to prevent infinite loops
  static const int _maxCascadingIterations = 5;

  AutoFixer({required this.config, required this.logger});

  /// Apply fixes for all auto-fixable issues in [scanResult].
  ///
  /// When [dryRun] is true, no files are modified but the plan is returned.
  Future<AutoFixResult> applyFixes(
    CodeScanResult scanResult, {
    bool dryRun = false,
  }) async {
    final fixableIssues = scanResult.issues.where((i) => i.canAutoFix).toList();
    if (fixableIssues.isEmpty) {
      logger.info('No auto-fixable issues found.');
      return AutoFixResult.empty(dryRun: dryRun);
    }

    final issuesByFile = _groupIssuesByFile(fixableIssues, scanResult);
    final appliedIssues = <String, List<CodeIssue>>{};
    final skippedIssues = <CodeIssue>[];
    var filesChanged = 0;
    var filesDeleted = 0;
    var appliedRanges = 0;

    for (final entry in issuesByFile.entries) {
      final file = File(entry.key);
      if (!file.existsSync()) {
        logger.warning('File not found for auto-fix: ${entry.key}');
        skippedIssues.addAll(entry.value);
        continue;
      }

      final original = await file.readAsString();
      final contentLength = original.length;

      // Validate and filter ranges that are within bounds
      final ranges = _buildRanges(entry.value, contentLength);
      if (ranges.isEmpty) {
        skippedIssues.addAll(entry.value);
        continue;
      }

      // Check if we should delete the entire file
      // This happens when the file only contains the unused class/code
      if (_shouldDeleteFile(original, ranges, entry.value)) {
        if (dryRun) {
          logger.info('Would delete file: ${_relativePath(entry.key)}');
          appliedIssues[entry.key] = entry.value;
          continue;
        }

        await file.delete();
        appliedIssues[entry.key] = entry.value;
        filesDeleted++;
        logger.success('Deleted file: ${_relativePath(entry.key)}');
        continue;
      }

      final updated = _applyRanges(original, ranges);
      appliedRanges += ranges.length;

      if (dryRun) {
        appliedIssues[entry.key] = entry.value;
        continue;
      }

      if (updated == original) {
        skippedIssues.addAll(entry.value);
        continue;
      }

      await file.writeAsString(updated);
      appliedIssues[entry.key] = entry.value;
      filesChanged++;

      logger.success(
        'Fixed ${ranges.length} issue(s) in ${_relativePath(entry.key)}',
      );

      // Perform cascading cleanup on the modified file
      // Skip cascading cleanup if the file has import-related issues
      // as it can cause problems with import directive ordering
      final hasImportIssues = entry.value.any(
        (issue) => issue.category == IssueCategory.unusedImport,
      );
      if (!hasImportIssues) {
        final cascadingResult = await _performCascadingCleanup(
          entry.key,
          dryRun: dryRun,
        );
        appliedRanges += cascadingResult.removedCount;
      }
    }

    if (dryRun) {
      logger.info(
        'Would fix ${fixableIssues.length} issue(s) across ${appliedIssues.length} file(s).',
      );
    }

    return AutoFixResult(
      fileIssues: appliedIssues,
      skippedIssues: skippedIssues,
      filesChanged: filesChanged,
      filesDeleted: filesDeleted,
      appliedRanges: appliedRanges,
      dryRun: dryRun,
    );
  }

  Map<String, List<CodeIssue>> _groupIssuesByFile(
    List<CodeIssue> issues,
    CodeScanResult scanResult,
  ) {
    final grouped = <String, List<CodeIssue>>{};

    for (final issue in issues) {
      final filePath = _resolveFilePath(issue, scanResult);
      if (filePath == null) {
        logger.debug(
          'Skipping issue ${issue.symbol} - unable to resolve file path',
        );
        continue;
      }
      grouped.putIfAbsent(filePath, () => []).add(issue);
    }

    return grouped;
  }

  String? _resolveFilePath(CodeIssue issue, CodeScanResult scanResult) {
    final filePath = issue.location.filePath;

    // Skip symlink paths - they should not be auto-fixed (the real files should)
    if (filePath.contains('/.symlinks/') ||
        filePath.contains('.symlinks/') ||
        filePath.startsWith('ios/.symlinks/') ||
        filePath.startsWith('macos/.symlinks/')) {
      logger.debug('Skipping symlink path: $filePath');
      return null;
    }

    final basePath = issue.packageName != null
        ? scanResult.packagePaths[issue.packageName]
        : config.rootPath;

    if (basePath == null) {
      // Try directly with rootPath even if packageName lookup failed
      final directPath = p.normalize(p.join(config.rootPath, filePath));
      if (File(directPath).existsSync()) {
        return directPath;
      }
      return null;
    }

    // Try 1: The filePath is already relative to workspace root
    final resolvedPath = p.normalize(p.join(config.rootPath, filePath));
    if (File(resolvedPath).existsSync()) {
      return resolvedPath;
    }

    // Try 2: The filePath is relative to package path
    final packagePath = p.normalize(p.join(basePath, filePath));
    if (File(packagePath).existsSync()) {
      return packagePath;
    }

    // Try 3: Strip redundant package prefix from filePath
    // e.g., if filePath is "packages/X/lib/..." and basePath already contains "packages/X"
    final filePathParts = filePath.split('/');
    if (filePathParts.length > 2 && filePathParts[0] == 'packages') {
      final packagePrefix = 'packages/${filePathParts[1]}';
      if (basePath.endsWith(packagePrefix) ||
          basePath.contains('/$packagePrefix')) {
        final strippedPath = filePathParts.skip(2).join('/');
        final strippedResolvedPath = p.normalize(
          p.join(basePath, strippedPath),
        );
        if (File(strippedResolvedPath).existsSync()) {
          return strippedResolvedPath;
        }
      }
    }

    // Try 4: If filePath starts with lib/, try joining with package path
    if (filePath.startsWith('lib/')) {
      final libPath = p.normalize(p.join(basePath, filePath));
      if (File(libPath).existsSync()) {
        return libPath;
      }
    }

    // Try 5: Extract just the lib/... portion from any path
    final libIndex = filePath.indexOf('/lib/');
    if (libIndex != -1) {
      final libPortion = filePath.substring(libIndex + 1); // removes leading /
      final libPathFromPackage = p.normalize(p.join(basePath, libPortion));
      if (File(libPathFromPackage).existsSync()) {
        return libPathFromPackage;
      }
    }

    // If file is absolute and exists, use it directly
    if (p.isAbsolute(filePath) && File(filePath).existsSync()) {
      return filePath;
    }

    logger.debug(
      'Could not resolve file path: $filePath (basePath: $basePath, rootPath: ${config.rootPath})',
    );
    return null;
  }

  List<_FixRange> _buildRanges(List<CodeIssue> issues, int contentLength) {
    final ranges = <_FixRange>[];
    for (final issue in issues) {
      final offset = issue.location.offset;
      final length = issue.location.length;

      if (length <= 0) {
        logger.debug(
          'Skipping zero-length range for ${issue.symbol} at ${issue.location}',
        );
        continue;
      }

      // Validate that the range is within the file bounds
      if (offset < 0 || offset >= contentLength) {
        logger.debug(
          'Skipping out-of-bounds offset for ${issue.symbol}: offset=$offset, fileLength=$contentLength',
        );
        continue;
      }

      // Clamp the end to file bounds
      final clampedLength = (offset + length > contentLength)
          ? contentLength - offset
          : length;

      if (clampedLength <= 0) {
        logger.debug(
          'Skipping invalid range for ${issue.symbol} after clamping',
        );
        continue;
      }

      ranges.add(
        _FixRange(offset: offset, length: clampedLength, issue: issue),
      );
    }

    return _mergeOverlapping(ranges);
  }

  /// Check if we should delete the entire file instead of just removing code.
  ///
  /// Returns true if:
  /// - The file contains only the unused class/code (after removing it, file would be empty)
  /// - The file contains only imports and the unused class
  bool _shouldDeleteFile(
    String content,
    List<_FixRange> ranges,
    List<CodeIssue> issues,
  ) {
    // Check if any issue is a class/enum/mixin/extension that spans most of the file
    for (final issue in issues) {
      if (_isTopLevelDeclaration(issue.category)) {
        // Calculate what would remain after removing this declaration
        final remaining = _calculateRemainingContent(content, ranges);
        if (_isEffectivelyEmpty(remaining)) {
          return true;
        }
      }
    }
    return false;
  }

  /// Check if the issue category is a top-level declaration
  bool _isTopLevelDeclaration(IssueCategory category) {
    return category == IssueCategory.unusedClass ||
        category == IssueCategory.unusedMixin ||
        category == IssueCategory.unusedExtension ||
        category == IssueCategory.unusedEnum ||
        category == IssueCategory.unusedTypedef;
  }

  /// Calculate what content would remain after applying all ranges
  String _calculateRemainingContent(String content, List<_FixRange> ranges) {
    var result = content;

    // Apply from the end backward
    final sortedRanges = List<_FixRange>.from(ranges)
      ..sort((a, b) => b.offset.compareTo(a.offset));

    for (final range in sortedRanges) {
      final expanded = _expandToLineBounds(result, range.offset, range.end);
      if (expanded.start < result.length && expanded.end <= result.length) {
        result = result.replaceRange(expanded.start, expanded.end, '');
      }
    }

    return _collapseBlankLines(result);
  }

  /// Check if the remaining content is effectively empty (only imports/comments)
  bool _isEffectivelyEmpty(String content) {
    // Remove all imports, exports, parts, and library directives
    var stripped = content
        .replaceAll(
          RegExp(r"^\s*import\s+'[^']*'[^;]*;\s*$", multiLine: true),
          '',
        )
        .replaceAll(
          RegExp(r'^\s*import\s+"[^"]*"[^;]*;\s*$', multiLine: true),
          '',
        )
        .replaceAll(
          RegExp(r"^\s*export\s+'[^']*'[^;]*;\s*$", multiLine: true),
          '',
        )
        .replaceAll(
          RegExp(r'^\s*export\s+"[^"]*"[^;]*;\s*$', multiLine: true),
          '',
        )
        .replaceAll(RegExp(r"^\s*part\s+'[^']*';\s*$", multiLine: true), '')
        .replaceAll(RegExp(r'^\s*part\s+"[^"]*";\s*$', multiLine: true), '')
        .replaceAll(
          RegExp(r"^\s*part\s+of\s+'[^']*';\s*$", multiLine: true),
          '',
        )
        .replaceAll(
          RegExp(r'^\s*part\s+of\s+"[^"]*";\s*$', multiLine: true),
          '',
        )
        .replaceAll(RegExp(r'^\s*part\s+of\s+\w+;\s*$', multiLine: true), '')
        .replaceAll(RegExp(r'^\s*library\s+[^;]*;\s*$', multiLine: true), '');

    // Remove comments
    stripped = stripped
        .replaceAll(RegExp(r'//.*$', multiLine: true), '')
        .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');

    // Check if anything meaningful remains
    return stripped.trim().isEmpty;
  }

  List<_FixRange> _mergeOverlapping(List<_FixRange> ranges) {
    if (ranges.isEmpty) return ranges;

    ranges.sort((a, b) => a.offset.compareTo(b.offset));
    final merged = <_FixRange>[ranges.first];

    for (var i = 1; i < ranges.length; i++) {
      final current = ranges[i];
      final last = merged.last;

      if (current.offset <= last.end) {
        final extendedEnd = current.end > last.end ? current.end : last.end;
        merged[merged.length - 1] = last.copyWith(
          length: extendedEnd - last.offset,
        );
      } else {
        merged.add(current);
      }
    }

    return merged;
  }

  String _applyRanges(String content, List<_FixRange> ranges) {
    var updated = content;

    // First, expand all ranges to line bounds and collect them
    // This must be done on the ORIGINAL content before any modifications
    final expandedRanges = <_Range>[];
    for (final range in ranges) {
      final expanded = _expandToLineBounds(content, range.offset, range.end);
      expandedRanges.add(expanded);
    }

    // Merge overlapping expanded ranges
    final mergedRanges = _mergeExpandedRanges(expandedRanges);

    // Apply from the end of the file backward so offsets stay valid.
    mergedRanges.sort((a, b) => b.start.compareTo(a.start));

    for (final range in mergedRanges) {
      // Validate range is within bounds
      if (range.start >= 0 &&
          range.end <= updated.length &&
          range.start < range.end) {
        updated = updated.replaceRange(range.start, range.end, '');
      }
    }

    return _collapseBlankLines(updated);
  }

  /// Merge overlapping expanded ranges
  List<_Range> _mergeExpandedRanges(List<_Range> ranges) {
    if (ranges.isEmpty) return ranges;

    // Sort by start position
    final sorted = List<_Range>.from(ranges)
      ..sort((a, b) => a.start.compareTo(b.start));

    final merged = <_Range>[sorted.first];

    for (var i = 1; i < sorted.length; i++) {
      final current = sorted[i];
      final last = merged.last;

      // Check if ranges overlap or are adjacent
      if (current.start <= last.end) {
        // Merge by extending the end
        final newEnd = current.end > last.end ? current.end : last.end;
        merged[merged.length - 1] = _Range(start: last.start, end: newEnd);
      } else {
        merged.add(current);
      }
    }

    return merged;
  }

  _Range _expandToLineBounds(String content, int start, int end) {
    // Find the start of the line containing `start`
    var lineStart = start <= 0 ? 0 : content.lastIndexOf('\n', start - 1);
    lineStart = lineStart == -1 ? 0 : lineStart + 1;

    // Expand backward to include preceding doc comments and blank lines
    // This handles cases where doc comments are on separate lines before the declaration
    lineStart = _expandToIncludePrecedingDocComments(content, lineStart);

    // SAFETY: Never expand into import/export/part directives at the top of the file
    // Check if the expanded range would include any directives
    lineStart = _preventDirectiveInclusion(content, lineStart);

    // Find the end of the line containing `end`
    var lineEnd = content.indexOf('\n', end);
    if (lineEnd == -1) {
      lineEnd = content.length;
    } else {
      // Include the trailing newline so we do not leave empty lines behind.
      lineEnd += 1;
    }

    return _Range(start: lineStart, end: lineEnd);
  }

  /// Prevent the range from including import/export/part directives
  int _preventDirectiveInclusion(String content, int lineStart) {
    if (lineStart <= 0) return lineStart;

    // Get the content from lineStart to find if we're including a directive
    final lineEndIndex = content.indexOf('\n', lineStart);
    if (lineEndIndex == -1) return lineStart;

    final line = content.substring(lineStart, lineEndIndex).trim();

    // If this line is a directive, move forward to after the directives
    if (line.startsWith('import ') ||
        line.startsWith("import '") ||
        line.startsWith('import "') ||
        line.startsWith('export ') ||
        line.startsWith("export '") ||
        line.startsWith('export "') ||
        line.startsWith('part ') ||
        line.startsWith("part '") ||
        line.startsWith('part "') ||
        line.startsWith('library ')) {
      // Find the next non-directive line
      var nextLineStart = lineEndIndex + 1;
      while (nextLineStart < content.length) {
        final nextLineEnd = content.indexOf('\n', nextLineStart);
        if (nextLineEnd == -1) break;

        final nextLine = content.substring(nextLineStart, nextLineEnd).trim();

        if (nextLine.isEmpty ||
            nextLine.startsWith('import ') ||
            nextLine.startsWith("import '") ||
            nextLine.startsWith('import "') ||
            nextLine.startsWith('export ') ||
            nextLine.startsWith("export '") ||
            nextLine.startsWith('export "') ||
            nextLine.startsWith('part ') ||
            nextLine.startsWith("part '") ||
            nextLine.startsWith('part "') ||
            nextLine.startsWith('library ')) {
          nextLineStart = nextLineEnd + 1;
        } else {
          // Found a non-directive line, return this position
          return nextLineStart;
        }
      }
    }

    return lineStart;
  }

  /// Expand backward to include doc comments and annotations preceding a declaration
  int _expandToIncludePrecedingDocComments(String content, int lineStart) {
    if (lineStart <= 0) return 0;

    var currentLineStart = lineStart;

    // Look at preceding lines and include doc comments, annotations, and blank lines
    while (currentLineStart > 0) {
      // Find the start of the previous line
      var prevLineEnd = currentLineStart - 1;
      if (prevLineEnd < 0) break;

      // Guard against out-of-bounds access
      if (prevLineEnd >= content.length) {
        prevLineEnd = content.length - 1;
      }

      var prevLineStart = content.lastIndexOf('\n', prevLineEnd);
      if (prevLineStart < 0) {
        prevLineStart = 0;
      } else {
        prevLineStart = prevLineStart + 1;
      }

      // Make sure we don't go backwards forever
      if (prevLineStart >= currentLineStart) {
        break;
      }

      // Get the content of the previous line
      final endIndex = currentLineStart > content.length
          ? content.length
          : currentLineStart;
      if (prevLineStart > endIndex) {
        break;
      }

      final prevLine = content.substring(prevLineStart, endIndex).trim();

      // Include if it's a doc comment, annotation, or blank line
      if (prevLine.isEmpty ||
          prevLine.startsWith('///') ||
          prevLine.startsWith('//') ||
          prevLine.startsWith('/*') ||
          prevLine.startsWith('*') ||
          prevLine.startsWith('@') ||
          prevLine.endsWith('*/')) {
        currentLineStart = prevLineStart;
      } else {
        // Stop if we hit actual code
        break;
      }
    }

    return currentLineStart;
  }

  String _collapseBlankLines(String content) {
    return content.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  }

  /// Perform cascading cleanup to remove orphaned code after initial fixes.
  ///
  /// This handles:
  /// - Fields that are no longer used after method removal
  /// - Private methods that are no longer called after public method removal
  /// - Imports that are no longer used after code removal
  Future<_CascadingCleanupResult> _performCascadingCleanup(
    String filePath, {
    bool dryRun = false,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      return _CascadingCleanupResult.empty();
    }

    var totalRemoved = 0;
    final removedItems = <String>[];

    // Iterate until no more orphaned code is found (with a max limit)
    for (var iteration = 0; iteration < _maxCascadingIterations; iteration++) {
      final content = await file.readAsString();

      // Skip if file is effectively empty (only whitespace/comments)
      if (_isEffectivelyEmpty(content)) {
        logger.debug('Skipping cascading cleanup - file is effectively empty');
        break;
      }

      // Parse the file - use throwIfDiagnostics: false to handle invalid content
      ParseStringResult parseResult;
      try {
        parseResult = parseString(content: content, throwIfDiagnostics: false);
      } catch (e) {
        logger.debug(
          'Skipping cascading cleanup due to parse exception in $filePath: $e',
        );
        break;
      }

      if (parseResult.errors.isNotEmpty) {
        logger.debug(
          'Skipping cascading cleanup due to parse errors in $filePath',
        );
        break;
      }

      // Collect all references in the file
      final refVisitor = _ReferenceCollectorVisitor();
      parseResult.unit.visitChildren(refVisitor);

      // Find orphaned elements (fields, private methods)
      // NOTE: We don't cleanup imports here as it's too error-prone
      // without full semantic analysis
      final orphanVisitor = _OrphanedElementVisitor(
        referencedIdentifiers: refVisitor.referencedIdentifiers,
      );
      parseResult.unit.visitChildren(orphanVisitor);

      final allOrphaned = orphanVisitor.orphanedElements;

      if (allOrphaned.isEmpty) {
        break; // No more orphaned code
      }

      // Build ranges for removal
      final ranges = <_FixRange>[];
      for (final orphan in allOrphaned) {
        // Validate range
        if (orphan.offset < 0 || orphan.offset >= content.length) {
          continue;
        }

        final clampedLength = (orphan.offset + orphan.length > content.length)
            ? content.length - orphan.offset
            : orphan.length;

        if (clampedLength <= 0) continue;

        ranges.add(
          _FixRange(
            offset: orphan.offset,
            length: clampedLength,
            issue: CodeIssue(
              category: IssueCategory.unusedField,
              severity: IssueSeverity.warning,
              symbol: orphan.name,
              location: SourceLocation(
                filePath: filePath,
                line: 0,
                column: 0,
                offset: orphan.offset,
                length: clampedLength,
              ),
              message: 'Orphaned ${orphan.type}: ${orphan.name}',
            ),
          ),
        );

        removedItems.add('${orphan.type}: ${orphan.name}');
      }

      if (ranges.isEmpty) {
        break;
      }

      // Merge overlapping ranges
      final mergedRanges = _mergeOverlapping(ranges);

      // Apply the removal
      final updated = _applyRanges(content, mergedRanges);

      if (updated == content) {
        break; // No changes made
      }

      if (!dryRun) {
        await file.writeAsString(updated);
        totalRemoved += mergedRanges.length;

        logger.debug(
          'Cascading cleanup: removed ${mergedRanges.length} orphaned item(s) from ${_relativePath(filePath)}',
        );
      } else {
        totalRemoved += mergedRanges.length;
        break; // Don't iterate in dry run mode
      }
    }

    return _CascadingCleanupResult(
      removedCount: totalRemoved,
      removedItems: removedItems,
    );
  }

  String _relativePath(String absolutePath) {
    try {
      return p.relative(absolutePath, from: config.rootPath);
    } catch (_) {
      return absolutePath;
    }
  }
}

/// Result of an auto-fix attempt.
class AutoFixResult {
  final Map<String, List<CodeIssue>> fileIssues;
  final List<CodeIssue> skippedIssues;
  final int filesChanged;
  final int filesDeleted;
  final int appliedRanges;
  final bool dryRun;

  AutoFixResult({
    required this.fileIssues,
    required this.skippedIssues,
    required this.filesChanged,
    this.filesDeleted = 0,
    required this.appliedRanges,
    required this.dryRun,
  });

  factory AutoFixResult.empty({bool dryRun = false}) => AutoFixResult(
    fileIssues: const {},
    skippedIssues: const [],
    filesChanged: 0,
    filesDeleted: 0,
    appliedRanges: 0,
    dryRun: dryRun,
  );

  int get totalIssues =>
      fileIssues.values.fold(0, (sum, list) => sum + list.length);
}

class _FixRange {
  final int offset;
  final int length;
  final CodeIssue issue;

  _FixRange({required this.offset, required this.length, required this.issue});

  int get end => offset + length;

  _FixRange copyWith({int? offset, int? length}) {
    return _FixRange(
      offset: offset ?? this.offset,
      length: length ?? this.length,
      issue: issue,
    );
  }
}

class _Range {
  final int start;
  final int end;

  const _Range({required this.start, required this.end});
}

/// Result of cascading cleanup
class _CascadingCleanupResult {
  final int removedCount;
  final List<String> removedItems;

  const _CascadingCleanupResult({
    required this.removedCount,
    required this.removedItems,
  });

  factory _CascadingCleanupResult.empty() =>
      const _CascadingCleanupResult(removedCount: 0, removedItems: []);
}

/// Information about an orphaned element
class _OrphanedElement {
  final String name;
  final int offset;
  final int length;
  final String type;

  const _OrphanedElement({
    required this.name,
    required this.offset,
    required this.length,
    required this.type,
  });
}

/// Visitor to collect all references within a compilation unit
class _ReferenceCollectorVisitor extends RecursiveAstVisitor<void> {
  final Set<String> referencedIdentifiers = {};
  final Set<String> declaredIdentifiers = {};

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    // Skip if this is a declaration
    if (node.inDeclarationContext()) {
      declaredIdentifiers.add(node.name);
    } else {
      referencedIdentifiers.add(node.name);
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    // Add both the prefix and the identifier
    referencedIdentifiers.add(node.prefix.name);
    referencedIdentifiers.add(node.identifier.name);
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    referencedIdentifiers.add(node.propertyName.name);
    super.visitPropertyAccess(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    referencedIdentifiers.add(node.methodName.name);
    super.visitMethodInvocation(node);
  }

  @override
  void visitConstructorFieldInitializer(ConstructorFieldInitializer node) {
    // Field initializers like `this._field = value` reference the field
    referencedIdentifiers.add(node.fieldName.name);
    super.visitConstructorFieldInitializer(node);
  }

  @override
  void visitFieldFormalParameter(FieldFormalParameter node) {
    // Constructor parameters like `this.field` reference the field
    referencedIdentifiers.add(node.name.lexeme);
    super.visitFieldFormalParameter(node);
  }

  @override
  void visitSuperFormalParameter(SuperFormalParameter node) {
    // Super parameters like `super.field` reference parent field
    referencedIdentifiers.add(node.name.lexeme);
    super.visitSuperFormalParameter(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    // Mark constructor parameters as referenced
    for (final param in node.parameters.parameters) {
      if (param is FieldFormalParameter) {
        referencedIdentifiers.add(param.name.lexeme);
      } else if (param is DefaultFormalParameter) {
        final innerParam = param.parameter;
        if (innerParam is FieldFormalParameter) {
          referencedIdentifiers.add(innerParam.name.lexeme);
        }
      }
    }

    // Also check initializer list for field assignments
    for (final initializer in node.initializers) {
      if (initializer is ConstructorFieldInitializer) {
        referencedIdentifiers.add(initializer.fieldName.name);
      }
    }

    super.visitConstructorDeclaration(node);
  }
}

/// Visitor to collect orphaned elements (unused fields, private methods)
class _OrphanedElementVisitor extends RecursiveAstVisitor<void> {
  final Set<String> referencedIdentifiers;
  final List<_OrphanedElement> orphanedElements = [];

  _OrphanedElementVisitor({required this.referencedIdentifiers});

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    // IMPORTANT: Skip static fields as they can be accessed from other files
    // Cascading cleanup only analyzes the current file, so we can't safely
    // determine if a static field is truly unused across the entire codebase
    if (node.isStatic) {
      super.visitFieldDeclaration(node);
      return;
    }

    for (final variable in node.fields.variables) {
      final name = variable.name.lexeme;
      // Check if this field is referenced anywhere in this file
      if (!referencedIdentifiers.contains(name)) {
        orphanedElements.add(
          _OrphanedElement(
            name: name,
            offset: node.offset,
            length: node.length,
            type: 'field',
          ),
        );
      }
    }
    super.visitFieldDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    final name = node.name.lexeme;

    // Skip public static methods as they can be accessed from other files
    // But private static methods (starting with _) are safe to remove
    // since they can only be accessed within the same file
    if (node.isStatic && !name.startsWith('_')) {
      super.visitMethodDeclaration(node);
      return;
    }

    // Only consider private methods for orphan detection
    if (name.startsWith('_') && !referencedIdentifiers.contains(name)) {
      orphanedElements.add(
        _OrphanedElement(
          name: name,
          offset: node.offset,
          length: node.length,
          type: 'method',
        ),
      );
    }
    super.visitMethodDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    final name = node.name.lexeme;
    // Only consider private functions for orphan detection
    if (name.startsWith('_') && !referencedIdentifiers.contains(name)) {
      orphanedElements.add(
        _OrphanedElement(
          name: name,
          offset: node.offset,
          length: node.length,
          type: 'function',
        ),
      );
    }
    super.visitFunctionDeclaration(node);
  }

  // NOTE: Import cleanup is intentionally NOT done in cascading cleanup
  // because it's too error-prone without full semantic analysis.
  // The initial unused import detection handles this more accurately.
  // Orphaned imports after code removal will be caught by dart analyzer
  // or a subsequent run of this tool.
}
