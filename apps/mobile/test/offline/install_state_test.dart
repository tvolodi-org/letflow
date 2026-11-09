// T-1499 (PWA M3): the 7-day storage warning decision.
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/offline/install_state.dart';

void main() {
  test('I1: warns only on web in a browser tab', () {
    expect(shouldWarnStorage(InstallState.browser, isWeb: true), isTrue);
  });

  test('I2: hidden when installed or native', () {
    expect(shouldWarnStorage(InstallState.installed, isWeb: true), isFalse);
    expect(shouldWarnStorage(InstallState.native, isWeb: false), isFalse);
    expect(shouldWarnStorage(InstallState.browser, isWeb: false), isFalse);
  });

  test('off web the install state is native', () {
    expect(currentInstallState(), InstallState.native);
  });
}
