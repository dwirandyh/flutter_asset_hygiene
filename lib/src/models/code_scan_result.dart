import 'code_element.dart';

/// Result of unused code analysis
class CodeScanResult {
  /// All issues found
  final List<CodeIssue> issues;

  /// All declarations found
  final Set<CodeElement> declarations;

  /// All references found
  final Set<CodeReference> references;

  /// Statistics about the scan
  final ScanStatistics statistics;

  /// Packages that were scanned
  final List<String> scannedPackages;

  /// Map of package name to path
  final Map<String, String> packagePaths;

  /// Warnings generated during scan
  final List<String> warnings;

  const CodeScanResult({
    required this.issues,
    this.declarations = const {},
    this.references = const {},
    required this.statistics,
    this.scannedPackages = const [],
    this.packagePaths = const {},
    this.warnings = const [],
  });

  /// Filter issues by minimum severity
  List<CodeIssue> issuesWithMinSeverity(IssueSeverity minSeverity) {
    return issues.where((issue) {
      switch (minSeverity) {
        case IssueSeverity.error:
          return issue.severity == IssueSeverity.error;
        case IssueSeverity.warning:
          return issue.severity == IssueSeverity.error ||
              issue.severity == IssueSeverity.warning;
        case IssueSeverity.info:
          return true;
      }
    }).toList();
  }

  /// Group issues by file
  Map<String, List<CodeIssue>> get issuesByFile {
    final result = <String, List<CodeIssue>>{};
    for (final issue in issues) {
      result.putIfAbsent(issue.location.filePath, () => []).add(issue);
    }
    return result;
  }

  /// Group issues by category
  Map<IssueCategory, List<CodeIssue>> get issuesByCategory {
    final result = <IssueCategory, List<CodeIssue>>{};
    for (final issue in issues) {
      result.putIfAbsent(issue.category, () => []).add(issue);
    }
    return result;
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'version': '1.0.0',
      'scanDate': DateTime.now().toIso8601String(),
      'issues': issues.map((i) => i.toJson()).toList(),
      'statistics': statistics.toJson(),
      'scannedPackages': scannedPackages,
      'packagePaths': packagePaths,
      'warnings': warnings,
    };
  }

  /// Convert to CSV
  String toCsv() {
    final buffer = StringBuffer();
    buffer.writeln('category,severity,symbol,file,line,column,message,suggestion');

    for (final issue in issues) {
      final escapedMessage = _escapeCsv(issue.message);
      final escapedSuggestion = _escapeCsv(issue.suggestion ?? '');
      buffer.writeln(
        '${issue.category.name},${issue.severity.name},${issue.symbol},'
        '${issue.location.filePath},${issue.location.line},${issue.location.column},'
        '$escapedMessage,$escapedSuggestion',
      );
    }

    return buffer.toString();
  }

  String _escapeCsv(String value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }

  /// Convert to HTML report
  String toHtml() {
    final buffer = StringBuffer();
    buffer.writeln('''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Unused Code Analysis Report</title>
  <style>
    :root {
      --bg-primary: #1a1a2e;
      --bg-secondary: #16213e;
      --bg-card: #0f3460;
      --text-primary: #eaeaea;
      --text-secondary: #a0a0a0;
      --accent: #e94560;
      --warning: #ffc107;
      --info: #17a2b8;
      --success: #28a745;
      --border: #2a2a4a;
    }
    
    * {
      margin: 0;
      padding: 0;
      box-sizing: border-box;
    }
    
    body {
      font-family: 'SF Mono', 'Fira Code', 'Consolas', monospace;
      background: var(--bg-primary);
      color: var(--text-primary);
      line-height: 1.6;
      padding: 2rem;
    }
    
    .container {
      max-width: 1200px;
      margin: 0 auto;
    }
    
    h1 {
      font-size: 2rem;
      margin-bottom: 0.5rem;
      color: var(--accent);
    }
    
    .subtitle {
      color: var(--text-secondary);
      margin-bottom: 2rem;
    }
    
    .stats-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
      gap: 1rem;
      margin-bottom: 2rem;
    }
    
    .stat-card {
      background: var(--bg-card);
      padding: 1rem;
      border-radius: 8px;
      text-align: center;
      border: 1px solid var(--border);
    }
    
    .stat-value {
      font-size: 2rem;
      font-weight: bold;
      color: var(--accent);
    }
    
    .stat-label {
      color: var(--text-secondary);
      font-size: 0.85rem;
    }
    
    .file-section {
      background: var(--bg-secondary);
      border-radius: 8px;
      margin-bottom: 1rem;
      border: 1px solid var(--border);
      overflow: hidden;
    }
    
    .file-header {
      background: var(--bg-card);
      padding: 0.75rem 1rem;
      font-weight: bold;
      display: flex;
      align-items: center;
      gap: 0.5rem;
    }
    
    .file-icon {
      color: var(--accent);
    }
    
    .issue-list {
      padding: 0.5rem 0;
    }
    
    .issue {
      padding: 0.75rem 1rem;
      border-bottom: 1px solid var(--border);
      display: grid;
      grid-template-columns: auto 1fr auto;
      gap: 1rem;
      align-items: start;
    }
    
    .issue:last-child {
      border-bottom: none;
    }
    
    .severity {
      padding: 0.25rem 0.5rem;
      border-radius: 4px;
      font-size: 0.75rem;
      font-weight: bold;
      text-transform: uppercase;
    }
    
    .severity-error {
      background: var(--accent);
      color: white;
    }
    
    .severity-warning {
      background: var(--warning);
      color: black;
    }
    
    .severity-info {
      background: var(--info);
      color: white;
    }
    
    .issue-content {
      flex: 1;
    }
    
    .issue-symbol {
      font-weight: bold;
      color: var(--text-primary);
    }
    
    .issue-message {
      color: var(--text-secondary);
      font-size: 0.9rem;
    }
    
    .issue-location {
      color: var(--text-secondary);
      font-size: 0.85rem;
    }
    
    .category-tag {
      background: var(--bg-primary);
      padding: 0.25rem 0.5rem;
      border-radius: 4px;
      font-size: 0.75rem;
      color: var(--text-secondary);
    }
    
    .footer {
      margin-top: 2rem;
      text-align: center;
      color: var(--text-secondary);
      font-size: 0.85rem;
    }
  </style>
</head>
<body>
  <div class="container">
    <h1>🔍 Unused Code Analysis</h1>
    <p class="subtitle">Generated on ${DateTime.now().toIso8601String()}</p>
    
    <div class="stats-grid">
      <div class="stat-card">
        <div class="stat-value">${statistics.filesScanned}</div>
        <div class="stat-label">Files Scanned</div>
      </div>
      <div class="stat-card">
        <div class="stat-value">${statistics.totalIssues}</div>
        <div class="stat-label">Total Issues</div>
      </div>
      <div class="stat-card">
        <div class="stat-value">${statistics.unusedClasses}</div>
        <div class="stat-label">Unused Classes</div>
      </div>
      <div class="stat-card">
        <div class="stat-value">${statistics.unusedFunctions}</div>
        <div class="stat-label">Unused Functions</div>
      </div>
      <div class="stat-card">
        <div class="stat-value">${statistics.unusedImports}</div>
        <div class="stat-label">Unused Imports</div>
      </div>
      <div class="stat-card">
        <div class="stat-value">${(statistics.scanDurationMs / 1000).toStringAsFixed(2)}s</div>
        <div class="stat-label">Scan Duration</div>
      </div>
    </div>
''');

    // Group by file
    final byFile = issuesByFile;
    final sortedFiles = byFile.keys.toList()..sort();

    for (final file in sortedFiles) {
      final fileIssues = byFile[file]!;
      fileIssues.sort((a, b) => a.location.line.compareTo(b.location.line));

      buffer.writeln('''
    <div class="file-section">
      <div class="file-header">
        <span class="file-icon">📄</span>
        $file
      </div>
      <div class="issue-list">
''');

      for (final issue in fileIssues) {
        final severityClass = 'severity-${issue.severity.name}';
        buffer.writeln('''
        <div class="issue">
          <span class="severity $severityClass">${issue.severity.name}</span>
          <div class="issue-content">
            <div class="issue-symbol">${_escapeHtml(issue.symbol)}</div>
            <div class="issue-message">${_escapeHtml(issue.message)}</div>
          </div>
          <div>
            <span class="category-tag">${issue.category.name}</span>
            <div class="issue-location">Line ${issue.location.line}</div>
          </div>
        </div>
''');
      }

      buffer.writeln('''
      </div>
    </div>
''');
    }

    buffer.writeln('''
    <div class="footer">
      <p>Generated by Flutter Asset Hygiene - Unused Code Analyzer</p>
    </div>
  </div>
</body>
</html>
''');

    return buffer.toString();
  }

  String _escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  /// Merge multiple scan results
  static CodeScanResult merge(List<CodeScanResult> results) {
    final allIssues = <CodeIssue>[];
    final allDeclarations = <CodeElement>{};
    final allReferences = <CodeReference>{};
    final allPackages = <String>{};
    final allPackagePaths = <String, String>{};
    final allWarnings = <String>[];
    var totalFiles = 0;
    var totalDuration = 0;

    for (final result in results) {
      allIssues.addAll(result.issues);
      allDeclarations.addAll(result.declarations);
      allReferences.addAll(result.references);
      allPackages.addAll(result.scannedPackages);
      allPackagePaths.addAll(result.packagePaths);
      allWarnings.addAll(result.warnings);
      totalFiles += result.statistics.filesScanned;
      totalDuration += result.statistics.scanDurationMs;
    }

    return CodeScanResult(
      issues: allIssues,
      declarations: allDeclarations,
      references: allReferences,
      statistics: ScanStatistics.fromIssues(
        allIssues,
        filesScanned: totalFiles,
        scanDurationMs: totalDuration,
      ),
      scannedPackages: allPackages.toList(),
      packagePaths: allPackagePaths,
      warnings: allWarnings,
    );
  }
}

/// Statistics about the scan
class ScanStatistics {
  final int filesScanned;
  final int totalIssues;
  final int unusedClasses;
  final int unusedFunctions;
  final int unusedParameters;
  final int unusedImports;
  final int unusedMembers;
  final int unusedExports;
  final int scanDurationMs;

  const ScanStatistics({
    required this.filesScanned,
    required this.totalIssues,
    this.unusedClasses = 0,
    this.unusedFunctions = 0,
    this.unusedParameters = 0,
    this.unusedImports = 0,
    this.unusedMembers = 0,
    this.unusedExports = 0,
    required this.scanDurationMs,
  });

  factory ScanStatistics.fromIssues(
    List<CodeIssue> issues, {
    required int filesScanned,
    required int scanDurationMs,
  }) {
    var unusedClasses = 0;
    var unusedFunctions = 0;
    var unusedParameters = 0;
    var unusedImports = 0;
    var unusedMembers = 0;
    var unusedExports = 0;

    for (final issue in issues) {
      switch (issue.category) {
        case IssueCategory.unusedClass:
        case IssueCategory.unusedMixin:
        case IssueCategory.unusedExtension:
        case IssueCategory.unusedEnum:
        case IssueCategory.unusedTypedef:
          unusedClasses++;
          break;
        case IssueCategory.unusedFunction:
          unusedFunctions++;
          break;
        case IssueCategory.unusedParameter:
          unusedParameters++;
          break;
        case IssueCategory.unusedImport:
          unusedImports++;
          break;
        case IssueCategory.unusedMethod:
        case IssueCategory.unusedGetter:
        case IssueCategory.unusedSetter:
        case IssueCategory.unusedField:
        case IssueCategory.unusedConstructor:
          unusedMembers++;
          break;
        case IssueCategory.unusedExport:
          unusedExports++;
          break;
        case IssueCategory.unusedVariable:
        case IssueCategory.deadCode:
        case IssueCategory.unusedOverride:
          break;
      }
    }

    return ScanStatistics(
      filesScanned: filesScanned,
      totalIssues: issues.length,
      unusedClasses: unusedClasses,
      unusedFunctions: unusedFunctions,
      unusedParameters: unusedParameters,
      unusedImports: unusedImports,
      unusedMembers: unusedMembers,
      unusedExports: unusedExports,
      scanDurationMs: scanDurationMs,
    );
  }

  Map<String, dynamic> toJson() => {
        'filesScanned': filesScanned,
        'totalIssues': totalIssues,
        'unusedClasses': unusedClasses,
        'unusedFunctions': unusedFunctions,
        'unusedParameters': unusedParameters,
        'unusedImports': unusedImports,
        'unusedMembers': unusedMembers,
        'unusedExports': unusedExports,
        'scanDurationMs': scanDurationMs,
      };
}

