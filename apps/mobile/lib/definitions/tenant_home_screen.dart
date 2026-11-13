/// `TenantHomeScreen` (design §8) — the definitions module's own
/// entry-point screen: lists the active tenant's cached definitions (type,
/// name/id, version), read from an already-resolved [DefinitionCacheEntry]
/// list. No definition renderer exists yet (REQ-426..428 build them); this
/// screen only lists identity, never a definition's rendered content.
///
/// Kept in its own file, separate from `definitions.dart` (design §1 item
/// 5), because it is UI (widgets + provider wiring), not storage/sync
/// logic.
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:go_router/go_router.dart';

import '../bootstrap/navigation_bootstrap.dart'
    show
        apiClientProvider,
        installedModulesProvider,
        isModuleInstalled,
        kCodesScanRoutePath,
        kStockHomeRoutePath;
import '../i18n/i18n.dart';
import '../bootstrap/language_switcher.dart';
import 'definitions.dart';

// ── §8.2 `DefinitionHomeController` ────────────────────────────────────────

/// Drives [TenantHomeScreen]'s content. `entries` is always already-resolved
/// data — never fetched inside a widget `build`/`initState` — so the screen
/// itself never needs a `FutureBuilder` (design §8.1: a `FutureBuilder`
/// inherently renders a `ConnectionState.waiting` frame, which would fail
/// the airplane-mode "no loading indicator at any frame" acceptance
/// criterion regardless of how briefly it is visible).
class DefinitionHomeController extends ChangeNotifier {
  DefinitionHomeController({
    required this.repository,
    required this.syncService,
  });

  final DefinitionCacheRepository repository;
  final DefinitionSyncService syncService;

  List<DefinitionCacheEntry> entries = const [];

  /// Loads [entries] from the cache, sorted by `(name, version)` ascending
  /// for a stable on-screen order (the repository interface's own ordering
  /// is unspecified). Must be awaited and completed **before**
  /// [TenantHomeScreen] is constructed/pushed.
  Future<void> loadFromCache() async {
    final loaded = await repository.listAvailable();
    loaded.sort((a, b) {
      final byName = a.name.compareTo(b.name);
      if (byName != 0) return byName;
      return a.version.compareTo(b.version);
    });
    entries = loaded;
    notifyListeners();
  }

  /// Runs [syncService.syncOnce] then reloads from cache — fire-and-forget
  /// from [TenantHomeScreen]'s post-first-frame hook, which is what makes
  /// this "background" (design §8.2). [syncOnce] never throws by its own
  /// contract, so the guard here is stated explicitly rather than assumed.
  Future<void> refreshInBackground() async {
    try {
      await syncService.syncOnce();
    } catch (_) {
      return;
    }
    await loadFromCache();
  }
}

// ── §8.3 The screen widget ─────────────────────────────────────────────────

class TenantHomeScreen extends ConsumerStatefulWidget {
  const TenantHomeScreen({super.key});

  @override
  ConsumerState<TenantHomeScreen> createState() => _TenantHomeScreenState();
}

class _TenantHomeScreenState extends ConsumerState<TenantHomeScreen> {
  bool _scheduledRefresh = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_scheduledRefresh) return;
    _scheduledRefresh = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Fire-and-forget — not awaited, no `setState`/spinner gating its
      // start (design §8.3).
      unawaited(
        ref.read(definitionHomeControllerProvider).refreshInBackground(),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(definitionHomeControllerProvider);
    final entries = controller.entries;
    final codesInstalled = isModuleInstalled(
      ref.watch(installedModulesProvider),
      'codes',
    );

    final stockInstalled = isModuleInstalled(
      ref.watch(installedModulesProvider),
      'stock',
    );

    return Scaffold(
      key: const Key('tenant-home-screen'),
      appBar: AppBar(
        title: Text(tr('home.appBarTitle')),
        actions: const [LanguageSwitcher(), SizedBox(width: 8)],
      ),
      // Deliberately no `CircularProgressIndicator`/`LinearProgressIndicator`
      // or any other loading-indicator widget anywhere in this build
      // method — not gated behind a flag, simply never constructed
      // (design §8.3).
      body: Column(
        children: [
          if (codesInstalled)
            ListTile(
              key: const Key('tenant-home-codes-entry'),
              leading: const Icon(Icons.qr_code_scanner),
              title: Text(tr('home.codes.scan')),
              onTap: () => context.go(kCodesScanRoutePath),
            ),
          if (stockInstalled)
            ListTile(
              key: const Key('tenant-home-stock-entry'),
              leading: const Icon(Icons.inventory_2_outlined),
              title: Text(tr('home.stock.entry')),
              onTap: () => context.go(kStockHomeRoutePath),
            ),
          Expanded(
            child: entries.isEmpty
                ? Center(
                    key: const Key('tenant-home-empty'),
                    child: Text(tr('home.emptyMessage')),
                  )
                : ListView.builder(
                    key: const Key('tenant-home-list'),
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final displayName = entry.name.isEmpty
                          ? entry.id
                          : entry.name;
                      return ListTile(
                        key: Key('tenant-home-entry-${entry.compositeKey}'),
                        title: Text(displayName),
                        subtitle: Text('${entry.type} · v${entry.version}'),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ── §8.4 Providers ──────────────────────────────────────────────────────────

final definitionCacheHolderProvider = Provider<ActiveDefinitionCacheHolder>((
  ref,
) {
  return ActiveDefinitionCacheHolder();
});

final definitionSyncServiceProvider = Provider<DefinitionSyncService>((ref) {
  final repo = ref.watch(definitionCacheHolderProvider).current;
  if (repo == null) {
    throw StateError(
      'definitionSyncServiceProvider read before ActiveDefinitionCacheHolder'
      '.openFor has run — this is a wiring bug, not a case this provider '
      'silently falls back for.',
    );
  }
  return DefinitionSyncService(
    repository: repo,
    client: ref.watch(apiClientProvider),
  );
});

final definitionHomeControllerProvider =
    ChangeNotifierProvider<DefinitionHomeController>((ref) {
      final repo = ref.watch(definitionCacheHolderProvider).current;
      if (repo == null) {
        throw StateError(
          'definitionHomeControllerProvider read before '
          'ActiveDefinitionCacheHolder.openFor has run.',
        );
      }
      return DefinitionHomeController(
        repository: repo,
        syncService: ref.watch(definitionSyncServiceProvider),
      );
    });
