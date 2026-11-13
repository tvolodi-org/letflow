/// Auth: OIDC Authorization-Code + PKCE via `flutter_appauth`, with tokens
/// stored exclusively in OS-secure storage (`flutter_secure_storage`) —
/// `docs/mobile/architecture.md` §2, `MOB-5`'s security invariant. Built
/// starting REQ-421 (MOB-2).
///
/// This is the ONLY storage path for tokens anywhere in the app —
/// [TenantTokenStore] is the sole class that calls into
/// `flutter_secure_storage`. No plain-preferences fallback exists.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/api_client.dart' show TenantConfig;
import 'app_auth_platform.dart' show webPointerKv;
import 'keep_signed_in.dart' show KeepSignedIn, SessionSyncKv;
import 'kv_store.dart';

/// Matches the Keycloak client's sole registered `redirectUris` entry
/// (REQ-418 §1.1) — literal, fixed, never derived from tenant config.
const String kOidcRedirectUrl = 'com.bizdala.letflow:/oauth2redirect';

/// Platform-default scope set (design §3.1, OQ-2) — no tenant-specific
/// scope.
const List<String> kOidcScopes = ['openid', 'profile', 'email'];

/// Scopes of the web sign-in when the 30-day sign-in is on (REQ-810): the
/// platform set plus `offline_access`, so the IdP issues an offline refresh
/// token. Never used on native, never with the flag off.
const List<String> kOidcScopesWeb = [...kOidcScopes, 'offline_access'];

@immutable
class TokenSet {
  const TokenSet({
    required this.accessToken,
    required this.refreshToken,
    required this.idToken,
    required this.accessTokenExpiration,
  });

  final String accessToken;
  final String? refreshToken;
  final String? idToken;
  final DateTime? accessTokenExpiration;

  Map<String, dynamic> toJson() => {
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'id_token': idToken,
    'access_token_expiration': accessTokenExpiration?.toIso8601String(),
  };

  factory TokenSet.fromJson(Map<String, dynamic> json) {
    final expirationRaw = json['access_token_expiration'] as String?;
    return TokenSet(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String?,
      idToken: json['id_token'] as String?,
      accessTokenExpiration: expirationRaw == null
          ? null
          : DateTime.parse(expirationRaw),
    );
  }

  factory TokenSet.fromAuthorizationTokenResponse(
    AuthorizationTokenResponse response,
  ) {
    final accessToken = response.accessToken;
    if (accessToken == null) {
      throw StateError(
        'AuthorizationTokenResponse carried no accessToken on a '
        'non-cancelled, non-throwing result',
      );
    }
    return TokenSet(
      accessToken: accessToken,
      refreshToken: response.refreshToken,
      idToken: response.idToken,
      accessTokenExpiration: response.accessTokenExpirationDateTime,
    );
  }
}

/// [KvStore] over `flutter_secure_storage` — the native backend.
class _SecureKv implements KvStore {
  const _SecureKv(this._s);

  final FlutterSecureStorage _s;

  @override
  Future<String?> read(String key) => _s.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _s.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

/// The one [FlutterSecureStorage] configuration of the app (PWA M3, D-112).
///
/// On web the plugin keeps its AES key next to the ciphertext, so the data is
/// only as safe as the storage area it sits in. With `useSessionStorage` both
/// live in `sessionStorage`: gone when the PWA/tab process closes, never in
/// long-lived browser storage. Consequence: on web the user signs in again
/// after closing the app (the offline draft queue, in IndexedDB, survives).
/// Android / iOS options are unchanged.
FlutterSecureStorage productionSecureStorage({bool web = kIsWeb}) =>
    FlutterSecureStorage(
      aOptions: const AndroidOptions(),
      iOptions: const IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
      webOptions: web
          ? const WebOptions(useSessionStorage: true)
          : WebOptions.defaultOptions,
    );

/// The one token-store class (REQ-421 design §4). Keyed by `realmUrl`, not
/// the entered slug — the secure-storage key is derived from the
/// backend-verified `realm_url`, never the user-claimed slug, which is
/// what keeps tenant B's calls from ever carrying tenant A's token even
/// when two different unresolvable slugs both fall back to the same
/// default realm (REQ-124's anti-enumeration behavior).
///
/// Key rotation, biometric gating, and tamper detection are **not** part of
/// REQ-422's requirement text (BUILDS items 1–7) and are not implemented
/// here — see REQ-422 design §"OQ-6" if a later requirement expects them
/// under this label.
class TenantTokenStore {
  const TenantTokenStore(FlutterSecureStorage storage)
    : _secure = storage,
      _tokensKv = null,
      _pointerKv = null;

  /// Backends chosen by the caller (web, tests). `tokens` holds credentials,
  /// `pointer` only the non-secret last-active-tenant pointer.
  const TenantTokenStore.withBackends({
    required KvStore tokens,
    required KvStore pointer,
  }) : _secure = null,
       _tokensKv = tokens,
       _pointerKv = pointer;

  /// Hardened production constructor (REQ-422 §1.2, MOB-5, BUILDS item 1) —
  /// the only call site that should ever construct a [TenantTokenStore] in
  /// production code. Wraps a single [FlutterSecureStorage] instance whose
  /// `aOptions`/`iOptions` defaults apply to every `read`/`write`/`delete`
  /// made through it:
  ///
  /// - iOS: `KeychainAccessibility.first_unlock_this_device` — unlocks only
  ///   after the device's first unlock post-boot, and is never included in
  ///   an iCloud Keychain backup/sync (no `synchronizable` flag is set;
  ///   the plugin's iCloud-sync option defaults to unset/`false`).
  ///
  /// **Package-version note (mirrors [RealAppAuthAdapter]'s own):** the
  /// design (§1.2) specifies `AndroidOptions(encryptedSharedPreferences:
  /// true)`. The pinned `flutter_secure_storage: ^11.2.0` (`pubspec.yaml`)
  /// removed that named parameter — `AndroidOptions`'s **default**
  /// constructor (used here, unadorned) is v11's own strong-security
  /// baseline: AES/GCM/NoPadding data encryption with an Android-Keystore
  /// RSA-OAEP-wrapped key, i.e. the modern superset of what
  /// `encryptedSharedPreferences: true` requested in the pre-v11 API. No
  /// parameter is needed to opt into it; passing the plain `AndroidOptions()`
  /// default *is* the hardened choice under this pinned version.
  factory TenantTokenStore.production() {
    // Web (PWA M2, D-112): tokens in memory only, the pointer in browser storage
    // through a store that accepts that one key. See README, "Web sign-in".
    // The M3 sessionStorage configuration ([productionSecureStorage]) is not
    // used for tokens on web: its AES key sits next to the ciphertext.
    final ptr = webPointerKv();
    if (kIsWeb && ptr != null) {
      return TenantTokenStore.withBackends(tokens: MemoryKv(), pointer: ptr);
    }
    return TenantTokenStore(productionSecureStorage());
  }

  /// Web with the 30-day sign-in on (REQ-810): the tokens stay in memory, and
  /// every new refresh token is also re-sealed into the encrypted record.
  factory TenantTokenStore.productionKeepSignedIn(KeepSignedIn keepSignedIn) {
    final ptr = webPointerKv();
    if (kIsWeb && ptr != null) {
      return TenantTokenStore.withBackends(
        tokens: SessionSyncKv(MemoryKv(), keepSignedIn),
        pointer: ptr,
      );
    }
    return TenantTokenStore(productionSecureStorage());
  }

  // `const` constructors cannot wrap the storage in a [KvStore], so the
  // native wrapper is made on demand.
  final FlutterSecureStorage? _secure;
  final KvStore? _tokensKv;
  final KvStore? _pointerKv;

  KvStore get _tokens => _tokensKv ?? _SecureKv(_secure!);
  KvStore get _pointer => _pointerKv ?? _SecureKv(_secure!);

  static String _keyFor(String realmUrl) => 'letflow.tenant_tokens.$realmUrl';

  /// A thrown [PlatformException] from the underlying secure storage
  /// (Keystore/Keychain unavailable) propagates — the caller is
  /// responsible for catching it and routing to
  /// `SecureStorageUnavailableScreen`.
  Future<void> store(String realmUrl, TokenSet tokens) {
    return _tokens.write(_keyFor(realmUrl), jsonEncode(tokens.toJson()));
  }

  Future<TokenSet?> read(String realmUrl) async {
    final raw = await _tokens.read(_keyFor(realmUrl));
    if (raw == null) return null;
    return TokenSet.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> delete(String realmUrl) {
    return _tokens.delete(_keyFor(realmUrl));
  }
}

// ── §7.3 Last-active-tenant pointer (REQ-423 design §7.3) ──────────────────
//
// Persisted alongside tokens, in the same `TenantTokenStore`-backed
// `FlutterSecureStorage` instance, under a second fixed key — not a new
// storage class, no new dependency. This is what lets
// `BootstrapController.attemptSessionResume()` reach a previously-
// authenticated tenant's identity with zero network calls.

const String _lastActiveTenantKey = 'letflow.last_active_tenant';

/// Key of the user's language choice, kept in the same non-secret store as
/// the pointer (survives a restart; web: browser storage).
const String _uiLocalePrefKey = 'letflow.ui_locale';

/// Reads the language the user picked on this device, or `null`.
Future<String?> readUiLocalePref(TenantTokenStore tokenStore) async {
  try {
    return await tokenStore._pointer.read(_uiLocalePrefKey);
  } catch (_) {
    return null;
  }
}

/// Remembers [locale] on this device. Never throws: a failed write only
/// means the choice is not remembered after a restart.
Future<void> writeUiLocalePref(
  TenantTokenStore tokenStore,
  String locale,
) async {
  try {
    await tokenStore._pointer.write(_uiLocalePrefKey, locale);
  } catch (_) {}
}

@immutable
class LastActiveTenantPointer {
  const LastActiveTenantPointer({required this.realmUrl, required this.slug});

  final String realmUrl;
  final String slug;

  Map<String, dynamic> toJson() => {'realm_url': realmUrl, 'slug': slug};

  factory LastActiveTenantPointer.fromJson(Map<String, dynamic> json) {
    return LastActiveTenantPointer(
      realmUrl: json['realm_url'] as String,
      slug: json['slug'] as String,
    );
  }
}

/// Writes [pointer] via [tokenStore]'s own storage instance (same-library
/// access to its private `_pointer` field — see [TenantTokenStore]).
Future<void> writeLastActiveTenant(
  TenantTokenStore tokenStore,
  LastActiveTenantPointer pointer,
) {
  return tokenStore._pointer.write(
    _lastActiveTenantKey,
    jsonEncode(pointer.toJson()),
  );
}

/// Reads the last-active-tenant pointer, or `null` if none has ever been
/// written (or it has been cleared).
Future<LastActiveTenantPointer?> readLastActiveTenant(
  TenantTokenStore tokenStore,
) async {
  final raw = await tokenStore._pointer.read(_lastActiveTenantKey);
  if (raw == null) return null;
  return LastActiveTenantPointer.fromJson(
    jsonDecode(raw) as Map<String, dynamic>,
  );
}

/// Clears the last-active-tenant pointer — called from the same two places
/// `ActiveDefinitionCacheHolder.closeAndClear()` is: `switchTenant`'s
/// pre-delete branch and `logout`.
Future<void> clearLastActiveTenant(TenantTokenStore tokenStore) {
  return tokenStore._pointer.delete(_lastActiveTenantKey);
}

/// Fake-adapter seam for `flutter_appauth` (REQ-421 design §3.2) — the
/// widget/unit tests plug a fake implementation in here instead of driving
/// a real Custom Tab / native AppAuth SDK.
abstract class AppAuthAdapter {
  Future<AuthorizationTokenResponse?> authorizeAndExchangeCode(
    AuthorizationTokenRequest request,
  );

  /// Performs an OIDC `refresh_token` grant (REQ-425 design §5.2) by
  /// delegating to `FlutterAppAuth.token(TokenRequest(...))` — the pinned
  /// `flutter_appauth 12.1.0`'s only refresh-capable call. Returns the new
  /// [TokenResponse] on success. Throws on any failure (network,
  /// `invalid_grant`, expired refresh token, etc.) — the caller
  /// (`_RefreshCoordinator._doRefresh` in `lib/api/api_client.dart`) treats
  /// every exception type uniformly as refresh failure.
  Future<TokenResponse> refresh(TokenRequest request);
}

/// Production wrapper around the real `flutter_appauth` plugin.
///
/// **Package-version note:** the design (§3.1) describes
/// `authorizeAndExchangeCode` returning `null` on user cancellation. The
/// pinned `flutter_appauth: ^12.1.0` (`pubspec.yaml`) instead *throws*
/// `FlutterAppAuthUserCancelledException` on cancellation — its
/// `authorizeAndExchangeCode` returns a non-nullable
/// `Future<AuthorizationTokenResponse>`. This adapter absorbs exactly that
/// one exception type and returns `null`, so [AppAuthAdapter]'s
/// null-on-cancel contract (and therefore `authenticateWithTenant`'s own)
/// holds regardless of which mechanism this exact dependency version uses
/// to signal it. Every other exception (a genuine OIDC-protocol failure)
/// propagates unmodified.
class RealAppAuthAdapter implements AppAuthAdapter {
  const RealAppAuthAdapter();

  @override
  Future<AuthorizationTokenResponse?> authorizeAndExchangeCode(
    AuthorizationTokenRequest request,
  ) async {
    try {
      return await const FlutterAppAuth().authorizeAndExchangeCode(request);
    } on FlutterAppAuthUserCancelledException {
      return null;
    }
  }

  @override
  Future<TokenResponse> refresh(TokenRequest request) {
    return const FlutterAppAuth().token(request);
  }
}

/// Runs the OIDC Authorization-Code + PKCE flow for [config] (design §3.1).
/// `clientId`/`issuer` are sourced from [config] — **never** a compiled
/// Dart constant. PKCE is S256, `flutter_appauth`'s own default behavior
/// for `AuthorizationTokenRequest` (no explicit code-verifier/challenge
/// construction here — the package generates and validates it internally;
/// `AuthorizationTokenRequest`'s constructor does not even accept a
/// `codeVerifier` parameter, unlike the lower-level `TokenRequest` it
/// extends, which is this app's proof that no explicit PKCE override is
/// possible at this call site).
///
/// Returns `null` on user cancellation. Lets any other exception from
/// [appAuthAdapter] (a genuine OIDC-protocol failure) propagate — the
/// caller (`runTenantBootstrap`) is responsible for catching it and
/// routing to `OidcFailureScreen`.
///
/// **`allowInsecureConnections`:** derived from `config.realmUrl`'s own
/// scheme, never hardcoded — the native AppAuth SDK (Android) refuses a
/// plain-`http` issuer/discovery connection unless this flag is set
/// (`only https connections are permitted`, `DefaultConnectionBuilder`).
/// Setting it based on the disclosed `realm_url`'s own scheme grants no
/// *new* trust: the client already only ever connects to whatever URL the
/// tenant-config response specified, over whatever scheme that response
/// specified. A real deployment's `realm_url` is always `https://`, so
/// this is `false` in production; only a local/dev backend that discloses
/// an `http://` realm (e.g. a local Keycloak with no TLS in front of it)
/// makes this `true`.
Future<AuthorizationTokenResponse?> authenticateWithTenant(
  TenantConfig config, {
  AppAuthAdapter appAuthAdapter = const RealAppAuthAdapter(),
  List<String> scopes = kOidcScopes,
}) {
  final allowInsecureConnections =
      Uri.tryParse(config.realmUrl)?.scheme != 'https';
  final request = AuthorizationTokenRequest(
    config.clientId,
    kOidcRedirectUrl,
    issuer: config.realmUrl,
    scopes: scopes,
    allowInsecureConnections: allowInsecureConnections,
  );
  return appAuthAdapter.authorizeAndExchangeCode(request);
}

// ── Audience scoping (REQ-422 §6, MOB-5, AC7) ──────────────────────────────
//
// A pure, `dart:convert`-only JWT-payload decode — no signature
// verification (the server already verified the token; this is a
// same-device "does this token belong to the tenant I'm about to call"
// sanity check, not a trust boundary), and no new pubspec dependency.

/// Decodes the middle (payload) segment of [jwt] and returns it as a JSON
/// map, or `null` on any failure (malformed/opaque token, wrong segment
/// count, invalid base64url, invalid JSON) — never throws.
Map<String, dynamic>? decodeJwtPayload(String jwt) {
  final segments = jwt.split('.');
  if (segments.length != 3) return null;
  try {
    final normalized = base64Url.normalize(segments[1]);
    final decodedBytes = base64Url.decode(normalized);
    final decodedString = utf8.decode(decodedBytes);
    final decoded = jsonDecode(decodedString);
    if (decoded is! Map<String, dynamic>) return null;
    return decoded;
  } catch (_) {
    return null;
  }
}

/// Returns the `iss` claim of [tokens]' ID token, falling back to its
/// access token if no ID token was stored — `null` if neither decodes to a
/// string `iss` claim (REQ-422 §6.1).
String? issuerOf(TokenSet tokens) {
  final payload = decodeJwtPayload(tokens.idToken ?? tokens.accessToken);
  final iss = payload?['iss'];
  return iss is String ? iss : null;
}
