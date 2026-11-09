// Install hint store: the "seen" flag (H4, H5).
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/offline/install_hint_store.dart';
import 'package:letflow/offline/offline_queue.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  test(
    'H5: the flag survives reopen and is not cleared with the queue',
    () async {
      final factory = newDatabaseFactoryMemory();
      final store = SembastInstallHintStore(
        () => factory.openDatabase('hint.db'),
      );
      expect(await store.seen(), isFalse);
      await store.markSeen();
      final queue = await SembastOfflineDraftQueue.open(
        'q.db',
        factory: factory,
      );
      await queue.closeAndClear();
      expect(
        await SembastInstallHintStore(
          () => factory.openDatabase('hint.db'),
        ).seen(),
        isTrue,
      );
    },
  );

  test('H4: a failing store counts as seen', () async {
    final store = SembastInstallHintStore(() async => throw StateError('x'));
    expect(await store.seen(), isTrue);
    await store.markSeen();
  });

  test('memory store', () async {
    final s = MemoryInstallHintStore();
    expect(await s.seen(), isFalse);
    await s.markSeen();
    expect(await s.seen(), isTrue);
  });
}
