import 'dart:io';

/// ANSI color codes for terminal output
class AnsiColors {
  static const reset = '\x1B[0m';
  static const red = '\x1B[31m';
  static const green = '\x1B[32m';
  static const yellow = '\x1B[33m';
  static const blue = '\x1B[34m';
  static const magenta = '\x1B[35m';
  static const cyan = '\x1B[36m';
  static const white = '\x1B[37m';
  static const bold = '\x1B[1m';
  static const dim = '\x1B[2m';
}

/// Logger for colored console output
class Logger {
  final bool verbose;
  final bool useColors;

  Logger({this.verbose = false, bool? useColors})
    : useColors = useColors ?? stdout.hasTerminal;

  /// Log info message
  void info(String message) {
    _log(message, AnsiColors.blue, '●');
  }

  /// Log success message
  void success(String message) {
    _log(message, AnsiColors.green, '✓');
  }

  /// Log warning message
  void warning(String message) {
    _log(message, AnsiColors.yellow, '⚠');
  }

  /// Log error message
  void error(String message) {
    _log(message, AnsiColors.red, '✗');
  }

  /// Log debug message (only in verbose mode)
  void debug(String message) {
    if (verbose) {
      _log(message, AnsiColors.dim, '·');
    }
  }

  /// Log a plain message
  void plain(String message) {
    stdout.writeln(message);
  }

  /// Log a header
  void header(String message) {
    stdout.writeln('');
    if (useColors) {
      stdout.writeln(
        '${AnsiColors.bold}${AnsiColors.cyan}═══ $message ═══${AnsiColors.reset}',
      );
    } else {
      stdout.writeln('═══ $message ═══');
    }
    stdout.writeln('');
  }

  /// Log a section divider
  void divider() {
    if (useColors) {
      stdout.writeln('${AnsiColors.dim}${'─' * 50}${AnsiColors.reset}');
    } else {
      stdout.writeln('─' * 50);
    }
  }

  /// Log progress
  void progress(String message) {
    if (useColors) {
      stdout.write('\r${AnsiColors.cyan}⟳ $message${AnsiColors.reset}');
    } else {
      stdout.write('\r⟳ $message');
    }
  }

  /// Clear progress line
  void clearProgress() {
    stdout.write('\r${' ' * 80}\r');
  }

  /// Log an asset path with status
  void asset(String path, {bool used = false, bool potential = false}) {
    final status = used
        ? '${AnsiColors.green}[USED]${AnsiColors.reset}'
        : potential
        ? '${AnsiColors.yellow}[MAYBE]${AnsiColors.reset}'
        : '${AnsiColors.red}[UNUSED]${AnsiColors.reset}';

    if (useColors) {
      stdout.writeln('  $status $path');
    } else {
      final statusText = used
          ? '[USED]'
          : potential
          ? '[MAYBE]'
          : '[UNUSED]';
      stdout.writeln('  $statusText $path');
    }
  }

  /// Log a table row
  void tableRow(List<String> columns, List<int> widths) {
    final row = StringBuffer();
    for (var i = 0; i < columns.length; i++) {
      final col = columns[i];
      final width = i < widths.length ? widths[i] : 20;
      row.write(col.padRight(width));
    }
    stdout.writeln(row.toString());
  }

  void _log(String message, String color, String icon) {
    if (useColors) {
      stdout.writeln('$color$icon $message${AnsiColors.reset}');
    } else {
      stdout.writeln('$icon $message');
    }
  }
}
