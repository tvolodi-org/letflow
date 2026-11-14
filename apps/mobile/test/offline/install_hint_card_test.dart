import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/features/stock/documents/offline_providers.dart';
import 'package:letflow/i18n/i18n.dart';
import 'package:letflow/offline/install_hint_card.dart';
import 'package:letflow/offline/install_hint_store.dart';
import 'package:letflow/offline/install_state.dart';

void main() {
  Future<void> pump(
    WidgetTester t, {
    InstallPlatform platform = InstallPlatform.ios,
    InstallState state = InstallState.browser,
    bool web = true,
    required InstallHintStore store,
  }) async {
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          offlineQueueEnabledProvider.overrideWithValue(web),
          installHintEnabledProvider.overrideWithValue(web),
          installPlatformProvider.overrideWithValue(platform),
          installStateProvider.overrideWithValue(state),
          installHintStoreProvider.overrideWithValue(store),
        ],
        child: const MaterialApp(home: Scaffold(body: InstallHintCard())),
      ),
    );
    await t.pumpAndSettle();
  }

  testWidgets('unread: how-to open; read hides it, stored, entry stays', (
    t,
  ) async {
    final store = MemoryInstallHintStore();
    await pump(t, store: store);
    expect(find.byKey(const Key('install-hint-card')), findsOne);
    expect(find.text(tr('offline.install.ios')), findsOne);
    expect(find.text(tr('offline.install.android')), findsNothing);
    await t.tap(find.byKey(const Key('install-hint-dismiss')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('install-hint-card')), findsNothing);
    expect(await store.seen(), isTrue);
    expect(find.byKey(const Key('install-hint-open')), findsOne);
  });

  testWidgets('already read: only the entry; it opens the how-to again', (
    t,
  ) async {
    final store = MemoryInstallHintStore();
    await store.markSeen();
    await pump(t, store: store, platform: InstallPlatform.android);
    expect(find.byKey(const Key('install-hint-card')), findsNothing);
    await t.tap(find.byKey(const Key('install-hint-open')));
    await t.pumpAndSettle();
    expect(find.text(tr('offline.install.android')), findsOne);
    expect(find.text(tr('offline.install.ios')), findsNothing);
  });

  testWidgets('desktop browser shows both how-tos', (t) async {
    await pump(
      t,
      store: MemoryInstallHintStore(),
      platform: InstallPlatform.other,
    );
    expect(find.text(tr('offline.install.ios')), findsOne);
    expect(find.text(tr('offline.install.android')), findsOne);
  });

  testWidgets('installed app and non-web show nothing', (t) async {
    await pump(
      t,
      store: MemoryInstallHintStore(),
      state: InstallState.installed,
    );
    expect(find.byType(Card), findsNothing);
    expect(find.byKey(const Key('install-hint-open')), findsNothing);
    await pump(t, store: MemoryInstallHintStore(), web: false);
    expect(find.byType(Card), findsNothing);
    expect(find.byKey(const Key('install-hint-open')), findsNothing);
  });
}
