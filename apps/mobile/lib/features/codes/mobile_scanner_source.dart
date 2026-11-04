/// The only file that imports `package:mobile_scanner` (REQ-732). Thin on
/// purpose: it needs a real camera, so it is covered by `flutter analyze`
/// and the build, not by a unit test.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'scan_source.dart';

class MobileScannerSource implements ScanSource {
  MobileScannerSource()
    : _controller = MobileScannerController(autoStart: false) {
    _subscription = _controller.barcodes.listen((capture) {
      String? text;
      for (final barcode in capture.barcodes) {
        final raw = barcode.rawValue;
        if (raw != null && raw.isNotEmpty) {
          text = raw;
          break;
        }
      }
      _events.add(ScanDetected(text));
    });
  }

  final MobileScannerController _controller;
  final StreamController<ScanEvent> _events =
      StreamController<ScanEvent>.broadcast();
  late final StreamSubscription<BarcodeCapture> _subscription;

  @override
  Stream<ScanEvent> get events => _events.stream;

  @override
  Future<void> start() async {
    try {
      await _controller.start();
    } on MobileScannerException {
      // Permission refused, unsupported device or any start failure: the
      // screen falls back to the typed field.
      _events.add(const ScanPermissionRefused());
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _controller.stop();
    } on MobileScannerException {
      // Stopping a camera that never started is not an error for the caller.
    }
  }

  @override
  Widget buildPreview() => MobileScanner(controller: _controller);

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    unawaited(_events.close());
    unawaited(_controller.dispose());
  }
}
