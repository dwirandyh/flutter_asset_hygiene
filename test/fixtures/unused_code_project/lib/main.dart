// Main entry point - should NOT be reported as unused
void main() {
  final service = UsedService();
  service.doSomething();

  final helper = UsedHelper();
  helper.help();
}

// Used class - should NOT be reported as unused
class UsedService {
  void doSomething() {
    print('Doing something');
  }
}

// Used class - should NOT be reported as unused
class UsedHelper {
  void help() {
    print('Helping');
  }
}

// Unused class - SHOULD be reported as unused
class UnusedService {
  void neverCalled() {
    print('Never called');
  }
}

// Unused function - SHOULD be reported as unused
void unusedFunction() {
  print('This function is never called');
}

// Used function - should NOT be reported as unused
void usedFunction() {
  print('This is used');
}

// Test usage of usedFunction
void caller() {
  usedFunction();
}
