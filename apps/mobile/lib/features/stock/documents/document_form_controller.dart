/// State of one document form (new or loaded). One request at a time: Save,
/// Discard and Issue are refused while another call is in flight, and no call
/// is retried by itself.
library;

import 'package:flutter/foundation.dart';

import '../../../api/api_error.dart';
import '../../../renderers/renderer_state.dart';
import '../../codes/codes_resolve.dart';
import 'document_draft.dart';
import 'document_pickers.dart';
import 'document_refusals.dart';
import 'documents_api.dart';

class DocFormController extends ChangeNotifier {
  DocFormController({
    required this.api,
    required this.pickers,
    required this.draft,
  });

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
      ),
    );
    return true;
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
    draft = id == null ? await api.save(draft) : await api.replace(id, draft);
    _dirty = false;
    return true;
  }

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
