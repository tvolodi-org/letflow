// Tests that the real _buildRouter in app.dart registers module routes from
// kFeatureRegistry at construction and guards absent modules via redirect.
//
// These tests use the real LetflowApp (and therefore the real _buildRouter)
// and drive BootstrapController through forceStateForTesting. On unmodified
// code, _buildRouter called buildRouteTable(controller.state.installedModules)
// — an empty list at construction — so after a successful bootstrap the router
// had no /codes/scan or /stock routes and GoRouter showed "Page Not Found".
// Every test in this file would have failed on that code.
//
// REQ-124/REQ-125: registered via bootstrap_sequence_test.dart (which owns
// the controller-level coverage); these tests cover the router-level
// acceptance criteria for the fix only.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:letflow/api/api_client.dart';
import 'package:letflow/app.dart';
import 'package:letflow/auth/auth.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';
import 'package:letflow/definitions/definitions.dart';
import 'package:letflow/definitions/pinned_form_cache.dart';
import 'package:letflow/definitions/tenant_home_screen.dart';
import 'package:letflow/features/codes/scan_screen.dart';
import 'package:letflow/features/codes/scan_source.dart';

import '../features/codes/fakes.dart';
import '../support/fake_app_auth_adapter.dart';
import '../support/fake_http_gateway.dart';
import '../support/fake_post_capable_http_gateway.dart';
import '../support/load_test_catalogue.dart';

// ── Helpers ─────────────────────────────────────────────────────────────────

/// A [HttpGateway] whose calls never complete — pins the controller in
/// [BootstrapPhase.loading] when beginBootstrap is called, which is never
/// done in this file (we use forceStateForTesting instead).
class _NeverGateway implements HttpGateway {
  @override
  Future<Response<dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) => Completer<Response<dynamic>>().future;

  @override
  Future<Response<dynamic>> getUnauthenticated(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) => Completer<Response<dynamic>>().future;
}

BootstrapController _makeController() => BootstrapController(
  client: _NeverGateway(),
  tokenStore: const TenantTokenStore(FlutterSecureStorage()),
  activeRealm: ActiveRealmHolder(),
  definitionCache: ActiveDefinitionCacheHolder(),
  pinnedFormCache: ActivePinnedFormCacheHolder(),
  cacheOpener: (_) async => InMemoryDefinitionCacheRepository(),
  pinnedFormCacheOpener: (_) async => InMemoryPinnedFormCacheRepository(),
  appAuthAdapter: FakeAppAuthAdapter(response: fakeTokenResponse()),
);

/// Minimal [DefinitionHomeController] backed by an empty in-memory repo.
/// [DefinitionSyncService.syncOnce] throws (no scripted response) but its
/// own catch-all swallows it, so the controller is safe to use in tests that
/// never rely on cached definitions.
DefinitionHomeController _makeDefinitionController() {
  final repo = InMemoryDefinitionCacheRepository();
  return DefinitionHomeController(
    repository: repo,
    syncService: DefinitionSyncService(
      repository: repo,
      client: FakeHttpGateway(), // throws on any call; syncOnce() catches it
    ),
  );
}

/// Pumps a [LetflowApp] with the minimum provider overrides needed to reach
/// tenant-content routes without crashing:
/// - [bootstrapControllerProvider] → the supplied [controller]
/// - [definitionHomeControllerProvider] → an empty in-memory controller
/// - [scanSourceProvider] → [fakeScanSource] (for /codes/scan; pass null to
///   skip the override when the test does not reach that screen)
/// - [codesGatewayProvider] → [codesGateway] (same)
Future<void> _pumpApp(
  WidgetTester tester,
  BootstrapController controller, {
  FakeScanSource? fakeScanSource,
  FakePostCapableHttpGateway? codesGateway,
}) async {
  final overrides = <Override>[
    bootstrapControllerProvider.overrideWith((ref) => controller),
    definitionHomeControllerProvider.overrideWith(
      (ref) => _makeDefinitionController(),
    ),
    if (fakeScanSource != null)
      scanSourceProvider.overrideWithValue(() => fakeScanSource),
    if (codesGateway != null)
      codesGatewayProvider.overrideWithValue(codesGateway),
  ];
  await tester.pumpWidget(
    ProviderScope(overrides: overrides, child: const LetflowApp()),
  );
  await tester.pump(); // settle initial frame (slug entry screen)
}

// Advances frames until stable; used after state changes that trigger GoRouter
// redirect (which may involve a page-transition animation).
Future<void> _settle(WidgetTester tester) =>
    tester.pumpAndSettle(const Duration(milliseconds: 50));

// ── Tests ────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(loadTestMessageCatalogue);

  // ── Red-proof + AC1: after bootstrap success with [codes, stock] the two
  //    home-screen tiles navigate to their own screens without "Page Not Found"
  //    (this test fails on the unmodified code because _buildRouter used to
  //    pass an empty installed-module list to buildRouteTable)
  testWidgets(
    'after bootstrap success with codes+stock: Scan Code tile reaches scan screen',
    (tester) async {
      final controller = _makeController();
      final source = FakeScanSource();
      final gateway = FakePostCapableHttpGateway();

      await _pumpApp(
        tester,
        controller,
        fakeScanSource: source,
        codesGateway: gateway,
      );

      // Drive the controller to success: routes for both modules were
      // registered at _buildRouter time (fix) and the redirect now allows them.
      controller.forceStateForTesting(
        const BootstrapUiState(
          phase: BootstrapPhase.success,
          installedModules: [
            InstalledModule(moduleId: 'codes', version: '1.0.0'),
            InstalledModule(moduleId: 'stock', version: '1.0.0'),
          ],
        ),
      );
      // settle includes page-transition animation to /home
      await _settle(tester);

      // The 'Scan Code' tile is shown when codes is installed.
      expect(find.byKey(const Key('tenant-home-codes-entry')), findsOneWidget);

      await tester.tap(find.byKey(const Key('tenant-home-codes-entry')));
      await _settle(tester); // navigate to /codes/scan

      // On unmodified code the route did not exist: GoRouter showed
      // "Page Not Found" and this expectation would fail.
      expect(find.text('Page Not Found'), findsNothing);
      expect(find.byKey(const Key('codes-scan-screen')), findsOneWidget);
    },
  );

  testWidgets(
    'after bootstrap success with codes+stock: Warehouse tile reaches stock home',
    (tester) async {
      final controller = _makeController();

      await _pumpApp(tester, controller);

      controller.forceStateForTesting(
        const BootstrapUiState(
          phase: BootstrapPhase.success,
          installedModules: [
            InstalledModule(moduleId: 'codes', version: '1.0.0'),
            InstalledModule(moduleId: 'stock', version: '1.0.0'),
          ],
        ),
      );
      await _settle(tester);

      expect(find.byKey(const Key('tenant-home-stock-entry')), findsOneWidget);

      await tester.tap(find.byKey(const Key('tenant-home-stock-entry')));
      await _settle(tester);

      expect(find.text('Page Not Found'), findsNothing);
      expect(find.byKey(const Key('stock-home-screen')), findsOneWidget);
    },
  );

  // ── AC2: with only codes installed, /stock is refused (redirected to /home)
  testWidgets(
    'with only codes installed: /stock is redirected to /home; /codes/scan opens',
    (tester) async {
      final controller = _makeController();
      final source = FakeScanSource();
      final gateway = FakePostCapableHttpGateway();

      await _pumpApp(
        tester,
        controller,
        fakeScanSource: source,
        codesGateway: gateway,
      );

      controller.forceStateForTesting(
        const BootstrapUiState(
          phase: BootstrapPhase.success,
          installedModules: [
            InstalledModule(moduleId: 'codes', version: '1.0.0'),
          ],
        ),
      );
      await _settle(tester);

      expect(find.byKey(const Key('tenant-home-codes-entry')), findsOneWidget);
      expect(find.byKey(const Key('tenant-home-stock-entry')), findsNothing);

      // Navigate to /stock directly: the route exists in the table but the
      // module is absent from installed_modules → redirect to /home.
      final ctx = tester.element(find.byKey(const Key('tenant-home-screen')));
      GoRouter.of(ctx).go('/stock');
      await _settle(tester);

      expect(find.text('Page Not Found'), findsNothing);
      // Redirect landed back at /home.
      expect(find.byKey(const Key('tenant-home-screen')), findsOneWidget);

      // /codes/scan is accessible with codes installed.
      GoRouter.of(
        tester.element(find.byKey(const Key('tenant-home-screen'))),
      ).go('/codes/scan');
      await _settle(tester);

      expect(find.text('Page Not Found'), findsNothing);
      expect(find.byKey(const Key('codes-scan-screen')), findsOneWidget);
    },
  );

  // ── AC3: router built exactly once — typed text in the slug entry screen
  //         survives a BootstrapController notification
  testWidgets(
    'slug screen keeps typed text when BootstrapController notifies',
    (tester) async {
      final controller = _makeController();

      await _pumpApp(tester, controller);

      expect(find.byKey(const Key('tenant-slug-entry-screen')), findsOneWidget);

      // Type a slug.
      await tester.enterText(
        find.byKey(const Key('tenant-slug-field')),
        'acme',
      );
      await tester.pump();

      // Verify text was entered (via the widget's TextEditingController, since
      // find.text in a router-based app may not match EditableText reliably).
      final fieldBefore = tester.widget<TextField>(
        find.byKey(const Key('tenant-slug-field')),
      );
      expect(fieldBefore.controller?.text, 'acme');

      // Fire a notification with the same unauthenticated state — simulates
      // an event (e.g. attemptSessionResume completing) that re-runs redirect
      // without changing the phase. If the router were rebuilt from scratch
      // (the old pattern), TenantSlugEntryScreen would be torn down and the
      // text field would be reset.
      controller.forceStateForTesting(BootstrapUiState.unauthenticated);
      await tester.pump();

      // Text survives because _router is built exactly once in initState.
      final fieldAfter = tester.widget<TextField>(
        find.byKey(const Key('tenant-slug-field')),
      );
      expect(fieldAfter.controller?.text, 'acme');
      expect(find.byKey(const Key('tenant-slug-entry-screen')), findsOneWidget);
    },
  );

  // ── Minor: resumedOffline behaviour
  //    In resumedOffline, installedModules is the last-verified set. A module
  //    in that set is reachable; one absent from it is refused — consistent
  //    with the success-phase guard (the distinction between verified and
  //    offline-resumed is preserved in phase for callers that need it).
  testWidgets(
    'resumedOffline: installed module is reachable; absent module is refused',
    (tester) async {
      final controller = _makeController();
      final source = FakeScanSource();
      final gateway = FakePostCapableHttpGateway();

      await _pumpApp(
        tester,
        controller,
        fakeScanSource: source,
        codesGateway: gateway,
      );

      // resumedOffline with [codes] in the last-known list.
      controller.forceStateForTesting(
        const BootstrapUiState(
          phase: BootstrapPhase.resumedOffline,
          installedModules: [
            InstalledModule(moduleId: 'codes', version: '1.0.0'),
          ],
        ),
      );
      await _settle(tester);

      // /codes/scan: codes is in installedModules → allowed.
      final ctx = tester.element(find.byKey(const Key('tenant-home-screen')));
      GoRouter.of(ctx).go('/codes/scan');
      await _settle(tester);

      expect(find.text('Page Not Found'), findsNothing);
      expect(find.byKey(const Key('codes-scan-screen')), findsOneWidget);

      // Navigate back to /home, then try /stock (not in last-known list → refused).
      GoRouter.of(
        tester.element(find.byKey(const Key('codes-scan-screen'))),
      ).go('/home');
      await _settle(tester);

      GoRouter.of(
        tester.element(find.byKey(const Key('tenant-home-screen'))),
      ).go('/stock');
      await _settle(tester);

      expect(find.text('Page Not Found'), findsNothing);
      expect(find.byKey(const Key('tenant-home-screen')), findsOneWidget);
    },
  );
}
