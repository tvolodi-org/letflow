// PWA M4 MS1..MS6: the camera adapter turns mobile_scanner's stored start
// errors (it stores them in `value.error` and completes normally) into one
// ScanEvent per start attempt. A stub controller replaces the platform; no
// camera, no platform channel.
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/features/codes/mobile_scanner_source.dart';
import 'package:letflow/features/codes/scan_source.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

MobileScannerException _error(MobileScannerErrorCode code) =>
    MobileScannerException(errorCode: code);

/// Stores [stored] like the package does after a failed platform start, or
/// throws [thrown]; touches no platform channel.
class _StubController extends MobileScannerController {
  _StubController() : super(autoStart: false);

  MobileScannerErrorCode? stored;
  Object? thrown;
  int starts = 0;

  @override
  Future<void> start({
    CameraFacing? cameraDirection,
    CameraLensType? cameraLensType,
  }) async {
    starts++;
    value = value.copyWith(isStarting: true);
    final t = thrown;
    if (t != null) throw t;
    final s = stored;
    value = s == null
        ? value.copyWith(
            isInitialized: true,
            isStarting: false,
            isRunning: true,
          )
        : value.copyWith(
            isInitialized: true,
            isStarting: false,
            isRunning: false,
            error: _error(s),
          );
  }

  @override
  Future<void> stop() async {
    value = value.copyWith(isRunning: false);
  }
}

Future<List<ScanEvent>> _run(
  _StubController stub,
  Future<void> Function(MobileScannerSource source) body,
) async {
  final source = MobileScannerSource(controller: stub);
  final events = <ScanEvent>[];
  final sub = source.events.listen(events.add);
  await body(source);
  await Future<void>.delayed(Duration.zero);
  await sub.cancel();
  return events;
}

void main() {
  test('MS1: a stored refusal is exactly one ScanPermissionRefused', () async {
    final stub = _StubController()
      ..stored = MobileScannerErrorCode.permissionDenied;
    final events = await _run(stub, (s) => s.start());
    expect(events, hasLength(1));
    expect(events.single, isA<ScanPermissionRefused>());
  });

  test('MS2: a stored unsupported or generic error is unavailable', () async {
    for (final code in [
      MobileScannerErrorCode.unsupported,
      MobileScannerErrorCode.genericError,
    ]) {
      final stub = _StubController()..stored = code;
      final events = await _run(stub, (s) => s.start());
      expect(events, hasLength(1), reason: '$code');
      expect(events.single, isA<ScanCameraUnavailable>(), reason: '$code');
    }
  });

  test('MS3: thrown errors; a start in flight reports nothing', () async {
    var stub = _StubController()
      ..thrown = _error(MobileScannerErrorCode.controllerDisposed);
    var events = await _run(stub, (s) => s.start());
    expect(events.single, isA<ScanCameraUnavailable>());

    stub = _StubController()..thrown = StateError('boom');
    events = await _run(stub, (s) => s.start());
    expect(events.single, isA<ScanCameraUnavailable>());

    stub = _StubController()
      ..thrown = _error(MobileScannerErrorCode.controllerInitializing);
    events = await _run(stub, (s) => s.start());
    expect(events, isEmpty);
  });

  test('MS4: a successful start reports nothing', () async {
    final stub = _StubController();
    final events = await _run(stub, (s) => s.start());
    expect(events, isEmpty);
    expect(stub.value.isRunning, isTrue);
  });

  test('MS5: no duplicates; each failed attempt and a later failure after a '
      'running camera report once', () async {
    final stub = _StubController()
      ..stored = MobileScannerErrorCode.permissionDenied;
    final events = await _run(stub, (s) async {
      await s.start(); // listener and post-start check see the same error
      await s.start(); // a retry with the same failure
      stub.stored = null;
      await s.start(); // the camera runs
      // An error the package stores later (for example on app resume).
      stub.value = stub.value.copyWith(
        isRunning: false,
        error: _error(MobileScannerErrorCode.unsupported),
      );
      // The same stored error seen again is not a second report.
      stub.value = stub.value.copyWith(
        isRunning: false,
        error: _error(MobileScannerErrorCode.unsupported),
      );
    });
    expect(stub.starts, 3);
    expect(events, hasLength(3));
    expect(events[0], isA<ScanPermissionRefused>());
    expect(events[1], isA<ScanPermissionRefused>());
    expect(events[2], isA<ScanCameraUnavailable>());
  });

  test('MS6: every package error code is classified', () {
    for (final code in MobileScannerErrorCode.values) {
      final event = scanEventForError(code);
      if (code == MobileScannerErrorCode.permissionDenied) {
        expect(event, isA<ScanPermissionRefused>(), reason: '$code');
      } else {
        expect(event, isA<ScanCameraUnavailable>(), reason: '$code');
      }
    }
  });

  test('MS7: needsUserTap is false off the web (flutter test is the VM)', () {
    final source = MobileScannerSource(controller: _StubController());
    expect(source.needsUserTap, isFalse);
  });
}
