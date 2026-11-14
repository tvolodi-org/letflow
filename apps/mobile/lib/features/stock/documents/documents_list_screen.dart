/// Drafts of the caller's stock documents: kind filter, "Load more" on the
/// server cursor, a "New" button offering the six kinds.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../api/api_error.dart';
import '../../../i18n/i18n.dart';
import '../../../renderers/renderer_state.dart';
import '../../../renderers/renderer_state_view.dart';
import 'document_draft.dart';
import 'document_form_screen.dart';
import 'document_kinds.dart';
import 'document_refusals.dart';
import 'documents_api.dart';
import '../../../offline/install_state.dart';
import '../../../offline/offline_queue.dart';
import 'documents_providers.dart';
import 'offline_providers.dart';

class DocumentsListScreen extends ConsumerStatefulWidget {
  const DocumentsListScreen({super.key});

  @override
  ConsumerState<DocumentsListScreen> createState() => _DocumentsListState();
}

class _DocumentsListState extends ConsumerState<DocumentsListScreen> {
  late final StockDocumentsApi _api;
  RendererState<List<DocSummary>> _state = const RendererLoading();
  String? _next;
  DocKind? _kind;
  String? _notFound;
  List<QueuedDraft> _queued = const [];
  String? _syncNote;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _api = StockDocumentsApi(ref.read(stockGatewayProvider));
    unawaited(_load());
    unawaited(_loadQueue());
  }

  Future<void> _loadQueue() async {
    final queue = ref.read(offlineQueueProvider);
    if (queue == null) return;
    try {
      final list = await queue.all();
      if (mounted) setState(() => _queued = list);
    } on Object {
      // An unreadable queue shows no banner; the list itself still works.
    }
  }

  Future<void> _sendNow() async {
    final sync = ref.read(offlineSyncProvider);
    if (sync == null || _syncing) return;
    setState(() => _syncing = true);
    final report = await sync.drain();
    if (!mounted) return;
    setState(() {
      _syncing = false;
      _syncNote = tr('offline.sent')
          .replaceAll('{sent}', '${report.sent}')
          .replaceAll('{rejected}', '${report.rejected}')
          .replaceAll('{remaining}', '${report.remaining}');
    });
    await _loadQueue();
    if (mounted) unawaited(_load());
  }

  Future<void> _retryQueued(QueuedDraft entry) async {
    await ref.read(offlineQueueProvider)?.clearRejection(entry.localId);
    await _loadQueue();
    await _sendNow();
  }

  Future<void> _editQueued(QueuedDraft entry) async {
    await context.push('$kStockDocumentsPath/queued/${entry.localId}');
    if (mounted) {
      unawaited(_load());
      unawaited(_loadQueue());
    }
  }

  Future<void> _confirmDiscard(QueuedDraft entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(tr('offline.conflict.discardConfirm')),
        actions: [
          TextButton(
            key: const Key('stock-doc-offline-discard-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(tr('stock.doc.cancel')),
          ),
          TextButton(
            key: const Key('stock-doc-offline-discard-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(tr('offline.discard')),
          ),
        ],
      ),
    );
    if (ok == true) await _discardQueued(entry);
  }

  Widget _rejectedCard(QueuedDraft e) {
    final detail = e.rejectionDetail;
    final server = detail != null
        ? refusalMessageFromDetail(detail)
        : tr('offline.rejected').replaceAll('{reason}', e.rejection!);
    final when = DateTime.fromMillisecondsSinceEpoch(e.createdAtMs);
    return Card(
      key: Key('stock-doc-offline-rejected-${e.localId}'),
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('offline.conflict.title'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text('${e.label} ($when)'),
            if (e.summary.isNotEmpty) Text(e.summary),
            const SizedBox(height: 8),
            Text(
              tr('offline.conflict.server'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(server),
            const SizedBox(height: 8),
            Text(tr('offline.conflict.keepNote')),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  key: Key('stock-doc-offline-rejected-${e.localId}-edit'),
                  onPressed: () => unawaited(_editQueued(e)),
                  child: Text(tr('offline.conflict.edit')),
                ),
                TextButton(
                  key: Key('stock-doc-offline-rejected-${e.localId}-retry'),
                  onPressed: () => unawaited(_retryQueued(e)),
                  child: Text(tr('offline.conflict.retry')),
                ),
                TextButton(
                  key: Key('stock-doc-offline-rejected-${e.localId}-discard'),
                  onPressed: () => unawaited(_confirmDiscard(e)),
                  child: Text(tr('offline.discard')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _discardQueued(QueuedDraft entry) async {
    await ref.read(offlineQueueProvider)?.remove(entry.localId);
    await _loadQueue();
  }

  Widget _offlineBanner() {
    final waiting = _queued.where((e) => e.rejection == null).length;
    final isWeb = ref.read(offlineQueueEnabledProvider);
    final installState = ref.read(installStateProvider);
    final warn = shouldWarnStorage(installState, isWeb: isWeb);
    if (_queued.isEmpty && !warn) return const SizedBox.shrink();
    return Column(
      key: const Key('stock-doc-offline-banner'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (waiting > 0)
          ListTile(
            key: const Key('stock-doc-offline-waiting'),
            title: Text(
              tr('offline.waiting').replaceAll('{count}', '$waiting'),
            ),
            subtitle: _syncNote == null ? null : Text(_syncNote!),
            trailing: TextButton(
              key: const Key('stock-doc-offline-send'),
              onPressed: _syncing ? null : () => unawaited(_sendNow()),
              child: Text(tr('offline.sendNow')),
            ),
          ),
        for (final e in _queued.where((e) => e.rejection != null))
          _rejectedCard(e),
        if (warn)
          Padding(
            key: const Key('stock-doc-storage-warning'),
            padding: const EdgeInsets.all(12),
            child: Text(tr('offline.storageWarning')),
          ),
      ],
    );
  }

  List<DocSummary> get _rows {
    final s = _state;
    return s is RendererContent<List<DocSummary>> ? s.data : const [];
  }

  Future<void> _load({bool more = false}) async {
    final keep = more ? _rows : const <DocSummary>[];
    if (!more) {
      setState(() {
        _state = const RendererLoading();
        _notFound = null;
      });
    }
    try {
      final page = await _api.list(kind: _kind, cursor: more ? _next : null);
      if (!mounted) return;
      setState(() {
        _next = page.nextCursor;
        _state = RendererContent(data: [...keep, ...page.rows]);
      });
    } on ApiError catch (error) {
      if (!mounted) return;
      final text = refusalMessage(error);
      setState(() {
        _notFound = text;
        _state = text != null
            ? const RendererFetchFailure()
            : rendererStateForError<List<DocSummary>>(error);
      });
    } on MalformedDocumentAnswer {
      if (!mounted) return;
      setState(() => _state = const RendererFetchFailure());
    }
  }

  Future<void> _new() async {
    final kind = await showModalBottomSheet<DocKind>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final k in DocKind.values)
              ListTile(
                key: Key('stock-doc-new-${k.wire}'),
                title: Text(tr(kindTitleKey(k))),
                onTap: () => Navigator.of(ctx).pop(k),
              ),
          ],
        ),
      ),
    );
    if (kind == null || !mounted) return;
    await context.push('$kStockDocumentsPath/new/${kind.wire}');
    if (mounted) {
      unawaited(_load());
      unawaited(_loadQueue());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('stock-doc-list-screen'),
      appBar: AppBar(title: Text(tr('stock.doc.list.title'))),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('stock-doc-new'),
        onPressed: () => unawaited(_new()),
        label: Text(tr('stock.doc.list.new')),
        icon: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                ChoiceChip(
                  key: const Key('stock-doc-filter-all'),
                  label: Text(tr('stock.doc.list.all')),
                  selected: _kind == null,
                  onSelected: (_) {
                    _kind = null;
                    unawaited(_load());
                  },
                ),
                for (final k in DocKind.values)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: ChoiceChip(
                      key: Key('stock-doc-filter-${k.wire}'),
                      label: Text(tr(kindTitleKey(k))),
                      selected: _kind == k,
                      onSelected: (_) {
                        _kind = k;
                        unawaited(_load());
                      },
                    ),
                  ),
              ],
            ),
          ),
          Expanded(child: _content()),
        ],
      ),
    );
  }

  Widget _content() {
    if (_notFound != null) {
      return Center(
        key: const Key('stock-doc-list-error'),
        child: Text(_notFound!),
      );
    }
    return Column(
      children: [
        _offlineBanner(),
        Expanded(
          child: RendererStateView<List<DocSummary>>(
            state: _state,
            onRetryBackpressure: _load,
            contentBuilder: (context, rows) {
              if (rows.isEmpty) {
                return Center(
                  key: const Key('stock-doc-list-empty'),
                  child: Text(tr('stock.doc.list.empty')),
                );
              }
              return ListView(
                children: [
                  for (final r in rows)
                    ListTile(
                      key: Key('stock-doc-row-${r.id}'),
                      title: Text(_title(r)),
                      subtitle: r.eventTime == null ? null : Text(r.eventTime!),
                      onTap: () async {
                        await context.push('$kStockDocumentsPath/${r.id}');
                        if (mounted) unawaited(_load());
                      },
                    ),
                  if (_next != null)
                    TextButton(
                      key: const Key('stock-doc-load-more'),
                      onPressed: () => unawaited(_load(more: true)),
                      child: Text(tr('stock.doc.list.more')),
                    ),
                ],
              );
            },
          ),
        ),
        if (_state is RendererFetchFailure<List<DocSummary>>)
          TextButton(
            key: const Key('stock-doc-list-retry'),
            onPressed: () => unawaited(_load()),
            child: Text(tr('stock.doc.retry')),
          ),
      ],
    );
  }

  String _title(DocSummary r) {
    final kind = DocKind.fromWire(r.kind);
    final name = kind == null ? r.kind : tr(kindTitleKey(kind));
    return r.number == null ? name : '$name ${r.number}';
  }
}
