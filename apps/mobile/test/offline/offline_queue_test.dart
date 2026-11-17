// T-1499 (PWA M3): the offline draft queue: limits, survives a reopen, clear.
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/client_key.dart';
import 'package:letflow/offline/offline_queue.dart';
import 'package:sembast/sembast_memory.dart';

Map<String, dynamic> _body(int n, {int pad = 0}) => {
  'kind': 'receipt',
  'n': n,
  'pad': 'x' * pad,
};

void main() {
  late DatabaseFactory factory;
  setUp(() => factory = newDatabaseFactoryMemory());

  test('Q1: an entry survives closing and reopening the same db', () async {
    var q = await SembastOfflineDraftQueue.open('q.db', factory: factory);
    expect(await q.enqueue(_body(1), label: 'Receipt'), EnqueueResult.stored);
    await q.closeOnly();

    q = await SembastOfflineDraftQueue.open('q.db', factory: factory);
    final all = await q.all();
    expect(all, hasLength(1));
    expect(all.single.body['n'], 1);
    expect(all.single.label, 'Receipt');
  });

  test('Q1b: detail and summary survive reopen; old record loads', () async {
    var q = await SembastOfflineDraftQueue.open('q.db', factory: factory);
    await q.enqueue(_body(1), label: 'R', summary: '1 lines: A x1');
    final id = (await q.all()).single.localId;
    await q.markRejected(
      id,
      'validation',
      detail: {'reason': 'field_required'},
    );
    await q.closeOnly();
    q = await SembastOfflineDraftQueue.open('q.db', factory: factory);
    final e = (await q.all()).single;
    expect(e.summary, '1 lines: A x1');
    expect(e.rejectionDetail, {'reason': 'field_required'});
    final old = QueuedDraft.fromJson({
      'local_id': 'x',
      'body': {'a': 1},
      'rejection': 'conflict',
    });
    expect(old.rejectionDetail, isNull);
    expect(old.summary, '');
  });

  test('Q2: the 21st entry is refused and nothing is stored', () async {
    final q = await SembastOfflineDraftQueue.open('q.db', factory: factory);
    for (var i = 0; i < kMaxQueuedDrafts; i++) {
      expect(await q.enqueue(_body(i)), EnqueueResult.stored);
    }
    expect(await q.enqueue(_body(99)), EnqueueResult.full);
    expect(await q.count(), kMaxQueuedDrafts);
  });

  test(
    'Q3: the total size limit refuses an entry that would exceed it',
    () async {
      final q = await SembastOfflineDraftQueue.open('q.db', factory: factory);
      var stored = 0;
      while (await q.enqueue(_body(stored, pad: 60 * 1024)) ==
          EnqueueResult.stored) {
        stored++;
      }
      expect(stored, lessThan(kMaxQueuedDrafts));
      expect(stored * 60 * 1024, lessThanOrEqualTo(kMaxQueuedBytes));
      expect(await q.count(), stored);
    },
  );

  test('Q4: a single entry over its limit is tooLarge', () async {
    final q = await SembastOfflineDraftQueue.open('q.db', factory: factory);
    expect(
      await q.enqueue(_body(1, pad: kMaxQueuedEntryBytes + 1)),
      EnqueueResult.tooLarge,
    );
    expect(await q.count(), 0);
  });

  test('Q5: closeAndClear empties the queue', () async {
    var q = await SembastOfflineDraftQueue.open('q.db', factory: factory);
    await q.enqueue(_body(1));
    await q.closeAndClear();
    q = await SembastOfflineDraftQueue.open('q.db', factory: factory);
    expect(await q.count(), 0);
  });

  test(
    'entries come back oldest first; markRejected keeps the entry',
    () async {
      final q = await SembastOfflineDraftQueue.open('q.db', factory: factory);
      await q.enqueue(_body(1));
      await q.enqueue(_body(2));
      final first = (await q.all()).first;
      expect(first.body['n'], 1);
      await q.markRejected(first.localId, 'validation');
      expect((await q.all()).first.rejection, 'validation');
      await q.remove(first.localId);
      expect(await q.count(), 1);
    },
  );

  test(
    'offlineQueueFileNameFor differs per realm and from the other caches',
    () {
      final a = offlineQueueFileNameFor('https://idp.example/realms/a');
      expect(a, startsWith('letflow_offline_'));
      expect(a, isNot(offlineQueueFileNameFor('https://idp.example/realms/b')));
    },
  );

  test('Q6: ActiveOfflineQueue clears the active realm queue', () async {
    String? realm = 'https://idp.example/realms/a';
    final active = ActiveOfflineQueue(
      realmUrl: () => realm,
      opener: (r) => SembastOfflineDraftQueue.open(
        offlineQueueFileNameFor(r),
        factory: factory,
      ),
    );
    expect(await active.enqueue(_body(1)), EnqueueResult.stored);
    expect(await active.count(), 1);
    await active.closeAndClear();
    realm = 'https://idp.example/realms/a';
    expect(await active.count(), 0);
    realm = null;
    expect(await active.count(), 0);
    expect(await active.enqueue(_body(2)), EnqueueResult.full);
  });

  test('Q7: a new entry has a UUID v4 client key', () async {
    final q = await SembastOfflineDraftQueue.open('q.db', factory: factory);
    await q.enqueue(_body(1));
    final e = (await q.all()).single;
    expect(e.clientKey, isNotNull);
    expect(
      e.clientKey,
      matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
    );
    expect(isClientKey(e.clientKey!), isTrue);
  });

  test('Q8: two entries have different keys', () async {
    final q = await SembastOfflineDraftQueue.open('q.db', factory: factory);
    await q.enqueue(_body(1));
    await q.enqueue(_body(2));
    final all = await q.all();
    expect(all[0].clientKey, isNot(all[1].clientKey));
  });

  test('Q9: the client key survives a reload', () async {
    var q = await SembastOfflineDraftQueue.open('q.db', factory: factory);
    await q.enqueue(_body(1));
    final key = (await q.all()).single.clientKey;
    await q.closeOnly();
    q = await SembastOfflineDraftQueue.open('q.db', factory: factory);
    expect((await q.all()).single.clientKey, key);
  });

  test('Q10: an entry without a key (old format) loads with null key', () {
    final old = QueuedDraft.fromJson({
      'local_id': 'x',
      'body': {'a': 1},
      'label': '',
      'created_at_ms': 0,
      // no 'client_key'
    });
    expect(old.clientKey, isNull);
  });

  test('Q11: setClientKey persists the key', () async {
    final q = await SembastOfflineDraftQueue.open('q.db', factory: factory);
    await q.enqueue(_body(1));
    final id = (await q.all()).single.localId;
    await q.setClientKey(id, 'test-key-value');
    expect((await q.all()).single.clientKey, 'test-key-value');
  });

  test('Q12: enqueueRaw stores an entry without a key (legacy simulation)', () async {
    final q = await SembastOfflineDraftQueue.open('q.db', factory: factory);
    await q.enqueueRaw(const QueuedDraft(
      localId: 'old-1',
      body: {'kind': 'receipt'},
      label: '',
      createdAtMs: 0,
    ));
    final e = (await q.all()).single;
    expect(e.localId, 'old-1');
    expect(e.clientKey, isNull);
    // After setClientKey the key is stored.
    await q.setClientKey('old-1', 'new-key');
    expect((await q.all()).single.clientKey, 'new-key');
  });
}
