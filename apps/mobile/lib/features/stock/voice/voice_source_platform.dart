/// Picks the recorder by platform at compile time (PWA M4): the native build
/// records to a temporary file (the io library, `path_provider`), the web build
/// records in memory. Neither graph compiles the other's imports.
library;

export 'voice_source_platform_io.dart'
    if (dart.library.js_interop) 'voice_source_platform_web.dart';
