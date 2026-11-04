import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:letflow/features/codes/scan_source.dart';

class FakeScanSource implements ScanSource {
  final StreamController<ScanEvent> controller =
      StreamController<ScanEvent>.broadcast();
  int starts = 0;
  int stops = 0;
  bool disposed = false;

  @override
  Stream<ScanEvent> get events => controller.stream;

  @override
  Future<void> start() async => starts++;

  @override
  Future<void> stop() async => stops++;

  @override
  Widget buildPreview() => const SizedBox(key: Key('fake-preview'));

  @override
  void dispose() => disposed = true;

  void detect(String? text) => controller.add(ScanDetected(text));
}
