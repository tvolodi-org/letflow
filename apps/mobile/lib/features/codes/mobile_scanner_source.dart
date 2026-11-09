/// The only file in lib/ that imports `package:mobile_scanner` (REQ-732).
///
/// Start failures (PWA M4): mobile_scanner 7.5.0's `MobileScannerController.start`
/// does not throw a platform failure (refused permission, no camera, an
/// insecure page). It stores it in `value.error` with `isRunning: false` and
/// completes normally; it throws only its own precondition errors. So this
/// adapter reads the stored state after `start()` and also listens to the
/// controller's value (an error stored outside our own `start()`, for example
/// on an app resume), and reports one event per start attempt:
/// `permissionDenied` is [ScanPermissionRefused], every other code is
/// [ScanCameraUnavailable]. The mapping is covered by
/// `mobile_scanner_source_test.dart` (MS1..MS6) through an injected
/// controller; the live camera is the owner's on-device check.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'scan_source.dart';

/// The event a stored or thrown camera error code becomes.
ScanEvent scanEventForError(MobileScannerErrorCode code) =>
    code == MobileScannerErrorCode.permissionDenied
    ? const ScanPermissionRefused()
    : const ScanCameraUnavailable();

class MobileScannerSource implements ScanSource {
  MobileScannerSource({@visibleForTesting MobileScannerController? controller})
    : _controller = controller ?? MobileScannerController(autoStart: false) {
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
    _controller.addListener(_onState);
  }

  final MobileScannerController _controller;
  final StreamController<ScanEvent> _events =
      StreamController<ScanEvent>.broadcast();
  late final StreamSubscription<BarcodeCapture> _subscription;

  /// One failure event per start attempt: the listener and the check after
  /// `start()` see the same stored error.
  bool _failureReported = false;

  @override
  Stream<ScanEvent> get events => _events.stream;

  @override
  bool get needsUserTap => kIsWeb;

  @override
  Future<void> start() async {
    _failureReported = false;
    try {
      await _controller.start();
    } on MobileScannerException catch (e) {
      // A start already in flight reports its own outcome.
      if (e.errorCode == MobileScannerErrorCode.controllerInitializing) return;
      _reportFailure(e.errorCode);
      return;
    } on Object {
      // INV-8: no realistic failure crashes the screen.
      _reportFailure(MobileScannerErrorCode.genericError);
      return;
    }
    _checkStored();
  }

  void _onState() => _checkStored();

  void _checkStored() {
    final st = _controller.value;
    final error = st.error;
    if (error != null && !st.isRunning) {
      _reportFailure(error.errorCode);
    } else if (error == null && st.isRunning) {
      // A running camera re-arms the report for a later stored failure.
      _failureReported = false;
    }
  }

  void _reportFailure(MobileScannerErrorCode code) {
    if (_failureReported || _events.isClosed) return;
    _failureReported = true;
    _events.add(scanEventForError(code));
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
  Widget buildPreview() => MobileScanner(
    controller: _controller,
    // The screens show their own texts (CameraStatusView), never the
    // package's default error preview.
    errorBuilder: (_, _) => const SizedBox.shrink(),
  );

  @override
  void dispose() {
    _controller.removeListener(_onState);
    unawaited(_subscription.cancel());
    unawaited(_events.close());
    unawaited(_controller.dispose());
  }
}
