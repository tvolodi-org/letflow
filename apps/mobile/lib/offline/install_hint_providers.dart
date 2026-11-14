import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'install_hint_store.dart';
import 'install_state.dart';

/// The install hint is a web/PWA feature; tests override it.
final Provider<bool> installHintEnabledProvider = Provider<bool>((_) => kIsWeb);

/// Remembers the dismissed install hint; null off the web (the hint is a
/// web/PWA feature). Tests override it with an in-memory store.
final Provider<InstallHintStore?> installHintStoreProvider =
    Provider<InstallHintStore?>((ref) {
      if (!ref.watch(installHintEnabledProvider)) return null;
      return productionInstallHintStore();
    });

/// The platform the hint is written for; tests override it.
final Provider<InstallPlatform> installPlatformProvider =
    Provider<InstallPlatform>((_) => currentInstallPlatform());

/// The install state; tests override it.
final Provider<InstallState> installStateProvider = Provider<InstallState>(
  (_) => currentInstallState(),
);
