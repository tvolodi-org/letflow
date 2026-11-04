/// Drives the scan screen (REQ-732): one detection, one request.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../api/api_error.dart';
import '../../renderers/renderer_state.dart';
import 'codes_resolve.dart';
import 'scan_source.dart';

class CodesScanController extends ChangeNotifier {
  CodesScanController({required this.resolver, required this.source}) {
    _subscription = source.events.listen((event) => unawaited(onEvent(event)));
  }

  final CodesResolver resolver;
  final ScanSource source;
  late final StreamSubscription<ScanEvent> _subscription;

  RendererState<CodeResolution>? state;
  bool scanning = false;
  bool cameraRefused = false;
  String? lastText;
  bool _disposed = false;

  Future<void> startScanning() async {
    if (cameraRefused) return;
    scanning = true;
    _notify();
    await source.start();
  }

  Future<void> onEvent(ScanEvent event) async {
    switch (event) {
      case ScanPermissionRefused():
        cameraRefused = true;
        scanning = false;
        _notify();
      case ScanDetected(:final text):
        // Extra detections while a request is in flight (or after one) are
        // dropped: `scanning` flips synchronously, before any await.
        if (!scanning) return;
        if (text == null || text.isEmpty) return;
        scanning = false;
        await source.stop();
        await lookUp(text);
    }
  }

  /// Sends [text] unchanged. Only the empty string is refused locally.
  Future<void> lookUp(String text) async {
    if (text.isEmpty) return;
    if (scanning) {
      scanning = false;
      await source.stop();
    }
    lastText = text;
    state = const RendererLoading();
    _notify();
    RendererState<CodeResolution> next;
    try {
      final result = await resolver.resolve(text);
      next = RendererContent(data: result);
    } on NotFoundError {
      next = RendererContent(data: _notKnown(text));
    } on ModuleNotAvailableError {
      // The resolve route's own 404 is "not known", not "module missing".
      next = RendererContent(data: _notKnown(text));
    } on ApiError catch (error) {
      next = rendererStateForError<CodeResolution>(error);
    } on MalformedResolveAnswer {
      next = const RendererFetchFailure();
    }
    if (_disposed) return;
    state = next;
    _notify();
  }

  Future<void> retry() async {
    final text = lastText;
    if (text != null) await lookUp(text);
  }

  Future<void> scanAgain() async {
    state = null;
    await startScanning();
  }

  CodeResolution _notKnown(String text) =>
      CodeResolution(status: CodeStatus.notKnown, value: text);

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
