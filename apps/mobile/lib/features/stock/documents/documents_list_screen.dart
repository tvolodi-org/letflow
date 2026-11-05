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
import 'documents_providers.dart';

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

  @override
  void initState() {
    super.initState();
    _api = StockDocumentsApi(ref.read(stockGatewayProvider));
    unawaited(_load());
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
    if (mounted) unawaited(_load());
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
