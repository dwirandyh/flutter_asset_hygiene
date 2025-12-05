import 'dart:convert';  // Used import
import 'dart:async';    // Unused import - SHOULD be reported

// Class with unused members
class ServiceWithUnusedMembers {
  // Used field
  final String name;
  
  // Unused field - SHOULD be reported
  final int _unusedCounter = 0;
  
  // Used constructor
  ServiceWithUnusedMembers(this.name);
  
  // Unused named constructor - SHOULD be reported
  ServiceWithUnusedMembers.unused() : name = 'unused';
  
  // Used method
  String getName() {
    return name;
  }
  
  // Unused method - SHOULD be reported
  void _unusedMethod() {
    print('Never called');
  }
  
  // Used getter
  bool get isValid => name.isNotEmpty;
  
  // Unused getter - SHOULD be reported
  int get unusedGetter => 42;
  
  // Method with unused parameter - SHOULD be reported
  void processData(String data, int unusedParam) {
    final encoded = json.encode({'data': data});
    print(encoded);
  }
}

// Extension on String - used
extension UsedStringExtension on String {
  String capitalize() {
    if (isEmpty) return this;
    return '${this[0].toUpperCase()}${substring(1)}';
  }
}

// Extension on String - unused - SHOULD be reported
extension UnusedStringExtension on String {
  String reverse() {
    return split('').reversed.join();
  }
}

// Usage
void useService() {
  final service = ServiceWithUnusedMembers('test');
  print(service.getName());
  print(service.isValid);
  service.processData('hello', 0);
  
  final text = 'hello'.capitalize();
  print(text);
}

