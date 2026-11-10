/// Whether the app runs installed (home screen) or in a browser tab, for the
/// "an uninstalled site can lose data after 7 days" warning (PWA M3, D-112).
library;

export 'install_state_stub.dart'
    if (dart.library.js_interop) 'install_state_web.dart';

enum InstallState { native, installed, browser }

/// The warning is shown only on web, in a browser tab (not installed).
bool shouldWarnStorage(InstallState state, {required bool isWeb}) =>
    isWeb && state == InstallState.browser;

enum InstallPlatform { ios, android, other }

/// iPhone / iPad / iPod, or an iPad that reports a desktop Mac user agent
/// (it has touch points) -> ios; Android -> android; anything else -> other.
InstallPlatform classifyPlatform(String userAgent, int maxTouchPoints) {
  if (RegExp(r'iPhone|iPad|iPod').hasMatch(userAgent)) {
    return InstallPlatform.ios;
  }
  if (userAgent.contains('Macintosh') && maxTouchPoints > 1) {
    return InstallPlatform.ios;
  }
  if (userAgent.contains('Android')) return InstallPlatform.android;
  return InstallPlatform.other;
}

/// The install hint is shown only on web, in a browser tab, on a phone/tablet.
bool shouldShowInstallHint(
  InstallState state,
  InstallPlatform platform, {
  required bool isWeb,
  required bool seen,
}) =>
    isWeb &&
    state == InstallState.browser &&
    platform != InstallPlatform.other &&
    !seen;
