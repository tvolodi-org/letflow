/// The draft form of one stock document: new (`kind` given) or loaded (`id`
/// given). One data-driven form for the six kinds; state lives in the screen
/// instance only, nothing is written to the device.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../api/api_error.dart';
import '../../../i18n/i18n.dart';
import '../../../renderers/renderer_state.dart';
import '../../../renderers/renderer_state_view.dart';
import '../../codes/codes_resolve.dart';
import 'document_draft.dart';
import 'document_form_controller.dart';
import 'document_kinds.dart';
import 'document_pickers.dart';
import 'documents_api.dart';
import 'documents_providers.dart';
import 'picker_sheet.dart';
import 'scan_fill_sheet.dart';

const String kStockDocumentsPath = '/stock/documents';

String kindTitleKey(DocKind kind) => 'stock.doc.kind.${kind.wire}';

class DocumentFormScreen extends ConsumerStatefulWidget {
  const DocumentFormScreen({super.key, this.kind, this.id});

  final DocKind? kind;
  final String? id;

  @override
  ConsumerState<DocumentFormScreen> createState() => _DocumentFormScreenState();
}

class _DocumentFormScreenState extends ConsumerState<DocumentFormScreen> {
  DocFormController? _controller;
  RendererState<DocDraft> _load = const RendererLoading();
  bool _notFound = false;
  late final StockDocumentsApi _api;
  late final PickerLoader _pickers;

  @override
  void initState() {
    super.initState();
    final gateway = ref.read(stockGatewayProvider);
    _api = StockDocumentsApi(gateway);
    _pickers = PickerLoader(gateway);
    final kind = widget.kind;
    if (kind != null) {
      _attach(DocDraft(kind: kind, eventTime: isoWithOffset(DateTime.now())));
    } else if (widget.id != null) {
      unawaited(_fetch());
    } else {
      _notFound = true;
    }
  }

  void _attach(DocDraft draft) {
    _controller = DocFormController(api: _api, pickers: _pickers, draft: draft)
      ..addListener(_onChange);
  }

  Future<void> _fetch() async {
    setState(() => _load = const RendererLoading());
    try {
      final draft = await _api.fetch(widget.id!);
      if (!mounted) return;
      setState(() {
        _attach(draft);
        _load = RendererContent(data: draft);
      });
    } on NotFoundError {
      _fail(notFound: true);
    } on ModuleNotAvailableError {
      _fail(notFound: true);
    } on ApiError catch (error) {
      _fail(state: rendererStateForError<DocDraft>(error));
    } on MalformedDocumentAnswer {
      _fail(state: const RendererFetchFailure());
    }
  }

  void _fail({bool notFound = false, RendererState<DocDraft>? state}) {
    if (!mounted) return;
    setState(() {
      _notFound = notFound;
      if (state != null) _load = state;
    });
  }

  void _onChange() {
    final c = _controller;
    if (!mounted || c == null) return;
    if (c.discarded) {
      context.go(kStockDocumentsPath);
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _controller
      ?..removeListener(_onChange)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final title = c != null
        ? tr(kindTitleKey(c.draft.kind))
        : tr('stock.doc.list.title');
    return Scaffold(
      key: const Key('stock-doc-form-screen'),
      appBar: AppBar(title: Text(title)),
      body: _body(c),
    );
  }

  Widget _body(DocFormController? c) {
    if (_notFound) {
      return Center(
        key: const Key('stock-doc-not-found'),
        child: Text(tr('stock.doc.error.notFound')),
      );
    }
    if (c == null) {
      return Column(
        children: [
          Expanded(
            child: RendererStateView<DocDraft>(
              state: _load,
              contentBuilder: (_, _) => const SizedBox.shrink(),
              onRetryBackpressure: _fetch,
            ),
          ),
          if (_load is! RendererLoading<DocDraft>)
            TextButton(
              key: const Key('stock-doc-load-retry'),
              onPressed: () => unawaited(_fetch()),
              child: Text(tr('stock.doc.retry')),
            ),
        ],
      );
    }
    return _FormBody(controller: c);
  }
}

class _FormBody extends ConsumerWidget {
  const _FormBody({required this.controller});

  final DocFormController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = controller;
    final d = c.draft;
    final spec = d.spec;
    final enabled = c.editable && !c.busy;
    final problems = d.problems();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (!c.editable)
          Text(
            key: const Key('stock-doc-readonly'),
            '${tr('stock.doc.readonly')} ${d.number ?? ''}'.trim(),
          ),
        if (c.message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(key: const Key('stock-doc-error'), c.message!),
          ),
        if (c.failure != null)
          RendererStateView<DocDraft>(
            state: c.failure!,
            contentBuilder: (_, _) => const SizedBox.shrink(),
            onRetryBackpressure: c.retry,
          ),
        if (c.failure is RendererFetchFailure<DocDraft>)
          TextButton(
            key: const Key('stock-doc-retry'),
            onPressed: () => unawaited(c.retry()),
            child: Text(tr('stock.doc.retry')),
          ),
        if (spec.isTwoSide) ...[
          for (final side in [Side.from, Side.to]) ...[
            Text(
              tr('stock.doc.side.${side.name}'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            for (final f in spec.sideFields(side))
              _field(context, ref, f, enabled),
          ],
          for (final f in spec.sideFields(Side.single))
            _field(context, ref, f, enabled),
          if (problems.contains('sides'))
            Text(
              key: const Key('stock-doc-sides-equal'),
              tr(
                'stock.doc.error.sides_equal',
              ).replaceAll('{field}', '').replaceAll('{side}', ''),
            ),
        ] else
          for (final f in spec.fields) _field(context, ref, f, enabled),
        const Divider(),
        Text(
          tr('stock.doc.lines'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        for (var i = 0; i < d.lines.length; i++)
          _LineEditor(
            key: ValueKey('stock-doc-line-$i-${d.lines.length}'),
            index: i,
            controller: c,
            enabled: enabled,
          ),
        if (c.editable)
          TextButton(
            key: const Key('stock-doc-add-line'),
            onPressed: enabled ? c.addLine : null,
            child: Text(tr('stock.doc.addLine')),
          ),
        const SizedBox(height: 16),
        if (c.editable) ...[
          FilledButton(
            key: const Key('stock-doc-save'),
            onPressed: enabled && problems.isEmpty
                ? () => unawaited(c.save())
                : null,
            child: Text(tr('stock.doc.save')),
          ),
          const SizedBox(height: 8),
          FilledButton.tonal(
            key: const Key('stock-doc-issue'),
            onPressed: enabled && problems.isEmpty
                ? () => unawaited(c.issue())
                : null,
            child: Text(tr('stock.doc.issue')),
          ),
          const SizedBox(height: 8),
          if (d.id != null)
            OutlinedButton(
              key: const Key('stock-doc-discard'),
              onPressed: enabled
                  ? () => unawaited(_confirmDiscard(context))
                  : null,
              child: Text(tr('stock.doc.discard')),
            ),
        ],
      ],
    );
  }

  Future<void> _confirmDiscard(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(tr('stock.doc.discard.confirm')),
        actions: [
          TextButton(
            key: const Key('stock-doc-discard-no'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(tr('stock.doc.cancel')),
          ),
          FilledButton(
            key: const Key('stock-doc-discard-yes'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(tr('stock.doc.discard')),
          ),
        ],
      ),
    );
    if (yes == true) unawaited(controller.discard());
  }

  Widget _field(
    BuildContext context,
    WidgetRef ref,
    HeaderField f,
    bool enabled,
  ) {
    final c = controller;
    final label = tr('stock.doc.field.${f.key}');
    final required = c.draft.spec.requiredKeys.contains(f.key);
    final labelText = required ? '$label *' : label;
    switch (f.input) {
      case FieldInput.pick:
        final value = c.draft.value(f.key);
        final canEdit = enabled && !c.isLocked(f.key);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  key: Key('stock-doc-field-${f.key}'),
                  onTap: canEdit
                      ? () async {
                          final o = await showEntityPicker(
                            context,
                            c,
                            f.entity!,
                          );
                          if (o != null) {
                            c.labels[o.id] = o.label;
                            c.setField(f.key, o.id);
                          }
                        }
                      : null,
                  child: InputDecorator(
                    decoration: InputDecoration(labelText: labelText),
                    child: Text(
                      value.isEmpty ? tr('stock.doc.pick') : c.labelOf(value),
                    ),
                  ),
                ),
              ),
              if (f.isLocation && canEdit)
                IconButton(
                  key: Key('stock-doc-scan-location-${_sideName(f)}'),
                  icon: const Icon(Icons.qr_code_scanner),
                  tooltip: tr('stock.doc.scan'),
                  onPressed: () => unawaited(_scanLocation(context, f)),
                ),
            ],
          ),
        );
      case FieldInput.reason:
        final value = c.draft.value(f.key);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: InkWell(
            key: Key('stock-doc-field-${f.key}'),
            onTap: enabled
                ? () async {
                    final o = await showFixedPicker(context, [
                      for (final r in kWriteOffReasons)
                        PickerOption(r, tr('stock.doc.reason.$r'), const {}),
                    ]);
                    if (o != null) c.setField(f.key, o.id);
                  }
                : null,
            child: InputDecorator(
              decoration: InputDecoration(labelText: labelText),
              child: Text(
                value.isEmpty
                    ? tr('stock.doc.pick')
                    : tr('stock.doc.reason.$value'),
              ),
            ),
          ),
        );
      case FieldInput.text || FieldInput.date:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: TextFormField(
            key: Key('stock-doc-field-${f.key}'),
            initialValue: c.draft.value(f.key),
            enabled: enabled,
            decoration: InputDecoration(
              labelText: labelText,
              hintText: f.input == FieldInput.date ? 'YYYY-MM-DD' : null,
            ),
            onChanged: (v) => c.setField(f.key, v),
          ),
        );
    }
  }

  String _sideName(HeaderField f) => f.side.name;

  Future<void> _scanLocation(BuildContext context, HeaderField f) async {
    final result = await showScanFill(context);
    if (result == null) return;
    if (!controller.applyLocationScan(result, f.key)) {
      controller.showMessage(scanRefusal(result));
    }
  }
}

/// The text shown when a scan fills nothing.
String scanRefusal(CodeResolution result) => switch (result.status) {
  CodeStatus.assigned => tr('stock.doc.scan.wrongKind'),
  CodeStatus.notAssigned => tr('codes.status.notAssigned'),
  CodeStatus.retired => tr('codes.status.retired'),
  CodeStatus.assignmentConflict => tr('codes.status.conflict'),
  CodeStatus.notKnown => tr('codes.status.notKnown'),
};

class _LineEditor extends ConsumerWidget {
  const _LineEditor({
    super.key,
    required this.index,
    required this.controller,
    required this.enabled,
  });

  final int index;
  final DocFormController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = controller;
    final line = c.draft.lines[index];
    final spec = c.draft.spec;
    return Card(
      key: Key('stock-doc-line-$index'),
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    key: Key('stock-doc-line-$index-item'),
                    onTap: enabled
                        ? () async {
                            final o = await showEntityPicker(
                              context,
                              c,
                              'catalog_item',
                            );
                            if (o != null) c.chooseItem(index, o);
                          }
                        : null,
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: tr('stock.doc.item'),
                      ),
                      child: Text(
                        line.item.isEmpty
                            ? tr('stock.doc.pick')
                            : c.labelOf(line.item),
                      ),
                    ),
                  ),
                ),
                if (enabled) ...[
                  IconButton(
                    key: Key('stock-doc-scan-line-$index'),
                    icon: const Icon(Icons.qr_code_scanner),
                    tooltip: tr('stock.doc.scan'),
                    onPressed: () => unawaited(_scan(context)),
                  ),
                  if (c.draft.lines.length > 1)
                    IconButton(
                      key: Key('stock-doc-remove-line-$index'),
                      icon: const Icon(Icons.delete_outline),
                      tooltip: tr('stock.doc.removeLine'),
                      onPressed: () => c.removeLine(index),
                    ),
                ],
              ],
            ),
            InkWell(
              key: Key('stock-doc-line-$index-uom'),
              onTap: enabled
                  ? () async {
                      final o = await showEntityPicker(
                        context,
                        c,
                        'catalog_uom',
                      );
                      if (o != null) c.setLine(index, line.copyWith(uom: o.id));
                    }
                  : null,
              child: InputDecorator(
                decoration: InputDecoration(labelText: tr('stock.doc.unit')),
                child: Text(
                  line.uom.isEmpty ? tr('stock.doc.pick') : c.labelOf(line.uom),
                ),
              ),
            ),
            if (line.item.isNotEmpty)
              InkWell(
                key: Key('stock-doc-line-$index-lot'),
                onTap: enabled
                    ? () async {
                        final o = await showEntityPicker(
                          context,
                          c,
                          'catalog_lot',
                          itemId: line.item,
                        );
                        if (o != null) {
                          c.labels[o.id] = o.label;
                          c.setLine(index, line.copyWith(lot: o.id));
                        }
                      }
                    : null,
                child: InputDecorator(
                  decoration: InputDecoration(labelText: tr('stock.doc.lot')),
                  child: Text(
                    line.lot.isEmpty
                        ? tr('stock.doc.pick')
                        : c.labelOf(line.lot),
                  ),
                ),
              ),
            TextFormField(
              key: Key('stock-doc-line-$index-quantity'),
              initialValue: line.quantity,
              enabled: enabled,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: '${tr('stock.doc.quantity')} *',
              ),
              onChanged: (v) =>
                  c.setLine(index, c.draft.lines[index].copyWith(quantity: v)),
            ),
            if (spec.hasPrice) ...[
              TextFormField(
                key: Key('stock-doc-line-$index-unit_price'),
                initialValue: line.unitPrice,
                enabled: enabled,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: tr('stock.doc.field.unit_price'),
                ),
                onChanged: (v) => c.setLine(
                  index,
                  c.draft.lines[index].copyWith(unitPrice: v),
                ),
              ),
              TextFormField(
                key: Key('stock-doc-line-$index-line_value'),
                initialValue: line.lineValue,
                enabled: enabled,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: tr('stock.doc.field.line_value'),
                ),
                onChanged: (v) => c.setLine(
                  index,
                  c.draft.lines[index].copyWith(lineValue: v),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// One scan button per line: an item code fills the item, a lot code fills
  /// the lot (and the item from the lot record).
  Future<void> _scan(BuildContext context) async {
    final result = await showScanFill(context);
    if (result == null) return;
    final c = controller;
    var ok = false;
    switch (result.objectKind) {
      case CodeObjectKind.item:
        ok = await c.applyItemScan(result, index);
      case CodeObjectKind.lot:
        ok = await c.applyLotScan(result, index);
      case CodeObjectKind.location || CodeObjectKind.other:
        ok = false;
    }
    if (!ok) {
      c.showMessage(scanRefusal(result));
    }
  }
}
