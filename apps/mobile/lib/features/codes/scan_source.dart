/// The one seam between the codes feature and a camera package (REQ-732).
/// Only `mobile_scanner_source.dart` imports the package; everything else,
/// tests included, talks to this interface, so a widget test never needs a
/// camera.
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

/// The device camera could not be used (permission refused or no camera).
final class ScanPermissionRefused extends ScanEvent {
  const ScanPermissionRefused();
}

abstract class ScanSource {
  Stream<ScanEvent> get events;
  Future<void> start();
  Future<void> stop();
  Widget buildPreview();
  void dispose();
}

/// Tests override this with a fake source.
final Provider<ScanSource> scanSourceProvider = Provider<ScanSource>(
  (ref) => MobileScannerSource(),
);
