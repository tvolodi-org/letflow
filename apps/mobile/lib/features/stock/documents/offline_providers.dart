import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../bootstrap/navigation_bootstrap.dart'
    show activeRealmHolderProvider;
import '../../../offline/offline_queue.dart';
import '../../../offline/offline_sync.dart';
import 'documents_api.dart';
import 'documents_providers.dart';

export '../../../offline/install_hint_providers.dart';

/// The offline draft queue is a web/PWA feature (D-112); Android and iOS keep
/// today's behaviour.
final Provider<bool> offlineQueueEnabledProvider = Provider<bool>(
  (_) => kIsWeb,
);

/// The queue of the active tenant, or null when the feature is off. Tests
/// override it with an in-memory fake.
final Provider<OfflineDraftQueue?> offlineQueueProvider =
    Provider<OfflineDraftQueue?>((ref) {
      if (!ref.watch(offlineQueueEnabledProvider)) return null;
      final realm = ref.watch(activeRealmHolderProvider);
      return ActiveOfflineQueue(realmUrl: () => realm.currentRealmUrl);
    });

final Provider<OfflineSyncService?> offlineSyncProvider =
    Provider<OfflineSyncService?>((ref) {
      final queue = ref.watch(offlineQueueProvider);
      if (queue == null) return null;
      final api = StockDocumentsApi(ref.watch(stockGatewayProvider));
      return OfflineSyncService(queue, api.createFromBody);
    });
