// T-1499 (PWA M3): saving a new draft with no network goes to the offline
// queue (web only); the list shows the waiting entries and "Send now".
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:letflow/api/api_error.dart';
import 'package:letflow/features/stock/documents/document_draft.dart';
import 'package:letflow/features/stock/documents/document_form_controller.dart';
import 'package:letflow/features/stock/documents/document_kinds.dart';
import 'package:letflow/features/stock/documents/document_pickers.dart';
import 'package:letflow/features/stock/documents/documents_api.dart';
import 'package:letflow/features/stock/documents/documents_providers.dart';
import 'package:letflow/features/stock/stock.dart';
import 'package:letflow/i18n/i18n.dart';
import 'package:letflow/offline/offline_queue.dart';
import 'package:letflow/offline/offline_sync.dart';
import 'package:sembast/sembast_memory.dart';

import '../../support/fake_write_gateway.dart';
import '../../support/load_test_catalogue.dart';

const _docs = '/api/v1/modules/stock/documents';
const _t = '2026-11-05T10:00:00+05:00';

DocDraft _draft({String? id}) => DocDraft(
  id: id,
  kind: DocKind.receipt,
  eventTime: _t,
  header: const {'org_unit_id': 'o', 'location_id': 'l', 'responsible_id': 'r'},
  lines: const [DocLine(item: 'i1', uom: 'u1', quantity: '2')],
);

/// Plain-list queue for widget tests (sembast needs real timers).
class _MemQueue implements OfflineDraftQueue {
  final List<QueuedDraft> items = [];
  @override
  Future<EnqueueResult> enqueue(
    Map<String, dynamic> body, {
    String label = '',
    String summary = '',
  }) async {
    items.add(
      QueuedDraft(
        localId: '${items.length}',
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
  Future<void> remove(String localId) async =>
      items.removeWhere((e) => e.localId == localId);
  @override
  Future<void> markRejected(
    String localId,
    String code, {
    Map<String, dynamic>? detail,
  }) async {
    final i = items.indexWhere((e) => e.localId == localId);
    final e = items[i];
    items[i] = QueuedDraft(
      localId: e.localId,
      body: e.body,
      label: e.label,
      summary: e.summary,
      createdAtMs: e.createdAtMs,
      rejection: code,
      rejectionDetail: detail,
    );
  }

  @override
  Future<void> clearRejection(String localId) async {
    final i = items.indexWhere((e) => e.localId == localId);
    final e = items[i];
    items[i] = QueuedDraft(
      localId: e.localId,
      body: e.body,
      label: e.label,
      summary: e.summary,
      createdAtMs: e.createdAtMs,
    );
  }

  @override
  Future<void> closeAndClear() async => items.clear();
}

void main() {
  setUpAll(loadTestMessageCatalogue);
  late FakeWriteGateway gw;
  late SembastOfflineDraftQueue queue;

  setUp(() async {
    gw = FakeWriteGateway();
    queue = await SembastOfflineDraftQueue.open(
      'q.db',
      factory: newDatabaseFactoryMemory(),
    );
  });

  DocFormController controller(DocDraft d, {OfflineDraftQueue? q}) =>
      DocFormController(
        api: StockDocumentsApi(gw),
        pickers: PickerLoader(gw),
        draft: d,
        queue: q,
      );

  test('F1: offline Save of a new draft is queued, nothing thrown', () async {
    gw.on('POST', _docs, [const NetworkUnavailableError()]);
    final c = controller(_draft(), q: queue);
    await c.save();
    expect(c.queuedLocally, isTrue);
    expect(c.message, tr('offline.saved'));
    expect(c.failure, isNull);
    expect(await queue.count(), 1);
    expect((await queue.all()).single.body['kind'], 'receipt');
  });

  test('F2: without a queue the failure state is as before', () async {
    gw.on('POST', _docs, [const NetworkUnavailableError()]);
    final c = controller(_draft());
    await c.save();
    expect(c.queuedLocally, isFalse);
    expect(c.failure, isNotNull);
  });

  test('F3: an online Save does not enqueue', () async {
    gw.on('POST', _docs, [
      (Object? d) => {...(d as Map), 'id': 'd1', 'state': 'draft'},
    ]);
    final c = controller(_draft(), q: queue);
    await c.save();
    expect(c.queuedLocally, isFalse);
    expect(await queue.count(), 0);
  });

  test('F4: offline Save of an existing draft (PUT) is not queued', () async {
    gw.on('PUT', '$_docs/d1', [const NetworkUnavailableError()]);
    final c = controller(_draft(id: 'd1'), q: queue);
    await c.save();
    expect(c.queuedLocally, isFalse);
    expect(c.failure, isNotNull);
    expect(await queue.count(), 0);
  });

  test('F5: a full queue shows the full message', () async {
    for (var i = 0; i < kMaxQueuedDrafts; i++) {
      await queue.enqueue({'n': i});
    }
    gw.on('POST', _docs, [const NetworkUnavailableError()]);
    final c = controller(_draft(), q: queue);
    await c.save();
    expect(c.queuedLocally, isFalse);
    expect(c.message, tr('offline.full'));
    expect(await queue.count(), kMaxQueuedDrafts);
  });

  test(
    'F6: Issue of a new draft offline stops after the queued save',
    () async {
      gw.on('POST', _docs, [const NetworkUnavailableError()]);
      final c = controller(_draft(), q: queue);
      await c.issue();
      expect(c.queuedLocally, isTrue);
      expect(gw.callsTo('POST', '$_docs/null/issue'), isEmpty);
      expect(gw.calls.where((x) => x.path.endsWith('/issue')), isEmpty);
    },
  );

  group('list screen', () {
    late _MemQueue mem;
    setUp(() => mem = _MemQueue());
    Future<void> pump(WidgetTester tester, OfflineDraftQueue q) async {
      gw.on('GET', _docs, [
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
            offlineSyncProvider.overrideWithValue(
              OfflineSyncService(q, StockDocumentsApi(gw).createFromBody),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('L1: banner shows the count and Send now sends', (
      tester,
    ) async {
      await mem.enqueue({'kind': 'receipt'}, label: 'Receipt');
      gw.on('POST', _docs, [
        {'id': 'd9'},
      ]);
      await pump(tester, mem);
      expect(find.byKey(const Key('stock-doc-offline-waiting')), findsOne);
      expect(
        find.text(tr('offline.waiting').replaceAll('{count}', '1')),
        findsOne,
      );
      await tester.tap(find.byKey(const Key('stock-doc-offline-send')));
      await tester.pumpAndSettle();
      expect(gw.callsTo('POST', _docs), hasLength(1));
      expect(await mem.count(), 0);
      expect(find.byKey(const Key('stock-doc-offline-waiting')), findsNothing);
    });

    testWidgets('L2: a refused entry shows Discard, which removes it', (
      tester,
    ) async {
      await mem.enqueue({'kind': 'receipt'}, label: 'Receipt');
      await mem.markRejected((await mem.all()).single.localId, 'conflict');
      await pump(tester, mem);
      expect(find.text(tr('offline.discard')), findsOne);
      await tester.tap(find.text(tr('offline.discard')));
      await tester.pumpAndSettle();
      // W3: Discard asks first; the entry is removed only after the confirm.
      expect(await mem.count(), 1);
      await tester.tap(
        find.byKey(const Key('stock-doc-offline-discard-confirm')),
      );
      await tester.pumpAndSettle();
      expect(await mem.count(), 0);
    });

    testWidgets('no banner when the queue is empty (native)', (tester) async {
      await pump(tester, mem);
      expect(find.byKey(const Key('stock-doc-offline-banner')), findsNothing);
    });
  });
}
