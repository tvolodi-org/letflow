/// Web side of `app_auth_platform.dart`.
library;

import '../api/api_client.dart' show newOidcHttp, newOidcRevocationHttp;
import 'auth.dart' show AppAuthAdapter;
import 'app_auth_platform_types.dart';
import 'device_unlock.dart';
import 'kv_store.dart';
import 'session_crypto.dart';
import 'session_record.dart';
import 'web_app_auth_adapter.dart';
import 'web_browser.dart';
import 'web_device_unlock.dart';
import 'web_pointer_kv.dart';
import 'web_session_crypto.dart';
import 'web_session_idb.dart';

final BrowserLocation _location = BrowserLocation();
final BrowserStorage _session = BrowserStorage.tab();

final WebAppAuthAdapter _adapter = WebAppAuthAdapter(
  http: newOidcHttp(),
  location: _location,
  session: _session,
);

AppAuthAdapter defaultAppAuthAdapter() => _adapter;

WebPendingSignIn? peekWebPendingSignIn() => peekPending(_location, _session);

/// The slug has to survive the redirect; the adapter runs before the tenant
/// pointer is written, so it travels in its own tab-scoped key.
void rememberWebSignInSlug(String slug) => _session.setItem(kWebSlugKey, slug);

KvStore? webPointerKv() => WebPointerKv(BrowserStorage.persistent());

SessionCrypto? webSessionCrypto() => WebSessionCrypto();

SessionRecordStore? webSessionRecordStore() => WebSessionRecordStore();

OidcRevoker? webOidcRevoker() =>
    OidcRevoker(discovery: newOidcHttp(), post: newOidcRevocationHttp());

DeviceUnlockAuthenticator? webDeviceUnlock() => WebDeviceUnlock();
