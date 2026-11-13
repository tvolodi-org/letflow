// T-1902: EN/RU/KK switch on the slug-entry screen and the home app bar;
// applied at once, remembered on the device, typed text kept.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/app.dart';
import 'package:letflow/auth/auth.dart';
import 'package:letflow/auth/kv_store.dart';
import 'package:letflow/bootstrap/language_switcher.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';
import 'package:letflow/i18n/i18n.dart';

import '../support/load_test_catalogue.dart';

TenantTokenStore _store(KvStore pointer) =>
    TenantTokenStore.withBackends(tokens: MemoryKv(), pointer: pointer);

Widget _app(TenantTokenStore store) => ProviderScope(
  overrides: [tenantTokenStoreProvider.overrideWithValue(store)],
  child: const LetflowApp(),
);

String _typed(WidgetTester t) => t
    .widget<TextField>(find.byKey(const Key('tenant-slug-field')))
    .controller!
    .text;

void main() {
  setUpAll(loadTestMessageCatalogue);
  setUp(() => setUserUiLocale(null));
  tearDown(() => setUserUiLocale(null));

  testWidgets('switch changes labels at once and keeps typed text', (
    tester,
  ) async {
    final pointer = MemoryKv();
    await tester.pumpWidget(_app(_store(pointer)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('tenant-slug-field')), 'acme');
    expect(
      find.text(tr('bootstrap.slugEntry.prompt', uiLocale: 'en')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('language-ru')));
    await tester.pumpAndSettle();
    expect(
      find.text(tr('bootstrap.slugEntry.prompt', uiLocale: 'ru')),
      findsOneWidget,
    );
    expect(_typed(tester), 'acme');

    await tester.tap(find.byKey(const Key('language-kk')));
    await tester.pumpAndSettle();
    expect(
      find.text(tr('bootstrap.slugEntry.prompt', uiLocale: 'kk')),
      findsOneWidget,
    );
    expect(_typed(tester), 'acme');
    expect(await pointer.read('letflow.ui_locale'), 'kk');
  });

  testWidgets('choice persists across a restart and beats device locale', (
    tester,
  ) async {
    final pointer = MemoryKv();
    await tester.pumpWidget(_app(_store(pointer)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('language-ru')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());

    setUserUiLocale(null); // a fresh process
    expect(resolveUiLocale(), isNot('ru'));
    await tester.pumpWidget(_app(_store(pointer)));
    await tester.pumpAndSettle();
    expect(userUiLocale.value, 'ru');
    expect(
      find.text(tr('bootstrap.slugEntry.prompt', uiLocale: 'ru')),
      findsOneWidget,
    );
  });

  test('user choice wins over candidates-less device resolution', () {
    setUserUiLocale('kk');
    expect(resolveUiLocale(), 'kk');
    expect(resolveUiLocale(['ru-RU']), 'ru'); // explicit candidates unchanged
    setUserUiLocale('de'); // unsupported: ignored
    expect(resolveUiLocale(), 'kk');
  });

  testWidgets('switcher widget renders three segments', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: Scaffold(body: const LanguageSwitcher())),
      ),
    );
    for (final c in ['en', 'ru', 'kk']) {
      expect(find.byKey(Key('language-$c')), findsOneWidget);
    }
  });
}
