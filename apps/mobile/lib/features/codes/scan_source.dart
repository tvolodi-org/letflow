/// The one seam between the codes feature and a camera package (REQ-732).
/// In lib/, only `mobile_scanner_source.dart` imports the package; everything
/// else talks to this interface, so a widget test never needs a camera (the
/// adapter's own test drives it through a stub controller).
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'mobile_scanner_source.dart';

sealed class ScanEvent {
  const ScanEvent();
}

/// One detection. [text] is the raw text exactly as read (null or empty when
/// the detection carried no text).
final class ScanDetected extends ScanEvent {
  const ScanDetected(this.text);
  final String? text;
}

/// The user (or the browser) refused the camera permission.
final class ScanPermissionRefused extends ScanEvent {
  const ScanPermissionRefused();
}

/// The camera cannot be used for another reason: no camera, an unsupported
/// browser, an insecure (non-HTTPS) page, or a start that failed (PWA M4).
final class ScanCameraUnavailable extends ScanEvent {
  const ScanCameraUnavailable();
}

/// What the camera area of a scan screen shows instead of the preview.
enum CameraPhase { awaitingTap, refused, unavailable }

abstract class ScanSource {
  Stream<ScanEvent> get events;

  /// True where the camera may only start after a user tap (web: Safari
  /// refuses a camera start without one). Native starts at once.
  bool get needsUserTap;

  Future<void> start();
  Future<void> stop();
  Widget buildPreview();
  void dispose();
}

/// Tests override this with a fake source.
final Provider<ScanSource> scanSourceProvider = Provider<ScanSource>(
  (ref) => MobileScannerSource(),
);
