/// The one sanctioned navigation-bootstrap file: this is the single place
/// outside `lib/features/<id>/` permitted to import from inside a
/// feature's tree, because it is the file that reads the installed-module
/// list (`GET /api/v1/me/modules`) and wires the route table accordingly
/// (`docs/mobile/architecture.md` §6, decision `0039` D3, rule 1). Enforced
/// by `test/guards/module_boundary_guard_test.dart`, which special-cases
/// this exact path.
///
/// Also covers tenant slug/deep-link resolution and the app's startup
/// sequence (unauthenticated `tenant-config` fetch, then login) —
/// `docs/mobile/architecture.md` §1. Built starting REQ-421 (MOB-2).
library;

import 'dart:convert' show base64Url;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_appauth/flutter_appauth.dart'
    show AuthorizationTokenResponse, TokenRequest;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/api_client.dart';
import '../api/api_error.dart' show ForbiddenError;
import '../api/transport_policy.dart';
import '../auth/app_auth_platform.dart';
import '../auth/auth.dart';
import '../auth/device_unlock.dart';
import '../auth/keep_signed_in.dart';
import '../auth/kv_store.dart' show OidcHttpError;
import '../auth/session_crypto.dart' show kMaxWrongPins;
import '../auth/session_record.dart' show SessionRecord, SessionRecordStore;
import '../auth/web_app_auth_adapter.dart' show OidcRevoker;
import '../definitions/definitions.dart'
    show ActiveDefinitionCacheHolder, DefinitionCacheOpener;
import '../definitions/pinned_form_cache.dart'
    show ActivePinnedFormCacheHolder, PinnedFormCacheOpener;
import '../definitions/pinned_form_resolver.dart'
    show pinnedFormCacheHolderProvider;
import '../definitions/sembast_cache_repository.dart'
    show openProductionDefinitionCache;
import '../definitions/sembast_pinned_form_cache_repository.dart'
    show openProductionPinnedFormCache;
import '../definitions/tenant_home_screen.dart'
    show definitionCacheHolderProvider;
import '../features/codes/codes.dart' show codesRoutes, kCodesScanPath;
import '../features/stock/stock.dart'
    show stockRoutes, kStockHomePath, offlineQueueProvider, offlineSyncProvider;
import '../i18n/i18n.dart';
import '../offline/offline_queue.dart' show OfflineDraftQueue;
import 'bootstrap_models.dart';
import 'error_screens.dart';

export 'bootstrap_models.dart';
export 'error_screens.dart';

// ── §1. Deep-link / manual-slug tenant-identity resolution ────────────────

/// The build-time platform host — read once, here, and threaded through as
/// a parameter everywhere else (design §1.3, OQ-1).
const String kPlatformHost = String.fromEnvironment(
  'LETFLOW_PLATFORM_HOST',
  defaultValue: '',
);

/// Extracts the tenant slug from an incoming deep-link/App-Link [uri], or
/// `null` if it does not match the expected `https://<slug>.<platformHost>`
/// shape (design §1.1). Never throws — a malformed/foreign URL is a `null`
/// result, not an exception.
@visibleForTesting
String? parseTenantSlugFromDeepLink(Uri uri, {required String platformHost}) {
  if (uri.scheme != 'https') return null;
  if (platformHost.isEmpty) return null;

  final host = uri.host;
  if (host == platformHost) return null;

  final suffix = '.$platformHost';
  if (!host.endsWith(suffix)) return null;

  final prefix = host.substring(0, host.length - suffix.length);
  if (prefix.isEmpty || prefix.contains('.')) return null;

  return prefix;
}

/// Manual-entry screen (design §1.2) — the widget both a resolved
/// deep-link slug and a typed slug ultimately converge on
/// (`runTenantBootstrap`, taking a plain `String`, is the one function
/// both paths call).
class TenantSlugEntryScreen extends ConsumerStatefulWidget {
  const TenantSlugEntryScreen({super.key});

  @override
  ConsumerState<TenantSlugEntryScreen> createState() =>
      _TenantSlugEntryScreenState();
}

class _TenantSlugEntryScreenState extends ConsumerState<TenantSlugEntryScreen> {
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Prefill the field with the last code the user signed in with
    // (T-1903: remember the last code on the device). The slug stored in
    // `LastActiveTenantPointer` is not a secret; we read it without
    // touching any credential.
    Future.microtask(_prefillLastSlug);
  }

  Future<void> _prefillLastSlug() async {
    final tokenStore = ref.read(tenantTokenStoreProvider);
    final pointer = await readLastActiveTenant(tokenStore);
    if (pointer != null && mounted) {
      _controller.text = pointer.slug;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final slug = _controller.text.trim();
    if (slug.isEmpty) return;
    ref.read(bootstrapControllerProvider).beginBootstrap(slug);
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(bootstrapControllerProvider);
    final isLoading = controller.state.phase == BootstrapPhase.loading;

    return Scaffold(
      key: const Key('tenant-slug-entry-screen'),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(tr('bootstrap.slugEntry.prompt')),
              TextField(
                key: const Key('tenant-slug-field'),
                controller: _controller,
                enabled: !isLoading,
                decoration: InputDecoration(
                  hintText: tr('bootstrap.slugEntry.hint'),
                ),
                onSubmitted: (_) => _submit(),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  tr('bootstrap.slugEntry.helper'),
                  key: const Key('slug-entry-helper'),
                ),
              ),
              if (unlockNoticeText(controller.state) != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    unlockNoticeText(controller.state)!,
                    key: const Key('session-notice'),
                  ),
                ),
              ValueListenableBuilder<bool>(
                valueListenable: controller.revocationFailed,
                builder: (context, failed, _) => failed
                    ? Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          tr('session.revocationFailed'),
                          key: const Key('session-revocation-failed'),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                key: const Key('tenant-slug-submit'),
                onPressed: isLoading ? null : _submit,
                // Deliberately not an indeterminate `CircularProgressIndicator`
                // here: its perpetual animation would keep
                // `WidgetTester.pumpAndSettle()` from ever settling in the
                // widget tests that drive this screen through a real
                // bootstrap attempt (AC7).
                child: Text(
                  isLoading
                      ? tr('bootstrap.slugEntry.signingIn')
                      : tr('bootstrap.slugEntry.continueAction'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── §5. Post-auth bootstrap orchestration ──────────────────────────────────

/// Runs the full tenant-bootstrap sequence for [enteredSlug] (design §5.2):
/// fetch tenant-config, authenticate via OIDC, store tokens, check
/// memberships (CANDIDATE 403 skips the check), then list installed
/// modules.
///
/// Returns `null` on user cancellation (the caller returns to the
/// slug-entry screen with no error screen shown — cancellation is not one
/// of the four failure states). Otherwise returns a [BootstrapResult].
Future<BootstrapResult?> runTenantBootstrap(
  String enteredSlug, {
  required HttpGateway client,
  required TenantTokenStore tokenStore,
  required ActiveRealmHolder activeRealm,
  AppAuthAdapter? appAuthAdapter,
  TransportPolicy? transportPolicy,
  ActiveDefinitionCacheHolder? definitionCache,
  DefinitionCacheOpener? cacheOpener,
  ActivePinnedFormCacheHolder? pinnedFormCache,
  PinnedFormCacheOpener? pinnedFormCacheOpener,
  ActiveTenantLocaleHolder? tenantLocale,
  List<String>? scopes,
}) async {
  final TenantConfig config;
  try {
    config = await fetchTenantConfig(enteredSlug, client: client);
  } catch (_) {
    return const BootstrapFailure(BootstrapFailureReason.networkUnavailable);
  }

  // Transport-policy realm_url check (REQ-422 §4.3, MOB-5, AC5) — the
  // `fetchTenantConfig` request above already went through `ApiClient`'s
  // own transport-policy interceptor; this check is additionally required
  // because `authenticateWithTenant`'s OIDC exchange goes through
  // `flutter_appauth`'s native AppAuth SDK, outside Dio entirely, and that
  // interceptor cannot see or block it.
  final effectivePolicy = transportPolicy ?? transportPolicyFor();
  if (!effectivePolicy.isUrlAllowed(Uri.parse(config.realmUrl))) {
    return const BootstrapFailure(BootstrapFailureReason.oidcFailure);
  }

  AuthorizationTokenResponse? tokenResponse;
  try {
    tokenResponse = await authenticateWithTenant(
      config,
      appAuthAdapter: appAuthAdapter ?? defaultAppAuthAdapter(),
      scopes: scopes ?? kOidcScopes,
    );
  } catch (_) {
    return const BootstrapFailure(BootstrapFailureReason.oidcFailure);
  }
  if (tokenResponse == null) {
    // User cancellation — not a failure state (design §5.2 step 2).
    return null;
  }

  final tokens = TokenSet.fromAuthorizationTokenResponse(tokenResponse);
  try {
    await tokenStore.store(config.realmUrl, tokens);
  } catch (_) {
    return const BootstrapFailure(
      BootstrapFailureReason.secureStorageUnavailable,
    );
  }

  // Set as soon as this tenant's own token is stored — *before* this same
  // tenant's own memberships/modules calls (design §5.2 step 4 requires
  // those calls to carry the just-stored bearer token automatically). This
  // is also what keeps a request made after a later tenant's bootstrap
  // begins from ever attaching an earlier tenant's token (design §5.3):
  // the pointer flips the moment the new tenant's token exists, strictly
  // before that new tenant's own tenant-content requests are issued.
  activeRealm.currentRealmUrl = config.realmUrl;
  // REQ-425 design §5.2 — the refresh coordinator needs `clientId` alongside
  // `currentRealmUrl` to build a refresh_token grant's `TokenRequest`.
  activeRealm.clientId = config.clientId;
  // REQ-429 (MOB-7) design §4.4 — tier (a)'s "tenant default" role
  // (`resolveFormattingLocale`'s `tenantDefaultLocale` parameter), set
  // alongside the realm/client-id pointers above.
  tenantLocale?.defaultLocale = config.defaultLocale;

  // REQ-423 design §7.3 — persisted at the same point the active-realm
  // pointer itself is set, so `attemptSessionResume` can reach this
  // tenant's identity with zero network calls on a later launch.
  await writeLastActiveTenant(
    tokenStore,
    LastActiveTenantPointer(realmUrl: config.realmUrl, slug: enteredSlug),
  );

  // REQ-423 design §7.2 — opened immediately after the token-store write
  // and before the memberships/modules calls that follow, so a
  // definition-cache operation issued from this point on is never
  // reachable before its tenant's own partition is open.
  if (definitionCache != null) {
    await definitionCache.openFor(
      config.realmUrl,
      opener: cacheOpener ?? openProductionDefinitionCache,
    );
  }

  // REQ-424 design §6.2 — paired, additive, immediately after the
  // definition-cache open above: opens this tenant's own pinned-form-cache
  // partition before any tenant-content call that follows.
  if (pinnedFormCache != null) {
    await pinnedFormCache.openFor(
      config.realmUrl,
      opener: pinnedFormCacheOpener ?? openProductionPinnedFormCache,
    );
  }

  return _verifyMembershipsAndModules(
    enteredSlug,
    realmUrl: config.realmUrl,
    client: client,
    tokenStore: tokenStore,
    activeRealm: activeRealm,
  );
}

/// Steps 4 and 5 of the bootstrap (memberships check, installed modules),
/// shared by the interactive sign-in and the PIN unlock (REQ-810).
Future<BootstrapResult> _verifyMembershipsAndModules(
  String enteredSlug, {
  required String realmUrl,
  required HttpGateway client,
  required TenantTokenStore tokenStore,
  required ActiveRealmHolder activeRealm,
}) async {
  try {
    final response = await client.get('/api/v1/me/memberships');
    final status = response.statusCode ?? 0;
    if (status == 200) {
      final data = response.data as Map<String, dynamic>;
      final memberships = (data['memberships'] as List<dynamic>)
          .map((e) => MembershipEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      // First-entry-only check (design §5.2 step 4) — never searches the
      // rest of the list even when a later entry does match.
      if (memberships.isEmpty || memberships.first.tenantSlug != enteredSlug) {
        await tokenStore.delete(realmUrl);
        activeRealm.currentRealmUrl = null;
        activeRealm.clientId = null;
        return const BootstrapFailure(BootstrapFailureReason.tenantNotFound);
      }
    } else {
      // Unreachable once `client` is a REQ-425-hardened `ApiClient`: a
      // non-2xx `get()` now throws `ApiError` (see the `on ForbiddenError`
      // clause below) rather than returning a non-2xx `Response`. Kept as a
      // defensive fallback for any `HttpGateway` fake that still returns a
      // non-2xx `Response` directly (e.g. `FakeHttpGateway` in tests).
      activeRealm.currentRealmUrl = null;
      activeRealm.clientId = null;
      return const BootstrapFailure(BootstrapFailureReason.networkUnavailable);
    }
  } on ForbiddenError {
    // CANDIDATE: membership check not applicable — proceed to modules.
    // (REQ-425/MOB-6 consequence: the hardened `ApiClient.get` now throws
    // `ForbiddenError` for a 403 instead of returning a 403 `Response`, so
    // this case moved from the `status == 403` branch above into its own
    // catch clause, ahead of the generic `catch (_)` below, to preserve the
    // original "proceed to modules" behavior.)
  } catch (_) {
    activeRealm.currentRealmUrl = null;
    activeRealm.clientId = null;
    return const BootstrapFailure(BootstrapFailureReason.networkUnavailable);
  }

  final List<InstalledModule> installedModules;
  try {
    final response = await client.get('/api/v1/me/modules');
    if ((response.statusCode ?? 0) != 200) {
      activeRealm.currentRealmUrl = null;
      activeRealm.clientId = null;
      return const BootstrapFailure(BootstrapFailureReason.networkUnavailable);
    }
    final data = response.data as Map<String, dynamic>;
    installedModules = (data['installed_modules'] as List<dynamic>)
        .map((e) => InstalledModule.fromJson(e as Map<String, dynamic>))
        .toList();
  } catch (_) {
    activeRealm.currentRealmUrl = null;
    activeRealm.clientId = null;
    return const BootstrapFailure(BootstrapFailureReason.networkUnavailable);
  }

  return BootstrapSuccess(installedModules: installedModules);
}

// ── §6. Audience scoping: logout / tenant switch ───────────────────────────
//
// REQ-422 §6.3, MOB-5, AC7 — a tenant switch or logout deletes the previous
// tenant's tokens explicitly, so no residual token for a tenant the user is
// no longer authenticated to survives in secure storage.

/// With the 30-day sign-in on (REQ-810), revokes the refresh token at the IdP
/// (best effort, [onRevocationFailed] is called when it did not work) and
/// ALWAYS deletes the encrypted record. A no-op when [keepSignedIn] is null,
/// so flag-off sign-out is unchanged.
Future<void> _signOutKeptSession({
  required KeepSignedIn? keepSignedIn,
  required OidcRevoker? revoker,
  required TenantTokenStore tokenStore,
  required String realmUrl,
  required String? clientId,
  void Function()? onRevocationFailed,
}) async {
  if (keepSignedIn == null) return;
  try {
    final refreshToken = (await tokenStore.read(realmUrl))?.refreshToken;
    if (refreshToken != null) {
      if (revoker == null || clientId == null) {
        throw StateError('revocation not possible');
      }
      await revoker.revoke(realmUrl, clientId, refreshToken);
    }
  } catch (_) {
    onRevocationFailed?.call();
  }
  try {
    await keepSignedIn.delete();
  } catch (_) {}
}

/// Deletes the active tenant's tokens and clears [activeRealm]. No-op if
/// nothing is currently active.
Future<void> logout({
  required TenantTokenStore tokenStore,
  required ActiveRealmHolder activeRealm,
  ActiveDefinitionCacheHolder? definitionCache,
  ActivePinnedFormCacheHolder? pinnedFormCache,
  OfflineDraftQueue? offlineQueue,
  KeepSignedIn? keepSignedIn,
  OidcRevoker? revoker,
  void Function()? onRevocationFailed,
}) async {
  final currentRealmUrl = activeRealm.currentRealmUrl;
  if (currentRealmUrl == null) return;
  await _signOutKeptSession(
    keepSignedIn: keepSignedIn,
    revoker: revoker,
    tokenStore: tokenStore,
    realmUrl: currentRealmUrl,
    clientId: activeRealm.clientId,
    onRevocationFailed: onRevocationFailed,
  );
  // PWA M3: unsent drafts belong to the signed-out person; another person on a
  // shared device must not be able to send them. Cleared while the realm is
  // still set (the queue is keyed by it).
  await offlineQueue?.closeAndClear();
  await tokenStore.delete(currentRealmUrl);
  activeRealm.currentRealmUrl = null;
  activeRealm.clientId = null;
  await clearLastActiveTenant(tokenStore);
  await definitionCache?.closeAndClear();
  // REQ-424 design §6.2 — paired, additive, immediately after the
  // definition-cache clear above.
  await pinnedFormCache?.closeAndClear();
}

/// Switches the active tenant to [enteredSlug] (REQ-422 §6.3, OQ-5).
///
/// Deletes the *previous* tenant's tokens **before** attempting the new
/// tenant's bootstrap — not after it succeeds — so a token for a tenant the
/// user is initiating a switch away from never survives an in-progress or
/// failed switch attempt. If there is no previous tenant at all (first
/// bootstrap of the app session, not a "switch") or the new tenant resolves
/// to the *same* `realm_url` as the previous one (re-authenticating the
/// same tenant), no delete occurs — deleting first would just force a
/// needless token gap for no isolation benefit.
///
/// This is a thin wrapper: the new tenant's own bootstrap sequence (OIDC
/// exchange, membership/module checks) is still entirely
/// [runTenantBootstrap]'s — this function only adds the pre-delete step,
/// which requires resolving the new tenant's `realm_url` via
/// `fetchTenantConfig` once up front to decide whether a delete is even
/// applicable (a same-tenant re-auth is not a switch). If that lookup
/// itself fails, no delete occurs and the failure is surfaced through the
/// normal `runTenantBootstrap` call below (which repeats the same,
/// idempotent, unauthenticated request).
Future<BootstrapResult?> switchTenant(
  String enteredSlug, {
  required HttpGateway client,
  required TenantTokenStore tokenStore,
  required ActiveRealmHolder activeRealm,
  AppAuthAdapter? appAuthAdapter,
  TransportPolicy? transportPolicy,
  ActiveDefinitionCacheHolder? definitionCache,
  DefinitionCacheOpener? cacheOpener,
  ActivePinnedFormCacheHolder? pinnedFormCache,
  PinnedFormCacheOpener? pinnedFormCacheOpener,
  ActiveTenantLocaleHolder? tenantLocale,
  OfflineDraftQueue? offlineQueue,
  KeepSignedIn? keepSignedIn,
  OidcRevoker? revoker,
  void Function()? onRevocationFailed,
}) async {
  final previousRealmUrl = activeRealm.currentRealmUrl;
  if (previousRealmUrl != null) {
    String? newRealmUrl;
    try {
      newRealmUrl = (await fetchTenantConfig(
        enteredSlug,
        client: client,
      )).realmUrl;
    } catch (_) {
      newRealmUrl = null;
    }
    if (newRealmUrl != previousRealmUrl) {
      // PWA M3: the previous tenant's unsent drafts go with its tokens.
      await offlineQueue?.closeAndClear();
      await _signOutKeptSession(
        keepSignedIn: keepSignedIn,
        revoker: revoker,
        tokenStore: tokenStore,
        realmUrl: previousRealmUrl,
        clientId: activeRealm.clientId,
        onRevocationFailed: onRevocationFailed,
      );
      await tokenStore.delete(previousRealmUrl);
      activeRealm.currentRealmUrl = null;
      activeRealm.clientId = null;
      await clearLastActiveTenant(tokenStore);
      // REQ-423 design §7.2 — closes the *previous* tenant's cache file
      // handle, mirroring the existing token delete. The new tenant's own
      // `openFor` call happens inside `runTenantBootstrap` below.
      await definitionCache?.closeAndClear();
      // REQ-424 design §6.2 — paired, additive, immediately after the
      // definition-cache clear above.
      await pinnedFormCache?.closeAndClear();
    }
  }
  return runTenantBootstrap(
    enteredSlug,
    client: client,
    tokenStore: tokenStore,
    activeRealm: activeRealm,
    appAuthAdapter: appAuthAdapter,
    transportPolicy: transportPolicy,
    definitionCache: definitionCache,
    cacheOpener: cacheOpener,
    pinnedFormCache: pinnedFormCache,
    pinnedFormCacheOpener: pinnedFormCacheOpener,
    tenantLocale: tenantLocale,
    scopes: keepSignedIn != null ? kOidcScopesWeb : null,
  );
}

// Tear-offs of the two top-level functions above, captured at top-level
// scope (not inside `BootstrapController`) so `BootstrapController`'s own
// identically-named `logout()`/`switchTenant(...)` methods can delegate to
// them without an unqualified call inside those methods resolving back to
// `this.logout`/`this.switchTenant` (Dart resolves a bare call to an
// instance member of the same name before falling back to a top-level
// declaration, which would otherwise recurse infinitely).
final Future<void> Function({
  required TenantTokenStore tokenStore,
  required ActiveRealmHolder activeRealm,
  ActiveDefinitionCacheHolder? definitionCache,
  ActivePinnedFormCacheHolder? pinnedFormCache,
  OfflineDraftQueue? offlineQueue,
  KeepSignedIn? keepSignedIn,
  OidcRevoker? revoker,
  void Function()? onRevocationFailed,
})
_logoutTopLevel = logout;

final Future<BootstrapResult?> Function(
  String enteredSlug, {
  required HttpGateway client,
  required TenantTokenStore tokenStore,
  required ActiveRealmHolder activeRealm,
  AppAuthAdapter appAuthAdapter,
  TransportPolicy? transportPolicy,
  ActiveDefinitionCacheHolder? definitionCache,
  DefinitionCacheOpener? cacheOpener,
  ActivePinnedFormCacheHolder? pinnedFormCache,
  PinnedFormCacheOpener? pinnedFormCacheOpener,
  ActiveTenantLocaleHolder? tenantLocale,
  OfflineDraftQueue? offlineQueue,
  KeepSignedIn? keepSignedIn,
  OidcRevoker? revoker,
  void Function()? onRevocationFailed,
})
_switchTenantTopLevel = switchTenant;

// ── §5.4. Route table construction ────────────────────────────────────────

/// The real route registry: one entry per feature module under
/// `lib/features/`. This file is the only one allowed to import `features/`.
final Map<String, List<RouteBase>> kFeatureRegistry = {
  'codes': codesRoutes(),
  'stock': stockRoutes(),
};

/// Route of the codes scan screen, re-exported as a plain constant so screens
/// outside `features/` can link to it without importing the feature.
const String kCodesScanRoutePath = kCodesScanPath;
const String kStockHomeRoutePath = kStockHomePath;

/// True when [moduleId] is among the tenant's [installedModules].
bool isModuleInstalled(
  List<InstalledModule> installedModules,
  String moduleId,
) => installedModules.any((m) => m.moduleId == moduleId);

/// Builds the tenant-content route list for the currently
/// [installedModules] (design §5.4). A `moduleId` absent from
/// [installedModules] has no route entry at all — not a route that then
/// denies access. REQ-421 ships zero real feature modules, so this
/// function's real-world output is the empty set unless a test fixture
/// supplies a fake installed module and a fake route-registry entry via
/// [registry].
List<RouteBase> buildRouteTable(
  List<InstalledModule> installedModules, {
  Map<String, List<RouteBase>>? registry,
}) {
  registry ??= kFeatureRegistry;
  final routes = <RouteBase>[];
  for (final module in installedModules) {
    final moduleRoutes = registry[module.moduleId];
    if (moduleRoutes != null) {
      routes.addAll(moduleRoutes);
    }
  }
  return routes;
}

// ── Bootstrap UI state + controller ────────────────────────────────────────

/// REQ-423 design §7.3 — `resumedOffline` is deliberately **not** the same
/// value as `success`: a resumed-without-verification session has not
/// re-confirmed membership or re-fetched the installed-module list. Never
/// silently merged with `success`.
enum BootstrapPhase {
  unauthenticated,
  loading,
  success,
  resumedOffline,
  failure,

  /// REQ-810: an encrypted 30-day record exists and the PIN is needed. Like
  /// `unauthenticated`, no tenant route is reachable.
  locked,
}

/// One plain line shown on the PIN or sign-in screen (REQ-810).
enum UnlockNotice {
  none,
  wrongPin,
  expired,
  revoked,
  noConnection,
  tooManyAttempts,
}

/// Result of finishing the PIN setup.
enum EnrollOutcome { enrolled, invalidPin, mismatch, failed }

/// Result of "unlock with this device" enrolment (REQ-811): the PIN stays the
/// way in whatever the outcome.
enum DeviceEnrolOutcome { enrolled, pinStays, cannotThisWay }

/// The plain line for a notice, or `null` for none.
String? unlockNoticeText(BootstrapUiState s) {
  return switch (s.unlockNotice) {
    UnlockNotice.none => null,
    UnlockNotice.wrongPin => tr(
      'session.wrongPin',
    ).replaceAll('{remaining}', '${s.pinsRemaining}'),
    UnlockNotice.expired => tr('session.expired'),
    UnlockNotice.revoked => tr('session.revoked'),
    UnlockNotice.noConnection => tr('session.noConnection'),
    UnlockNotice.tooManyAttempts => tr('session.tooManyAttempts'),
  };
}

@immutable
class BootstrapUiState {
  const BootstrapUiState({
    required this.phase,
    this.installedModules = const [],
    this.failureReason,
    this.unlockNotice = UnlockNotice.none,
    this.pinsRemaining = 0,
  });

  final BootstrapPhase phase;
  final List<InstalledModule> installedModules;
  final BootstrapFailureReason? failureReason;
  final UnlockNotice unlockNotice;

  /// Wrong PINs left before the record is deleted (with `wrongPin`).
  final int pinsRemaining;

  static const unauthenticated = BootstrapUiState(
    phase: BootstrapPhase.unauthenticated,
  );
}

/// Drives the router's `refreshListenable`/`redirect` gating (design §5.4)
/// — no tenant-content route is reachable until this notifier's state
/// reaches [BootstrapPhase.success].
class BootstrapController extends ChangeNotifier {
  BootstrapController({
    required this.client,
    required this.tokenStore,
    required this.activeRealm,
    required this.definitionCache,
    required this.pinnedFormCache,
    this.offlineQueue,
    AppAuthAdapter? appAuthAdapter,
    this.cacheOpener,
    this.pinnedFormCacheOpener,
    ActiveTenantLocaleHolder? tenantLocale,
    this.webMode = kIsWeb,
    WebPendingSignIn? Function()? webPending,
    this.keepSignedIn,
    this.deviceUnlock,
    String Function()? rpId,
    OidcRevoker? revoker,
    SessionRecordStore? staleRecordStore,
    DateTime Function()? now,
  }) : _rpId = rpId ?? (() => Uri.base.host),
       appAuthAdapter = appAuthAdapter ?? defaultAppAuthAdapter(),
       webPending = webPending ?? peekWebPendingSignIn,
       tenantLocale = tenantLocale ?? ActiveTenantLocaleHolder(),
       revoker = revoker ?? (keepSignedIn != null ? webOidcRevoker() : null),
       _staleRecordStore =
           staleRecordStore ?? (webMode ? webSessionRecordStore() : null),
       _now = now ?? DateTime.now;

  /// REQ-810: the 30-day sign-in. `null` = off (the default): every branch
  /// below that uses it is skipped, so the flow is the one of main.
  final KeepSignedIn? keepSignedIn;
  final OidcRevoker? revoker;

  /// REQ-811: the device passkey seam; `null` unless [keepSignedIn] is built.
  final DeviceUnlockAuthenticator? deviceUnlock;
  final String Function() _rpId;

  /// True while the "unlock with this device?" offer is due (after the PIN).
  final ValueNotifier<bool> offerDeviceUnlock = ValueNotifier<bool>(false);

  /// True on the lock screen when the record has a device wrapping.
  final ValueNotifier<bool> deviceUnlockAvailable = ValueNotifier<bool>(false);
  bool _deviceEnrolTried = false;
  bool _deviceUnlockBusy = false;

  /// Used only when [keepSignedIn] is null: a record left by an earlier build
  /// with the flag on is deleted unread.
  final SessionRecordStore? _staleRecordStore;
  final DateTime Function() _now;

  /// True while the "stay signed in for 30 days?" offer is due.
  final ValueNotifier<bool> offerKeepSignedIn = ValueNotifier<bool>(false);

  /// True after a sign-out whose IdP revocation did not work.
  final ValueNotifier<bool> revocationFailed = ValueNotifier<bool>(false);

  /// Time of the last full (interactive) sign-in; the 30 days count from it.
  DateTime? _fullSignInAt;

  /// Web (PWA M2): sign-in is a full-page redirect, so a session is resumed
  /// by finishing a pending redirect or silently restarting it. Injectable
  /// so tests need no browser.
  final bool webMode;
  final WebPendingSignIn? Function() webPending;

  final HttpGateway client;
  final TenantTokenStore tokenStore;
  final ActiveRealmHolder activeRealm;
  final ActiveDefinitionCacheHolder definitionCache;
  final ActivePinnedFormCacheHolder pinnedFormCache;

  /// Web only (PWA M3); null on Android / iOS.
  final OfflineDraftQueue? offlineQueue;

  /// Tier (a)'s "tenant default" (REQ-429 design §4.4) — set from
  /// `TenantConfig.defaultLocale` by [runTenantBootstrap]/[switchTenant]
  /// below. Defaults to a fresh, unset holder when not supplied.
  final ActiveTenantLocaleHolder tenantLocale;

  /// Defaults to [openProductionDefinitionCache] when null (tests inject a
  /// fake opener so `flutter test` never touches `path_provider`'s
  /// platform channel).
  final DefinitionCacheOpener? cacheOpener;

  /// Defaults to [openProductionPinnedFormCache] when null — mirrors
  /// [cacheOpener]'s own testing-seam purpose (REQ-424 design §6.2).
  final PinnedFormCacheOpener? pinnedFormCacheOpener;

  /// Real `flutter_appauth` by default; tests construct their own
  /// [BootstrapController] with a [FakeAppAuthAdapter]-equivalent here so
  /// the UI-driven flow (`TenantSlugEntryScreen`'s submit button) never
  /// reaches a real platform channel in `flutter test`.
  final AppAuthAdapter appAuthAdapter;

  BootstrapUiState _state = BootstrapUiState.unauthenticated;
  BootstrapUiState get state => _state;

  Future<void> beginBootstrap(String slug) async {
    revocationFailed.value = false;
    rememberWebSignInSlug(slug);
    _state = const BootstrapUiState(phase: BootstrapPhase.loading);
    notifyListeners();

    final result = await runTenantBootstrap(
      slug,
      client: client,
      tokenStore: tokenStore,
      activeRealm: activeRealm,
      appAuthAdapter: appAuthAdapter,
      definitionCache: definitionCache,
      cacheOpener: cacheOpener,
      pinnedFormCache: pinnedFormCache,
      pinnedFormCacheOpener: pinnedFormCacheOpener,
      tenantLocale: tenantLocale,
      scopes: keepSignedIn != null ? kOidcScopesWeb : null,
    );

    if (result == null) {
      // Cancellation: silently back to the entry screen.
      _state = BootstrapUiState.unauthenticated;
    } else {
      _state = switch (result) {
        BootstrapSuccess(:final installedModules) => BootstrapUiState(
          phase: BootstrapPhase.success,
          installedModules: installedModules,
        ),
        BootstrapFailure(:final reason) => BootstrapUiState(
          phase: BootstrapPhase.failure,
          failureReason: reason,
        ),
      };
      if (_state.phase == BootstrapPhase.success) {
        await _afterFullSignIn(slug);
      }
    }
    notifyListeners();
  }

  // ── REQ-810: the 30-day sign-in ─────────────────────────────────────────

  /// After an interactive sign-in reached `success`: remember when it
  /// happened, drop a record that this sign-in supersedes, and offer to keep
  /// the sign-in when the IdP issued a refresh token.
  Future<void> _afterFullSignIn(String slug) async {
    final k = keepSignedIn;
    if (k == null) return;
    try {
      _fullSignInAt = _now().toUtc();
      final realm = activeRealm.currentRealmUrl;
      if (realm == null) return;
      final refreshToken = (await tokenStore.read(realm))?.refreshToken;
      await k.delete();
      if (refreshToken != null && refreshToken.isNotEmpty) {
        offerKeepSignedIn.value = true;
      }
    } catch (_) {
      // The offer is optional; the verified session is unaffected.
    }
  }

  /// The user declined (or dismissed) the offer: nothing is stored.
  void declineKeepSignedIn() {
    offerKeepSignedIn.value = false;
  }

  /// Finishes the PIN setup. Invalid PIN or a mismatch store nothing.
  Future<EnrollOutcome> enrollWithPin(String pin, String confirm) async {
    final k = keepSignedIn;
    if (k == null) return EnrollOutcome.failed;
    if (!KeepSignedIn.isValidPin(pin)) return EnrollOutcome.invalidPin;
    if (pin != confirm) return EnrollOutcome.mismatch;
    try {
      final realm = activeRealm.currentRealmUrl;
      final signedInAt = _fullSignInAt;
      if (realm == null || signedInAt == null) return EnrollOutcome.failed;
      final refreshToken = (await tokenStore.read(realm))?.refreshToken;
      final pointer = await readLastActiveTenant(tokenStore);
      if (refreshToken == null || pointer == null) {
        return EnrollOutcome.failed;
      }
      await k.enroll(
        realmUrl: realm,
        slug: pointer.slug,
        refreshToken: refreshToken,
        pin: pin,
        signedInAt: signedInAt,
      );
      offerKeepSignedIn.value = false;
      _deviceEnrolTried = false;
      await _maybeOfferDeviceUnlock();
      return EnrollOutcome.enrolled;
    } catch (_) {
      return EnrollOutcome.failed;
    }
  }

  Future<void> _maybeOfferDeviceUnlock() async {
    final d = deviceUnlock;
    var available = false;
    if (d != null) {
      try {
        available = await d.isAvailable();
      } catch (_) {
        available = false;
      }
    }
    offerDeviceUnlock.value = available;
  }

  /// The user said "not now" to the device offer: no WebAuthn call, the
  /// record is untouched.
  void declineDeviceUnlock() {
    offerDeviceUnlock.value = false;
  }

  /// Enrols the device passkey for the record just made. At most one attempt
  /// per offer; every outcome leaves the PIN working.
  Future<DeviceEnrolOutcome> enrollDeviceUnlock() async {
    final d = deviceUnlock;
    final k = keepSignedIn;
    offerDeviceUnlock.value = false;
    if (d == null || k == null || _deviceEnrolTried) {
      return DeviceEnrolOutcome.pinStays;
    }
    _deviceEnrolTried = true;
    final Uint8List evalInput;
    final DeviceCreateResult created;
    final String rpId = _rpId();
    try {
      evalInput = await k.newEvalInput();
      created = await d.create(
        rpId: rpId,
        evalInput: evalInput,
        userVerification: kDeviceUserVerification,
        authenticatorAttachment: kDeviceAttachment,
      );
    } catch (_) {
      return DeviceEnrolOutcome.pinStays;
    }
    if (!created.prfEnabled) return DeviceEnrolOutcome.cannotThisWay;
    try {
      var prf = created.prfOutput;
      prf ??= await d.get(
        rpId: rpId,
        credentialId: created.credentialId,
        evalInput: evalInput,
        userVerification: kDeviceUserVerification,
      );
      if (prf == null) return DeviceEnrolOutcome.cannotThisWay;
      final ok = await k.enrollDeviceUnlock(
        credentialId: created.credentialId,
        evalInput: evalInput,
        prfOutput: prf,
      );
      return ok
          ? DeviceEnrolOutcome.enrolled
          : DeviceEnrolOutcome.cannotThisWay;
    } catch (_) {
      return DeviceEnrolOutcome.cannotThisWay;
    }
  }

  /// Tries the device passkey on the lock screen. A cancel, a failure or no
  /// output changes nothing (no state change, no store write): the PIN field
  /// stays. Success follows the PIN path from here.
  Future<void> tryDeviceUnlock() async {
    final d = deviceUnlock;
    final k = keepSignedIn;
    if (d == null ||
        k == null ||
        _state.phase != BootstrapPhase.locked ||
        k.isUnlocked ||
        _deviceUnlockBusy) {
      return;
    }
    _deviceUnlockBusy = true;
    try {
      final rec = await k.peek();
      final credB64 = rec?.deviceCredentialId;
      final evalB64 = rec?.deviceEvalInput;
      if (rec == null || credB64 == null || evalB64 == null) return;
      final Uint8List? prf;
      try {
        prf = await d.get(
          rpId: _rpId(),
          credentialId: Uint8List.fromList(base64Url.decode(credB64)),
          evalInput: Uint8List.fromList(base64Url.decode(evalB64)),
          userVerification: kDeviceUserVerification,
        );
      } catch (_) {
        return;
      }
      if (prf == null) return;
      final UnlockResult result;
      try {
        result = await k.unlockWithDevice(prf);
      } catch (_) {
        await _dropRecord();
        _toUnauthenticated(UnlockNotice.revoked);
        return;
      }
      switch (result) {
        case Unlocked(:final record):
          await _refreshAfterUnlock(record);
        case Expired():
          _toUnauthenticated(UnlockNotice.expired);
        case Corrupt():
          _toUnauthenticated(UnlockNotice.none);
        case DeviceNotAccepted() || WrongPin() || TooManyAttempts():
          break;
      }
    } finally {
      _deviceUnlockBusy = false;
    }
  }

  void _toUnauthenticated(UnlockNotice notice) {
    _state = BootstrapUiState(
      phase: BootstrapPhase.unauthenticated,
      unlockNotice: notice,
    );
    notifyListeners();
  }

  /// Checks the PIN on the lock screen; on the right PIN refreshes the
  /// session once and continues like a sign-in.
  Future<void> submitPin(String pin) async {
    final k = keepSignedIn;
    if (k == null || _state.phase != BootstrapPhase.locked) return;
    if (!KeepSignedIn.isValidPin(pin)) {
      _state = const BootstrapUiState(
        phase: BootstrapPhase.locked,
        unlockNotice: UnlockNotice.wrongPin,
        pinsRemaining: kMaxWrongPins,
      );
      notifyListeners();
      return;
    }
    final UnlockResult result;
    try {
      result = await k.unlock(pin);
    } catch (_) {
      await _dropRecord();
      _toUnauthenticated(UnlockNotice.revoked);
      return;
    }
    switch (result) {
      case Unlocked(:final record):
        await _refreshAfterUnlock(record);
      case WrongPin(:final remaining):
        _state = BootstrapUiState(
          phase: BootstrapPhase.locked,
          unlockNotice: UnlockNotice.wrongPin,
          pinsRemaining: remaining,
        );
        notifyListeners();
      case Expired():
        _toUnauthenticated(UnlockNotice.expired);
      case TooManyAttempts():
        _toUnauthenticated(UnlockNotice.tooManyAttempts);
      case Corrupt():
        _toUnauthenticated(UnlockNotice.none);
      case DeviceNotAccepted():
        break;
    }
  }

  Future<void> _dropRecord() async {
    try {
      await keepSignedIn?.delete();
    } catch (_) {}
  }

  /// Retry button after `noConnection`: the data key is still in memory, so
  /// the PIN is not asked again.
  Future<void> retryUnlockRefresh() async {
    final k = keepSignedIn;
    if (k == null || _state.phase != BootstrapPhase.locked) return;
    final record = await k.peek();
    if (record == null || !k.isUnlocked) {
      _toUnauthenticated(UnlockNotice.none);
      return;
    }
    await _refreshAfterUnlock(record);
  }

  /// "Sign in again" on the lock screen: the record goes, the normal sign-in
  /// entry shows.
  Future<void> signInAgain() async {
    await _dropRecord();
    _toUnauthenticated(UnlockNotice.none);
  }

  Future<void> _refreshAfterUnlock(SessionRecord record) async {
    final k = keepSignedIn!;
    void stayLocked(UnlockNotice n) {
      _state = BootstrapUiState(phase: BootstrapPhase.locked, unlockNotice: n);
      notifyListeners();
    }

    final TenantConfig config;
    try {
      config = await fetchTenantConfig(record.slug, client: client);
    } catch (_) {
      stayLocked(UnlockNotice.noConnection);
      return;
    }
    // The record only ever refreshes against the realm it was made for, and
    // that realm must pass the same transport policy as a sign-in.
    if (config.realmUrl != record.realmUrl ||
        !transportPolicyFor().isUrlAllowed(Uri.parse(config.realmUrl))) {
      await _dropRecord();
      _toUnauthenticated(UnlockNotice.revoked);
      return;
    }
    final refreshToken = await k.unlockedRefreshToken();
    if (refreshToken == null) {
      await _dropRecord();
      _toUnauthenticated(UnlockNotice.none);
      return;
    }
    final TokenSet tokens;
    try {
      final response = await appAuthAdapter.refresh(
        TokenRequest(
          config.clientId,
          kOidcRedirectUrl,
          issuer: record.realmUrl,
          refreshToken: refreshToken,
        ),
      );
      final accessToken = response.accessToken;
      if (accessToken == null) {
        stayLocked(UnlockNotice.noConnection);
        return;
      }
      tokens = TokenSet(
        accessToken: accessToken,
        refreshToken: response.refreshToken ?? refreshToken,
        idToken: response.idToken,
        accessTokenExpiration: response.accessTokenExpirationDateTime,
      );
    } catch (e) {
      if (e is OidcHttpError && e.isInvalidGrant) {
        await _dropRecord();
        _toUnauthenticated(UnlockNotice.revoked);
      } else {
        stayLocked(UnlockNotice.noConnection);
      }
      return;
    }

    _state = const BootstrapUiState(phase: BootstrapPhase.loading);
    notifyListeners();
    try {
      await tokenStore.store(record.realmUrl, tokens);
    } catch (_) {
      _state = const BootstrapUiState(
        phase: BootstrapPhase.failure,
        failureReason: BootstrapFailureReason.secureStorageUnavailable,
      );
      notifyListeners();
      return;
    }
    activeRealm.currentRealmUrl = record.realmUrl;
    activeRealm.clientId = config.clientId;
    tenantLocale.defaultLocale = config.defaultLocale;
    await writeLastActiveTenant(
      tokenStore,
      LastActiveTenantPointer(realmUrl: record.realmUrl, slug: record.slug),
    );
    await definitionCache.openFor(
      record.realmUrl,
      opener: cacheOpener ?? openProductionDefinitionCache,
    );
    await pinnedFormCache.openFor(
      record.realmUrl,
      opener: pinnedFormCacheOpener ?? openProductionPinnedFormCache,
    );
    final result = await _verifyMembershipsAndModules(
      record.slug,
      realmUrl: record.realmUrl,
      client: client,
      tokenStore: tokenStore,
      activeRealm: activeRealm,
    );
    _state = switch (result) {
      BootstrapSuccess(:final installedModules) => BootstrapUiState(
        phase: BootstrapPhase.success,
        installedModules: installedModules,
      ),
      BootstrapFailure(:final reason) => BootstrapUiState(
        phase: BootstrapPhase.failure,
        failureReason: reason,
      ),
    };
    notifyListeners();
  }

  /// A failing IdP must not loop on reload: drop the pointer so the next
  /// start shows the slug entry.
  Future<void> _clearPointerOnFailure({bool force = false}) async {
    if (force || _state.phase == BootstrapPhase.failure) {
      try {
        await clearLastActiveTenant(tokenStore);
      } catch (_) {}
    }
  }

  /// Returns to the slug-entry screen (used by the tenant-not-found
  /// screen's retry action, and by a generic "start over").
  void resetToEntry() {
    _state = BootstrapUiState.unauthenticated;
    notifyListeners();
  }

  /// Switches the active tenant to [slug] (REQ-422 §6.3) — mirrors
  /// [beginBootstrap] but deletes the previous tenant's tokens first via
  /// the top-level [switchTenant] function (called through the
  /// [_switchTenantTopLevel] tear-off — see that variable's doc comment
  /// for why).
  Future<void> switchTenant(String slug) async {
    rememberWebSignInSlug(slug);
    _state = const BootstrapUiState(phase: BootstrapPhase.loading);
    notifyListeners();

    final result = await _switchTenantTopLevel(
      slug,
      client: client,
      tokenStore: tokenStore,
      activeRealm: activeRealm,
      appAuthAdapter: appAuthAdapter,
      definitionCache: definitionCache,
      cacheOpener: cacheOpener,
      pinnedFormCache: pinnedFormCache,
      pinnedFormCacheOpener: pinnedFormCacheOpener,
      tenantLocale: tenantLocale,
      offlineQueue: offlineQueue,
      keepSignedIn: keepSignedIn,
      revoker: revoker,
      onRevocationFailed: () => revocationFailed.value = true,
    );

    if (result == null) {
      _state = BootstrapUiState.unauthenticated;
    } else {
      _state = switch (result) {
        BootstrapSuccess(:final installedModules) => BootstrapUiState(
          phase: BootstrapPhase.success,
          installedModules: installedModules,
        ),
        BootstrapFailure(:final reason) => BootstrapUiState(
          phase: BootstrapPhase.failure,
          failureReason: reason,
        ),
      };
      if (_state.phase == BootstrapPhase.success) {
        await _afterFullSignIn(slug);
      }
    }
    notifyListeners();
  }

  /// Logs out the active tenant (REQ-422 §6.3) via the top-level [logout]
  /// function (through the [_logoutTopLevel] tear-off), then resets to the
  /// unauthenticated entry state.
  Future<void> logout() async {
    await _logoutTopLevel(
      tokenStore: tokenStore,
      activeRealm: activeRealm,
      definitionCache: definitionCache,
      pinnedFormCache: pinnedFormCache,
      offlineQueue: offlineQueue,
      keepSignedIn: keepSignedIn,
      revoker: revoker,
      onRevocationFailed: () => revocationFailed.value = true,
    );
    offerKeepSignedIn.value = false;
    offerDeviceUnlock.value = false;
    deviceUnlockAvailable.value = false;
    _state = BootstrapUiState.unauthenticated;
    notifyListeners();
  }

  /// Session resume without network (REQ-423 design §7.3) — reads only
  /// secure storage (no HTTP call), so a previously-authenticated session
  /// can render content-visible state offline. Called once at app start.
  ///
  /// No last-active-tenant pointer, or no tokens found for it (e.g. a
  /// prior logout raced with an unclean pointer clear): falls back to
  /// [BootstrapPhase.unauthenticated] — today's exact behaviour, zero
  /// change for a device that has never bootstrapped. A thrown exception
  /// from secure storage itself (Keystore/Keychain unavailable — the same
  /// condition `runTenantBootstrap`'s token-store write already treats as
  /// non-fatal-to-the-overall-flow, `BootstrapFailureReason
  /// .secureStorageUnavailable`) falls back the same way: this is a
  /// best-effort offline-resume attempt, never one that can crash app
  /// start or block the normal online bootstrap flow that follows.
  Future<void> attemptSessionResume() async {
    if (webMode) {
      try {
        if (keepSignedIn == null) {
          // Flag off: a record left by an earlier build with the flag on is
          // deleted without ever being read.
          await _staleRecordStore?.delete();
        }
        final pending = webPending();
        if (pending != null) {
          // Back from the IdP: finishes the code exchange.
          await beginBootstrap(pending.slug);
          await _clearPointerOnFailure();
          return;
        }
        final k = keepSignedIn;
        final stored = k == null ? null : await k.peek();
        if (k != null && stored != null) {
          // A 30-day record exists: nothing opens before the PIN.
          deviceUnlockAvailable.value =
              deviceUnlock != null && stored.hasDeviceUnlock;
          _state = const BootstrapUiState(phase: BootstrapPhase.locked);
          notifyListeners();
          return;
        }
        final p = await readLastActiveTenant(tokenStore);
        if (p != null && await tokenStore.read(p.realmUrl) == null) {
          // Tokens are memory-only on web: restart sign-in; silent while the
          // Keycloak SSO session lives.
          await beginBootstrap(p.slug);
          await _clearPointerOnFailure();
          return;
        }
      } catch (_) {
        await _clearPointerOnFailure(force: true);
        _state = BootstrapUiState.unauthenticated;
        notifyListeners();
        return;
      }
    }
    try {
      final pointer = await readLastActiveTenant(tokenStore);
      if (pointer == null) {
        _state = BootstrapUiState.unauthenticated;
        notifyListeners();
        return;
      }
      final tokens = await tokenStore.read(pointer.realmUrl);
      if (tokens == null) {
        _state = BootstrapUiState.unauthenticated;
        notifyListeners();
        return;
      }
      activeRealm.currentRealmUrl = pointer.realmUrl;
      await definitionCache.openFor(
        pointer.realmUrl,
        opener: cacheOpener ?? openProductionDefinitionCache,
      );
      // REQ-424 design §6.2 — paired, additive, immediately after the
      // definition-cache open above and before the `_state` assignment.
      await pinnedFormCache.openFor(
        pointer.realmUrl,
        opener: pinnedFormCacheOpener ?? openProductionPinnedFormCache,
      );
      // Deliberately `resumedOffline`, never `success` — membership/modules
      // have not been re-verified (design §7.3's own rationale).
      _state = const BootstrapUiState(phase: BootstrapPhase.resumedOffline);
      notifyListeners();
    } catch (_) {
      activeRealm.currentRealmUrl = null;
      _state = BootstrapUiState.unauthenticated;
      notifyListeners();
    }
  }
}

// ── Providers ───────────────────────────────────────────────────────────
//
// Declared here (not app.dart) so `TenantSlugEntryScreen` above and
// `app.dart`'s router can both depend on `bootstrapControllerProvider`
// without a circular import. Real production wiring by default; widget
// tests override `bootstrapControllerProvider` (or a lower-level provider
// it depends on) via `ProviderScope(overrides: [...])` at the test root —
// the standard Riverpod testing idiom, not a second wiring path.

/// REQ-810: the 30-day sign-in, or `null` (the default) when the compile-time
/// flag is off or the browser seams are missing.
final keepSignedInProvider = Provider<KeepSignedIn?>((ref) {
  if (!kKeepSignedInFlag || !kIsWeb) return null;
  final crypto = webSessionCrypto();
  final store = webSessionRecordStore();
  if (crypto == null || store == null) return null;
  return KeepSignedIn(crypto: crypto, store: store);
});

final tenantTokenStoreProvider = Provider<TenantTokenStore>((ref) {
  final k = ref.watch(keepSignedInProvider);
  if (k != null) return TenantTokenStore.productionKeepSignedIn(k);
  return TenantTokenStore.production();
});

final activeRealmHolderProvider = Provider<ActiveRealmHolder>((ref) {
  return ActiveRealmHolder();
});

/// REQ-429 (MOB-7) design §4.4 — tier (a)'s "tenant default" holder, set by
/// [runTenantBootstrap]/[switchTenant] from `TenantConfig.defaultLocale`.
final activeTenantLocaleHolderProvider = Provider<ActiveTenantLocaleHolder>((
  ref,
) {
  return ActiveTenantLocaleHolder();
});

/// Resolved once per read from the active tenant's default locale (if any)
/// plus the device's own reported locales — the same "resolved once per
/// session" shape as the SPA's `useSessionLocaleStore` (design §4.4). Every
/// call site that formats a date or number reads this provider rather than
/// constructing a bare, locale-less `DateFormat`/`NumberFormat`.
final formattingLocaleProvider = Provider<String>((ref) {
  final tenantLocale = ref.watch(activeTenantLocaleHolderProvider);
  return resolveFormattingLocale(
    tenantDefaultLocale: tenantLocale.defaultLocale,
  );
});

final Provider<ApiClient> apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient.create(
    tokenStore: ref.watch(tenantTokenStoreProvider),
    activeRealm: ref.watch(activeRealmHolderProvider),
    appAuthAdapter: defaultAppAuthAdapter(),
    onRefreshRejected: ref.watch(keepSignedInProvider)?.delete,
    // `ref.read` here is deferred until a 401-refresh failure actually
    // calls this closure — it is never evaluated while `apiClientProvider`
    // itself is being built, so this does not create a build-time circular
    // dependency with `bootstrapControllerProvider` (which itself depends
    // on `apiClientProvider`) even though each provider's *value* depends
    // on the other's (REQ-425 design §2.4/OQ-3 — resolved this way since
    // the design left the exact routing mechanism as an implementation
    // detail of this app's actual router/provider setup).
    routeToLogin: () => ref.read(bootstrapControllerProvider).resetToEntry(),
  );
});

/// The tenant's installed modules, as last resolved by the bootstrap.
final Provider<List<InstalledModule>> installedModulesProvider =
    Provider<List<InstalledModule>>(
      (ref) => ref.watch(bootstrapControllerProvider).state.installedModules,
    );

final ChangeNotifierProvider<BootstrapController> bootstrapControllerProvider =
    ChangeNotifierProvider<BootstrapController>((ref) {
      return BootstrapController(
        client: ref.watch(apiClientProvider),
        tokenStore: ref.watch(tenantTokenStoreProvider),
        activeRealm: ref.watch(activeRealmHolderProvider),
        definitionCache: ref.watch(definitionCacheHolderProvider),
        pinnedFormCache: ref.watch(pinnedFormCacheHolderProvider),
        offlineQueue: ref.watch(offlineQueueProvider),
        tenantLocale: ref.watch(activeTenantLocaleHolderProvider),
        keepSignedIn: ref.watch(keepSignedInProvider),
        deviceUnlock: ref.watch(keepSignedInProvider) == null
            ? null
            : webDeviceUnlock(),
      );
    });

/// PWA M3: sends the queued offline drafts once, when the app opens with a
/// verified session. Fire and forget; a failing sync never crashes the shell.
Future<void> syncOfflineQueueOnOpen(WidgetRef ref) async {
  try {
    await ref.read(offlineSyncProvider)?.drain();
  } on Object {
    // Entries stay queued; the user can tap "Send now".
  }
}

/// Renders the dedicated screen for [reason] (design §6) — the single
/// dispatch point; never a generic fallback for one of the four named
/// cases.
Widget buildErrorScreen(
  BootstrapFailureReason reason, {
  VoidCallback? onRetry,
}) {
  return switch (reason) {
    BootstrapFailureReason.tenantNotFound => TenantNotFoundScreen(
      onBackToEntry: onRetry,
    ),
    BootstrapFailureReason.networkUnavailable => NetworkUnavailableScreen(
      onRetry: onRetry,
    ),
    BootstrapFailureReason.oidcFailure => OidcFailureScreen(onRetry: onRetry),
    BootstrapFailureReason.secureStorageUnavailable =>
      SecureStorageUnavailableScreen(onRetry: onRetry),
  };
}
