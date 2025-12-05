import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/code_element.dart';
import '../models/code_scan_config.dart';
import '../models/code_scan_result.dart';
import '../utils/logger.dart';

/// Applies auto-fix actions for unused code issues.
class AutoFixer {
  final CodeScanConfig config;
  final Logger logger;

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
    var appliedRanges = 0;

    for (final entry in issuesByFile.entries) {
      final file = File(entry.key);
      if (!file.existsSync()) {
        logger.warning('File not found for auto-fix: ${entry.key}');
        skippedIssues.addAll(entry.value);
        continue;
      }

      final original = await file.readAsString();
      final ranges = _buildRanges(entry.value);
      if (ranges.isEmpty) {
        skippedIssues.addAll(entry.value);
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
    final basePath = issue.packageName != null
        ? scanResult.packagePaths[issue.packageName]
        : config.rootPath;

    if (basePath == null) return null;
    return p.normalize(p.join(basePath, issue.location.filePath));
  }

  List<_FixRange> _buildRanges(List<CodeIssue> issues) {
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
      ranges.add(_FixRange(offset: offset, length: length, issue: issue));
    }

    return _mergeOverlapping(ranges);
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

    // Apply from the end of the file backward so offsets stay valid.
    ranges.sort((a, b) => b.offset.compareTo(a.offset));

    for (final range in ranges) {
      final expanded = _expandToLineBounds(updated, range.offset, range.end);
      updated = updated.replaceRange(expanded.start, expanded.end, '');
    }

    return _collapseBlankLines(updated);
  }

  _Range _expandToLineBounds(String content, int start, int end) {
    var lineStart = start <= 0 ? 0 : content.lastIndexOf('\n', start - 1);
    lineStart = lineStart == -1 ? 0 : lineStart + 1;

    var lineEnd = content.indexOf('\n', end);
    if (lineEnd == -1) {
      lineEnd = content.length;
    } else {
      // Include the trailing newline so we do not leave empty lines behind.
      lineEnd += 1;
    }

    return _Range(start: lineStart, end: lineEnd);
  }

  String _collapseBlankLines(String content) {
    return content.replaceAll(RegExp(r'\n{3,}'), '\n\n');
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
  final int appliedRanges;
  final bool dryRun;

  AutoFixResult({
    required this.fileIssues,
    required this.skippedIssues,
    required this.filesChanged,
    required this.appliedRanges,
    required this.dryRun,
  });

  factory AutoFixResult.empty({bool dryRun = false}) => AutoFixResult(
    fileIssues: const {},
    skippedIssues: const [],
    filesChanged: 0,
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
