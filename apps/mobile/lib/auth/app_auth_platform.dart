/// Picks the OIDC adapter and the pointer store per target (PWA M2, D-112).
/// Native keeps `RealAppAuthAdapter` (flutter_appauth); web uses the redirect
/// flow in `web_app_auth_adapter.dart`.
library;

export 'app_auth_platform_types.dart';
export 'app_auth_platform_stub.dart'
    if (dart.library.js_interop) 'app_auth_platform_web.dart';
