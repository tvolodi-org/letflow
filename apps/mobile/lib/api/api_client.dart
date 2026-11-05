/// The single `Dio`-construction site for the whole app (REQ-421 design
/// §7). Also houses the tenant-config response models (§2.1) and the
/// unauthenticated `tenant-config` fetch (§2.2).
///
/// **Invariant (AC8):** a repo-wide grep for a `Dio` constructor call must
/// return exactly one hit — the one inside [ApiClient.create] below. No
/// other file in `apps/mobile/lib` constructs a `Dio` instance. (This
/// comment deliberately spells the call differently from the real one so
/// it is not itself a second grep hit.)
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_appauth/flutter_appauth.dart' show TokenRequest;

import '../auth/auth.dart'
    show AppAuthAdapter, TenantTokenStore, TokenSet, issuerOf, kOidcRedirectUrl;
import 'api_error.dart';
import 'transport_policy.dart';

@immutable
class TenantBranding {
  const TenantBranding({
    required this.appName,
    required this.logoUrl,
    required this.primaryColor,
  });

  final String appName;
  final String? logoUrl;
  final String primaryColor;

  factory TenantBranding.fromJson(Map<String, dynamic> json) {
    return TenantBranding(
      appName: _requireString(json, 'app_name'),
      logoUrl: json['logo_url'] as String?,
      primaryColor: _requireString(json, 'primary_color'),
    );
  }
}

/// The mobile `tenant-config` response (`Letflow.Routers.MobileTenantConfig`,
/// REQ-421 design §2.1). `fromJson` is total over the backend's six-key
/// shape and throws [FormatException] on any missing/malformed key — the
/// bootstrap sequence treats a malformed response the same as an
/// unreachable one (no separate "malformed tenant-config" error screen).
@immutable
class TenantConfig {
  const TenantConfig({
    required this.realmUrl,
    required this.clientId,
    required this.locales,
    required this.defaultLocale,
    required this.branding,
    required this.environmentKind,
  });

  final String realmUrl;
  final String clientId;
  final List<String> locales;
  final String defaultLocale;
  final TenantBranding branding;
  final String environmentKind;

  factory TenantConfig.fromJson(Map<String, dynamic> json) {
    final brandingJson = json['branding'];
    if (brandingJson is! Map<String, dynamic>) {
      throw const FormatException(
        'TenantConfig.fromJson: missing or non-object "branding"',
      );
    }
    final localesJson = json['locales'];
    if (localesJson is! List) {
      throw const FormatException(
        'TenantConfig.fromJson: missing or non-array "locales"',
      );
    }
    return TenantConfig(
      realmUrl: _requireString(json, 'realm_url'),
      clientId: _requireString(json, 'client_id'),
      locales: localesJson.map((e) => e as String).toList(),
      defaultLocale: _requireString(json, 'default_locale'),
      branding: TenantBranding.fromJson(brandingJson),
      environmentKind: _requireString(json, 'environment_kind'),
    );
  }
}

String _requireString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('missing or non-string "$key"');
  }
  return value;
}

/// The narrow HTTP surface this requirement's callers need — an interface
/// so tests can supply a fake without touching Dio's transport layer.
/// [ApiClient] is the sole production implementation.
abstract class HttpGateway {
  Future<Response<dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
  });

  Future<Response<dynamic>> getUnauthenticated(
    String path, {
    Map<String, dynamic>? queryParameters,
  });
}

/// Extends [HttpGateway] with the one `POST` call REQ-426's list renderer
/// needs (`POST /api/v1/entities/query`). Kept as a separate interface,
/// never added directly to [HttpGateway], because `implements` requires a
/// class to re-implement every member an interface declares -- even one
/// given a default body upstream -- so adding a bare `post` method to
/// [HttpGateway] itself would have broken every existing `implements
/// HttpGateway` test double in `test/`, none of which have ever needed to
/// script a POST call. A caller that needs to POST (only the list renderer,
/// so far) depends on this narrower interface instead of the concrete
/// [ApiClient] class.
abstract class PostCapableHttpGateway implements HttpGateway {
  Future<Response<dynamic>> post(String path, {Object? data});
}

/// Adds `PUT` (the stock count's typed quantity, D3a). Separate from
/// [PostCapableHttpGateway] so existing test doubles keep compiling.
abstract class PutCapableHttpGateway implements PostCapableHttpGateway {
  Future<Response<dynamic>> put(String path, {Object? data});
}

/// Adds `DELETE` (stock document drafts, D3b) on top of `PUT`. Like [post],
/// neither is retried on a 5xx.
abstract class WriteCapableHttpGateway implements PutCapableHttpGateway {
  Future<Response<dynamic>> delete(String path);
}

/// Holds the `realm_url` of whichever tenant's bootstrap most recently
/// completed successfully — the bearer-attach interceptor's source of
/// truth for "the currently active tenant" (REQ-421 design §5.3/§7.2). A
/// plain mutable holder, not a build-time constant, so a second
/// `runTenantBootstrap` call (different tenant, same app instance) can
/// overwrite it with no rebuild.
class ActiveRealmHolder {
  String? currentRealmUrl;

  /// The active tenant's OIDC `client_id` (REQ-425 design §5.2) — needed by
  /// [_RefreshCoordinator] to build a `TokenRequest` for the refresh_token
  /// grant, alongside [currentRealmUrl]. Not part of REQ-421/422's original
  /// shape (those only ever needed `currentRealmUrl`); set by whichever code
  /// sets `currentRealmUrl` from a `TenantConfig` (`lib/bootstrap/
  /// navigation_bootstrap.dart`'s `runTenantBootstrap`/`switchTenant`).
  String? clientId;
}

/// A callback that routes the app to its login/tenant-entry screen
/// (REQ-425 design §2.4). A plain function type, not a `go_router`-specific
/// one, so `lib/api/` does not need to import the app's routing package —
/// the production closure (wherever [ApiClient.create] is constructed) is
/// responsible for actually navigating.
typedef LoginRouter = void Function();

/// Total HTTP requests sent (original + retries) for one logical GET call
/// against a persistent 5xx before giving up and surfacing [ServerError]
/// (design §3.1). GET-only — POST (and any future PUT/PATCH/DELETE) is never
/// auto-retried on 5xx (design §3.3).
const int kMaxServerRetryAttempts = 3;

/// Backoff formula constants (design §3.2): delay before attempt N+1 is
/// `kBaseServerRetryDelay * 2^(N-1)`, capped at [kMaxServerRetryDelay].
const Duration kBaseServerRetryDelay = Duration(milliseconds: 200);
const Duration kMaxServerRetryDelay = Duration(seconds: 5);

/// The delay to await after [attemptNumber] (1-based) has just failed with a
/// 5xx, before the next attempt. Deterministic and pure so a test can assert
/// on it directly without a real wall-clock wait.
Duration backoffDelayFor(int attemptNumber) {
  final scaled = kBaseServerRetryDelay * (1 << (attemptNumber - 1));
  return scaled > kMaxServerRetryDelay ? kMaxServerRetryDelay : scaled;
}

/// Request-`extra` flag marking a request as "already retried once after a
/// 401" (design §2.2 step 6) — set only on the request re-issued by
/// [_RefreshCoordinator]'s caller, never on a fresh caller-initiated
/// request. Its presence is the loop-prevention mechanism: a second 401 on
/// an already-retried request never triggers a second refresh.
const String _kRetriedAfter401Flag = '_letflowRetriedAfter401';

/// Request-`extra` key recording which tenant's `realm_url` was active when
/// [_bearerInterceptor] sent this request (rework of REQ-425 §2, cross-tenant
/// refresh race fix). A 401's refresh/retry flow must never silently
/// re-authenticate and re-serve a request under a *different* tenant than
/// the one it was issued for — this tag is the source of truth the retry
/// path re-checks against, independent of whatever tenant happens to be
/// active by the time the refresh resolves.
///
/// **rework 2:** this tag is also [_bearerInterceptor]'s OWN re-check at the
/// moment it actually attaches a token to a *retried* request (see that
/// interceptor's `onRequest`, below) — not just `_handleUnauthorized`'s
/// pre-fetch check. dio 5.11.1 schedules a `fetch()` call's interceptor
/// chain via a real event-loop turn (`Future(() => ...)`, `dio_mixin.dart`
/// `initState`/`fetch` internals, verified against the pinned
/// `pubspec.lock` version's pub-cache source), so a tenant switch/logout can
/// land strictly between `_handleUnauthorized`'s check and the interceptor's
/// own header-attach step. Trusting only the earlier check left that later
/// window open; the interceptor must re-verify itself, at the point it
/// actually decides whether to attach a token at all.
const String _kIssuedForRealmKey = '_letflowIssuedForRealm';

/// Marks a [DioException] thrown by [_bearerInterceptor]'s reject path when
/// it detects, at token-attach time, that a retried request's tagged realm
/// no longer matches the currently active tenant. Distinct from a generic
/// transport failure so [ApiClient._handleUnauthorized] can classify it as
/// [UnauthorizedError] rather than [NetworkUnavailableError] (`classifyError`
/// would otherwise see a `null` status code and misclassify this as a
/// connectivity problem).
class _CrossTenantRetryAbortedException implements Exception {
  const _CrossTenantRetryAbortedException();

  @override
  String toString() =>
      '_CrossTenantRetryAbortedException(retry dispatched under a realm '
      "different from the one it was issued for -- aborted before a token "
      'was attached)';
}

/// Outcome of one [_RefreshCoordinator._doRefresh] attempt. Distinct from a
/// plain `bool` so the caller ([ApiClient._handleUnauthorized]) can tell
/// "refresh genuinely failed, tokens cleared, routed to login" apart from
/// "refresh was abandoned mid-flight because the active tenant changed" —
/// the latter must never be treated as, or reported like, the former: it is
/// not this tenant's failure to report, and it must not retry as whatever
/// tenant is active now.
enum _RefreshOutcome { success, failed, aborted }

/// Mediates "concurrent 401s share one in-flight refresh" (design §2.1).
/// One instance per [ApiClient] — matches the single-client invariant this
/// whole requirement hardens.
class _RefreshCoordinator {
  _RefreshCoordinator({
    required TenantTokenStore tokenStore,
    required ActiveRealmHolder activeRealm,
    required AppAuthAdapter appAuthAdapter,
    required LoginRouter routeToLogin,
  }) : _tokenStore = tokenStore,
       _activeRealm = activeRealm,
       _appAuthAdapter = appAuthAdapter,
       _routeToLogin = routeToLogin;

  final TenantTokenStore _tokenStore;
  final ActiveRealmHolder _activeRealm;
  final AppAuthAdapter _appAuthAdapter;
  final LoginRouter _routeToLogin;

  /// Non-null while a refresh triggered by some 401 is in flight. Every
  /// caller that observes a 401 while this is non-null awaits THIS Future
  /// instead of starting a second refresh call.
  Future<_RefreshOutcome>? _inFlightRefresh;

  /// Returns [_RefreshOutcome.success] iff the refresh succeeded (new tokens
  /// stored under the SAME realm that was active when the refresh started)
  /// and the caller should retry its original request; [_RefreshOutcome.failed]
  /// iff refresh genuinely failed (tokens already cleared and login routing
  /// already triggered by the time this returns); [_RefreshOutcome.aborted]
  /// iff the active tenant changed (switchTenant/logout) while the refresh's
  /// network call was in flight, in which case NEITHER the old tenant's
  /// tokens were touched (no resurrection of a just-deleted/switched-away
  /// tenant's credentials) NOR is there anything to route to login for —
  /// whatever changed the active tenant already handled that.
  Future<_RefreshOutcome> refreshOnce() {
    final inFlight = _inFlightRefresh;
    if (inFlight != null) return inFlight;
    final future = _doRefresh();
    _inFlightRefresh = future;
    return future.whenComplete(() => _inFlightRefresh = null);
  }

  Future<_RefreshOutcome> _doRefresh() async {
    final realmUrl = _activeRealm.currentRealmUrl;
    if (realmUrl == null) {
      // No active tenant even before the network call started -- a
      // concurrent logout/switch already got here first and already handled
      // its own token clearing/login routing. Nothing for this refresh to
      // do or fail; routing to login again would be a spurious second call.
      return _RefreshOutcome.aborted;
    }
    final clientId = _activeRealm.clientId;
    final tokens = await _tokenStore.read(realmUrl);
    final refreshToken = tokens?.refreshToken;
    if (refreshToken == null) {
      await _handleFailure(realmUrl);
      return _RefreshOutcome.failed;
    }
    try {
      final response = await _appAuthAdapter.refresh(
        TokenRequest(
          clientId ?? '',
          kOidcRedirectUrl,
          issuer: realmUrl,
          refreshToken: refreshToken,
        ),
      );
      // Re-check BEFORE persisting anything: did switchTenant/logout flip the
      // active tenant while this `await` was suspended on the network call?
      // If so, `realmUrl` may already have had its tokens deleted by that
      // switch/logout -- writing the just-refreshed tokens back under it now
      // would resurrect a tenant the app believes it has left. Discard the
      // refreshed tokens silently instead of storing them anywhere.
      if (_activeRealm.currentRealmUrl != realmUrl ||
          _activeRealm.clientId != clientId) {
        return _RefreshOutcome.aborted;
      }
      final accessToken = response.accessToken;
      if (accessToken == null) {
        await _handleFailure(realmUrl);
        return _RefreshOutcome.failed;
      }
      final newTokens = TokenSet(
        accessToken: accessToken,
        refreshToken: response.refreshToken ?? refreshToken,
        idToken: response.idToken,
        accessTokenExpiration: response.accessTokenExpirationDateTime,
      );
      await _tokenStore.store(realmUrl, newTokens);
      return _RefreshOutcome.success;
    } catch (_) {
      // A tenant switch/logout that raced this failing refresh already
      // cleared/replaced whatever `realmUrl` pointed to -- do not clear the
      // NEW active tenant's tokens or re-route it to login under the guise
      // of handling the OLD tenant's refresh failure.
      if (_activeRealm.currentRealmUrl != realmUrl) {
        return _RefreshOutcome.aborted;
      }
      await _handleFailure(realmUrl);
      return _RefreshOutcome.failed;
    }
  }

  Future<void> _handleFailure(String? realmUrl) async {
    if (realmUrl != null) {
      await _tokenStore.delete(realmUrl);
    }
    _activeRealm.currentRealmUrl = null;
    _routeToLogin();
  }
}

class ApiClient implements WriteCapableHttpGateway {
  ApiClient._(
    this._dio,
    this._refreshCoordinator,
    this._delayFn,
    this._activeRealm,
  );

  final Dio _dio;
  final _RefreshCoordinator _refreshCoordinator;
  final Future<void> Function(Duration) _delayFn;

  /// Read (never written) by [_handleUnauthorized] to re-verify, after a
  /// refresh completes, that the active tenant is still the one the failing
  /// request was issued for (rework of REQ-425 §2, cross-tenant refresh
  /// race fix).
  final ActiveRealmHolder _activeRealm;

  static const String _apiBaseUrl = String.fromEnvironment(
    'LETFLOW_API_BASE_URL',
  );

  /// The one place a [Dio] instance is constructed in `apps/mobile/lib`
  /// (design §7.1, AC8). `baseUrl` defaults to the build-time `LETFLOW_API_BASE_URL`
  /// define, read once, here — never re-read anywhere else.
  ///
  /// `validateStatus` accepts every HTTP status code, so a 401/403/404/...
  /// arrives as a normal `Response` through the interceptor chain — this is
  /// *why* the refresh/retry/backoff logic below (REQ-425 design §2.5) is
  /// implemented as method-body logic inspecting `response.statusCode`,
  /// rather than a Dio `onError` interceptor, which would never fire for
  /// these statuses under this policy. A thrown [DioException] from this
  /// client therefore only ever indicates a genuine transport failure (no
  /// connectivity, DNS, timeout) — every such exception, and every non-2xx
  /// response, is normalized to an [ApiError] before it leaves this class
  /// (design §5.1's throwing convention).
  factory ApiClient.create({
    required TenantTokenStore tokenStore,
    required ActiveRealmHolder activeRealm,
    required AppAuthAdapter appAuthAdapter,
    required LoginRouter routeToLogin,
    String? baseUrl,
    TransportPolicy? transportPolicy,
    Future<void> Function(Duration) delayFn = Future.delayed,
    bool registerRedactingLog = true,
  }) {
    final dio = Dio(
      BaseOptions(baseUrl: baseUrl ?? _apiBaseUrl, validateStatus: (_) => true),
    );
    // Transport-policy rejection (REQ-422 §4.2, MOB-5, AC5) — added
    // *before* the bearer-attach interceptor so a rejected request never
    // reaches it (immaterial to correctness, keeps the reject path
    // cheapest) and, more importantly, so `handler.reject` runs strictly
    // before `HttpClientAdapter.fetch` — no socket is ever opened for a
    // disallowed URL.
    dio.interceptors.add(
      _transportPolicyInterceptor(transportPolicy ?? transportPolicyFor()),
    );
    dio.interceptors.add(_bearerInterceptor(tokenStore, activeRealm));
    if (registerRedactingLog) {
      dio.interceptors.add(const RedactingLogInterceptor());
    }
    final coordinator = _RefreshCoordinator(
      tokenStore: tokenStore,
      activeRealm: activeRealm,
      appAuthAdapter: appAuthAdapter,
      routeToLogin: routeToLogin,
    );
    return ApiClient._(dio, coordinator, delayFn, activeRealm);
  }

  /// Test-only seam: wraps a caller-supplied [Dio] (e.g. one configured
  /// with a fake `HttpClientAdapter`) so tests can exercise the real
  /// [ApiClient] wiring (interceptor, header attach, refresh/retry/backoff)
  /// without constructing a second one inside this file — the test builds
  /// the [Dio] instance itself, outside `apps/mobile/lib`. Auto-attaches the
  /// same bearer-attach interceptor [ApiClient.create] does (so a retry
  /// after a successful refresh re-reads the now-fresh token, design §2.6),
  /// but not the transport-policy interceptor or the redacting logger
  /// (tests exercise those, if at all, through their own dedicated fixtures).
  @visibleForTesting
  factory ApiClient.forTesting(
    Dio dio, {
    required TenantTokenStore tokenStore,
    required ActiveRealmHolder activeRealm,
    required AppAuthAdapter appAuthAdapter,
    required LoginRouter routeToLogin,
    Future<void> Function(Duration) delayFn = Future.delayed,
  }) {
    dio.interceptors.add(_bearerInterceptor(tokenStore, activeRealm));
    final coordinator = _RefreshCoordinator(
      tokenStore: tokenStore,
      activeRealm: activeRealm,
      appAuthAdapter: appAuthAdapter,
      routeToLogin: routeToLogin,
    );
    return ApiClient._(dio, coordinator, delayFn, activeRealm);
  }

  /// Throws [ApiError] (never [DioException]/[SocketException]) on any
  /// non-2xx outcome, after refresh/retry/backoff handling has already run.
  /// Returns the response unchanged on 2xx.
  @override
  Future<Response<dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) {
    return _sendWithBackoff(
      () => _dio.get<dynamic>(path, queryParameters: queryParameters),
      allowServerRetry: true,
    );
  }

  @override
  Future<Response<dynamic>> getUnauthenticated(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) {
    return _sendWithBackoff(
      () => _dio.get<dynamic>(
        path,
        queryParameters: queryParameters,
        options: Options(extra: const {'skipAuth': true}),
      ),
      allowServerRetry: true,
    );
  }

  /// No 5xx auto-retry (design §3.3) — a single attempt only, matching the
  /// "POST is not auto-retried" requirement text (no duplicate task
  /// completion). Still subject to the 401 refresh/retry flow (design §2)
  /// like every authenticated call, since that flow is orthogonal to
  /// retry-on-5xx. Throws [ApiError].
  @override
  Future<Response<dynamic>> post(String path, {Object? data}) {
    return _sendWithBackoff(
      () => _dio.post<dynamic>(path, data: data),
      allowServerRetry: false,
    );
  }

  /// Single attempt, like [post]; still subject to the 401 refresh flow.
  @override
  Future<Response<dynamic>> put(String path, {Object? data}) {
    return _sendWithBackoff(
      () => _dio.put<dynamic>(path, data: data),
      allowServerRetry: false,
    );
  }

  /// Single attempt, like [post]; still subject to the 401 refresh flow.
  @override
  Future<Response<dynamic>> delete(String path) {
    return _sendWithBackoff(
      () => _dio.delete<dynamic>(path),
      allowServerRetry: false,
    );
  }

  /// Implements design §3's GET-only 5xx backoff and design §2's 401
  /// refresh-then-retry, for one logical call. [allowServerRetry] is `true`
  /// only for GET/`getUnauthenticated` (design §3.3).
  Future<Response<dynamic>> _sendWithBackoff(
    Future<Response<dynamic>> Function() requestFn, {
    required bool allowServerRetry,
  }) async {
    final maxAttempts = allowServerRetry ? kMaxServerRetryAttempts : 1;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      Response<dynamic> response;
      try {
        response = await requestFn();
      } on DioException catch (e) {
        throw classifyError(
          e.requestOptions,
          statusCode: null,
          transportException: e,
        );
      }

      final status = response.statusCode;

      if (status != null && status >= 200 && status < 300) {
        return response;
      }

      // A 401 exits the backoff loop immediately and hands off to the
      // refresh/retry flow (design §3.3) — the two mechanisms are not
      // nested; the 401 flow's own retry result (success, terminal
      // UnauthorizedError, or a 5xx) is the final result of this call, with
      // no further backoff attempts (design §3.3/OQ-5's chosen behavior).
      if (status == 401) {
        return _handleUnauthorized(response);
      }

      final isServerError = status != null && status >= 500 && status <= 599;
      if (isServerError && allowServerRetry && attempt < maxAttempts) {
        await _delayFn(backoffDelayFor(attempt));
        continue;
      }

      throw classifyError(
        response.requestOptions,
        statusCode: status,
        retryAfterHeader: response.headers.value('retry-after'),
        responseBody: response.data,
      );
    }

    // Unreachable (the loop above always returns or throws before falling
    // off its last iteration), but required so every code path returns.
    throw const ServerError();
  }

  /// The 401 refresh-then-retry sequence (design §2.2). [response] is the
  /// 401 response observed on some attempt; on success, this method retries
  /// that exact request exactly once through the same [_dio] instance (so
  /// the bearer-attach interceptor re-reads the just-refreshed token).
  Future<Response<dynamic>> _handleUnauthorized(
    Response<dynamic> response,
  ) async {
    final requestOptions = response.requestOptions;

    // An unauthenticated call (no Authorization header to begin with) has
    // no token to refresh usefully — skip the whole flow (design §2.2
    // step 7, mirrors `_bearerInterceptor`'s own `skipAuth` short-circuit).
    if (requestOptions.extra['skipAuth'] == true) {
      throw const UnauthorizedError();
    }

    // A second 401 on a request already retried once after a 401: terminal,
    // no second refresh, ever (design §2.2 step 6 — the loop-prevention
    // rule).
    if (requestOptions.extra[_kRetriedAfter401Flag] == true) {
      throw const UnauthorizedError();
    }

    // The tenant this request was issued for (tagged by `_bearerInterceptor`
    // at send time), captured BEFORE awaiting the refresh below — this is
    // what the post-refresh re-check compares against, never whatever tenant
    // happens to be active once the refresh (a real network round-trip)
    // resolves.
    final issuedForRealm = requestOptions.extra[_kIssuedForRealmKey] as String?;

    final outcome = await _refreshCoordinator.refreshOnce();
    if (outcome != _RefreshOutcome.success) {
      // Either refresh genuinely failed (tokens already cleared and login
      // routing already triggered by `_RefreshCoordinator` itself, design
      // §2.2 step 5) or it was aborted because the active tenant changed
      // mid-refresh (rework of REQ-425 §2) — either way, the caller only
      // ever gets the typed error, never a silent retry under some other
      // tenant's identity.
      throw const UnauthorizedError();
    }

    // Re-check BEFORE reissuing the retry: even though the coordinator's
    // refresh succeeded, it may have succeeded for a tenant OTHER than the
    // one this specific request was issued for (e.g. this request's 401 was
    // for tenant A, but by the time it called `refreshOnce()` a switch to
    // tenant B was already in flight and its refresh is what completed) --
    // never silently re-authenticate and re-serve this request as a
    // different tenant than the caller expects.
    if (issuedForRealm != null &&
        issuedForRealm != _activeRealm.currentRealmUrl) {
      throw const UnauthorizedError();
    }

    final retriedOptions = requestOptions.copyWith(
      extra: {...requestOptions.extra, _kRetriedAfter401Flag: true},
    );

    Response<dynamic> retryResponse;
    try {
      retryResponse = await _dio.fetch<dynamic>(retriedOptions);
    } on DioException catch (e) {
      // `_bearerInterceptor` rejects with this sentinel when ITS OWN
      // token-attach-time re-check (the fix for the retry-dispatch race,
      // rework 2) finds the retry's tagged realm no longer matches the
      // active tenant -- report it as the typed auth failure it is, not
      // fall through to `classifyError`'s generic null-status-code ->
      // network-unavailable path.
      if (e.error is _CrossTenantRetryAbortedException) {
        throw const UnauthorizedError();
      }
      throw classifyError(
        e.requestOptions,
        statusCode: null,
        transportException: e,
      );
    }

    final retryStatus = retryResponse.statusCode;
    if (retryStatus != null && retryStatus >= 200 && retryStatus < 300) {
      return retryResponse;
    }
    if (retryStatus == 401) {
      // Recurses once more, purely to reuse the classification above; the
      // `_kRetriedAfter401Flag` set on `retriedOptions` guarantees this
      // second pass takes the terminal branch immediately, with no second
      // refresh call.
      return _handleUnauthorized(retryResponse);
    }
    throw classifyError(
      retryResponse.requestOptions,
      statusCode: retryStatus,
      retryAfterHeader: retryResponse.headers.value('retry-after'),
      responseBody: retryResponse.data,
    );
  }
}

/// Transport-policy enforcement interceptor (REQ-422 §4.2, MOB-5, AC5) —
/// rejects any request whose absolute URL [policy] disallows, strictly
/// before Dio's `HttpClientAdapter.fetch` runs (`handler.reject` never
/// calls `handler.next`, so the fake HTTP layer records zero calls for a
/// rejected URL in tests).
Interceptor _transportPolicyInterceptor(TransportPolicy policy) {
  return InterceptorsWrapper(
    onRequest: (options, handler) {
      final uri = options.uri;
      if (!policy.isUrlAllowed(uri)) {
        handler.reject(
          DioException(
            requestOptions: options,
            error: TransportPolicyRejectedException(
              uri,
              isRelease: policy is ReleaseTransportPolicy,
            ),
            type: DioExceptionType.unknown,
          ),
        );
        return;
      }
      handler.next(options);
    },
  );
}

/// Bearer-attach interceptor (design §7.2) — attaches nothing beyond that,
/// except the audience check added by REQ-422 §6.2 below. Refresh-on-401,
/// retry, and typed `ApiError` normalization are REQ-425's (MOB-6) scope,
/// not this one's.
///
/// **rework 2 (retry-dispatch race, `_kIssuedForRealmKey`'s doc comment):**
/// on a request already carrying an `_kIssuedForRealmKey` tag -- i.e. a
/// retry re-dispatched by `_handleUnauthorized` after a 401 refresh, never a
/// fresh caller-initiated request -- this interceptor re-verifies that tag
/// against the realm active RIGHT NOW, at the point it is about to decide
/// whether to attach a token, and rejects outright on any mismatch. This is
/// deliberately a SEPARATE, later check from `_handleUnauthorized`'s own
/// pre-fetch one: dio 5.11.1 schedules `fetch()`'s interceptor chain via a
/// real event-loop turn, so a tenant switch/logout can land strictly
/// between that pre-fetch check and this interceptor running -- trusting
/// only the earlier check left exactly that window open (a retry issued for
/// tenant A could be dispatched carrying tenant B's freshly-active bearer
/// token). The realm value used for the token-store read and the header
/// attach below is the SAME local `realmUrl` captured before this check --
/// never re-read from `activeRealm` after the `await tokenStore.read` below
/// -- so nothing (including that await's own suspension) can substitute a
/// different tenant's token once this check has passed.
Interceptor _bearerInterceptor(
  TenantTokenStore tokenStore,
  ActiveRealmHolder activeRealm,
) {
  return InterceptorsWrapper(
    onRequest: (options, handler) async {
      if (options.extra['skipAuth'] == true) {
        handler.next(options);
        return;
      }
      final realmUrl = activeRealm.currentRealmUrl;
      final isRetryDispatch = options.extra.containsKey(_kIssuedForRealmKey);
      if (isRetryDispatch) {
        final issuedForRealm = options.extra[_kIssuedForRealmKey] as String?;
        if (issuedForRealm != realmUrl) {
          handler.reject(
            DioException(
              requestOptions: options,
              error: const _CrossTenantRetryAbortedException(),
              type: DioExceptionType.cancel,
            ),
          );
          return;
        }
      } else {
        // First (non-retry) pass for this request -- tag it with the tenant
        // it is being issued for now. `_handleUnauthorized` reads this back
        // for its own pre-fetch check, and this interceptor reads it back
        // again (the branch above) the next time this same request -- now a
        // retry -- passes through here.
        options.extra[_kIssuedForRealmKey] = realmUrl;
      }
      if (realmUrl != null) {
        final tokens = await tokenStore.read(realmUrl);
        if (tokens != null && _tokenMatchesActiveRealm(tokens, realmUrl)) {
          options.headers['Authorization'] = 'Bearer ${tokens.accessToken}';
        }
      }
      handler.next(options);
    },
  );
}

/// Audience-scoping check (REQ-422 §6.2, MOB-5, AC7) — defense-in-depth on
/// top of [TenantTokenStore]'s per-`realm_url` storage keying (the primary
/// isolation mechanism, REQ-421 §4.1). Returns `true` (attach the token)
/// iff [tokens]' `iss` claim equals [activeRealmUrl] exactly, **or** the
/// `iss` claim cannot be determined at all (fails open only when
/// undeterminable — never on a determinable mismatch, per design §6.2's
/// OQ-4).
bool _tokenMatchesActiveRealm(TokenSet tokens, String activeRealmUrl) {
  final iss = issuerOf(tokens);
  return iss == null || iss == activeRealmUrl;
}

/// Redacts secret-bearing request/response surfaces before handing them to
/// [logSink] (REQ-422 §2, MOB-5, AC2). **Not registered** by REQ-422 — see
/// `lib/letflow/design/req422-mobile-security-hardening.md` §2.1/OQ-1: no
/// unredacted `LogInterceptor`/third-party logger is registered anywhere in
/// this app today (the "absent" branch already satisfies AC2), so this
/// class exists as reusable infrastructure for REQ-425 (MOB-6) to adopt
/// when it has an actual need to log Dio traffic.
/// `debugPrint` (`package:flutter/foundation.dart`) is a mutable top-level
/// variable, not a compile-time constant, so it cannot be used directly as
/// a `const` constructor's default parameter value — this thin top-level
/// forwarding function is, and is [RedactingLogInterceptor]'s actual
/// default.
void _defaultLogSink(String message) => debugPrint(message);

@immutable
class RedactingLogInterceptor extends Interceptor {
  const RedactingLogInterceptor({this.logSink = _defaultLogSink});

  /// Injectable for tests. Defaults to `debugPrint` via [_defaultLogSink].
  final void Function(String) logSink;

  /// Token/refresh-token-endpoint paths whose request/response bodies are
  /// always fully redacted, regardless of shape — a refresh token or
  /// access token can appear in either the request
  /// (`grant_type=refresh_token&refresh_token=...`) or the response body.
  static const List<String> _tokenEndpointSuffixes = [
    '/protocol/openid-connect/token',
    '/oauth2/token',
  ];

  static const String _redacted = '[REDACTED]';

  bool _isTokenEndpoint(String path) {
    final lower = path.toLowerCase();
    return _tokenEndpointSuffixes.any((s) => lower.endsWith(s.toLowerCase()));
  }

  Map<String, dynamic> _redactHeaders(Map<String, dynamic> headers) {
    final redacted = <String, dynamic>{};
    for (final entry in headers.entries) {
      redacted[entry.key] = entry.key.toLowerCase() == 'authorization'
          ? _redacted
          : entry.value;
    }
    return redacted;
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final headers = _redactHeaders(options.headers);
    final body = _isTokenEndpoint(options.path) ? _redacted : options.data;
    logSink(
      '--> ${options.method} ${options.path} headers=$headers body=$body',
    );
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final headers = _redactHeaders(
      response.headers.map.map((k, v) => MapEntry(k, v.join(','))),
    );
    final body = _isTokenEndpoint(response.requestOptions.path)
        ? _redacted
        : response.data;
    logSink(
      '<-- ${response.statusCode} ${response.requestOptions.path}'
      ' headers=$headers body=$body',
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final path = err.requestOptions.path;
    final body = _isTokenEndpoint(path) ? _redacted : err.message;
    logSink('<-x $path error=$body');
    handler.next(err);
  }
}

/// Fetches the unauthenticated `tenant-config` for [slug] (design §2.2).
/// Throws (a [DioException] or a [FormatException]) on any transport
/// failure or malformed response — `runTenantBootstrap` catches both and
/// maps them to `BootstrapFailureReason.networkUnavailable`.
Future<TenantConfig> fetchTenantConfig(
  String slug, {
  required HttpGateway client,
}) async {
  final response = await client.getUnauthenticated(
    '/api/mobile/tenant-config',
    queryParameters: {'slug': slug},
  );
  final status = response.statusCode ?? 0;
  if (status < 200 || status >= 300) {
    throw DioException(
      requestOptions: response.requestOptions,
      response: response,
    );
  }
  return TenantConfig.fromJson(response.data as Map<String, dynamic>);
}

/// Builds a multipart request body for `POST /instances/:id/attachments`
/// (REQ-212's `handle_upload_attachment/2` contract, REQ-427 §1.3/§6.3) —
/// the one place outside this directory that needs a `dio` multipart type
/// constructed, kept here (not in `lib/renderers/form/`) so every
/// `package:dio` import in this codebase stays inside `lib/api/`
/// (`test/guards/single_api_client_guard_test.dart`, REQ-425 design §4).
/// Returned as `Object` (the exact type `HttpGateway.post`'s own `data`
/// parameter already accepts) so a caller outside `lib/api/` never needs to
/// import `package:dio` itself just to pass this value through.
///
/// [partName] is the multipart field name the server's own
/// `conn.body_params["file"]` lookup expects — always `"file"` for the real
/// attachment-upload route; parameterized only so a test fixture can prove
/// the wrong part name is rejected without duplicating this function.
/// [fields] are extra text parts sent before the file (REQ-747: `lang`).
Object buildFileUploadFormData({
  required List<int> bytes,
  required String fileName,
  required String contentType,
  String partName = 'file',
  Map<String, String> fields = const {},
}) {
  return FormData.fromMap({
    ...fields,
    partName: MultipartFile.fromBytes(
      bytes,
      filename: fileName,
      contentType: DioMediaType.parse(contentType),
    ),
  });
}
