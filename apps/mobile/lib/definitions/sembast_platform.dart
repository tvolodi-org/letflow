/// Platform storage helpers for the production sembast caches (PWA M1, D-112).
/// `dart:io` + `path_provider` on Android/iOS, IndexedDB (`sembast_web`) on web.
library;

export 'sembast_platform_io.dart'
    if (dart.library.js_interop) 'sembast_platform_web.dart';
