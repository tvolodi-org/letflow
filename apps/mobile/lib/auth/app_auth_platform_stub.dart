/// Native (non-web) side of `app_auth_platform.dart`.
library;

import 'auth.dart' show AppAuthAdapter, RealAppAuthAdapter;
import 'app_auth_platform_types.dart';
import 'kv_store.dart';
import 'session_crypto.dart';
import 'session_record.dart';
import 'web_app_auth_adapter.dart' show OidcRevoker;

AppAuthAdapter defaultAppAuthAdapter() => const RealAppAuthAdapter();

WebPendingSignIn? peekWebPendingSignIn() => null;

void rememberWebSignInSlug(String slug) {}

KvStore? webPointerKv() => null;

SessionCrypto? webSessionCrypto() => null;

SessionRecordStore? webSessionRecordStore() => null;

OidcRevoker? webOidcRevoker() => null;
