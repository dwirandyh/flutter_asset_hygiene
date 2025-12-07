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
        'unused,${_escapeCsv(asset.path)},${_escapeCsv(asset.packageName ?? '')},${asset.type.name}',
      );
    }

    for (final asset in potentiallyUsedAssets) {
      buffer.writeln(
        'potentially_used,${_escapeCsv(asset.path)},${_escapeCsv(asset.packageName ?? '')},${asset.type.name}',
      );
    }

    for (final asset in usedAssets) {
      buffer.writeln(
        'used,${_escapeCsv(asset.path)},${_escapeCsv(asset.packageName ?? '')},${asset.type.name}',
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
  <title>Asset Scan Report</title>
  <style>
    :root {
      --bg-primary: #0d1117;
      --bg-secondary: #161b22;
      --bg-card: #21262d;
      --text-primary: #c9d1d9;
      --text-secondary: #8b949e;
      --accent: #58a6ff;
      --warning: #d29922;
      --error: #f85149;
      --success: #3fb950;
      --border: #30363d;
    }
    
    * {
      margin: 0;
      padding: 0;
      box-sizing: border-box;
    }
    
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, sans-serif;
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
      grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
      gap: 1rem;
      margin-bottom: 2rem;
    }
    
    .stat-card {
      background: var(--bg-card);
      padding: 1.25rem;
      border-radius: 8px;
      text-align: center;
      border: 1px solid var(--border);
    }
    
    .stat-value {
      font-size: 2.5rem;
      font-weight: bold;
    }
    
    .stat-value.unused { color: var(--error); }
    .stat-value.used { color: var(--success); }
    .stat-value.potential { color: var(--warning); }
    .stat-value.total { color: var(--accent); }
    
    .stat-label {
      color: var(--text-secondary);
      font-size: 0.9rem;
      margin-top: 0.25rem;
    }
    
    .section {
      background: var(--bg-secondary);
      border-radius: 8px;
      margin-bottom: 1.5rem;
      border: 1px solid var(--border);
      overflow: hidden;
    }
    
    .section-header {
      background: var(--bg-card);
      padding: 1rem 1.25rem;
      font-weight: 600;
      display: flex;
      align-items: center;
      gap: 0.5rem;
      border-bottom: 1px solid var(--border);
    }
    
    .section-header.unused { color: var(--error); }
    .section-header.potential { color: var(--warning); }
    .section-header.used { color: var(--success); }
    
    .asset-list {
      padding: 0.5rem 0;
    }
    
    .asset-item {
      padding: 0.75rem 1.25rem;
      border-bottom: 1px solid var(--border);
      display: flex;
      justify-content: space-between;
      align-items: center;
    }
    
    .asset-item:last-child {
      border-bottom: none;
    }
    
    .asset-path {
      font-family: 'SF Mono', 'Fira Code', 'Consolas', monospace;
      font-size: 0.9rem;
    }
    
    .asset-meta {
      display: flex;
      gap: 0.75rem;
      align-items: center;
    }
    
    .asset-type {
      background: var(--bg-primary);
      padding: 0.2rem 0.5rem;
      border-radius: 4px;
      font-size: 0.75rem;
      color: var(--text-secondary);
    }
    
    .asset-package {
      color: var(--accent);
      font-size: 0.85rem;
    }
    
    .empty-state {
      padding: 2rem;
      text-align: center;
      color: var(--text-secondary);
    }
    
    .footer {
      margin-top: 2rem;
      text-align: center;
      color: var(--text-secondary);
      font-size: 0.85rem;
    }
    
    .warnings {
      background: rgba(210, 153, 34, 0.1);
      border: 1px solid var(--warning);
      border-radius: 8px;
      padding: 1rem;
      margin-bottom: 1.5rem;
    }
    
    .warning-item {
      padding: 0.5rem 0;
      color: var(--warning);
      font-size: 0.9rem;
    }
  </style>
</head>
<body>
  <div class="container">
    <h1>📦 Asset Scan Report</h1>
    <p class="subtitle">Generated on ${DateTime.now().toIso8601String()}</p>
    
    <div class="stats-grid">
      <div class="stat-card">
        <div class="stat-value total">$totalDeclared</div>
        <div class="stat-label">Total Declared</div>
      </div>
      <div class="stat-card">
        <div class="stat-value used">$totalUsed</div>
        <div class="stat-label">Used Assets</div>
      </div>
      <div class="stat-card">
        <div class="stat-value potential">$totalPotentiallyUsed</div>
        <div class="stat-label">Potentially Used</div>
      </div>
      <div class="stat-card">
        <div class="stat-value unused">$totalUnused</div>
        <div class="stat-label">Unused Assets</div>
      </div>
      <div class="stat-card">
        <div class="stat-value total">${scannedPackages.length}</div>
        <div class="stat-label">Packages Scanned</div>
      </div>
      <div class="stat-card">
        <div class="stat-value total">${(scanDurationMs / 1000).toStringAsFixed(2)}s</div>
        <div class="stat-label">Scan Duration</div>
      </div>
    </div>
''');

    // Warnings section
    if (warnings.isNotEmpty) {
      buffer.writeln('''
    <div class="warnings">
      <strong>⚠️ Warnings</strong>
''');
      for (final warning in warnings) {
        buffer.writeln(
          '      <div class="warning-item">${_escapeHtml(warning.message)}</div>',
        );
      }
      buffer.writeln('    </div>');
    }

    // Unused assets section
    buffer.writeln('''
    <div class="section">
      <div class="section-header unused">
        ❌ Unused Assets (${unusedAssets.length})
      </div>
''');
    if (unusedAssets.isEmpty) {
      buffer.writeln(
        '      <div class="empty-state">No unused assets found! 🎉</div>',
      );
    } else {
      buffer.writeln('      <div class="asset-list">');
      final sortedUnused = unusedAssets.toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final asset in sortedUnused) {
        buffer.writeln('''
        <div class="asset-item">
          <span class="asset-path">${_escapeHtml(asset.path)}</span>
          <div class="asset-meta">
            ${asset.packageName != null ? '<span class="asset-package">${_escapeHtml(asset.packageName!)}</span>' : ''}
            <span class="asset-type">${asset.type.name}</span>
          </div>
        </div>
''');
      }
      buffer.writeln('      </div>');
    }
    buffer.writeln('    </div>');

    // Potentially used assets section
    if (potentiallyUsedAssets.isNotEmpty) {
      buffer.writeln('''
    <div class="section">
      <div class="section-header potential">
        ⚠️ Potentially Used Assets (${potentiallyUsedAssets.length})
      </div>
      <div class="asset-list">
''');
      final sortedPotential = potentiallyUsedAssets.toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final asset in sortedPotential) {
        buffer.writeln('''
        <div class="asset-item">
          <span class="asset-path">${_escapeHtml(asset.path)}</span>
          <div class="asset-meta">
            ${asset.packageName != null ? '<span class="asset-package">${_escapeHtml(asset.packageName!)}</span>' : ''}
            <span class="asset-type">${asset.type.name}</span>
          </div>
        </div>
''');
      }
      buffer.writeln('''
      </div>
    </div>
''');
    }

    // Used assets section
    buffer.writeln('''
    <div class="section">
      <div class="section-header used">
        ✅ Used Assets (${usedAssets.length})
      </div>
''');
    if (usedAssets.isEmpty) {
      buffer.writeln(
        '      <div class="empty-state">No used assets found.</div>',
      );
    } else {
      buffer.writeln('      <div class="asset-list">');
      final sortedUsed = usedAssets.toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final asset in sortedUsed) {
        buffer.writeln('''
        <div class="asset-item">
          <span class="asset-path">${_escapeHtml(asset.path)}</span>
          <div class="asset-meta">
            ${asset.packageName != null ? '<span class="asset-package">${_escapeHtml(asset.packageName!)}</span>' : ''}
            <span class="asset-type">${asset.type.name}</span>
          </div>
        </div>
''');
      }
      buffer.writeln('      </div>');
    }
    buffer.writeln('    </div>');

    buffer.writeln('''
    <div class="footer">
      <p>Generated by Flutter Asset Hygiene</p>
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
