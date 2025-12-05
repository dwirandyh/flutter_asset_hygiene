import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/element.dart';

import '../models/code_element.dart';
import 'semantic_analyzer.dart';

/// Detects Dependency Injection patterns and marks types as used.
///
/// Supports:
/// - GetIt: `GetIt.I<T>()`, `GetIt.instance<T>()`, `locator<T>()`, `sl<T>()`
/// - Injectable: `@injectable`, `@singleton`, `@lazySingleton`
/// - Riverpod: `@riverpod`, `@Riverpod()`, Provider patterns
/// - Provider: `Provider<T>`, `ChangeNotifierProvider<T>`
/// - BLoC: `BlocProvider<T>`, `@injectable` on Blocs
class DependencyInjectionDetector extends RecursiveAstVisitor<void> {
  /// Types that are registered/used via DI
  final Set<String> registeredTypes = {};

  /// Types that are retrieved via DI
  final Set<String> retrievedTypes = {};

  /// All DI registrations found
  final List<DIRegistration> registrations = [];

  /// All DI retrievals found
  final List<DIRetrieval> retrievals = [];

  /// The resolved unit for semantic information
  final ResolvedUnitResult? resolvedUnit;

  /// The file being visited
  final String filePath;

  /// Package name
  final String? packageName;

  DependencyInjectionDetector({
    this.resolvedUnit,
    required this.filePath,
    this.packageName,
  });

  // ============================================================
  // Annotation-based DI (Injectable, Riverpod)
  // ============================================================

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    _checkClassAnnotations(node);
    super.visitClassDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    _checkFunctionAnnotations(node);
    super.visitFunctionDeclaration(node);
  }

  void _checkClassAnnotations(ClassDeclaration node) {
    final className = node.name.lexeme;

    for (final annotation in node.metadata) {
      final result = _parseAnnotation(annotation);
      if (result != null) {
        registeredTypes.add(className);
        registrations.add(DIRegistration(
          typeName: className,
          framework: result.framework,
          registrationType: result.registrationType,
          location: _locationFromNode(annotation),
          packageName: packageName,
        ));
      }
    }
  }

  void _checkFunctionAnnotations(FunctionDeclaration node) {
    final functionName = node.name.lexeme;

    for (final annotation in node.metadata) {
      final result = _parseAnnotation(annotation);
      if (result != null) {
        // For Riverpod, the function generates a provider
        if (result.framework == DIFramework.riverpod) {
          registeredTypes.add(functionName);
          registrations.add(DIRegistration(
            typeName: functionName,
            framework: result.framework,
            registrationType: result.registrationType,
            location: _locationFromNode(annotation),
            packageName: packageName,
          ));
        }
      }
    }
  }

  _AnnotationResult? _parseAnnotation(Annotation annotation) {
    final name = annotation.name.name;

    // Injectable annotations
    switch (name) {
      case 'injectable':
      case 'Injectable':
        return _AnnotationResult(
          DIFramework.injectable,
          DIRegistrationType.factory,
        );
      case 'singleton':
      case 'Singleton':
        return _AnnotationResult(
          DIFramework.injectable,
          DIRegistrationType.singleton,
        );
      case 'lazySingleton':
      case 'LazySingleton':
        return _AnnotationResult(
          DIFramework.injectable,
          DIRegistrationType.lazySingleton,
        );
      case 'module':
      case 'Module':
        return _AnnotationResult(
          DIFramework.injectable,
          DIRegistrationType.factory,
        );

      // Riverpod annotations
      case 'riverpod':
      case 'Riverpod':
        return _AnnotationResult(
          DIFramework.riverpod,
          DIRegistrationType.provider,
        );
    }

    return null;
  }

  // ============================================================
  // Method-based DI (GetIt, Provider)
  // ============================================================

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _checkGetItInvocation(node);
    _checkProviderInvocation(node);
    super.visitMethodInvocation(node);
  }

  void _checkGetItInvocation(MethodInvocation node) {
    final methodName = node.methodName.name;
    final target = node.target;

    // Pattern 1: GetIt.I<T>() or GetIt.instance<T>()
    if (target is PrefixedIdentifier) {
      final prefix = target.prefix.name;
      final identifier = target.identifier.name;

      if (prefix == 'GetIt' && (identifier == 'I' || identifier == 'instance')) {
        _extractTypeArguments(node, DIFramework.getIt, isRetrieval: true);
        return;
      }
    }

    // Pattern 2: locator<T>(), sl<T>(), getIt<T>()
    if (target == null) {
      if (methodName == 'locator' ||
          methodName == 'sl' ||
          methodName == 'getIt' ||
          methodName == 'get') {
        _extractTypeArguments(node, DIFramework.getIt, isRetrieval: true);
        return;
      }
    }

    // Pattern 3: GetIt.I.get<T>() or instance.get<T>()
    if (methodName == 'get' || methodName == 'call') {
      if (target is SimpleIdentifier) {
        final targetName = target.name;
        if (targetName == 'locator' ||
            targetName == 'sl' ||
            targetName == 'getIt' ||
            targetName == 'instance') {
          _extractTypeArguments(node, DIFramework.getIt, isRetrieval: true);
          return;
        }
      }
    }

    // Pattern 4: Registration methods
    if (methodName == 'registerSingleton' ||
        methodName == 'registerLazySingleton' ||
        methodName == 'registerFactory' ||
        methodName == 'registerFactoryAsync') {
      final registrationType = _getRegistrationTypeFromMethod(methodName);
      _extractTypeArguments(node, DIFramework.getIt,
          isRetrieval: false, registrationType: registrationType);
    }
  }

  void _checkProviderInvocation(MethodInvocation node) {
    final methodName = node.methodName.name;
    final target = node.target;

    // Pattern: context.read<T>(), context.watch<T>(), ref.watch(), ref.read()
    if (target is SimpleIdentifier) {
      final targetName = target.name;

      // Provider patterns
      if (targetName == 'context' &&
          (methodName == 'read' || methodName == 'watch' || methodName == 'select')) {
        _extractTypeArguments(node, DIFramework.provider, isRetrieval: true);
        return;
      }

      // Riverpod patterns
      if (targetName == 'ref' &&
          (methodName == 'read' || methodName == 'watch' || methodName == 'listen')) {
        _extractTypeArguments(node, DIFramework.riverpod, isRetrieval: true);
        return;
      }
    }
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _checkProviderCreation(node);
    _checkBlocProviderCreation(node);
    super.visitInstanceCreationExpression(node);
  }

  void _checkProviderCreation(InstanceCreationExpression node) {
    final typeName = node.constructorName.type.name2.lexeme;

    // Provider patterns
    final providerTypes = {
      'Provider',
      'ChangeNotifierProvider',
      'FutureProvider',
      'StreamProvider',
      'StateProvider',
      'StateNotifierProvider',
      'NotifierProvider',
      'AsyncNotifierProvider',
    };

    if (providerTypes.contains(typeName)) {
      _extractTypeArguments(node, DIFramework.provider, isRetrieval: false);
    }
  }

  void _checkBlocProviderCreation(InstanceCreationExpression node) {
    final typeName = node.constructorName.type.name2.lexeme;

    if (typeName == 'BlocProvider' ||
        typeName == 'RepositoryProvider' ||
        typeName == 'MultiBlocProvider') {
      _extractTypeArguments(node, DIFramework.bloc, isRetrieval: false);
    }
  }

  // ============================================================
  // Helper methods
  // ============================================================

  void _extractTypeArguments(
    AstNode node,
    DIFramework framework, {
    required bool isRetrieval,
    DIRegistrationType registrationType = DIRegistrationType.factory,
  }) {
    TypeArgumentList? typeArgs;

    if (node is MethodInvocation) {
      typeArgs = node.typeArguments;
    } else if (node is InstanceCreationExpression) {
      typeArgs = node.constructorName.type.typeArguments;
    }

    if (typeArgs != null && typeArgs.arguments.isNotEmpty) {
      for (final typeArg in typeArgs.arguments) {
        if (typeArg is NamedType) {
          final typeName = typeArg.name2.lexeme;

          if (isRetrieval) {
            retrievedTypes.add(typeName);
            retrievals.add(DIRetrieval(
              typeName: typeName,
              framework: framework,
              location: _locationFromNode(node),
              packageName: packageName,
            ));
          } else {
            registeredTypes.add(typeName);
            registrations.add(DIRegistration(
              typeName: typeName,
              framework: framework,
              registrationType: registrationType,
              location: _locationFromNode(node),
              packageName: packageName,
            ));
          }

          // Also track the element if we have semantic info
          if (resolvedUnit != null) {
            final element = typeArg.element;
            if (element != null) {
              // The type is used via DI
              registeredTypes.add(_getElementId(element));
            }
          }
        }
      }
    }
  }

  DIRegistrationType _getRegistrationTypeFromMethod(String methodName) {
    switch (methodName) {
      case 'registerSingleton':
        return DIRegistrationType.singleton;
      case 'registerLazySingleton':
        return DIRegistrationType.lazySingleton;
      case 'registerFactory':
      case 'registerFactoryAsync':
        return DIRegistrationType.factory;
      default:
        return DIRegistrationType.factory;
    }
  }

  String _getElementId(Element element) {
    final parts = <String>[];

    final library = element.library;
    if (library != null) {
      parts.add(library.source.uri.toString());
    }

    final name = element.name;
    if (name != null && name.isNotEmpty) {
      parts.add(name);
    }

    return parts.join('::');
  }

  SourceLocation _locationFromNode(AstNode node) {
    if (resolvedUnit != null) {
      final lineInfo = resolvedUnit!.lineInfo;
      final location = lineInfo.getLocation(node.offset);
      return SourceLocation(
        filePath: filePath,
        line: location.lineNumber,
        column: location.columnNumber,
        offset: node.offset,
        length: node.length,
      );
    }

    return SourceLocation(
      filePath: filePath,
      line: 0,
      column: 0,
      offset: node.offset,
      length: node.length,
    );
  }

  /// Get all types that are used via DI (either registered or retrieved)
  Set<String> get allDITypes => {...registeredTypes, ...retrievedTypes};

  /// Check if a type is used via DI
  bool isTypeUsedViaDI(String typeName) {
    return registeredTypes.contains(typeName) || retrievedTypes.contains(typeName);
  }
}

/// Result of parsing an annotation
class _AnnotationResult {
  final DIFramework framework;
  final DIRegistrationType registrationType;

  const _AnnotationResult(this.framework, this.registrationType);
}

/// Information about a DI retrieval (getting a dependency)
class DIRetrieval {
  final String typeName;
  final DIFramework framework;
  final SourceLocation location;
  final String? packageName;

  const DIRetrieval({
    required this.typeName,
    required this.framework,
    required this.location,
    this.packageName,
  });
}

/// Result of DI detection analysis
class DIDetectionResult {
  /// Types registered via DI
  final Set<String> registeredTypes;

  /// Types retrieved via DI
  final Set<String> retrievedTypes;

  /// All registrations found
  final List<DIRegistration> registrations;

  /// All retrievals found
  final List<DIRetrieval> retrievals;

  const DIDetectionResult({
    required this.registeredTypes,
    required this.retrievedTypes,
    required this.registrations,
    required this.retrievals,
  });

  /// Get all types used via DI
  Set<String> get allTypes => {...registeredTypes, ...retrievedTypes};

  /// Merge with another result
  DIDetectionResult merge(DIDetectionResult other) {
    return DIDetectionResult(
      registeredTypes: {...registeredTypes, ...other.registeredTypes},
      retrievedTypes: {...retrievedTypes, ...other.retrievedTypes},
      registrations: [...registrations, ...other.registrations],
      retrievals: [...retrievals, ...other.retrievals],
    );
  }

  factory DIDetectionResult.empty() => const DIDetectionResult(
        registeredTypes: {},
        retrievedTypes: {},
        registrations: [],
        retrievals: [],
      );
}

