// T-1587: refused queue entries show both copies and let the person choose;
// the install hint is shown once.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:letflow/features/stock/documents/document_draft.dart';
import 'package:letflow/features/stock/documents/document_kinds.dart';
import 'package:letflow/features/stock/documents/documents_api.dart';
import 'package:letflow/features/stock/documents/documents_providers.dart';
import 'package:letflow/features/stock/documents/offline_providers.dart';
import 'package:letflow/features/stock/stock.dart';
import 'package:letflow/i18n/i18n.dart';
import 'package:letflow/offline/install_hint_store.dart';
import 'package:letflow/offline/install_state.dart';
import 'package:letflow/offline/offline_queue.dart';
import 'package:letflow/offline/offline_sync.dart';

import '../../support/fake_write_gateway.dart';
import '../../support/load_test_catalogue.dart';

const _docs = '/api/v1/modules/stock/documents';

class _Q implements OfflineDraftQueue {
  final List<QueuedDraft> items = [];
  @override
  Future<EnqueueResult> enqueue(
    Map<String, dynamic> body, {
    String label = '',
    String summary = '',
  }) async {
    items.add(
      QueuedDraft(
        localId: 'e${items.length}',
        body: body,
        label: label,
        summary: summary,
        createdAtMs: items.length,
      ),
    );
    return EnqueueResult.stored;
  }

  @override
  Future<List<QueuedDraft>> all() async => [...items];
  @override
  Future<int> count() async => items.length;
  @override
  Future<void> remove(String id) async =>
      items.removeWhere((e) => e.localId == id);
  @override
  Future<void> markRejected(
    String id,
    String code, {
    Map<String, dynamic>? detail,
  }) async {
    _put(id, code, detail);
  }

  @override
  Future<void> clearRejection(String id) async => _put(id, null, null);
  void _put(String id, String? code, Map<String, dynamic>? detail) {
    final i = items.indexWhere((e) => e.localId == id);
    final e = items[i];
    items[i] = QueuedDraft(
      localId: id,
      body: e.body,
      label: e.label,
      summary: e.summary,
      createdAtMs: e.createdAtMs,
      rejection: code,
      rejectionDetail: detail,
    );
  }

  @override
  Future<void> closeAndClear() async => items.clear();
}

final _body = DocDraft(
  kind: DocKind.receipt,
  eventTime: '2026-11-05T10:00:00+05:00',
  header: const {'org_unit_id': 'o', 'location_id': 'l', 'responsible_id': 'r'},
  lines: const [DocLine(item: 'i1', uom: 'u1', quantity: '2')],
).toBody();

void main() {
  setUpAll(loadTestMessageCatalogue);

  test('M1: fromBody inverts toBody', () {
    final d = DocDraft.fromBody(_body)!;
    expect(d.toBody(), _body);
    expect(d.id, isNull);
    expect(DocDraft.fromBody({'kind': 'nope', 'lines': []}), isNull);
  });

  late FakeWriteGateway gw;
  late _Q q;
  setUp(() {
    gw = FakeWriteGateway();
    q = _Q();
  });

  Future<void> pump(
    WidgetTester tester, {
    InstallPlatform platform = InstallPlatform.other,
    InstallState state = InstallState.browser,
    bool web = false,
    InstallHintStore? store,
    Size? size,
  }) async {
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
    gw.on('GET', _docs, [
      {'rows': []},
      {'rows': []},
      {'rows': []},
    ]);
    final router = GoRouter(
      initialLocation: kStockDocumentsPath,
      routes: stockRoutes(),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          stockGatewayProvider.overrideWithValue(gw),
          offlineQueueProvider.overrideWithValue(q),
          offlineQueueEnabledProvider.overrideWithValue(web),
          installPlatformProvider.overrideWithValue(platform),
          installStateProvider.overrideWithValue(state),
          installHintStoreProvider.overrideWithValue(store),
          offlineSyncProvider.overrideWithValue(
            OfflineSyncService(q, StockDocumentsApi(gw).createFromBody),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<String> refused({Map<String, dynamic>? detail, String? code}) async {
    await q.enqueue(_body, label: 'Receipt', summary: '1 lines: A x2');
    await q.markRejected('e0', code ?? 'validation', detail: detail);
    return 'e0';
  }

  testWidgets('W1: card shows the draft and the server text', (t) async {
    await refused(detail: {'reason': 'location_frozen'});
    await pump(t);
    expect(find.text('1 lines: A x2'), findsOne);
    expect(find.text(tr('stock.doc.error.location_frozen')), findsOne);
    expect(find.text(tr('offline.conflict.keepNote')), findsOne);
  });

  testWidgets('W1b: unknown reason is generic, old entry shows the code', (
    t,
  ) async {
    await refused(detail: {'reason': '<script>'});
    await pump(t);
    expect(find.text(tr('stock.doc.error.generic')), findsOne);
    expect(find.textContaining('<script>'), findsNothing);
  });

  testWidgets('W1c: old entry without detail shows the code word', (t) async {
    await refused(code: 'conflict');
    await pump(t);
    expect(
      find.text(tr('offline.rejected').replaceAll('{reason}', 'conflict')),
      findsOne,
    );
  });

  testWidgets('W2: narrow screen does not overflow', (t) async {
    await refused(detail: {'reason': 'location_frozen'});
    await pump(t, size: const Size(320, 640));
    expect(t.takeException(), isNull);
  });

  testWidgets('W3: cancel keeps the entry', (t) async {
    final id = await refused(detail: {'reason': 'field_required'});
    await pump(t);
    await t.tap(find.byKey(Key('stock-doc-offline-rejected-$id-discard')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('stock-doc-offline-discard-cancel')));
    await t.pumpAndSettle();
    expect(q.items, hasLength(1));
  });

  testWidgets('W4: Send again clears the refusal and sends', (t) async {
    final id = await refused(detail: {'reason': 'field_required'});
    gw.on('POST', _docs, [
      {'id': 'd1'},
    ]);
    await pump(t);
    await t.tap(find.byKey(Key('stock-doc-offline-rejected-$id-retry')));
    await t.pumpAndSettle();
    expect(gw.callsTo('POST', _docs), hasLength(1));
    expect(q.items, isEmpty);
  });

  testWidgets('W5: Edit and resend prefills; online save removes the old', (
    t,
  ) async {
    final id = await refused(detail: {'reason': 'field_required'});
    gw.on('POST', _docs, [
      (Object? d) => {...(d as Map), 'id': 'd2', 'state': 'draft'},
    ]);
    await pump(t, size: const Size(800, 3000));
    await t.tap(find.byKey(Key('stock-doc-offline-rejected-$id-edit')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('stock-doc-form-screen')), findsOne);
    expect(q.items, hasLength(1)); // not removed before the save
    await t.tap(find.byKey(const Key('stock-doc-save')));
    await t.pumpAndSettle();
    expect(gw.callsTo('POST', _docs), hasLength(1));
    expect(q.items, isEmpty);
  });

  testWidgets('H: ios hint shown once, dismissed, stored', (t) async {
    final store = MemoryInstallHintStore();
    await pump(t, platform: InstallPlatform.ios, web: true, store: store);
    expect(find.byKey(const Key('stock-doc-install-hint')), findsOne);
    expect(find.text(tr('offline.install.ios')), findsOne);
    expect(find.byKey(const Key('stock-doc-storage-warning')), findsNothing);
    await t.tap(find.byKey(const Key('stock-doc-install-hint-dismiss')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('stock-doc-install-hint')), findsNothing);
    expect(await store.seen(), isTrue);
    expect(find.byKey(const Key('stock-doc-storage-warning')), findsOne);
  });

  testWidgets('H3b: a rebuilt screen with a seen store has no hint', (t) async {
    final store = MemoryInstallHintStore();
    await store.markSeen();
    await pump(t, platform: InstallPlatform.android, web: true, store: store);
    expect(find.byKey(const Key('stock-doc-install-hint')), findsNothing);
  });

  testWidgets('H1b: android shown; other and installed not shown', (t) async {
    await pump(
      t,
      platform: InstallPlatform.android,
      web: true,
      store: MemoryInstallHintStore(),
    );
    expect(find.text(tr('offline.install.android')), findsOne);
  });

  testWidgets('H1c: installed shows no hint', (t) async {
    await pump(
      t,
      platform: InstallPlatform.ios,
      state: InstallState.installed,
      web: true,
      store: MemoryInstallHintStore(),
    );
    expect(find.byKey(const Key('stock-doc-install-hint')), findsNothing);
  });
}
