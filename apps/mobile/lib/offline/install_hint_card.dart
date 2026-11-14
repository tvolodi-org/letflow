/// The "Install on your phone" entry of the PWA home screen (owner finding
/// O-003, checklist item 19). It lives on the home screen, not inside a
/// document list. Until the user presses "I have read it" the how-to is open;
/// afterwards only a one-line entry stays, and pressing it opens the how-to
/// again. The "read" flag is the [InstallHintStore] (survives sign-out).
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/stock/documents/offline_providers.dart';
import '../i18n/i18n.dart';
import 'install_state.dart';

class InstallHintCard extends ConsumerStatefulWidget {
  const InstallHintCard({super.key});

  @override
  ConsumerState<InstallHintCard> createState() => _InstallHintCardState();
}

class _InstallHintCardState extends ConsumerState<InstallHintCard> {
  // True until the store answers, so the how-to never flashes for a user
  // who has already read it.
  bool _seen = true;
  bool _reopened = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final store = ref.read(installHintStoreProvider);
    if (store == null) return;
    final seen = await store.seen();
    if (mounted) setState(() => _seen = seen);
  }

  Future<void> _markRead() async {
    setState(() {
      _seen = true;
      _reopened = false;
    });
    await ref.read(installHintStoreProvider)?.markSeen();
  }

  @override
  Widget build(BuildContext context) {
    final isWeb = ref.read(offlineQueueEnabledProvider);
    final state = ref.read(installStateProvider);
    final platform = ref.read(installPlatformProvider);
    if (!isWeb || state != InstallState.browser) {
      return const SizedBox.shrink();
    }
    final open = !_seen || _reopened;
    if (!open) {
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          key: const Key('install-hint-open'),
          icon: const Icon(Icons.install_mobile),
          label: Text(tr('offline.install.title')),
          onPressed: () => setState(() => _reopened = true),
        ),
      );
    }
    final texts = <String>[
      if (platform != InstallPlatform.android) tr('offline.install.ios'),
      if (platform != InstallPlatform.ios) tr('offline.install.android'),
    ];
    return Card(
      key: const Key('install-hint-card'),
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('offline.install.title'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            for (final text in texts) ...[
              Text(text),
              const SizedBox(height: 8),
            ],
            TextButton(
              key: const Key('install-hint-dismiss'),
              onPressed: () => unawaited(_markRead()),
              child: Text(tr('offline.install.dismiss')),
            ),
          ],
        ),
      ),
    );
  }
}
