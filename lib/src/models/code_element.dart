/// Represents a code element (class, function, variable, etc.)
class CodeElement {
  /// Name of the element
  final String name;

  /// Type of the element
  final CodeElementType type;

  /// Location in the source file
  final SourceLocation location;

  /// Whether the element is public (not prefixed with _)
  final bool isPublic;

  /// Whether the element is static
  final bool isStatic;

  /// Whether the element has @override annotation
  final bool isOverride;

  /// Whether the element is abstract (abstract class/method)
  final bool isAbstract;

  /// Package name (for monorepo support)
  final String? packageName;

  /// Parent element (e.g., class for a method)
  final String? parentName;

  /// Annotations on this element
  final List<String> annotations;

  /// Documentation comment
  final String? documentation;

  /// Whether this element is exported
  final bool isExported;

  /// Superclass name (for classes that extend another class)
  final String? superclassName;

  /// Implemented interface names
  final List<String> implementedInterfaces;

  /// Mixed-in mixin names
  final List<String> mixins;

  const CodeElement({
    required this.name,
    required this.type,
    required this.location,
    this.isPublic = true,
    this.isStatic = false,
    this.isOverride = false,
    this.isAbstract = false,
    this.packageName,
    this.parentName,
    this.annotations = const [],
    this.documentation,
    this.isExported = false,
    this.superclassName,
    this.implementedInterfaces = const [],
    this.mixins = const [],
  });

  /// Unique identifier for this element
  String get id {
    final parts = <String>[];
    if (packageName != null) parts.add(packageName!);
    parts.add(location.filePath);
    if (parentName != null) parts.add(parentName!);
    parts.add(name);
    return parts.join('::');
  }

  /// Full qualified name
  String get qualifiedName {
    if (parentName != null) {
      return '$parentName.$name';
    }
    return name;
  }

  /// Check if element has a specific annotation
  bool hasAnnotation(String annotation) {
    final normalizedAnnotation = annotation.startsWith('@')
        ? annotation.substring(1)
        : annotation;
    return annotations.any(
      (a) => a == normalizedAnnotation || a == '@$normalizedAnnotation',
    );
  }

  CodeElement copyWith({
    String? name,
    CodeElementType? type,
    SourceLocation? location,
    bool? isPublic,
    bool? isStatic,
    bool? isOverride,
    bool? isAbstract,
    String? packageName,
    String? parentName,
    List<String>? annotations,
    String? documentation,
    bool? isExported,
    String? superclassName,
    List<String>? implementedInterfaces,
    List<String>? mixins,
  }) {
    return CodeElement(
      name: name ?? this.name,
      type: type ?? this.type,
      location: location ?? this.location,
      isPublic: isPublic ?? this.isPublic,
      isStatic: isStatic ?? this.isStatic,
      isOverride: isOverride ?? this.isOverride,
      isAbstract: isAbstract ?? this.isAbstract,
      packageName: packageName ?? this.packageName,
      parentName: parentName ?? this.parentName,
      annotations: annotations ?? this.annotations,
      documentation: documentation ?? this.documentation,
      isExported: isExported ?? this.isExported,
      superclassName: superclassName ?? this.superclassName,
      implementedInterfaces:
          implementedInterfaces ?? this.implementedInterfaces,
      mixins: mixins ?? this.mixins,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'type': type.name,
    'location': location.toJson(),
    'isPublic': isPublic,
    'isStatic': isStatic,
    'isOverride': isOverride,
    'isAbstract': isAbstract,
    if (packageName != null) 'packageName': packageName,
    if (parentName != null) 'parentName': parentName,
    'annotations': annotations,
    if (documentation != null) 'documentation': documentation,
    'isExported': isExported,
    if (superclassName != null) 'superclassName': superclassName,
    if (implementedInterfaces.isNotEmpty)
      'implementedInterfaces': implementedInterfaces,
    if (mixins.isNotEmpty) 'mixins': mixins,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CodeElement &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'CodeElement($qualifiedName, $type, ${location.filePath}:${location.line})';
}

/// Types of code elements
enum CodeElementType {
  /// Top-level class
  classDeclaration,

  /// Mixin declaration
  mixinDeclaration,

  /// Extension declaration
  extensionDeclaration,

  /// Enum declaration
  enumDeclaration,

  /// Typedef/type alias
  typedefDeclaration,

  /// Top-level function
  topLevelFunction,

  /// Top-level variable
  topLevelVariable,

  /// Class constructor
  constructor,

  /// Class method
  method,

  /// Class getter
  getter,

  /// Class setter
  setter,

  /// Class field
  field,

  /// Enum value
  enumValue,

  /// Function/method parameter
  parameter,

  /// Local variable
  localVariable,

  /// Import directive
  importDirective,

  /// Export directive
  exportDirective,

  /// Part directive
  partDirective,
}

/// Represents a location in source code
class SourceLocation {
  /// Path to the file (relative to project root)
  final String filePath;

  /// Line number (1-based)
  final int line;

  /// Column number (1-based)
  final int column;

  /// Offset in the file
  final int offset;

  /// Length of the element in characters
  final int length;

  const SourceLocation({
    required this.filePath,
    required this.line,
    required this.column,
    this.offset = 0,
    this.length = 0,
  });

  Map<String, dynamic> toJson() => {
    'filePath': filePath,
    'line': line,
    'column': column,
    'offset': offset,
    'length': length,
  };

  @override
  String toString() => '$filePath:$line:$column';
}

/// Represents a reference to a code element
class CodeReference {
  /// The element being referenced
  final String elementId;

  /// Location of the reference
  final SourceLocation location;

  /// Type of reference
  final ReferenceType type;

  /// Package where the reference occurs
  final String? packageName;

  const CodeReference({
    required this.elementId,
    required this.location,
    required this.type,
    this.packageName,
  });

  Map<String, dynamic> toJson() => {
    'elementId': elementId,
    'location': location.toJson(),
    'type': type.name,
    if (packageName != null) 'packageName': packageName,
  };
}

/// Types of references
enum ReferenceType {
  /// Direct invocation (function call, constructor)
  invocation,

  /// Type usage (in declaration, cast, generic)
  typeUsage,

  /// Inheritance (extends, implements, with)
  inheritance,

  /// Property access
  propertyAccess,

  /// Import/export
  importExport,

  /// Annotation usage
  annotation,

  /// Assignment
  assignment,

  /// Read access
  read,
}

/// Issue found during unused code analysis
class CodeIssue {
  /// Category of the issue
  final IssueCategory category;

  /// Severity level
  final IssueSeverity severity;

  /// Name of the unused symbol
  final String symbol;

  /// Location in source
  final SourceLocation location;

  /// Human-readable message
  final String message;

  /// Suggestion for fixing
  final String? suggestion;

  /// Code snippet around the issue
  final String? codeSnippet;

  /// Whether this issue can be auto-fixed
  final bool canAutoFix;

  /// Package name (for monorepo)
  final String? packageName;

  const CodeIssue({
    required this.category,
    required this.severity,
    required this.symbol,
    required this.location,
    required this.message,
    this.suggestion,
    this.codeSnippet,
    this.canAutoFix = false,
    this.packageName,
  });

  Map<String, dynamic> toJson() => {
    'category': category.name,
    'severity': severity.name,
    'symbol': symbol,
    'file': location.filePath,
    'line': location.line,
    'column': location.column,
    'message': message,
    if (suggestion != null) 'suggestion': suggestion,
    if (codeSnippet != null) 'codeSnippet': codeSnippet,
    'canAutoFix': canAutoFix,
    if (packageName != null) 'packageName': packageName,
  };

  @override
  String toString() =>
      '[$category] $symbol at ${location.filePath}:${location.line}';
}

/// Categories of unused code issues
enum IssueCategory {
  unusedClass,
  unusedMixin,
  unusedExtension,
  unusedEnum,
  unusedTypedef,
  unusedFunction,
  unusedMethod,
  unusedGetter,
  unusedSetter,
  unusedField,
  unusedParameter,
  unusedVariable,
  unusedImport,
  unusedExport,
  unusedConstructor,
  deadCode,
  unusedOverride,
}

/// Severity levels for issues
enum IssueSeverity {
  info,
  warning,
  error;

  static IssueSeverity fromString(String value) {
    switch (value.toLowerCase()) {
      case 'error':
        return IssueSeverity.error;
      case 'warning':
        return IssueSeverity.warning;
      default:
        return IssueSeverity.info;
    }
  }
}
