import 'install_state.dart';

InstallState currentInstallState() => InstallState.native;

/// No-op off web.
Future<void> requestPersistentStorage() async {}

InstallPlatform currentInstallPlatform() => InstallPlatform.other;
