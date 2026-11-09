// T-1499 (PWA M3): tokens on web live in sessionStorage, never localStorage.
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/auth/auth.dart';

void main() {
  test('W1: web uses session storage, native does not', () {
    expect(
      productionSecureStorage(
        web: true,
      ).webOptions.toMap()['useSessionStorage'],
      'true',
    );
    expect(
      productionSecureStorage(
        web: false,
      ).webOptions.toMap()['useSessionStorage'],
      'false',
    );
  });
}
