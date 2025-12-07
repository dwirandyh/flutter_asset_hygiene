// Test file for cascading cleanup edge cases

/// Class with method that uses a private helper
/// When the public method is removed, the private helper should also be removed
class ClassWithPrivateHelper {
  /// Public method that uses private helper - UNUSED
  String formatData(String input) {
    return _privateHelper(input);
  }

  /// Private helper only used by formatData - should be removed with it
  String _privateHelper(String input) {
    return input.toUpperCase();
  }

  /// Used method
  String getName() => 'ClassWithPrivateHelper';
}

/// Class with field only used by unused method
/// When the method is removed, the field should also be removed
class ClassWithOrphanedField {
  /// Field only used by unusedMethod - should be removed with it
  final String _onlyUsedByUnusedMethod = 'orphan';

  /// Unused method that uses _onlyUsedByUnusedMethod
  void unusedMethod() {
    print(_onlyUsedByUnusedMethod);
  }

  /// Used method
  String getInfo() => 'ClassWithOrphanedField';
}

/// Class with field used in constructor - should NOT be removed
class ClassWithConstructorField {
  final String _fieldUsedInConstructor;

  ClassWithConstructorField(String value) : _fieldUsedInConstructor = value;

  /// Unused method that was using the field
  void unusedMethod() {
    print(_fieldUsedInConstructor);
  }

  /// Used method
  String getInfo() => 'ClassWithConstructorField';
}

/// Class with field formal parameter - should NOT be removed
class ClassWithFieldFormalParameter {
  final String _fieldWithFormalParam;

  ClassWithFieldFormalParameter(this._fieldWithFormalParam);

  /// Unused method that was using the field
  void unusedMethod() {
    print(_fieldWithFormalParam);
  }

  /// Used method
  String getInfo() => 'ClassWithFieldFormalParameter';
}

/// Class with static field - should NOT be removed by cascading cleanup
/// (static fields can be accessed from other files)
class ClassWithStaticField {
  static const String staticField = 'static';

  /// Unused method that uses static field
  void unusedMethod() {
    print(staticField);
  }

  /// Used method
  String getInfo() => 'ClassWithStaticField';
}

/// Class with private static method - CAN be removed by cascading cleanup
/// (private static methods cannot be accessed from other files)
class ClassWithPrivateStaticMethod {
  /// Unused public method that uses private static method
  String formatText(String input) {
    return _privateStaticHelper(input);
  }

  /// Private static helper - should be removed with formatText
  static String _privateStaticHelper(String input) {
    return input.trim();
  }

  /// Used method
  String getInfo() => 'ClassWithPrivateStaticMethod';
}

/// Class with nested private method calls
/// When A is removed, B should be removed, then C should be removed
class ClassWithNestedPrivateMethods {
  /// Unused public method
  void unusedPublicMethod() {
    _privateMethodA();
  }

  void _privateMethodA() {
    _privateMethodB();
  }

  void _privateMethodB() {
    _privateMethodC();
  }

  void _privateMethodC() {
    print('deepest');
  }

  /// Used method
  String getInfo() => 'ClassWithNestedPrivateMethods';
}

/// Class with multiple unused methods sharing a helper
class ClassWithSharedHelper {
  /// Unused method 1
  void unusedMethod1() {
    _sharedHelper();
  }

  /// Unused method 2
  void unusedMethod2() {
    _sharedHelper();
  }

  /// Shared helper - should be removed when both unused methods are removed
  void _sharedHelper() {
    print('shared');
  }

  /// Used method
  String getInfo() => 'ClassWithSharedHelper';
}

// Usage - only call used methods
void useCascadingClasses() {
  print(ClassWithPrivateHelper().getName());
  print(ClassWithOrphanedField().getInfo());
  print(ClassWithConstructorField('test').getInfo());
  print(ClassWithFieldFormalParameter('test').getInfo());
  print(ClassWithStaticField().getInfo());
  print(ClassWithPrivateStaticMethod().getInfo());
  print(ClassWithNestedPrivateMethods().getInfo());
  print(ClassWithSharedHelper().getInfo());
}

