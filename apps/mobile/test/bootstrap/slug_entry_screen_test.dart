// T-1903: Company code wording + last-code prefill.
//
// AC-I: prompt text in en/ru/kk shows updated "Company code" label.
// AC-P: field is prefilled with the slug from the last sign-in.
// AC-E: field is empty when no previous sign-in is stored.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_client.dart';
import 'package:letflow/auth/auth.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';
import 'package:letflow/definitions/definitions.dart';
import 'package:letflow/definitions/pinned_form_cache.dart';

import '../support/fake_app_auth_adapter.dart';
import '../support/fake_http_gateway.dart';
import '../support/fake_secure_storage_platform.dart';
import '../support/load_test_catalogue.dart';

// ── helpers ───────────────────────────────────────────────────────────────

/// A minimal [BootstrapController] that stays in the unauthenticated state
/// (no network calls needed — we only test the slug entry screen itself).
BootstrapController _makeController(TenantTokenStore tokenStore) {
  return BootstrapController(
    client: FakeHttpGateway(),
    tokenStore: tokenStore,
    activeRealm: ActiveRealmHolder(),
    definitionCache: ActiveDefinitionCacheHolder(),
    pinnedFormCache: ActivePinnedFormCacheHolder(),
    cacheOpener: (_) async => InMemoryDefinitionCacheRepository(),
    pinnedFormCacheOpener: (_) async => InMemoryPinnedFormCacheRepository(),
    appAuthAdapter: FakeAppAuthAdapter(),
  );
}

/// Pumps the [TenantSlugEntryScreen] directly (not via the full app router)
/// so the test stays fast and does not need a matching GoRouter.
Future<void> _pumpScreen(
  WidgetTester tester,
  BootstrapController controller,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        bootstrapControllerProvider.overrideWith((ref) => controller),
      ],
      child: const MaterialApp(home: TenantSlugEntryScreen()),
    ),
  );
  // Allow the prefill microtask to settle.
  await tester.pump();
}

// ── tests ─────────────────────────────────────────────────────────────────

void main() {
  setUpAll(loadTestMessageCatalogue);

  setUp(() {
    FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
  });

  // AC-I: prompt label shows "Company code" in English.
  testWidgets('AC-I en: prompt shows "Company code"', (tester) async {
    final tokenStore = const TenantTokenStore(FlutterSecureStorage());
    final controller = _makeController(tokenStore);
    await _pumpScreen(tester, controller);

    expect(find.text('Company code'), findsOneWidget);
  });

  // AC-I: prompt label shows the Russian translation.
  testWidgets('AC-I ru: prompt shows "Код компании"', (tester) async {
    final tokenStore = const TenantTokenStore(FlutterSecureStorage());
    final controller = _makeController(tokenStore);
    await _pumpScreen(tester, controller);

    // Check the ARB catalogue directly for the Russian value (the widget
    // renders with the device locale, which is 'en' in a test environment;
    // the ARB values are verified by arb_completeness_test and codes_i18n_test
    // patterns — here we confirm the key carries the right Russian string).
    final arbRaw = await tester.runAsync(() async {
      return jsonDecode(
            await DefaultAssetBundle.of(
              tester.element(find.byType(TenantSlugEntryScreen)),
            ).loadString('lib/i18n/l10n/app_ru.arb'),
          )
          as Map<String, dynamic>;
    });
    expect(
      arbRaw!['bootstrap.slugEntry.prompt'],
      equals('Код компании'),
      reason: 'Russian prompt label',
    );
  });

  // AC-I: prompt label shows the Kazakh translation.
  testWidgets('AC-I kk: prompt shows "Компания коды"', (tester) async {
    final tokenStore = const TenantTokenStore(FlutterSecureStorage());
    final controller = _makeController(tokenStore);
    await _pumpScreen(tester, controller);

    final arbRaw = await tester.runAsync(() async {
      return jsonDecode(
            await DefaultAssetBundle.of(
              tester.element(find.byType(TenantSlugEntryScreen)),
            ).loadString('lib/i18n/l10n/app_kk.arb'),
          )
          as Map<String, dynamic>;
    });
    expect(
      arbRaw!['bootstrap.slugEntry.prompt'],
      equals('Компания коды'),
      reason: 'Kazakh prompt label',
    );
  });

  // AC-E: field is empty when no slug was stored.
  testWidgets('AC-E: field empty when no previous sign-in', (tester) async {
    // FakeSecureStoragePlatform starts empty, so no pointer is stored.
    final tokenStore = const TenantTokenStore(FlutterSecureStorage());
    final controller = _makeController(tokenStore);
    await _pumpScreen(tester, controller);

    final field = tester.widget<TextField>(
      find.byKey(const Key('tenant-slug-field')),
    );
    expect(field.controller?.text, isEmpty);
  });

  // AC-P: field is prefilled with the slug from the last successful sign-in.
  testWidgets('AC-P: field prefilled with last sign-in slug', (tester) async {
    final tokenStore = const TenantTokenStore(FlutterSecureStorage());
    // Write a pointer that simulates a previous successful sign-in.
    await writeLastActiveTenant(
      tokenStore,
      const LastActiveTenantPointer(
        realmUrl: 'https://idp.example/realms/acme',
        slug: 'acme',
      ),
    );

    final controller = _makeController(tokenStore);
    await _pumpScreen(tester, controller);

    final field = tester.widget<TextField>(
      find.byKey(const Key('tenant-slug-field')),
    );
    expect(field.controller?.text, equals('acme'));
  });
}
