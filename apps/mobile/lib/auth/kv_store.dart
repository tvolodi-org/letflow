/// Small key/value seams for the token store and the web sign-in (PWA M2,
/// D-112). Platform-neutral: no `flutter_secure_storage`, no `package:web`.
library;

/// Async key/value store behind [TenantTokenStore] (`auth.dart`).
abstract interface class KvStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Process-memory store. On web this holds the tokens: nothing a script on
/// the origin can read back after a reload.
class MemoryKv implements KvStore {
  final Map<String, String> _m = {};

  @override
  Future<String?> read(String key) async => _m[key];

  @override
  Future<void> write(String key, String value) async {
    _m[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _m.remove(key);
  }
}

/// Synchronous string storage with the shape of the browser's Web Storage.
/// Real implementations live in `web_browser.dart`; tests use a map.
abstract interface class StringStorage {
  String? getItem(String key);
  void setItem(String key, String value);
  void removeItem(String key);
}

/// JSON-over-HTTP seam for the web sign-in. The transport (Dio) lives only
/// in `lib/api/` (single-api-client guard); the implementation is
/// `newOidcHttp()` in `api_client.dart`. Throws on a non-2xx answer.
abstract interface class OidcHttp {
  Future<Map<String, dynamic>> getJson(Uri url);
  Future<Map<String, dynamic>> postForm(Uri url, Map<String, String> form);
}

/// A non-2xx answer of an OIDC endpoint. Carries the status and the OAuth
/// `error` code only (for example `invalid_grant`), never the body, so it is
/// safe to log. Lets the keep-signed-in unlock tell "the IdP refused this
/// refresh token" from "the network failed".
class OidcHttpError implements Exception {
  const OidcHttpError(this.statusCode, [this.error]);

  final int statusCode;
  final String? error;

  bool get isInvalidGrant => error == 'invalid_grant';

  @override
  String toString() => 'OIDC endpoint answered $statusCode';
}
