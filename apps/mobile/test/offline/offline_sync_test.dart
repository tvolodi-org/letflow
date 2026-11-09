// T-1499 (PWA M3): draining the queue.
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_error.dart';
import 'package:letflow/offline/offline_queue.dart';
import 'package:letflow/offline/offline_sync.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  late SembastOfflineDraftQueue queue;
  late List<int> sent;
  setUp(() async {
    queue = await SembastOfflineDraftQueue.open(
      'q.db',
      factory: newDatabaseFactoryMemory(),
    );
    sent = [];
    for (var i = 1; i <= 3; i++) {
      await queue.enqueue({'n': i});
    }
  });

  OfflineSyncService service(Object? Function(int n) behaviour) =>
      OfflineSyncService(queue, (body) async {
        final n = body['n'] as int;
        sent.add(n);
        final r = behaviour(n);
        if (r is Exception) throw r;
      });

  test('S1: sends oldest first and removes what was sent', () async {
    final report = await service((_) => null).drain();
    expect(sent, [1, 2, 3]);
    expect(report.sent, 3);
    expect(report.remaining, 0);
    expect(await queue.count(), 0);
  });

  test('S2: a network failure stops the pass and keeps every entry', () async {
    final report = await service(
      (n) => n == 2 ? const NetworkUnavailableError() : null,
    ).drain();
    expect(sent, [1, 2]);
    expect(report.sent, 1);
    expect(report.remaining, 2);
    expect(await queue.count(), 2);
  });

  test('S3: a refusal marks the entry rejected and goes on', () async {
    final report = await service(
      (n) => n == 1 ? const ConflictError() : null,
    ).drain();
    expect(sent, [1, 2, 3]);
    expect(report.rejected, 1);
    final left = await queue.all();
    expect(left, hasLength(1));
    expect(left.single.rejection, 'conflict');
    // A rejected entry is not sent again.
    sent.clear();
    await service((_) => null).drain();
    expect(sent, isEmpty);
  });

  test('S4: an unauthorized answer stops the pass', () async {
    final report = await service((_) => const UnauthorizedError()).drain();
    expect(sent, [1]);
    expect(report.remaining, 3);
  });

  test('S4b: a server error stops the pass and keeps the entry', () async {
    final report = await service((_) => const ServerError()).drain();
    expect(sent, [1]);
    expect(report.rejected, 0);
    expect(report.remaining, 3);
  });

  test('S5: a second drain while one runs sends each entry once', () async {
    final s = service((_) => null);
    final a = s.drain();
    final b = s.drain();
    await Future.wait([a, b]);
    expect(sent, [1, 2, 3]);
  });
}
