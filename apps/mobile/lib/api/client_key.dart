/// Version-4 UUID generator for idempotency keys (REQ-849).
library;

import 'dart:math';

final Random _random = Random.secure();

/// Returns a fresh version-4 UUID using a secure random source (no package
/// needed: dart:math's Random.secure() is CSPRNG on all platforms).
String newClientKey() {
  final b = List<int>.generate(16, (_) => _random.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String h(int from, int to) =>
      b.sublist(from, to).map((e) => e.toRadixString(16).padLeft(2, '0')).join();
  return '${h(0, 4)}-${h(4, 6)}-${h(6, 8)}-${h(8, 10)}-${h(10, 16)}';
}

/// Returns true when [s] is a valid version-4 UUID (lowercase hex).
bool isClientKey(String s) {
  if (s.length != 36) return false;
  final parts = s.split('-');
  if (parts.length != 5) return false;
  if (parts[0].length != 8) return false;
  if (parts[1].length != 4) return false;
  if (parts[2].length != 4) return false;
  if (parts[3].length != 4) return false;
  if (parts[4].length != 12) return false;
  // version nibble must be 4
  if (parts[2][0] != '4') return false;
  // variant nibble must be 8, 9, a or b
  final variant = parts[3][0];
  return variant == '8' || variant == '9' || variant == 'a' || variant == 'b';
}
