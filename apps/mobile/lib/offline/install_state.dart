/// Whether the app runs installed (home screen) or in a browser tab, for the
/// "an uninstalled site can lose data after 7 days" warning (PWA M3, D-112).
library;

export 'install_state_stub.dart'
    if (dart.library.js_interop) 'install_state_web.dart';

enum InstallState { native, installed, browser }

/// The warning is shown only on web, in a browser tab (not installed).
bool shouldWarnStorage(InstallState state, {required bool isWeb}) =>
    isWeb && state == InstallState.browser;
