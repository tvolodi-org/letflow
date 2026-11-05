/// Drives one count on the phone: open and close, place by scanning a
/// location code, item or lot scan, typed quantity, surplus line, lines and
/// entries (phone-flows.md sections 2 and 3). One detection, one request.
/// Nothing is stored on the device; the scanned text is sent unchanged.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../api/api_error.dart';
import '../../renderers/renderer_state.dart';
import '../codes/codes.dart';
import 'count_api.dart';
import 'count_models.dart';
import 'count_refusal.dart';
import 'scan_id.dart';

final RegExp _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
final RegExp _quantityPattern = RegExp(r'^\d+(\.\d+)?$');

bool isUuidText(String v) => _uuidPattern.hasMatch(v);

/// A decimal >= 0 with a dot; a comma, a sign or letters are refused.
bool isQuantityText(String v) => _quantityPattern.hasMatch(v);

/// Up to this many extra line pages are read to find the unit of an item.
const int kSurplusExtraPages = 5;

@immutable
class SurplusDraft {
  const SurplusDraft({
    required this.locationId,
    this.catalogItemId = '',
    this.catalogLotId = '',
    this.unitRef = '',
    this.codeNotUsable = false,
  });

  final String locationId;
  final String catalogItemId;
  final String catalogLotId;
  final String unitRef;

  /// The refused code could not name an item or lot (unknown, retired, a
  /// place, ...): the ids stay empty and the sheet says so.
  final bool codeNotUsable;
}

class CountDetailController extends ChangeNotifier {
  CountDetailController({
    required this.id,
    required this.api,
    required this.resolver,
    required this.source,
  }) {
    _subscription = source.events.listen((e) => unawaited(onEvent(e)));
  }

  final String id;
  final StockCountApi api;
  final CodesResolver resolver;
  final ScanSource source;
  late final StreamSubscription<ScanEvent> _subscription;

  RendererState<CountOrder> order = const RendererLoading();
  List<CountLine> lines = [];
  String? linesCursor;
  List<CountEntry> entries = [];
  String? entriesCursor;

  /// The current place (a location id from `codes/resolve`); screen only.
  String? placeId;
  CountRefusal? refusal;

  /// Message key of a non-refusal notice (place problems, not available).
  String? noticeKey;

  /// A permission / backpressure / fetch-failure state of the last action.
  RendererState<Object?>? failure;
  bool scanning = false;
  bool cameraRefused = false;
  bool busy = false;

  /// The last scan answer was a retry of an already counted scan.
  bool lastDuplicate = false;
  int? lastLineNo;
  String? _refusedText;
  Future<void> Function()? _retry;
  bool _disposed = false;

  bool get canSurplus => refusal == CountRefusal.scanNoLine;

  Future<void> load() async {
    order = const RendererLoading();
    _notify();
    RendererState<CountOrder> next;
    try {
      final o = await api.getCount(id);
      final first = await api.lines(id);
      lines = first.rows;
      linesCursor = first.nextCursor;
      next = RendererContent(data: o);
    } on ApiError catch (e) {
      next = rendererStateForError(e);
      if (e is NotFoundError || e is ModuleNotAvailableError) {
        noticeKey = 'stock.state.notAvailable';
      }
    } on MalformedStockAnswer {
      next = const RendererFetchFailure();
    }
    if (_disposed) return;
    order = next;
    _notify();
  }

  Future<void> loadMoreLines() async {
    final cursor = linesCursor;
    if (cursor == null) return;
    await _guard(() async {
      final page = await api.lines(id, cursor: cursor);
      lines = [...lines, ...page.rows];
      linesCursor = page.nextCursor;
    });
  }

  Future<void> loadEntries({bool more = false}) async {
    final cursor = more ? entriesCursor : null;
    if (more && cursor == null) return;
    await _guard(() async {
      final page = await api.entries(id, cursor: cursor);
      entries = more ? [...entries, ...page.rows] : page.rows;
      entriesCursor = page.nextCursor;
    });
  }

  Future<void> open() => _transition(api.open);

  Future<void> close() => _transition(api.close);

  Future<void> _transition(Future<CountOrder> Function(String) call) async {
    await _guard(() async {
      final o = await call(id);
      order = RendererContent(data: o);
      final first = await api.lines(id);
      lines = first.rows;
      linesCursor = first.nextCursor;
    });
  }

  // -- scanning ---------------------------------------------------------------

  Future<void> startScanning() async {
    if (cameraRefused) return;
    scanning = true;
    _notify();
    await source.start();
  }

  Future<void> scanAgain() => startScanning();

  Future<void> onEvent(ScanEvent event) async {
    switch (event) {
      case ScanPermissionRefused():
        cameraRefused = true;
        scanning = false;
        _notify();
      case ScanDetected(:final text):
        // `scanning` flips synchronously: extra detections are dropped.
        if (!scanning) return;
        if (text == null || text.isEmpty) return;
        scanning = false;
        await source.stop();
        await submitScan(text);
    }
  }

  /// Typed or scanned [text], sent unchanged. Only the empty string is
  /// refused locally.
  Future<void> submitScan(String text) async {
    if (text.isEmpty || busy) return;
    if (scanning) {
      scanning = false;
      await source.stop();
    }
    final place = placeId;
    if (place == null) {
      await _guard(() => _resolvePlace(text));
    } else {
      final scanId = newScanId();
      await _guard(() => _runScan(text, place, scanId));
    }
  }

  Future<void> _resolvePlace(String text) async {
    _retry = () => _guard(() => _resolvePlace(text));
    CodeResolution result;
    try {
      result = await resolver.resolve(text);
    } on NotFoundError {
      noticeKey = 'stock.place.notKnown';
      return;
    } on ModuleNotAvailableError {
      // The resolve route's own 404 is "not known", not "module missing".
      noticeKey = 'stock.place.notKnown';
      return;
    } on MalformedResolveAnswer {
      throw const MalformedStockAnswer();
    }
    switch (result.status) {
      case CodeStatus.assigned:
        final target = result.targetId;
        if (result.objectKind == CodeObjectKind.location && target != null) {
          placeId = target;
        } else {
          noticeKey = 'stock.place.notLocation';
        }
      case CodeStatus.notAssigned:
        noticeKey = 'stock.place.notAssigned';
      case CodeStatus.retired:
        noticeKey = 'stock.place.retired';
      case CodeStatus.assignmentConflict:
        noticeKey = 'stock.place.conflict';
      case CodeStatus.notKnown:
        noticeKey = 'stock.place.notKnown';
    }
  }

  /// The same [scanId] is sent again by the retry after a network failure.
  Future<void> _runScan(String text, String place, String scanId) async {
    _retry = () => _guard(() => _runScan(text, place, scanId));
    _refusedText = text;
    final answer = await api.scan(
      id,
      scannedText: text,
      locationId: place,
      scanId: scanId,
    );
    switch (answer) {
      case ScanLine(:final line, :final duplicate):
        _putLine(line);
        lastDuplicate = duplicate;
        lastLineNo = line.lineNo;
      case ScanLocation(:final locationId):
        placeId = locationId;
    }
  }

  void _putLine(CountLine line) {
    final i = lines.indexWhere((l) => l.lineNo == line.lineNo);
    if (i >= 0) {
      lines = [...lines]..[i] = line;
    } else {
      lines = [...lines, line]..sort((a, b) => a.lineNo.compareTo(b.lineNo));
    }
  }

  void clearPlace() {
    placeId = null;
    _notify();
  }

  // -- typed quantity and surplus ----------------------------------------------

  /// Returns true when the server accepted [text]; an invalid [text] is
  /// refused here and nothing is sent.
  Future<bool> setCount(int lineNo, String text) async {
    if (!isQuantityText(text)) return false;
    return _guardOk(() async {
      _putLine(await api.setCount(id, lineNo, text));
      lastLineNo = lineNo;
      lastDuplicate = false;
    });
  }

  /// Resolves the refused scan text once (unchanged) to pre-fill the ids.
  Future<SurplusDraft> prepareSurplus() async {
    final place = placeId ?? '';
    final text = _refusedText;
    if (text == null) return SurplusDraft(locationId: place);
    CodeResolution r;
    try {
      r = await resolver.resolve(text);
    } on ApiError {
      return SurplusDraft(locationId: place, codeNotUsable: true);
    } on MalformedResolveAnswer {
      return SurplusDraft(locationId: place, codeNotUsable: true);
    }
    final target = r.targetId;
    if (r.status != CodeStatus.assigned || target == null) {
      return SurplusDraft(locationId: place, codeNotUsable: true);
    }
    try {
      switch (r.objectKind) {
        case CodeObjectKind.item:
          final unit = await _findLine((l) => l.catalogItemId == target);
          return SurplusDraft(
            locationId: place,
            catalogItemId: target,
            unitRef: unit?.unitRef ?? '',
          );
        case CodeObjectKind.lot:
          final line = await _findLine((l) => l.catalogLotId == target);
          return SurplusDraft(
            locationId: place,
            catalogLotId: target,
            catalogItemId: line?.catalogItemId ?? '',
            unitRef: line?.unitRef ?? '',
          );
        case CodeObjectKind.location:
        case CodeObjectKind.other:
          return SurplusDraft(locationId: place, codeNotUsable: true);
      }
    } on ApiError {
      return SurplusDraft(locationId: place);
    } on MalformedStockAnswer {
      return SurplusDraft(locationId: place);
    }
  }

  Future<CountLine?> _findLine(bool Function(CountLine) test) async {
    var extra = 0;
    while (true) {
      for (final l in lines) {
        if (test(l)) return l;
      }
      final cursor = linesCursor;
      if (cursor == null || extra >= kSurplusExtraPages) return null;
      extra++;
      final page = await api.lines(id, cursor: cursor);
      lines = [...lines, ...page.rows];
      linesCursor = page.nextCursor;
    }
  }

  Future<bool> addSurplus({
    required String locationId,
    required String catalogItemId,
    required String unitRef,
    required String quantity,
    String catalogLotId = '',
  }) async {
    if (!isUuidText(locationId) ||
        !isUuidText(catalogItemId) ||
        !isUuidText(unitRef) ||
        (catalogLotId.isNotEmpty && !isUuidText(catalogLotId)) ||
        !isQuantityText(quantity)) {
      return false;
    }
    return _guardOk(() async {
      final line = await api.addSurplus(
        id,
        locationId: locationId,
        catalogItemId: catalogItemId,
        unitRef: unitRef,
        countedQuantity: quantity,
        catalogLotId: catalogLotId.isEmpty ? null : catalogLotId,
      );
      _putLine(line);
      lastLineNo = line.lineNo;
      lastDuplicate = false;
    });
  }

  // -- failures ------------------------------------------------------------------

  Future<void> retry() async {
    final again = _retry;
    if (again != null) await again();
  }

  Future<bool> _guardOk(Future<void> Function() body) async {
    var ok = false;
    await _guard(() async {
      await body();
      ok = true;
    });
    return ok;
  }

  /// Runs one action: clears the last message, maps every failure to a
  /// refusal, a notice or a renderer state. Never throws.
  Future<void> _guard(Future<void> Function() body) async {
    if (busy) return;
    busy = true;
    refusal = null;
    noticeKey = null;
    failure = null;
    _retry = null;
    _notify();
    try {
      await body();
    } on ValidationError catch (e) {
      refusal = CountRefusal.fromReason(e.reason);
      _retry = null;
    } on ConflictError catch (e) {
      refusal = CountRefusal.fromReason(e.reason);
      _retry = null;
    } on NotFoundError {
      noticeKey = 'stock.state.notAvailable';
      _retry = null;
    } on ModuleNotAvailableError {
      noticeKey = 'stock.state.notAvailable';
      _retry = null;
    } on ApiError catch (e) {
      failure = rendererStateForError<Object?>(e);
      if (e is ForbiddenError || e is UnauthorizedError) _retry = null;
    } on MalformedStockAnswer {
      failure = const RendererFetchFailure();
    }
    busy = false;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
