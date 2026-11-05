/// Barrel of the `codes` feature module (REQ-732), imported only by
/// `lib/bootstrap/navigation_bootstrap.dart`.
library;

export 'codes_routes.dart' show codesRoutes, kCodesScanPath;
export 'codes_resolve.dart'
    show
        CodesResolver,
        CodeResolution,
        CodeStatus,
        CodeObjectKind,
        MalformedResolveAnswer;
export 'scan_source.dart'
    show
        ScanSource,
        ScanEvent,
        ScanDetected,
        ScanPermissionRefused,
        scanSourceProvider;
