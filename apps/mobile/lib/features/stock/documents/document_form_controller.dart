/// State of one document form (new or loaded). One request at a time: Save,
/// Discard and Issue are refused while another call is in flight, and no call
/// is retried by itself.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../api/api_error.dart';
import '../../../i18n/i18n.dart';
import '../../../offline/install_state.dart' show requestPersistentStorage;
import '../../../offline/offline_queue.dart';
import '../../../renderers/renderer_state.dart';
import '../../codes/codes_resolve.dart';
import '../voice/voice_models.dart';
import 'document_draft.dart';
import 'document_kinds.dart';
import 'document_pickers.dart';
import 'document_refusals.dart';
import 'documents_api.dart';

class DocFormController extends ChangeNotifier {
  DocFormController({
    required this.api,
    required this.pickers,
    required this.draft,
    this.queue,
    this.replacesQueuedId,
  });

  /// Edit and resend: the refused queue entry this draft replaces. It is
  /// removed only after the server accepted the draft or the new local copy
  /// was stored.
  final String? replacesQueuedId;

  /// Web only (PWA M3): a new draft saved without a network goes here. Null on
  /// Android / iOS (today's behaviour).
  final OfflineDraftQueue? queue;

  /// True after a Save was stored in the offline queue instead of sent.
  bool queuedLocally = false;

  final StockDocumentsApi api;
  final PickerLoader pickers;

  DocDraft draft;
  bool busy = false;
  bool discarded = false;

  /// A refusal text (stock reasons, 404), shown in the form.
  String? message;

  /// 403, 429, network and server failures (renderer states).
  RendererState<DocDraft>? failure;
  Future<void> Function()? _lastAction;

  /// Voice (REQ-747): items to choose among. While set, Save and Issue stay
  /// off. [voiceEpoch] changes when a draft fills lines, so the line editors
  /// are rebuilt with the new text.
  List<VoiceItem>? voiceChoices;
  String? _voiceQuantity;
  int voiceEpoch = 0;

  bool get hasPendingVoiceChoice => voiceChoices != null;

  final Map<String, List<PickerOption>> _options = {};
  final Map<String, String> labels = {};
  bool _dirty = false;
  bool _disposed = false;

  void showMessage(String text) {
    message = text;
    _notify();
  }

  bool get editable => draft.isDraft;

  /// A saved draft keeps its org unit (the server refuses a change).
  bool isLocked(String key) => draft.id != null && key == 'org_unit_id';

  String labelOf(String id) => id.isEmpty ? '' : labels[id] ?? id;

  Future<List<PickerOption>> options(String entity, {String? itemId}) async {
    final cacheKey = '$entity|${itemId ?? ''}';
    final cached = _options[cacheKey];
    if (cached != null) return cached;
    try {
      final loaded = await pickers.load(entity, itemId: itemId);
      _options[cacheKey] = loaded;
      for (final o in loaded) {
        labels[o.id] = o.label;
      }
      _notify();
      return loaded;
    } on ApiError {
      // A picker failure leaves its list empty; the form stays usable.
      return const [];
    }
  }

  void setField(String key, String value) {
    draft = draft.withField(key, value);
    _changed();
  }

  void setLine(int index, DocLine line) {
    final lines = [...draft.lines]..[index] = line;
    draft = draft.copyWith(lines: lines);
    _changed();
  }

  /// Picking an item presets the unit to the item's base unit and clears the
  /// lot.
  void chooseItem(int index, PickerOption item) {
    labels[item.id] = item.label;
    final base = item.fields['base_uom_id'];
    setLine(
      index,
      draft.lines[index].copyWith(
        item: item.id,
        uom: base is String ? base : '',
        lot: '',
      ),
    );
  }

  void addLine() {
    draft = draft.copyWith(lines: [...draft.lines, const DocLine()]);
    _changed();
  }

  void removeLine(int index) {
    if (draft.lines.length < 2) return;
    final lines = [...draft.lines]..removeAt(index);
    draft = draft.copyWith(lines: lines);
    _changed();
  }

  /// Fills a location field from a resolved code when it is assigned and a
  /// location. Returns false (and fills nothing) otherwise.
  bool applyLocationScan(CodeResolution result, String fieldKey) {
    final id = result.targetId;
    if (result.status != CodeStatus.assigned ||
        result.objectKind != CodeObjectKind.location ||
        id == null) {
      return false;
    }
    setField(fieldKey, id);
    return true;
  }

  /// A scanned item fills the item and presets its base unit.
  Future<bool> applyItemScan(CodeResolution result, int line) async {
    final id = result.targetId;
    if (result.status != CodeStatus.assigned ||
        result.objectKind != CodeObjectKind.item ||
        id == null) {
      return false;
    }
    return _fillItem(line, id);
  }

  /// Sets the item of [line] and presets its base unit (a read; a failing
  /// read leaves the unit to be picked by hand).
  Future<bool> _fillItem(int line, String id, {String? quantity}) async {
    PickerOption? item;
    try {
      item = await pickers.loadOne('catalog_item', id);
    } on ApiError {
      // The id is still valid; the unit is picked by hand.
    }
    if (line >= draft.lines.length) return false;
    if (item != null) labels[id] = item.label;
    final base = item?.fields['base_uom_id'];
    setLine(
      line,
      draft.lines[line].copyWith(
        item: id,
        uom: base is String ? base : '',
        lot: '',
        quantity: quantity,
      ),
    );
    return true;
  }

  // -- voice (REQ-747) -----------------------------------------------------------

  /// Fills the form from a voice draft for the user to check. Reads only: no
  /// save, issue or post is made here.
  Future<void> applyVoiceDraft(VoiceDraft d) async {
    voiceChoices = null;
    if (d.kind != draft.kind.wire) {
      showMessage(tr('stock.voice.kindMismatch'));
      return;
    }
    message = null;
    void place(String key, VoicePlace? p) {
      if (p == null) return;
      labels[p.id] = p.label;
      draft = draft.withField(key, p.id);
    }

    if (draft.kind == DocKind.transfer) {
      place('from_location_id', d.location);
      place('to_location_id', d.toLocation);
    } else {
      place('location_id', d.location);
    }
    voiceEpoch++;
    _dirty = true;
    if (d.items.length > 1) {
      voiceChoices = d.items;
      _voiceQuantity = d.quantity;
      _notify();
      return;
    }
    _notify();
    if (d.items.length == 1) {
      await _fillVoiceLine(d.items.first, d.quantity);
    }
  }

  Future<void> chooseVoiceItem(VoiceItem item) async {
    final q = _voiceQuantity;
    voiceChoices = null;
    _voiceQuantity = null;
    _notify();
    await _fillVoiceLine(item, q);
  }

  void dismissVoiceChoice() {
    voiceChoices = null;
    _voiceQuantity = null;
    _notify();
  }

  Future<void> _fillVoiceLine(VoiceItem item, String? quantity) async {
    final first = draft.lines.isEmpty ? null : draft.lines.first;
    final firstEmpty =
        first != null && first.item.isEmpty && first.quantity.isEmpty;
    var index = 0;
    if (!firstEmpty) {
      draft = draft.copyWith(lines: [...draft.lines, const DocLine()]);
      index = draft.lines.length - 1;
    }
    labels[item.id] = item.label;
    await _fillItem(index, item.id, quantity: quantity ?? '');
    voiceEpoch++;
    _notify();
  }

  /// A scanned lot fills the lot and, from the lot record, its item and the
  /// item's base unit. Returns false when the code is not an assigned lot.
  Future<bool> applyLotScan(CodeResolution result, int line) async {
    final id = result.targetId;
    if (result.status != CodeStatus.assigned ||
        result.objectKind != CodeObjectKind.lot ||
        id == null) {
      return false;
    }
    PickerOption? lot;
    PickerOption? item;
    try {
      lot = await pickers.loadOne('catalog_lot', id);
      final itemId = lot?.fields['item_id'];
      if (itemId is String && itemId != draft.lines[line].item) {
        item = await pickers.loadOne('catalog_item', itemId);
      }
    } on ApiError {
      // The lot id is still valid; the item stays as it was.
    }
    if (line >= draft.lines.length) return false;
    var next = draft.lines[line].copyWith(lot: id);
    if (lot != null) labels[id] = lot.label;
    final lotItem = lot?.fields['item_id'];
    if (item != null && lotItem is String) {
      labels[item.id] = item.label;
      final base = item.fields['base_uom_id'];
      next = next.copyWith(item: lotItem, uom: base is String ? base : '');
    }
    setLine(line, next);
    return true;
  }

  Future<void> save() => _run(() async {
    await _save();
  });

  Future<void> issue() => _run(() async {
    if (_dirty || draft.id == null) {
      if (!await _save()) return;
    }
    final saved = await api.issue(draft.id!);
    draft = saved;
    _dirty = false;
  });

  Future<void> discard() => _run(() async {
    final id = draft.id;
    if (id != null) await api.discard(id);
    discarded = true;
  });

  Future<bool> _save() async {
    if (!draft.isSaveable) return false;
    final id = draft.id;
    if (id == null) {
      try {
        draft = await api.save(draft);
        await _dropReplaced(queue);
      } on NetworkUnavailableError {
        final q = queue;
        if (q == null) rethrow;
        return _enqueue(q);
      }
    } else {
      draft = await api.replace(id, draft);
    }
    _dirty = false;
    return true;
  }

  /// Stores the new draft locally. Returns false: nothing was sent, so Issue
  /// stops here.
  Future<bool> _enqueue(OfflineDraftQueue q) async {
    final result = await q.enqueue(
      draft.toBody(),
      label: _label(),
      summary: _summary(),
    );
    if (result == EnqueueResult.stored) {
      await _dropReplaced(q);
      queuedLocally = true;
      _dirty = false;
      message = tr('offline.saved');
      unawaited(requestPersistentStorage());
    } else {
      message = tr('offline.full');
    }
    return false;
  }

  Future<void> _dropReplaced(OfflineDraftQueue? q) async {
    final old = replacesQueuedId;
    if (old == null || q == null) return;
    try {
      await q.remove(old);
    } on Object {
      // The old copy stays; the person can discard it from the list.
    }
  }

  /// "2 lines: Cement x2, Sand x1" (at most three names, then "+N").
  String _summary() {
    final lines = draft.lines;
    final shown = [
      for (final l in lines.take(3)) '${labelOf(l.item)} x${l.quantity}'.trim(),
    ].join(', ');
    final more = lines.length > 3 ? ' +${lines.length - 3}' : '';
    return tr('offline.summary')
        .replaceAll('{count}', '${lines.length}')
        .replaceAll('{items}', '$shown$more');
  }

  String _label() => tr('stock.doc.kind.${draft.kind.wire}');

  Future<void> retry() async {
    final action = _lastAction;
    if (action != null) await action();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy || !editable) return;
    busy = true;
    message = null;
    failure = null;
    _notify();
    _lastAction = () => _run(action);
    try {
      await action();
    } on ApiError catch (error) {
      final text = refusalMessage(error);
      if (text != null) {
        message = text;
      } else {
        failure = rendererStateForError<DocDraft>(error);
      }
    } on MalformedDocumentAnswer {
      failure = const RendererFetchFailure();
    }
    busy = false;
    _notify();
  }

  void _changed() {
    _dirty = true;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
