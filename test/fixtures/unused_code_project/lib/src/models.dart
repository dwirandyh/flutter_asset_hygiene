// Used enum - should NOT be reported as unused
enum UsedStatus { active, inactive, pending }

// Unused enum - SHOULD be reported as unused
enum UnusedStatus { unknown, error }

// Used mixin - should NOT be reported as unused
mixin UsedMixin {
  void mixinMethod() {
    print('Mixin method');
  }
}

// Unused mixin - SHOULD be reported as unused
mixin UnusedMixin {
  void unusedMixinMethod() {
    print('Unused mixin method');
  }
}

// Used typedef - should NOT be reported as unused
typedef UsedCallback = void Function(String message);

// Unused typedef - SHOULD be reported as unused
typedef UnusedCallback = void Function(int value);

// Class using mixin
class ServiceWithMixin with UsedMixin {
  void run() {
    mixinMethod();
  }
}

// Class using enum
class StatusChecker {
  UsedStatus checkStatus() {
    return UsedStatus.active;
  }
}

// Function using typedef
void registerCallback(UsedCallback callback) {
  callback('Hello');
}
