/// One count on the phone: camera preview with a typed fallback, place,
/// lines and entries, quantity dialog and the surplus line sheet
/// (phone-flows.md sections 2 and 3). State lives in this screen only.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/i18n.dart';
import '../../renderers/renderer_state.dart';
import '../../renderers/renderer_state_view.dart';
import '../codes/codes.dart';
import 'count_api.dart';
import 'count_detail_controller.dart';
import 'count_models.dart';
import 'count_refusal.dart';
import 'stock_providers.dart';
import 'surplus_line_sheet.dart';

class CountDetailScreen extends ConsumerStatefulWidget {
  const CountDetailScreen({super.key, required this.countId});

  final String countId;

  @override
  ConsumerState<CountDetailScreen> createState() => _CountDetailScreenState();
}

class _CountDetailScreenState extends ConsumerState<CountDetailScreen> {
  late final ScanSource _source;
  late final CountDetailController _c;
  final TextEditingController _typed = TextEditingController();
  bool _showEntries = false;

  @override
  void initState() {
    super.initState();
    _source = ref.read(scanSourceProvider);
    final gateway = ref.read(stockGatewayProvider);
    _c = CountDetailController(
      id: widget.countId,
      api: StockCountApi(gateway),
      resolver: CodesResolver(gateway),
      source: _source,
    )..addListener(_onChange);
    unawaited(_start());
  }

  Future<void> _start() async {
    await _c.load();
    await _c.startScanning();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _c
      ..removeListener(_onChange)
      ..dispose();
    unawaited(_source.stop());
    _source.dispose();
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      key: const Key('stock-count-screen'),
      appBar: AppBar(title: Text(tr('stock.counts.title'))),
      body: RendererStateView<CountOrder>(
        state: c.order,
        onRetryBackpressure: c.load,
        contentBuilder: (context, order) => _body(context, order),
      ),
    );
  }

  Widget _body(BuildContext context, CountOrder order) {
    final c = _c;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          key: const Key('stock-count-status'),
          '${order.number ?? order.id} · ${order.status}',
        ),
        Row(
          children: [
            if (order.status == 'ordered')
              FilledButton(
                key: const Key('stock-count-open'),
                onPressed: c.busy ? null : () => unawaited(c.open()),
                child: Text(tr('stock.count.open')),
              ),
            if (order.status == 'counting')
              FilledButton(
                key: const Key('stock-count-close'),
                onPressed: c.busy ? null : () => unawaited(c.close()),
                child: Text(tr('stock.count.close')),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          key: const Key('stock-count-place'),
          c.placeId == null
              ? tr('stock.count.place.none')
              : '${tr('stock.count.place')}: ${c.placeId}',
        ),
        if (c.placeId != null)
          TextButton(
            key: const Key('stock-count-place-clear'),
            onPressed: c.clearPlace,
            child: Text(tr('stock.count.place.set')),
          ),
        if (c.cameraRefused)
          Text(
            key: const Key('stock-camera-refused'),
            tr('codes.cameraRefused'),
          )
        else if (c.scanning)
          SizedBox(height: 200, child: _source.buildPreview()),
        TextField(
          key: const Key('stock-typed'),
          controller: _typed,
          decoration: InputDecoration(hintText: tr('stock.scan.typed.hint')),
        ),
        FilledButton(
          key: const Key('stock-send'),
          onPressed: () => unawaited(c.submitScan(_typed.text)),
          child: Text(tr('stock.scan.send')),
        ),
        if (!c.scanning && !c.cameraRefused)
          TextButton(
            key: const Key('stock-scan-again'),
            onPressed: () => unawaited(c.scanAgain()),
            child: Text(tr('codes.scanAgain')),
          ),
        ..._messages(context),
        const SizedBox(height: 8),
        Row(
          children: [
            ChoiceChip(
              key: const Key('stock-tab-lines'),
              label: Text(tr('stock.count.lines')),
              selected: !_showEntries,
              onSelected: (_) => setState(() => _showEntries = false),
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              key: const Key('stock-tab-entries'),
              label: Text(tr('stock.count.entries')),
              selected: _showEntries,
              onSelected: (_) {
                setState(() => _showEntries = true);
                unawaited(c.loadEntries());
              },
            ),
          ],
        ),
        if (_showEntries) ..._entries() else ..._lines(context),
      ],
    );
  }

  List<Widget> _messages(BuildContext context) {
    final c = _c;
    final refusal = c.refusal;
    final failure = c.failure;
    return [
      if (refusal != null)
        Text(key: const Key('stock-refusal'), tr(refusal.messageKey)),
      if (refusal == CountRefusal.scanNoLine)
        TextButton(
          key: const Key('stock-surplus-open'),
          onPressed: () => unawaited(_openSurplus(context)),
          child: Text(tr('stock.surplus.title')),
        ),
      if (refusal == CountRefusal.scanAmbiguous)
        TextButton(
          key: const Key('stock-type-quantity'),
          onPressed: () => setState(() => _showEntries = false),
          child: Text(tr('stock.qty.title')),
        ),
      if (c.noticeKey != null)
        Text(key: const Key('stock-notice'), tr(c.noticeKey!)),
      if (c.lastDuplicate)
        Text(key: const Key('stock-duplicate'), tr('stock.scan.duplicate')),
      if (failure != null && failure is! RendererContent<Object?>)
        SizedBox(
          height: 80,
          child: RendererStateView<Object?>(
            state: failure,
            onRetryBackpressure: c.retry,
            contentBuilder: (context, _) => const SizedBox.shrink(),
          ),
        ),
      if (failure is RendererFetchFailure<Object?>)
        TextButton(
          key: const Key('stock-retry'),
          onPressed: () => unawaited(c.retry()),
          child: Text(tr('stock.scan.retry')),
        ),
    ];
  }

  List<Widget> _lines(BuildContext context) => [
    for (final l in _c.lines)
      ListTile(
        key: Key('stock-line-${l.lineNo}'),
        title: Text(
          '${l.lineNo} · ${l.catalogItemId}'
          '${l.catalogLotId == null ? '' : ' · ${l.catalogLotId}'}',
        ),
        subtitle: Text(
          '${l.unitRef} · ${l.bookQuantity ?? '-'} / '
          '${l.countedQuantity ?? '-'}',
        ),
        onTap: () => unawaited(_askQuantity(context, l)),
      ),
    if (_c.linesCursor != null)
      TextButton(
        key: const Key('stock-lines-more'),
        onPressed: () => unawaited(_c.loadMoreLines()),
        child: Text(tr('stock.counts.more')),
      ),
  ];

  List<Widget> _entries() => [
    for (final e in _c.entries)
      ListTile(
        key: Key('stock-entry-${e.entryNo}'),
        title: Text('${e.entryNo} · ${e.lineNo} · ${e.method ?? ''}'),
        subtitle: Text(
          '${e.quantityBefore ?? '-'} → ${e.quantityAfter ?? '-'}',
        ),
      ),
    if (_c.entriesCursor != null)
      TextButton(
        key: const Key('stock-entries-more'),
        onPressed: () => unawaited(_c.loadEntries(more: true)),
        child: Text(tr('stock.counts.more')),
      ),
  ];

  Future<void> _askQuantity(BuildContext context, CountLine line) async {
    final controller = TextEditingController(text: line.countedQuantity ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) {
          final valid = isQuantityText(controller.text);
          return AlertDialog(
            title: Text(tr('stock.qty.title')),
            content: TextField(
              key: const Key('stock-qty-field'),
              controller: controller,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => setLocal(() {}),
              decoration: InputDecoration(
                errorText: controller.text.isEmpty || valid
                    ? null
                    : tr('stock.qty.invalid'),
              ),
            ),
            actions: [
              TextButton(
                key: const Key('stock-qty-save'),
                onPressed: valid
                    ? () => Navigator.of(context).pop(controller.text)
                    : null,
                child: Text(tr('stock.qty.save')),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
    if (value != null) await _c.setCount(line.lineNo, value);
  }

  Future<void> _openSurplus(BuildContext context) async {
    final draft = await _c.prepareSurplus();
    if (!context.mounted) return;
    final result = await showDialog<SurplusResult>(
      context: context,
      builder: (context) => SurplusLineSheet(draft: draft),
    );
    if (result == null) return;
    await _c.addSurplus(
      locationId: result.locationId,
      catalogItemId: result.catalogItemId,
      unitRef: result.unitRef,
      quantity: result.quantity,
      catalogLotId: result.catalogLotId,
    );
  }
}
