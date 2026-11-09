/// The camera area of a scan screen when it shows no preview (PWA M4): the
/// tap-to-start intro (web: Safari starts a camera only after a tap), the
/// refused text and the unavailable text. Shared by the codes scan screen,
/// the document scan sheet and the stock count screen, so all three say the
/// same thing. The typed field below it stays the fallback in every state.
library;

import 'package:flutter/material.dart';

import '../../i18n/i18n.dart';
import 'scan_source.dart';

class CameraStatusView extends StatelessWidget {
  const CameraStatusView({
    super.key,
    required this.phase,
    required this.onStart,
    required this.keyPrefix,
  });

  final CameraPhase phase;
  final VoidCallback onStart;

  /// `codes`, `stock-doc-scan` or `stock-count`: the widget keys are
  /// `<prefix>-camera-intro`, `-camera-start`, `-camera-refused` and
  /// `-camera-unavailable`.
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    switch (phase) {
      case CameraPhase.awaitingTap:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(key: Key('$keyPrefix-camera-intro'), tr('codes.camera.intro')),
            const SizedBox(height: 8),
            FilledButton(
              key: Key('$keyPrefix-camera-start'),
              onPressed: onStart,
              child: Text(tr('codes.camera.start')),
            ),
          ],
        );
      case CameraPhase.refused:
        return Text(
          key: Key('$keyPrefix-camera-refused'),
          tr('codes.camera.refused'),
        );
      case CameraPhase.unavailable:
        return Text(
          key: Key('$keyPrefix-camera-unavailable'),
          tr('codes.camera.unavailable'),
        );
    }
  }
}
