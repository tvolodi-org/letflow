// T-1499 (PWA M3): the 7-day storage warning decision.
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/offline/install_state.dart';

void main() {
  platformTests();
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

void platformTests() {
  test('P1: classifyPlatform', () {
    const iphone =
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) Safari/604';
    const mac = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Safari/605';
    expect(classifyPlatform(iphone, 5), InstallPlatform.ios);
    expect(classifyPlatform(mac, 5), InstallPlatform.ios);
    expect(classifyPlatform(mac, 0), InstallPlatform.other);
    expect(
      classifyPlatform('Mozilla/5.0 (Linux; Android 14) Chrome/120', 5),
      InstallPlatform.android,
    );
    expect(
      classifyPlatform('Mozilla/5.0 (X11; Linux x86_64)', 0),
      InstallPlatform.other,
    );
    expect(currentInstallPlatform(), InstallPlatform.other);
  });

  test('H1: hint decision', () {
    bool f(
      InstallState s,
      InstallPlatform p, {
      bool web = true,
      bool seen = false,
    }) => shouldShowInstallHint(s, p, isWeb: web, seen: seen);
    expect(f(InstallState.browser, InstallPlatform.ios), isTrue);
    expect(f(InstallState.browser, InstallPlatform.android), isTrue);
    expect(f(InstallState.browser, InstallPlatform.other), isFalse);
    expect(f(InstallState.installed, InstallPlatform.ios), isFalse);
    expect(f(InstallState.browser, InstallPlatform.ios, web: false), isFalse);
    expect(f(InstallState.browser, InstallPlatform.ios, seen: true), isFalse);
  });
}
