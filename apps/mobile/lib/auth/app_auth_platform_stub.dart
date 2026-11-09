/// Native (non-web) side of `app_auth_platform.dart`.
library;

import 'auth.dart' show AppAuthAdapter, RealAppAuthAdapter;
import 'app_auth_platform_types.dart';
import 'kv_store.dart';

AppAuthAdapter defaultAppAuthAdapter() => const RealAppAuthAdapter();

WebPendingSignIn? peekWebPendingSignIn() => null;

void rememberWebSignInSlug(String slug) {}

KvStore? webPointerKv() => null;
