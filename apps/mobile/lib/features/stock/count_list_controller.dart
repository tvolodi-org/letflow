/// Drives the count list (phone-flows.md section 2 step 1).
library;

import 'package:flutter/foundation.dart';

import '../../api/api_error.dart';
import '../../renderers/renderer_state.dart';
import 'count_api.dart';
import 'count_models.dart';

const List<String> kCountListStatuses = ['counting', 'ordered'];

class CountListController extends ChangeNotifier {
  CountListController(this.api);

  final StockCountApi api;

  String status = kCountListStatuses.first;
  RendererState<CountPage<CountOrder>> state = const RendererLoading();

  /// A 404 of the stock routes: the one not-available message.
  bool notAvailable = false;
  bool loadingMore = false;
  bool _disposed = false;
  int _generation = 0;

  Future<void> load() async {
    final generation = ++_generation;
    state = const RendererLoading();
    notAvailable = false;
    _notify();
    RendererState<CountPage<CountOrder>> next;
    var missing = false;
    try {
      next = RendererContent(data: await api.listCounts(status: status));
    } on ApiError catch (e) {
      missing = e is NotFoundError || e is ModuleNotAvailableError;
      next = rendererStateForError(e);
    } on MalformedStockAnswer {
      next = const RendererFetchFailure();
    }
    if (_disposed || generation != _generation) return;
    notAvailable = missing;
    state = next;
    _notify();
  }

  Future<void> selectStatus(String value) {
    status = value;
    return load();
  }

  Future<void> loadMore() async {
    final current = state;
    if (current is! RendererContent<CountPage<CountOrder>> ||
        current.data.nextCursor == null ||
        loadingMore) {
      return;
    }
    loadingMore = true;
    _notify();
    final generation = _generation;
    try {
      final page = await api.listCounts(
        status: status,
        cursor: current.data.nextCursor,
      );
      if (_disposed || generation != _generation) return;
      state = RendererContent(
        data: CountPage(
          rows: [...current.data.rows, ...page.rows],
          nextCursor: page.nextCursor,
        ),
      );
    } on ApiError catch (e) {
      if (_disposed || generation != _generation) return;
      notAvailable = e is NotFoundError || e is ModuleNotAvailableError;
      state = rendererStateForError(e);
    } on MalformedStockAnswer {
      if (_disposed || generation != _generation) return;
      state = const RendererFetchFailure();
    } finally {
      loadingMore = false;
      _notify();
    }
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
