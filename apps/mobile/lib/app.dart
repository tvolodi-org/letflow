import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'bootstrap/keep_signed_in_screens.dart';
import 'bootstrap/navigation_bootstrap.dart';
import 'definitions/tenant_home_screen.dart' show TenantHomeScreen;

/// The one sanctioned "app/router" file (REQ-419 design §3). Defines the
/// top-level app widget and the [GoRouter] instance, gated on
/// `BootstrapController`'s state (REQ-421 design §5.4). The real provider
/// wiring (`ApiClient`, `TenantTokenStore`, `ActiveRealmHolder`,
/// `bootstrapControllerProvider`) lives in `bootstrap/navigation_bootstrap.dart`
/// so both this file's router and that file's own widgets can depend on it
/// without a circular import.
///
/// REQ-423 design §7.3 — [attemptSessionResume] is invoked once at app
/// start (before any tenant-content route is requested), so a previously-
/// authenticated, currently-offline device can reach [TenantHomeScreen]
/// without needing bootstrap's usual three-call network sequence to
/// succeed first.
class LetflowApp extends ConsumerStatefulWidget {
  const LetflowApp({super.key});

  @override
  ConsumerState<LetflowApp> createState() => _LetflowAppState();
}

class _LetflowAppState extends ConsumerState<LetflowApp> {
  // Built exactly once, here — never inside `build()`. `GoRouter` itself
  // uses `refreshListenable: controller` to re-evaluate `redirect` on every
  // `BootstrapController` state change, which is sufficient to gate
  // *navigation* (design §5.4) — but go_router does **not** re-invoke a
  // route's `builder` on a `refreshListenable` notification when the
  // matched location is unchanged (verified directly against this
  // project's pinned `go_router` version: a bare `refreshListenable`
  // notify with no resulting location change never re-runs `builder`).
  // Reconstructing a brand-new `GoRouter` per rebuild (the previous
  // pattern, driven by `ref.watch` triggering `LetflowApp.build()`) worked
  // around that by replacing the whole `Navigator`/route-widget tree on
  // every notification — but that discards in-flight widget state (e.g.
  // text already entered in `TenantSlugEntryScreen`) the instant such a
  // notification lands mid-interaction, which is exactly what
  // `attemptSessionResume`'s own asynchronous, unawaited `notifyListeners()`
  // call now does. The router is therefore built once; the `'/'` route's
  // content is wrapped in its own [ListenableBuilder] below so it still
  // refreshes on a `BootstrapController` state change without the whole
  // router/navigator being torn down.
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    final controller = ref.read(bootstrapControllerProvider);
    _controller = controller;
    _router = _buildRouter(controller);
    // Fire-and-forget: a device with no last-active-tenant pointer leaves
    // state at `BootstrapPhase.unauthenticated` unconditionally (today's
    // exact behaviour, design §7.3).
    controller.attemptSessionResume();
    // PWA M3: send the queued offline drafts once per app start, as soon as
    // the session is network-verified (not on `resumedOffline`).
    controller.addListener(_syncOnceWhenVerified);
    // REQ-810: the 30-day offer, shown once per full sign-in.
    controller.offerKeepSignedIn.addListener(_maybeOffer);
  }

  bool _offering = false;

  void _maybeOffer() {
    if (!_controller.offerKeepSignedIn.value || _offering) return;
    _offering = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final ctx = _router.routerDelegate.navigatorKey.currentContext;
        if (ctx == null || !ctx.mounted) {
          _controller.declineKeepSignedIn();
          return;
        }
        final accepted = await showKeepSignedInOffer(ctx);
        if (!accepted || !ctx.mounted) {
          _controller.declineKeepSignedIn();
          return;
        }
        await Navigator.of(ctx).push<bool>(
          MaterialPageRoute<bool>(builder: (_) => const PinSetupScreen()),
        );
        _controller.declineKeepSignedIn();
        if (!ctx.mounted) {
          _controller.declineDeviceUnlock();
        } else if (_controller.offerDeviceUnlock.value) {
          await _offerDevice(ctx);
        }
      } finally {
        _offering = false;
      }
    });
  }

  /// REQ-811: after the PIN is saved, offer "unlock with this device".
  Future<void> _offerDevice(BuildContext ctx) async {
    final accepted = await showDeviceUnlockOffer(ctx);
    if (!accepted) {
      _controller.declineDeviceUnlock();
      return;
    }
    final outcome = await _controller.enrollDeviceUnlock();
    final line = deviceEnrolOutcomeText(outcome);
    if (line != null && ctx.mounted) {
      ScaffoldMessenger.maybeOf(
        ctx,
      )?.showSnackBar(SnackBar(content: Text(line)));
    }
  }

  late final BootstrapController _controller;
  bool _synced = false;

  void _syncOnceWhenVerified() {
    if (_synced) return;
    if (_controller.state.phase != BootstrapPhase.success) return;
    _synced = true;
    unawaited(syncOfflineQueueOnOpen(ref));
  }

  @override
  void dispose() {
    _controller.removeListener(_syncOnceWhenVerified);
    _controller.offerKeepSignedIn.removeListener(_maybeOffer);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(title: 'Letflow', routerConfig: _router);
  }
}

/// Content is reachable — a tenant-content or `/home` route may be shown —
/// exactly when bootstrap has reached one of these two phases (design
/// §7.3): `success` (fully network-verified) or `resumedOffline`
/// (identity-only, membership/modules unverified). Never merges the two
/// into one meaning; callers that need to distinguish them still can via
/// `controller.state.phase` directly.
bool _contentReachable(BootstrapPhase phase) =>
    phase == BootstrapPhase.success || phase == BootstrapPhase.resumedOffline;

GoRouter _buildRouter(BootstrapController controller) {
  return GoRouter(
    refreshListenable: controller,
    initialLocation: '/',
    redirect: (context, state) {
      final phase = controller.state.phase;
      final reachable = _contentReachable(phase);
      // No tenant-content route is reachable until bootstrap succeeds or
      // resumes offline (design §5.2/§5.4's ordering invariant, extended
      // by REQ-423 §7.3).
      if (!reachable && state.matchedLocation != '/') {
        return '/';
      }
      // REQ-423 design §8.4 — the default landing target for either
      // content-reachable phase is `/home` explicitly.
      if (reachable && state.matchedLocation == '/') {
        return '/home';
      }
      return null;
    },
    routes: [
      GoRoute(
        path: '/',
        // `ListenableBuilder` — not a bare read of `controller.state` — is
        // what makes this content refresh on every `BootstrapController`
        // change despite the route's own `builder` only being re-invoked
        // by go_router when the matched location itself changes (see
        // `_LetflowAppState`'s own doc comment above).
        builder: (context, state) {
          return ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final uiState = controller.state;
              if (uiState.phase == BootstrapPhase.failure &&
                  uiState.failureReason != null) {
                return buildErrorScreen(
                  uiState.failureReason!,
                  onRetry: controller.resetToEntry,
                );
              }
              if (uiState.phase == BootstrapPhase.locked) {
                return const PinUnlockScreen();
              }
              return const TenantSlugEntryScreen();
            },
          );
        },
      ),
      GoRoute(
        path: '/home',
        builder: (context, state) => const TenantHomeScreen(),
      ),
      // buildRouteTable uses the real feature registry (`codes`, REQ-732).
      // A module absent from `installed_modules` has no route entry here, so
      // `GoRouter`'s own default not-found page is shown for it (AC3).
      ...buildRouteTable(controller.state.installedModules),
    ],
  );
}
